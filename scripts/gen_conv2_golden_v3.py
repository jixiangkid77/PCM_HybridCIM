#!/usr/bin/env python3
"""
gen_conv2_golden_v3.py

RTL-equivalent conv2 layer golden generator for Paper 2 v3.

Pipeline:
    image (28x28 INT8 signed)
        -> conv1 (5x5, padding=2, 1->6 ch, rshift, ReLU, sat[0,127])
        -> pool1 (maxpool 2x2 stride 2, 6 ch unchanged)
        -> conv2 (5x5, padding=0, 6->16 ch, rshift, ReLU, sat[0,127])

Per-stage details match RTL conv_engine / pool_wrapper exactly:
    - Conv MAC in INT32: acc = bias + sum(v[i] * w[i])
    - acc <= 0  -> output 0 (ReLU before shift)
    - else      -> min(127, acc >>> rshift)   # arithmetic right shift, truncate
    - Pool: 2x2 maxpool stride 2 over INT8 unsigned values from conv1 output

Weight layout per RTL conv_engine:
    w_addr = oc * IC_KK + ic * K2 + ky * KERNEL + kx
    For conv1: IC_KK = 1*25 = 25, K2 = 25
    For conv2: IC_KK = 6*25 = 150, K2 = 25

Bias offset in biases_all.hex (5-layer concat):
    conv1 = 0..5   (6)
    conv2 = 6..21  (16)
    fc1   = 22..141 (120)
    fc2   = 142..225 (84)
    fc3   = 226..235 (10)

Rshift layout in rshift_per_layer.hex (5 entries):
    [conv1, conv2, fc1, fc2, fc3]

Output:
    16 * 10 * 10 = 1600 INT8 unsigned values [0, 127]
    addr layout = oc * 100 + y * 10 + x

CLI:
    python gen_conv2_golden_v3.py \\
        --src-dir data/rtl_inputs_A \\
        --image data/rtl_inputs_A/images/img_001.hex \\
        --out data/golden/golden_conv2_A_img1.hex
"""

import argparse
import os
import sys


def read_hex_bytes(path, signed=True):
    """Read 1 byte per hex line; return list of int (signed=True -> [-128,127])."""
    vals = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            v = int(line, 16)
            if signed and v >= 128:
                v -= 256
            vals.append(v)
    return vals


def read_hex_words(path, width_bits=32):
    """Read 1 word (width_bits) per hex line; signed."""
    vals = []
    sign_bit = 1 << (width_bits - 1)
    full = 1 << width_bits
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            v = int(line, 16)
            if v >= sign_bit:
                v -= full
            vals.append(v)
    return vals


# ------------------------------------------------------------------
# Conv1 (matches gen_conv1_golden_v3.py byte-for-byte)
# ------------------------------------------------------------------
def conv1_full(image, weights, biases, rshift):
    """
    Return list of 4704 INT8 unsigned values (layout c*784 + y*28 + x).
    """
    IN_H, IN_W, IN_CH = 28, 28, 1
    OUT_H, OUT_W, OUT_CH = 28, 28, 6
    KERNEL = 5
    PADDING = 2
    K2 = KERNEL * KERNEL

    out = [0] * (OUT_CH * OUT_H * OUT_W)
    for oc in range(OUT_CH):
        for y in range(OUT_H):
            for x in range(OUT_W):
                acc = biases[oc]
                for ky in range(KERNEL):
                    for kx in range(KERNEL):
                        py = y + ky - PADDING
                        px = x + kx - PADDING
                        if 0 <= py < IN_H and 0 <= px < IN_W:
                            v = image[py * IN_W + px]
                        else:
                            v = 0
                        # IC=0 only for conv1
                        w = weights[oc * K2 + ky * KERNEL + kx]
                        acc += v * w
                if acc <= 0:
                    val = 0
                else:
                    shifted = acc >> rshift
                    val = 127 if shifted > 127 else shifted
                out[oc * OUT_H * OUT_W + y * OUT_W + x] = val
    return out


# ------------------------------------------------------------------
# Pool1: maxpool 2x2 stride 2 over INT8 unsigned
# ------------------------------------------------------------------
def pool1(conv1_out):
    """
    Input layout: c * 784 + y * 28 + x (6 x 28 x 28).
    Output layout: c * 196 + y * 14 + x (6 x 14 x 14).
    """
    IN_H, IN_W, CH = 28, 28, 6
    OUT_H, OUT_W = 14, 14
    out = [0] * (CH * OUT_H * OUT_W)
    for c in range(CH):
        for y in range(OUT_H):
            for x in range(OUT_W):
                py0, px0 = y * 2, x * 2
                m = max(
                    conv1_out[c * IN_H * IN_W + (py0 + dy) * IN_W + (px0 + dx)]
                    for dy in (0, 1) for dx in (0, 1)
                )
                out[c * OUT_H * OUT_W + y * OUT_W + x] = m
    return out


# ------------------------------------------------------------------
# Conv2: 6-channel input, 16-channel output, K=5, P=0
# ------------------------------------------------------------------
def conv2_full(pool1_out, weights, biases, rshift):
    """
    Input layout: c * 196 + y * 14 + x (6 x 14 x 14, INT8 unsigned [0,127]).
    Output layout: oc * 100 + y * 10 + x (16 x 10 x 10).
    """
    IN_H, IN_W, IN_CH = 14, 14, 6
    OUT_H, OUT_W, OUT_CH = 10, 10, 16
    KERNEL = 5
    PADDING = 0
    K2 = KERNEL * KERNEL
    IC_KK = IN_CH * K2  # 150

    out = [0] * (OUT_CH * OUT_H * OUT_W)
    for oc in range(OUT_CH):
        for y in range(OUT_H):
            for x in range(OUT_W):
                # Conv2 bias is at biases_all[6 + oc] (caller passes already-sliced bias)
                acc = biases[oc]
                for ic in range(IN_CH):
                    for ky in range(KERNEL):
                        for kx in range(KERNEL):
                            py = y + ky - PADDING
                            px = x + kx - PADDING
                            # PADDING=0 + valid OUT_H=10 ensures always in-bounds
                            v = pool1_out[ic * IN_H * IN_W + py * IN_W + px]
                            w = weights[oc * IC_KK + ic * K2 + ky * KERNEL + kx]
                            acc += v * w
                if acc <= 0:
                    val = 0
                else:
                    shifted = acc >> rshift
                    val = 127 if shifted > 127 else shifted
                out[oc * OUT_H * OUT_W + y * OUT_W + x] = val
    return out


# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--src-dir", required=True,
                        help="Directory with weights_conv1.hex, weights_conv2.hex, "
                             "biases_all.hex, rshift_per_layer.hex")
    parser.add_argument("--image", required=True,
                        help="Image hex file (28*28 = 784 signed INT8 entries)")
    parser.add_argument("--out", required=True,
                        help="Output golden conv2 hex (1600 INT8 unsigned entries)")
    parser.add_argument("--verify-against", default=None,
                        help="(Optional) compare result against existing hex file")
    args = parser.parse_args()

    print(f"gen_conv2_golden_v3")
    print(f"  src dir : {args.src_dir}")
    print(f"  image   : {args.image}")
    print(f"  out     : {args.out}")

    # Load all weights and config
    weights_c1 = read_hex_bytes(os.path.join(args.src_dir, "weights_conv1.hex"))
    weights_c2 = read_hex_bytes(os.path.join(args.src_dir, "weights_conv2.hex"))
    biases_all = read_hex_words(os.path.join(args.src_dir, "biases_all.hex"))
    rshift_all = read_hex_words(os.path.join(args.src_dir, "rshift_per_layer.hex"),
                                width_bits=8)
    image = read_hex_bytes(args.image, signed=True)

    if len(weights_c1) != 150:
        print(f"ERROR: weights_conv1.hex has {len(weights_c1)} entries, expected 150")
        sys.exit(1)
    if len(weights_c2) != 2400:
        print(f"ERROR: weights_conv2.hex has {len(weights_c2)} entries, expected 2400")
        sys.exit(1)
    if len(biases_all) < 22:
        print(f"ERROR: biases_all.hex has {len(biases_all)} entries, expected >=22")
        sys.exit(1)
    if len(rshift_all) < 2:
        print(f"ERROR: rshift_per_layer.hex has {len(rshift_all)} entries, expected >=2")
        sys.exit(1)
    if len(image) != 784:
        print(f"ERROR: image has {len(image)} entries, expected 784")
        sys.exit(1)

    rshift_c1 = rshift_all[0]
    rshift_c2 = rshift_all[1]
    biases_c1 = biases_all[0:6]
    biases_c2 = biases_all[6:22]

    print(f"  rshift conv1  : {rshift_c1}")
    print(f"  rshift conv2  : {rshift_c2}")
    print(f"  conv1 weight range : [{min(weights_c1)}, {max(weights_c1)}]")
    print(f"  conv2 weight range : [{min(weights_c2)}, {max(weights_c2)}]")
    print(f"  bias conv1    : {biases_c1}")
    print(f"  bias conv2    : {biases_c2}")
    print()

    # Stage 1: conv1
    print("  computing conv1 ...")
    c1 = conv1_full(image, weights_c1, biases_c1, rshift_c1)
    nz_c1 = sum(1 for v in c1 if v != 0)
    print(f"    conv1 output : 4704 entries, range [{min(c1)}, {max(c1)}], "
          f"non-zero {nz_c1}")

    # Stage 2: pool1
    print("  computing pool1 ...")
    p1 = pool1(c1)
    nz_p1 = sum(1 for v in p1 if v != 0)
    print(f"    pool1 output : 1176 entries, range [{min(p1)}, {max(p1)}], "
          f"non-zero {nz_p1}")

    # Stage 3: conv2
    print("  computing conv2 ...")
    c2 = conv2_full(p1, weights_c2, biases_c2, rshift_c2)
    nz_c2 = sum(1 for v in c2 if v != 0)
    print(f"    conv2 output : 1600 entries, range [{min(c2)}, {max(c2)}], "
          f"non-zero {nz_c2}")

    # Write output
    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w") as f:
        for v in c2:
            f.write(f"{v:02x}\n")
    print(f"  wrote {len(c2)} entries to {args.out}")

    # Optional verify
    if args.verify_against:
        print()
        print(f"=== Verify vs {args.verify_against} ===")
        ref = read_hex_bytes(args.verify_against, signed=False)
        if len(ref) != len(c2):
            print(f"  FAIL: ref has {len(ref)} entries, we have {len(c2)}")
            sys.exit(2)
        diffs = sum(1 for a, b in zip(c2, ref) if a != b)
        if diffs == 0:
            print(f"  PASS: {len(c2)} / {len(c2)} exact match")
        else:
            print(f"  FAIL: {diffs} / {len(c2)} mismatches")
            sys.exit(2)


if __name__ == "__main__":
    main()
