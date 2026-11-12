#!/usr/bin/env python3
"""Fig. 3 of the TVLSI manuscript: top-1 accuracy under drift at the 5-bit ADC readout.

Data and rules as scripts/fig06_accuracy.py: LeNet-5 / MNIST from
reports/accuracy/lenet_imc_full_pre.json (key '<arm>|5b|<t>', arm 'algo_only'
for no protection), ResNet-50 / ImageNet from reports/accuracy/
final_imc_results.json (rows with readout 'adc_pre'); mean and population
standard deviation over seeds; the three schemes are drawn at t / 1.58, t and
1.58 t so that their error bars do not cover each other. Only the size (one
column) and the layout differ.

Usage: python3 scripts/tvlsi/fig3_accuracy.py --paper2 . --out figures/tvlsi
"""
import argparse
import json
import os
import statistics as st
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tvlsi_style as S  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402

C_NONE, C_UNI, C_LA = "#7f7f7f", "#2a6fb0", "#c0392b"
DODGE = 0.20
ARMS = [("none", "no protection", C_NONE, "s", "-"),
        ("uniform", "uniform", C_UNI, "o", "--"),
        ("layer_aware", "layer-aware", C_LA, "^", "-")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".")
    ap.add_argument("--out", default="figures/tvlsi")
    a = ap.parse_args()
    acc = os.path.join(a.paper2, "reports", "accuracy")
    ld = json.load(open(os.path.join(acc, "lenet_imc_full_pre.json")))
    rd = json.load(open(os.path.join(acc, "final_imc_results.json")))
    lt = ld["meta"]["times"]
    lclean = ld["meta"]["clean"] * 100

    def lenet(arm):
        k = "algo_only" if arm == "none" else arm
        m = [ld["data"][f"{k}|5b|{t:.0e}"]["mean"] * 100 for t in lt]
        s = [ld["data"][f"{k}|5b|{t:.0e}"]["std"] * 100 for t in lt]
        return m, s

    rclean = rd["clean"]["top1"] * 100
    rt = sorted({r["drift_t"] for r in rd["rows"]})

    def resnet(arm):
        m, s = [], []
        for t in rt:
            v = [r["top1"] * 100 for r in rd["rows"]
                 if r["readout"] == "adc_pre" and r["arm"] == arm and r["drift_t"] == t]
            m.append(sum(v) / len(v))
            s.append(st.pstdev(v) if len(v) > 1 else 0.0)
        return m, s

    print(f"references: LeNet-5 {lclean:.2f} %, ResNet-50 {rclean:.2f} %")
    for name, fn in (("LeNet-5", lenet), ("ResNet-50", resnet)):
        for arm, lab, *_ in ARMS:
            m, s = fn(arm)
            print(name, lab, " ".join(f"{v:.2f}" for v in m))

    fig, (axA, axB) = plt.subplots(1, 2, figsize=(S.COL1, 1.85), gridspec_kw={"wspace": 0.40})
    for ax, xs, fn, clean in ((axA, lt, lenet, lclean), (axB, rt, resnet, rclean)):
        ax.axhline(clean, color="0.4", lw=0.8, ls=":", zorder=1, label="drift-free")
        for k, (arm, lab, col, mk, lsty) in enumerate(ARMS):
            m, s = fn(arm)
            xd = [x * 10 ** (DODGE * (k - 1)) for x in xs]
            ax.errorbar(xd, m, yerr=s, color=col, marker=mk, ls=lsty, lw=1.0, ms=3.2, mfc=col, mec=col,
                        capsize=1.5, elinewidth=0.6, label=lab, zorder=3)
        ax.set_xscale("log")
        ax.set_xticks([1, 1e2, 1e4, 1e6])
        ax.set_xticks([], minor=True)
        ax.set_xlim(0.40, 2.5e6)
        ax.set_xlabel("Drift time $t$ (s)")
        S.grid(ax)
    lo = min(mm - ss for arm, *_ in ARMS for mm, ss in zip(*lenet(arm)))
    axA.set_ylim(2 * int(lo // 2) - 1, 100.3)
    axB.set_ylim(-4, 80)
    axA.set_ylabel("Top-1 accuracy (%)")
    S.panel_title(axA, "(a) LeNet-5")
    S.panel_title(axB, "(b) ResNet-50")
    h, l = axB.get_legend_handles_labels()
    order = [l.index(x) for x in ["no protection", "uniform", "layer-aware", "drift-free"]]
    axB.legend([h[i] for i in order], [l[i] for i in order], loc="center left", bbox_to_anchor=(0.0, 0.47),
               frameon=False, handlelength=1.8, fontsize=S.FS_SMALL)
    fig.subplots_adjust(left=0.12, right=0.965, top=0.89, bottom=0.215)
    S.save(fig, a.out, "fig3_accuracy")


if __name__ == "__main__":
    main()
