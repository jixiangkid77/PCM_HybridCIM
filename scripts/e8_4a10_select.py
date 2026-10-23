#!/usr/bin/env python3
"""
e8_4a10_select.py   (P2R-E8.4a-10: which macros of the 82 tables not yet simulated to simulate)

select  Fits a model of the one-cell bitline of the screening read (tt, 25 C, 1.80 V;
        each target row read after a read of row 0, as in E8.4a-7/-8/-9) on
          - the 533,188 one cells (rows 1-47) of the 18 simulated tables
            (reports/e8_rom/e8_4a8/export_cells_tables.json.gz), and
          - the 784 designed cells of the synthetic table of E8.4a-9 (reports/
            e8_4a9_rom_tables.log and reports/e8_rom/e8_4a9/tables/), which hold
            the extreme contents the real tables lack,
        with three weights of the designed cells (5, 20, 50), predicts every one cell
        of rows 1-47 of the 400 macros of the 100 tables, and applies the rule fixed
        before the run (2026-10-15, claude/p2r-e8-4a10-sandbox.md):
          R1 a macro whose lowest predicted bitline is below 1.20 V for any weight;
          R2 a macro with a one cell whose column has no zero cell joined to the
             bitline at the top (Z = 0), whose two neighbouring columns both
             discharge in the read, and whose stronger neighbour has at least 30
             zero cells joined to the bitline from row 0;
        only macros of tables not simulated before. The macros chosen in the sandbox
        are written into this script (SELECTED); the run uses them, and the
        recomputed selection is printed against them.
        Writes reports/e8_rom/e8_4a10/tables/: <table>.bin of each selected table
        (rebuilt from data/ as E8.6a and E8.4a-8 do, compared with the export),
        selected.txt (tables), selected_macros.txt (macros), predictions.json.
        Needs numpy and scikit-learn: run it with /home/kid/openram-venv/bin/python3.
check   After scripts/e8_4a10_rom_tables.sh (it calls this at its end): for each
        selected macro, the lowest measured one-cell bitline (rows 1-47) against the
        lowest prediction (weight 20); the prediction at the measured lowest cell;
        the error of every measured one cell; whether the measured lowest row is
        among the 8 rows with the lowest prediction. Rule J3 (fixed before the run):
        the model-based coverage of the macros not simulated holds only if no
        selected macro is lower than predicted by more than 65 mV (the largest such
        error in the leave-one-table-out check of the 18 tables, 64.7 mV); it is
        judged when all 47 rows of every selected macro were read. Exit 0: J3 holds;
        1: it does not; 2: not judged yet. Only json: any python3.

Usage:
  /home/kid/openram-venv/bin/python3 scripts/e8_4a10_select.py select --paper2 /mnt/d/Project/hybrid_memory/paper2
  python3 scripts/e8_4a10_select.py check --paper2 /mnt/d/Project/hybrid_memory/paper2
"""
import argparse
import gzip
import hashlib
import importlib.util
import json
import os
import re
import sys
import time

ROWS, WPR, NCOL = 48, 13, 208
PER = ROWS * WPR
WEIGHTS = (5.0, 20.0, 50.0)
W_CHECK = 20.0
T_SEL = 1.20                 # R1 (V)
PATTERN_Z = 30               # R2: joined zero cells of the stronger neighbour
J3_MV = 65.0                 # J3 (mV)
SELECTED = [                 # the sandbox selection of 2026-10-15; the run simulates these
    "e8rom_A_pcm_l01_16x2496_r48k3", "e8rom_A_pcm_l02_16x2496_r48k3", "e8rom_A_pcm_l04_16x2496_r48k3",
    "e8rom_A_pcm_l05_16x2496_r48k3", "e8rom_A_pcm_l07_16x2496_r48k3", "e8rom_A_pcm_l11_16x2496_r48k3",
    "e8rom_A_pcm_l14_16x2496_r48k3", "e8rom_A_pcm_l17_16x2496_r48k3", "e8rom_B_pcm_l01_16x2496_r48k0",
    "e8rom_B_pcm_l07_16x2496_r48k1", "e8rom_B_pcm_l09_16x2496_r48k1", "e8rom_B_pcm_l10_16x2496_r48k3",
]
SANDBOX_INPUTS = {           # md5 of the inputs the sandbox selection used (KID's files of 2026-10-15)
    "export": "e4f5776110929e93ddc35916fe0aed6a",
    "E8.4a-9 log": "11bb1cc1b7183e178eaa7d63f6f7539c",
    "synthetic": "bce563c0a16026f6a95dc51a80872df9",
}
SANDBOX_COUNTS = {"training": 533188, "synthetic": 784, "predicted": 2852968}
FEATS = ["R", "Z", "L", "ones_above", "iso_zeros", "full", "row_zeros", "word", "bit"] + \
        [f"{n}_{q}" for n in ("l1", "r1", "l2", "r2") for q in ("exists", "dis", "Z", "ones_above")] + \
        ["dis_n", "zmax_dis", "zsum_dis"]


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


# ------------------------------------------------------------------ cells and their features
def grids(np, words):
    """one 48 x 208 array per macro: 1 = transistor (one cell), 0 = zero cell; column = bit x 13 + word, bit 0 = MSB"""
    out = []
    for k in range(len(words) // PER):
        w = np.array(words[k * PER:(k + 1) * PER], dtype=np.int64).reshape(ROWS, WPR)
        g = np.zeros((ROWS, NCOL), dtype=np.int8)
        for b in range(16):
            g[:, b * WPR:(b + 1) * WPR] = (w >> (15 - b)) & 1
        out.append(g)
    return out


def col_info(np, g):
    """per column: leading zero cells from row 0; one cells above each row; zero cells directly above each row"""
    lead0 = np.array([(np.nonzero(g[:, c])[0][0] if g[:, c].any() else ROWS) for c in range(NCOL)], dtype=np.int64)
    ones_cum = np.vstack([np.zeros((1, NCOL), dtype=np.int64), np.cumsum(g, axis=0)])
    zrun = np.zeros((ROWS, NCOL), dtype=np.int64)
    for R in range(1, ROWS):
        zrun[R] = np.where(g[R - 1] == 0, zrun[R - 1] + 1, 0)
    return lead0, ones_cum, zrun


def cell_feats(np, g, R, cols, info):
    """features of the one cells at row R, columns cols (Z, T, L as in E8.4a-9; neighbours l1 r1 l2 r2)"""
    lead0, ones_cum, zrun = info
    n = len(cols)
    f = {}
    Z = np.minimum(lead0[cols], R)
    f["R"] = np.full(n, R)
    f["Z"] = Z
    f["ones_above"] = ones_cum[R, cols]
    f["L"] = np.where(Z < R, zrun[R, cols], 0)
    f["iso_zeros"] = R - Z - ones_cum[R, cols]
    f["full"] = (Z == R).astype(int)
    f["row_zeros"] = np.full(n, int((g[R] == 0).sum()))
    f["word"] = cols % WPR
    f["bit"] = cols // WPR
    for d, nm in ((-1, "l1"), (1, "r1"), (-2, "l2"), (2, "r2")):
        cc = cols + d
        ok = (cc >= 0) & (cc < NCOL)
        c2 = np.clip(cc, 0, NCOL - 1)
        f[f"{nm}_exists"] = ok.astype(int)
        f[f"{nm}_dis"] = np.where(ok, g[R, c2] == 0, False).astype(int)
        f[f"{nm}_Z"] = np.where(ok, np.minimum(lead0[c2], R), 0)
        f[f"{nm}_ones_above"] = np.where(ok, ones_cum[R, c2], 0)
    f["dis_n"] = f["l1_dis"] + f["r1_dis"]
    f["zmax_dis"] = np.maximum(f["l1_Z"] * f["l1_dis"], f["r1_Z"] * f["r1_dis"])
    f["zsum_dis"] = f["l1_Z"] * f["l1_dis"] + f["r1_Z"] * f["r1_dis"]
    f["col"] = cols
    return f


def stack(np, parts):
    return {k: np.concatenate([p[k] for p in parts]) for k in parts[0]}


def X_of(np, f):
    return np.column_stack([f[k] for k in FEATS]).astype(float)


def words_of_hex(h):
    return [int(h[i:i + 4], 16) for i in range(0, len(h), 4)]


def macro_cells(np, g):
    """features of every one cell of rows 1-47 of one macro"""
    info = col_info(np, g)
    parts = []
    for R in range(1, ROWS):
        cols = np.nonzero(g[R] == 1)[0].astype(np.int64)
        if len(cols):
            parts.append(cell_feats(np, g, R, cols, info))
    return stack(np, parts)


def synthetic_cells(np, log_path, bin_path, json_path):
    """the designed cells of the synthetic table: lowest bitline (one cell) or mean (several) from the E8.4a-9 log"""
    lines = open(log_path, errors="replace").read().splitlines()
    i0 = next(n for n, ln in enumerate(lines) if "synthetic table: one-cell bitlines of the designed cells" in ln)
    entries, srows, mac, cur_s = {}, {}, None, None
    for ln in lines[i0:]:
        m = re.match(r"\s{3}(k[0-3]):\s*$", ln)
        if m:
            mac, cur_s = m.group(1), None
            continue
        m = re.match(r"\s+S columns .*neighbours (\S+): row: lowest V", ln)
        if m:
            cur_s = m.group(1)
            continue
        if cur_s and re.match(r"\s+\d+:\s", ln):
            for r, v in re.findall(r"(\d+):\s+([0-9.]+)", ln):
                srows[(mac, cur_s, int(r))] = float(v)
            continue
        cur_s = None
        m = re.match(r"\s+(k[0-3].*?)\s{2,}(\S+/\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+\|\s+([0-9.]+)\s+([0-9.]+)\s+"
                     r"\(\s*(\d+)\)", ln)
        if m and mac:
            entries[(mac, m.group(1).strip(), m.group(2), int(m.group(3)), int(m.group(4)), int(m.group(5)),
                     int(m.group(6)))] = (float(m.group(7)), float(m.group(8)), int(m.group(9)))
        if ln.startswith("   the 10 lowest"):
            break
    des = json.load(open(json_path))
    data = open(bin_path, "rb").read()
    words = [int.from_bytes(data[2 * j:2 * j + 2], "big") for j in range(len(data) // 2)]
    gs = grids(np, words)
    parts, used, missing = [], set(), 0
    for k, mac in enumerate(("k0", "k1", "k2", "k3")):
        g = gs[k]
        info = col_info(np, g)
        for cs, v in des["macros"][mac].items():
            c = int(cs)
            if v["design"].startswith("k1 S"):
                nbt = v["nb"].split("/")[0]
                for R in range(1, ROWS):
                    if (mac, nbt, R) in srows:
                        f = cell_feats(np, g, R, np.array([c]), info)
                        f["V"] = np.array([srows[(mac, nbt, R)]])
                        parts.append(f)
                continue
            key = next((e for e in entries if e[0] == mac and e[1] == v["design"] and e[2] == v["nb"] and
                        e[3:] == (v["Z"], v["T"], v["L"], v["row"])), None)
            if key is None:
                missing += 1
                continue
            if g[v["row"], c] != 1:
                sys.exit(f"synthetic {mac} column {c}: the design file says a one cell at row {v['row']}, the table not")
            used.add(key)
            low, mean, n = entries[key]
            f = cell_feats(np, g, v["row"], np.array([c]), info)
            f["V"] = np.array([low if n == 1 else mean])
            parts.append(f)
    return stack(np, parts), len(entries), len(used), missing


# ------------------------------------------------------------------ select
def cmd_select(a):
    import numpy as np
    import sklearn
    from sklearn.ensemble import HistGradientBoostingRegressor
    t0 = time.time()
    root = os.path.join(a.paper2, "reports", "e8_rom")
    inputs = {"export": os.path.join(root, "e8_4a8", "export_cells_tables.json.gz"),
              "E8.4a-9 log": os.path.join(a.paper2, "reports", "e8_4a9_rom_tables.log"),
              "synthetic": os.path.join(root, "e8_4a9", "tables", "e8rom_X_syn_l00_16x2496.bin")}
    syn_j = inputs["synthetic"] + ".json"
    print(f"P2R-E8.4a-10 selection  {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"   script : {md5(os.path.abspath(__file__))}  {os.path.abspath(__file__)}")
    print(f"   python {sys.version.split()[0]} ({sys.executable}), numpy {np.__version__}, "
          f"scikit-learn {sklearn.__version__}")
    for nm, p in list(inputs.items()) + [("design", syn_j)]:
        if not os.path.isfile(p):
            sys.exit(f"missing input {p}")
        h = md5(p)
        note = "" if nm not in SANDBOX_INPUTS else \
            ("  (the file the sandbox used)" if h == SANDBOX_INPUTS[nm] else "  (NOT the file the sandbox used)")
        print(f"   {nm:<12}: {h}  {p}{note}")
    d = json.load(gzip.open(inputs["export"], "rt"))
    # training: the one cells of the 18 simulated tables, rows 1-47
    parts = []
    for mname, v in sorted(d["macros"].items()):
        k = int(mname.split("_r48k")[1])
        g = grids(np, words_of_hex(d["tables"][v["table"]]))[k]
        if not (g == grids(np, words_of_hex(v["bin_hex"]))[0]).all():
            sys.exit(f"{mname}: its exported data file differs from the table")
        info = col_info(np, g)
        for rd in v["reads"]:
            R = rd["row"]
            if R == 0:
                continue
            cols = np.array(sorted(int(c) for c in rd["bl1_by_col"]), dtype=np.int64)
            if not (g[R, cols] == 1).all():
                sys.exit(f"{mname} row {R}: a measured one-cell bitline on a zero cell")
            f = cell_feats(np, g, R, cols, info)
            f["V"] = np.array([rd["bl1_by_col"][str(c)] for c in cols])
            f["table"] = np.array([v["table"]] * len(cols))
            parts.append(f)
    tr = stack(np, parts)
    sim = sorted(set(tr["table"]))
    syn, n_ent, n_used, n_miss = synthetic_cells(np, inputs["E8.4a-9 log"], inputs["synthetic"], syn_j)
    print(f"   training: {len(tr['V'])} one cells of {len(sim)} simulated tables (sandbox {SANDBOX_COUNTS['training']}); "
          f"synthetic: {len(syn['V'])} designed cells (sandbox {SANDBOX_COUNTS['synthetic']}; {n_used} of {n_ent} "
          f"log entries matched, {n_miss} designs without an entry)")
    Xtr = np.vstack([X_of(np, tr), X_of(np, syn)])
    ytr = np.concatenate([tr["V"], syn["V"]])
    models = {}
    for w in WEIGHTS:
        wt = np.concatenate([np.ones(len(tr["V"])), np.full(len(syn["V"]), w)])
        models[w] = HistGradientBoostingRegressor(max_iter=400, learning_rate=0.1, max_leaf_nodes=63,
                                                  min_samples_leaf=5, random_state=0).fit(Xtr, ytr, sample_weight=wt)
    print(f"   three models fitted ({time.time() - t0:.0f} s)")
    # every one cell of rows 1-47 of the 400 macros
    macros, cells_sel, n_pred = {}, {}, 0
    for t, hx in sorted(d["tables"].items()):
        for k, g in enumerate(grids(np, words_of_hex(hx))):
            kname = f"{t}_r48k{k}"
            f = macro_cells(np, g)
            X = X_of(np, f)
            n_pred += len(X)
            rec = {"table": t, "simulated": t in sim}
            for w in WEIGHTS:
                p = models[w].predict(X)
                i = int(np.argmin(p))
                rec[f"min_w{int(w)}"] = round(float(p[i]), 5)
                if w == W_CHECK:
                    rec["row"], rec["col"] = int(f["R"][i]), int(f["col"][i])
                    rmin = {int(R): float(p[f["R"] == R].min()) for R in np.unique(f["R"])}
                    rec["rows8"] = sorted(rmin, key=lambda r_: (rmin[r_], r_))[:8]
                    if kname in SELECTED:
                        cells_sel[kname] = {f"{int(r_)},{int(c_)}": round(float(v_), 5)
                                            for r_, c_, v_ in zip(f["R"], f["col"], p)}
            pat = (f["Z"] == 0) & (f["l1_dis"] == 1) & (f["r1_dis"] == 1) & \
                  (np.maximum(f["l1_Z"], f["r1_Z"]) >= PATTERN_Z)
            rec["pattern_cells"] = int(pat.sum())
            rec["R1"] = (not rec["simulated"]) and min(rec[f"min_w{int(w)}"] for w in WEIGHTS) < T_SEL
            rec["R2"] = (not rec["simulated"]) and rec["pattern_cells"] > 0
            macros[kname] = rec
    print(f"   predicted: {n_pred} one cells of {len(macros)} macros in {len(d['tables'])} tables "
          f"(sandbox {SANDBOX_COUNTS['predicted']}); {time.time() - t0:.0f} s")
    sel = sorted(k for k, r in macros.items() if r["R1"] or r["R2"])
    print(f"\n   R1 (lowest predicted bitline < {T_SEL:.2f} V for weight 5, 20 or 50; tables not simulated): "
          f"{sum(r['R1'] for r in macros.values())} macros")
    print(f"   R2 (Z = 0, both neighbours discharge, the stronger with >= {PATTERN_Z} joined zero cells; tables not "
          f"simulated): {sum(r['R2'] for r in macros.values())} macros")
    print("\n   the 30 macros with the lowest prediction (V):")
    print(f"   {'macro':<26} {'w5':>6} {'w20':>6} {'w50':>6}  row col  R2 cells  rule")
    for kname in sorted(macros, key=lambda x: (macros[x]["min_w20"], x))[:30]:
        r = macros[kname]
        print(f"   {kname.replace('e8rom_', '').replace('_16x2496', ''):<26} {r['min_w5']:6.3f} {r['min_w20']:6.3f} "
              f"{r['min_w50']:6.3f}  {r['row']:3d} {r['col']:3d}  {r['pattern_cells']:8d}  "
              f"{'simulated before' if r['simulated'] else ' '.join(x for x in ('R1', 'R2') if r[x])}")
    others = [k for k, r in macros.items() if not r["simulated"] and k not in SELECTED]
    print(f"\n   macros neither simulated before nor selected: {len(others)}; their lowest prediction: " +
          ", ".join(f"weight {int(w)} {min(macros[k][f'min_w{int(w)}'] for k in others):.3f} V" for w in WEIGHTS))
    same = sel == sorted(SELECTED)
    print(f"   recomputed selection: {len(sel)} macros, {'THE SAME AS' if same else 'DIFFERENT FROM'} the sandbox "
          f"selection ({len(SELECTED)} macros)")
    if not same:
        print(f"      only recomputed: {sorted(set(sel) - set(SELECTED))}")
        print(f"      only sandbox   : {sorted(set(SELECTED) - set(sel))}")
        print("      the run simulates the sandbox selection (fixed before the run); report this difference")
    # data files of the selected tables, rebuilt from data/ as E8.6a and E8.4a-8 do
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("e86a2", os.path.join(here, "e8_6a2_rom_energy.py"))
    E = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(E)
    out_dir = os.path.join(root, "e8_4a10", "tables")
    os.makedirs(out_dir, exist_ok=True)
    tabs = sorted(set(k.rsplit("_r48k", 1)[0] for k in SELECTED))
    print(f"\n   data files of the {len(tabs)} tables (from data/rtl_inputs_<model>_v3, equal to the export):")
    for t in tabs:
        _, M, side, ln, _ = t.split("_")
        w = E.table_words(a.paper2, M, side, int(ln[1:]), 2496)
        if "".join(f"{x:04x}" for x in w) != d["tables"][t]:
            sys.exit(f"{t}: the table rebuilt from data/ differs from the export")
        f = os.path.join(out_dir, f"{t}.bin")
        with open(f, "wb") as fh:
            fh.write(bytes(b for x in w for b in ((x >> 8) & 0xFF, x & 0xFF)))
        ks = [k for k in SELECTED if k.startswith(t + "_")]
        print(f"   {t}: {md5(f)}  macro {', '.join('k' + k.rsplit('k', 1)[1] for k in ks)}")
    with open(os.path.join(out_dir, "selected.txt"), "w") as fh:
        fh.write(" ".join(tabs) + "\n")
    with open(os.path.join(out_dir, "selected_macros.txt"), "w") as fh:
        fh.write("\n".join(SELECTED) + "\n")
    pj = os.path.join(out_dir, "predictions.json")
    json.dump({"created": time.strftime("%Y-%m-%d %H:%M:%S"), "script_md5": md5(os.path.abspath(__file__)),
               "versions": {"python": sys.version.split()[0], "numpy": np.__version__, "sklearn": sklearn.__version__},
               "rule": {"T_SEL_V": T_SEL, "weights": WEIGHTS, "PATTERN_Z": PATTERN_Z, "J3_mV": J3_MV,
                        "w_check": W_CHECK},
               "simulated_tables": sim, "selected": SELECTED, "recomputed": sel, "macros": macros,
               "cells_selected_w20": cells_sel}, open(pj, "w"), indent=1)
    print(f"   written to {out_dir}: selected.txt ({len(tabs)} tables), selected_macros.txt ({len(SELECTED)} macros), "
          f"predictions.json ({md5(pj)})")
    print(f"done ({time.time() - t0:.0f} s)")
    return 0


# ------------------------------------------------------------------ check
def cmd_check(a):
    work = a.work or os.path.join(a.paper2, "reports", "e8_rom", "e8_4a10")
    pj = json.load(open(os.path.join(a.in_dir or os.path.join(work, "tables"), "predictions.json")))
    j3 = pj["rule"]["J3_mV"]
    print(f"P2R-E8.4a-10 model check  {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"   predictions of {pj['created']} (weight {pj['rule']['w_check']:g}); J3: no selected macro lower than "
          f"predicted by more than {j3:.0f} mV; judged when every selected macro has all {ROWS - 1} rows read")
    print("   error = lowest prediction - lowest measurement of the macro (+: measured lower than predicted); "
          "cells: prediction - measurement of every measured one cell")
    print(f"   {'macro':<20} {'rows':>4} {'measured':>8} {'row':>4} {'col':>4}  {'predicted':>9} {'row':>4} {'col':>4}  "
          f"{'error':>8}  {'pred there':>10}  {'cells':>5} {'mean':>6} {'SD':>5} {'max':>6}  worst row in 8")
    beyond, missing, n, hit, allres = 0, 0, 0, 0, []
    for kname in pj["selected"]:
        lab = kname.replace("e8rom_", "").replace("_16x2496", "")
        rj = os.path.join(work, kname, "tt_cs", "result.json")
        if not os.path.isfile(rj):
            print(f"   {lab:<20} no screening result")
            missing += 1
            continue
        r_ = json.load(open(rj))
        cells = pj["cells_selected_w20"].get(kname, {})
        best, res, rows = None, [], set()
        for cy, x in zip(r_["meta"]["cycles"], r_["cycles"]):
            if cy["kind"] != "read" or not x.get("complete") or cy["row"] == 0:
                continue
            rows.add(cy["row"])
            for c, v in (x.get("bl1_by_col") or {}).items():
                if best is None or v < best[0]:
                    best = (v, cy["row"], int(c))
                p = cells.get(f"{cy['row']},{int(c)}")
                if p is not None:
                    res.append(p - v)
        p = pj["macros"][kname]
        if best is None:
            print(f"   {lab:<20} {len(rows):4d} no one-cell bitline in the result")
            missing += 1
            continue
        err = (p["min_w20"] - best[0]) * 1000.0
        at = cells.get(f"{best[1]},{best[2]}")
        ok = err <= j3
        full = len(rows) == ROWS - 1
        inrows = best[1] in p["rows8"]
        n += 1
        hit += inrows
        beyond += not ok
        missing += not full
        allres += res
        m = sum(res) / len(res) if res else float("nan")
        sd = (sum((x - m) ** 2 for x in res) / len(res)) ** 0.5 if res else float("nan")
        mx = max(res) if res else float("nan")
        print(f"   {lab:<20} {len(rows):4d} {best[0]:8.3f} {best[1]:4d} {best[2]:4d}  {p['min_w20']:9.3f} {p['row']:4d} "
              f"{p['col']:4d}  {err:+8.1f}  {'-' if at is None else f'{at:.3f}':>10}  {len(res):5d} {m * 1000:+6.1f} "
              f"{sd * 1000:5.1f} {mx * 1000:+6.1f}  {'yes' if inrows else 'NO'}{'' if ok else '   <- beyond J3'}"
              f"{'' if full else '   (not all rows read)'}")
    if allres:
        m = sum(allres) / len(allres)
        sd = (sum((x - m) ** 2 for x in allres) / len(allres)) ** 0.5
        print(f"   every measured one cell (prediction - measurement, mV): {len(allres)} cells, mean {m * 1000:+.1f}, "
              f"SD {sd * 1000:.1f}, largest {max(allres) * 1000:+.1f} (measured lower than predicted), smallest "
              f"{min(allres) * 1000:+.1f}")
    print(f"   {n} of {len(pj['selected'])} macros measured; measured lowest row among the 8 rows with the lowest "
          f"prediction: {hit} of {n}")
    if beyond:
        print(f"   J3 DOES NOT HOLD ({beyond} macro(s) beyond {j3:.0f} mV): the macros not simulated are not covered by "
              f"the model (next: E8.4a-11)")
        return 1
    if missing:
        print(f"   J3 NOT JUDGED YET: {missing} macro(s) without a screening of all {ROWS - 1} rows")
        return 2
    print("   J3 HOLDS: the model-based coverage of the macros not simulated stands")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("select")
    p.add_argument("--paper2", required=True)
    p = sp.add_parser("check")
    p.add_argument("--paper2", required=True)
    p.add_argument("--work", default="", help="output folder of the run (default reports/e8_rom/e8_4a10)")
    p.add_argument("--in-dir", default="", help="folder of predictions.json (default <work>/tables)")
    a = ap.parse_args()
    return cmd_select(a) if a.cmd == "select" else cmd_check(a)


if __name__ == "__main__":
    sys.exit(main())
