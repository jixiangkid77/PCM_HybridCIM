#!/usr/bin/env python3
"""Fig. 7 of the TVLSI manuscript: area against the protection budget and the per-inference energy, from
reports/e9/e9_5/e9_5_summary.json (scripts/e9_5_recost.py: the address map of E9, seven ROM macros and the
AMU, on the accounting of scripts/e10_2b_recost.py: the protected-weight SRAM as 25 single-port banks with
their pool logic, no conv1 cache).

(a) Model A at the baseline converter scheme: the blocks independent of the budget (digital periphery,
activation buffer and bias table, crossbar, address map) and the banked SRAM; the curve is the model of
the recost (25 banks of ceil(n / 25) words, each linear in its words between the 128-word bank and the
4,096-word macro, plus the pool logic), the marked point the design as built, whose banks are rounded up
to 128 words. (b) The protected-weight SRAM alone: the 25 banks against one copy of the 4-KB macro (area
per bit of that macro, the per-bit model of E8.6), which cannot serve the 25 reads of a step, and 25
copies; marked points as built. (c) The four parts of the per-inference energy of the two models; the bar
tops give the totals A to D and the error bars the ranges of the parts B and D.

Usage: python3 scripts/tvlsi/fig7_cost.py --summary reports/e9/e9_5/e9_5_summary.json --out figures/tvlsi
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tvlsi_style as S  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import Patch  # noqa: E402

C_SRAM = "#2a6f7d"   # protected-weight storage
C_MAP = "#b5643b"    # address map
C_XBAR = "#c3b1d6"   # PCM crossbar
C_BUF = "#e4d9b8"    # activation buffer and bias table
C_DIG = "#a9cdb9"    # digital periphery
C_MARK = "#1f7a4a"   # as built
C_ONE = "#8a8a8a"    # one 4-KB copy


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary", default="reports/e9/e9_5/e9_5_summary.json")
    ap.add_argument("--out", default="figures/tvlsi")
    a = ap.parse_args()
    d = json.load(open(a.summary, encoding="utf-8"))
    f7 = d["fig7"]
    bl = f7["blocks_mm2"]
    dig, buf, xbar, amap = bl["digital_periphery"], bl["act_buffer_and_bias"], bl["crossbar_baseline"], bl["address_map"]
    curve = [r for r in f7["curve"] if r["budget_pct"] > 0]
    x = [r["budget_pct"] for r in curve]
    sram = [r["sram_banked_mm2"] for r in curve]
    floor = dig + buf + xbar
    built = f7["as_built"]
    en = d["energy"]
    print(f"area: digital {dig:.3f}, buffer+bias {buf:.3f}, crossbar {xbar:.2f}, map {amap:.2f} mm2; as built "
          f"{built['total_baseline_mm2']:.2f} mm2 (compact scheme {built['total_compact_mm2']:.2f}), SRAM "
          f"{built['sram_banked_mm2']:.3f} / one copy {built['sram_single_mm2']:.3f} / 25 copies {built['sram_replicated_mm2']:.2f}; "
          f"budget 1 % {curve[0]['total_banked_baseline_mm2']:.2f}, 50 % {curve[-1]['total_banked_baseline_mm2']:.2f} mm2; "
          f"SRAM at 50 %: banks {curve[-1]['sram_banked_mm2']:.2f}, one copy {curve[-1]['sram_single_mm2']:.2f}, "
          f"25 copies {curve[-1]['sram_replicated_mm2']:.1f} mm2")
    for m in ("A", "B"):
        e = en[m]
        print(f"energy {m}: A {e['A_uJ']:.2f} B {e['B_uJ']:.2f} C {e['C_uJ']:.3f} D {e['D_uJ']:.2f} "
              f"total {e['total_AD_uJ']:.2f} uJ, (B+D)/(A..D) {100 * e['share_BD_of_AD']:.1f} %")

    fig = plt.figure(figsize=(S.COL2, 1.98))
    ax1 = fig.add_axes([0.058, 0.278, 0.27, 0.626])
    ax2 = fig.add_axes([0.392, 0.278, 0.27, 0.626])
    ax3 = fig.add_axes([0.735, 0.278, 0.255, 0.626])

    # (a) stacked components, banked SRAM
    xs = [0.0] + x
    y0 = [0.0] * len(xs)
    for h, col in [(dig, C_DIG), (buf, C_BUF), (xbar, C_XBAR), (amap, C_MAP)]:
        y1 = [v + h for v in y0]
        ax1.fill_between(xs, y0, y1, color=col, lw=0)
        y0 = y1
    top = y0[1:]
    y1 = [v + s for v, s in zip(top, sram)]
    ax1.fill_between(x, top, y1, color=C_SRAM, lw=0)
    ax1.plot(x, y1, color="#444444", lw=0.8)
    ax1.axhline(floor, color="#555555", lw=0.8, ls=(0, (3, 2)))
    ax1.plot([built["budget_pct"]], [built["total_baseline_mm2"]], "o", color=C_MARK, ms=4, zorder=5)
    ax1.text(built["budget_pct"] + 2.0, built["total_baseline_mm2"] - 0.45, "as built, 5%", color="white",
             fontsize=S.FS_SMALL, ha="left", va="center")
    ax1.annotate("address map, %.2f mm$^2$" % amap, xy=(15, floor + amap * 0.5), xytext=(1.5, 7.45),
                 color=C_MAP, fontsize=S.FS_SMALL, ha="left", va="center",
                 arrowprops=dict(arrowstyle="->", color=C_MAP, lw=0.8, shrinkA=1, shrinkB=1, relpos=(0.5, 0.0)))
    ax1.text(49.3, floor + 0.12, "due to the protection", color="white", fontsize=S.FS_SMALL, ha="right",
             va="bottom")
    ax1.text(49.3, floor - 0.15, "present without it", color="#333333", fontsize=S.FS_SMALL, ha="right", va="top")
    ax1.set_xlim(0, 50)
    ax1.set_ylim(0, 8)
    ax1.set_yticks([0, 2, 4, 6, 8])
    ax1.set_ylabel("Area (mm$^2$)")
    ax1.set_xlabel("Protection budget (%)")
    S.panel_title(ax1, "(a) Area, 25 SRAM banks")
    S.grid(ax1, axis="y")

    # (b) the protected-weight SRAM: banks, one 4-KB copy, 25 copies
    one = [r["sram_single_mm2"] for r in curve]
    rep = [r["sram_replicated_mm2"] for r in curve]
    ax2.plot(x, rep, color=C_MAP, lw=1.2, ls=(0, (4, 2)))
    ax2.plot(x, sram, color=C_SRAM, lw=1.4)
    ax2.plot(x, one, color=C_ONE, lw=1.0, ls=(0, (1.5, 1.5)))
    pts = [built["sram_replicated_mm2"], built["sram_banked_mm2"], built["sram_single_mm2"]]
    for v, c in zip(pts, (C_MAP, C_MARK, C_ONE)):
        ax2.plot([built["budget_pct"]], [v], "o", color=c, ms=4, zorder=5)
    ax2.text(49.3, rep[-1] * 0.62, "25 copies of the\n4-KB macro", color=C_MAP, fontsize=S.FS_SMALL, ha="right",
             va="top")
    ax2.text(49.3, sram[-1] * 1.25, "25 banks, as built at 5%", color=C_SRAM, fontsize=S.FS_SMALL, ha="right",
             va="bottom")
    ax2.text(49.3, 0.33, "one 4-KB copy (one read\nper cycle, not usable)", color="#555555",
             fontsize=S.FS_SMALL, ha="right", va="top")
    ax2.set_yscale("log")
    ax2.set_xlim(0, 50)
    ax2.set_ylim(0.03, 100)
    ax2.set_ylabel("SRAM area (mm$^2$)")
    ax2.set_xlabel("Protection budget (%)")
    S.panel_title(ax2, "(b) Protected-weight SRAM")
    S.grid(ax2, axis="y")

    # (c) energy per inference, four parts
    w = 0.5
    for i, m in enumerate(("A", "B")):
        e = en[m]
        b = 0.0
        for v, col in [(e["A_uJ"], C_DIG), (e["B_uJ"], C_SRAM), (e["C_uJ"], C_XBAR), (e["D_uJ"], C_MAP)]:
            ax3.bar(i, v, w, bottom=b, color=col, edgecolor="white", lw=0.4)
            b += v
        lo = e["A_uJ"] + e["B_range_uJ"][0] + e["C_uJ"] + e["D_range_uJ"][0]
        hi = e["A_uJ"] + e["B_range_uJ"][1] + e["C_uJ"] + e["D_range_uJ"][1]
        ax3.errorbar(i, b, yerr=[[b - lo], [hi - b]], color="#333333", capsize=2, lw=0.7)
        ax3.text(i, hi + 0.7, "%.1f" % b, ha="center", va="bottom", fontsize=S.FS_SMALL)
    ax3.set_xticks([0, 1])
    ax3.set_xticklabels(["Model A", "Model B"])
    ax3.set_xlim(-0.55, 1.55)
    ax3.set_ylim(0, 36)
    ax3.set_ylabel("Energy per inference (µJ)")
    S.panel_title(ax3, "(c) Energy, tt, 25 °C")
    S.grid(ax3, axis="y")

    handles = [Patch(color=C_SRAM, label="protected-weight storage (B)"),
               Patch(color=C_MAP, label="address map (D)"),
               Patch(color=C_XBAR, label="PCM crossbar (C)"),
               Patch(color=C_BUF, label="activation buffer, bias table"),
               Patch(color=C_DIG, label="digital periphery (A)")]
    fig.legend(handles=handles, loc="lower center", ncol=5, frameon=False, bbox_to_anchor=(0.5, -0.01),
               columnspacing=1.2, handlelength=1.2, fontsize=S.FS_SMALL)
    S.save(fig, a.out, "fig7_cost")


if __name__ == "__main__":
    main()
