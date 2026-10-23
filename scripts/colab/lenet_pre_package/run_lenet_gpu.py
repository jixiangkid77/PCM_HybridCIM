#!/usr/bin/env python3
"""
run_lenet_gpu.py -- LeNet INT8 hybrid SRAM/PCM-IMC accuracy sweep on GPU (torch).

Same experiment as run_lenet_full.py but uses imc_torch (cuda) so the full
10000-image x multi-seed x drift-grid sweep runs in minutes on Colab instead of
hours on CPU. Forward is validated to reproduce the numpy reference image-for-image
and the RTL golden bit-exactly at the no-drift/no-ADC/no-noise point.

Arms (per drift time t, per seed): algo_only / uniform / layer_aware, each at ADC
off and 5-bit. clean = pristine INT8 (no drift, no ADC, no write noise).
Non-idealities: drift t^(-nu) (nu ~ N(0.10,0.03), Paper 1); per-cell write noise
(sigma matched to Paper 1 WRITE_NOISE=0.03); 5-bit ADC (Param.cpp levelOutput=32).
cellBit=2 sign-magnitude (NeuroSim Scheme III).

Inputs: --mnist (torchvision, calibrates exact input scale, self-checks vs
img_001.hex) or --hex-dir (pre-quantized img_*.hex).
"""

import argparse
import json
import math
import os
import re
import time
import numpy as np
import torch

from imc_vec import load_model, read_hex_bytes, LAYERS
from imc_torch import to_torch_model, forward_batch_t, nu_torch, writenoise_torch, DEFAULT_CFG

COMP = 0.10


# ---------- masks (numpy, Paper 1 semantics) ----------
def make_uniform_mask(model, budget=0.05):
    return {L: (np.abs(model["W"][L]) >= np.percentile(np.abs(model["W"][L]), 100 * (1 - budget)))
            for L in LAYERS}


def masks_to_torch(maskdict, device):
    return {L: torch.tensor(maskdict[L], device=device) for L in LAYERS}


def writenoise_sigma_cell(cellBit=2, ncell=4):
    return 0.03 * 127.0 / math.sqrt(sum((2 ** (cellBit * j)) ** 2 for j in range(ncell)))


# ---------- input loading ----------
def read_input_scale(src_dir):
    for ln in open(os.path.join(src_dir, "scales.txt")):
        m = re.match(r"\s*input\s+([\d.eE+-]+)", ln)
        if m:
            return float(m.group(1))
    raise SystemExit("input scale not found")


def calibrate_input_scale(root, n_calib=1000):
    from torchvision import datasets, transforms
    tf = transforms.Compose([transforms.ToTensor(), transforms.Normalize((0.1307,), (0.3081,))])
    ds = datasets.MNIST(root, train=True, download=True, transform=tf)
    mx = 0.0
    for i in range(n_calib):
        x, _ = ds[i]
        mx = max(mx, float(x.abs().max()))
    return mx / 127.0


def load_images_mnist(n, input_scale, root, selfcheck_hex=None):
    from torchvision import datasets, transforms
    tf = transforms.Compose([transforms.ToTensor(), transforms.Normalize((0.1307,), (0.3081,))])
    ds = datasets.MNIST(root, train=False, download=True, transform=tf)
    n = n or len(ds)
    X = np.zeros((n, 784), dtype=np.int64)
    y = np.zeros(n, dtype=np.int64)
    for i in range(n):
        x, lab = ds[i]
        X[i] = np.round(x.numpy() / input_scale).clip(-128, 127).astype(np.int64).flatten()
        y[i] = int(lab)
    if selfcheck_hex and os.path.exists(selfcheck_hex):
        ref = np.array(read_hex_bytes(selfcheck_hex, signed=True))
        ok = np.array_equal(X[0], ref)
        print(f"  input self-check (test[0] vs img_001.hex): {'PASS' if ok else 'FAIL'}")
        if not ok:
            raise SystemExit("input quantization mismatch")
    return X, y


def load_images_hex(img_dir, label_file, n):
    lab = {}
    for ln in open(label_file):
        m = re.match(r"\s*img_(\d+)\s+(\d+)", ln)
        if m:
            lab[int(m.group(1))] = int(m.group(2))
    avail = sorted(int(re.match(r"img_(\d+)\.hex", f).group(1))
                   for f in os.listdir(img_dir) if re.match(r"img_\d+\.hex", f))
    avail = avail[:n] if n else avail
    X = np.array([read_hex_bytes(os.path.join(img_dir, f"img_{k:03d}.hex"), signed=True)
                  for k in avail], dtype=np.int64)
    y = np.array([lab[k] for k in avail])
    return X, y


# ---------- chunked arm runner (GPU) ----------
def run_arm(tm, arm_mask_t, X, y, nu, wn, drift_t, comp, adc_bits, chunk):
    for L in LAYERS:
        tm["mask"][L] = arm_mask_t[L]
    tm["nu"] = nu
    cfg = dict(DEFAULT_CFG)
    cfg["drift_t"] = drift_t; cfg["comp"] = comp; cfg["adc_bits"] = adc_bits
    correct = 0
    with torch.no_grad():
        for i in range(0, len(X), chunk):
            _, preds = forward_batch_t(X[i:i + chunk], tm, cfg, wn=wn)
            correct += int((preds.cpu().numpy() == y[i:i + chunk]).sum())
    return correct / len(X)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src-dir", required=True)
    ap.add_argument("--v3-dir", required=True)
    ap.add_argument("--hex-dir", default=None)
    ap.add_argument("--mnist", action="store_true")
    ap.add_argument("--mnist-root", default="./_mnist")
    ap.add_argument("--n-calib", type=int, default=1000)
    ap.add_argument("--n-images", type=int, default=0)
    ap.add_argument("--seeds", type=int, default=5)
    ap.add_argument("--drift-times", default="1,1e1,1e2,1e3,1e4,1e5,1e6")
    ap.add_argument("--adc-bits", type=int, default=5)
    ap.add_argument("--no-write-noise", action="store_true")
    ap.add_argument("--chunk", type=int, default=1000)
    ap.add_argument("--fp64", action="store_true", help="use float64 (exact, slower on GPU)")
    ap.add_argument("--out", default="lenet_imc_gpu.json")
    args = ap.parse_args()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    dtype = torch.float64 if args.fp64 else torch.float32
    print(f"device: {device}, dtype: {dtype}")

    model = load_model(args.src_dir, args.v3_dir)
    tm = to_torch_model(model, device=device, dtype=dtype)
    times = [float(x) for x in args.drift_times.split(",")]

    if args.mnist:
        sc = calibrate_input_scale(args.mnist_root, args.n_calib)
        print(f"MNIST: calibrated input scale {sc:.12f} (scales.txt rounded {read_input_scale(args.src_dir)})")
        X, y = load_images_mnist(args.n_images, sc, args.mnist_root,
                                 selfcheck_hex=os.path.join(args.src_dir, "images", "img_001.hex"))
    else:
        X, y = load_images_hex(args.hex_dir, os.path.join(args.src_dir, "image_labels.txt"), args.n_images)
    print(f"images: {len(X)}, seeds: {args.seeds}, drift times: {times}")

    arms_np = {"algo_only": {L: np.zeros_like(model["mask"][L], dtype=bool) for L in LAYERS},
               "uniform": make_uniform_mask(model),
               "layer_aware": model["mask"]}
    arms = {k: masks_to_torch(v, device) for k, v in arms_np.items()}

    use_wn = not args.no_write_noise
    nus = [nu_torch(model, 1000 + s, device, dtype) for s in range(args.seeds)]
    wns = [writenoise_torch(model, 5000 + s, device, dtype) if use_wn else None
           for s in range(args.seeds)]
    sc_cell = writenoise_sigma_cell()
    print(f"write noise: {'ON' if use_wn else 'OFF'}"
          + (f" (sigma_cell={sc_cell:.6f}, value-level sigma=3.81 per Paper 1)" if use_wn else ""))

    clean = run_arm(tm, arms["layer_aware"], X, y, nus[0], None, 1.0, 0.0, None, args.chunk)
    print(f"clean (INT8, no drift, no ADC, no write noise): {100*clean:.2f}%")

    results = {"meta": {"n_images": len(X), "seeds": args.seeds, "times": times,
                        "adc_bits": args.adc_bits, "clean": clean, "device": device,
                        "dtype": str(dtype), "sign_scheme": "signmag_cellBit2", "cellBit": 2,
                        "write_noise": use_wn, "write_noise_sigma_cell": (sc_cell if use_wn else 0.0)},
               "data": {}}
    t_start = time.time()
    for arm, mask_t in arms.items():
        for adc_name, adc in [("noADC", None), (f"{args.adc_bits}b", args.adc_bits)]:
            for t in times:
                accs = []
                for s in range(args.seeds):
                    accs.append(run_arm(tm, mask_t, X, y, nus[s], wns[s], t, COMP, adc, args.chunk))
                accs = np.array(accs)
                results["data"][f"{arm}|{adc_name}|{t:.0e}"] = {
                    "mean": float(accs.mean()), "std": float(accs.std()), "vals": accs.tolist()}
                print(f"  {arm:12} {adc_name:6} t={t:.0e}: {100*accs.mean():6.2f}% +/- {100*accs.std():.2f}   "
                      f"[{time.time()-t_start:.0f}s]")

    with open(args.out, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nsaved -> {args.out}")
    print("\n=== layer_aware - uniform gap (pp) ===")
    print(f"  {'t':>7} | {'no-ADC':>8} | {f'{args.adc_bits}-bit':>8}")
    for t in times:
        g0 = 100 * (results["data"][f"layer_aware|noADC|{t:.0e}"]["mean"]
                    - results["data"][f"uniform|noADC|{t:.0e}"]["mean"])
        g5 = 100 * (results["data"][f"layer_aware|{args.adc_bits}b|{t:.0e}"]["mean"]
                    - results["data"][f"uniform|{args.adc_bits}b|{t:.0e}"]["mean"])
        print(f"  {t:7.0e} | {g0:7.2f}  | {g5:7.2f}")


if __name__ == "__main__":
    main()
