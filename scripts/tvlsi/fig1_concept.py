#!/usr/bin/env python3
"""Fig. 1 of the TVLSI manuscript: why a fixed PCM crossbar cannot host the
layer-aware allocation in place (a), and the hybrid datapath that realizes it (b).

Drawn at the full page width (7.16 in); one axis unit is one inch. The blocks
follow the RTL: the address map (the address-map unit of rtl/e9 and one word
per entry in 7 ROM macros) gives, for each operand, the assignment bit b_a and
the slot;
a protected weight is read as an exact INT8 value from the SRAM partition,
25 single-port banks interleaved by slot, and multiplied in the digital datapath; an
unprotected weight takes part in the analog multiply-accumulate of the
crossbar, whose cells at protected positions are left in the RESET state, and
the 5-bit ADC reads the addressed column; the two partial sums meet in the
24-bit combiner and are accumulated with the bias in 32 bits
(rtl/src/combiner.v, conv_engine.v, fc_engine.v).

Usage: python3 scripts/tvlsi/fig1_concept.py --out figures/tvlsi
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tvlsi_style as S  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import Circle, Polygon  # noqa: E402

W, H = S.COL2, 2.3
GRY = "#8a8a8a"


def crossbar(ax, x0, y0, pitch, n, protected, vacated, r_cell, label_rows=True):
    """n x n crossbar with its top-left cell at (x0, y0); returns cell centers and the bottom of the columns."""
    xs = [x0 + i * pitch for i in range(n)]
    ys = [y0 - j * pitch for j in range(n)]
    left, right = x0 - 0.55 * pitch, xs[-1] + 0.35 * pitch
    top, bottom = y0 + 0.4 * pitch, ys[-1] - 0.55 * pitch
    for y in ys:
        ax.plot([left, right], [y, y], color=GRY, lw=0.6, zorder=1)
        if label_rows:
            ax.add_patch(Polygon([[left - 0.07, y + 0.035], [left - 0.07, y - 0.035], [left - 0.005, y]],
                                 closed=True, fc=S.P_EDGE, ec="none", zorder=2))
    for x in xs:
        ax.plot([x, x], [top, bottom], color=GRY, lw=0.6, zorder=1)
    for j, y in enumerate(ys):
        for i, x in enumerate(xs):
            if (i, j) in protected:
                if vacated:
                    ax.add_patch(Circle((x, y), r_cell, fc="white", ec=GRY, lw=0.8, ls=(0, (1.5, 1)), zorder=3))
                else:
                    d = r_cell * 1.35
                    ax.add_patch(Polygon([[x, y + d], [x + d, y], [x, y - d], [x - d, y]], closed=True,
                                         fc=S.GOLD, ec=S.GOLD_D, lw=0.7, zorder=3))
            else:
                ax.add_patch(Circle((x, y), r_cell, fc=S.P_FILL, ec=S.P_EDGE, lw=0.6, zorder=3))
    return xs, ys, left, bottom


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="figures/tvlsi")
    a = ap.parse_args()
    fig = plt.figure(figsize=(W, H))
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, W)
    ax.set_ylim(0, H)
    ax.axis("off")
    fs, fsm = S.FS, S.FS_SMALL

    # ---------------- (a) ----------------
    ax.text(0.04, H - 0.05, "(a) A fixed PCM crossbar", ha="left", va="top", fontsize=fs, fontweight="bold")
    prot = {(1, 0), (3, 1), (0, 3), (2, 4)}
    xs, ys, left, bottom = crossbar(ax, 0.42, 1.74, 0.215, 5, prot, False, 0.05)
    ax.text(0.04, 1.93, "activations $x_i$", ha="left", va="bottom", fontsize=fsm, color=S.P_EDGE)
    cx = xs[3]
    # the column read by the converter: the drifting current of the sensitive weight flows into its sum
    S.arrow(ax, cx, ys[1] - 0.07, cx, bottom - 0.01, color=S.GOLD_D, lw=1.3, ms=6)
    S.box(ax, cx, 0.22, 0.80, 0.26, "5-bit ADC", S.P_EDGE, S.P_FILL, fs=fs)
    S.arrow(ax, cx, bottom - 0.04, cx, 0.35, color=S.P_EDGE, lw=0.9, ms=6)
    ax.text(cx + 0.06, 0.53, "column current $\\Sigma_i\\,G_i x_i$", ha="left", va="center", fontsize=fsm,
            color=S.P_EDGE)
    ax.plot([xs[3] + 0.065, 1.53], [ys[1] + 0.005, 1.50], color=S.GOLD_D, lw=0.6, ls=(0, (2, 1.5)))
    ax.text(1.55, 1.52, "drift-sensitive\nweights", ha="left", va="center", fontsize=fsm, color=S.GOLD_D,
            fontweight="bold", linespacing=1.2)
    ax.text(1.55, 1.04, "drift in place;\ntheir currents\nmerge into the\ncolumn sum", ha="left", va="center",
            fontsize=fsm, color=S.INK, linespacing=1.15)
    ax.plot([2.47, 2.47], [0.08, H - 0.08], color="#d0d0d0", lw=0.8)

    # ---------------- (b) ----------------
    x0b = 2.6
    ax.text(x0b, H - 0.05, "(b) Hybrid datapath of this work", ha="left", va="top", fontsize=fs,
            fontweight="bold")
    # address-map unit
    S.box(ax, 3.12, 1.15, 0.98, 0.66, "address map\n(AMU and\n7 ROM macros)", S.R_EDGE, S.R_FILL, fs=fs)
    S.arrow(ax, 3.12, 1.86, 3.12, 1.48, lw=0.9, ms=6)
    ax.text(3.12, 1.89, "weight index $a$", ha="center", va="bottom", fontsize=fsm)
    # SRAM path (upper row)
    S.box(ax, 4.45, 1.62, 0.96, 0.46, "SRAM, 25 banks\nexact INT8 $w_a$", S.T_EDGE, S.T_FILL, fs=fs)
    S.box(ax, 5.30, 1.62, 0.46, 0.46, "$w_a x_a$", S.G_EDGE, S.G_FILL, fs=fs)
    S.arrow(ax, 4.93, 1.62, 5.07, 1.62, lw=0.9, ms=6)
    S.arrow(ax, 3.61, 1.33, 3.97, 1.55, color=S.T_EDGE, lw=0.9, ms=6)
    ax.text(3.74, 1.49, "$b_a=1$", ha="right", va="bottom", fontsize=fsm, color=S.T_EDGE)
    # PCM path (lower row)
    prot_b = {(1, 0), (3, 1), (0, 3)}
    xs2, ys2, left2, bottom2 = crossbar(ax, 4.13, 0.98, 0.16, 4, prot_b, True, 0.043, label_rows=False)
    ybus = bottom2 - 0.02
    # the addressed column, read by the converter
    ax.plot([xs2[-1], xs2[-1]], [ys2[0] + 0.4 * 0.16, ybus], color=S.P_EDGE, lw=1.3, zorder=2)
    ax.text(xs2[-1] + 0.12, 0.79, "PCM\ncrossbar", ha="left", va="center", fontsize=fsm, color=S.P_EDGE,
            linespacing=1.05)
    S.arrow(ax, 3.61, 0.97, 3.93, 0.84, color=S.P_EDGE, lw=0.9, ms=6)
    ax.text(3.70, 0.82, "$b_a=0$", ha="right", va="top", fontsize=fsm, color=S.P_EDGE)
    S.box(ax, 5.30, ybus, 0.60, 0.28, "5-bit ADC", S.P_EDGE, S.P_FILL, fs=fsm)
    S.arrow(ax, xs2[-1] - 0.006, ybus, 5.0, ybus, color=S.P_EDGE, lw=0.9, ms=6)
    ax.text(3.97, 0.15, "cells of protected weights in RESET", ha="left", va="center", fontsize=fsm,
            color="#6d6d6d")
    ax.plot([xs2[0] + 0.03, xs2[0] + 0.20], [ys2[3] - 0.04, 0.22], color="#6d6d6d", lw=0.5)
    # combiner, accumulator, requantization
    S.box(ax, 6.70, 1.62, 0.78, 0.40, "combiner", S.G_EDGE, S.G_FILL, fs=fsm)
    S.box(ax, 6.70, 1.04, 0.78, 0.40, "accumulator\nwith bias", S.G_EDGE, S.G_FILL, fs=fsm)
    S.box(ax, 6.70, 0.46, 0.78, 0.40, "requantize,\nReLU", S.G_EDGE, S.G_FILL, fs=fsm)
    S.arrow(ax, 5.53, 1.70, 6.31, 1.70, lw=0.9, ms=6)
    ax.text(5.92, 1.73, "exact", ha="center", va="bottom", fontsize=fsm, color=S.G_EDGE)
    ax.plot([5.60, 6.05, 6.05], [ybus, ybus, 1.54], color=S.P_EDGE, lw=0.9)
    S.arrow(ax, 6.05, 1.54, 6.31, 1.54, color=S.P_EDGE, lw=0.9, ms=6)
    ax.text(6.0, 0.95, "analog\npartial\nsum", ha="right", va="center", fontsize=fsm, color=S.P_EDGE,
            linespacing=1.0)
    S.arrow(ax, 6.70, 1.42, 6.70, 1.24, lw=0.9, ms=6)
    S.arrow(ax, 6.70, 0.84, 6.70, 0.66, lw=0.9, ms=6)
    S.save(fig, a.out, "fig1_concept")


if __name__ == "__main__":
    main()
