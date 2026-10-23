#!/usr/bin/env python3
"""Time-step check of the SRAM simulations on a smaller macro (E8.4c).

The macro (proxy_sram_1rw_1x4096 in the header of each analysis): OpenRAM, one
bit wide, 4,096 words, generated with 16 words per row (257 rows x 17 columns),
so its bit lines and 16-to-1 column multiplexer are those of the 4-KB macro. It
was simulated with the same kind of bench as the 4-KB macro (scripts/e8_4c_sram_bench.py),
with a maximum time step of one fiftieth of the clock period (200 ps at 10 ns,
400 ps at 20 ns), of 50 ps, and of 20 ps as the reference (see the notes of
version 6 in scripts/e8_4c_sram_char.sh). The analysis of each run
(reports/e8_rom/e8_4c_tstep/an_*.txt) lists every cycle: kind, data read, energy
from the supply. File names: n9 / n27 = stages of the delay chain, t10 / t20 =
clock period in ns, spc = precharge at the sense-amplifier inputs, p = a shorter
sequence of cycles; _50ps and _fine (20 ps) = the maximum time step, none = one
fiftieth of the period. Runs of different length are compared over the cycles
both contain. an_n27_t10_fine.txt, an_n27_t20.txt and an_n9_t20spc.txt are runs
of the same study that are not part of a pair.

For each pair of runs this script compares the reads cycle by cycle and the
energy of each kind of cycle, over the cycles that both runs completed.

Usage: python3 scripts/e8_4c_tstep_compare.py --paper2 .
"""
import argparse
import os

PAIRS = [
    ("27 stages, 20 ns clock: 50 ps against 20 ps", "an_n27_t20p_50ps.txt", "an_n27_t20p_fine.txt"),
    ("9 stages with sense-input precharge, 10 ns gated reads: 50 ps against 20 ps",
     "an_n9_t10spc_50ps.txt", "an_n9_t10spc_fine.txt"),
    ("27 stages, 20 ns clock: 400 ps against 20 ps", "an_n27_t20p.txt", "an_n27_t20p_fine.txt"),
    ("9 stages with sense-input precharge, 10 ns gated reads: 200 ps against 20 ps",
     "an_n9_t10spc.txt", "an_n9_t10spc_fine.txt"),
    ("9 stages, 20 ns clock: 400 ps against 20 ps", "an_n9_t20.txt", "an_n9_t20_fine.txt"),
]


def cycles(path):
    out = {}
    complete = None
    for line in open(path):
        if line.startswith("data: simulated to"):
            n, m = line.split("cycles complete")[0].split(",")[-1].split(" of ")
            complete = int(n)

        tk = line.split()
        if len(tk) < 5 or not tk[0].isdigit():
            continue
        k, kind = int(tk[0]), tk[1]
        rec = {"kind": kind}
        if kind == "read":
            rec["read_end"] = tk[5]
            rec["E"] = float(tk[7])
            rec["after_stop"] = line.split("after the stop:")[1].split()[0] if "after the stop:" in line else None
        else:
            nums = [x for x in tk[2:] if x != "-"]
            rec["E"] = float(nums[-3])
        out[k] = rec
    return {k: v for k, v in out.items() if complete is None or k < complete}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".")
    a = ap.parse_args()
    d = os.path.join(a.paper2, "reports", "e8_rom", "e8_4c_tstep")
    for title, f1, f2 in PAIRS:
        c1, c2 = cycles(os.path.join(d, f1)), cycles(os.path.join(d, f2))
        ks = sorted(set(c1) & set(c2))
        reads = [k for k in ks if c1[k]["kind"] == "read"]
        same_end = sum(1 for k in reads if c1[k]["read_end"] == c2[k]["read_end"])
        same_stop = sum(1 for k in reads if c1[k]["after_stop"] == c2[k]["after_stop"])
        print(f"{title}  ({f1} / {f2}, cycles 0-{ks[-1]})")
        print(f"   reads: {len(reads)}; same word at the end of the cycle {same_end}, after the stopped clock {same_stop}")
        for kind in ("read", "write", "idle", "stop"):
            ds = [abs(c1[k]["E"] / c2[k]["E"] - 1) for k in ks if c1[k]["kind"] == kind == c2[k]["kind"] and c2[k]["E"]]
            if ds:
                print(f"   {kind:5s}: {len(ds):2d} cycles, largest energy difference {100 * max(ds):.2f}%")
        gated = [abs((c1[k]["E"] + c1[k + 1]["E"]) / (c2[k]["E"] + c2[k + 1]["E"]) - 1)
                 for k in reads if k + 1 in ks and c1[k + 1]["kind"] == "stop" == c2[k + 1]["kind"]]
        if gated:
            print(f"   read with the following stopped interval: {len(gated)}, largest difference {100 * max(gated):.2f}%")


if __name__ == "__main__":
    main()
