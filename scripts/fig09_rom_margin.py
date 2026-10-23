#!/usr/bin/env python3
"""Fig. 9: read margin of the 400 address-map ROM macros.

(a) tt, 25 C, 1.80 V: the lowest one-cell bit line of each of the 97 simulated
    macros (measured: every 'bl1_min_V' of the runs with the chip select 10 ns
    after the edge in reports/e8_rom/e8_4a7, e8_4a8, e8_4a10, e8_4a11) and the
    lower bound of the model for the other 303 (reports/e8_rom/e8_4a11/tables/
    predictions.json, 'LB'); the 13 macros whose lower bound fell below the
    coverage level were then simulated (E8.4a-11) and are drawn with both values.
(b) margin (lowest one-cell bit line minus the switching level of the condition,
    reports/e8_rom/e8_4a8/vm/vm.txt) of the simulated macros at the four
    verification conditions, and the 30 Monte Carlo samples of the worst cell at
    each of the two Monte Carlo sites (reports/e8_rom/e8_4d/e8_4d_summary.json,
    'm1_site_col_V' of samples s0001..s0030).

Colors: the rust family of the address map (dark: simulated, light: lower
bound of the model), gray for Monte Carlo, red for the switching level and the
margin rule.

Usage: python3 scripts/fig09_rom_margin.py --paper2 . --out figures
"""
import argparse
import collections
import glob
import json
import os
import statistics as st

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

CONDS = ["tt:25:1.80", "fs:25:1.80", "tt:25:1.60", "fs:-40:1.60"]
CLAB = {"tt:25:1.80": "tt\n25 °C\n1.80 V", "fs:25:1.80": "fs\n25 °C\n1.80 V",
        "tt:25:1.60": "tt\n25 °C\n1.60 V", "fs:-40:1.60": "fs\n−40 °C\n1.60 V"}
C_SIM, C_LB, C_MC, C_RED = "#6e3416", "#dc9a6c", "#777777", "#c0392b"

plt.rcParams.update({
    "mathtext.fontset": "custom", "mathtext.rm": "Liberation Sans", "mathtext.it": "Liberation Sans:italic",
    "mathtext.bf": "Liberation Sans:bold",
    "font.family": "Liberation Sans", "font.size": 15, "axes.labelsize": 15,
    "xtick.labelsize": 14, "ytick.labelsize": 14, "legend.fontsize": 13,
    "axes.linewidth": 1.0, "pdf.fonttype": 42,
})


def measured(rom):
    meas = collections.defaultdict(dict)
    for d in ("e8_4a7", "e8_4a8", "e8_4a10", "e8_4a11"):
        for p in glob.glob(os.path.join(rom, d, "**", "result.json"), recursive=True):
            try:
                j = json.load(open(p))
            except (OSError, ValueError):
                continue
            m = j.get("meta", {})
            top = m.get("top") or ""
            if not top.startswith("e8rom_") or (m.get("cs_delay_ns") or 0) < 9:
                continue
            rs = [c["bl1_min_V"] for c in j.get("cycles", []) if c.get("kind") == "read" and c.get("bl1_min_V") is not None]
            if not rs:
                continue
            cond = f"{m['corner']}:{int(m['temp'])}:{m['vdd']:.2f}"
            v = min(rs)
            meas[top][cond] = min(v, meas[top].get(cond, v))
    return meas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".")
    ap.add_argument("--out", default="figures")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rom = os.path.join(a.paper2, "reports", "e8_rom")
    pred = json.load(open(os.path.join(rom, "e8_4a11", "tables", "predictions.json")))
    t_cov, v_rule = pred["rule"]["T_COV_V"], pred["rule"]["V_RULE"]
    vm = {}
    for line in open(os.path.join(rom, "e8_4a8", "vm", "vm.txt")):
        k, v = line.split()
        vm[k] = float(v)
    meas = measured(rom)
    sel = set(pred["selected"])
    sim = {k for k, v in pred["macros"].items() if v["simulated"]} | sel
    assert set(meas) == sim and len(sim) == 97, (len(meas), len(sim))
    others = {k: v["LB"] for k, v in pred["macros"].items() if k not in sim}
    assert len(others) == 303
    tt = {k: meas[k]["tt:25:1.80"] for k in sim}
    print(f"simulated {len(sim)}, lowest bit line at tt {min(tt.values()):.4f} V (margin {min(tt.values()) - vm['tt:25:1.80']:.4f} V)")
    print(f"other {len(others)}: lowest lower bound {min(others.values()):.4f} V; coverage level {t_cov} V")
    for c in CONDS:
        vals = [meas[k][c] - vm[c] for k in sim if c in meas[k]]
        print(f"{c}: {len(vals)} macros, smallest margin {min(vals):.4f} V")
    gap = [tt[k] - pred["macros"][k]["LB"] for k in sel]
    print(f"13 re-simulated: measured minus lower bound {1000 * min(gap):.1f}..{1000 * max(gap):.1f} mV")
    mc = json.load(open(os.path.join(rom, "e8_4d", "e8_4d_summary.json")))["sites"]
    mcv = collections.defaultdict(list)
    for name, s in mc.items():
        smp = [s["samples"][f"s{i:04d}"]["m1_site_col_V"] for i in range(1, 31)]
        assert abs(st.mean(smp) - s["margin_worst_cell"]["mean"]) < 1e-9
        mcv[s["site"]["cond"]].append((s["site"]["short"], smp))
        print(f"MC {name}: sd {1000 * st.stdev(smp):.1f} mV, min {min(smp):.3f} V, mean-3sd {st.mean(smp) - 3 * st.stdev(smp):.3f} V")

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(6.5, 10.2), gridspec_kw={"hspace": 0.42, "height_ratios": [1, 1.05]})
    # (a)
    allv = sorted([(v, "lb", k) for k, v in others.items()] + [(tt[k], "sim", k) for k in sim])
    xs = {k: i + 1 for i, (_, _, k) in enumerate(allv)}
    ax1.scatter([xs[k] for v, t, k in allv if t == "lb"], [v for v, t, k in allv if t == "lb"], s=10, color=C_LB,
                zorder=3, label="lower bound of the model (303 macros)")
    ax1.scatter([xs[k] for v, t, k in allv if t == "sim"], [v for v, t, k in allv if t == "sim"], s=16, color=C_SIM,
                zorder=4, label="simulated (97 macros)")
    for k in sorted(sel):
        lb = pred["macros"][k]["LB"]
        ax1.plot([xs[k], xs[k]], [lb, tt[k]], color="#999999", lw=0.9, zorder=2)
        ax1.scatter([xs[k]], [lb], s=26, facecolor="white", edgecolor=C_LB, lw=1.2, zorder=5)
    ax1.axhline(t_cov, color="#444444", lw=1.3, ls="-.")
    ax1.axhline(v_rule, color=C_RED, lw=1.2, ls=":")
    ax1.axhline(vm["tt:25:1.80"], color=C_RED, lw=1.4, ls="--")
    ax1.text(395, t_cov - 0.012, "coverage level", ha="right", va="top", fontsize=13, color="#444444")
    ax1.text(395, v_rule + 0.012, "0.10-V margin rule", ha="right", va="bottom", fontsize=13, color=C_RED)
    ax1.text(395, vm["tt:25:1.80"] + 0.012, "switching level", ha="right", va="bottom", fontsize=13, color=C_RED)
    ax1.set_xlim(-5, 405)
    ax1.set_ylim(0.82, max(v for v, _, _ in allv) + 0.04)
    ax1.set_xlabel("Macro, in order of its value")
    ax1.set_ylabel("Lowest one-cell bit line (V)")
    ax1.set_title("(a) All 400 macros at tt, 25 °C, 1.80 V", loc="left", fontsize=15, fontweight="bold")
    h, l = ax1.get_legend_handles_labels()
    h.append(Line2D([], [], ls="", marker="o", mfc="white", mec=C_LB, mew=1.2, ms=6))
    l.append("lower bound of the 13 re-simulated macros")
    ax1.legend(h, l, loc="upper left", fontsize=13, frameon=False, handletextpad=0.3)
    ax1.grid(True, color="#e6e6e6", lw=0.7)
    ax1.set_axisbelow(True)
    # (b)
    for i, c in enumerate(CONDS):
        vals = sorted(meas[k][c] - vm[c] for k in sim if c in meas[k])
        n = len(vals)
        jit = [((j * 0.6180339887) % 1.0 - 0.5) * 0.22 for j in range(n)]
        ax2.scatter([i - 0.15 + x for x in jit], vals, s=12, color=C_SIM, zorder=3)
        for s_i, (short, smp) in enumerate(mcv[c]):
            x0 = i + 0.22 + 0.12 * s_i
            ax2.scatter([x0] * len(smp), smp, s=9, color=C_MC, alpha=0.75, zorder=3)
        ax2.text(i - 0.15, min(vals) - 0.012, f"{min(vals):.3f}", ha="center", va="top", fontsize=13, color=C_SIM)
    ax2.axhline(0.10, color=C_RED, lw=1.2, ls=":")
    ax2.axhline(0.0, color=C_RED, lw=1.4, ls="--")
    ax2.text(-0.5, 0.10 + 0.008, "0.10-V rule", ha="left", va="bottom", fontsize=13, color=C_RED)
    ax2.text(-0.5, 0.008, "read error", ha="left", va="bottom", fontsize=13, color=C_RED)
    ax2.set_xticks(range(4))
    ax2.set_xticklabels([CLAB[c] for c in CONDS], fontsize=13)
    ax2.set_xlim(-0.55, 3.6)
    ax2.set_ylim(-0.03, 0.62)
    ax2.set_ylabel("Margin above the switching level (V)")
    ax2.set_title("(b) Margin at the four verification conditions", loc="left", fontsize=15, fontweight="bold")
    ax2.legend(handles=[Line2D([], [], ls="", marker="o", color=C_SIM, ms=5, label="simulated macros (97 at tt 1.80 V, 41 elsewhere)"),
                        Line2D([], [], ls="", marker="o", color=C_MC, ms=5, label="Monte Carlo, worst cell, 2 sites × 30")],
               loc="upper right", fontsize=13, frameon=False, handletextpad=0.3)
    ax2.grid(True, axis="y", color="#e6e6e6", lw=0.7)
    ax2.set_axisbelow(True)
    fig.subplots_adjust(left=0.14, right=0.97, top=0.96, bottom=0.1)
    for ext in ("png", "pdf"):
        fig.savefig(os.path.join(a.out, "fig09_rom_margin." + ext), dpi=300)
    plt.close(fig)


if __name__ == "__main__":
    main()
