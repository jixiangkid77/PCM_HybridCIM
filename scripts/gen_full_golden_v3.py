#!/usr/bin/env python3
"""
gen_full_golden_v3.py

Generates RTL-equivalent goldens for the FULL LeNet-5 v3 inference
pipeline:

  image (28x28 INT8)
    → conv1  (5x5, P=2, 1→6 ch,  rshift, ReLU+sat[0,127])
    → pool1  (max 2x2/2,  6 ch unchanged)
    → conv2  (5x5, P=0, 6→16 ch, rshift, ReLU+sat[0,127])
    → pool2  (max 2x2/2, 16 ch unchanged)
    → fc1    (400→120,  ReLU+sat[0,127])
    → fc2    (120→84,   ReLU+sat[0,127])
    → fc3    (84→10,    NO ReLU, INT16 signed saturation [-32768, +32767]
              with RTL-specific asymmetric negative threshold at -131071)
    → argmax (signed strict-greater, ties → lowest index)

Outputs (one hex file per stage):
    golden_conv1_<M>_img1.hex   (4704 INT8 unsigned entries)
    golden_pool1_<M>_img1.hex   (1176 INT8 unsigned entries)
    golden_conv2_<M>_img1.hex   (1600 INT8 unsigned entries)
    golden_pool2_<M>_img1.hex   ( 400 INT8 unsigned entries)
    golden_fc1_<M>_img1.hex     ( 120 INT8 unsigned entries)
    golden_fc2_<M>_img1.hex     (  84 INT8 unsigned entries)
    golden_fc3_<M>_img1.hex     (  10 INT16 signed entries, 4 hex chars each)
    golden_pred_<M>_img1.txt    (single digit 0..9)

Critical RTL-equivalence details:
    * Conv MAC in INT32; bias added to acc BEFORE shift.
    * Arithmetic right shift (sign-preserving), truncate (no rounding).
    * Conv/fc1/fc2 ReLU: if acc <= 0, output 0 (BEFORE shift); else
      min(127, acc >> rshift). Sign check is on acc, NOT on shifted.
    * fc3 saturation (USE_RELU=0): exactly mirrors RTL line 287-292.
      Asymmetric: positive threshold +32767, negative threshold -131071.
      In normal LeNet range, shifted values are in [-32768, +32767] and
      the asymmetry never triggers, but we still report saturation /
      truncation-wrap diagnostics for paper auditability.
    * Weight layout (PyTorch Linear-style):
        conv layer: w_addr = oc * (IC*K*K) + ic * (K*K) + ky * K + kx
        fc   layer: w_addr = oc * IN_DIM + ic_flat
    * Bias offsets in biases_all.hex (cumulative 5 layers):
        conv1=0..5, conv2=6..21, fc1=22..141, fc2=142..225, fc3=226..235
    * rshift table layout in rshift_per_layer.hex (5 entries):
        [conv1, conv2, fc1, fc2, fc3]
    * pool2 → fc1 flatten order matches feature_buffer address order:
        flat_idx = c * 25 + y * 5 + x   (16 channels × 5 × 5 = 400)
"""

import argparse
import os
import sys


def read_hex_bytes(path, signed=True):
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


# ============================================================
# Convolutional layer (generic; conv1 and conv2 use same kernel)
# ============================================================
def conv_layer(in_buf, in_h, in_w, in_ch,
               weights, biases, rshift,
               out_h, out_w, out_ch, kernel, padding):
    """
    Generic RTL-equivalent conv layer.
    in_buf layout: ic * (in_h * in_w) + y * in_w + x
    out layout:    oc * (out_h * out_w) + y * out_w + x
    Returns list of INT8 unsigned values.
    """
    k2 = kernel * kernel
    ic_kk = in_ch * k2
    out = [0] * (out_ch * out_h * out_w)
    for oc in range(out_ch):
        for y in range(out_h):
            for x in range(out_w):
                acc = biases[oc]
                for ic in range(in_ch):
                    for ky in range(kernel):
                        for kx in range(kernel):
                            py = y + ky - padding
                            px = x + kx - padding
                            if 0 <= py < in_h and 0 <= px < in_w:
                                v = in_buf[ic * in_h * in_w + py * in_w + px]
                            else:
                                v = 0
                            w = weights[oc * ic_kk + ic * k2 + ky * kernel + kx]
                            acc += v * w
                if acc <= 0:
                    val = 0
                else:
                    shifted = acc >> rshift
                    val = 127 if shifted > 127 else shifted
                out[oc * out_h * out_w + y * out_w + x] = val
    return out


# ============================================================
# Pool layer (max 2x2 stride 2, generic)
# ============================================================
def pool_layer(in_buf, in_h, in_w, channels):
    """
    Max pool 2x2 stride 2. In/out layout: c * H * W + y * W + x.
    Signed compare in RTL but values are >= 0 from preceding ReLU,
    so equivalent to unsigned max().
    """
    out_h, out_w = in_h // 2, in_w // 2
    out = [0] * (channels * out_h * out_w)
    for c in range(channels):
        for y in range(out_h):
            for x in range(out_w):
                py0, px0 = y * 2, x * 2
                m = max(
                    in_buf[c * in_h * in_w + (py0 + dy) * in_w + (px0 + dx)]
                    for dy in (0, 1) for dx in (0, 1)
                )
                out[c * out_h * out_w + y * out_w + x] = m
    return out


# ============================================================
# FC layer (fc1/fc2: ReLU + INT8 unsigned; fc3: NO ReLU + INT16 signed)
# ============================================================
def fc_layer_relu(in_vec, weights, biases, rshift):
    """
    fc1/fc2 RTL equivalent: ReLU + INT8 unsigned [0, 127] saturate.
    Same rule as conv (acc<=0 → 0; else min(127, acc>>rshift)).
    """
    in_dim = len(in_vec)
    out_dim = len(biases)
    out = [0] * out_dim
    for oc in range(out_dim):
        acc = biases[oc]
        for ic in range(in_dim):
            acc += in_vec[ic] * weights[oc * in_dim + ic]
        if acc <= 0:
            val = 0
        else:
            shifted = acc >> rshift
            val = 127 if shifted > 127 else shifted
        out[oc] = val
    return out


def fc3_saturate(shifted, diag):
    """
    Exact mirror of fc_engine.v lines 287-292 (USE_RELU=0 branch).
    Returns 16-bit signed int. Mutates `diag` dict for stats.
    """
    POS_THRESH = 32767       # +(2^15 - 1)
    NEG_THRESH = -131071     # RTL's actual asymmetric negative threshold
    if shifted > POS_THRESH:
        diag['pos_sat'] += 1
        return 32767
    elif shifted < NEG_THRESH:
        diag['neg_sat'] += 1
        return -32768
    else:
        # RTL truncates 32-bit signed acc_in to 16-bit signed acc_out
        truncated = shifted & 0xFFFF
        if truncated & 0x8000:
            truncated -= 0x10000
        if shifted < -32768 or shifted > 32767:
            # Theoretically reachable region: [-131071, -32768] →
            # wraparound instead of saturate. Flag for audit.
            diag['truncation_wrap'] += 1
        return truncated


def fc_layer_fc3(in_vec, weights, biases, rshift):
    """
    fc3 RTL equivalent: no ReLU, 16-bit signed saturation/truncation.
    Returns (out[10], diagnostics).
    """
    in_dim = len(in_vec)
    out_dim = len(biases)
    diag = {'pos_sat': 0, 'neg_sat': 0, 'truncation_wrap': 0,
            'shifted_min': float('inf'), 'shifted_max': float('-inf')}
    out = [0] * out_dim
    for oc in range(out_dim):
        acc = biases[oc]
        for ic in range(in_dim):
            acc += in_vec[ic] * weights[oc * in_dim + ic]
        shifted = acc >> rshift   # Python arithmetic right shift on signed int
        if shifted < diag['shifted_min']: diag['shifted_min'] = shifted
        if shifted > diag['shifted_max']: diag['shifted_max'] = shifted
        out[oc] = fc3_saturate(shifted, diag)
    return out, diag


# ============================================================
# Argmax (matches RTL argmax10.v: signed strict->, ties → lowest)
# ============================================================
def argmax10_strict(logits):
    """argmax10.v cascade with strict '>' so ties keep lowest index."""
    best_idx = 0
    best_val = logits[0]
    for i in range(1, len(logits)):
        if logits[i] > best_val:
            best_val = logits[i]
            best_idx = i
    return best_idx


# ============================================================
# Hex output helpers
# ============================================================
def write_hex_bytes(path, vals, width_chars=2):
    with open(path, "w") as f:
        for v in vals:
            if v < 0:
                v = v & ((1 << (width_chars * 4)) - 1)
            f.write(f"{v:0{width_chars}x}\n")


# ============================================================
# Main
# ============================================================
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--src-dir", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--model-tag", required=True, help="A or B")
    parser.add_argument("--verify-against-dir", default=None,
                        help="If provided, compare conv1/conv2 against existing goldens in this dir")
    args = parser.parse_args()

    print(f"gen_full_golden_v3   (model {args.model_tag})")
    print(f"  src dir : {args.src_dir}")
    print(f"  image   : {args.image}")
    print(f"  out dir : {args.out_dir}")
    print()

    # ---- Load all RTL data ----
    weights_c1 = read_hex_bytes(os.path.join(args.src_dir, "weights_conv1.hex"))
    weights_c2 = read_hex_bytes(os.path.join(args.src_dir, "weights_conv2.hex"))
    weights_f1 = read_hex_bytes(os.path.join(args.src_dir, "weights_fc1.hex"))
    weights_f2 = read_hex_bytes(os.path.join(args.src_dir, "weights_fc2.hex"))
    weights_f3 = read_hex_bytes(os.path.join(args.src_dir, "weights_fc3.hex"))
    biases_all = read_hex_words(os.path.join(args.src_dir, "biases_all.hex"))
    rshift_all = read_hex_words(os.path.join(args.src_dir, "rshift_per_layer.hex"),
                                width_bits=8)
    image = read_hex_bytes(args.image, signed=True)

    # Slice biases by layer (cumulative offsets)
    b_c1 = biases_all[0:6]
    b_c2 = biases_all[6:22]
    b_f1 = biases_all[22:142]
    b_f2 = biases_all[142:226]
    b_f3 = biases_all[226:236]

    rs_c1, rs_c2, rs_f1, rs_f2, rs_f3 = rshift_all[0:5]

    # Size sanity
    assert len(weights_c1) == 150,   f"weights_conv1 = {len(weights_c1)}"
    assert len(weights_c2) == 2400,  f"weights_conv2 = {len(weights_c2)}"
    assert len(weights_f1) == 48000, f"weights_fc1   = {len(weights_f1)}"
    assert len(weights_f2) == 10080, f"weights_fc2   = {len(weights_f2)}"
    assert len(weights_f3) == 840,   f"weights_fc3   = {len(weights_f3)}"
    assert len(b_c1) == 6 and len(b_c2) == 16
    assert len(b_f1) == 120 and len(b_f2) == 84 and len(b_f3) == 10
    assert len(image) == 784

    print(f"  rshift       : conv1={rs_c1} conv2={rs_c2} fc1={rs_f1} fc2={rs_f2} fc3={rs_f3}")
    print()

    os.makedirs(args.out_dir, exist_ok=True)

    # ---- Stage 1: conv1 ----
    print("  [stage 1/8] conv1 (1->6, 28x28, K=5, P=2) ...")
    c1 = conv_layer(image, 28, 28, 1, weights_c1, b_c1, rs_c1,
                    28, 28, 6, 5, 2)
    print(f"    output : 4704 entries, range [{min(c1)}, {max(c1)}], "
          f"non-zero {sum(1 for v in c1 if v != 0)}")

    # ---- Stage 2: pool1 ----
    print("  [stage 2/8] pool1 (max 2x2/2, 6 ch) ...")
    p1 = pool_layer(c1, 28, 28, 6)
    print(f"    output : 1176 entries, range [{min(p1)}, {max(p1)}], "
          f"non-zero {sum(1 for v in p1 if v != 0)}")

    # ---- Stage 3: conv2 ----
    print("  [stage 3/8] conv2 (6->16, 14x14→10x10, K=5, P=0) ...")
    c2 = conv_layer(p1, 14, 14, 6, weights_c2, b_c2, rs_c2,
                    10, 10, 16, 5, 0)
    print(f"    output : 1600 entries, range [{min(c2)}, {max(c2)}], "
          f"non-zero {sum(1 for v in c2 if v != 0)}")

    # ---- Stage 4: pool2 ----
    print("  [stage 4/8] pool2 (max 2x2/2, 16 ch) ...")
    p2 = pool_layer(c2, 10, 10, 16)
    print(f"    output : 400 entries, range [{min(p2)}, {max(p2)}], "
          f"non-zero {sum(1 for v in p2 if v != 0)}")

    # ---- Stage 5: fc1 ----
    # Flatten order matches feature_buffer layout: c*25 + y*5 + x
    # That's exactly the layout pool_layer already produces.
    print("  [stage 5/8] fc1 (400->120, ReLU+sat[0,127]) ...")
    f1 = fc_layer_relu(p2, weights_f1, b_f1, rs_f1)
    print(f"    output : 120 entries, range [{min(f1)}, {max(f1)}], "
          f"non-zero {sum(1 for v in f1 if v != 0)}")

    # ---- Stage 6: fc2 ----
    print("  [stage 6/8] fc2 (120->84, ReLU+sat[0,127]) ...")
    f2 = fc_layer_relu(f1, weights_f2, b_f2, rs_f2)
    print(f"    output : 84 entries, range [{min(f2)}, {max(f2)}], "
          f"non-zero {sum(1 for v in f2 if v != 0)}")

    # ---- Stage 7: fc3 (RTL-strict INT16 saturation) ----
    print("  [stage 7/8] fc3 (84->10, NO ReLU, INT16 signed sat) ...")
    f3, diag = fc_layer_fc3(f2, weights_f3, b_f3, rs_f3)
    print(f"    output : 10 logits = {f3}")
    print(f"    shifted range          : [{diag['shifted_min']}, {diag['shifted_max']}]")
    print(f"    positive saturation    : {diag['pos_sat']}/10 (>32767)")
    print(f"    negative saturation    : {diag['neg_sat']}/10 (<-131071)")
    print(f"    truncation-wrap region : {diag['truncation_wrap']}/10 (shifted ∈ [-131071,-32768])")
    if diag['truncation_wrap'] > 0:
        print("    *** WARNING: fc3 truncation-wraparound triggered. Predicted_class may differ from pure-sat reference. ***")

    # ---- Stage 8: argmax ----
    print("  [stage 8/8] argmax (signed strict-greater) ...")
    pred = argmax10_strict(f3)
    print(f"    predicted_class = {pred}")
    print()

    # ---- Write all goldens ----
    tag = args.model_tag
    out = args.out_dir
    write_hex_bytes(os.path.join(out, f"golden_conv1_{tag}_img1.hex"), c1, 2)
    write_hex_bytes(os.path.join(out, f"golden_pool1_{tag}_img1.hex"), p1, 2)
    write_hex_bytes(os.path.join(out, f"golden_conv2_{tag}_img1.hex"), c2, 2)
    write_hex_bytes(os.path.join(out, f"golden_pool2_{tag}_img1.hex"), p2, 2)
    write_hex_bytes(os.path.join(out, f"golden_fc1_{tag}_img1.hex"),   f1, 2)
    write_hex_bytes(os.path.join(out, f"golden_fc2_{tag}_img1.hex"),   f2, 2)
    write_hex_bytes(os.path.join(out, f"golden_fc3_{tag}_img1.hex"),   f3, 4)  # INT16 → 4 hex chars
    with open(os.path.join(out, f"golden_pred_{tag}_img1.txt"), "w") as f:
        f.write(f"{pred}\n")

    print(f"  wrote 7 golden hex files + predicted_class to {out}")

    # ---- Optional regression vs existing conv1/conv2 goldens ----
    if args.verify_against_dir:
        print()
        print(f"=== Regression vs existing goldens in {args.verify_against_dir} ===")
        for stage_name, gen_vals in [("conv1", c1), ("conv2", c2)]:
            ref_path = os.path.join(args.verify_against_dir,
                                    f"golden_{stage_name}_{tag}_img1.hex")
            if not os.path.exists(ref_path):
                print(f"  {stage_name}: ref file not found, skipping")
                continue
            ref = read_hex_bytes(ref_path, signed=False)
            if len(ref) != len(gen_vals):
                print(f"  {stage_name}: size mismatch ref={len(ref)} gen={len(gen_vals)} FAIL")
                sys.exit(2)
            diffs = sum(1 for a, b in zip(gen_vals, ref) if a != b)
            if diffs == 0:
                print(f"  {stage_name}: PASS  {len(gen_vals)}/{len(gen_vals)} match")
            else:
                print(f"  {stage_name}: FAIL  {diffs}/{len(gen_vals)} mismatches")
                sys.exit(2)


if __name__ == "__main__":
    main()
