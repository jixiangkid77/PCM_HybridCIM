#!/usr/bin/env python3
"""Fig. 4 of the TVLSI manuscript: the read failure of the generated ROM macros and its fix.

Data and rules as scripts/fig08_rom_race.py: every read of the 13 screened
macros (32, 48 and 64 rows; 32 reads each) at tt, 25 C, 1.80 V with the
generated timing (reports/e8_rom/e8_4a6/<table>/a5/<macro>.json) and with the
chip select raised 10 ns after the clock edge (<table>/<macro>/tt_cs/
result.json), and the 192-row macro (<table>/full/tt_orig and tt_cs).
x: time from the turn-off of the cells of the selected row to the turn-on of
the bit-line footers (the negative of 'footer_to_wl_ns'); y: lowest bit line
among the one cells of the read row ('bl1_min_V'). Only the size (one column)
and the layout differ.

Usage: python3 scripts/tvlsi/fig4_rom_race.py --paper2 . --out figures/tvlsi
"""
import argparse
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tvlsi_style as S  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402

TABLE = "e8rom_A_pcm_l00_16x2496"
VM_TT = 0.876          # switching level of the bit-line inverter, tt 25 C 1.80 V
RULE = 0.10
COL = {32: "#d4895a", 48: "#b5643b", 64: "#6e3416", 192: "#222222"}
MK = {64: "^", 48: "o", 32: "s", 192: "D"}


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
    ap.add_argument("--out", default="figures/tvlsi")
    a = ap.parse_args()
    data, full = load(a.paper2)
    wrong_o = sum(not o["ok"] for _, _, o, _ in data)
    wrong_f = sum(not f["ok"] for _, _, _, f in data)
    lag_o = [-o["footer_to_wl_ns"] for _, _, o, _ in data]
    lag_f = [-f["footer_to_wl_ns"] for _, _, _, f in data]
    rise = [f["bl1_min_V"] - o["bl1_min_V"] for _, _, o, f in data]
    print(f"{len(set(m for _, m, _, _ in data))} macros, {len(data)} reads; wrong: generated {wrong_o}, CS delayed {wrong_f}")
    print(f"footers on after the cells are off: generated {min(lag_o):.3f}..{max(lag_o):.3f} ns, "
          f"CS delayed {min(lag_f):.3f}..{max(lag_f):.3f} ns; rise {1000 * min(rise):.1f}..{1000 * max(rise):.1f} mV")
    print("192-row macro: generated %d of %d wrong, CS delayed %d wrong" % (
        sum(not o["ok"] for o, _ in full), len(full), sum(not f["ok"] for _, f in full)))

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(S.COL1, 2.35), sharey=True, gridspec_kw={"wspace": 0.10})
    for ax, idx, title in ((ax1, 0, "(a) Generated timing"), (ax2, 1, "(b) Chip select 10 ns later")):
        for rows in (32, 48, 64):
            pts = [(r[2], r[3]) for r in data if r[0] == rows]
            xs = [-p[idx]["footer_to_wl_ns"] for p in pts]
            ys = [p[idx]["bl1_min_V"] for p in pts]
            ok = [p[idx]["ok"] for p in pts]
            ax.scatter([x for x, k in zip(xs, ok) if k], [y for y, k in zip(ys, ok) if k], s=9, marker=MK[rows],
                       facecolor="white", edgecolor=COL[rows], lw=0.6, zorder=3)
            ax.scatter([x for x, k in zip(xs, ok) if not k], [y for y, k in zip(ys, ok) if not k], s=9,
                       marker=MK[rows], color=COL[rows], lw=0, zorder=4)
        xs = [-p[idx]["footer_to_wl_ns"] for p in full]
        ys = [p[idx]["bl1_min_V"] for p in full]
        ok = [p[idx]["ok"] for p in full]
        ax.scatter([x for x, k in zip(xs, ok) if k], [y for y, k in zip(ys, ok) if k], s=10, marker="D",
                   facecolor="white", edgecolor=COL[192], lw=0.6, zorder=3)
        ax.scatter([x for x, k in zip(xs, ok) if not k], [y for y, k in zip(ys, ok) if not k], s=10, marker="D",
                   color=COL[192], lw=0, zorder=4)
        ax.axhline(VM_TT, color=S.RED, lw=0.8, ls="--", zorder=2)
        ax.axhline(VM_TT + RULE, color=S.RED, lw=0.8, ls=":", zorder=2)
        S.panel_title(ax, title)
        S.grid(ax)
    ax1.set_xlim(-1.45, 0.05)
    ax2.set_xlim(8.2, 9.8)
    ax1.set_xticks([-1.2, -0.8, -0.4, 0.0])
    ax2.set_xticks([8.4, 8.8, 9.2, 9.6])
    ax1.set_ylim(0.2, 1.85)
    ax1.set_ylabel("Lowest one-cell bit line (V)")
    fig.text(0.56, 0.015, "Footer turn-on after the selected cells turn off (ns)", ha="center", va="bottom",
             fontsize=S.FS)
    ax2.text(8.86, VM_TT - 0.025, "switching level", color=S.RED, fontsize=S.FS_SMALL, va="top", bbox=S.WHITE)
    ax1.text(-1.13, VM_TT + RULE + 0.025, "0.10-V rule", color=S.RED, fontsize=S.FS_SMALL, va="bottom", bbox=S.WHITE)
    handles = [Line2D([], [], ls="", marker=MK[r], mfc="white", mec=COL[r], mew=0.7, ms=3.6, label=f"{r} rows")
               for r in (32, 48, 64, 192)]
    handles.append(Line2D([], [], ls="", marker="o", mfc="white", mec="#666666", mew=0.7, ms=3.6, label="correct"))
    handles.append(Line2D([], [], ls="", marker="o", color="#666666", ms=3.6, label="wrong"))
    order = [0, 3, 1, 4, 2, 5]
    fig.legend(handles=[handles[i] for i in order], loc="upper center", ncol=3, frameon=False,
               bbox_to_anchor=(0.56, 1.01), columnspacing=1.2, handletextpad=0.2, fontsize=S.FS_SMALL)
    fig.subplots_adjust(left=0.13, right=0.985, top=0.765, bottom=0.17)
    S.save(fig, a.out, "fig4_rom_race")


if __name__ == "__main__":
    main()
