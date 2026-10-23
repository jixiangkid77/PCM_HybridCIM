"""
03_split_protected_v3.py
============================================================
Paper 2 v3 — Memory-Pool / Layer-Config Architecture

Splits quantized INT8 weights into POOLED partitions (one
unified SRAM array, one unified PCM array) and emits the
runtime layer-configuration regfile contents.

This replaces v2's per-layer SRAM/PCM arrays with a pool +
layer_config + addr_to_slot ROM design, which is the physical
realization required by Prof. Namba's "通用化" feedback (4/30
email): the RTL body becomes Model-agnostic and per-layer
parameters are loaded at runtime from layer_config.hex.

============================================================
OUTPUT LAYOUT (Model A example, default v2 ratios)
============================================================
  sram_pool.hex          3074 lines  (INT8, conv1+conv2+fc1+fc2+fc3)
  pcm_pool.hex          58396 lines  (INT8, layer-concatenated)
  nu_pcm_pool.hex       58396 lines  (uint8 Q0.8, per-cell drift coef)
  layer_config.hex         10 lines  (32-bit, {size[15:0], base[15:0]})
  addr_to_slot_<L>_<side>_lane<KK>.hex
                              (250 files, lane-sliced compact tables)
                              <L>    in {conv1, conv2, fc1, fc2, fc3}
                              <side> in {sram, pcm}
                              <KK>   in {00, 01, ..., 24}
  split_summary_v3.json    (metadata for downstream debug)

============================================================
SLOT FORMAT
============================================================
  All addr_to_slot files are 16-bit wide (4 hex chars per line),
  regardless of how many slots the layer actually has.
  INVALID sentinel = 0xFFFF (means: this orig_addr is NOT in
  this partition).

  Stored value: layer-RELATIVE local slot. Runtime:
      pool_addr = layer_config.base + local_slot
  See v3 設計仕様書 §10 step 2 for rationale.

============================================================
LAYER_CONFIG.HEX LAYOUT (regfile address 0x00..0x09)
============================================================
  Line 0  (addr 0x00): SRAM conv1  {size, base}
  Line 1  (addr 0x01): SRAM conv2
  Line 2  (addr 0x02): SRAM fc1
  Line 3  (addr 0x03): SRAM fc2
  Line 4  (addr 0x04): SRAM fc3
  Line 5  (addr 0x05): PCM  conv1   (size=0 for typical configs)
  Line 6  (addr 0x06): PCM  conv2
  Line 7  (addr 0x07): PCM  fc1
  Line 8  (addr 0x08): PCM  fc2
  Line 9  (addr 0x09): PCM  fc3

  Each word is 32-bit:  {size[15:0], base[15:0]}.
  base is the offset within sram_pool / pcm_pool where this
  layer's slice begins; size is the number of slots in that
  slice (== n_sram or n_pcm for that layer).

============================================================
USAGE
============================================================
  python 03_split_protected_v3.py --model A
  python 03_split_protected_v3.py --model B \
      --input-hex-dir ./data/rtl_inputs_B \
      --output-dir   ./data/rtl_inputs_B_v3

  --ratios-json: optional explicit path to LayerAware_Ratios.json.
      If absent, falls back to <input-hex-dir>/split_summary.json
      (which v2's 03_split_protected.py wrote). This lets the
      script run end-to-end on existing v2 data without needing
      access to D:/Project/PCM_Research5/outputs/.
"""

import argparse
import json
import numpy as np
from pathlib import Path

LAYERS = ['conv1', 'conv2', 'fc1', 'fc2', 'fc3']
LAYER_COUNTS = {'conv1': 150, 'conv2': 2400, 'fc1': 48000,
                'fc2': 10080, 'fc3': 840}
INVALID = 0xFFFF
SLOT_HEX_W = 4   # 16-bit -> 4 hex chars
CFG_HEX_W = 8    # 32-bit -> 8 hex chars


# ============================================================
# IO helpers
# ============================================================

def hex_to_int8(path):
    """Read a flat hex file (one byte per line), return signed INT8 array."""
    vals = []
    with open(path) as f:
        for line in f:
            s = line.split('//')[0].strip()
            if not s:
                continue
            x = int(s, 16)
            if x >= 128:
                x -= 256
            vals.append(x)
    return np.array(vals, dtype=np.int32)


def hex_to_uint8(path):
    """Read a flat hex file, return unsigned uint8 array (for nu)."""
    vals = []
    with open(path) as f:
        for line in f:
            s = line.split('//')[0].strip()
            if not s:
                continue
            vals.append(int(s, 16))
    return np.array(vals, dtype=np.int32)


def write_int8(arr, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w') as f:
        for v in arr:
            f.write(f"{int(v) & 0xFF:02x}\n")


def write_uint8(arr, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w') as f:
        for v in arr:
            f.write(f"{int(v) & 0xFF:02x}\n")


def write_slot16(arr, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w') as f:
        for v in arr:
            f.write(f"{int(v) & 0xFFFF:0{SLOT_HEX_W}x}\n")


def write_cfg32(words, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w') as f:
        for w in words:
            f.write(f"{int(w) & 0xFFFFFFFF:0{CFG_HEX_W}x}\n")


# ============================================================
# Layer split
# ============================================================

def split_layer(weights, ratio):
    """
    Top-K |w| selection within a layer (Paper 1 III-D rule).
    Tie-break by lower index (np.argsort with kind='stable').
    Returns sorted ascending sram_idx and pcm_idx.
    """
    n = len(weights)
    k_sram = int(round(n * ratio))
    if k_sram == 0:
        return np.array([], dtype=np.int32), np.arange(n, dtype=np.int32)
    if k_sram == n:
        return np.arange(n, dtype=np.int32), np.array([], dtype=np.int32)
    order = np.argsort(-np.abs(weights), kind='stable')
    return np.sort(order[:k_sram]), np.sort(order[k_sram:])


# ============================================================
# Ratios resolution
# ============================================================

def load_ratios(args, in_dir):
    """
    Resolution order:
      1. --ratios-json path if it exists
      2. <in_dir>/split_summary.json (v2 product)
    """
    if args.ratios_json:
        p = Path(args.ratios_json)
        if p.exists():
            with open(p) as f:
                r = json.load(f)
            ratios = {k.replace('.weight', ''): float(v) for k, v in r.items()}
            print(f"  ratios from: {p}")
            return ratios

    fallback = in_dir / 'split_summary.json'
    if fallback.exists():
        with open(fallback) as f:
            s = json.load(f)
        ratios = {L: float(s['layers'][L]['ratio']) for L in LAYERS}
        print(f"  ratios from: {fallback} (v2 fallback)")
        return ratios

    raise FileNotFoundError(
        f"No ratios source found. Provide --ratios-json, "
        f"or ensure {fallback} exists from a prior v2 run.")


# ============================================================
# Main
# ============================================================

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', choices=['A', 'B'], required=True)
    ap.add_argument('--ratios-json', default=None,
                    help='Path to LayerAware_Ratios[_B].json. Optional.')
    ap.add_argument('--input-hex-dir', default=None,
                    help='Source dir containing v2 weights_<L>.hex and '
                         'nu_<L>_pcm.hex. Default: ./data/rtl_inputs_<model>')
    ap.add_argument('--output-dir', default=None,
                    help='v3 output dir. Default: ./data/rtl_inputs_<model>_v3')
    args = ap.parse_args()

    in_dir = Path(args.input_hex_dir) if args.input_hex_dir \
             else Path(f'./data/rtl_inputs_{args.model}')
    out_dir = Path(args.output_dir) if args.output_dir \
              else Path(f'./data/rtl_inputs_{args.model}_v3')

    print("=" * 60)
    print(f"03_split_protected_v3.py  Model {args.model}")
    print(f"  input : {in_dir}")
    print(f"  output: {out_dir}")
    print("=" * 60)

    ratios = load_ratios(args, in_dir)
    print("Layer-aware ratios: " +
          ", ".join(f"{L}={ratios[L]:.4f}" for L in LAYERS))
    print()

    # ---- Step A: split each layer ----
    layer_data = {}
    for L in LAYERS:
        w = hex_to_int8(in_dir / f'weights_{L}.hex')
        if len(w) != LAYER_COUNTS[L]:
            raise ValueError(f"{L}: got {len(w)} weights, "
                             f"expected {LAYER_COUNTS[L]}")
        sram_idx, pcm_idx = split_layer(w, ratios[L])
        layer_data[L] = {
            'n_total': len(w),
            'sram_idx': sram_idx,
            'pcm_idx':  pcm_idx,
            'sram_w':   w[sram_idx],
            'pcm_w':    w[pcm_idx],
        }
        print(f"  {L:6s}  total={len(w):>5d}  "
              f"sram={len(sram_idx):>5d} ({100*len(sram_idx)/len(w):5.2f}%)  "
              f"pcm={len(pcm_idx):>5d}")

    # ---- Step B: build pools (concatenate in canonical layer order) ----
    sram_pool = np.concatenate([layer_data[L]['sram_w'] for L in LAYERS])
    pcm_pool = np.concatenate([layer_data[L]['pcm_w'] for L in LAYERS])

    sram_bases, pcm_bases = {}, {}
    s_off, p_off = 0, 0
    for L in LAYERS:
        sram_bases[L] = s_off
        pcm_bases[L] = p_off
        s_off += len(layer_data[L]['sram_idx'])
        p_off += len(layer_data[L]['pcm_idx'])
    sram_total = s_off
    pcm_total = p_off

    print()
    print(f"  sram_pool total = {sram_total}")
    print(f"  pcm_pool  total = {pcm_total}")
    print(f"  grand total     = {sram_total + pcm_total} "
          f"(expect {sum(LAYER_COUNTS.values())})")
    assert sram_total + pcm_total == sum(LAYER_COUNTS.values()), \
        "pool totals do not match expected weight count"

    # ---- Step C: build per-layer addr_to_slot (layer-relative, 16-bit) ----
    addr_to_slot = {}
    for L in LAYERS:
        n = layer_data[L]['n_total']
        s_tab = np.full(n, INVALID, dtype=np.uint32)
        p_tab = np.full(n, INVALID, dtype=np.uint32)
        for slot_i, orig in enumerate(layer_data[L]['sram_idx']):
            s_tab[orig] = slot_i
        for slot_i, orig in enumerate(layer_data[L]['pcm_idx']):
            p_tab[orig] = slot_i
        # Sanity: every orig addr is in exactly one partition
        cnt_s = int(np.sum(s_tab != INVALID))
        cnt_p = int(np.sum(p_tab != INVALID))
        if cnt_s + cnt_p != n:
            raise AssertionError(
                f"{L}: {cnt_s} (sram) + {cnt_p} (pcm) != {n} (total)")
        # Sanity: max slot fits in 16-bit minus the sentinel
        if cnt_s > 0 and s_tab[s_tab != INVALID].max() >= INVALID:
            raise AssertionError(f"{L} sram slot collides with INVALID")
        if cnt_p > 0 and p_tab[p_tab != INVALID].max() >= INVALID:
            raise AssertionError(f"{L} pcm slot collides with INVALID")
        addr_to_slot[L] = {'sram': s_tab, 'pcm': p_tab}

    # ---- Step D: assemble nu_pcm_pool from v2 per-layer files ----
    nu_chunks = []
    for L in LAYERS:
        n_pcm_layer = len(layer_data[L]['pcm_idx'])
        if n_pcm_layer == 0:
            continue
        nu_path = in_dir / f'nu_{L}_pcm.hex'
        if not nu_path.exists():
            raise FileNotFoundError(
                f"Missing {nu_path}; run 04_generate_pcm_nu.py first.")
        nu_arr = hex_to_uint8(nu_path)
        if len(nu_arr) != n_pcm_layer:
            raise ValueError(f"{nu_path}: expected {n_pcm_layer} entries, "
                             f"got {len(nu_arr)}")
        nu_chunks.append(nu_arr)
    nu_pool = (np.concatenate(nu_chunks) if nu_chunks
               else np.array([], dtype=np.int32))
    if len(nu_pool) != pcm_total:
        raise AssertionError(
            f"nu_pool length {len(nu_pool)} != pcm_pool length {pcm_total}")

    # ---- Step E: write all output files ----
    out_dir.mkdir(parents=True, exist_ok=True)
    write_int8(sram_pool, out_dir / 'sram_pool.hex')
    write_int8(pcm_pool, out_dir / 'pcm_pool.hex')
    write_uint8(nu_pool, out_dir / 'nu_pcm_pool.hex')

    # layer_config.hex (10 lines)
    cfg_words = []
    for L in LAYERS:    # SRAM block, addresses 0x00..0x04
        size = len(layer_data[L]['sram_idx'])
        base = sram_bases[L]
        cfg_words.append((size << 16) | (base & 0xFFFF))
    for L in LAYERS:    # PCM block, addresses 0x05..0x09
        size = len(layer_data[L]['pcm_idx'])
        base = pcm_bases[L]
        cfg_words.append((size << 16) | (base & 0xFFFF))
    write_cfg32(cfg_words, out_dir / 'layer_config.hex')

    # addr_to_slot lane-sliced files (250 total: 5 layers x 2 sides x 25 lanes)
    # Lane-sliced refactor (2026-05-12): each lane stores only its 1/25
    # share of the addr_to_slot table, reducing total RTL address-ROM
    # capacity from 49.2 Mbit to ~1.99 Mbit (25x reduction) without
    # changing functional behaviour. See sram_addr_decoder.v header
    # for the lane-mapping convention.
    KK = 25
    LAYER_PARAMS = {
        'conv1': ('conv',   1,   6),
        'conv2': ('conv',   6,  16),
        'fc1':   ('fc',   400, 120),
        'fc2':   ('fc',   120,  84),
        'fc3':   ('fc',    84,  10),
    }
    import math as _math

    def lane_compact_tables(L, full_tab):
        """Convert a full layer-wide addr_to_slot table to 25 lane-sliced
        compact tables. Returns list of 25 numpy arrays."""
        ltype, a, b = LAYER_PARAMS[L]
        if ltype == 'conv':
            IC, OC = a, b
            plc = OC * IC
        else:
            IN_DIM = a
            sb_groups = _math.ceil(IN_DIM / KK)
            plc = b * sb_groups
        # Per-lane arrays initialized to INVALID
        lane_tabs = [np.full(plc, INVALID, dtype=np.uint32) for _ in range(KK)]
        n = LAYER_COUNTS[L]
        for orig in range(n):
            if ltype == 'conv':
                k = orig % KK
                rem = orig // KK
                oc = rem // IC
                ic = rem % IC
                cidx = oc * IC + ic
            else:
                oc = orig // IN_DIM
                flat = orig % IN_DIM
                k = flat % KK
                sb = flat // KK
                cidx = oc * sb_groups + sb
            if 0 <= cidx < plc:
                lane_tabs[k][cidx] = full_tab[orig]
        return lane_tabs

    for L in LAYERS:
        for side in ('sram', 'pcm'):
            tabs = lane_compact_tables(L, addr_to_slot[L][side])
            for k in range(KK):
                out_path = out_dir / f'addr_to_slot_{L}_{side}_lane{k:02d}.hex'
                write_slot16(tabs[k], out_path)

    # ---- Step F: summary ----
    summary = {
        'model': args.model,
        'sram_total': int(sram_total),
        'pcm_total':  int(pcm_total),
        'slot_format': 'layer_relative',
        'invalid_sentinel': f"{INVALID:04x}",
        'pool_layout': ('sram and pcm pools concatenated in canonical '
                        'layer order: conv1, conv2, fc1, fc2, fc3'),
        'layer_config_layout': {
            'word_format': '{size[15:0], base[15:0]}',
            'lines_0_to_4': 'SRAM partition base/size for '
                            'conv1, conv2, fc1, fc2, fc3',
            'lines_5_to_9': 'PCM partition base/size for '
                            'conv1, conv2, fc1, fc2, fc3',
        },
        'overall_protection_pct': 100.0 * sram_total /
                                  (sram_total + pcm_total),
        'layers': {},
    }
    for L in LAYERS:
        summary['layers'][L] = {
            'n_total':   layer_data[L]['n_total'],
            'n_sram':    int(len(layer_data[L]['sram_idx'])),
            'n_pcm':     int(len(layer_data[L]['pcm_idx'])),
            'sram_base': int(sram_bases[L]),
            'pcm_base':  int(pcm_bases[L]),
            'ratio':     float(ratios[L]),
        }
    with open(out_dir / 'split_summary_v3.json', 'w') as f:
        json.dump(summary, f, indent=2)

    print()
    print("=" * 60)
    print("Outputs written:")
    print(f"  {out_dir/'sram_pool.hex'}        ({sram_total} lines)")
    print(f"  {out_dir/'pcm_pool.hex'}         ({pcm_total} lines)")
    print(f"  {out_dir/'nu_pcm_pool.hex'}      ({len(nu_pool)} lines)")
    print(f"  {out_dir/'layer_config.hex'}     (10 lines)")
    print(f"  addr_to_slot_<L>_<side>_lane<KK>.hex   (250 files, lane-sliced)")
    print(f"  {out_dir/'split_summary_v3.json'}")
    print("=" * 60)
    print(f"Overall protection: {summary['overall_protection_pct']:.4f}%")
    print("Done.")


if __name__ == '__main__':
    main()
