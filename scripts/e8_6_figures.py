#!/usr/bin/env python3
"""Figures 13 and 14 from reports/e8_6/e8_6_summary.json.

Fig. 13: area against the protection budget (model A). Fig. 14: per-inference
energy of the two models. Colors and panel titles as in the other figures,
legend below; canvas 6.5 in wide with 13-15 pt text for Word. In Fig. 14 the
four parts and the breakdown of (b) have separate legends.

Usage: python3 scripts/e8_6_figures.py [--summary FILE] [--out DIR]
"""
import argparse
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

C_SRAM = "#2a6f7d"   # protected-weight storage (teal)
C_MAP = "#b5643b"    # address map (rust)
C_XBAR = "#c3b1d6"   # PCM crossbar (lavender)
C_BUF = "#e4d9b8"    # activation buffer and bias table (beige)
C_DIG = "#a9cdb9"    # digital periphery (green)
C_MARK = "#1f7a4a"   # as-built marker (dark green)
C_TEXT = "#333333"

plt.rcParams.update({
    "mathtext.fontset": "custom", "mathtext.rm": "Liberation Sans", "mathtext.it": "Liberation Sans:italic",
    "mathtext.bf": "Liberation Sans:bold",
    "font.family": "Liberation Sans",
    "font.size": 14,
    "axes.titlesize": 15,
    "axes.titleweight": "bold",
    "axes.labelsize": 15,
    "xtick.labelsize": 14,
    "ytick.labelsize": 14,
    "legend.fontsize": 13,
    "axes.linewidth": 1.0,
    "pdf.fonttype": 42,
})


def fig7(d, out):
    f7 = d["fig7"]
    ar = d["area"]["A"]
    a0 = d["area"]
    dig = ar["digital_periphery_mm2"]
    buf = a0["act_buffer_mm2"] + a0["bias_table_mm2"]
    xbar = a0["crossbar_mm2"][1]
    amap = ar["address_map_mm2"]
    cache = ar["conv1_cache_mm2"]
    curve = f7["curve"]
    x = [r["budget_pct"] for r in curve]
    sram = [r["sram_single_mm2"] for r in curve]
    floor = dig + buf + xbar
    built = f7["as_built"]

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(6.5, 10.6),
                                   gridspec_kw={"height_ratios": [1.0, 1.0], "hspace": 0.42})
    # (a) stacked components, single logical copy
    y0 = [0.0] * len(x)
    layers = [(dig, C_DIG), (buf, C_BUF), (xbar, C_XBAR), (amap, C_MAP)]
    for h, col in layers:
        y1 = [v + h for v in y0]
        ax1.fill_between(x, y0, y1, color=col, lw=0)
        y0 = y1
    top_fixed = y0[:]
    y1 = [v + cache + s for v, s in zip(top_fixed, sram)]
    ax1.fill_between(x, top_fixed, y1, color=C_SRAM, lw=0)
    ax1.plot(x, y1, color="#444444", lw=1.6)
    ax1.axhline(floor, color="#555555", lw=1.4, ls=(0, (4, 3)))
    ax1.plot([built["budget_pct"]], [built["total_single_mm2"]], "o", color=C_MARK, ms=10, zorder=5)
    ax1.annotate("as built, 5%", xy=(built["budget_pct"], built["total_single_mm2"]),
                 xytext=(9.5, built["total_single_mm2"] + 1.55), color=C_MARK, fontsize=14,
                 arrowprops=dict(arrowstyle="->", color=C_MARK, lw=1.4))
    ax1.text(14, floor + amap * 0.62, "address map %.2f mm$^2$\nROM macros and AMU,\nset by the weight count,\nnot by the budget" % amap,
             color="white", fontsize=14, va="center")
    ax1.text(49.3, floor + 0.28, "caused by the protection", color="white", fontsize=13.5, ha="right", va="bottom")
    ax1.text(49.3, floor - 0.25, "present without protection", color="#3d3d3d", fontsize=13.5, ha="right", va="top")
    ax1.set_xlim(0, 50)
    ax1.set_ylim(0, 15)
    ax1.set_yticks([0, 2, 4, 6, 8, 10, 12, 14])
    ax1.set_ylabel("Area (mm$^2$)")
    ax1.set_xlabel("Protection budget (% of weights in SRAM)")
    ax1.set_title("(a) Single logical copy, by component", loc="left")
    ax1.grid(axis="y", color="#e6e6e6", lw=0.8)
    ax1.set_axisbelow(True)

    # (b) totals for the two SRAM realizations
    tot1 = [r["total_single_mm2"] for r in curve]
    tot25 = [r["total_replicated_mm2"] for r in curve]
    ax2.fill_between(x, tot1, tot25, color="#e9eef0", lw=0)
    ax2.plot(x, tot25, color=C_MAP, lw=2.6, ls=(0, (5, 3)))
    ax2.plot(x, tot1, color=C_SRAM, lw=3.0)
    fl = curve[0]["total_single_mm2"]
    ax2.axhline(fl, color="#999999", lw=1.6, ls=(0, (1, 2)))
    ax2.plot([built["budget_pct"]] * 2, [built["total_single_mm2"], built["total_replicated_mm2"]], "o",
             color=C_MARK, ms=10, zorder=5)
    ax2.annotate("", xy=(built["budget_pct"] - 0.3, built["total_replicated_mm2"] + 1.0), xytext=(4.0, 35.0),
                 arrowprops=dict(arrowstyle="->", color=C_MARK, lw=1.4))
    ax2.annotate("", xy=(built["budget_pct"] + 0.6, built["total_single_mm2"] + 0.8), xytext=(6.2, 35.0),
                 arrowprops=dict(arrowstyle="->", color=C_MARK, lw=1.4, connectionstyle="arc3,rad=-0.25"))
    ax2.text(1.0, 36.0, "as built, 5%", color=C_MARK, fontsize=14, ha="left", va="bottom")
    ax2.annotate("25-read-port\nreplication", xy=(35, tot25[35]), xytext=(17, 52), color=C_MAP, fontsize=14,
                 arrowprops=dict(arrowstyle="->", color=C_MAP, lw=1.4))
    ax2.text(49.3, tot1[-1] + 1.6, "single logical copy", color=C_SRAM, fontsize=14, ha="right", va="bottom")
    ax2.text(49.3, fl - 1.2, "budget-independent floor", color="#808080", fontsize=13.5, ha="right", va="top")
    ax2.set_xlim(0, 50)
    ax2.set_ylim(0, 70)
    ax2.set_ylabel("Total area (mm$^2$)")
    ax2.set_xlabel("Protection budget (% of weights in SRAM)")
    ax2.set_title("(b) Both SRAM realizations, total", loc="left")
    ax2.grid(axis="y", color="#e6e6e6", lw=0.8)
    ax2.set_axisbelow(True)

    handles = [Patch(color=C_SRAM, label="protected-weight storage"),
               Patch(color=C_MAP, label="address map"),
               Patch(color=C_XBAR, label="PCM crossbar (fixed)"),
               Patch(color=C_BUF, label="activation buffer, bias table"),
               Patch(color=C_DIG, label="digital periphery")]
    fig.legend(handles=handles, loc="lower center", ncol=2, frameon=True, edgecolor="#aaaaaa",
               bbox_to_anchor=(0.5, 0.005), columnspacing=1.2, handlelength=1.6)
    fig.subplots_adjust(left=0.15, right=0.96, top=0.965, bottom=0.165)
    for ext in ("png", "pdf"):
        fig.savefig(os.path.join(out, "fig13_area." + ext), dpi=300)
    plt.close(fig)


def fig8(d, out):
    en = d["energy"]
    M = ("A", "B")
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(6.5, 11.6),
                                   gridspec_kw={"height_ratios": [1.0, 1.0], "hspace": 0.40})
    # (a) four parts, stacked
    xs = [0, 1]
    w = 0.52
    for i, m in enumerate(M):
        e = en[m]
        parts = [(e["A_uJ"], C_DIG), (e["B_uJ"], C_SRAM), (e["C_uJ"], C_XBAR), (e["D_uJ"], C_MAP)]
        b = 0.0
        for v, col in parts:
            ax1.bar(xs[i], v, w, bottom=b, color=col, edgecolor="white", lw=0.6)
            b += v
        lo = e["A_uJ"] + e["B_range_uJ"][0] + e["C_uJ"] + e["D_range_uJ"][0]
        hi = e["A_uJ"] + e["B_range_uJ"][1] + e["C_uJ"] + e["D_range_uJ"][1]
        ax1.errorbar(xs[i], b, yerr=[[b - lo], [hi - b]], color="#333333", capsize=6, lw=1.4)
        ax1.text(xs[i], hi + 1.4, "%.1f" % b, ha="center", va="bottom", fontsize=14)
    eA = en["A"]
    ax1.annotate("C: %.2f" % eA["C_uJ"], xy=(0.27, eA["A_uJ"] + eA["B_uJ"] + 0.15),
                 xytext=(0.30, eA["A_uJ"] + eA["B_uJ"] - 10.0), color="#6a4c93", fontsize=14, ha="left",
                 arrowprops=dict(arrowstyle="->", color="#6a4c93", lw=1.3))
    ax1.text(1.45, 52, "B and D exist\nbecause weights\nare protected:\n%.1f%% and %.1f%%\nof the total" % (
        100 * en["A"]["share_BD_of_AD"], 100 * en["B"]["share_BD_of_AD"]), color=C_MAP, fontsize=14, va="top")
    ax1.set_xticks(xs)
    ax1.set_xticklabels(["Model A", "Model B"])
    ax1.set_xlim(-0.5, 2.75)
    ax1.set_ylim(0, 66)
    ax1.set_ylabel("Energy per inference (µJ)")
    ax1.set_title("(a) The four parts", loc="left")
    ax1.grid(axis="y", color="#e6e6e6", lw=0.8)
    ax1.set_axisbelow(True)

    # (b) B and D broken down
    keysB = [("SRAM reads", "#1d4f59"), ("SRAM static (1 macro)", "#5b9aa8"), ("conv1 cache", "#8fc1cc")]
    keysD = [("lookup reads", "#7d3f1f"), ("parking reads", "#9a5530"), ("static after lookup reads", "#c98a63"),
             ("macros at rest on an all-ones word", "#e0b394"), ("macros parked on words with zero bits", "#efd3bf"),
             ("AMU logic", "#b5643b")]
    pos = {("A", "B"): 0.0, ("A", "D"): 0.62, ("B", "B"): 1.62, ("B", "D"): 2.24}
    wb = 0.5
    for m in M:
        e = en[m]
        b = 0.0
        for k, col in keysB:
            v = e["B_parts_uJ"][k]
            ax2.bar(pos[(m, "B")], v, wb, bottom=b, color=col, edgecolor="white", lw=0.6)
            b += v
        ax2.text(pos[(m, "B")], b + 0.4, "%.1f" % b, ha="center", va="bottom", fontsize=13.5)
        b = 0.0
        for k, col in keysD:
            v = e["D_parts_uJ"][k]
            hatch = "//" if k == "AMU logic" else None
            ax2.bar(pos[(m, "D")], v, wb, bottom=b, color=col, edgecolor="white", lw=0.6, hatch=hatch)
            b += v
        ax2.text(pos[(m, "D")], b + 0.4, "%.1f" % b, ha="center", va="bottom", fontsize=13.5)
    ax2.set_xticks([pos[("A", "B")], pos[("A", "D")], pos[("B", "B")], pos[("B", "D")]])
    ax2.set_xticklabels(["B", "D", "B", "D"])
    ax2.text(0.31, -3.4, "Model A", ha="center", va="top", fontsize=14, color="#555555")
    ax2.text(1.93, -3.4, "Model B", ha="center", va="top", fontsize=14, color="#555555")
    ax2.set_xlim(-0.45, 2.7)
    ax2.set_ylim(0, 21)
    ax2.set_ylabel("Energy per inference (µJ)")
    ax2.set_title("(b) Protection-dependent parts, broken down", loc="left")
    ax2.grid(axis="y", color="#e6e6e6", lw=0.8)
    ax2.set_axisbelow(True)

    h1 = [Patch(color=C_DIG, label="$\\mathbf{A}$ digital periphery"),
          Patch(color=C_SRAM, label="$\\mathbf{B}$ protected-weight storage"),
          Patch(color=C_XBAR, label="$\\mathbf{C}$ PCM-CIM array"),
          Patch(color=C_MAP, label="$\\mathbf{D}$ address map")]
    names = {"SRAM reads": "SRAM reads (B)", "conv1 cache": "conv1 cache (B)",
             "lookup reads": "ROM lookup reads (D)", "parking reads": "ROM parking reads (D)",
             "static after lookup reads": "static after ROM lookups (D)",
             "macros at rest on an all-ones word": "ROM at rest, all-ones word (D)",
             "macros parked on words with zero bits": "ROM parked on zero bits (D)", "AMU logic": "AMU logic (D)"}
    h2 = [Patch(color=c, label=names[k]) for k, c in keysB if not k.startswith("SRAM static")] + \
         [Patch(facecolor=c, edgecolor="white", hatch=("//" if k == "AMU logic" else None), label=names[k])
          for k, c in keysD]
    l1 = fig.legend(handles=h1, loc="upper left", frameon=True, edgecolor="#aaaaaa", bbox_to_anchor=(0.03, 0.222),
                    handlelength=1.5, fontsize=12.5, title="Parts, (a)", title_fontsize=12.5)
    l1._legend_box.align = "left"
    l2 = fig.legend(handles=h2, loc="upper right", frameon=True, edgecolor="#aaaaaa", bbox_to_anchor=(0.985, 0.222),
                    handlelength=1.5, fontsize=12.5, title="Breakdown, (b)", title_fontsize=12.5)
    l2._legend_box.align = "left"
    fig.subplots_adjust(left=0.15, right=0.96, top=0.968, bottom=0.285)
    for ext in ("png", "pdf"):
        fig.savefig(os.path.join(out, "fig14_energy." + ext), dpi=300)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary", default="reports/e8_6/e8_6_summary.json")
    ap.add_argument("--out", default="figures")
    a = ap.parse_args()
    d = json.load(open(a.summary, encoding="utf-8"))
    os.makedirs(a.out, exist_ok=True)
    fig7(d, a.out)
    fig8(d, a.out)


if __name__ == "__main__":
    main()
