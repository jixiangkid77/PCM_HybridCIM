"""
06_diagnose_quantization.py
===========================
Diagnostic script to compare weight distributions and quantization
error between Model A and Model B.

The hypothesis: Model B's RTL accuracy collapse (20% vs Model A 99%)
is caused by per-tensor quantization failing on Model B's weight
distribution. Specifically, if any layer has outlier weights, the
per-tensor scale gets stretched to accommodate them, and then all
the "normal" weights get quantized into a tiny sub-range of INT8,
losing precision.

This script prints:
  - weight distribution stats (min, max, std, percentiles)
  - quantization error (MSE between original and dequantized weights)
  - number of weights quantized to 0 (complete information loss)
  - histogram of INT8 values (is the INT8 range fully utilized?)

No model loading or inference; just reads .pth files directly.
"""

import os
import sys
import numpy as np
import torch


PAPER1_DIR = "D:/Project/PCM_Research5/outputs"
MODEL_A_PATH = os.path.join(PAPER1_DIR, "Model_Baseline.pth")
MODEL_B_PATH = os.path.join(PAPER1_DIR, "Model_Baseline_B.pth")

LAYERS = [
    ("conv1", "conv1.weight"),
    ("conv2", "conv2.weight"),
    ("fc1",   "fc1.weight"),
    ("fc2",   "fc2.weight"),
    ("fc3",   "fc3.weight"),
]


def analyze_layer(w_tensor, name, variant):
    """Analyze a single weight tensor using per-tensor quantization."""
    w = w_tensor.detach().cpu().numpy().astype(np.float32)
    flat = w.flatten()
    n = flat.size

    maxabs = float(np.abs(flat).max())
    mean = float(np.mean(flat))
    std  = float(np.std(flat))
    p50 = float(np.percentile(np.abs(flat), 50))
    p95 = float(np.percentile(np.abs(flat), 95))
    p99 = float(np.percentile(np.abs(flat), 99))

    # Outlier ratio: maxabs / p99
    outlier_ratio = maxabs / p99 if p99 > 0 else float('inf')

    # Per-tensor quantization
    scale = maxabs / 127.0 if maxabs > 0 else 1.0
    q = np.round(flat / scale).clip(-128, 127).astype(np.int32)
    dq = q.astype(np.float32) * scale

    # Quantization error
    err = flat - dq
    mse = float(np.mean(err ** 2))
    rmse_normalized = float(np.sqrt(mse) / std) if std > 0 else 0

    # How many weights are quantized to 0 (information loss)
    zeros = int(np.sum(q == 0))
    near_zero_pct = 100.0 * zeros / n

    # INT8 histogram: is the INT8 range fully utilized?
    int8_std = float(np.std(q))   # std of quantized values (INT8 units)

    print(f"\n--- Model {variant} : {name} ({n} weights) ---")
    print(f"  FP32  maxabs = {maxabs:.6f}  std = {std:.6f}")
    print(f"  FP32  |w|_p50  = {p50:.6f}")
    print(f"  FP32  |w|_p95  = {p95:.6f}")
    print(f"  FP32  |w|_p99  = {p99:.6f}")
    print(f"  Outlier ratio  = maxabs/p99 = {outlier_ratio:.2f}x")
    if outlier_ratio > 3.0:
        print(f"  >>> SUSPICIOUS: outliers stretch scale {outlier_ratio:.1f}x beyond p99!")
    print(f"  per-tensor scale = {scale:.6f}")
    print(f"  INT8  std     = {int8_std:.2f}  (ideal ~15-40 for full utilization)")
    print(f"  Quantized to 0 : {zeros}/{n} = {near_zero_pct:.2f}%")
    if near_zero_pct > 20:
        print(f"  >>> WARNING: {near_zero_pct:.1f}% of weights became 0 after quantization!")
    print(f"  Relative RMSE  = {rmse_normalized:.4f}  (smaller is better, <0.05 is good)")

    return {
        'outlier_ratio': outlier_ratio,
        'int8_std': int8_std,
        'near_zero_pct': near_zero_pct,
        'rmse_normalized': rmse_normalized,
        'scale': scale,
    }


def main():
    print("=" * 70)
    print(" Weight Distribution and Per-Tensor Quantization Analysis")
    print("=" * 70)

    for (path, variant) in [(MODEL_A_PATH, "A"), (MODEL_B_PATH, "B")]:
        print(f"\n\n{'#' * 70}")
        print(f"# MODEL {variant}")
        print(f"# {path}")
        print(f"{'#' * 70}")

        if not os.path.exists(path):
            print(f"ERROR: {path} not found")
            continue

        sd = torch.load(path, map_location='cpu', weights_only=False)
        for name, key in LAYERS:
            if key in sd:
                analyze_layer(sd[key], name, variant)
            else:
                print(f"WARN: {key} not in state_dict")

    print("\n\n" + "=" * 70)
    print(" COMPARISON SUMMARY")
    print("=" * 70)
    print(" Look for:")
    print("  - Layers where Model B's outlier_ratio >> Model A's")
    print("  - Layers where Model B's near_zero_pct >> 20%")
    print("  - Layers where Model B's int8_std is tiny (< 5)")
    print("    -> means weights are packed into a narrow INT8 range")
    print("    -> only a few INT8 values used -> massive precision loss")


if __name__ == "__main__":
    main()
