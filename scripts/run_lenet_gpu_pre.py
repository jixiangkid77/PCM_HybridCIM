"""
LeNet IMC full grid with CORRECTED readout (comp-aware ADC reference),
mirroring the original run_lenet_gpu protocol: 3 arms x 7 drift times x
5 seeds x 10000 MNIST images, noADC + 5-bit. Differences from original:
  - ADC arm uses cfg["comp_pre"]=True (compensation scales the ADC reference)
  - anchor phase first: reproduces OLD post-comp cells at t=1e6 and compares
    against the embedded original results (validates same harness on this GPU)
  - per-cell checkpoint (resume-safe on Colab)
Usage (Colab):
  python3 run_lenet_gpu_pre.py --src-dir data/rtl_inputs_A --v3-dir data/rtl_inputs_A_v3 --mnist
"""
import os, json, time, argparse
import numpy as np
import torch
import run_lenet_gpu as G

OLD_REF = {'clean': 0.9892, 'layer_aware|5b|1e+06': [0.8055, 0.741, 0.7593, 0.7673, 0.787], 'layer_aware|noADC|1e+06': [0.9837, 0.9865, 0.9861, 0.9824, 0.9873], 'uniform|5b|1e+06': [0.3449, 0.3874, 0.3455, 0.2563, 0.2842], 'uniform|noADC|1e+06': [0.9805, 0.973, 0.9726, 0.9485, 0.9808]}

CKPT = "lenet_pre_ckpt.json"

def run_arm(tm, mask_t, X, y, nu, wn, t, comp, adc_bits, chunk, comp_pre):
    for L in G.LAYERS:
        tm["mask"][L] = mask_t[L]
    tm["nu"] = nu
    cfg = dict(G.DEFAULT_CFG)
    cfg["drift_t"] = t; cfg["comp"] = comp; cfg["adc_bits"] = adc_bits
    cfg["comp_pre"] = bool(comp_pre)
    correct = 0
    with torch.no_grad():
        for i in range(0, len(X), chunk):
            _, preds = G.forward_batch_t(X[i:i + chunk], tm, cfg, wn=wn)
            correct += int((preds.cpu().numpy() == y[i:i + chunk]).sum())
    return correct / len(X)

def load_ckpt():
    if os.path.exists(CKPT):
        return json.load(open(CKPT))
    return {"clean": None, "anchors": {}, "cells": {}}

def save_ckpt(d):
    json.dump(d, open(CKPT + ".tmp", "w"), indent=1); os.replace(CKPT + ".tmp", CKPT)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src-dir", required=True)
    ap.add_argument("--v3-dir", required=True)
    ap.add_argument("--mnist", action="store_true")
    ap.add_argument("--mnist-root", default="./_mnist")
    ap.add_argument("--n-calib", type=int, default=1000)
    ap.add_argument("--n-images", type=int, default=0)
    ap.add_argument("--seeds", type=int, default=5)
    ap.add_argument("--drift-times", default="1,1e1,1e2,1e3,1e4,1e5,1e6")
    ap.add_argument("--adc-bits", type=int, default=5)
    ap.add_argument("--chunk", type=int, default=1000)
    ap.add_argument("--out", default="lenet_imc_full_pre.json")
    args = ap.parse_args()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    dtype = torch.float32
    print(f"device: {device}", flush=True)
    model = G.load_model(args.src_dir, args.v3_dir)
    tm = G.to_torch_model(model, device=device, dtype=dtype)
    times = [float(x) for x in args.drift_times.split(",")]
    sc = G.calibrate_input_scale(args.mnist_root, args.n_calib)
    X, y = G.load_images_mnist(args.n_images, sc, args.mnist_root,
                               selfcheck_hex=os.path.join(args.src_dir, "images", "img_001.hex"))
    print(f"images: {len(X)}, seeds: {args.seeds}, times: {times}", flush=True)

    arms_np = {"algo_only": {L: np.zeros_like(model["mask"][L], dtype=bool) for L in G.LAYERS},
               "uniform": G.make_uniform_mask(model),
               "layer_aware": model["mask"]}
    arms = {k: G.masks_to_torch(v, device) for k, v in arms_np.items()}
    nus = [G.nu_torch(model, 1000 + s, device, dtype) for s in range(args.seeds)]
    wns = [G.writenoise_torch(model, 5000 + s, device, dtype) for s in range(args.seeds)]

    d = load_ckpt()
    if d["clean"] is None:
        c = run_arm(tm, arms["layer_aware"], X, y, nus[0], None, 1.0, 0.0, None, args.chunk, False)
        d["clean"] = c; save_ckpt(d)
    print(f"clean INT8 = {100*d['clean']:.2f}%  (original {100*OLD_REF['clean']:.2f}%)", flush=True)

    # anchor phase: OLD readout (comp_pre=False) at t=1e6, seeds 0-1, vs embedded originals
    if len(X) == 10000:
        for arm in ["layer_aware", "uniform"]:
            for ro, adc in [("5b", args.adc_bits), ("noADC", None)]:
                for s in range(min(2, args.seeds)):
                    k = f"{arm}|{ro}|s{s}"
                    if k in d["anchors"]:
                        continue
                    a = run_arm(tm, arms[arm], X, y, nus[s], wns[s], 1e6, G.COMP, adc, args.chunk, False)
                    old = OLD_REF[f"{arm}|{ro}|1e+06"][s]
                    d["anchors"][k] = {"mine": a, "old": old}
                    save_ckpt(d)
                    diff = (a - old) * 100
                    tag = "PASS" if abs(diff) <= 0.10 else "CHECK"
                    print(f"[anchor] {arm:12s} {ro:5s} t=1e6 s{s}: mine {100*a:.2f}  "
                          f"old {100*old:.2f}  diff {diff:+.2f} pp  {tag}", flush=True)

    # corrected grid
    plan = [(arm, ro, adc, pre, t, s)
            for arm in arms
            for ro, adc, pre in [("noADC", None, False), (f"{args.adc_bits}b", args.adc_bits, True)]
            for t in times for s in range(args.seeds)]
    todo = [c for c in plan if f"{c[0]}|{c[1]}|{c[4]:.0e}|s{c[5]}" not in d["cells"]]
    print(f"grid: {len(plan)} cells, {len(plan)-len(todo)} done, {len(todo)} to run", flush=True)
    t0 = time.time()
    for arm, ro, adc, pre, t, s in todo:
        a = run_arm(tm, arms[arm], X, y, nus[s], wns[s], t, G.COMP, adc, args.chunk, pre)
        d["cells"][f"{arm}|{ro}|{t:.0e}|s{s}"] = a
        save_ckpt(d)
        print(f"  {arm:12s} {ro:6s} t={t:.0e} s{s}: {100*a:.2f}%   [{time.time()-t0:.0f}s]", flush=True)

    # assemble in the original output schema
    results = {"meta": {"n_images": len(X), "seeds": args.seeds, "times": times,
                        "adc_bits": args.adc_bits, "clean": d["clean"], "device": device,
                        "dtype": str(dtype), "sign_scheme": "signmag_cellBit2", "cellBit": 2,
                        "write_noise": True,
                        "write_noise_sigma_cell": G.writenoise_sigma_cell(),
                        "readout": "ADC arm uses comp-aware ADC reference (comp_pre)"},
               "anchors": d["anchors"], "data": {}}
    for arm in arms:
        for ro in ["noADC", f"{args.adc_bits}b"]:
            for t in times:
                vals = [d["cells"].get(f"{arm}|{ro}|{t:.0e}|s{s}") for s in range(args.seeds)]
                if any(v is None for v in vals):
                    continue
                v = np.array(vals)
                results["data"][f"{arm}|{ro}|{t:.0e}"] = {"mean": float(v.mean()),
                                                          "std": float(v.std()), "vals": v.tolist()}
    with open(args.out, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nsaved -> {args.out}", flush=True)
    print("\n=== layer_aware - uniform gap (pp) ===", flush=True)
    print(f"  {'t':>7} | {'no-ADC':>8} | {'5b corrected':>12}")
    for t in times:
        ka, ku = f"layer_aware|noADC|{t:.0e}", f"uniform|noADC|{t:.0e}"
        kA, kU = f"layer_aware|{args.adc_bits}b|{t:.0e}", f"uniform|{args.adc_bits}b|{t:.0e}"
        if all(k in results["data"] for k in [ka, ku, kA, kU]):
            g0 = 100 * (results["data"][ka]["mean"] - results["data"][ku]["mean"])
            g5 = 100 * (results["data"][kA]["mean"] - results["data"][kU]["mean"])
            print(f"  {t:7.0e} | {g0:7.2f}  | {g5:11.2f}")

if __name__ == "__main__":
    main()
