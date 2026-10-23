#!/usr/bin/env python3
"""
run_lenet_full.py -- LeNet INT8 hybrid SRAM/PCM-IMC accuracy sweep.

Arms (per drift time t, per seed): clean / algo_only / uniform / layer_aware,
each at ADC off and 5-bit. Reports mean +/- std over seeds.
Core question: does the layer-aware vs uniform gap survive 5-bit ADC.

Compute model (VALIDATED, see notes): per-weight drift t^(-nu) on unprotected
cellBit=2 sign-magnitude cells, two's-complement bit-serial input, subArray=64
tiling, 5-bit MLSA ADC per partial sum, global compensation t^(+0.10) after ADC.
Protected (~5%) weights are exact (SRAM). Anchored bit-exact to the RTL golden
at the no-drift/no-ADC point (including the all-PCM signed-input path).

NOT yet included: write noise (next increment, coupled to the final sign-scheme
choice once the NeuroSim C-segment config is locked). Sign scheme = sign-magnitude
(parameterizable). These do not change the qualitative LA-vs-uniform finding but
are needed for final numbers.

Two input modes:
  --hex-dir DIR   read pre-quantized img_*.hex (RTL preprocessing). Use this if
                  you generate the full test set with 02_quantize_and_export.py.
  --mnist         load torchvision MNIST test set and quantize on the fly with
                  the RTL recipe (ToTensor + Normalize(0.1307,0.3081); round to
                  INT8 with scales['input']). Includes a self-check against
                  img_001.hex. Requires torch/torchvision.
"""

import argparse
import json
import os
import re
import time
import numpy as np

from imc_vec import (load_model, forward_batch, DEFAULT_CFG, read_hex_bytes,
                     LAYERS, WCOUNT)

DRIFT_MEAN, DRIFT_STD, COMP = 0.10, 0.03, 0.10


# ---------- masks and nu (Paper 1 apply_drift semantics) ----------
def make_uniform_mask(model, budget=0.05):
    return {L: (np.abs(model["W"][L]) >= np.percentile(np.abs(model["W"][L]), 100 * (1 - budget)))
            for L in LAYERS}


def make_none_mask(model):
    return {L: np.zeros_like(model["mask"][L], dtype=bool) for L in LAYERS}


def regenerate_nu(model, seed):
    rng = np.random.RandomState(seed)
    return {L: rng.normal(DRIFT_MEAN, DRIFT_STD, model["W"][L].shape) for L in LAYERS}


# ---------- input loading ----------
def read_input_scale(src_dir):
    for ln in open(os.path.join(src_dir, "scales.txt")):
        m = re.match(r"\s*input\s+([\d.eE+-]+)", ln)
        if m:
            return float(m.group(1))
    raise SystemExit("input scale not found in scales.txt")


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


def calibrate_input_scale(root, n_calib=1000):
    """Reproduce 02_quantize_and_export.calibrate() exactly: input scale =
    (max abs normalized pixel over first n_calib TRAINING images) / 127.
    scales.txt only stores this rounded to 6 dp, which is too coarse to
    reproduce the images bit-exactly, so we recompute it here."""
    from torchvision import datasets, transforms
    tf = transforms.Compose([transforms.ToTensor(),
                             transforms.Normalize((0.1307,), (0.3081,))])
    ds = datasets.MNIST(root, train=True, download=True, transform=tf)
    mx = 0.0
    for i in range(n_calib):
        x, _ = ds[i]
        mx = max(mx, float(x.abs().max()))
    return mx / 127.0


def load_images_mnist(n, input_scale, root, selfcheck_hex=None):
    from torchvision import datasets, transforms
    tf = transforms.Compose([transforms.ToTensor(),
                             transforms.Normalize((0.1307,), (0.3081,))])
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
            raise SystemExit("input quantization mismatch; check transform/scale")
    return X, y


# ---------- chunked arm runner ----------
def run_arm(model, X, y, mask, nu, drift_t, comp, adc_bits, chunk=500):
    m = dict(model); m["mask"] = mask; m["nu"] = nu
    cfg = dict(DEFAULT_CFG)
    cfg["drift_t"] = drift_t; cfg["comp"] = comp; cfg["adc_bits"] = adc_bits
    correct = 0
    for i in range(0, len(X), chunk):
        _, preds = forward_batch(X[i:i + chunk], m, cfg)
        correct += int((preds == y[i:i + chunk]).sum())
    return correct / len(X)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src-dir", required=True, help="rtl_inputs_A (weights, scales)")
    ap.add_argument("--v3-dir", required=True, help="rtl_inputs_A_v3 (split)")
    ap.add_argument("--hex-dir", default=None, help="dir of img_*.hex (hex mode)")
    ap.add_argument("--mnist", action="store_true", help="load torchvision MNIST")
    ap.add_argument("--mnist-root", default="./_mnist")
    ap.add_argument("--n-calib", type=int, default=1000,
                    help="training images for input-scale calibration (match 02_quantize)")
    ap.add_argument("--n-images", type=int, default=0, help="0 = all available")
    ap.add_argument("--seeds", type=int, default=5)
    ap.add_argument("--drift-times", default="1,1e1,1e2,1e3,1e4,1e5,1e6")
    ap.add_argument("--adc-bits", type=int, default=5)
    ap.add_argument("--chunk", type=int, default=500)
    ap.add_argument("--out", default="lenet_imc_results.json")
    args = ap.parse_args()

    model = load_model(args.src_dir, args.v3_dir)
    times = [float(x) for x in args.drift_times.split(",")]

    if args.mnist:
        sc = calibrate_input_scale(args.mnist_root, args.n_calib)
        print(f"loading MNIST (calibrated input scale {sc:.12f}, "
              f"scales.txt rounded {read_input_scale(args.src_dir)}) ...")
        X, y = load_images_mnist(args.n_images, sc, args.mnist_root,
                                 selfcheck_hex=os.path.join(args.src_dir, "images", "img_001.hex"))
    else:
        X, y = load_images_hex(args.hex_dir, os.path.join(args.src_dir, "image_labels.txt"),
                               args.n_images)
    print(f"images: {len(X)},  seeds: {args.seeds},  drift times: {times}")

    la = model["mask"]
    uni = make_uniform_mask(model)
    arms = {"algo_only": make_none_mask(model), "uniform": uni, "layer_aware": la}

    # clean baseline (drift off; seed-independent)
    nu0 = regenerate_nu(model, 0)
    clean = run_arm(model, X, y, la, nu0, 1.0, 0.0, None, args.chunk)
    print(f"\nclean (INT8, no drift, no ADC): {100*clean:.2f}%")

    # sweep
    results = {"meta": {"n_images": len(X), "seeds": args.seeds, "times": times,
                        "adc_bits": args.adc_bits, "clean": clean,
                        "sign_scheme": "signmag", "write_noise": False},
               "data": {}}
    t_start = time.time()
    for arm, mask in arms.items():
        for adc_name, adc in [("noADC", None), (f"{args.adc_bits}b", args.adc_bits)]:
            for t in times:
                accs = []
                for s in range(args.seeds):
                    nu = regenerate_nu(model, 1000 + s)
                    accs.append(run_arm(model, X, y, mask, nu, t, COMP, adc, args.chunk))
                accs = np.array(accs)
                key = f"{arm}|{adc_name}|{t:.0e}"
                results["data"][key] = {"mean": float(accs.mean()), "std": float(accs.std()),
                                        "vals": accs.tolist()}
                print(f"  {arm:12} {adc_name:6} t={t:.0e}: "
                      f"{100*accs.mean():6.2f}% +/- {100*accs.std():.2f}   "
                      f"[{time.time()-t_start:.0f}s]")

    with open(args.out, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nsaved -> {args.out}")

    # quick gap summary
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
