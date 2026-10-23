#!/usr/bin/env python3
"""Fig. 10: supply power of a ROM macro left at rest after a read.

Average power over successive intervals after the read (from the cumulative
energy 'E_curve' of each 3-ms run; intervals from 5 us on, because the first
microseconds still carry the end of the read itself):
  - words with three to seven zero bits, not followed by a parking read:
    reports/e8_rom/e8_5d_park/park.json (runs 'current' and 'candidate*');
  - after a parking read of the all-ones word: reports/e8_rom/e8_5f_park/park.json.
(a) tt, 25 C, 1.80 V, all runs; (b) one macro of each kind at the six
conditions (A_pcm_l04_r48k1 on its lookup word 37ef; A_pcm_l00_r48k0 parked).
Line style gives the kind (solid: lookup word, not parked; dashed: parked); in
(a) the lookup words are rust (address map), in (b) the color gives the
condition, from blue (lower static power than tt, 25 C) through black (tt,
25 C) to red (higher), in the order of Fig. 11.

Usage: python3 scripts/fig10_rom_static.py --paper2 . --out figures
"""
import argparse
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

C_LOOK, C_PARK = "#b5643b", "#222222"
CONDS = ["tt:-40:1.80", "ss:25:1.80", "tt:25:1.80", "ff:25:1.80", "tt:85:1.80", "ff:85:1.80"]
CLAB = {"tt:-40:1.80": "tt, −40 °C", "ss:25:1.80": "ss, 25 °C", "tt:25:1.80": "tt, 25 °C",
        "ff:25:1.80": "ff, 25 °C", "tt:85:1.80": "tt, 85 °C", "ff:85:1.80": "ff, 85 °C"}
CCOL = {"tt:-40:1.80": "#1f4e79", "ss:25:1.80": "#6fa3d6", "tt:25:1.80": "#222222",
        "ff:25:1.80": "#e8a33d", "tt:85:1.80": "#d95f02", "ff:85:1.80": "#a50f15"}

plt.rcParams.update({
    "mathtext.fontset": "custom", "mathtext.rm": "Liberation Sans", "mathtext.it": "Liberation Sans:italic",
    "mathtext.bf": "Liberation Sans:bold",
    "font.family": "Liberation Sans", "font.size": 15, "axes.labelsize": 15,
    "xtick.labelsize": 14, "ytick.labelsize": 14, "legend.fontsize": 12,
    "axes.linewidth": 1.0, "pdf.fonttype": 42,
})


def segments(run, t_from=5e-6):
    ec = run["E_curve"]
    out = []
    for (t1, e1), (t2, e2) in zip(ec, ec[1:]):
        if t1 >= t_from - 1e-12:
            out.append(((t1 * t2) ** 0.5 * 1e6, (e2 - e1) / (t2 - t1) * 1e6))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".")
    ap.add_argument("--out", default="figures")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rom = os.path.join(a.paper2, "reports", "e8_rom")
    look = json.load(open(os.path.join(rom, "e8_5d_park", "park.json")))["runs"]
    park = json.load(open(os.path.join(rom, "e8_5f_park", "park.json")))["runs"]
    look_tt = [r for r in look if r["info"]["cond"] == "tt:25:1.80"]
    park_tt = [r for r in park if r["info"]["cond"] == "tt:25:1.80"]
    print(f"tt 25 C: {len(look_tt)} lookup words (zero bits {sorted(r['info']['z'] for r in look_tt)}), {len(park_tt)} parked macros")
    for r in look_tt:
        pa = r["P_at_uW"]
        print(f"  {r['info']['label']:40s} z={r['info']['z']}  0.5 ms {pa['500']:7.2f}  1 ms {pa['1000']:6.2f}  end {r['P_end_uW']:.3f} uW")
    for r in park_tt:
        seg = segments(r)
        print(f"  {r['info']['label']:40s} 5-10 us {seg[0][1]:.3f} uW, last {r['P_end_uW']:.3f} uW, "
              f"min/max after 5 us {min(v for _, v in seg):.3f}/{max(v for _, v in seg):.3f}")

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(6.5, 10.8), gridspec_kw={"hspace": 0.34})
    for r in look_tt:
        s = segments(r)
        ax1.plot([x for x, _ in s], [y for _, y in s], color=C_LOOK, lw=1.4, alpha=0.85, marker="o", ms=3)
    for r in park_tt:
        s = [(x, y) for x, y in segments(r) if y > 0]
        ax1.plot([x for x, _ in s], [y for _, y in s], color=C_PARK, lw=1.4, alpha=0.85, marker="o", ms=3, ls="--")
    ax1.set_xscale("log")
    ax1.set_yscale("log")
    ax1.set_xlim(4, 4000)
    ax1.set_ylim(0.08, 1000)
    ax1.set_xlabel("Time after the read (µs)")
    ax1.set_ylabel("Supply power (µW)")
    ax1.set_title("(a) All runs at tt, 25 °C, 1.80 V", loc="left", fontsize=15, fontweight="bold")
    ax1.legend(handles=[Line2D([], [], color=C_LOOK, lw=1.6, marker="o", ms=3,
                               label=f"lookup word with 3 to 7 zero bits, no parking read ({len(look_tt)})"),
                        Line2D([], [], color=C_PARK, lw=1.6, marker="o", ms=3, ls="--",
                               label=f"after a parking read of the all-ones word ({len(park_tt)})")],
               loc="center left", bbox_to_anchor=(0.0, 0.40), frameon=False, handletextpad=0.4)
    ax1.grid(True, which="major", color="#e3e3e3", lw=0.7)
    ax1.set_axisbelow(True)

    for c in CONDS:
        rl = [r for r in look if r["info"]["cond"] == c and r["info"]["role"] == "current"
              and r["info"]["macro"].endswith("A_pcm_l04_16x2496_r48k1")]
        rp = [r for r in park if r["info"]["cond"] == c and r["info"]["macro"].endswith("A_pcm_l00_16x2496_r48k0")]
        assert len(rl) == 1 and len(rp) == 1, (c, len(rl), len(rp))
        s = segments(rl[0])
        ax2.plot([x for x, _ in s], [y for _, y in s], color=CCOL[c], lw=1.6, ls="-")
        s = [(x, y) for x, y in segments(rp[0]) if y > 0]
        ax2.plot([x for x, _ in s], [y for _, y in s], color=CCOL[c], lw=1.6, ls="--")
        print(f"  {c}: lookup word end {rl[0]['P_end_uW']:.3f} uW, parked end {rp[0]['P_end_uW']:.3f} uW")
    ax2.set_xscale("log")
    ax2.set_yscale("log")
    ax2.set_xlim(4, 4000)
    ax2.set_ylim(0.01, 1000)
    ax2.set_xlabel("Time after the read (µs)")
    ax2.set_ylabel("Supply power (µW)")
    ax2.set_title("(b) One macro of each kind at six conditions", loc="left", fontsize=15, fontweight="bold")
    h = [Line2D([], [], color=CCOL[c], lw=2.0, label=CLAB[c]) for c in CONDS]
    h += [Line2D([], [], color="#444444", lw=1.6, ls="-", label="lookup word, not parked"),
          Line2D([], [], color="#444444", lw=1.6, ls="--", label="parked")]
    ax2.legend(handles=h, loc="upper center", bbox_to_anchor=(0.5, -0.16), ncol=3, frameon=False, handletextpad=0.4,
               columnspacing=1.0)
    ax2.grid(True, which="major", color="#e3e3e3", lw=0.7)
    ax2.set_axisbelow(True)
    fig.subplots_adjust(left=0.14, right=0.97, top=0.96, bottom=0.15)
    for ext in ("png", "pdf"):
        fig.savefig(os.path.join(a.out, "fig10_rom_static." + ext), dpi=300)
    plt.close(fig)


if __name__ == "__main__":
    main()
