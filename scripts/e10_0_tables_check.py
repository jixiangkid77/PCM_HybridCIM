#!/usr/bin/env python3
"""
e10_0_tables_check.py   P2R-E10.0: can the SRAM pool be 25 single-port banks?

The 25 lanes of a datapath step read the weights of one entry. A protected
weight is read at pool address = SRAM base of its layer + its slot (the
SRAM-side slot tables, data/rtl_inputs_<M>_v3/addr_to_slot_<layer>_sram_laneNN.hex;
base from split_summary_v3.json). With bank = address mod N and row = address
div N, the reads of a step never meet in one bank if their addresses are
distinct modulo N. This script checks, for every entry of both models:
  - the slots of the protected lanes are consecutive in lane order (so the
    addresses of a step are at most 25 consecutive numbers),
  - no two protected lanes of a step fall into the same bank, for N = 25 and 32,
  - the deepest row, and the protected weights per lane.
Exit 0 if every check passes.
Usage: python3 scripts/e10_0_tables_check.py --paper2 .
"""
import argparse, json, os, sys

LAYERS = ["conv1", "conv2", "fc1", "fc2", "fc3"]


def rd(path):
    return [x.strip().lower() for x in open(path) if x.strip() and not x.startswith("//") and not x.startswith("@")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".")
    ap.add_argument("--models", default="A,B")
    a = ap.parse_args()
    ok = True
    for M in a.models.split(","):
        d = os.path.join(a.paper2, "data", f"rtl_inputs_{M}_v3")
        summ = json.load(open(os.path.join(d, "split_summary_v3.json")))
        steps = nonconsec = 0
        conflicts = {25: 0, 32: 0}
        deepest = {25: 0, 32: 0}
        per_lane = [0] * 25
        for L in LAYERS:
            S = [rd(os.path.join(d, f"addr_to_slot_{L}_sram_lane{k:02d}.hex")) for k in range(25)]
            base = summ["layers"][L]["sram_base"]
            for e in range(len(S[0])):
                addr = []
                for k in range(25):
                    if S[k][e] != "ffff":
                        addr.append(base + int(S[k][e], 16))
                        per_lane[k] += 1
                if not addr:
                    continue
                steps += 1
                if any(addr[i + 1] != addr[i] + 1 for i in range(len(addr) - 1)):
                    nonconsec += 1
                for N in (25, 32):
                    if len({x % N for x in addr}) != len(addr):
                        conflicts[N] += 1
                    deepest[N] = max(deepest[N], max(x // N for x in addr))
        total = summ["sram_total"]
        good = nonconsec == 0 and conflicts[25] == 0 and deepest[25] < 128
        ok = ok and good
        print(f"model {M}: {total} protected weights, {steps} entries with protected weights; "
              f"entries with non-consecutive slots {nonconsec}")
        for N in (25, 32):
            print(f"   {N} banks: steps with two reads in one bank {conflicts[N]}, deepest row {deepest[N]} "
                  f"(words per bank needed {deepest[N] + 1})")
        print(f"   protected weights per lane: {min(per_lane)} to {max(per_lane)}")
    print("TABLES OK" if ok else "TABLES FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
