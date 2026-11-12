#!/usr/bin/env python3
"""Fig. 6 of the TVLSI manuscript: energy per access of the two SRAM macros of the compiler and of the
address-map ROM.

For the 4-KB macro (4,096 words of 8 bit) and for the 128-word bank of the protected-weight SRAM (E10):
the energy a gate-level power analysis takes from the compiler's timing library for a read (two clock
transitions; library generated from the netlist with a 6.89-fF load), against post-layout simulation of a
read in the two-cycle sequence of the system (mean of seven reads; the bar gives their range). The 4-KB
values are those of E8.6 (reports/e8_6/e8_6_summary.json: the library entry 11.81819 pJ per transition,
'e84f'); the bank's are those of E10.2b (reports/e10/e10_2b/e10_2b_summary.json 'bank': the library of the
bank as generated, E10.1 F, and the system read of the bank as used, E10.1 S). The ROM lookup read is the
mean energy of a lookup read of the address map over its cycle (90 ns of precharge after it), over the 2,483
lookups of Model A in one inference (reports/e9/e9_5/e9_5_summary.json 'lookup_read': the lookup model of
E9.3b, corrected by its mean error with each macro left out). Printed as well: the SRAM read after cycles
without access and the data-valid times that the text reports.

Usage: python3 scripts/tvlsi/fig6_sram.py --paper2 . --out figures/tvlsi
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tvlsi_style as S  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402

LIB_ENTRY_PJ = 11.81819          # clk0 internal_power entry of the 4-KB macro's timing library, per transition
LIB_READ_PJ = 2 * LIB_ENTRY_PJ   # a read: one rising and one falling transition
ANALYTIC_LEAK_UW = 34.375        # leakage of the same library
G, GL, R, N = "#2a6f7d", "#5f9ea8", "#b5643b", "#8a8a8a"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".")
    ap.add_argument("--out", default="figures/tvlsi")
    a = ap.parse_args()
    s = json.load(open(os.path.join(a.paper2, "reports", "e8_6", "e8_6_summary.json")))
    b = json.load(open(os.path.join(a.paper2, "reports", "e10", "e10_2b", "e10_2b_summary.json")))["bank"]
    f = s["e84f"]
    cond = json.load(open(os.path.join(a.paper2, "reports", "e8_rom", "e8_4e_sram", "e8_4e_sram_summary.json")))["per"]
    t_tt = f["t_acc_gated_ns_max"]
    t_slow = max(max(r["t_acc_gated_ns"] for r in v["reads"]) for v in cond.values())
    e95 = json.load(open(os.path.join(a.paper2, "reports", "e9", "e9_5", "e9_5_summary.json")))
    lookup_pj = e95["lookup_read"]["models"]["A"]["mean_pJ"]
    idle = [x for x in f["gated_all_pJ"] if x not in f["system_pJ"]]
    print(f"4-KB macro: data valid {t_tt:.3f} ns (tt 25 C), slowest {t_slow:.2f} ns; library read {LIB_READ_PJ:.2f} pJ; "
          f"read after idle {sum(idle) / len(idle):.2f} pJ; system read {f['e_read_pJ']:.2f} pJ "
          f"({f['e_read_min_pJ']:.2f}-{f['e_read_max_pJ']:.2f}), {f['e_read_pJ'] / LIB_READ_PJ:.2f} x the library; "
          f"static {f['p_static_uW']:.3f} uW, 1/{ANALYTIC_LEAK_UW / f['p_static_uW']:.1f} of {ANALYTIC_LEAK_UW} uW")
    print(f"bank: library read {b['library_read_pJ_6p89fF']:.3f} pJ (6.89 fF), {b['library_read_pJ_default_loads']:.3f} pJ "
          f"(default loads); system read {b['system_read_pJ']:.3f} pJ ({b['system_read_range_pJ'][0]:.3f}-"
          f"{b['system_read_range_pJ'][1]:.3f}); as generated {b['F_system_read_pJ']:.3f} pJ = "
          f"{b['F_over_library_6p89fF']:.2f} x and {b['F_over_library_default']:.2f} x its library")
    print(f"ROM lookup read {lookup_pj:.2f} pJ, {lookup_pj / LIB_READ_PJ:.2f} x the 4-KB library read")

    fig = plt.figure(figsize=(S.COL1, 1.25))
    bx = fig.add_axes([0.345, 0.29, 0.635, 0.70])
    labels = ["4-KB macro, library", "4-KB macro, read", "bank, library", "bank, read", "ROM lookup read"]
    vals = [LIB_READ_PJ, f["e_read_pJ"], b["library_read_pJ_6p89fF"], b["system_read_pJ"], lookup_pj]
    rng = {1: (f["e_read_min_pJ"], f["e_read_max_pJ"]), 3: tuple(b["system_read_range_pJ"])}
    cols = [N, G, N, GL, R]
    y = list(range(len(vals)))[::-1]
    bx.barh(y, vals, color=cols, height=0.66)
    for i_, (lo, hi) in rng.items():
        bx.errorbar([vals[i_]], [y[i_]], xerr=[[vals[i_] - lo], [hi - vals[i_]]], color="#333333", capsize=2, lw=0.7)
    for i_, (yy, v) in enumerate(zip(y, vals)):
        xt = (rng[i_][1] if i_ in rng else v) + 2.0
        bx.text(xt, yy, f"{v:.1f} pJ", va="center", fontsize=S.FS_SMALL)
    bx.set_yticks(y)
    bx.set_yticklabels(labels, fontsize=S.FS_SMALL, linespacing=1.0)
    bx.set_xlim(0, 112)
    bx.set_xlabel("Energy per access (pJ)")
    S.grid(bx, axis="x")
    S.save(fig, a.out, "fig6_sram")


if __name__ == "__main__":
    main()
