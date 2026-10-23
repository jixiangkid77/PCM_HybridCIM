"""
verify_split.py
============================================================
Self-validation: SRAM ∪ PCM ?= original weights

Verifies that 03_split_protected_v2.py output correctly splits
the original weights without loss or duplication.

Checks per layer:
  1. Reconstruction: weights[sram_idx] = sram_weights AND
                     weights[pcm_idx]  = pcm_weights, equals original
  2. Union: sram_idx ∪ pcm_idx == {0, 1, ..., n-1}
  3. Exclusivity: sram_idx ∩ pcm_idx == ∅
  4. Count: len(sram) + len(pcm) == n_total

Usage:
    python verify_split.py --model A
    python verify_split.py --model B
"""

import argparse
import numpy as np
from pathlib import Path

LAYER_COUNTS = {'conv1': 150, 'conv2': 2400, 'fc1': 48000, 'fc2': 10080, 'fc3': 840}


def read_int8(path):
    vals = []
    with open(path) as f:
        for line in f:
            s = line.strip()
            if s and not s.startswith('//'):
                x = int(s, 16)
                if x >= 128:
                    x -= 256
                vals.append(x)
    return np.array(vals, dtype=np.int32)


def read_addr(path):
    vals = []
    with open(path) as f:
        for line in f:
            s = line.strip()
            if s and not s.startswith('//'):
                vals.append(int(s, 16))
    return np.array(vals, dtype=np.int32)


def verify(model, src_dir, out_dir):
    print(f"\nModel {model}:")
    print(f"  source: {src_dir}")
    print(f"  output: {out_dir}")
    print()

    all_pass = True
    for layer, n in LAYER_COUNTS.items():
        orig = read_int8(src_dir / f'weights_{layer}.hex')
        sram_w = read_int8(out_dir / f'weights_{layer}_sram.hex')
        pcm_w = read_int8(out_dir / f'weights_{layer}_pcm.hex')
        sram_idx = read_addr(out_dir / f'idx_{layer}_sram.hex')
        pcm_idx = read_addr(out_dir / f'idx_{layer}_pcm.hex')

        # Test 4: count
        count_ok = len(sram_w) + len(pcm_w) == n
        # Test 1: reconstruction
        recon = np.zeros(n, dtype=np.int32)
        if len(sram_idx) > 0:
            recon[sram_idx] = sram_w
        if len(pcm_idx) > 0:
            recon[pcm_idx] = pcm_w
        recon_ok = np.array_equal(orig, recon)
        # Test 2: union
        union_ok = (set(sram_idx) | set(pcm_idx)) == set(range(n))
        # Test 3: exclusivity
        excl_ok = len(set(sram_idx) & set(pcm_idx)) == 0

        # Test 5 & 6: addr_to_slot tables match idx files
        slot_ok = True
        addr_to_slot_path_s = out_dir / f'addr_to_slot_{layer}_sram.hex'
        addr_to_slot_path_p = out_dir / f'addr_to_slot_{layer}_pcm.hex'
        if addr_to_slot_path_s.exists() and addr_to_slot_path_p.exists():
            addr_width = max(1, int(np.ceil(np.log2(n))))
            INVALID = (1 << addr_width) - 1
            s_table = read_addr(addr_to_slot_path_s)
            p_table = read_addr(addr_to_slot_path_p)
            # Each addr must be in exactly one partition
            for addr in range(n):
                in_s = s_table[addr] != INVALID
                in_p = p_table[addr] != INVALID
                if (in_s + in_p) != 1:
                    slot_ok = False
                    break
                if in_s:
                    # sram_w[s_table[addr]] should equal orig[addr]
                    if sram_w[s_table[addr]] != orig[addr]:
                        slot_ok = False
                        break
                else:
                    if pcm_w[p_table[addr]] != orig[addr]:
                        slot_ok = False
                        break

        passed = count_ok and recon_ok and union_ok and excl_ok and slot_ok
        status = '[PASS]' if passed else '[FAIL]'
        print(f"  {layer:6s}  count={count_ok}  recon={recon_ok}  "
              f"union={union_ok}  exclusive={excl_ok}  slot={slot_ok}  {status}")

        if not passed:
            all_pass = False

    print()
    print(f"  Model {model}: {'ALL PASS' if all_pass else 'FAILED'}")
    return all_pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', choices=['A', 'B'], required=True)
    ap.add_argument('--src-dir', default='./data/rtl_inputs_TMP')
    ap.add_argument('--out-dir', default=None)
    args = ap.parse_args()

    src_dir = Path(args.src_dir)
    out_dir = Path(args.out_dir) if args.out_dir else Path(f'./data/rtl_inputs_{args.model}')

    print("=" * 60)
    print(f"verify_split.py  Model {args.model}")
    print("=" * 60)

    ok = verify(args.model, src_dir, out_dir)
    exit(0 if ok else 1)


if __name__ == '__main__':
    main()
