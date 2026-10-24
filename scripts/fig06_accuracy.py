#!/usr/bin/env python3
"""Fig. 6: top-1 accuracy under conductance drift at the 5-bit ADC readout.

Same data and plotting rules as figure5.py (2026-06-25): LeNet-5 / MNIST from
reports/accuracy/lenet_imc_full_pre.json (key '<arm>|5b|<t>', arm 'algo_only'
for no protection), ResNet-50 / ImageNet from reports/accuracy/
final_imc_results.json (rows with readout 'adc_pre'); mean and population
standard deviation over seeds. Only the canvas, the fonts, the file names, the
lower limit of (a) (set from the data so that no error bar is cut), the
lower-case legend entries and the horizontal offsets differ from figure5.py: the
three schemes are drawn at t / 1.58, t and 1.58 t (DODGE decades apart on the
logarithmic axis) so that error bars and markers at the same drift time do not
cover each other (the time axis is widened to keep them inside); the values belong
to the drift time t on the axis.

Usage: python3 scripts/fig06_accuracy.py --paper2 . --out figures
"""
import argparse
import json
import os
import statistics as st

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

C_NONE, C_UNI, C_LA = "#7f7f7f", "#2a6fb0", "#c0392b"
DODGE = 0.20   # horizontal offset between the schemes, in decades of t (factor 10**0.2 = 1.58)
ARMS = [("none", "no protection", C_NONE, "s", "-"),
        ("uniform", "uniform", C_UNI, "o", "--"),
        ("layer_aware", "layer-aware", C_LA, "^", "-")]

plt.rcParams.update({
    "mathtext.fontset": "custom", "mathtext.rm": "Liberation Sans", "mathtext.it": "Liberation Sans:italic",
    "mathtext.bf": "Liberation Sans:bold",
    "font.family": "Liberation Sans", "font.size": 15, "axes.labelsize": 15,
    "xtick.labelsize": 14, "ytick.labelsize": 14, "legend.fontsize": 13,
    "axes.linewidth": 1.0, "pdf.fonttype": 42,
})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".")
    ap.add_argument("--out", default="figures")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
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

    for name, xs, fn in (("LeNet-5", lt, lenet), ("ResNet-50", rt, resnet)):
        for arm, lab, *_ in ARMS:
            m, s = fn(arm)
            print(name, lab, " ".join(f"{v:.2f}" for v in m))

    fig, (axA, axB) = plt.subplots(2, 1, figsize=(6.5, 8.9), gridspec_kw={"hspace": 0.38})
    for ax, xs, fn, clean in ((axA, lt, lenet, lclean), (axB, rt, resnet, rclean)):
        ax.axhline(clean, color="0.45", lw=1.2, ls=":", zorder=1, label="INT8 software reference")
        for k, (arm, lab, col, mk, lsty) in enumerate(ARMS):
            m, s = fn(arm)
            xd = [x * 10 ** (DODGE * (k - 1)) for x in xs]
            ax.errorbar(xd, m, yerr=s, color=col, marker=mk, ls=lsty, lw=2.0, ms=7, mfc=col, mec=col,
                        capsize=3, elinewidth=1.1, label=lab, zorder=3)
        ax.set_xscale("log")
        ax.set_ylabel("Top-1 accuracy (%)")
        ax.grid(True, which="major", color="0.85", lw=0.8, ls=":", zorder=0)
        ax.set_xticks([1, 1e2, 1e4, 1e6])
        ax.set_xlim(0.40, 2.5e6)   # 0.2 decade beyond the outermost offset points
        ax.set_xlabel("Drift time $t$ (s)")
    axA.set_title("(a) LeNet-5 / MNIST", loc="left", fontsize=15, fontweight="bold")
    axB.set_title("(b) ResNet-50 / ImageNet", loc="left", fontsize=15, fontweight="bold")
    lo = min(mm - ss for arm, *_ in ARMS for mm, ss in zip(*lenet(arm)))
    print(f"(a) lowest mean - sd: {lo:.2f} %")
    axA.set_ylim(2 * int(lo // 2) - 1, 99.8)
    axB.set_ylim(-4, 80)
    h, l = axB.get_legend_handles_labels()
    order = [l.index(x) for x in ["no protection", "uniform", "layer-aware", "INT8 software reference"]]
    axB.legend([h[i] for i in order], [l[i] for i in order], loc="center left", bbox_to_anchor=(0.03, 0.50),
               frameon=True, framealpha=0.95, edgecolor="0.7", handlelength=2.2)
    fig.subplots_adjust(left=0.13, right=0.97, top=0.96, bottom=0.07)
    for ext in ("png", "pdf"):
        fig.savefig(os.path.join(a.out, "fig06_accuracy." + ext), dpi=300)
    plt.close(fig)


if __name__ == "__main__":
    main()
