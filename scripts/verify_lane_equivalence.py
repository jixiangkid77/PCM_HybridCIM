"""
verify_lane_equivalence.py
============================================================
Paper 2 v3 — Lane-sliced address decoder equivalence (LS-2)

Verifies that the lane-sliced compact-ROM design has identical
functional behaviour to a hypothetical full-table decoder, by:

  1. Re-implementing 03_split_protected_v3.py's forward formula
     (Python writer) - "which (lane, compact_idx) does this orig
     get written to?"

  2. Faithfully translating the Verilog decoder's combinational
     logic from sram_addr_decoder.v / pcm_addr_decoder.v
     (Verilog reader) - "for this (LANE_ID, orig), do we hit,
     and at what compact_idx?"

  3. Checking that for every (model, side, layer, lane, orig)
     the two are consistent:
       - if forward assigned orig to LANE_ID:
             decoder.lane_ok = True
             decoder.compact_idx = forward.compact_idx
             -> lane_sliced_lookup() == reconstructed full-table value
       - else:
             decoder.lane_ok = False
             -> lane_sliced_lookup() == INVALID

============================================================
SCOPE (what LS-2 does and does not catch)
============================================================
This is LS-2 from the audit plan. It complements:
  - verify_split_v3.py round-trip (lane_compact <-> reconstruct_full)
  - RTL synthetic-data decoder unit test (lane=7 full sweep)

WHAT THIS CATCHES — five independent axes:
  (1) lane_flag_fail : decoder.lane_ok != forward.is_match
                       i.e. the lane-assignment formula has drifted
                       between Python writer (03_split) and
                       Verilog reader (decoder.v).
  (2) compact_fail   : on matching lanes, decoder.compact_idx
                       != forward.cidx, i.e. the compact-index
                       formula has drifted.
  (3) depth_fail     : on matching lanes, decoder.depth_ok is
                       false, i.e. the depth-guard wrongly
                       rejects an in-range entry.
  (4) match_fail     : on matching lanes, the looked-up slot
                       disagrees with the reconstructed full
                       table value.
  (5) miss_fail      : on non-matching lanes, the decoder
                       returns something other than INVALID.

For example, if the Verilog decoder is changed to use a
different sb_groups multiplier for fc2 but 03_split is not
updated, this script's decoder_sim_vec (faithful Verilog
mirror) will disagree with its forward_split_vec (faithful
03_split mirror) and the sweep will report compact_fail
mismatches.

WHAT THIS DOES NOT CATCH:
  - Single-slot data corruption in lane hex files
    (covered by verify_split_v3.py end-to-end pool->weight
    reconstruction check).
  - conv_engine.v / fc_engine.v lane convention mismatch
    (whether orig_addr_bus[gi] really feeds lane gi, vs some
    permutation). This is only verifiable via manual code
    review of the engines, or via Step 9 / Step 10b end-to-end
    execution.

Run BOTH verify_split_v3.py AND verify_lane_equivalence.py
on each Model A / B build; they cover orthogonal failure
modes. Step 9 / Step 10b regression then catches the third
(engine convention) mode.

============================================================
USAGE
============================================================
    python verify_lane_equivalence.py --model A
    python verify_lane_equivalence.py --model B

Expected output on a clean build:
    Model X: PASS  (0 mismatches across 3,073,500 tuples)
"""

import argparse
import math
import numpy as np
from pathlib import Path

LAYERS = ['conv1', 'conv2', 'fc1', 'fc2', 'fc3']
LAYER_COUNTS = {'conv1': 150, 'conv2': 2400, 'fc1': 48000,
                'fc2': 10080, 'fc3': 840}
# layer: (type, IC_or_INDIM, OC_or_OUTDIM)
LAYER_PARAMS = {
    'conv1': ('conv',   1,   6),
    'conv2': ('conv',   6,  16),
    'fc1':   ('fc',   400, 120),
    'fc2':   ('fc',   120,  84),
    'fc3':   ('fc',    84,  10),
}
KK = 25
INVALID = 0xFFFF
SIDES = ['sram', 'pcm']


# ============================================================
# Per-layer compact ROM depth (== per-lane file length)
# ============================================================
def lane_depth(L):
    ltype, a, b = LAYER_PARAMS[L]
    if ltype == 'conv':
        return b * a            # OC * IC
    return b * math.ceil(a / KK)  # OUT_DIM * sb_groups


# ============================================================
# Formula A — Python writer (mirrors 03_split_protected_v3.py)
# ============================================================
def forward_split_vec(L, orig_arr):
    """Vectorised. Returns (k_fwd, cidx_fwd) per element of orig_arr."""
    ltype, a, b = LAYER_PARAMS[L]
    if ltype == 'conv':
        IC = a
        k = orig_arr % KK
        rem = orig_arr // KK
        oc = rem // IC
        ic = rem % IC
        cidx = oc * IC + ic
    else:
        IN_DIM = a
        sb_groups = math.ceil(IN_DIM / KK)
        oc = orig_arr // IN_DIM
        flat = orig_arr % IN_DIM
        k = flat % KK
        sb = flat // KK
        cidx = oc * sb_groups + sb
    return k, cidx


# ============================================================
# Formula B — Verilog decoder mirror
# (sram_addr_decoder.v / pcm_addr_decoder.v combinational logic)
# ============================================================
def decoder_sim_vec(L, orig_arr, LANE_ID):
    """Vectorised. Returns (lane_ok, compact_idx, depth_ok, in_range)
    arrays, matching exactly the Verilog combinational decode.
    """
    n = LAYER_COUNTS[L]
    in_range = orig_arr < n

    ltype, a, b = LAYER_PARAMS[L]
    depth = lane_depth(L)

    if ltype == 'conv':
        # Verilog: conv_compact = o16 / 25
        #          conv_lane_ok = (o16 % 25) == LANE_ID
        compact = orig_arr // KK
        lane_ok = (orig_arr % KK) == LANE_ID
    else:
        IN_DIM = a
        sb_groups = math.ceil(IN_DIM / KK)
        # Verilog: fc_oc = o16 / IN_DIM
        #          fc_flat = o16 - fc_oc * IN_DIM
        oc = orig_arr // IN_DIM
        flat = orig_arr - oc * IN_DIM
        # Verilog: fc_sb = (fc_flat >= LANE_ID) ? (fc_flat - LANE_ID) / 25 : 0
        sb = np.where(flat >= LANE_ID, (flat - LANE_ID) // KK, 0)
        compact = oc * sb_groups + sb
        lane_ok = (flat % KK) == LANE_ID

    depth_ok = compact < depth
    return lane_ok, compact, depth_ok, in_range


# ============================================================
# Lane file IO
# ============================================================
def read_uint(path):
    vals = []
    with open(path) as f:
        for line in f:
            s = line.split('//')[0].strip()
            if s:
                vals.append(int(s, 16))
    return np.array(vals, dtype=np.int64)


def load_lane_tabs(v3_dir):
    """lane_tabs[L][side][lane_id] -> ndarray of compact slot values."""
    lane_tabs = {}
    for L in LAYERS:
        lane_tabs[L] = {}
        for side in SIDES:
            tabs = []
            for k in range(KK):
                p = v3_dir / f'addr_to_slot_{L}_{side}_lane{k:02d}.hex'
                if not p.exists():
                    raise FileNotFoundError(str(p))
                tabs.append(read_uint(p))
            lane_tabs[L][side] = tabs
    return lane_tabs


# ============================================================
# Reconstruct full table from lane files (matches
# verify_split_v3.read_addr_to_slot_full, with the FC padding fix)
# ============================================================
def reconstruct_full(lane_tabs, L, side):
    n = LAYER_COUNTS[L]
    full = np.full(n, INVALID, dtype=np.int64)
    ltype, a, b = LAYER_PARAMS[L]
    if ltype == 'conv':
        IC = a
        for k in range(KK):
            lane = lane_tabs[L][side][k]
            for cidx in range(len(lane)):
                oc = cidx // IC
                ic = cidx % IC
                orig = oc * (IC * KK) + ic * KK + k
                if 0 <= orig < n:
                    full[orig] = lane[cidx]
    else:
        IN_DIM = a
        sb_groups = math.ceil(IN_DIM / KK)
        for k in range(KK):
            lane = lane_tabs[L][side][k]
            for cidx in range(len(lane)):
                oc = cidx // sb_groups
                sb = cidx % sb_groups
                flat_idx = sb * KK + k
                if flat_idx >= IN_DIM:
                    continue  # padding cell, no real orig here
                orig = oc * IN_DIM + flat_idx
                if 0 <= orig < n:
                    full[orig] = lane[cidx]
    return full


# ============================================================
# Per-(L, side, lane) equivalence sweep — vectorised
# ============================================================
def sweep_layer_side_lane(lane_tabs, L, side, LANE_ID, full_table):
    """Returns dict of fail counts across 5 categories, plus first
    few failure samples for debug.

    Five failure categories tested per (orig, LANE_ID):

      lane_flag_fail : decoder_sim.lane_ok != forward.is_match
                       (lane-assignment formula disagrees)
      compact_fail   : is_match AND decoder_sim.compact != forward.cidx
                       (compact-index formula disagrees on matching lane)
      depth_fail     : is_match AND NOT decoder_sim.depth_ok
                       (depth-guard wrongly rejects a valid lane)
      match_fail     : is_match AND new_slot != reconstructed_full_slot
                       (matching-lane slot lookup disagrees with full)
      miss_fail      : NOT is_match AND new_slot != INVALID
                       (wrong-lane should miss but returns a slot)
    """
    n = LAYER_COUNTS[L]
    orig = np.arange(n)

    k_fwd, cidx_fwd = forward_split_vec(L, orig)
    lane_ok, compact, depth_ok, in_range = decoder_sim_vec(L, orig, LANE_ID)

    is_match = (k_fwd == LANE_ID)

    # === Direct formula checks (don't depend on lane file values) ===
    lane_flag_fail = lane_ok != is_match
    compact_fail   = is_match & (compact != cidx_fwd)
    depth_fail     = is_match & (~depth_ok)

    # === Slot-lookup checks (existing, depend on lane file values) ===
    tab = lane_tabs[L][side][LANE_ID]
    safe_idx = np.clip(compact, 0, len(tab) - 1)
    raw_slot = tab[safe_idx]
    new_slot = np.where(in_range & lane_ok & depth_ok, raw_slot, INVALID)
    old_slot = full_table

    match_fail = is_match & (new_slot != old_slot)
    miss_fail  = (~is_match) & (new_slot != INVALID)

    # Capture first failure of each type for debug output
    fail_samples = []
    for kind, mask in [('lane_flag', lane_flag_fail),
                       ('compact',   compact_fail),
                       ('depth',     depth_fail),
                       ('match',     match_fail),
                       ('miss',      miss_fail)]:
        hit = np.where(mask)[0]
        if len(hit) > 0:
            idx = int(hit[0])
            fail_samples.append({
                'kind': kind, 'orig': idx,
                'k_fwd': int(k_fwd[idx]), 'cidx_fwd': int(cidx_fwd[idx]),
                'lane_ok': bool(lane_ok[idx]),
                'compact': int(compact[idx]),
                'depth_ok': bool(depth_ok[idx]),
                'new_slot': int(new_slot[idx]),
                'old_slot': int(old_slot[idx]),
            })

    return {
        'lane_flag': int(lane_flag_fail.sum()),
        'compact':   int(compact_fail.sum()),
        'depth':     int(depth_fail.sum()),
        'match':     int(match_fail.sum()),
        'miss':      int(miss_fail.sum()),
        'samples':   fail_samples,
    }


# ============================================================
# Top-level verification
# ============================================================
def verify(model, v3_dir):
    print(f"\n{'='*64}\nModel {model}\n  v3_dir: {v3_dir}\n{'='*64}")

    # 1. Load and check file lengths (both SRAM and PCM)
    lane_tabs = load_lane_tabs(v3_dir)
    print("\n  [1] Per-lane file lengths:")
    fail_lens = 0
    for L in LAYERS:
        exp = lane_depth(L)
        for side in SIDES:
            actual = [len(lane_tabs[L][side][k]) for k in range(KK)]
            bad = [k for k, a in enumerate(actual) if a != exp]
            status = 'OK' if not bad else f'FAIL ({len(bad)} files)'
            print(f"      {L:6s} {side:4s} expected {exp:5d}/lane  -> {status}")
            if bad:
                fail_lens += len(bad)

    # 2. Sweep
    print("\n  [2] Equivalence sweep "
          "(all model x side x layer x lane x orig):")
    print(f"      {'side':5s} {'layer':6s} "
          f"{'lane-flag':>10s} {'compact':>8s} {'depth':>6s} "
          f"{'match':>7s} {'miss':>6s} {'checks':>10s}")
    tot = {'lane_flag': 0, 'compact': 0, 'depth': 0,
           'match': 0, 'miss': 0}
    total_checks = 0
    sample_log = []

    for side in SIDES:
        full_per_L = {L: reconstruct_full(lane_tabs, L, side) for L in LAYERS}
        for L in LAYERS:
            layer = {'lane_flag': 0, 'compact': 0, 'depth': 0,
                     'match': 0, 'miss': 0}
            for LANE_ID in range(KK):
                r = sweep_layer_side_lane(
                    lane_tabs, L, side, LANE_ID, full_per_L[L])
                for k in layer:
                    layer[k] += r[k]
                for s in r['samples']:
                    if len(sample_log) < 12:
                        sample_log.append({'side': side, 'L': L,
                                           'LANE_ID': LANE_ID, **s})
            checks = KK * LAYER_COUNTS[L]
            print(f"      {side:5s} {L:6s} "
                  f"{layer['lane_flag']:>10d} {layer['compact']:>8d} "
                  f"{layer['depth']:>6d} {layer['match']:>7d} "
                  f"{layer['miss']:>6d} {checks:>10,d}")
            for k in tot:
                tot[k] += layer[k]
            total_checks += checks

    # Print failure samples if any
    if sample_log:
        print("\n  Failure samples (first ~12):")
        for s in sample_log:
            print(f"    [{s['kind']:9s}] side={s['side']:4s} "
                  f"L={s['L']:5s} LANE_ID={s['LANE_ID']:>2d} "
                  f"orig={s['orig']:>5d} k_fwd={s['k_fwd']:>2d} "
                  f"cidx_fwd={s['cidx_fwd']:>5d} "
                  f"lane_ok={int(s['lane_ok'])} "
                  f"compact={s['compact']:>5d} "
                  f"depth_ok={int(s['depth_ok'])} "
                  f"new=0x{s['new_slot']:04x} old=0x{s['old_slot']:04x}")

    # 3. Summary
    print(f"\n  Summary:")
    print(f"      Total (lane, orig) checks: {total_checks:>12,d}")
    print(f"      lane-flag failures:        {tot['lane_flag']:>12,d}")
    print(f"      compact-idx failures:      {tot['compact']:>12,d}")
    print(f"      depth-guard failures:      {tot['depth']:>12,d}")
    print(f"      match-slot failures:       {tot['match']:>12,d}")
    print(f"      miss-slot failures:        {tot['miss']:>12,d}")
    print(f"      file-length failures:      {fail_lens:>12d}")
    print()

    overall_pass = (tot['lane_flag'] == 0
                    and tot['compact']   == 0
                    and tot['depth']     == 0
                    and tot['match']     == 0
                    and tot['miss']      == 0
                    and fail_lens == 0)
    if overall_pass:
        print(f"  Model {model}: PASS")
        print(f"    Lane-sliced decoder verified across "
              f"{total_checks:,} (lane, orig) tuples on five")
        print(f"    independent formula and lookup axes:")
        print(f"      - lane-assignment formula consistency")
        print(f"      - compact-index formula consistency")
        print(f"      - depth-guard formula consistency")
        print(f"      - matching-lane slot equality vs reconstructed full")
        print(f"      - wrong-lane miss-return (INVALID) behaviour")
    else:
        print(f"  Model {model}: FAIL")
    return overall_pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', choices=['A', 'B'], required=True)
    ap.add_argument('--v3-dir', default=None,
                    help='v3 output dir (default: '
                         './data/rtl_inputs_<model>_v3)')
    args = ap.parse_args()
    v3_dir = (Path(args.v3_dir) if args.v3_dir
              else Path(f'./data/rtl_inputs_{args.model}_v3'))
    if not v3_dir.exists():
        print(f"ERROR: v3 dir not found: {v3_dir}")
        return 1
    ok = verify(args.model, v3_dir)
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
