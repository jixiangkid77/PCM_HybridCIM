#!/usr/bin/env python3
"""Fig. 8: the read failure of the generated ROM macros and its fix.

Every read of the 13 screened macros (32, 48 and 64 rows; 32 reads each) at
tt, 25 C, 1.80 V, with the generated timing (E8.4a-5 runs, re-analyzed in
E8.4a-6: reports/e8_rom/e8_4a6/<table>/a5/<macro>.json) and with the chip
select raised 10 ns after the clock edge (E8.4a-6: <table>/<macro>/tt_cs/
result.json); the 192-row macro (<table>/full/tt_orig and tt_cs) is shown
for comparison. x: time from the selected word line going low (its cells
turning off) to the array footers turning on, from the per-read
'footer_to_wl_ns' (negative of it, so that positive means the footers turn on
after the cells are off). y: lowest bit line among the one cells of the read
row ('bl1_min_V'). Lines: switching level of the bit-line inverter at tt and
the 0.10-V margin rule. All macros are address-map ROMs, so the row counts
are drawn in the rust family of the address map (light to dark with depth).

Usage: python3 scripts/fig08_rom_race.py --paper2 . --out figures
"""
import argparse
import glob
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

TABLE = "e8rom_A_pcm_l00_16x2496"
VM_TT = 0.876          # switching level of the bit-line inverter, tt 25 C 1.80 V (E8.4a-6 log)
RULE = 0.10
COL = {32: "#d4895a", 48: "#b5643b", 64: "#6e3416", 192: "#222222"}
MK = {64: "^", 48: "o", 32: "s", 192: "D"}

plt.rcParams.update({
    "mathtext.fontset": "custom", "mathtext.rm": "Liberation Sans", "mathtext.it": "Liberation Sans:italic",
    "mathtext.bf": "Liberation Sans:bold",
    "font.family": "Liberation Sans", "font.size": 15, "axes.labelsize": 15,
    "xtick.labelsize": 14, "ytick.labelsize": 14, "legend.fontsize": 13,
    "axes.linewidth": 1.0, "pdf.fonttype": 42,
})


def reads(path):
    d = json.load(open(path))
    return [c for c in d["cycles"] if c.get("kind") == "read"]


def load(paper2):
    base = os.path.join(paper2, "reports", "e8_rom", "e8_4a6", TABLE)
    out = []
    for p in sorted(glob.glob(os.path.join(base, "a5", TABLE + "_r*.json"))):
        m = os.path.basename(p)[:-5]
        rows = int(m.split("_r")[-1].split("k")[0])
        orig = reads(p)
        fix = reads(os.path.join(base, m, "tt_cs", "result.json"))
        assert len(orig) == len(fix) == 32
        for a, b in zip(orig, fix):
            assert a["addr"] == b["addr"]
            out.append((rows, m, a, b))
    full = list(zip(reads(os.path.join(base, "full", "tt_orig", "result.json")),
                    reads(os.path.join(base, "full", "tt_cs", "result.json"))))
    return out, full


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".")
    ap.add_argument("--out", default="figures")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    data, full = load(a.paper2)
    n = len(data)
    wrong_o = sum(not o["ok"] for _, _, o, _ in data)
    wrong_f = sum(not f["ok"] for _, _, _, f in data)
    lag_o = [-o["footer_to_wl_ns"] for _, _, o, _ in data]
    lag_f = [-f["footer_to_wl_ns"] for _, _, _, f in data]
    rise = [f["bl1_min_V"] - o["bl1_min_V"] for _, _, o, f in data]
    print(f"{len(set(m for _, m, _, _ in data))} macros, {n} reads; wrong: generated {wrong_o}, CS delayed {wrong_f}")
    print(f"footers on after the cells are off: generated {min(lag_o):.3f}..{max(lag_o):.3f} ns, "
          f"CS delayed {min(lag_f):.3f}..{max(lag_f):.3f} ns")
    print(f"lowest one-cell bit line: generated {min(o['bl1_min_V'] for _, _, o, _ in data):.3f} V, "
          f"CS delayed {min(f['bl1_min_V'] for _, _, _, f in data):.3f} V; rise {1000 * min(rise):.1f}..{1000 * max(rise):.1f} mV")
    print("192-row macro: generated %d of %d wrong, CS delayed %d wrong; lag %.3f..%.3f ns" % (
        sum(not o["ok"] for o, _ in full), len(full), sum(not f["ok"] for _, f in full),
        min(-f["footer_to_wl_ns"] for _, f in full), max(-f["footer_to_wl_ns"] for _, f in full)))

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(6.5, 5.6), sharey=True, gridspec_kw={"wspace": 0.08})
    for ax, idx, title in ((ax1, 0, "(a) Generated timing"), (ax2, 1, "(b) Chip select 10 ns later")):
        for rows in (32, 48, 64):
            pts = [(r[2], r[3]) for r in data if r[0] == rows]
            xs = [-p[idx]["footer_to_wl_ns"] for p in pts]
            ys = [p[idx]["bl1_min_V"] for p in pts]
            ok = [p[idx]["ok"] for p in pts]
            ax.scatter([x for x, k in zip(xs, ok) if k], [y for y, k in zip(ys, ok) if k], s=34, marker=MK[rows],
                       facecolor="white", edgecolor=COL[rows], lw=1.3, zorder=3)
            ax.scatter([x for x, k in zip(xs, ok) if not k], [y for y, k in zip(ys, ok) if not k], s=34,
                       marker=MK[rows], color=COL[rows], zorder=4)
        xs = [-p[idx]["footer_to_wl_ns"] for p in full]
        ys = [p[idx]["bl1_min_V"] for p in full]
        ok = [p[idx]["ok"] for p in full]
        ax.scatter([x for x, k in zip(xs, ok) if k], [y for y, k in zip(ys, ok) if k], s=40, marker="D",
                   facecolor="white", edgecolor=COL[192], lw=1.3, zorder=3)
        ax.scatter([x for x, k in zip(xs, ok) if not k], [y for y, k in zip(ys, ok) if not k], s=40, marker="D",
                   color=COL[192], zorder=4)
        ax.axhline(VM_TT, color="#c0392b", lw=1.4, ls="--", zorder=2)
        ax.axhline(VM_TT + RULE, color="#c0392b", lw=1.2, ls=":", zorder=2)
        ax.set_title(title, loc="left", fontsize=15, fontweight="bold")
        ax.grid(True, color="#e3e3e3", lw=0.7)
        ax.set_axisbelow(True)
    ax1.set_xlim(-1.45, 0.05)
    ax2.set_xlim(8.2, 9.8)
    ax1.set_xticks([-1.2, -0.8, -0.4, 0.0])
    ax2.set_xticks([8.4, 8.8, 9.2, 9.6])
    ax1.set_ylim(0.2, 1.85)
    ax1.set_ylabel("Lowest bit line of a one cell (V)")
    fig.text(0.54, 0.035, "Footer turn-on after the selected cells turn off (ns)", ha="center", fontsize=15)
    ax2.text(8.93, VM_TT - 0.012, "switching level", color="#c0392b", fontsize=13, va="top")
    ax2.text(8.93, VM_TT + RULE / 2, "0.10-V rule", color="#c0392b", fontsize=13, va="center")
    handles = [Line2D([], [], ls="", marker=MK[r], mfc="white", mec=COL[r], mew=1.3, ms=8, label=f"{r} rows")
               for r in (32, 48, 64, 192)]
    handles.append(Line2D([], [], ls="", marker="o", mfc="white", mec="#777777", mew=1.3, ms=8, label="read correct"))
    handles.append(Line2D([], [], ls="", marker="o", color="#777777", ms=8, label="read wrong"))
    fig.legend(handles=handles, loc="upper center", ncol=3, frameon=False, bbox_to_anchor=(0.55, 1.0),
               columnspacing=1.4, handletextpad=0.3, fontsize=13)
    fig.subplots_adjust(left=0.13, right=0.98, top=0.82, bottom=0.14)
    for ext in ("png", "pdf"):
        fig.savefig(os.path.join(a.out, "fig08_rom_race." + ext), dpi=300)
    plt.close(fig)


if __name__ == "__main__":
    main()
