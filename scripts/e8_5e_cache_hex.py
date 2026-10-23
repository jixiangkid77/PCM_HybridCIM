#!/usr/bin/env python3
"""
e8_5e_cache_hex.py   (P2R-E8.5e)

The contents of the conv1 register cache (rtl/e8/conv1_cache.v) for one model,
from the same data the RTL simulation loads:
  data/rtl_inputs_<M>_v3/layer_config.hex           conv1 SRAM base and size (entry 0)
  data/rtl_inputs_<M>_v3/addr_to_slot_conv1_sram_lane<LL>.hex   6 slots per lane
  data/rtl_inputs_<M>_v3/sram_pool.hex              the pool (SRAM_TOTAL words)
Entry l*6 + oc = pool[base + slot(l, oc)], i.e. the word the SRAM-side decoder of
lane l would address for output channel oc (rtl/src/sram_addr_decoder.v: conv1
compact index = orig_addr / 25 = oc). Every conv1 entry must be a clean hit
(slot != FFFF, slot < size, base + slot < SRAM_TOTAL); otherwise the script stops.

Usage:
  python3 scripts/e8_5e_cache_hex.py --data data/rtl_inputs_A_v3 --out WORK/conv1_cache_A.hex
Writes 150 lines of two hex digits and prints a summary with the md5 of every input.
"""
import argparse
import hashlib
import os
import sys

K, NOC, SRAM_TOTAL = 25, 6, 3074


def md5(path):
    return hashlib.md5(open(path, "rb").read()).hexdigest()


def read_memh(path, n, width_bits):
    """$readmemh subset: hex words separated by white space, // comments, @addr lines"""
    mem = [None] * n
    addr = 0
    for ln in open(path):
        ln = ln.split("//")[0]
        for tok in ln.split():
            if tok.startswith("@"):
                addr = int(tok[1:], 16)
                continue
            if addr >= n:
                sys.exit(f"{path}: more than {n} words")
            v = int(tok.replace("_", ""), 16)
            if v >= 1 << width_bits:
                sys.exit(f"{path}: word {tok} wider than {width_bits} bits")
            mem[addr] = v
            addr += 1
    return mem


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", required=True, help="data/rtl_inputs_<M>_v3")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    lc = os.path.join(a.data, "layer_config.hex")
    pool_f = os.path.join(a.data, "sram_pool.hex")
    cfg = read_memh(lc, 10, 32)
    if cfg[0] is None:
        sys.exit(f"{lc}: no entry 0 (conv1 SRAM)")
    base, size = cfg[0] & 0xFFFF, cfg[0] >> 16
    pool = read_memh(pool_f, SRAM_TOTAL, 8)
    print(f"P2R-E8.5e conv1 cache contents from {a.data}")
    print(f"   layer_config.hex : {md5(lc)}  conv1 SRAM base {base}, size {size}")
    print(f"   sram_pool.hex    : {md5(pool_f)}  {sum(1 for x in pool if x is not None)} words")
    out, slots = [], []
    for lane in range(K):
        f = os.path.join(a.data, f"addr_to_slot_conv1_sram_lane{lane:02d}.hex")
        s = read_memh(f, NOC, 16)
        for oc in range(NOC):
            sl = s[oc]
            if sl is None or sl == 0xFFFF:
                sys.exit(f"{f}: entry {oc} is not a hit ({sl}); the cache assumes every conv1 weight is protected")
            if sl >= size or base + sl >= SRAM_TOTAL:
                sys.exit(f"{f}: entry {oc}: slot {sl} out of range (size {size}, base {base})")
            w = pool[base + sl]
            if w is None:
                sys.exit(f"{pool_f}: no word at {base + sl}")
            out.append(w)
            slots.append(sl)
    with open(a.out, "w") as fh:
        fh.write("".join(f"{w:02x}\n" for w in out))
    print(f"   conv1 slots: {len(slots)} hits, {len(set(slots))} distinct, {min(slots)}..{max(slots)}")
    print(f"   written {a.out}: {len(out)} entries (lane*6 + oc)  md5 {md5(a.out)}")


if __name__ == "__main__":
    main()
