"""
verify_split_v3.py
============================================================
Self-validation of 03_split_protected_v3.py output.

Reads the v3 pool files and reconstructs the original weights
through the layer_config + addr_to_slot indirection chain that
the RTL will use at runtime. This is the Python mirror of what
sram_pool.v + pcm_crossbar.v will do in hardware:

    For each layer L, for each original weight address a in 0..n_L-1:
        s_slot = addr_to_slot_L_sram[a]
        p_slot = addr_to_slot_L_pcm [a]

        # Exactly one of s_slot, p_slot is != 0xFFFF
        if s_slot != 0xFFFF:
            pool_addr = sram_base[L] + s_slot
            recon = sram_pool[pool_addr]
        else:
            pool_addr = pcm_base[L] + p_slot
            recon = pcm_pool[pool_addr]

        assert recon == orig_weight[L][a]

Also validates:
  - sram_pool / pcm_pool line counts
  - layer_config word format (size & base ranges, monotonic bases)
  - nu_pcm_pool length == pcm_pool length
  - INVALID sentinel = 0xFFFF
  - Each orig addr is in exactly one partition

Usage:
    python verify_split_v3.py --model A
    python verify_split_v3.py --model B
"""

import argparse
import json
import numpy as np
from pathlib import Path

LAYERS = ['conv1', 'conv2', 'fc1', 'fc2', 'fc3']
LAYER_COUNTS = {'conv1': 150, 'conv2': 2400, 'fc1': 48000,
                'fc2': 10080, 'fc3': 840}
INVALID = 0xFFFF


def read_int8(path):
    vals = []
    with open(path) as f:
        for line in f:
            s = line.split('//')[0].strip()
            if s:
                x = int(s, 16)
                vals.append(x - 256 if x >= 128 else x)
    return np.array(vals, dtype=np.int32)


def read_uint(path):
    vals = []
    with open(path) as f:
        for line in f:
            s = line.split('//')[0].strip()
            if s:
                vals.append(int(s, 16))
    return np.array(vals, dtype=np.int64)


def parse_cfg(words):
    """Each 32-bit word -> (size, base)."""
    return [((w >> 16) & 0xFFFF, w & 0xFFFF) for w in words]


# ---- Lane-sliced addr_to_slot reconstruction (v3 lane-sliced refactor) ----
# Each decoder stores only its 1/25 share of the layer's addr_to_slot
# table. This helper reads all 25 lane files and reconstructs the
# full layer-wide table (length LAYER_COUNTS[L]), filling INVALID
# for any unmapped orig_addr.

import math as _math
_LAYER_PARAMS = {
    'conv1': ('conv',   1,   6),
    'conv2': ('conv',   6,  16),
    'fc1':   ('fc',   400, 120),
    'fc2':   ('fc',   120,  84),
    'fc3':   ('fc',    84,  10),
}
_KK = 25


def read_addr_to_slot_full(v3_dir, L, side):
    """Reconstruct the full layer-wide addr_to_slot table from 25
    lane-sliced files. Returns numpy array of length LAYER_COUNTS[L].

    For FC layers where IN_DIM is not a multiple of 25, some (k, sb)
    combinations correspond to padding (flat_idx = sb*25+k >= IN_DIM)
    and have no corresponding real orig_addr. The lane file leaves
    those slots as INVALID, and the forward mapping never writes
    there. We must skip them in reverse to avoid overwriting valid
    entries via the ambiguous formula `orig = oc*IN_DIM + sb*25 + k`.
    """
    n = LAYER_COUNTS[L]
    full = np.full(n, INVALID, dtype=np.int64)
    ltype, a, b = _LAYER_PARAMS[L]
    if ltype == 'conv':
        IC = a
        for k in range(_KK):
            lane = read_uint(v3_dir /
                f'addr_to_slot_{L}_{side}_lane{k:02d}.hex')
            for cidx in range(len(lane)):
                oc = cidx // IC
                ic = cidx % IC
                orig = oc * (IC * _KK) + ic * _KK + k
                if 0 <= orig < n:
                    full[orig] = lane[cidx]
    else:
        IN_DIM = a
        sb_groups = _math.ceil(IN_DIM / _KK)
        for k in range(_KK):
            lane = read_uint(v3_dir /
                f'addr_to_slot_{L}_{side}_lane{k:02d}.hex')
            for cidx in range(len(lane)):
                oc = cidx // sb_groups
                sb = cidx % sb_groups
                flat_idx = sb * _KK + k
                if flat_idx >= IN_DIM:
                    continue   # padding cell - skip
                orig = oc * IN_DIM + flat_idx
                if 0 <= orig < n:
                    full[orig] = lane[cidx]
    return full


def verify(model, src_dir, v3_dir):
    print(f"\nModel {model}:")
    print(f"  v2 source:   {src_dir}")
    print(f"  v3 outputs:  {v3_dir}")
    print()

    failures = []

    def check(cond, name, detail=""):
        status = "PASS" if cond else "FAIL"
        line = f"  [{status}] {name}"
        if detail:
            line += f"  -- {detail}"
        print(line)
        if not cond:
            failures.append(name)

    # ---- 1. File presence + line counts ----
    sram_pool = read_int8(v3_dir / 'sram_pool.hex')
    pcm_pool = read_int8(v3_dir / 'pcm_pool.hex')
    nu_pool = read_uint(v3_dir / 'nu_pcm_pool.hex')
    cfg_words = read_uint(v3_dir / 'layer_config.hex')

    check(len(sram_pool) == 3074, "sram_pool.hex line count == 3074",
          f"got {len(sram_pool)}")
    check(len(pcm_pool) == 58396, "pcm_pool.hex line count == 58396",
          f"got {len(pcm_pool)}")
    check(len(nu_pool) == len(pcm_pool),
          "nu_pcm_pool.hex length == pcm_pool length",
          f"{len(nu_pool)} vs {len(pcm_pool)}")
    check(len(cfg_words) == 10, "layer_config.hex == 10 lines",
          f"got {len(cfg_words)}")

    # ---- 2. Parse layer_config ----
    cfg = parse_cfg(cfg_words)
    sram_cfg = cfg[0:5]
    pcm_cfg = cfg[5:10]

    print()
    print("  layer_config.hex contents:")
    for i, L in enumerate(LAYERS):
        sz, ba = sram_cfg[i]
        print(f"    [0x{i:02x}] SRAM {L:6s}: base={ba:5d} (0x{ba:04x})  "
              f"size={sz:5d} (0x{sz:04x})")
    for i, L in enumerate(LAYERS):
        sz, ba = pcm_cfg[i]
        print(f"    [0x{i+5:02x}] PCM  {L:6s}: base={ba:5d} (0x{ba:04x})  "
              f"size={sz:5d} (0x{sz:04x})")
    print()

    # ---- 3. Bases monotone, last base+size matches pool sizes ----
    s_bases_ok = True
    s_off = 0
    for L, (sz, ba) in zip(LAYERS, sram_cfg):
        if ba != s_off:
            s_bases_ok = False
        s_off += sz
    check(s_bases_ok, "SRAM bases are contiguous (each base = sum of "
                     "preceding sizes)")
    check(s_off == 3074, "SRAM total size sum == 3074",
          f"got {s_off}")

    p_bases_ok = True
    p_off = 0
    for L, (sz, ba) in zip(LAYERS, pcm_cfg):
        if ba != p_off:
            p_bases_ok = False
        p_off += sz
    check(p_bases_ok, "PCM bases are contiguous")
    check(p_off == 58396, "PCM total size sum == 58396",
          f"got {p_off}")

    # ---- 4. Per-layer: reconstruct addr_to_slot from lane-sliced files;
    #         then check exclusivity ----
    print()
    a2s = {}
    for L in LAYERS:
        n = LAYER_COUNTS[L]
        s_tab = read_addr_to_slot_full(v3_dir, L, 'sram')
        p_tab = read_addr_to_slot_full(v3_dir, L, 'pcm')

        # Reconstruction returns length-n array by construction, so the
        # length checks are now trivial; we keep an exclusivity assertion
        # which is the meaningful invariant.

        in_s = (s_tab != INVALID)
        in_p = (p_tab != INVALID)
        excl = np.all((in_s.astype(np.int32) +
                       in_p.astype(np.int32)) == 1)
        check(bool(excl),
              f"{L}: every orig addr in exactly one partition")

        # Slot ranges within partition size
        sz_s, _ = sram_cfg[LAYERS.index(L)]
        sz_p, _ = pcm_cfg[LAYERS.index(L)]
        if in_s.any():
            check(int(s_tab[in_s].max()) < sz_s,
                  f"{L}: max sram slot < layer size {sz_s}",
                  f"max={int(s_tab[in_s].max())}")
        if in_p.any():
            check(int(p_tab[in_p].max()) < sz_p,
                  f"{L}: max pcm slot < layer size {sz_p}",
                  f"max={int(p_tab[in_p].max())}")

        a2s[L] = {'sram': s_tab, 'pcm': p_tab}

    # ---- 5. End-to-end reconstruction (the RTL-equivalent path) ----
    print()
    recon_pass = 0
    recon_fail = 0
    for L in LAYERS:
        orig = read_int8(src_dir / f'weights_{L}.hex')
        n = LAYER_COUNTS[L]
        sz_s, ba_s = sram_cfg[LAYERS.index(L)]
        sz_p, ba_p = pcm_cfg[LAYERS.index(L)]
        s_tab = a2s[L]['sram']
        p_tab = a2s[L]['pcm']
        recon = np.zeros(n, dtype=np.int32)
        for a in range(n):
            if s_tab[a] != INVALID:
                pool_addr = ba_s + int(s_tab[a])
                recon[a] = sram_pool[pool_addr]
            else:
                pool_addr = ba_p + int(p_tab[a])
                recon[a] = pcm_pool[pool_addr]
        ok = np.array_equal(recon, orig)
        if ok:
            recon_pass += 1
        else:
            recon_fail += 1
            mismatch_count = int(np.sum(recon != orig))
            print(f"  [FAIL] {L} reconstruction: {mismatch_count} "
                  f"mismatches (of {n})")
        check(ok, f"{L}: pool[base+slot] matches original weights")

    # ---- Summary ----
    print()
    if not failures:
        print(f"  Model {model}: ALL CHECKS PASSED")
        return True
    else:
        print(f"  Model {model}: {len(failures)} FAILED")
        for fname in failures:
            print(f"    - {fname}")
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', choices=['A', 'B'], required=True)
    ap.add_argument('--src-dir', default=None,
                    help='Source dir with v2 weights_<L>.hex. '
                         'Default: ./data/rtl_inputs_<model>')
    ap.add_argument('--v3-dir', default=None,
                    help='v3 output dir. Default: '
                         './data/rtl_inputs_<model>_v3')
    args = ap.parse_args()

    src_dir = Path(args.src_dir) if args.src_dir \
              else Path(f'./data/rtl_inputs_{args.model}')
    v3_dir = Path(args.v3_dir) if args.v3_dir \
             else Path(f'./data/rtl_inputs_{args.model}_v3')

    print("=" * 60)
    print(f"verify_split_v3.py  Model {args.model}")
    print("=" * 60)

    ok = verify(args.model, src_dir, v3_dir)
    exit(0 if ok else 1)


if __name__ == '__main__':
    main()
