#!/usr/bin/env python3
"""
e8_4a8_margin_screen.py   (P2R-E8.4a-8, part 1)

E8.4a-7 simulated 12 of the 100 address-map tables (both models, lanes 0, 12,
24, both sides) and read every row of every macro (r48, tt, 25 C, 1.80 V, CS
10 ns after the clock edge). The lowest 1-cell bitlines were 1 cells whose two
neighbouring columns discharge in the same read (column = bit x 13 + word),
with a long string of 0 cells directly above them; the lowest of all
(A_pcm_l00 k3, row 43, column 12: 1.136 V, 32 zero cells above, 114 zero cells
in the row) lies far below a linear fit over all cells. E8.6a-2 found
two-sided cells with longer strings above them in tables that were not
simulated (up to 47 against 42).

This script:
  1. reads the 1-cell bitlines of the E8.4a-7 screenings (every row, tt) and
     the features of each cell: discharging neighbours (0, 1, 2), row, zero
     cells directly above (string), 1 cells above, zero cells in the row;
  2. fits, for the two-sided and the one-sided cells separately, a linear model
     of the bitline in these features with string^2 and the products string x
     row-zeros and string x row (least squares); the cells without a
     discharging neighbour are not modelled (E8.4a-7: lowest 1.708 V);
  3. checks the model on the lowest cell of every simulated macro, leaving
     each table out of the fit in turn: the predicted against the measured
     minimum, the rank of the macros;
  4. predicts every 1 cell of every macro of all 100 tables (r48, from the RTL
     data files, as E8.6a) and ranks the tables by their lowest predicted
     bitline;
  5. selects tables not simulated for part 2 (the E8.4a-7 flow on them), two
     ways, because the model may not capture the lowest cells: (a) the lowest
     predicted bitlines (--n-model, default 4); (b) the longest strings of 0
     cells above a two-sided cell, longer than in any simulated table
     (--n-string, default 2); at most --max-tables (6). Writes their
     2,496-word data files and selected.txt.

The model ranks tables for simulation; it is not a margin. The margins come
from part 2 (simulation).

Usage:
  python3 scripts/e8_4a8_margin_screen.py --paper2 /mnt/d/Project/hybrid_memory/paper2
Reads reports/e8_rom/e8_4a7/ (bins, screenings), data/rtl_inputs_{A,B}_v3/,
scripts/e8_4_rom_bench.py; writes reports/e8_rom/e8_4a8/screen.json and
reports/e8_rom/e8_4a8/tables/<table>.bin, selected.txt.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import statistics
import sys
import time

K = 25
LAYERS = ["conv1", "conv2", "fc1", "fc2", "fc3"]
DEPTH = [6, 96, 1920, 420, 40]
MISS = 0xFFFF
FEATS = ["1", "row", "string", "string^2", "ones_above", "row_zeros", "string x row_zeros", "string x row"]


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def read_memh(path, depth):
    """$readmemh replica (as scripts/e8_3_rom_tools.py): unloaded words keep 0xFFFF"""
    mem = [MISS] * depth
    addr = 0
    with open(path) as fh:
        for raw in fh:
            line = raw.split("//", 1)[0]
            for tok in line.split():
                if tok.startswith("@"):
                    addr = int(tok[1:], 16)
                    continue
                if addr < depth:
                    mem[addr] = int(tok, 16)
                addr += 1
    return mem


def table_words(paper2, model, side, lane, n_words):
    d = os.path.join(paper2, "data", f"rtl_inputs_{model}_v3")
    words = []
    for li, name in enumerate(LAYERS):
        f = os.path.join(d, f"addr_to_slot_{name}_{side}_lane{lane:02d}.hex")
        if not os.path.isfile(f):
            sys.exit(f"missing table file {f}")
        words += read_memh(f, DEPTH[li])
    words = words + [MISS] * max(0, n_words - len(words))
    return words[:n_words]


def to_bytes(words):
    return bytes(x for v in words for x in ((v >> 8) & 0xFF, v & 0xFF))


def features(bm):
    """per 1 cell of rows >= 1: (row, col, neighbours discharging, string above, ones above, row zeros)"""
    rows, cols = len(bm), len(bm[0])
    run = [[0] * cols for _ in range(rows)]       # zero cells directly above (contiguous)
    ones = [[0] * cols for _ in range(rows)]      # 1 cells above
    for c in range(cols):
        r_, o_ = 0, 0
        for r in range(rows):
            run[r][c], ones[r][c] = r_, o_
            if bm[r][c] == 0:
                r_ += 1
            else:
                r_ = 0
                o_ += 1
    out = []
    for r in range(1, rows):
        g = bm[r]
        rz = sum(1 for x in g if x == 0)
        for c in range(cols):
            if g[c] != 1:
                continue
            nb = (c > 0 and g[c - 1] == 0) + (c < cols - 1 and g[c + 1] == 0)
            out.append((r, c, nb, run[r][c], ones[r][c], rz))
    return out


def xrow(r, s, o, z):
    return [1.0, r, s, s * s, o, z, s * z, s * r]


def lsq(X, y):
    """least squares by the normal equations (few unknowns), partial pivoting"""
    n = len(X[0])
    M = [[sum(a[i] * a[j] for a in X) for j in range(n)] for i in range(n)]
    v = [sum(a[i] * t for a, t in zip(X, y)) for i in range(n)]
    for i in range(n):
        p = max(range(i, n), key=lambda k: abs(M[k][i]))
        if abs(M[p][i]) < 1e-12:
            return None
        M[i], M[p], v[i], v[p] = M[p], M[i], v[p], v[i]
        for k in range(n):
            if k != i:
                f = M[k][i] / M[i][i]
                M[k] = [x - f * zz for x, zz in zip(M[k], M[i])]
                v[k] -= f * v[i]
    return [v[i] / M[i][i] for i in range(n)]


def fit(cells):
    """per class (1, 2 neighbours): coefficients, r^2, n, residual SD, lowest residual"""
    m = {}
    for nb in (1, 2):
        pts = [p for p in cells if p["nb"] == nb]
        if len(pts) < 2 * len(FEATS):
            continue
        X = [xrow(p["row"], p["string"], p["ones"], p["rz"]) for p in pts]
        y = [p["v"] for p in pts]
        co = lsq(X, y)
        if co is None:
            continue
        pr = [sum(a * b for a, b in zip(co, x)) for x in X]
        res = [t - q for t, q in zip(y, pr)]
        ym = statistics.mean(y)
        ss = sum((t - ym) ** 2 for t in y)
        m[nb] = {"coef": co, "n": len(pts), "r2": 1 - sum(r * r for r in res) / ss if ss > 0 else float("nan"),
                 "res_sd": statistics.pstdev(res), "res_min": min(res)}
    return m


def predict(m, nb, r, s, o, z):
    if nb not in m:
        return None
    return sum(a * b for a, b in zip(m[nb]["coef"], xrow(r, s, o, z)))


def macro_min(m, feats):
    """lowest predicted bitline of a macro and its cell"""
    best = None
    for (r, c, nb, s, o, z) in feats:
        if nb == 0:
            continue
        v = predict(m, nb, r, s, o, z)
        if v is not None and (best is None or v < best[0]):
            best = (v, r, c, nb, s, o, z)
    return best


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--paper2", required=True)
    ap.add_argument("--rows", type=int, default=48)
    ap.add_argument("--wpr", type=int, default=13)
    ap.add_argument("--table-words", type=int, default=2496)
    ap.add_argument("--lanes", type=int, default=K)
    ap.add_argument("--n-model", type=int, default=4)
    ap.add_argument("--n-string", type=int, default=2)
    ap.add_argument("--max-tables", type=int, default=6)
    a = ap.parse_args()
    t0 = time.time()
    root = os.path.join(a.paper2, "reports", "e8_rom")
    w7 = os.path.join(root, "e8_4a7")
    out_dir = os.path.join(root, "e8_4a8")
    here_f = os.path.abspath(__file__)
    bench = os.path.join(os.path.dirname(here_f), "e8_4_rom_bench.py")
    spec = importlib.util.spec_from_file_location("e8bench", bench)
    B = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(B)
    print(f"P2R-E8.4a-8 part 1 (margin screening)  {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"   script : {md5(here_f)}  {here_f}")
    print(f"   bench  : {md5(bench)}  {bench}")
    wb = 2
    suf = f"_16x{a.table_words}"

    # 1. measured cells of the E8.4a-7 screenings (tt)
    cells, macros = [], {}
    tables7 = sorted(f[:-6] for f in os.listdir(os.path.join(w7, "bins")) if f.endswith(".names"))
    for t in tables7:
        names = [x.strip() for x in open(os.path.join(w7, "bins", t + ".names")) if x.strip()]
        for n in names:
            binf = os.path.join(w7, "bins", n + ".bin")
            rj = os.path.join(w7, n, "tt_cs", "result.json")
            if not (os.path.isfile(binf) and os.path.isfile(rj)):
                print(f"   {n}: no screening result, skipped")
                continue
            data = open(binf, "rb").read()
            _, w_, cols, rows = B.organisation(len(data), wb, a.wpr)
            bm = B.bitmap(data, wb, w_, cols)
            feat = {(r, c): (nb, s, o, z) for (r, c, nb, s, o, z) in features(bm)}
            r_ = json.load(open(rj))
            if r_["meta"].get("bitlines") != "all":
                print(f"   {n}: screening without all bitlines, skipped")
                continue
            got = 0
            for cy, x in zip(r_["meta"]["cycles"], r_["cycles"]):
                if cy["kind"] != "read" or not x.get("complete") or cy["row"] == 0 or not x.get("bl1_by_col"):
                    continue
                R = cy["row"]
                for cs, v in x["bl1_by_col"].items():
                    f = feat.get((R, int(cs)))
                    if f is None:
                        continue
                    cells.append({"table": t, "macro": n, "row": R, "col": int(cs), "nb": f[0], "string": f[1],
                                  "ones": f[2], "rz": f[3], "v": v})
                    got += 1
            macros[n] = {"table": t, "feats": features(bm)}
            print(f"   {n}: {got} one cells")
    if not cells:
        sys.exit("no E8.4a-7 screening found")
    print(f"\n1. {len(cells)} measured one cells in {len(macros)} macros of {len(tables7)} tables")
    for nb in (0, 1, 2):
        g = [p["v"] for p in cells if p["nb"] == nb]
        if g:
            print(f"   {nb} neighbours discharging: {len(g):7d} cells, mean {statistics.mean(g):.3f} V, lowest {min(g):.3f} V")

    # 2. the models
    m = fit(cells)
    print("\n2. models of the one-cell bitline (V), least squares; features: " + ", ".join(FEATS))
    for nb, x in sorted(m.items()):
        print(f"   {nb} neighbours: {x['n']} cells, r^2 {x['r2']:.3f}, residual SD {1e3 * x['res_sd']:.1f} mV, lowest "
              f"residual {1e3 * x['res_min']:+.1f} mV; coefficients " +
              ", ".join(f"{f} {c:+.5g}" for f, c in zip(FEATS, x["coef"])))
    lo = sorted(cells, key=lambda p: p["v"])[:8]
    print("   lowest measured cells and the model:")
    for p in lo:
        pv = predict(m, p["nb"], p["row"], p["string"], p["ones"], p["rz"])
        print(f"      {p['v']:.3f} V  {p['macro']:<34} row {p['row']:2d} col {p['col']:3d}  neighbours {p['nb']}  string "
              f"{p['string']:2d}  ones above {p['ones']:2d}  row zeros {p['rz']:3d}  model {pv:.3f} V")

    # 3. check: lowest cell of every simulated macro, each table left out of the fit
    print("\n3. check on the lowest cell of each simulated macro (each table left out of the fit):")
    rows_chk = []
    for t in tables7:
        mt = fit([p for p in cells if p["table"] != t])
        for n, info in macros.items():
            if info["table"] != t:
                continue
            meas = min((p["v"] for p in cells if p["macro"] == n), default=None)
            pm = macro_min(mt, info["feats"])
            if meas is None or pm is None:
                continue
            rows_chk.append((n, meas, pm[0]))
    if rows_chk:
        err = [p - q for _, q, p in rows_chk]
        order_meas = sorted(rows_chk, key=lambda x: x[1])
        order_pred = sorted(rows_chk, key=lambda x: x[2])
        rk = {n: i for i, (n, _, _) in enumerate(order_pred)}
        rm = {n: i for i, (n, _, _) in enumerate(order_meas)}
        nn = len(rows_chk)
        d2 = sum((rk[n] - rm[n]) ** 2 for n, _, _ in rows_chk)
        rho = 1 - 6 * d2 / (nn * (nn * nn - 1)) if nn > 2 else float("nan")
        print(f"   {nn} macros: predicted - measured minimum {1e3 * statistics.mean(err):+.1f} mV on average, "
              f"from {1e3 * min(err):+.1f} to {1e3 * max(err):+.1f} mV; rank correlation (Spearman) {rho:.3f}")
        print("   the 6 lowest measured macros, their predicted minimum and predicted rank:")
        for n, q, p in order_meas[:6]:
            print(f"      {n:<34} measured {q:.3f} V  predicted {p:.3f} V  rank {rk[n] + 1} of {nn}")

    # 4. every macro of all tables
    print(f"\n4. all tables (r{a.rows}, {a.table_words} words, from data/rtl_inputs_<model>_v3): lowest predicted one-cell "
          f"bitline per table")
    per = a.rows * a.wpr
    res = []
    for M in ("A", "B"):
        for side in ("pcm", "sram"):
            for lane in range(a.lanes):
                t = f"e8rom_{M}_{side}_l{lane:02d}{suf}"
                words = table_words(a.paper2, M, side, lane, a.table_words)
                best = None
                smax = (0, None)                 # longest string of 0 cells above a two-sided cell
                for k in range(len(words) // per):
                    data = to_bytes(words[k * per:(k + 1) * per])
                    _, w_, cols, rows = B.organisation(len(data), wb, a.wpr)
                    bm = B.bitmap(data, wb, w_, cols)
                    ft = features(bm)
                    pm = macro_min(m, ft)
                    if pm and (best is None or pm[0] < best[0]):
                        best = (pm[0], k) + pm[1:]
                    for (r, c, nb, s_, o, z) in ft:
                        if nb == 2 and s_ > smax[0]:
                            smax = (s_, (k, r, c))
                res.append({"table": t, "simulated": t in tables7, "pred_min_V": best[0], "macro": best[1],
                            "row": best[2], "col": best[3], "nb": best[4], "string": best[5], "ones": best[6],
                            "row_zeros": best[7], "max_string": smax[0], "max_string_cell": smax[1], "words": words})
    res.sort(key=lambda x: x["pred_min_V"])
    sim_pcm = [x for x in res if x["simulated"] and "_pcm_" in x["table"]]
    thr = max(x["pred_min_V"] for x in sim_pcm) if sim_pcm else None
    print(f"   {'table':<26} {'pred. V':>8}  macro row col  nb string ones row-zeros  longest string (two-sided)  simulated")
    for x in res[:20]:
        print(f"   {x['table']:<26} {x['pred_min_V']:8.3f}  k{x['macro']}  {x['row']:3d} {x['col']:3d}  {x['nb']:2d} "
              f"{x['string']:6d} {x['ones']:4d} {x['row_zeros']:9d}  {x['max_string']:26d}  {'yes' if x['simulated'] else ''}")
    for x in res:
        if x["simulated"] and x not in res[:20]:
            print(f"   {x['table']:<26} {x['pred_min_V']:8.3f}  k{x['macro']}  (simulated; rank "
                  f"{res.index(x) + 1} of {len(res)})")
    meas7 = {}
    for p in cells:
        meas7[p["table"]] = min(meas7.get(p["table"], 9.0), p["v"])
    print("   simulated tables: measured minimum (E8.4a-7, tt) against predicted:")
    for x in res:
        if x["simulated"]:
            print(f"      {x['table']:<26} measured {meas7.get(x['table'], float('nan')):.3f} V, predicted "
                  f"{x['pred_min_V']:.3f} V")

    # 5. selection: (a) the lowest predictions, (b) the longest strings above a two-sided cell
    smax7 = max((x["max_string"] for x in res if x["simulated"]), default=0)
    sel_a = [x for x in res if not x["simulated"]][:a.n_model]
    by_s = sorted((x for x in res if not x["simulated"] and x["max_string"] > smax7 and x not in sel_a),
                  key=lambda x: (-x["max_string"], x["pred_min_V"]))
    sel_b = by_s[:a.n_string]
    sel = (sel_a + sel_b)[:a.max_tables]
    print(f"\n5. selection for part 2 (tables not simulated): (a) the {a.n_model} lowest predicted bitlines; (b) up to "
          f"{a.n_string} tables whose longest string of 0 cells above a two-sided cell is longer than in any simulated "
          f"table ({smax7}): {len(by_s)} such tables, the longest first")
    if thr is not None:
        n_thr = sum(1 for x in res if not x["simulated"] and x["pred_min_V"] < thr)
        print(f"   {n_thr} tables not simulated are predicted below the highest predicted minimum of the simulated "
              f"PCM-side tables ({thr:.3f} V)")
    os.makedirs(os.path.join(out_dir, "tables"), exist_ok=True)
    for x in sel:
        f = os.path.join(out_dir, "tables", x["table"] + ".bin")
        open(f, "wb").write(to_bytes(x["words"]))
        why = "(a)" if x in sel_a else "(b)"
        print(f"   {why} {x['table']}: predicted {x['pred_min_V']:.3f} V (k{x['macro']} row {x['row']} col {x['col']}), "
              f"longest string {x['max_string']}; {f} md5 {md5(f)}")
    with open(os.path.join(out_dir, "tables", "selected.txt"), "w") as fh:
        fh.write(" ".join(x["table"] for x in sel) + "\n")
    print(f"   {len(sel)} tables selected for part 2: " + " ".join(x["table"] for x in sel))
    json.dump({"models": {str(k): v for k, v in m.items()}, "features": FEATS,
               "check": [{"macro": n, "measured_V": q, "predicted_V": p} for n, q, p in rows_chk],
               "tables": [{k: v for k, v in x.items() if k != "words"} for x in res],
               "threshold_V": thr, "selected": [x["table"] for x in sel]},
              open(os.path.join(out_dir, "screen.json"), "w"), indent=1)
    print(f"\nwritten: {os.path.join(out_dir, 'screen.json')}  ({time.time() - t0:.0f} s)")


if __name__ == "__main__":
    main()
