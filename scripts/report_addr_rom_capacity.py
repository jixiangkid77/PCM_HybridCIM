#!/usr/bin/env python3
"""
report_addr_rom_capacity.py

Reports the address-mapping ROM capacity for the lane-sliced implementation,
using actual hex file row counts as the ground-truth measurement source.

Reads:
  data/rtl_inputs_<MODEL>_v3/addr_to_slot_<layer>_<side>_lane<KK>.hex
  (250 files per model: 5 layers x 2 sides x 25 lanes)

Writes:
  reports/addr_rom_capacity_report.txt    (and prints to stdout)

The report compares naive full-table per-lane ROM (~49.18 Mbit) against the
implemented lane-sliced ROM (~1.99 Mbit), verifying that:
  (1) all 25 lanes in a given (layer, side) have identical hex row count
      (lane-sliced ROM uses uniform-shape Option-B padding);
  (2) SRAM and PCM sides produce identical per-lane depth per layer
      (since both share the same per-layer protection-map shape).

If either invariant fails, the script raises and stops -- that would indicate
a bug in 03_split_protected_v3.py's lane_compact_tables() output.
"""

import argparse
import sys
from pathlib import Path

# Fixed by LeNet-5 architecture (unchanged by lane-sliced refactor)
LAYER_WEIGHT_COUNTS = {
    'conv1':   150,
    'conv2':  2400,
    'fc1':   48000,
    'fc2':   10080,
    'fc3':     840,
}
LAYERS = ['conv1', 'conv2', 'fc1', 'fc2', 'fc3']
SIDES  = ['sram', 'pcm']

# Fixed by RTL (rtl/src/sram_addr_decoder.v, pcm_addr_decoder.v):
N_LANES = 25      # SIMD lane count
N_SIDES = 2       # sram-side decoder + pcm-side decoder
WADDR_W = 16      # bit-width of one addr-to-slot entry in ROM


def count_lines(path):
    """Return non-empty line count of a hex file."""
    with open(path) as f:
        return sum(1 for line in f if line.strip())


def gather_lane_depths(data_dir):
    """For each (layer, side), return the list of per-lane row counts."""
    depths = {}
    for layer in LAYERS:
        for side in SIDES:
            row_counts = []
            for lane_id in range(N_LANES):
                p = data_dir / f"addr_to_slot_{layer}_{side}_lane{lane_id:02d}.hex"
                if not p.exists():
                    raise FileNotFoundError(f"Missing required hex file: {p}")
                row_counts.append(count_lines(p))
            depths[(layer, side)] = row_counts
    return depths


def verify_uniform(depths):
    """Verify lane-sliced ROM invariants:
    (1) all 25 lanes in (layer, side) have identical row count
    (2) sram side == pcm side per layer
    Returns dict {layer: uniform_per_lane_depth}.
    """
    side_depths = {}
    for (layer, side), counts in depths.items():
        unique = set(counts)
        if len(unique) != 1:
            raise ValueError(
                f"[INVARIANT 1 VIOLATED] Lane-depth NOT uniform for "
                f"{layer}_{side}: distribution = {sorted(unique)}\n"
                f"  Lane-sliced ROM expects all 25 lanes to share the same "
                f"row count (Option-B padding to layer's max-lane depth)."
            )
        side_depths[(layer, side)] = counts[0]

    per_layer = {}
    for layer in LAYERS:
        d_sram = side_depths[(layer, 'sram')]
        d_pcm  = side_depths[(layer, 'pcm')]
        if d_sram != d_pcm:
            raise ValueError(
                f"[INVARIANT 2 VIOLATED] SRAM/PCM lane depth differ for "
                f"{layer}: sram={d_sram}, pcm={d_pcm}\n"
                f"  Both sides share the same per-layer protection-map shape."
            )
        per_layer[layer] = d_sram
    return per_layer


def build_report(model, data_dir):
    depths = gather_lane_depths(data_dir)
    per_layer = verify_uniform(depths)

    per_lane_total = sum(per_layer.values())

    naive_per_decoder_entries = sum(LAYER_WEIGHT_COUNTS.values())     # 61,470
    naive_per_decoder_bits    = naive_per_decoder_entries * WADDR_W
    n_decoders                = N_LANES * N_SIDES                     # 50
    naive_total_bits          = naive_per_decoder_bits * n_decoders

    impl_per_decoder_entries  = per_lane_total                        # 2,482
    impl_per_decoder_bits     = impl_per_decoder_entries * WADDR_W
    impl_total_entries        = impl_per_decoder_entries * n_decoders # 124,100
    impl_total_bits           = impl_per_decoder_bits * n_decoders

    reduction = naive_total_bits / impl_total_bits

    lines = []
    P = lines.append
    P("============================================================")
    P(f"Address-ROM Capacity Report   (Model {model})")
    P("============================================================")
    P(f"Source dir       : {data_dir}")
    P(f"Method           : derived from actual hex file row counts")
    P(f"Bit-width / entry: {WADDR_W} bit  (RTL param WADDR_W)")
    P(f"Lane count       : {N_LANES}      (RTL SIMD width)")
    P(f"Sides per lane   : {N_SIDES}       (SRAM-side decoder + PCM-side decoder)")
    P("")
    P("Lane-sliced invariants verified:")
    P(f"  [PASS] All 25 lanes have identical row count per (layer, side)")
    P(f"  [PASS] SRAM and PCM sides share identical per-lane depth per layer")
    P("")
    P("Per-layer per-lane compact depth (verified ground-truth):")
    P(f"  {'Layer':<8} {'Total weights':>14} {'Per-lane depth':>16}")
    P(f"  {'-'*8} {'-'*14} {'-'*16}")
    for layer in LAYERS:
        P(f"  {layer:<8} {LAYER_WEIGHT_COUNTS[layer]:>14} "
          f"{per_layer[layer]:>16}")
    P(f"  {'-'*8} {'-'*14} {'-'*16}")
    P(f"  {'Total':<8} {sum(LAYER_WEIGHT_COUNTS.values()):>14} "
      f"{per_lane_total:>16}")
    P("")
    P("------------------------------------------------------------")
    P("Baseline: naive full-table per-lane ROM (pre-refactor)")
    P("  Each lane stores the COMPLETE 5-layer addr_to_slot table.")
    P(f"  Entries per decoder    : {naive_per_decoder_entries:>10}  "
      f"(= sum of all model weights)")
    P(f"  Bits per decoder       : {naive_per_decoder_bits:>10}  "
      f"({naive_per_decoder_bits/1e6:.3f} Mbit)")
    P(f"  Number of decoders     : {n_decoders:>10}  "
      f"({N_LANES} lanes x {N_SIDES} sides)")
    P(f"  TOTAL                  : {naive_total_bits:>10} bit")
    P(f"                         = {naive_total_bits/1e6:.3f} Mbit")
    P("")
    P("------------------------------------------------------------")
    P("Implemented: lane-sliced ROM (this work)")
    P("  Each lane stores only its share, padded uniformly per layer.")
    P(f"  Entries per decoder    : {impl_per_decoder_entries:>10}  "
      f"(= sum of per-lane depths)")
    P(f"  Bits per decoder       : {impl_per_decoder_bits:>10}  "
      f"({impl_per_decoder_bits/1e3:.2f} Kbit)")
    P(f"  Number of decoders     : {n_decoders:>10}  "
      f"({N_LANES} lanes x {N_SIDES} sides)")
    P(f"  TOTAL entries verified : {impl_total_entries:>10}  "
      f"(matches sum of hex rows)")
    P(f"  TOTAL                  : {impl_total_bits:>10} bit")
    P(f"                         = {impl_total_bits/1e6:.4f} Mbit")
    P("")
    P("------------------------------------------------------------")
    P(f"Reduction factor         : {reduction:.2f}x")
    P(f"  ({naive_total_bits/1e6:.3f} Mbit -> "
      f"{impl_total_bits/1e6:.4f} Mbit)")
    P("============================================================")
    P("")
    P("Paper-ready statement (English):")
    P("  The implemented lane-sliced address-mapping ROM stores")
    P(f"  {impl_total_bits:,} bits ({impl_total_bits/1e6:.3f} Mbit) in total")
    P(f"  ({impl_per_decoder_bits/1e3:.2f} Kbit per decoder x {n_decoders} decoders),")
    P(f"  a {reduction:.2f}x reduction from the naive per-lane full-table")
    P(f"  baseline of {naive_total_bits/1e6:.3f} Mbit.")
    P("============================================================")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--data-root', default='data',
                    help='Root containing rtl_inputs_<MODEL>_v3/ (default: data)')
    ap.add_argument('--models', nargs='+', default=['A', 'B'],
                    help='Models to report (default: A B)')
    ap.add_argument('--output', default='reports/addr_rom_capacity_report.txt',
                    help='Output report path (default: reports/addr_rom_capacity_report.txt)')
    args = ap.parse_args()

    data_root = Path(args.data_root)
    out_path  = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    all_text = []
    for model in args.models:
        data_dir = data_root / f"rtl_inputs_{model}_v3"
        if not data_dir.is_dir():
            print(f"ERROR: directory not found: {data_dir}", file=sys.stderr)
            sys.exit(2)
        report = build_report(model, data_dir)
        print(report)
        print()
        all_text.append(report)

    with open(out_path, 'w') as f:
        f.write("\n\n".join(all_text))
        f.write("\n")
    print(f"Report written to: {out_path}")


if __name__ == '__main__':
    main()
