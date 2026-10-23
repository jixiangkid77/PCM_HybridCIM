#!/usr/bin/env python3
"""
e8_4a9_make_synthetic.py   (P2R-E8.4a-9, synthetic table)

Writes a synthetic address-map table, e8rom_X_syn_l00_16x2496 (16 bit x 2,496
words, the size of a real table, so the E8.4a-8 flow cuts it into the same four
r48 macros), whose contents are chosen cell by cell to measure how the one-cell
bitline of a read depends on the contents above the read cell and in the two
neighbouring columns. It is not an address map; its verdict is not a verdict on
the design but a measurement of the content dependence.

Column c = bit x 13 + word (the bench's convention; neighbouring columns are
physically adjacent). Odd columns hold the test patterns, even columns are the
neighbours. A column is a chain of NMOS from the bitline (row 0 side) to the
footer; zero cells are shorted transistors. Terms for a 1 cell at row R:
  Z  zero cells from row 0 down, joined to the bitline (precharged with it);
  T  the 1 cells (transistors) below them;
  L  the zero cells directly above the cell, below the transistors (isolated).
Z + T + L = R. Neighbour (aggressor) types are given by their contents above R;
all have a zero cell at the read row, so they discharge in the same read.

Macros (every row of every macro is read at tt by the flow, each after a read
of row 0):
  k0  the sandbox pattern of 2026-10-15 (identical bits): target row 47; 52
      (T, L) combinations with Z = 47 - T - L; neighbours all zero cells
      (joined, columns < 104) or all 1 cells (columns >= 104)
  k1  depth: neighbours all zero cells (columns < 104) or a 1 cell at row 0 and
      zero cells below (columns >= 104); test columns S (1 cells from row 0 to
      47: the read of each row tests Z = 0, T = R) and W(R) (1 cell at row 0,
      zero cells to R - 1, the target at R, zero cells below) for 14 depths,
      and W2(R) (1 cells at rows 0-1) for 3 depths
  k2  neighbour types, target row 47: 26 blocks of 8 columns (n t n t n t n t),
      10 neighbour types; targets (Z, T, L) = (0, 1, 46), (0, 47, 0),
      (0, 11, 36), (8, 1, 38)
  k3  patterns like the real lowest cell (A_pcm_l00 r48k3 row 43 column 12:
      Z = 0, T = 11, L = 32; neighbours with 11 transistors at the top and zero
      cells below): at row 43 and at row 47; the pattern (0, 1, 46) with the
      same neighbours; and one-sided cells (one neighbour all zero cells, the
      other a 1 cell at the read row)

Usage:
  python3 scripts/e8_4a9_make_synthetic.py --paper2 /mnt/d/Project/hybrid_memory/paper2
Writes reports/e8_rom/e8_4a9/tables/e8rom_X_syn_l00_16x2496.bin (4,992 bytes),
its design (.bin.json) and appends the table to selected.txt (once).
"""
import argparse
import hashlib
import json
import os
import random

ROWS, WPR, WB = 48, 13, 16
COLS = WPR * WB
R = ROWS - 1
K0_COMBOS = [(1, 46), (1, 44), (3, 44), (1, 40), (2, 40), (4, 40), (7, 40),
             (1, 36), (2, 36), (4, 36), (8, 36), (11, 36),
             (1, 32), (2, 32), (4, 32), (8, 32), (11, 32), (15, 32),
             (1, 28), (4, 28), (11, 28), (19, 28),
             (1, 24), (4, 24), (11, 24), (23, 24),
             (1, 20), (11, 20), (27, 20),
             (1, 16), (4, 16), (11, 16), (31, 16),
             (1, 12), (11, 12), (35, 12),
             (1, 8), (4, 8), (11, 8), (39, 8),
             (1, 4), (11, 4), (43, 4),
             (1, 2), (11, 2), (47, 0), (11, 0), (0, 47),
             (2, 45), (5, 42), (6, 30), (16, 31)]


def column(z, t, l, target, below):
    """cells of rows 0..47: z zero cells, t ones, l zero cells, the target 1 cell at row `target`
    (= z + t + l), then `below` (0 or 1) to row 47"""
    assert z + t + l == target <= R
    col = [0] * z + [1] * t + [0] * l + [1] + [below] * (R - target)
    assert len(col) == ROWS
    return col


NEIGHBOURS = {
    "joined_all": lambda: [0] * ROWS,
    "iso_T1": lambda: [1] + [0] * R,
    "iso_T4": lambda: [1] * 4 + [0] * (ROWS - 4),
    "iso_T11": lambda: [1] * 11 + [0] * (ROWS - 11),
    "iso_T32": lambda: [1] * 32 + [0] * (ROWS - 32),
    "joined_half": lambda: [0] * 24 + [1] * 23 + [0],
    "joined_40": lambda: [0] * 40 + [1] * 7 + [0],
    "alternating": lambda: [1 if r % 2 == 0 else 0 for r in range(R)] + [0],
    "ones": lambda: [1] * R + [0],
    "random50": None,
}


def k0():
    cols, meta = [None] * COLS, {}
    for c in range(COLS):
        if c % 2 == 0:
            cols[c] = ([0] * R if c < 104 else [1] * R) + [0]
        else:
            T, L = K0_COMBOS[(c // 2) % 52]
            Z = R - T - L
            cols[c] = column(Z, T, L, R, 1)
            if T == 0:                      # no transistor above: the zero cells are joined to the bitline
                Z, L = Z + L, 0
            meta[c] = {"design": "k0", "Z": Z, "T": T, "L": L, "row": R,
                       "nb": ("joined_all" if c - 1 < 104 else "ones") + "/" +
                             (("joined_all" if c + 1 < 104 else "ones") if c + 1 < COLS else "-")}
    return cols, meta


def k1():
    cols, meta = [None] * COLS, {}
    depths = [47, 45, 43, 41, 39, 35, 31, 27, 23, 19, 15, 11, 7, 3]
    tests = [("S", None)] * 4 + [("W", d) for d in depths for _ in range(3)] + [("W2", d) for d in (47, 31, 15) for _ in range(2)]
    assert len(tests) == 52
    for c in range(COLS):
        grp = "joined_all" if c < 104 else "iso_T1"
        if c % 2 == 0:
            cols[c] = NEIGHBOURS[grp]()
            continue
        kind, d = tests[(c // 2) % 52]
        nbl = "joined_all" if c - 1 < 104 else "iso_T1"
        nbr = ("joined_all" if c + 1 < 104 else "iso_T1") if c + 1 < COLS else "-"
        if kind == "S":
            cols[c] = [1] * ROWS
            meta[c] = {"design": "k1 S (every row: Z 0, T = row, L 0)", "Z": 0, "T": None, "L": 0, "row": None,
                       "nb": f"{nbl}/{nbr}"}
        else:
            t = 1 if kind == "W" else 2
            cols[c] = column(0, t, d - t, d, 0)
            meta[c] = {"design": f"k1 {kind}", "Z": 0, "T": t, "L": d - t, "row": d, "nb": f"{nbl}/{nbr}"}
    return cols, meta


def k2():
    cols, meta = [None] * COLS, {}
    types = ["joined_all", "iso_T1", "iso_T4", "iso_T11", "iso_T32", "joined_half", "joined_40", "alternating",
             "ones", "random50"]
    order = types * 2 + types[:6]
    assert len(order) == 26
    rng = random.Random(20261015)
    targets = [(0, 1, 46), (0, 47, 0), (0, 11, 36), (8, 1, 38)]
    nbtype = {}
    for b in range(26):
        ty = order[b]
        for j in range(8):
            c = 8 * b + j
            if c % 2 == 0:
                nbtype[c] = ty
                cols[c] = ([1 if rng.random() < 0.5 else 0 for _ in range(R)] + [0]) if ty == "random50" \
                    else NEIGHBOURS[ty]()
    for b in range(26):
        for j in range(8):
            c = 8 * b + j
            if c % 2 == 1:
                Z, T, L = targets[(j - 1) // 2]
                cols[c] = column(Z, T, L, R, 1)
                meta[c] = {"design": "k2", "Z": Z, "T": T, "L": L, "row": R,
                           "nb": f"{nbtype[c - 1]}/{nbtype.get(c + 1, '-')}"}
    return cols, meta


def k3():
    cols, meta = [None] * COLS, {}
    for c in range(COLS):
        if c < 192:
            if c % 2 == 0:
                cols[c] = NEIGHBOURS["iso_T11"]()
                continue
            if c < 64:
                cols[c] = column(0, 11, 32, 43, 0)
                meta[c] = {"design": "k3 like A_pcm_l00 (row 43)", "Z": 0, "T": 11, "L": 32, "row": 43}
            elif c < 128:
                cols[c] = column(0, 11, 36, 47, 1)
                meta[c] = {"design": "k3 like A_pcm_l00 at row 47", "Z": 0, "T": 11, "L": 36, "row": 47}
            else:
                cols[c] = column(0, 1, 46, 47, 1)
                meta[c] = {"design": "k3 (0, 1, 46), neighbours iso_T11", "Z": 0, "T": 1, "L": 46, "row": 47}
            meta[c]["nb"] = "iso_T11/" + ("iso_T11" if c + 1 < 192 else "?")
        else:
            j = (c - 192) % 4             # aggressor, test, quiet, test
            if j == 0:
                cols[c] = NEIGHBOURS["joined_all"]()
            elif j == 2:
                cols[c] = [1] * ROWS         # quiet: a 1 cell at row 47 (not discharging)
            else:
                cols[c] = column(0, 1, 46, 47, 1)
                meta[c] = {"design": "k3 one-sided (0, 1, 46)", "Z": 0, "T": 1, "L": 46, "row": 47,
                           "nb": "joined_all/quiet" if j == 1 else "quiet/" + ("joined_all" if c + 1 < COLS else "-")}
    # the test column at 191 has neighbour 192 (joined_all): mark it
    meta[191]["nb"] = "iso_T11/joined_all"
    return cols, meta


def to_bytes(cols):
    """column lists -> 1,248 bytes of one macro (bench bitmap: bm[r][bit*13 + word] = rowbits[bit + word*16])"""
    out = bytearray()
    for r in range(ROWS):
        rb = [0] * COLS
        for word in range(WPR):
            for bit in range(WB):
                rb[bit + word * WB] = cols[bit * WPR + word][r]
        for i in range(0, COLS, 8):
            out.append(int("".join(str(x) for x in rb[i:i + 8]), 2))
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--paper2", required=True)
    ap.add_argument("--name", default="e8rom_X_syn_l00_16x2496")
    a = ap.parse_args()
    out_dir = os.path.join(a.paper2, "reports", "e8_rom", "e8_4a9", "tables")
    os.makedirs(out_dir, exist_ok=True)
    data, design = b"", {}
    for k, fn in enumerate((k0, k1, k2, k3)):
        cols, meta = fn()
        assert all(len(x) == ROWS for x in cols)
        data += to_bytes(cols)
        design[f"k{k}"] = {str(c): m for c, m in sorted(meta.items())}
    assert len(data) == 4 * ROWS * WPR * 2 == 4992
    f = os.path.join(out_dir, a.name + ".bin")
    open(f, "wb").write(data)
    json.dump({"table": a.name, "rows": ROWS, "words_per_row": WPR, "column": "bit x 13 + word",
               "macros": design}, open(f + ".json", "w"), indent=1)
    sel = os.path.join(out_dir, "selected.txt")
    have = open(sel).read().split() if os.path.isfile(sel) else []
    if a.name not in have:
        have.append(a.name)
    with open(sel, "w") as fh:
        fh.write(" ".join(have) + "\n")
    words = [(data[2 * i] << 8) | data[2 * i + 1] for i in range(len(data) // 2)]
    zeros = sum(16 - bin(w).count("1") for w in words)
    print(f"P2R-E8.4a-9 synthetic table: {f}")
    print(f"   md5 {hashlib.md5(data).hexdigest()}, {len(data)} bytes, {len(words)} words, zero bits {zeros} of "
          f"{16 * len(words)}; test columns per macro: " +
          ", ".join(f"{k} {len(v)}" for k, v in design.items()))
    print(f"   selected.txt: {' '.join(have)}")


if __name__ == "__main__":
    main()
