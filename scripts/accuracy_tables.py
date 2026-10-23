#!/usr/bin/env python3
"""Accuracy numbers of Section IV from the saved result files.

Reads, from reports/accuracy/:
  lenet_imc_full_pre.json     LeNet-5 / MNIST, Model A, 10,000 test images, 5 seeds, 7 drift times;
                              5-bit ADC with the compensation applied at the ADC reference
  final_imc_results.json      ResNet-50 / ImageNet, 2,000 validation images (subset seed 42),
                              3 seeds, drift times 1, 1e2, 1e4, 1e6 s; 5-bit ADC as above
  lenet_imc_full.json         LeNet-5 / MNIST as above, 5-bit ADC with the compensation applied
                              after the converter (Section IV-C)
  lenet_imc_resid_signed.json LeNet-5 / MNIST as above, residual conductance of vacated cells,
                              memory window r = 10 and 100, baseline r = inf (Section IV-D)

Prints Table I, the Section IV-C comparison and the Section IV-D summary. Every value is the
mean over the seeds stored in the file, in percent. Standard library only.

Usage: python3 scripts/accuracy_tables.py [--dir reports/accuracy]
"""
import argparse
import hashlib
import json
import os
import statistics

ARMS_MNIST = (("algo_only", "None"), ("uniform", "Uniform"), ("layer_aware", "Layer-aware"))
ARMS_IMNET = (("none", "None"), ("uniform", "Uniform"), ("layer_aware", "Layer-aware"))
READOUTS = (("noADC", "noadc", "Ideal converter"), ("5b", "adc_pre", "5-bit ADC"))
TIMES = ("1e+00", "1e+01", "1e+02", "1e+03", "1e+04", "1e+05", "1e+06")


def load(folder, name):
    path = os.path.join(folder, name)
    with open(path, "rb") as f:
        raw = f.read()
    print(f"  {name:28s} md5 {hashlib.md5(raw).hexdigest()}")
    return json.loads(raw.decode("utf-8"))


def pct(x):
    return f"{100.0 * x:6.2f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="reports/accuracy")
    a = ap.parse_args()

    print("Input files")
    pre = load(a.dir, "lenet_imc_full_pre.json")
    imnet = load(a.dir, "final_imc_results.json")
    post = load(a.dir, "lenet_imc_full.json")
    resid = load(a.dir, "lenet_imc_resid_signed.json")

    # ImageNet: mean of top-1 over the seeds for each (readout, arm, drift time)
    runs = {}
    for r in imnet["rows"]:
        runs.setdefault((r["readout"], r["arm"], float(r["drift_t"])), []).append(r["top1"])
    im = {k: statistics.mean(v) for k, v in runs.items()}
    nseeds = sorted({len(v) for v in runs.values()})

    m = pre["meta"]
    print("\nTable I. Top-1 accuracy (%) at t = 1 s and t = 1e6 s")
    print(f"  MNIST: {m['n_images']} images, {m['seeds']} seeds; ImageNet: {imnet['meta']['n_images']} images, "
          f"{'/'.join(str(n) for n in nseeds)} seeds")
    print(f"  drift-free INT8 reference: MNIST {100 * m['clean']:.2f}, ImageNet {100 * imnet['clean']['top1']:.2f}")
    print(f"  {'Readout':16s} {'Allocation':12s} {'MNIST t=1':>10s} {'MNIST t=1e6':>12s} "
          f"{'ImageNet t=1':>13s} {'ImageNet t=1e6':>15s}")
    d = pre["data"]
    for ro_m, ro_i, ro_name in READOUTS:
        for (arm_m, label), (arm_i, _) in zip(ARMS_MNIST, ARMS_IMNET):
            print(f"  {ro_name:16s} {label:12s} {pct(d[f'{arm_m}|{ro_m}|1e+00']['mean']):>10s} "
                  f"{pct(d[f'{arm_m}|{ro_m}|1e+06']['mean']):>12s} {pct(im[(ro_i, arm_i, 1.0)]):>13s} "
                  f"{pct(im[(ro_i, arm_i, 1e6)]):>15s}")

    print("\nSection IV-C. MNIST, 5-bit ADC, t = 1e6 s: compensation at the ADC reference against after the converter")
    dp = post["data"]
    for arm, label in ARMS_MNIST:
        k = f"{arm}|5b|1e+06"
        print(f"  {label:12s} reference side {pct(d[k]['mean'])}   output side {pct(dp[k]['mean'])}")

    print("\nSection IV-D. MNIST, residual conductance of vacated cells, change against r = inf (points)")
    print("  max |change| over the drift grid; within std: |change| <= std of the r = inf run at every drift time")
    br = resid["by_ratio"]
    for r in ("100", "10"):
        for arm, label in ARMS_MNIST[1:]:
            for ro, _, ro_name in READOUTS:
                rows = []
                for t in TIMES:
                    x, ref = br[r][f"{arm}|{ro}|{t}"], br["inf"][f"{arm}|{ro}|{t}"]
                    rows.append((t, 100.0 * (x["mean"] - ref["mean"]), 100.0 * ref["std"], 100.0 * x["mean"]))
                worst = max(rows, key=lambda q: abs(q[1]))
                within = all(abs(q[1]) <= q[2] for q in rows)
                print(f"  r = {r:>3s}  {label:12s} {ro_name:16s} max |change| {abs(worst[1]):5.2f} at t = {worst[0]} s;"
                      f" within std: {'yes' if within else 'no '};  accuracy at t = 1e6 s {rows[-1][3]:6.2f}")


if __name__ == "__main__":
    main()
