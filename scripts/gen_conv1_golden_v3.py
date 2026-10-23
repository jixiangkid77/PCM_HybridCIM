#!/usr/bin/env python3
"""
gen_conv1_golden_v3.py
-----------------------
Generate an RTL-equivalent integer golden for the LeNet-5 conv1 layer
output, given the same hex inputs the RTL itself loads.

This script reproduces conv_engine.v's exact integer datapath:

    For each output (c_out, y, x):
        acc = bias[c_out]              # 32-bit signed, loaded BEFORE shift
        for ky in 0..4:
            for kx in 0..4:
                py = y + ky - 2        # padding = 2
                px = x + kx - 2
                v = image[py][px] if in-bounds else 0        # zero pad
                w = weight[c_out, 0, ky, kx]                  # signed INT8
                acc += v * w
        if acc <= 0:                   # ReLU check BEFORE shift
            out = 0
        else:
            shifted = acc >> rshift    # arithmetic right shift, truncate
            out = 127 if shifted > 127 else shifted

Why not PyTorch FP32 output?
  PyTorch FP32 -> quantize -> ReLU -> saturate has 1-LSB rounding
  ambiguity vs the RTL integer path. The script reproduces the RTL
  bit-exact, so the golden cannot disagree with correct RTL output.

Validated against existing conv1_out_img1_ref.hex (Model A): 4704/4704
exact match. Safe to use as Step 7 testbench reference.
"""

import argparse
import sys
from pathlib import Path


# ---------- hex parsing helpers ----------

def read_hex_bytes(path, n_expected=None, signed=True):
    vals = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('//'):
                continue
            v = int(line, 16)
            if signed and v >= 128:
                v -= 256
            vals.append(v)
    if n_expected is not None and len(vals) != n_expected:
        sys.exit(f"ERROR: {path}: got {len(vals)} entries, expected {n_expected}")
    return vals


def read_hex_words(path, width_bits=32, n_expected=None):
    vals = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('//'):
                continue
            v = int(line, 16)
            sign_bit = 1 << (width_bits - 1)
            if v >= sign_bit:
                v -= (1 << width_bits)
            vals.append(v)
    if n_expected is not None and len(vals) != n_expected:
        sys.exit(f"ERROR: {path}: got {len(vals)} entries, expected {n_expected}")
    return vals


# ---------- conv1 RTL-equivalent compute ----------

# Conv1 layer params (LeNet-5):
#   input shape   : (1, 28, 28)
#   output shape  : (6, 28, 28)
#   kernel        : 5x5, padding 2, stride 1
#   IC_KK = 1*5*5 = 25; weight layout: w[oc*25 + ky*5 + kx]
#   bias layout (in biases_all.hex): conv1 occupies first 6 entries
#   rshift_per_layer.hex layout: [conv1, conv2, fc1, fc2, fc3]
#   Output layout (matches conv_engine.v o_addr_full):
#       out_addr = oc * 28 * 28 + y * 28 + x

IN_H, IN_W = 28, 28
OUT_CH = 6
KERNEL = 5
PADDING = 2

def conv1_at(image, weights, biases, c_out, y, x, rshift):
    """Compute one conv1 output pixel bit-exact vs RTL."""
    acc = biases[c_out]
    for ky in range(KERNEL):
        for kx in range(KERNEL):
            py = y + ky - PADDING
            px = x + kx - PADDING
            if 0 <= py < IN_H and 0 <= px < IN_W:
                v = image[py * IN_W + px]
            else:
                v = 0
            w = weights[c_out * 25 + ky * KERNEL + kx]
            acc += v * w
    if acc <= 0:
        return 0
    shifted = acc >> rshift   # Python's >> on positive acc == arith shift
    return 127 if shifted > 127 else shifted


def compute_golden(image, weights, biases, rshift):
    out = [0] * (OUT_CH * IN_H * IN_W)
    for c in range(OUT_CH):
        for y in range(IN_H):
            for x in range(IN_W):
                out[c * IN_H * IN_W + y * IN_W + x] = \
                    conv1_at(image, weights, biases, c, y, x, rshift)
    return out


def write_hex_bytes(out_path, vals):
    with open(out_path, 'w') as f:
        for v in vals:
            f.write(f"{v & 0xff:02x}\n")


# ---------- CLI ----------

def main():
    p = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--src-dir', required=True,
                   help='Source dir containing weights_conv1.hex, '
                        'biases_all.hex, rshift_per_layer.hex')
    p.add_argument('--image', required=True,
                   help='Path to a single 784-byte image hex file '
                        '(signed INT8 per line)')
    p.add_argument('--out', required=True,
                   help='Output hex file (4704 1-byte entries, layout '
                        'oc*784 + y*28 + x)')
    p.add_argument('--verify-against', default=None,
                   help='Optional reference hex file to verify against '
                        '(e.g., conv1_out_img1_ref.hex). Reports diff count.')
    args = p.parse_args()

    src = Path(args.src_dir)

    print(f"gen_conv1_golden_v3")
    print(f"  src dir : {src}")
    print(f"  image   : {args.image}")
    print(f"  out     : {args.out}")
    print()

    weights = read_hex_bytes(src / "weights_conv1.hex", 150, signed=True)
    biases  = read_hex_words(src / "biases_all.hex",
                             width_bits=32)[:6]  # first 6 = conv1
    rshift_tbl = read_hex_words(src / "rshift_per_layer.hex",
                                width_bits=8, n_expected=5)
    rshift = rshift_tbl[0]                       # conv1

    image = read_hex_bytes(args.image, 784, signed=True)

    print(f"  weights range : [{min(weights)}, {max(weights)}]")
    print(f"  bias conv1    : {biases}")
    print(f"  rshift conv1  : {rshift}")
    print()

    golden = compute_golden(image, weights, biases, rshift)
    write_hex_bytes(args.out, golden)

    print(f"  wrote {len(golden)} entries")
    print(f"  output range  : [{min(golden)}, {max(golden)}]")
    print(f"  non-zero count: {sum(1 for v in golden if v != 0)} / {len(golden)}")

    if args.verify_against:
        ref = read_hex_bytes(args.verify_against, 4704, signed=False)
        diffs = [(i, golden[i], ref[i]) for i in range(4704)
                 if golden[i] != ref[i]]
        print()
        print(f"=== Verify vs {args.verify_against} ===")
        if not diffs:
            print(f"  PASS: 4704 / 4704 exact match")
        else:
            print(f"  FAIL: {len(diffs)} differences")
            for (i, g, r) in diffs[:5]:
                c = i // 784
                y = (i % 784) // 28
                x = i % 28
                print(f"    [c={c} y={y} x={x}] got={g} ref={r}")


if __name__ == "__main__":
    main()
