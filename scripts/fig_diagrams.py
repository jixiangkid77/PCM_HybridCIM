#!/usr/bin/env python3
"""Diagram figures: Fig. 2 (top-level datapath with the AMU), Fig. 3
(entries per table), Fig. 4 (address-map unit and ROM read timing), Fig. 5
(the two studies). Canvas 6.5 in wide.

In Fig. 2 the address-map unit routes each operand (the table that hits
gives the medium, one bit per weight, and the slot), the SRAM and PCM partial
sums meet in the 24-bit combiner and the layer accumulator is 32-bit, as in
rtl/src/combiner.v and conv_engine.v / fc_engine.v; in Fig. 4 the per-lane
check has 24 comparators (lanes 1 to 24, rtl/e8/amu_lanes.v); file names carry
two-digit figure numbers. Colors: green digital logic, teal the SRAM partition,
purple the analog crossbar, rust the address map (Fig. 4 is the address-map
unit, so its blocks are rust: logic light, ROM macros darker), gray the
datapath interface.

Usage: python3 scripts/fig_diagrams.py --out DIR
"""
import argparse
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker
from matplotlib.patches import FancyBboxPatch

G_EDGE, G_FILL = "#2e7d32", "#e3efe3"     # digital logic
T_EDGE, T_FILL = "#2a6f7d", "#dcebee"     # SRAM partition
P_EDGE, P_FILL = "#6a1b9a", "#ece0f3"     # analog crossbar
N_EDGE, N_FILL = "#888888", "#e8e8e8"     # neutral
R_EDGE, R_FILL = "#b5643b", "#f6e6dc"     # address map (rust, as in Figs. 8 to 14)
RM_EDGE, RM_FILL = "#7a3b1d", "#e9c2a6"   # address-map ROM macros
ARROW = "#333333"

plt.rcParams.update({"font.family": "Liberation Sans", "font.size": 15, "pdf.fonttype": 42,
                     "mathtext.fontset": "custom", "mathtext.rm": "Liberation Sans",
                     "mathtext.it": "Liberation Sans:italic", "mathtext.bf": "Liberation Sans:bold"})


def box(ax, x, y, w, h, text, edge, fill, fs=15, lw=2.4, color="black"):
    ax.add_patch(FancyBboxPatch((x - w / 2, y - h / 2), w, h, boxstyle="round,pad=0.0,rounding_size=0.12",
                                ec=edge, fc=fill, lw=lw))
    ax.text(x, y, text, ha="center", va="center", fontsize=fs, color=color, linespacing=1.15)


def arrow(ax, x0, y0, x1, y1, color=ARROW, lw=2.2, style="-|>", ms=16):
    ax.annotate("", xy=(x1, y1), xytext=(x0, y0),
                arrowprops=dict(arrowstyle=style, color=color, lw=lw, mutation_scale=ms, shrinkA=0, shrinkB=0))


def save(fig, out, name):
    for ext in ("png", "pdf"):
        fig.savefig(os.path.join(out, name + "." + ext), dpi=300)
    plt.close(fig)


def fig2(out):
    fig, ax = plt.subplots(figsize=(6.5, 8.75))
    ax.set_xlim(0, 10)
    ax.set_ylim(0.3, 13.2)
    ax.axis("off")
    box(ax, 5.0, 12.55, 3.6, 0.9, "operand", N_EDGE, N_FILL)
    arrow(ax, 5.0, 12.1, 5.0, 11.62)
    box(ax, 5.0, 10.5, 6.2, 2.2, "address-map unit\n50 tables in 200 ROM macros:\nthe table that hits gives the medium\n(one bit per weight) and the slot",
        R_EDGE, R_FILL, fs=13.5)
    box(ax, 1.95, 7.55, 3.7, 1.8, "SRAM partition\n(exact INT8;\nconv1 in a\nregister cache)", T_EDGE, T_FILL, fs=13.5)
    box(ax, 8.05, 7.55, 3.7, 1.8, "PCM crossbar\n(5-bit ADC)", P_EDGE, P_FILL)
    arrow(ax, 3.3, 9.4, 1.95, 8.47)
    ax.text(2.35, 9.2, "protected", fontsize=13, color=T_EDGE, ha="right", va="center")
    arrow(ax, 6.7, 9.4, 8.05, 8.47)
    ax.text(7.65, 9.2, "unprotected", fontsize=13, color=P_EDGE, ha="left", va="center")
    # merge
    ax.plot([1.95, 1.95], [6.65, 6.2], color=ARROW, lw=2.2)
    ax.plot([8.05, 8.05], [6.65, 6.2], color=ARROW, lw=2.2)
    ax.plot([1.95, 8.05], [6.2, 6.2], color=ARROW, lw=2.2)
    arrow(ax, 5.0, 6.2, 5.0, 5.82)
    box(ax, 5.0, 5.35, 5.6, 0.92, "24-bit combiner (SRAM + PCM)", G_EDGE, G_FILL, fs=14)
    arrow(ax, 5.0, 4.89, 5.0, 4.45)
    box(ax, 5.0, 3.92, 5.6, 1.05, "32-bit accumulator\nover the passes, with the bias", G_EDGE, G_FILL, fs=14)
    arrow(ax, 5.0, 3.39, 5.0, 2.93)
    box(ax, 5.0, 2.45, 5.6, 0.92, "requantize + ReLU", G_EDGE, G_FILL)
    arrow(ax, 5.0, 1.99, 5.0, 1.55)
    box(ax, 5.0, 1.08, 3.6, 0.9, "writeback", G_EDGE, G_FILL)
    fig.subplots_adjust(left=0.01, right=0.99, top=0.99, bottom=0.01)
    save(fig, out, "fig02_datapath")


def fig3(out):
    layers = ["conv1", "conv2", "fc1", "fc2", "fc3"]
    vals = [6, 96, 1920, 420, 40]
    fig, ax = plt.subplots(figsize=(6.5, 3.6))
    ax.bar(layers, vals, 0.62, color=R_FILL, edgecolor=R_EDGE, lw=2.0)
    for i, v in enumerate(vals):
        ax.text(i, v + 35, f"{v:,}", ha="center", va="bottom", fontsize=14)
    ax.text(-0.3, 1960, "2,482 entries per\ntable in total\n(61,470 for a\nflat table)", ha="left", va="top",
            fontsize=13, bbox=dict(boxstyle="round,pad=0.35", fc="white", ec="#999999"))
    ax.set_ylabel("Entries per table")
    ax.set_xlabel("Layer")
    ax.set_ylim(0, 2150)
    ax.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda x, p: f"{int(x):,}"))
    ax.grid(axis="y", color="#cccccc", lw=0.8, ls=":")
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    fig.subplots_adjust(left=0.15, right=0.98, top=0.97, bottom=0.2)
    save(fig, out, "fig03_mapping")


def fig4(out):
    fig = plt.figure(figsize=(6.5, 9.4))
    ax = fig.add_axes([0.01, 0.40, 0.98, 0.59])
    ax.set_xlim(0, 10)
    ax.set_ylim(0, 10)
    ax.axis("off")
    ax.text(0.05, 9.85, "(a) Address-map unit", fontsize=15, fontweight="bold", va="top")
    # datapath side
    box(ax, 1.55, 7.6, 2.8, 1.25, "datapath:\nlayer, lane-0 index,\n25 lane indices", N_EDGE, N_FILL, fs=13)
    box(ax, 5.0, 7.6, 3.2, 1.25, "1 shared entry\ncomputation", R_EDGE, R_FILL, fs=13)
    box(ax, 8.45, 7.6, 2.8, 1.25, "2 per-lane check\n(24 comparators)", R_EDGE, R_FILL, fs=13)
    box(ax, 5.0, 5.15, 3.2, 1.35, "3 entry buffer\n8 slots × 800 bit\nearly reads", R_EDGE, R_FILL, fs=13)
    box(ax, 1.55, 5.15, 2.8, 1.35, "4 ROM sequencer\nclock, CS, address", R_EDGE, R_FILL, fs=13)
    box(ax, 1.55, 2.55, 2.8, 1.35, "5 parking flags\none per macro", R_EDGE, R_FILL, fs=13)
    box(ax, 5.0, 2.55, 3.2, 1.35, "200 ROM macros\n50 tables × 4,\n48 rows each", RM_EDGE, RM_FILL, fs=13)
    box(ax, 8.45, 4.0, 2.8, 1.35, "to datapath:\nhit and slot of\n50 lookups", N_EDGE, N_FILL, fs=13)
    arrow(ax, 2.95, 7.6, 3.4, 7.6)
    ax.annotate("", xy=(8.45, 8.23), xytext=(1.55, 8.23),
                arrowprops=dict(arrowstyle="-|>", color=ARROW, lw=1.6, mutation_scale=14,
                                connectionstyle="arc3,rad=-0.18", shrinkA=0, shrinkB=0))
    ax.text(5.0, 9.05, "lane indices", fontsize=13, ha="center", va="bottom")
    arrow(ax, 5.0, 6.97, 5.0, 5.83)
    ax.text(5.15, 6.4, "entry, tag", fontsize=13, va="center")
    arrow(ax, 6.6, 7.6, 7.05, 7.6)
    arrow(ax, 6.6, 5.15, 7.05, 4.35)
    ax.text(6.95, 5.15, "words", fontsize=13, va="center")
    arrow(ax, 8.45, 6.97, 8.45, 4.68)
    arrow(ax, 3.4, 5.15, 2.95, 5.15)
    ax.annotate("", xy=(3.4, 2.75), xytext=(2.25, 4.47),
                arrowprops=dict(arrowstyle="-|>", color=ARROW, lw=1.8, mutation_scale=14, shrinkA=0, shrinkB=0))
    arrow(ax, 5.0, 3.23, 5.0, 4.47)
    ax.text(5.15, 3.85, "word", fontsize=13, va="center")
    ax.annotate("", xy=(1.55, 4.47), xytext=(1.55, 3.23),
                arrowprops=dict(arrowstyle="<|-|>", color=ARROW, lw=1.6, mutation_scale=14, shrinkA=0, shrinkB=0))
    ax.text(1.72, 3.85, "park", fontsize=13, va="center")
    ax.text(0.15, 0.95, "The AMU reads each entry ahead of use; the datapath start is never held.", fontsize=13,
            color="#444444")

    # (b) ROM read timing, T1
    bx = fig.add_axes([0.235, 0.055, 0.74, 0.30])
    fig.text(0.01, 0.375, "(b) ROM read timing", fontsize=15, fontweight="bold", va="bottom")
    t0, t1 = -100, 60
    rows = [("system clock", 6.0), ("macro clock", 4.5), ("address", 3.0), ("chip select", 1.5), ("data", 0.0)]
    for name, y in rows:
        bx.text(t0 - 3, y + 0.35, name, ha="right", va="center", fontsize=13)
    # system clock, 10-ns period
    xs, ys = [], []
    for k in range(-10, 6):
        a = k * 10
        xs += [a, a, a + 5, a + 5]
        ys += [6.0, 6.7, 6.7, 6.0]
    bx.plot(xs, ys, color="#666666", lw=1.2)
    # macro clock: low for 90 ns (precharge), high 50 ns from the edge at t = 0
    bx.plot([t0, 0, 0, 50, 50, t1], [4.5, 4.5, 5.2, 5.2, 4.5, 4.5], color=R_EDGE, lw=2.2)
    bx.annotate("", xy=(-90, 4.25), xytext=(0, 4.25), arrowprops=dict(arrowstyle="<->", color="#444444", lw=1.2))
    bx.text(-45, 4.02, "low ≥ 90 ns: precharge", ha="center", va="top", fontsize=13)
    # address: valid from 10 ns before the edge
    bx.plot([t0, -10], [3.35, 3.35], color="#999999", lw=1.4)
    bx.fill_between([-10, 50], 3.0, 3.7, color=R_FILL, ec=R_EDGE, lw=1.6)
    bx.text(20, 3.35, "address valid", ha="center", va="center", fontsize=13)
    # chip select: rises 10 ns after the edge
    bx.plot([t0, 10, 10, 50, 50, t1], [1.5, 1.5, 2.2, 2.2, 1.5, 1.5], color=R_EDGE, lw=2.2)
    bx.annotate("", xy=(0, 2.45), xytext=(10, 2.45), arrowprops=dict(arrowstyle="<->", color="#444444", lw=1.2))
    bx.text(-1.5, 2.45, "10 ns", ha="right", va="center", fontsize=13)
    # data: valid at most 21.4 ns after the edge (slowest read at fs, 25 C, 1.80 V), sampled at 40 ns
    bx.plot([t0, 21.4], [0.35, 0.35], color="#999999", lw=1.4)
    bx.fill_between([21.4, 50], 0.0, 0.7, color=RM_FILL, ec=RM_EDGE, lw=1.6)
    bx.text(30.0, 0.35, "word", ha="center", va="center", fontsize=13)
    bx.plot([40, 40], [-0.35, 7.05], color="#555555", lw=1.2, ls=(0, (3, 2)))
    bx.text(40, 7.15, "sample, 40 ns", ha="center", va="bottom", fontsize=13)
    bx.text(18.5, -0.45, "≤ 21.4 ns", ha="center", va="top", fontsize=13)
    bx.set_xlim(t0, t1)
    bx.set_ylim(-1.4, 8.0)
    bx.set_yticks([])
    for s in ("left", "right", "top"):
        bx.spines[s].set_visible(False)
    bx.set_xticks([-100, -80, -60, -40, -20, 0, 20, 40, 60])
    bx.set_xlabel("Time from the rising edge of the macro clock (ns)", fontsize=14)
    bx.tick_params(labelsize=13)
    save(fig, out, "fig04_amu")


def fig5(out):
    fig, ax = plt.subplots(figsize=(6.5, 6.9))
    ax.set_xlim(0, 10)
    ax.set_ylim(1.15, 11.6)
    ax.axis("off")
    PE, PF = "#6a4c9c", "#e9e1f2"
    box(ax, 5.0, 10.6, 5.0, 1.3, "trained network\n+ protection map", "#888888", "#e6e6e6", fs=15)
    ax.plot([5.0, 5.0], [9.95, 9.45], color=ARROW, lw=3)
    ax.plot([2.55, 7.45], [9.45, 9.45], color=ARROW, lw=3)
    arrow(ax, 2.55, 9.45, 2.55, 8.9, lw=3)
    arrow(ax, 7.45, 9.45, 7.45, 8.9, lw=3)
    box(ax, 2.55, 8.15, 4.3, 1.4, "behavioral\nIMC model", PE, PF, lw=3)
    box(ax, 2.55, 5.65, 4.3, 1.4, "LeNet-5\nResNet-50", PE, PF, lw=3)
    box(ax, 2.55, 3.15, 4.3, 1.4, "accuracy\nunder drift", PE, PF, lw=3)
    box(ax, 7.45, 8.15, 4.3, 1.4, "RTL (Verilog),\nverified bit for bit", G_EDGE, G_FILL, lw=3)
    box(ax, 7.45, 5.65, 4.3, 1.4, "logic: gate level\nmemories: post-layout", G_EDGE, G_FILL, lw=3)
    box(ax, 7.45, 3.15, 4.3, 1.4, "latency, area\nand energy", G_EDGE, G_FILL, lw=3)
    for x in (2.55, 7.45):
        arrow(ax, x, 7.45, x, 6.38, lw=3)
        arrow(ax, x, 4.95, x, 3.88, lw=3)
    ax.text(2.55, 1.9, "Accuracy study\n(Section IV)", ha="center", va="center", fontsize=14, style="italic", color=PE)
    ax.text(7.45, 1.9, "Hardware study\n(Section V)", ha="center", va="center", fontsize=14, style="italic", color=G_EDGE)
    fig.subplots_adjust(left=0.01, right=0.99, top=0.99, bottom=0.01)
    save(fig, out, "fig05_studies")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    fig2(a.out)
    fig3(a.out)
    fig4(a.out)
    fig5(a.out)


if __name__ == "__main__":
    main()
