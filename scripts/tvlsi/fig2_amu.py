#!/usr/bin/env python3
"""Fig. 2 of the TVLSI manuscript: the address-map unit (AMU) of the map of E9.

The five parts of the AMU as in rtl/e9/amu9_top.v: the shared entry computation and the per-lane check
(rtl/e8/amu_entry.v, amu_lanes.v: 24 comparators, lanes 1 to 24), the entry buffer (8 slots of 37 bit:
the 25 assignment bits and the 12-bit count of an entry), the controller with the ROM read and parking
sequence (amu9_core.v; 7 macros on one address bus, a clock and a chip select each) and the slot decoder
(amu9_decode.v: prefix counts of the protected lanes). The read timing that the sequencer drives (macro
clock low for at least 90 ns before a lookup read, chip select 10 ns after the rising edge, word sampled
40 ns after it) is given in the text.

Usage: python3 scripts/tvlsi/fig2_amu.py --out figures/tvlsi
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tvlsi_style as S  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="figures/tvlsi")
    a = ap.parse_args()
    fsm = S.FS_SMALL
    W, H = S.COL1, 1.72
    fig = plt.figure(figsize=(W, H))
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, W)
    ax.set_ylim(0, H)
    ax.axis("off")
    bw, bh = 1.02, 0.36
    cx = [0.58, 1.75, 2.92]
    ry = [1.52, 0.90, 0.28]
    S.box(ax, cx[0], ry[0], bw, bh, "datapath: layer,\n25 weight indices", S.N_EDGE, S.N_FILL, fs=fsm)
    S.box(ax, cx[1], ry[0], bw, bh, "1 shared entry\ncomputation", S.R_EDGE, S.R_FILL, fs=fsm)
    S.box(ax, cx[2], ry[0], bw, bh, "2 per-lane check\n(24 comparators)", S.R_EDGE, S.R_FILL, fs=fsm)
    S.box(ax, cx[1], ry[1], bw, bh, "3 entry buffer,\n8 slots × 37 bit", S.R_EDGE, S.R_FILL, fs=fsm)
    S.box(ax, cx[0], ry[1], bw, bh, "4 sequencer:\nread, park", S.R_EDGE, S.R_FILL, fs=fsm)
    S.box(ax, cx[2], ry[1], bw, bh, "5 slot decoder,\nprefix counts", S.R_EDGE, S.R_FILL, fs=fsm)
    S.box(ax, cx[2], ry[2], bw, bh, "to datapath: hit and\nslot of 25 lanes", S.N_EDGE, S.N_FILL, fs=fsm)
    S.box(ax, (cx[0] + cx[1]) / 2, ry[2], bw + 0.55, bh, "7 ROM macros, 48 rows ×\n8 words × 40 bit", S.RM_EDGE,
          S.RM_FILL, fs=fsm)
    hw, hh = bw / 2, bh / 2
    S.arrow(ax, cx[0] + hw, ry[0], cx[1] - hw, ry[0], ms=5)
    S.arrow(ax, cx[1] + hw, ry[0], cx[2] - hw, ry[0], ms=5)
    S.arrow(ax, cx[1], ry[0] - hh, cx[1], ry[1] + hh, ms=5)
    ax.text(cx[1] + 0.05, (ry[0] + ry[1]) / 2, "entry", ha="left", va="center", fontsize=fsm)
    S.arrow(ax, cx[2], ry[0] - hh, cx[2], ry[1] + hh, ms=5)
    ax.text(cx[2] + 0.05, (ry[0] + ry[1]) / 2, "valid", ha="left", va="center", fontsize=fsm)
    S.arrow(ax, cx[1] + hw, ry[1], cx[2] - hw, ry[1], ms=5)
    S.arrow(ax, cx[1] - hw, ry[1], cx[0] + hw, ry[1], ms=5)
    S.arrow(ax, cx[2], ry[1] - hh, cx[2], ry[2] + hh, ms=5)
    S.arrow(ax, cx[0], ry[1] - hh, cx[0], ry[2] + hh, ms=5)
    ax.text(cx[0] + 0.05, (ry[1] + ry[2]) / 2, "address,\nclock, select", ha="left", va="center", fontsize=fsm,
            linespacing=1.0)
    S.arrow(ax, cx[1] + 0.25, ry[2] + hh, cx[1] + 0.25, ry[1] - hh, ms=5)
    ax.text(cx[1] + 0.30, (ry[1] + ry[2]) / 2, "word", ha="left", va="center", fontsize=fsm)
    S.save(fig, a.out, "fig2_amu")


if __name__ == "__main__":
    main()
