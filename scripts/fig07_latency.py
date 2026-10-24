#!/usr/bin/env python3
"""Fig. 7: inference latency against the two datapath parameters.

The analytical model is the FSM-grounded model of figure4new.py (2026-06-25):
per output, a convolution needs ceil(field / K) passes of K + L + 5 cycles plus
3 cycles, and a fully connected neuron ceil(fan-in / K) passes of L + 6 cycles;
the layer-independent remainder is calibrated once so that the model returns
the measured 617,573 cycles at K = 25, L = 8. The number of datapath steps at
K = 25 (16,684) equals the count in the full-inference trace
reports/e8_rom/trace/e8_2_ops_A.csv, which the script checks.

The earlier figure (fig6new_latency.py) plotted hand-entered values; this
script plots the model output itself (equation (10)). The model
curve is drawn in a neutral color, the operating point in the green used for
the as-built design in Fig. 13.

Usage: python3 scripts/fig07_latency.py --paper2 . --out figures
"""
import argparse
import csv
import math
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

LAYERS = [("conv", 25, 4704), ("conv", 150, 1600),
          ("fc", 400, 120), ("fc", 120, 84), ("fc", 84, 10)]
RTL_TOTAL = 617573
NS_PER_CYCLE = 10.0

CURVE, PICK, MINC, PTS = "#3a3a3a", "#1f7a4a", "#111111", "#3a3a3a"
WHITE = dict(boxstyle="square,pad=0.12", fc="white", ec="none")   # text over the gridlines

plt.rcParams.update({
    "mathtext.fontset": "custom", "mathtext.rm": "Liberation Sans", "mathtext.it": "Liberation Sans:italic",
    "mathtext.bf": "Liberation Sans:bold",
    "font.family": "Liberation Sans", "font.size": 15, "axes.labelsize": 15,
    "xtick.labelsize": 14, "ytick.labelsize": 14, "axes.linewidth": 1.0,
    "pdf.fonttype": 42,
})


def per_output(kind, field, K, L):
    passes = math.ceil(field / K)
    return passes * (K + L + 5) + 3 if kind == "conv" else passes * (L + 6)


def active(K, L):
    return sum(n * per_output(k, f, K, L) for (k, f, n) in LAYERS)


FIXED = RTL_TOTAL - active(25, 8)


def total(K, L):
    return active(K, L) + FIXED


def steps(K):
    return sum(n * math.ceil(f / K) for (_, f, n) in LAYERS)


def check_trace(paper2):
    path = os.path.join(paper2, "reports", "e8_rom", "trace", "e8_2_ops_A.csv")
    with open(path) as fh:
        n = sum(1 for _ in csv.DictReader(fh))
    assert n == steps(25), (n, steps(25))
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".")
    ap.add_argument("--out", default="figures")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    n_trace = check_trace(a.paper2)

    ks = list(range(5, 51))
    tk = [total(k, 8) for k in ks]
    kmin = min(ks, key=lambda k: total(k, 8))
    marked_k = [9, 16, 25, 36, 49]
    ls = list(range(2, 17))
    tl = [total(25, L) for L in ls]
    marked_l = [4, 8, 12, 16]

    print("FIXED", FIXED, "steps(25)", steps(25), "trace", n_trace)
    for k in marked_k + [kmin]:
        print(f"K={k:2d} L=8  {total(k, 8):9,d}  {100 * (total(k, 8) / RTL_TOTAL - 1):+6.2f} %")
    for L in marked_l:
        print(f"K=25 L={L:2d} {total(25, L):9,d}")
    print(f"T(25,16)/T(25,4) = {total(25, 16) / total(25, 4):.4f}; slope {steps(25)} cycles per cycle of L")
    print(f"share of array waits L+3 at L=8: {steps(25) * 11 / RTL_TOTAL:.4f}; of L alone: {steps(25) * 8 / RTL_TOTAL:.4f}")

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(6.5, 9.0), gridspec_kw={"hspace": 0.42})
    m = 1e6
    ax1.plot(ks, [t / m for t in tk], "-", color=CURVE, lw=1.6, zorder=2)
    ax1.plot(ks, [t / m for t in tk], "o", color=CURVE, ms=2.8, zorder=3)
    ax1.plot(marked_k, [total(k, 8) / m for k in marked_k], "o", color=PTS, ms=7, mfc="white", mew=1.8, zorder=4)
    ax1.plot([25], [total(25, 8) / m], "o", color=PICK, ms=12, zorder=5)
    ax1.plot([kmin], [total(kmin, 8) / m], "D", color=MINC, ms=8, zorder=5)
    ax1.text(23.4, 0.665, "operating point, 25\n617,573 cycles", ha="right", va="center",
             fontsize=13, color=PICK, bbox=WHITE)
    ax1.annotate(f"model minimum, {kmin}\n{total(kmin, 8):,} cycles", xy=(kmin, total(kmin, 8) / m),
                 xytext=(33.5, 0.86), fontsize=13, color=MINC, bbox=WHITE,
                 arrowprops=dict(arrowstyle="->", color=MINC, lw=1.3))
    ax1.set_xlabel("Operations per pass")
    ax1.set_ylabel("Latency (10$^6$ cycles)")
    ax1.set_xlim(4, 51)
    ax1.set_ylim(0.55, 1.75)
    ax1.set_xticks([5, 9, 16, 25, 30, 36, 49])
    ax1.grid(True, color="#dddddd", lw=0.7)
    ax1.set_axisbelow(True)
    ax1.set_title("(a) Operations per pass, read latency 8 cycles", loc="left", fontsize=15, fontweight="bold")

    ax2.plot(ls, [t / m for t in tl], "-", color=CURVE, lw=1.6)
    ax2.plot(marked_l, [total(25, L) / m for L in marked_l], "o", color=PTS, ms=7, mfc="white", mew=1.8)
    ax2.plot([8], [total(25, 8) / m], "o", color=PICK, ms=12, zorder=5)
    ax2.annotate("operating point, 8", xy=(8, total(25, 8) / m), xytext=(9.3, 0.57), fontsize=13, color=PICK,
                 bbox=WHITE, arrowprops=dict(arrowstyle="->", color=PICK, lw=1.3))
    ax2.text(2.4, 0.735, f"+{steps(25):,} cycles per cycle\nof read latency", fontsize=13, color="#333333",
             va="top", bbox=WHITE)
    ax2.set_xlabel("PCM array read latency (cycles)")
    ax2.set_ylabel("Latency (10$^6$ cycles)")
    ax2.set_xlim(1.5, 16.5)
    ax2.set_ylim(0.50, 0.78)
    ax2.set_xticks([2, 4, 6, 8, 10, 12, 14, 16])
    ax2.grid(True, color="#dddddd", lw=0.7)
    ax2.set_axisbelow(True)
    ax2.set_title("(b) Array read latency, 25 operations per pass", loc="left", fontsize=15, fontweight="bold")

    for ax in (ax1, ax2):
        ax.secondary_yaxis("right", functions=(lambda c: c * NS_PER_CYCLE, lambda t: t / NS_PER_CYCLE))
    fig.subplots_adjust(left=0.13, right=0.86, top=0.95, bottom=0.07)
    fig.align_ylabels([ax1, ax2])
    for ax in (ax1, ax2):   # right-hand labels at one x, although their tick labels differ in width
        pos = ax.get_position()
        fig.text(0.95, (pos.y0 + pos.y1) / 2, "Time at a 10-ns clock (ms)", rotation=90, ha="center", va="center",
                 fontsize=15)
    for ext in ("png", "pdf"):
        fig.savefig(os.path.join(a.out, "fig07_latency." + ext), dpi=300)
    plt.close(fig)


if __name__ == "__main__":
    main()
