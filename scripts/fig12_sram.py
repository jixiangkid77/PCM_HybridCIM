#!/usr/bin/env python3
"""Fig. 12: the protected-weight SRAM read.

(a) Timing of a read of the 4-KB macro against the 10-ns system clock (drawn
    to scale; the times are measured): with one clock per read the data are
    not valid at the next edge (4 of 17 reads correct, E8.4c, reports/
    e8_4c_sram_char_resume3.log, F2); with the macro clock held low for the next
    cycle the data are valid 10.6 ns after the read edge at tt, 25 C (E8.4f,
    reports/e8_6/e8_6_summary.json 'e84f') and at most 13.5 ns at ss, 25 C
    (E8.4e-SRAM, reports/e8_rom/e8_4e_sram/e8_4e_sram_summary.json), and are
    taken at the second edge (rtl/e8/sram_pool_25lane_2c.v).
(b) Energy per access: the compiler's analytical figure used before (11.82 pJ,
    the timing library of the macro) against post-layout simulation: an
    address-map ROM lookup read, its read window only (Model A lookup-read
    energy over its 122,990 lookup reads, e8_6_summary 'D_parts_uJ'), and an
    SRAM read after cycles without access and in the system's two-cycle read
    (e8_6_summary 'e84f'); the note gives the SRAM static power with the clock
    stopped after a read against the analytical leakage (34.375 uW, the same
    library).
Colors: teal the SRAM (light: read after cycles without access), rust the
address-map ROM, gray the analytical model and the one-cycle read that is not
used.

Usage: python3 scripts/fig12_sram.py --paper2 . --out figures
"""
import argparse
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ANALYTIC_PJ = 11.82        # clk0 internal_power of the OpenRAM timing library generated 2026-06-08 (scripts/sram_lib_energy.py)
ANALYTIC_LEAK_UW = 34.375  # same library, leakage
LOOKUP_READS = 122990      # Model A lookup reads per inference (E8.5)
G, GL, R, RL, N = "#2a6f7d", "#9cc3cb", "#b5643b", "#e8c3ad", "#888888"
GR = "#8a8a8a"   # one-cycle read (not used)

plt.rcParams.update({
    "mathtext.fontset": "custom", "mathtext.rm": "Liberation Sans", "mathtext.it": "Liberation Sans:italic",
    "mathtext.bf": "Liberation Sans:bold",
    "font.family": "Liberation Sans", "font.size": 15, "axes.labelsize": 15,
    "xtick.labelsize": 13, "ytick.labelsize": 13, "legend.fontsize": 12,
    "axes.linewidth": 1.0, "pdf.fonttype": 42,
})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".")
    ap.add_argument("--out", default="figures")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    s = json.load(open(os.path.join(a.paper2, "reports", "e8_6", "e8_6_summary.json")))
    f = s["e84f"]
    cond = json.load(open(os.path.join(a.paper2, "reports", "e8_rom", "e8_4e_sram", "e8_4e_sram_summary.json")))["per"]
    t_tt = f["t_acc_gated_ns_max"]
    t_slow = max(max(r["t_acc_gated_ns"] for r in v["reads"]) for v in cond.values())
    slow_c = max(cond, key=lambda c: max(r["t_acc_gated_ns"] for r in cond[c]["reads"]))
    lookup_pj = s["energy"]["A"]["D_parts_uJ"]["lookup reads"] * 1e6 / LOOKUP_READS
    idle = [x for x in f["gated_all_pJ"] if x not in f["system_pJ"]]
    print(f"data valid {t_tt:.3f} ns (tt 25 C), slowest {t_slow:.2f} ns at {slow_c}")
    print(f"ROM lookup read window {lookup_pj:.2f} pJ; SRAM read after idle {min(idle):.2f}-{max(idle):.2f} pJ; "
          f"system read {f['e_read_pJ']:.2f} pJ ({f['e_read_min_pJ']:.2f}-{f['e_read_max_pJ']:.2f}); "
          f"ratio {f['e_read_pJ'] / ANALYTIC_PJ:.2f}; static {f['p_static_uW']:.3f} uW, 1/{ANALYTIC_LEAK_UW / f['p_static_uW']:.1f}")

    fig = plt.figure(figsize=(6.5, 9.6))
    ax = fig.add_axes([0.24, 0.56, 0.73, 0.38])
    rows = [("system clock", 5.0), ("macro clock,\none cycle", 3.6), ("macro clock,\ntwo-cycle read", 2.2),
            ("data output", 0.8)]
    for name, y in rows:
        ax.text(-6.3, y + 0.3, name, ha="right", va="center", fontsize=13.5)
    xs, ys = [], []
    for k in range(-1, 3):
        t = k * 10
        xs += [t, t, t + 5, t + 5]
        ys += [5.0, 5.6, 5.6, 5.0]
    ax.plot(xs, ys, color="#555555", lw=1.4)
    ax.plot([-5, 0, 0, 5, 5, 10, 10, 15, 15, 25], [3.6, 3.6, 4.2, 4.2, 3.6, 3.6, 4.2, 4.2, 3.6, 3.6], color=GR, lw=2.2,
            ls=(0, (4, 2)))
    ax.plot([-5, 0, 0, 5, 5, 25], [2.2, 2.2, 2.8, 2.8, 2.2, 2.2], color=G, lw=2.2)
    ax.text(15, 2.95, "held low", ha="center", va="bottom", fontsize=13, color=G)
    ax.plot([-5, t_tt], [1.1, 1.1], color="#aaaaaa", lw=1.4)
    ax.fill_between([t_tt, 25], 0.8, 1.4, color=GL, ec=G, lw=1.4)
    ax.fill_between([t_tt, t_slow], 0.8, 1.4, color="white", ec=G, lw=1.0, hatch="///")
    ax.text(19.5, 1.1, "word", ha="center", va="center", fontsize=13)
    for t in (0, 10, 20):
        ax.plot([t, t], [0.4, 5.75], color="#999999", lw=1.0, ls=(0, (3, 2)), zorder=0)
    ax.annotate("", xy=(t_tt, 0.55), xytext=(0, 0.55), arrowprops=dict(arrowstyle="<->", color="#333333", lw=1.1))
    ax.text(t_tt / 2, 0.42, f"{t_tt:.1f} ns at tt, 25 °C", ha="center", va="top", fontsize=13)
    ax.text(t_slow + 0.3, 1.45, f"≤ {t_slow:.1f} ns\n(ss, 25 °C)", ha="left", va="bottom", fontsize=12.5, color=G)
    ax.text(10, 6.05, "one-cycle read:\n4 of 17 correct", ha="center", va="bottom", fontsize=13, color="#555555")
    ax.text(20, 6.05, "two-cycle read:\nall correct", ha="center", va="bottom", fontsize=13, color=G)
    ax.set_xlim(-5, 25)
    ax.set_ylim(-0.4, 7.3)
    ax.set_yticks([])
    for sp in ("left", "right", "top"):
        ax.spines[sp].set_visible(False)
    ax.set_xticks([0, 5, 10, 15, 20, 25])
    ax.set_xlabel("Time from the read edge (ns)", fontsize=14)
    fig.text(0.01, 0.955, "(a) Read timing at a 10-ns clock", fontsize=15, fontweight="bold")

    bx = fig.add_axes([0.40, 0.08, 0.57, 0.33])
    labels = ["analytical model\n(compiler), per access", "ROM lookup read\n(read window)",
              "SRAM read after\ncycles without access", "SRAM read in the\ntwo-cycle sequence"]
    vals = [ANALYTIC_PJ, lookup_pj, sum(idle) / len(idle), f["e_read_pJ"]]
    cols = [N, R, GL, G]
    y = list(range(len(vals)))[::-1]
    bx.barh(y, vals, color=cols, height=0.62)
    bx.errorbar([f["e_read_pJ"]], [y[3]], xerr=[[f["e_read_pJ"] - f["e_read_min_pJ"]], [f["e_read_max_pJ"] - f["e_read_pJ"]]],
                color="#333333", capsize=4, lw=1.2)
    for i_, (yy, v) in enumerate(zip(y, vals)):
        xt = (f["e_read_max_pJ"] if i_ == 3 else v) + 2.0
        bx.text(xt, yy, f"{v:.1f} pJ", va="center", fontsize=13)
    bx.set_yticks(y)
    bx.set_yticklabels(labels, fontsize=13)
    bx.set_xlim(0, 112)
    bx.set_xlabel("Energy per access (pJ)", fontsize=14)
    bx.grid(True, axis="x", color="#e3e3e3", lw=0.7)
    bx.set_axisbelow(True)
    fig.text(0.01, 0.455, "(b) Energy per access: analytical and post-layout", fontsize=15, fontweight="bold")
    bx.text(110, y[0], f"SRAM static power\nafter a read: {f['p_static_uW']:.2f} µW\n(analytical: {ANALYTIC_LEAK_UW:.1f} µW)",
            ha="right", va="center", fontsize=12.5, color="#333333")
    for ext in ("png", "pdf"):
        fig.savefig(os.path.join(a.out, "fig12_sram." + ext), dpi=300)
    plt.close(fig)


if __name__ == "__main__":
    main()
