#!/usr/bin/env python3
"""Fig. 5 of the TVLSI manuscript: the address-map ROM of the two models (E9: 7 macros per model, 48 rows
of eight 40-bit words), from reports/e9/e9_5/e9_5_summary.json (scripts/e9_5_recost.py, which takes the
numbers from the result files of E9.2 and E9.3c).

(a) tt, 25 C, 1.80 V: the lowest one-cell bit line of each read row (rows 1 to 47; 'bl1_min_V' of the
reads of E9.2) of the 14 macros, against the switching level of the bit-line inverter (vm.txt of E9.2)
and the 0.10-V rule. (b) Margin above the switching level of each condition for the eight weakest words
of the weakest macro of each model (the words E9.2 simulated at fs, 25 C, 1.80 V, at tt, 25 C, 1.60 V and
at fs, -40 C, 1.60 V; at tt, 25 C, 1.80 V the rows of these words in its screen); at fs, -40 C, 1.60 V
only the bit lines are judged. (c) Supply power after the parking read of the first and second macro of
each model (E9.3c): the mean power of the windows of the runs with a 2-ns time step to 11.1 us (the first
three windows, 0.10 to 0.35 us, taken together), of the window 20 to 100 us of the runs with a 500-ns
step, and from 910 to 982 us of the same runs (the settled level); dashed: the level before the first
read (dotted).

Usage: python3 scripts/tvlsi/fig5_rom_margin.py --summary reports/e9/e9_5/e9_5_summary.json --out figures/tvlsi
"""
import argparse
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tvlsi_style as S  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402
from matplotlib.ticker import NullFormatter  # noqa: E402

CONDS = ["tt:25:1.80", "fs:25:1.80", "tt:25:1.60", "fs:-40:1.60"]
CLAB = {"tt:25:1.80": "tt\n25 °C\n1.80 V", "fs:25:1.80": "fs\n25 °C\n1.80 V",
        "tt:25:1.60": "tt\n25 °C\n1.60 V", "fs:-40:1.60": "fs\n−40 °C\n1.60 V"}
COL = {"A": "#b5643b", "B": "#5b2a12"}
WORST = {"A": "A_k1", "B": "B_k0"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary", default="reports/e9/e9_5/e9_5_summary.json")
    ap.add_argument("--out", default="figures/tvlsi")
    a = ap.parse_args()
    d = json.load(open(a.summary, encoding="utf-8"))
    rom, rest = d["rom"], d["rest"]
    vm = rom["vm_V"]
    tt = rom["macros_tt"]
    print("tt: lowest one-cell bit line per macro: " + ", ".join(f"{k} {v['bl1_min_V']:.3f}" for k, v in tt.items()))
    print("smallest margins: " + ", ".join(f"{c} {v:.3f} V" for c, v in rom["smallest_margin_all_V"].items()))

    fig = plt.figure(figsize=(S.COL2, 2.05))
    ax1 = fig.add_axes([0.062, 0.235, 0.255, 0.64])
    ax2 = fig.add_axes([0.388, 0.235, 0.25, 0.64])
    ax3 = fig.add_axes([0.742, 0.235, 0.245, 0.64])

    # (a) every read row of the 14 macros
    for k, v in tt.items():
        M = k[0]
        rows = sorted(v["rows"], key=lambda r: r["row"])
        ax1.scatter([r["row"] for r in rows], [r["bl1_min_V"] for r in rows], s=2.2, color=COL[M], lw=0, alpha=0.85,
                    zorder=3)
    rule = vm["tt:25:1.80"] + 0.10
    ax1.axhline(vm["tt:25:1.80"], color=S.RED, lw=0.8, ls="--")
    ax1.axhline(rule, color=S.RED, lw=0.8, ls=":")
    ax1.text(46.5, rule + 0.012, "0.10-V rule", ha="right", va="bottom", fontsize=S.FS_SMALL, color=S.RED, bbox=S.WHITE)
    ax1.text(46.5, vm["tt:25:1.80"] - 0.012, "switching level", ha="right", va="top", fontsize=S.FS_SMALL,
             color=S.RED, bbox=S.WHITE)
    low = min(tt.values(), key=lambda v: v["bl1_min_V"])
    ax1.set_xlim(0, 48)
    ax1.set_ylim(0.78, 1.86)
    ax1.set_xticks([1, 12, 24, 36, 47])
    ax1.set_xlabel("Read row")
    ax1.set_ylabel("Lowest one-cell bit line (V)")
    S.panel_title(ax1, "(a) 14 macros, tt, 25 °C, 1.80 V")
    ax1.legend(handles=[Line2D([], [], ls="", marker="o", color=COL["A"], ms=2.6, label="Model A, 7 macros"),
                        Line2D([], [], ls="", marker="o", color=COL["B"], ms=2.6, label="Model B, 7 macros")],
               loc="lower left", bbox_to_anchor=(0.0, 0.22), frameon=True, framealpha=1.0, facecolor="white",
               edgecolor="none", handletextpad=0.3)
    S.grid(ax1)
    print(f"(a) lowest {low['bl1_min_V']:.3f} V, margin {low['margin_one_V']:.3f} V")

    # (b) the eight weakest words of the weakest macro of each model at the four conditions
    for j, M in enumerate("AB"):
        words = d["rom"]["conditions"][f"{M} fs:25:1.80"]["per_word"]
        rows_tt = {r["row"]: r["bl1_min_V"] for r in tt[WORST[M]]["rows"]}
        for i, c in enumerate(CONDS):
            if c == "tt:25:1.80":
                vals = [rows_tt[w["row"]] - vm[c] for w in words]
            else:
                vals = [w["margin_V"] for w in d["rom"]["conditions"][f"{M} {c}"]["per_word"]]
            x0 = i - 0.13 + 0.26 * j
            jit = [((n * 0.6180339887) % 1.0 - 0.5) * 0.14 for n in range(len(vals))]
            ax2.scatter([x0 + x for x in jit], vals, s=5, color=COL[M], lw=0, zorder=3)
            print(f"(b) {M} {c}: {min(vals):.3f}-{max(vals):.3f} V")
    for i, c in enumerate(CONDS):
        m = rom["smallest_margin_all_V"][c]
        ax2.text(i, m - 0.018, f"{m:.3f}", ha="center", va="top", fontsize=S.FS_SMALL, color="#333333", bbox=S.WHITE)
    ax2.axhline(0.10, color=S.RED, lw=0.8, ls=":")
    ax2.axhline(0.0, color=S.RED, lw=0.8, ls="--")
    ax2.text(-0.45, 0.10 + 0.010, "0.10-V rule", ha="left", va="bottom", fontsize=S.FS_SMALL, color=S.RED,
             bbox=S.WHITE)
    ax2.set_xticks(range(4))
    ax2.set_xticklabels([CLAB[c] for c in CONDS], fontsize=S.FS_SMALL, linespacing=1.0)
    ax2.set_xlim(-0.55, 3.55)
    ax2.set_ylim(-0.03, 0.66)
    ax2.set_ylabel("Margin (V)")
    S.panel_title(ax2, "(b) Margin at four conditions")
    ax2.legend(handles=[Line2D([], [], ls="", marker="o", color=COL["A"], ms=2.6, label="Model A, macro 1"),
                        Line2D([], [], ls="", marker="o", color=COL["B"], ms=2.6, label="Model B, macro 0")],
               loc="center right", bbox_to_anchor=(1.0, 0.36), fontsize=S.FS_SMALL, frameon=True, framealpha=1.0,
               facecolor="white", edgecolor="none", handletextpad=0.1)
    S.grid(ax2, axis="y")

    # (c) power after the parking read
    style = {"A_k0": ("A", "-"), "B_k0": ("B", "-"), "A_k1": ("A", (0, (3, 1.5))), "B_k1": ("B", (0, (3, 1.5)))}
    for k, (M, ls) in style.items():
        r = rest[k]
        fw = r["fine_windows"]
        e_first = sum(w[2] for w in fw if w[1] <= 350.0 + 1e-6)
        pts = [(math.sqrt(100.0 * 350.0), e_first / 250.0 * 1e3)]
        pts += [(math.sqrt(w[0] * w[1]), w[2] / (w[1] - w[0]) * 1e3) for w in fw if w[0] >= 350.0 - 1e-6]
        pts.append((math.sqrt(10100.0 * 11100.0), r["10.1-11.1us_uW"]))
        pts.append((math.sqrt(20000.0 * 100000.0), r["20-100us_uW"]))
        pts.append((math.sqrt(910000.0 * 982000.0), r["settled_uW"]))
        ax3.plot([t * 1e-3 for t, _ in pts], [p for _, p in pts], color=COL[M], lw=0.9, ls=ls, marker="o", ms=1.8)
        ax3.axhline(r["unread_uW"], color=COL[M], lw=0.6, ls=(0, (1, 1.2)), alpha=0.8)
        print(f"(c) {k}: " + ", ".join(f"{t * 1e-3:.3g} us {p:.3f}" for t, p in pts) + f"; unread {r['unread_uW']:.4f} uW")
    ax3.set_xscale("log")
    ax3.set_yscale("log")
    ax3.set_xlim(0.1, 2000)
    ax3.set_ylim(0.3, 14)
    ax3.set_yticks([0.3, 0.5, 1, 2, 5, 10])
    ax3.set_yticklabels(["0.3", "0.5", "1", "2", "5", "10"])
    ax3.yaxis.set_minor_formatter(NullFormatter())
    ax3.set_xlabel("Time after the parking read (µs)")
    ax3.set_ylabel("Supply power (µW)")
    S.panel_title(ax3, "(c) Parked macro, tt, 25 °C")
    ax3.legend(handles=[Line2D([], [], color="#444444", lw=0.9, marker="o", ms=1.6, label="macro 0, after a lookup"),
                        Line2D([], [], color="#444444", lw=0.9, marker="o", ms=1.6, ls=(0, (3, 1.5)),
                               label="macro 1, after its last lookup"),
                        Line2D([], [], color="#444444", lw=0.6, ls=(0, (1, 1.5)), label="before the first read")],
               loc="upper right", frameon=True, framealpha=1.0, facecolor="white", edgecolor="none",
               handletextpad=0.3)
    S.grid(ax3)
    S.save(fig, a.out, "fig5_rom_margin")


if __name__ == "__main__":
    main()
