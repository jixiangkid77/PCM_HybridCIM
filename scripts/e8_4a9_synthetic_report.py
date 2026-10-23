#!/usr/bin/env python3
"""
e8_4a9_synthetic_report.py   (P2R-E8.4a-9)

For a synthetic table written by scripts/e8_4a9_make_synthetic.py: the lowest
one-cell bitline of every designed test cell, read from the screenings (tt,
25 C, 1.80 V, every row, each read after a read of row 0 and 90 ns of
precharge) and from the condition runs of the table, grouped by the design
(Z: zero cells joined to the bitline at the top of the column; T: transistors
below them; L: zero cells directly above the cell, below the transistors;
neighbour types). Called by scripts/e8_4a9_rom_tables.sh in its summaries; can
also be run alone. Only reads.

Usage:
  python3 scripts/e8_4a9_synthetic_report.py --paper2 /mnt/d/Project/hybrid_memory/paper2
"""
import argparse
import glob
import json
import os
import statistics


def vm_levels(work):
    out = {}
    f = os.path.join(work, "vm", "vm.txt")
    if os.path.isfile(f):
        for line in open(f):
            tk = line.split()
            if len(tk) >= 2:
                try:
                    out[tk[0]] = float(tk[1])
                except ValueError:
                    pass
    return out


def reads(result_json):
    """{row: {col: lowest one-cell bitline}} of the complete reads of rows >= 1"""
    r = json.load(open(result_json))
    out = {}
    for cy, x in zip(r["meta"]["cycles"], r["cycles"]):
        if cy["kind"] == "read" and x.get("complete") and cy["row"] >= 1 and x.get("bl1_by_col"):
            d = out.setdefault(cy["row"], {})
            for c, v in x["bl1_by_col"].items():
                d[int(c)] = min(v, d.get(int(c), 9.0))
    return out


def fmt(vs):
    if not vs:
        return f"{'-':>23}"
    return f"{min(vs):6.3f} {statistics.mean(vs):6.3f} ({len(vs):2d})"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--paper2", required=True)
    ap.add_argument("--work", default=None, help="default reports/e8_rom/e8_4a9")
    ap.add_argument("--in-dir", default=None, help="default <work>/tables")
    ap.add_argument("--rows", type=int, default=48)
    a = ap.parse_args()
    work = a.work or os.path.join(a.paper2, "reports", "e8_rom", "e8_4a9")
    ind = a.in_dir or os.path.join(work, "tables")
    vm = vm_levels(work)
    designs = sorted(glob.glob(os.path.join(ind, "*.bin.json")))
    if not designs:
        print("   no synthetic table")
        return
    for dj in designs:
        d = json.load(open(dj))
        t = d["table"]
        print(f"   {t}: design {dj}")
        print("   V = lowest one-cell bitline while evaluating (V): lowest, mean (number of cells); tt, 25 C, 1.80 V, "
              f"switching level {vm.get('tt:25:1.80', float('nan')):.3f} V")
        meas = {}
        for k in range(len(d["macros"])):
            n = f"{t}_r{a.rows}k{k}"
            rj = os.path.join(work, n, "tt_cs", "result.json")
            if os.path.isfile(rj):
                meas[f"k{k}"] = reads(rj)
            else:
                print(f"      {n}: no screening result yet")
        allc = []
        for k, cols in d["macros"].items():
            if k not in meas:
                continue
            m = meas[k]
            groups = {}
            for c, info in cols.items():
                c = int(c)
                rows = [info["row"]] if info["row"] is not None else sorted(m)
                for r in rows:
                    v = m.get(r, {}).get(c)
                    if v is None:
                        continue
                    T = info["T"] if info["T"] is not None else r
                    key = (info["design"], info.get("nb", ""), info["Z"], T, info["L"], r)
                    groups.setdefault(key, []).append(v)
                    allc.append((v, k, r, c, info["design"], info.get("nb", ""), info["Z"], T, info["L"]))
            print(f"\n   {k}:")
            if k == "k1":
                prof = {}
                for (des, nb, Z, T, L, r), vs in groups.items():
                    if des.startswith("k1 S"):
                        prof.setdefault(nb.split("/")[0], {}).setdefault(r, []).extend(vs)
                for nb, pr in sorted(prof.items()):
                    print(f"      S columns (Z 0, T = row, L 0), neighbours {nb}: row: lowest V")
                    rs = sorted(pr)
                    for i in range(0, len(rs), 8):
                        print("         " + "  ".join(f"{r:2d}: {min(pr[r]):.3f}" for r in rs[i:i + 8]))
                print(f"      {'design':<14} {'neighbours':<22} {'Z':>2} {'T':>2} {'L':>2} {'row':>3} | {'V lowest   mean   (n)':>23}")
                for key in sorted((g for g in groups if not g[0].startswith("k1 S")), key=lambda g: (g[1], g[0], -g[5])):
                    des, nb, Z, T, L, r = key
                    print(f"      {des:<14} {nb:<22} {Z:2d} {T:2d} {L:2d} {r:3d} | {fmt(groups[key])}")
            else:
                print(f"      {'design':<38} {'neighbours':<24} {'Z':>2} {'T':>2} {'L':>2} {'row':>3} | {'V lowest   mean   (n)':>23}")
                for key in sorted(groups, key=lambda g: min(groups[g])):
                    des, nb, Z, T, L, r = key
                    print(f"      {des:<38} {nb:<24} {Z:2d} {T:2d} {L:2d} {r:3d} | {fmt(groups[key])}")
        if allc:
            allc.sort()
            print("\n   the 10 lowest designed cells at tt:")
            for v, k, r, c, des, nb, Z, T, L in allc[:10]:
                print(f"      {v:.3f} V  margin {v - vm.get('tt:25:1.80', float('nan')):+.3f} V  {k} row {r:2d} col {c:3d}  "
                      f"{des}  Z {Z} T {T} L {L}  neighbours {nb}")
        # condition runs of the table
        for cd in sorted(glob.glob(os.path.join(work, t, "corner_*"))):
            rj = os.path.join(cd, "result.json")
            mf = os.path.join(cd, "macro")
            if not (os.path.isfile(rj) and os.path.isfile(mf)):
                continue
            macro = open(mf).read().strip()
            k = "k" + macro.rsplit("k", 1)[-1]
            cond = os.path.basename(cd)[len("corner_"):]
            ckey = next((c for c in vm if cond == "{}_{}C_{}".format(*c.split(":")).replace("-", "m").replace(".", "v")),
                        None)
            m = reads(rj)
            got = []
            for r, cols in m.items():
                for c, v in cols.items():
                    info = d["macros"].get(k, {}).get(str(c))
                    if info and (info["row"] == r or info["row"] is None):
                        got.append((v, r, c, info["design"], info.get("nb", "")))
            got.sort()
            lvl = vm.get(ckey, float("nan")) if ckey else float("nan")
            print(f"\n   condition {cond} ({macro}), switching level {lvl:.3f} V: the 5 lowest designed cells")
            for v, r, c, des, nb in got[:5]:
                print(f"      {v:.3f} V  margin {v - lvl:+.3f} V  row {r:2d} col {c:3d}  {des}  neighbours {nb}")


if __name__ == "__main__":
    main()
