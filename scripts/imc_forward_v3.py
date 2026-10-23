#!/usr/bin/env python3
"""
imc_forward_v3.py  --  STEP 2a (plumbing only)

Fork of gen_full_golden_v3.py. Splits each layer's weights into a
PROTECTED path (SRAM, exact digital MAC) and an UNPROTECTED path
(PCM-IMC, routed through pcm_mac()). At STEP 2a, pcm_mac() is an
EXACT passthrough, so the combined accumulator equals the original
full MAC and the output MUST stay bit-exact vs the RTL golden.

This file is the vehicle for later steps (cellBit slicing, per-cell
drift, 5-bit ADC, read noise). Those will only change pcm_mac() and
add per-weight drift coefficients; the layer plumbing stays fixed.

v3 split is taken from rtl_inputs_A_v3:
  addr_to_slot_<layer>_sram.hex / _pcm.hex  (16-bit, FFFF = not here)
  sram_pool.hex / pcm_pool.hex / nu_pcm_pool.hex (layer-concatenated)
  split_summary_v3.json (per-layer sram_base / pcm_base)

Forward weight VALUES come from the raw per-layer weight files in
--src-dir (the exact arrays that produced the golden). The v3 pools
are used only to (a) derive the protected mask and (b) validate that
pool+addr reconstruction == raw weights.
"""

import argparse
import json
import os
import sys

FFFF = 0xFFFF

# layer canonical order and raw weight counts
LAYERS = ["conv1", "conv2", "fc1", "fc2", "fc3"]
WCOUNT = {"conv1": 150, "conv2": 2400, "fc1": 48000, "fc2": 10080, "fc3": 840}


# ------------------------------------------------------------------
# Hex readers (identical semantics to gen_full_golden_v3.py)
# ------------------------------------------------------------------
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


def read_hex_u(path):
    """Unsigned hex ints (for addr_to_slot slot indices and nu codes)."""
    vals = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            vals.append(int(line, 16))
    return vals


def write_hex_bytes(path, vals, width_chars=2):
    with open(path, "w") as f:
        for v in vals:
            if v < 0:
                v = v & ((1 << (width_chars * 4)) - 1)
            f.write(f"{v:0{width_chars}x}\n")


# ------------------------------------------------------------------
# PCM-IMC partial-sum (STEP 2a: exact passthrough)
# ------------------------------------------------------------------
def pcm_mac(pairs, layer):
    """
    pairs : list of (v, w, nu) for one output neuron's UNPROTECTED
            (PCM) fan-in. v = INT8 activation, w = INT8 weight,
            nu = drift code (unused at step 2a).
    Returns the integer PCM partial sum.

    STEP 2a: exact analog model == ideal digital sum. No cellBit
    slicing, no drift, no ADC, no noise. Later steps replace this
    body with: per-cell drift G(t), 64-row subArray tiling, 5-bit
    MLSA ADC quantization, and read noise.
    """
    s = 0
    for v, w, nu in pairs:
        s += v * w
    return s


# ------------------------------------------------------------------
# Conv layer (hybrid SRAM exact + PCM via pcm_mac)
# ------------------------------------------------------------------
def conv_layer(in_buf, in_h, in_w, in_ch,
               weights, biases, rshift, mask,
               out_h, out_w, out_ch, kernel, padding, nu_by_addr):
    k2 = kernel * kernel
    ic_kk = in_ch * k2
    out = [0] * (out_ch * out_h * out_w)
    for oc in range(out_ch):
        for y in range(out_h):
            for x in range(out_w):
                acc_sram = 0
                pcm_pairs = []
                for ic in range(in_ch):
                    for ky in range(kernel):
                        for kx in range(kernel):
                            py = y + ky - padding
                            px = x + kx - padding
                            if 0 <= py < in_h and 0 <= px < in_w:
                                v = in_buf[ic * in_h * in_w + py * in_w + px]
                            else:
                                v = 0
                            w_addr = oc * ic_kk + ic * k2 + ky * kernel + kx
                            w = weights[w_addr]
                            if mask[w_addr]:            # protected -> SRAM exact
                                acc_sram += v * w
                            else:                       # unprotected -> PCM
                                pcm_pairs.append((v, w, nu_by_addr[w_addr]))
                acc = biases[oc] + acc_sram + pcm_mac(pcm_pairs, "conv")
                if acc <= 0:
                    val = 0
                else:
                    shifted = acc >> rshift
                    val = 127 if shifted > 127 else shifted
                out[oc * out_h * out_w + y * out_w + x] = val
    return out


# ------------------------------------------------------------------
# Pool layer (identical to golden gen)
# ------------------------------------------------------------------
def pool_layer(in_buf, in_h, in_w, channels):
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


# ------------------------------------------------------------------
# FC layers (hybrid)
# ------------------------------------------------------------------
def fc_layer_relu(in_vec, weights, biases, rshift, mask, nu_by_addr):
    in_dim = len(in_vec)
    out_dim = len(biases)
    out = [0] * out_dim
    for oc in range(out_dim):
        acc_sram = 0
        pcm_pairs = []
        base = oc * in_dim
        for ic in range(in_dim):
            w_addr = base + ic
            w = weights[w_addr]
            v = in_vec[ic]
            if mask[w_addr]:
                acc_sram += v * w
            else:
                pcm_pairs.append((v, w, nu_by_addr[w_addr]))
        acc = biases[oc] + acc_sram + pcm_mac(pcm_pairs, "fc")
        if acc <= 0:
            val = 0
        else:
            shifted = acc >> rshift
            val = 127 if shifted > 127 else shifted
        out[oc] = val
    return out


def fc3_saturate(shifted, diag):
    POS_THRESH = 32767
    NEG_THRESH = -131071
    if shifted > POS_THRESH:
        diag['pos_sat'] += 1
        return 32767
    elif shifted < NEG_THRESH:
        diag['neg_sat'] += 1
        return -32768
    else:
        truncated = shifted & 0xFFFF
        if truncated & 0x8000:
            truncated -= 0x10000
        if shifted < -32768 or shifted > 32767:
            diag['truncation_wrap'] += 1
        return truncated


def fc_layer_fc3(in_vec, weights, biases, rshift, mask, nu_by_addr):
    in_dim = len(in_vec)
    out_dim = len(biases)
    diag = {'pos_sat': 0, 'neg_sat': 0, 'truncation_wrap': 0,
            'shifted_min': float('inf'), 'shifted_max': float('-inf')}
    out = [0] * out_dim
    for oc in range(out_dim):
        acc_sram = 0
        pcm_pairs = []
        base = oc * in_dim
        for ic in range(in_dim):
            w_addr = base + ic
            w = weights[w_addr]
            v = in_vec[ic]
            if mask[w_addr]:
                acc_sram += v * w
            else:
                pcm_pairs.append((v, w, nu_by_addr[w_addr]))
        acc = biases[oc] + acc_sram + pcm_mac(pcm_pairs, "fc3")
        shifted = acc >> rshift
        if shifted < diag['shifted_min']: diag['shifted_min'] = shifted
        if shifted > diag['shifted_max']: diag['shifted_max'] = shifted
        out[oc] = fc3_saturate(shifted, diag)
    return out, diag


def argmax10_strict(logits):
    best_idx = 0
    best_val = logits[0]
    for i in range(1, len(logits)):
        if logits[i] > best_val:
            best_val = logits[i]
            best_idx = i
    return best_idx


# ------------------------------------------------------------------
# v3 split loading + validation
# ------------------------------------------------------------------
def load_v3_split(v3_dir, raw_weights):
    """
    Returns:
      mask[layer]        : list[bool], True = protected (SRAM)
      nu_by_addr[layer]  : list[int],  drift code per w_addr (0 if protected)
    Validates pool+addr reconstruction == raw weights for every weight.
    """
    with open(os.path.join(v3_dir, "split_summary_v3.json")) as f:
        summ = json.load(f)
    sram_pool = read_hex_bytes(os.path.join(v3_dir, "sram_pool.hex"))
    pcm_pool = read_hex_bytes(os.path.join(v3_dir, "pcm_pool.hex"))
    nu_pool = read_hex_u(os.path.join(v3_dir, "nu_pcm_pool.hex"))
    assert len(sram_pool) == summ["sram_total"], "sram_pool size"
    assert len(pcm_pool) == summ["pcm_total"], "pcm_pool size"
    assert len(nu_pool) == summ["pcm_total"], "nu_pool size"

    mask = {}
    nu_by_addr = {}
    total_sram = 0
    total_pcm = 0
    mismatches = 0
    for L in LAYERS:
        n = WCOUNT[L]
        a_sram = read_hex_u(os.path.join(v3_dir, f"addr_to_slot_{L}_sram.hex"))
        a_pcm = read_hex_u(os.path.join(v3_dir, f"addr_to_slot_{L}_pcm.hex"))
        assert len(a_sram) == n, f"{L} sram map len {len(a_sram)} != {n}"
        assert len(a_pcm) == n, f"{L} pcm map len {len(a_pcm)} != {n}"
        sbase = summ["layers"][L]["sram_base"]
        pbase = summ["layers"][L]["pcm_base"]
        m = [False] * n
        nu = [0] * n
        ns = 0
        npc = 0
        for w_addr in range(n):
            in_sram = a_sram[w_addr] != FFFF
            in_pcm = a_pcm[w_addr] != FFFF
            # exactly one pool
            if in_sram == in_pcm:
                raise SystemExit(
                    f"{L} w_addr {w_addr}: in_sram={in_sram} in_pcm={in_pcm} "
                    "(must be exactly one)")
            if in_sram:
                val = sram_pool[sbase + a_sram[w_addr]]
                m[w_addr] = True
                ns += 1
            else:
                slot = pbase + a_pcm[w_addr]
                val = pcm_pool[slot]
                nu[w_addr] = nu_pool[slot]
                npc += 1
            if val != raw_weights[L][w_addr]:
                mismatches += 1
        assert ns == summ["layers"][L]["n_sram"], \
            f"{L} n_sram {ns} != {summ['layers'][L]['n_sram']}"
        assert npc == summ["layers"][L]["n_pcm"], \
            f"{L} n_pcm {npc} != {summ['layers'][L]['n_pcm']}"
        mask[L] = m
        nu_by_addr[L] = nu
        total_sram += ns
        total_pcm += npc

    print(f"  v3 split loaded: SRAM={total_sram} PCM={total_pcm}")
    print(f"  per-layer protected: " +
          " ".join(f"{L}={summ['layers'][L]['n_sram']}/{WCOUNT[L]}" for L in LAYERS))
    if mismatches == 0:
        print(f"  reconstruction check: PASS (pool+addr == raw weights, "
              f"all {sum(WCOUNT.values())} weights)")
    else:
        print(f"  reconstruction check: FAIL ({mismatches} mismatches)")
        sys.exit(2)
    return mask, nu_by_addr


# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src-dir", required=True, help="raw weights dir (rtl_inputs_A)")
    ap.add_argument("--v3-dir", required=True, help="v3 split dir (rtl_inputs_A_v3)")
    ap.add_argument("--image", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--model-tag", required=True)
    ap.add_argument("--verify-against-dir", default=None)
    args = ap.parse_args()

    print(f"imc_forward_v3   (model {args.model_tag})  [STEP 2a: pcm_mac passthrough]")
    print(f"  src dir : {args.src_dir}")
    print(f"  v3 dir  : {args.v3_dir}")
    print(f"  image   : {args.image}")
    print()

    raw = {
        "conv1": read_hex_bytes(os.path.join(args.src_dir, "weights_conv1.hex")),
        "conv2": read_hex_bytes(os.path.join(args.src_dir, "weights_conv2.hex")),
        "fc1": read_hex_bytes(os.path.join(args.src_dir, "weights_fc1.hex")),
        "fc2": read_hex_bytes(os.path.join(args.src_dir, "weights_fc2.hex")),
        "fc3": read_hex_bytes(os.path.join(args.src_dir, "weights_fc3.hex")),
    }
    for L in LAYERS:
        assert len(raw[L]) == WCOUNT[L], f"{L} weights {len(raw[L])} != {WCOUNT[L]}"

    biases_all = read_hex_words(os.path.join(args.src_dir, "biases_all.hex"))
    rshift_all = read_hex_words(os.path.join(args.src_dir, "rshift_per_layer.hex"),
                                width_bits=8)
    image = read_hex_bytes(args.image, signed=True)
    assert len(image) == 784, f"image len {len(image)}"

    b = {"conv1": biases_all[0:6], "conv2": biases_all[6:22],
         "fc1": biases_all[22:142], "fc2": biases_all[142:226],
         "fc3": biases_all[226:236]}
    rs = dict(zip(LAYERS, rshift_all[0:5]))
    print(f"  rshift  : " + " ".join(f"{L}={rs[L]}" for L in LAYERS))

    mask, nu_by_addr = load_v3_split(args.v3_dir, raw)
    print()

    os.makedirs(args.out_dir, exist_ok=True)

    print("  [1/8] conv1 ...")
    c1 = conv_layer(image, 28, 28, 1, raw["conv1"], b["conv1"], rs["conv1"],
                    mask["conv1"], 28, 28, 6, 5, 2, nu_by_addr["conv1"])
    print(f"        range [{min(c1)},{max(c1)}] nz {sum(1 for v in c1 if v)}")

    print("  [2/8] pool1 ...")
    p1 = pool_layer(c1, 28, 28, 6)

    print("  [3/8] conv2 ...")
    c2 = conv_layer(p1, 14, 14, 6, raw["conv2"], b["conv2"], rs["conv2"],
                    mask["conv2"], 10, 10, 16, 5, 0, nu_by_addr["conv2"])
    print(f"        range [{min(c2)},{max(c2)}] nz {sum(1 for v in c2 if v)}")

    print("  [4/8] pool2 ...")
    p2 = pool_layer(c2, 10, 10, 16)

    print("  [5/8] fc1 ...")
    f1 = fc_layer_relu(p2, raw["fc1"], b["fc1"], rs["fc1"],
                       mask["fc1"], nu_by_addr["fc1"])
    print(f"        range [{min(f1)},{max(f1)}] nz {sum(1 for v in f1 if v)}")

    print("  [6/8] fc2 ...")
    f2 = fc_layer_relu(f1, raw["fc2"], b["fc2"], rs["fc2"],
                       mask["fc2"], nu_by_addr["fc2"])
    print(f"        range [{min(f2)},{max(f2)}] nz {sum(1 for v in f2 if v)}")

    print("  [7/8] fc3 ...")
    f3, diag = fc_layer_fc3(f2, raw["fc3"], b["fc3"], rs["fc3"],
                            mask["fc3"], nu_by_addr["fc3"])
    print(f"        logits {f3}")
    print(f"        pos_sat {diag['pos_sat']} neg_sat {diag['neg_sat']} "
          f"trunc_wrap {diag['truncation_wrap']}")

    print("  [8/8] argmax ...")
    pred = argmax10_strict(f3)
    print(f"        predicted_class = {pred}")
    print()

    tag = args.model_tag
    out = args.out_dir
    write_hex_bytes(os.path.join(out, f"golden_conv1_{tag}_img1.hex"), c1, 2)
    write_hex_bytes(os.path.join(out, f"golden_pool1_{tag}_img1.hex"), p1, 2)
    write_hex_bytes(os.path.join(out, f"golden_conv2_{tag}_img1.hex"), c2, 2)
    write_hex_bytes(os.path.join(out, f"golden_pool2_{tag}_img1.hex"), p2, 2)
    write_hex_bytes(os.path.join(out, f"golden_fc1_{tag}_img1.hex"), f1, 2)
    write_hex_bytes(os.path.join(out, f"golden_fc2_{tag}_img1.hex"), f2, 2)
    write_hex_bytes(os.path.join(out, f"golden_fc3_{tag}_img1.hex"), f3, 4)
    with open(os.path.join(out, f"golden_pred_{tag}_img1.txt"), "w") as f:
        f.write(f"{pred}\n")
    print(f"  wrote 7 golden hex files + pred to {out}")

    if args.verify_against_dir:
        print()
        print(f"=== Regression vs {args.verify_against_dir} (all 7 layers, value-based) ===")
        streams = [("conv1", c1, False), ("pool1", p1, False),
                   ("conv2", c2, False), ("pool2", p2, False),
                   ("fc1", f1, False), ("fc2", f2, False), ("fc3", f3, True)]
        all_pass = True
        for name, gen, is16 in streams:
            ref_path = os.path.join(args.verify_against_dir,
                                    f"golden_{name}_{tag}_img1.hex")
            if not os.path.exists(ref_path):
                print(f"  {name}: ref missing, skip")
                continue
            ref = read_hex_words(ref_path, width_bits=16) if is16 \
                else read_hex_bytes(ref_path, signed=False)
            if len(ref) != len(gen):
                print(f"  {name}: size mismatch ref={len(ref)} gen={len(gen)} FAIL")
                all_pass = False
                continue
            diffs = sum(1 for a, c in zip(gen, ref) if a != c)
            print(f"  {name}: {'PASS' if diffs == 0 else 'FAIL'}  "
                  f"{len(gen) - diffs}/{len(gen)} match")
            if diffs:
                all_pass = False
        print("  >>> ALL 7 LAYERS BIT-EXACT" if all_pass else "  >>> MISMATCH")
        if not all_pass:
            sys.exit(2)


if __name__ == "__main__":
    main()
