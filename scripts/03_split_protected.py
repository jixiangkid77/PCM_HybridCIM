"""
03_split_protected.py
============================================================
Paper 2 v2 - SRAM/PCM Hybrid Architecture

Splits quantized INT8 weights into two physical partitions:
  - weights_<layer>_sram.hex  : protected weights (top-K |w|, drift-immune)
  - weights_<layer>_pcm.hex   : unprotected weights (will be drift-injected at runtime)

Each weight goes to EXACTLY one partition (no duplication).

Layer-aware ratios from Paper 1: LayerAware_Ratios.json (Model A)
                                  LayerAware_Ratios_B.json (Model B)

Usage:
    python 03_split_protected.py --model A
    python 03_split_protected.py --model B

Output (per layer L in {conv1,conv2,fc1,fc2,fc3}):
    data/rtl_inputs_<A|B>/weights_L_sram.hex     (signed INT8 hex, K_sram lines)
    data/rtl_inputs_<A|B>/weights_L_pcm.hex      (signed INT8 hex, K_pcm lines)
    data/rtl_inputs_<A|B>/idx_L_sram.hex         (original linear addr -> SRAM slot)
    data/rtl_inputs_<A|B>/idx_L_pcm.hex          (original linear addr -> PCM slot)
    data/rtl_inputs_<A|B>/split_summary.json     (counts, ratios)
"""

import argparse
import json
import numpy as np
from pathlib import Path

LAYERS = ['conv1', 'conv2', 'fc1', 'fc2', 'fc3']
LAYER_COUNTS = {'conv1': 150, 'conv2': 2400, 'fc1': 48000, 'fc2': 10080, 'fc3': 840}


def parse_args():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', choices=['A', 'B'], required=True)
    ap.add_argument('--paper1-dir', default='D:/Project/PCM_Research5',
                    help='Paper1 outputs directory')
    ap.add_argument('--input-hex-dir', default=None,
                    help='Existing weights_*.hex source dir; default = ./data/rtl_inputs_<model>')
    ap.add_argument('--output-dir', default=None,
                    help='Output dir; default = ./data/rtl_inputs_<model>')
    return ap.parse_args()


def hex_to_int8_array(hex_path):
    """Read a flat hex file (one INT8 per line, 2 hex chars), return signed int8 array."""
    vals = []
    with open(hex_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            # remove comments
            if '//' in line:
                line = line.split('//')[0].strip()
            if not line:
                continue
            x = int(line, 16)
            if x >= 128:
                x -= 256
            vals.append(x)
    return np.array(vals, dtype=np.int32)


def write_int8_hex(arr, path):
    """Write signed INT8 array as 2-hex-char per line."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w') as f:
        for v in arr:
            unsigned = int(v) & 0xFF
            f.write(f"{unsigned:02x}\n")


def write_idx_hex(idx_arr, path, addr_width_bits):
    """Write address indices as hex (zero-padded to fit the layer's max addr)."""
    hex_chars = (addr_width_bits + 3) // 4
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w') as f:
        for v in idx_arr:
            f.write(f"{v:0{hex_chars}x}\n")


def build_addr_to_slot_table(presence_idx, n_total, slot_width_bits):
    """
    Build a forward lookup table: original_addr -> slot_in_partition_or_INVALID.

    presence_idx: sorted array of original addresses present in this partition
    n_total: total number of original weights in the layer
    slot_width_bits: bit width chosen so INVALID = (1 << slot_width_bits) - 1
                     can represent "this addr is NOT in this partition"

    Returns: numpy uint32 array of length n_total
             arr[orig_addr] = slot_index   if addr is in partition
                            = INVALID      otherwise
    """
    INVALID = (1 << slot_width_bits) - 1
    table = np.full(n_total, INVALID, dtype=np.uint32)
    for slot_i, orig_addr in enumerate(presence_idx):
        table[orig_addr] = slot_i
    return table


def write_addr_to_slot_hex(table, path, slot_width_bits):
    """Write addr->slot lookup table as hex (one row per original addr)."""
    hex_chars = (slot_width_bits + 3) // 4
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w') as f:
        for v in table:
            f.write(f"{int(v):0{hex_chars}x}\n")


def split_layer(weights_int8, ratio, layer_name):
    """
    Given a flat INT8 weight array and protection ratio, split into:
      - sram_weights:  top-K_sram |w| go to SRAM (preserved)
      - pcm_weights:   the rest go to PCM (will drift)
      - sram_idx:      original linear addresses of SRAM weights
      - pcm_idx:       original linear addresses of PCM weights

    Selection criterion: largest absolute values are most critical (Paper 1 III-D).
    Tie-breaking: lower original index wins (deterministic).
    """
    n = len(weights_int8)
    k_sram = int(round(n * ratio))
    k_pcm = n - k_sram

    if k_sram == 0:
        # All in PCM
        sram_idx = np.array([], dtype=np.int32)
        pcm_idx = np.arange(n, dtype=np.int32)
    elif k_sram == n:
        # All in SRAM
        sram_idx = np.arange(n, dtype=np.int32)
        pcm_idx = np.array([], dtype=np.int32)
    else:
        # Top-K by |w|
        abs_w = np.abs(weights_int8)
        # argsort descending; stable=true to break ties by index
        order = np.argsort(-abs_w, kind='stable')
        sram_idx = np.sort(order[:k_sram])
        pcm_idx = np.sort(order[k_sram:])

    sram_weights = weights_int8[sram_idx]
    pcm_weights = weights_int8[pcm_idx]

    print(f"  {layer_name}: total={n}, sram={k_sram} ({100*k_sram/n:.2f}%), pcm={k_pcm}")

    return {
        'n_total': n,
        'n_sram': int(k_sram),
        'n_pcm': int(k_pcm),
        'ratio': float(ratio),
        'sram_weights': sram_weights,
        'pcm_weights': pcm_weights,
        'sram_idx': sram_idx,
        'pcm_idx': pcm_idx,
    }


def main():
    args = parse_args()

    paper1_dir = Path(args.paper1_dir)
    if args.model == 'A':
        ratios_file = paper1_dir / 'outputs' / 'LayerAware_Ratios.json'
    else:
        ratios_file = paper1_dir / 'outputs' / 'LayerAware_Ratios_B.json'

    out_dir = Path(args.output_dir) if args.output_dir else Path(f'./data/rtl_inputs_{args.model}')
    src_hex_dir = Path(args.input_hex_dir) if args.input_hex_dir else Path(f'./data/rtl_inputs_{args.model}')

    print("=" * 60)
    print(f"03_split_protected.py  Model {args.model}")
    print(f"  Source ratios: {ratios_file}")
    print(f"  Source hex:    {src_hex_dir}")
    print(f"  Output dir:    {out_dir}")
    print("=" * 60)

    # Load layer-aware ratios
    with open(ratios_file, 'r') as f:
        ratios = json.load(f)
    # keys are 'conv1.weight' style; strip suffix
    ratios = {k.replace('.weight', ''): v for k, v in ratios.items()}

    summary = {
        'model': args.model,
        'ratios_source': str(ratios_file),
        'layers': {},
    }

    total_n = 0
    total_sram = 0

    for layer in LAYERS:
        ratio = ratios[layer]
        n_expected = LAYER_COUNTS[layer]

        src_hex = src_hex_dir / f'weights_{layer}.hex'
        if not src_hex.exists():
            print(f"[ERROR] Missing input file: {src_hex}")
            print(f"        Run 02_quantize_and_export.py first.")
            return

        weights = hex_to_int8_array(src_hex)
        if len(weights) != n_expected:
            print(f"[WARN] {layer}: got {len(weights)} weights, expected {n_expected}")

        result = split_layer(weights, ratio, layer)

        # Determine address width (bits to encode original linear addr)
        addr_width = max(1, int(np.ceil(np.log2(result['n_total']))))

        # Slot width: enough to encode the largest partition + 1 INVALID code.
        # Use the same width as addr_width so INVALID = (1 << addr_width) - 1
        # which is reserved (= n_total or larger, never collides with real slots
        # because real slots are < max(n_sram, n_pcm) <= n_total).
        slot_width = addr_width

        # Build forward lookup tables (orig_addr -> slot or INVALID)
        sram_table = build_addr_to_slot_table(
            result['sram_idx'], result['n_total'], slot_width)
        pcm_table = build_addr_to_slot_table(
            result['pcm_idx'], result['n_total'], slot_width)

        # Write hex files
        write_int8_hex(result['sram_weights'], out_dir / f'weights_{layer}_sram.hex')
        write_int8_hex(result['pcm_weights'], out_dir / f'weights_{layer}_pcm.hex')
        write_idx_hex(result['sram_idx'], out_dir / f'idx_{layer}_sram.hex', addr_width)
        write_idx_hex(result['pcm_idx'], out_dir / f'idx_{layer}_pcm.hex', addr_width)
        write_addr_to_slot_hex(sram_table,
                               out_dir / f'addr_to_slot_{layer}_sram.hex', slot_width)
        write_addr_to_slot_hex(pcm_table,
                               out_dir / f'addr_to_slot_{layer}_pcm.hex', slot_width)

        summary['layers'][layer] = {
            'n_total': result['n_total'],
            'n_sram': result['n_sram'],
            'n_pcm': result['n_pcm'],
            'ratio': result['ratio'],
            'addr_width_bits': addr_width,
            'slot_width_bits': slot_width,
            'invalid_code_hex': f"{(1 << slot_width) - 1:0{(slot_width+3)//4}x}",
        }

        total_n += result['n_total']
        total_sram += result['n_sram']

    summary['total_weights'] = total_n
    summary['total_sram'] = total_sram
    summary['overall_protection_pct'] = 100.0 * total_sram / total_n

    # Write summary
    with open(out_dir / 'split_summary.json', 'w') as f:
        json.dump(summary, f, indent=2)

    print("=" * 60)
    print(f"Total weights:       {total_n}")
    print(f"Total in SRAM:       {total_sram} ({100*total_sram/total_n:.2f}%)")
    print(f"Total in PCM:        {total_n - total_sram}")
    print(f"Summary written:     {out_dir / 'split_summary.json'}")
    print("=" * 60)
    print("Done.")


if __name__ == '__main__':
    main()
