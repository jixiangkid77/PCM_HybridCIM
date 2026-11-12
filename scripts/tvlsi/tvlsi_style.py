"""Common style of the figures of the TVLSI manuscript.

Every figure is drawn at its printed size: one column is 3.5 in wide and the
full page width 7.16 in, so the font sizes below are the sizes on the page
(8.5 pt text, 8 pt tick labels, at least 7.5 pt anywhere). Colors as in the
other figures of the study: green the digital logic, teal the SRAM partition,
purple the analog crossbar, rust the address map.
"""
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

COL1 = 3.5     # one column (in)
COL2 = 7.16    # page width (in)

G_EDGE, G_FILL = "#2e7d32", "#e3efe3"      # digital logic
T_EDGE, T_FILL = "#2a6f7d", "#dcebee"      # SRAM partition
P_EDGE, P_FILL = "#6a1b9a", "#ece0f3"      # analog crossbar
R_EDGE, R_FILL = "#b5643b", "#f6e6dc"      # address map
RM_EDGE, RM_FILL = "#7a3b1d", "#e9c2a6"    # address-map ROM macros
N_EDGE, N_FILL = "#777777", "#ececec"      # neutral
GOLD, GOLD_D = "#e6b422", "#8a6a00"        # drift-sensitive weights
RED = "#c0392b"
INK = "#1e1e1e"
WHITE = dict(boxstyle="square,pad=0.1", fc="white", ec="none")

FS = 8.5       # text
FS_TICK = 8.0
FS_SMALL = 7.5

plt.rcParams.update({
    "font.family": "Liberation Sans",
    "mathtext.fontset": "custom", "mathtext.rm": "Liberation Sans",
    "mathtext.it": "Liberation Sans:italic", "mathtext.bf": "Liberation Sans:bold",
    "font.size": FS, "axes.labelsize": FS, "axes.titlesize": FS,
    "xtick.labelsize": FS_TICK, "ytick.labelsize": FS_TICK, "legend.fontsize": FS_SMALL,
    "axes.linewidth": 0.6, "xtick.major.width": 0.6, "ytick.major.width": 0.6,
    "xtick.minor.width": 0.4, "ytick.minor.width": 0.4,
    "xtick.major.size": 2.5, "ytick.major.size": 2.5, "xtick.minor.size": 1.5, "ytick.minor.size": 1.5,
    "xtick.major.pad": 2.0, "ytick.major.pad": 2.0, "axes.labelpad": 2.0,
    "lines.linewidth": 1.0, "lines.markersize": 3.5,
    "legend.handlelength": 1.6, "legend.handletextpad": 0.4, "legend.borderaxespad": 0.3,
    "legend.borderpad": 0.3, "legend.labelspacing": 0.25, "legend.columnspacing": 1.0,
    "pdf.fonttype": 42, "savefig.dpi": 600,
})


def panel_title(ax, text, x=0.0, y=1.02):
    """Panel label and title, left-aligned above the axes."""
    ax.text(x, y, text, transform=ax.transAxes, ha="left", va="bottom", fontsize=FS, fontweight="bold")


def grid(ax, axis="both"):
    ax.grid(True, axis=axis, color="#e2e2e2", lw=0.4)
    ax.set_axisbelow(True)


def box(ax, x, y, w, h, text, edge, fill, fs=FS, lw=0.9, color=INK, weight="normal", r=0.06):
    """Rounded box centered at (x, y) in data units, with centered text."""
    ax.add_patch(FancyBboxPatch((x - w / 2, y - h / 2), w, h,
                                boxstyle=f"round,pad=0.0,rounding_size={r}", ec=edge, fc=fill, lw=lw))
    if text:
        ax.text(x, y, text, ha="center", va="center", fontsize=fs, color=color, linespacing=1.12,
                fontweight=weight)


def arrow(ax, x0, y0, x1, y1, color=INK, lw=0.9, ms=7, style="-|>", ls="-"):
    ax.annotate("", xy=(x1, y1), xytext=(x0, y0),
                arrowprops=dict(arrowstyle=style, color=color, lw=lw, mutation_scale=ms,
                                shrinkA=0, shrinkB=0, linestyle=ls))


def save(fig, out, name):
    os.makedirs(out, exist_ok=True)
    fig.savefig(os.path.join(out, name + ".pdf"))
    fig.savefig(os.path.join(out, name + ".png"), dpi=300)
    plt.close(fig)
    print("wrote", os.path.join(out, name + ".pdf"))
