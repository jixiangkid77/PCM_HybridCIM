#!/usr/bin/env python3
"""Fig. 11: the memories at six combinations of corner and temperature (1.80 V).

(a) Each quantity divided by its value at tt, 25 C: the per-inference ROM
    energy D_ROM (corrected for the model error) of the two models, the
    SRAM energy per read in the system (gated two-cycle) read, and the SRAM
    static power after a read.
(b) Model A per inference: D_ROM, with the share drawn by the macros at rest
    (leakage) written above the bar, and the protected-weight SRAM with one
    macro and with 25 copies, split into reads and static power.
Sources: reports/e8_6/e8_6_summary.json ('conditions'), reports/e8_rom/e8_5g/
e8_5g_drom.json. The share of the macros at rest is their energy divided by
D_ROM after the correction, the value the bar shows: 'parked_leak_new_uJ' /
'corrected_uJ' of 'conditions'.<cond>.A, and at tt 25 C the parts 'leak' of
models.A.variants.main over its 'corrected_uJ'. (The file's 'leak_share' is
the same energy over D_ROM before the correction.)

Usage: python3 scripts/fig11_conditions.py --paper2 . --out figures
"""
import argparse
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch
from matplotlib.lines import Line2D

CONDS = ["tt:-40", "ss:25", "tt:25", "ff:25", "tt:85", "ff:85"]
CLAB = {"tt:-40": "tt\n−40 °C", "ss:25": "ss\n25 °C", "tt:25": "tt\n25 °C", "ff:25": "ff\n25 °C",
        "tt:85": "tt\n85 °C", "ff:85": "ff\n85 °C"}
C_MAP, C_SRAM, C_SRAM_L = "#b5643b", "#2a6f7d", "#9cc3cb"
WHITE = dict(boxstyle="square,pad=0.12", fc="white", ec="none")   # text over the gridlines

plt.rcParams.update({
    "mathtext.fontset": "custom", "mathtext.rm": "Liberation Sans", "mathtext.it": "Liberation Sans:italic",
    "mathtext.bf": "Liberation Sans:bold",
    "font.family": "Liberation Sans", "font.size": 15, "axes.labelsize": 15,
    "xtick.labelsize": 14, "ytick.labelsize": 14, "legend.fontsize": 12,
    "axes.linewidth": 1.0, "pdf.fonttype": 42,
})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".")
    ap.add_argument("--out", default="figures")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    s = json.load(open(os.path.join(a.paper2, "reports", "e8_6", "e8_6_summary.json")))["conditions"]
    g = json.load(open(os.path.join(a.paper2, "reports", "e8_rom", "e8_5g", "e8_5g_drom.json")))
    main_a = g["models"]["A"]["variants"]["main"]
    leak = {"tt:25": (main_a["parts_uJ"]["pcm"]["leak"] + main_a["parts_uJ"]["sram"]["leak"]) / main_a["corrected_uJ"]}
    for c in CONDS:
        if c != "tt:25":
            gc = g["conditions"][c + ":1.80"]["A"]
            leak[c] = gc["parked_leak_new_uJ"] / gc["corrected_uJ"]
            assert abs(gc["corrected_uJ"] - s[c]["A"]["d_rom_uJ"]) < 1e-9
            print(f"{c}: at rest {100 * leak[c]:.1f}% of corrected D_ROM ({100 * gc['leak_share']:.1f}% before the correction)")
    for c in CONDS:
        v = s[c]
        print(f"{c:6s} D_ROM A {v['A']['d_rom_uJ']:6.2f} ({v['A']['d_rom_x_tt']:.2f}x, at rest {100 * leak[c]:.0f}%)  "
              f"B {v['B']['d_rom_uJ']:6.2f} ({v['B']['d_rom_x_tt']:.2f}x)  SRAM read {v['r_read']:.3f}x static {v['r_static']:.2f}x  "
              f"A: 1 macro {v['A']['sram_1_uJ']:.2f}, 25 copies {v['A']['sram_25_uJ']:.2f} uJ")

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(6.5, 10.2), gridspec_kw={"hspace": 0.40})
    x = list(range(len(CONDS)))
    series = [("$D_\\mathrm{ROM}$, Model A", [s[c]["A"]["d_rom_x_tt"] for c in CONDS], C_MAP, "o", "-"),
              ("$D_\\mathrm{ROM}$, Model B", [s[c]["B"]["d_rom_x_tt"] for c in CONDS], C_MAP, "s", "--"),
              ("SRAM energy per read", [s[c]["r_read"] for c in CONDS], C_SRAM, "^", "-"),
              ("SRAM static power after a read", [s[c]["r_static"] for c in CONDS], C_SRAM, "D", ":")]
    for lab, ys, col, mk, ls in series:
        ax1.plot(x, ys, color=col, marker=mk, ls=ls, lw=1.6, ms=8, mfc="white" if mk in "sD" else col, mew=1.6,
                 label=lab)
    ax1.axhline(1.0, color="#999999", lw=1.0)
    ax1.set_yscale("log")
    ax1.set_ylim(0.3, 300)
    ax1.set_xticks(x)
    ax1.set_xticklabels([CLAB[c] for c in CONDS])
    ax1.set_ylabel("Relative to tt, 25 °C")
    ax1.set_title("(a) Change from tt, 25 °C", loc="left", fontsize=15, fontweight="bold")
    ax1.legend(loc="upper left", frameon=True, framealpha=1.0, facecolor="white", edgecolor="none", handletextpad=0.4)
    ax1.grid(True, which="major", color="#e3e3e3", lw=0.7)
    ax1.set_axisbelow(True)

    w = 0.26
    gap = 0.07   # between the D_ROM bar and the two SRAM bars, so that the share above D_ROM clears them
    for i, c in enumerate(CONDS):
        v = s[c]["A"]
        ax2.bar(i - w - gap, v["d_rom_uJ"], w, color=C_MAP, edgecolor="white", lw=0.6)
        ax2.text(i - w - gap, v["d_rom_uJ"] + 1.2, f"{100 * leak[c]:.0f}%", ha="center", va="bottom", fontsize=12.5,
                 color=C_MAP, bbox=WHITE)
        for j, n in ((0, 1), (1, 25)):
            st = v["sram_static_1_uJ"] * n
            rd = v["sram_reads_uJ"]
            xx = i + (j * w)
            ax2.bar(xx, rd, w, color=C_SRAM, edgecolor="white", lw=0.6)
            ax2.bar(xx, st, w, bottom=rd, color=C_SRAM_L, edgecolor="white", lw=0.6, hatch="//")
            assert abs(rd + st - v["sram_1_uJ" if n == 1 else "sram_25_uJ"]) < 1e-6
    ax2.set_xticks([i - gap / 2 for i in x])
    ax2.set_xticklabels([CLAB[c] for c in CONDS])
    ax2.set_ylabel("Energy per inference (µJ)")
    ax2.set_ylim(0, 98)
    ax2.set_title("(b) Model A: address-map ROMs and SRAM", loc="left", fontsize=15, fontweight="bold")
    ax2.legend(handles=[Patch(color=C_MAP, label="$D_\\mathrm{ROM}$ (above: share of the macros at rest)"),
                        Patch(color=C_SRAM, label="SRAM reads (left: one macro; right: 25 copies)"),
                        Patch(facecolor=C_SRAM_L, hatch="//", edgecolor="white", label="SRAM static power")],
               loc="upper left", frameon=True, framealpha=1.0, facecolor="white", edgecolor="none", handletextpad=0.4)
    ax2.grid(True, axis="y", color="#e3e3e3", lw=0.7)
    ax2.set_axisbelow(True)
    fig.subplots_adjust(left=0.14, right=0.97, top=0.96, bottom=0.08)
    fig.align_ylabels([ax1, ax2])
    for ext in ("png", "pdf"):
        fig.savefig(os.path.join(a.out, "fig11_conditions." + ext), dpi=300)
    plt.close(fig)


if __name__ == "__main__":
    main()
