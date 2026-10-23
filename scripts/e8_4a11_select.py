#!/usr/bin/env python3
"""
e8_4a11_select.py   (P2R-E8.4a-11: the bitline model fitted again with the 12 macros of E8.4a-10;
                     a lower bound of every one cell; which macros to simulate)

select  1. Training data: the one cells (rows 1-47) of the tt screenings of
             - the 18 tables of E8.4a-7/-8 (reports/e8_rom/e8_4a8/export_cells_tables.json.gz) and
             - the 12 macros of E8.4a-10 (reports/e8_rom/e8_4a10/export_cells_e8_4a10.json.gz),
           and the 784 designed cells of the synthetic table of E8.4a-9 (weights 5, 20, 50), with the
           features and the model of scripts/e8_4a10_select.py (imported, not copied).
        2. Leave one table out over the 30 simulated tables, for each weight: the largest amount by
           which the model predicted a one cell too high (mV), in three groups fixed before the run:
             E_HS cells below LOW (measured or predicted) that have the H pattern (a discharging
                  adjacent column with >= ZMAX_H zero cells joined to its bitline: the R2 pattern of
                  E8.4a-10) or lie in a sparse group: both adjacent columns discharge and fewer than
                  N_BIN measured cells of the tables the model was fitted on share the cell's group
                  (Z <= 2 or > 2; zero run directly above in 0-9, 10-19, 20-29, 30-47; joined zeros of
                  the stronger discharging neighbour in the same four bands);
             E_M  the other cells below LOW;
             E_A  every cell.
        3. Fitted on all data, it predicts every one cell of rows 1-47 of the 400 macros and gives each
           cell the lower bound  pred - E,  E = E_A if pred >= LOW; else E_HS if the cell has the H
           pattern or lies in a sparse group (counted on all 30 tables); else E_M. The bound of a
           macro (LB) is the lowest bound of its cells over the three weights.
        4. Rules fixed before the run (claude/p2r-e8-4a11-sandbox.md):
             R1 every macro not simulated whose LB is below T_COV (= 0.976 + 0.130 + 0.045 V: the tt rule
                level, the largest condition penalty seen, the farther columns) is simulated;
             R2 then the macros not simulated with the lowest LB, until N_SEL macros are chosen.
           The sandbox selection is written into this script (SELECTED); the run uses it, and the
           recomputed selection is printed against it.
        Writes reports/e8_rom/e8_4a11/tables/: <table>.bin of each selected table (rebuilt from data/
        as E8.6a and E8.4a-10 do, compared with the export), selected.txt, selected_macros.txt,
        predictions.json. Needs numpy and scikit-learn: /home/kid/openram-venv/bin/python3.
check   After scripts/e8_4a11_rom_tables.sh (it calls this at its end): for each selected macro, the
        lowest measured one-cell bitline (rows 1-47) against its bound LB and against the lowest
        prediction (weight 20). Rule J3 (fixed before the run): the bound holds for every selected
        macro (measured lowest >= LB), judged when all 47 rows of every selected macro were read.
        It also reads the condition penalty of the new tables (penalty.txt, written by the run
        script) and lists the macros not simulated whose LB is below 0.976 + max(0.130, the new
        penalty) + 0.045 V (not covered). Exit 0: J3 holds; 1: it does not; 2: not judged yet.
        Only json: any python3.

Usage:
  /home/kid/openram-venv/bin/python3 scripts/e8_4a11_select.py select --paper2 /mnt/d/Project/hybrid_memory/paper2
  python3 scripts/e8_4a11_select.py check --paper2 /mnt/d/Project/hybrid_memory/paper2

Place  : scripts/   (next to scripts/e8_4a10_select.py and scripts/e8_6a2_rom_energy.py, which it reads)
Status : NEW FILE.
"""
import argparse
import gzip
import hashlib
import importlib.util
import json
import os
import sys
import time

ROWS = 48
WEIGHTS = (5.0, 20.0, 50.0)
W_CHECK = 20.0
V_RULE = 0.976               # tt switching level 0.876 V + 0.10 V
PENALTY = 0.130              # largest (tt margin - lowest condition margin) of a simulated table (B_pcm07, E8.4a-10)
FAR = 0.045                  # farther columns (E8.4a-9)
T_COV = round(V_RULE + PENALTY + FAR, 3)   # 1.151 V
LOW = 1.35                   # cells predicted at or above this use E_A
ZMAX_H = 30                  # H pattern: a discharging adjacent column with >= 30 joined zero cells
N_BIN = 10                   # a group with fewer measured cells (both neighbours discharging) is sparse
N_SEL = 12
BANDS = (10, 20, 30)         # 0-9, 10-19, 20-29, 30-47
A10_SELECT_MD5 = "a9b54a357a0cc62790491293a2afc1e8"
SANDBOX_INPUTS = {           # md5 of the inputs of the sandbox selection (KID's files of 2026-10-15)
    "export E8.4a-8": "e4f5776110929e93ddc35916fe0aed6a",
    "export E8.4a-10": "991eb94e841b20bbf6003766c66c19e0",
    "E8.4a-9 log": "11bb1cc1b7183e178eaa7d63f6f7539c",
    "synthetic": "bce563c0a16026f6a95dc51a80872df9",
}
SANDBOX_COUNTS = {"training": 590987, "synthetic": 784, "predicted": 2852968, "tables": 30}
SANDBOX_E = {5.0: (77.8, 35.4, 82.1), 20.0: (81.1, 32.4, 91.6), 50.0: (80.7, 33.6, 80.7)}   # (E_HS, E_M, E_A) mV
SELECTED = [                 # the sandbox selection of 2026-10-15 (R1: 13 macros, R2: none); the run simulates these
    "e8rom_A_pcm_l03_16x2496_r48k3", "e8rom_A_pcm_l09_16x2496_r48k3", "e8rom_A_pcm_l13_16x2496_r48k3",
    "e8rom_A_pcm_l16_16x2496_r48k3", "e8rom_B_pcm_l07_16x2496_r48k3", "e8rom_B_pcm_l08_16x2496_r48k3",
    "e8rom_B_pcm_l13_16x2496_r48k2", "e8rom_B_pcm_l13_16x2496_r48k3", "e8rom_B_pcm_l14_16x2496_r48k3",
    "e8rom_B_pcm_l15_16x2496_r48k2", "e8rom_B_pcm_l15_16x2496_r48k3", "e8rom_B_pcm_l17_16x2496_r48k2",
    "e8rom_B_pcm_l18_16x2496_r48k3",
]


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def load_a10(here):
    p = os.path.join(here, "e8_4a10_select.py")
    if not os.path.isfile(p):
        sys.exit(f"missing {p} (E8.4a-10)")
    h = md5(p)
    if h != A10_SELECT_MD5:
        sys.exit(f"{p}: md5 {h}, expected {A10_SELECT_MD5} (the E8.4a-10 script, whose features this run uses)")
    spec = importlib.util.spec_from_file_location("e8_4a10_select", p)
    S = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(S)
    return S, h


def gidx(np, f):
    """group of every cell with both adjacent columns discharging (0..31), -1 for the others"""
    band = lambda x: sum((np.asarray(x) >= b).astype(np.int64) for b in BANDS)
    g = (np.asarray(f["Z"]) > 2).astype(np.int64) * 16 + band(f["L"]) * 4 + band(f["zmax_dis"])
    return np.where(np.asarray(f["dis_n"]) == 2, g, -1)


def group_name(k):
    nm = ("0-9", "10-19", "20-29", "30-47")
    return f"Z{'>2' if k >= 16 else '<=2'} L{nm[(k % 16) // 4]} zmax{nm[k % 4]}"


def lower(np, pw, hs, e):
    """lower bound of each cell at one weight: E_A at or above LOW, else E_HS or E_M (mV)"""
    return pw - np.where(pw >= LOW, e[2], np.where(hs, e[0], e[1])) / 1000.0


# ------------------------------------------------------------------ training data
def measured_cells(S, np, d, tables_hex, src, need_complete):
    parts = []
    for mname, v in sorted(d["macros"].items()):
        if need_complete and not (v.get("complete") and v.get("rows_read") == ROWS - 1):
            sys.exit(f"{mname}: the E8.4a-10 screening is not complete (complete={v.get('complete')}, "
                     f"rows {v.get('rows_read')})")
        k = int(mname.split("_r48k")[1])
        g = S.grids(np, S.words_of_hex(tables_hex[v["table"]]))[k]
        if not (g == S.grids(np, S.words_of_hex(v["bin_hex"]))[0]).all():
            sys.exit(f"{mname}: its exported data file differs from the table")
        info = S.col_info(np, g)
        for rd in v["reads"]:
            R = rd["row"]
            if R == 0:
                continue
            cols = np.array(sorted(int(c) for c in rd["bl1_by_col"]), dtype=np.int64)
            if not (g[R, cols] == 1).all():
                sys.exit(f"{mname} row {R}: a measured one-cell bitline on a zero cell")
            f = S.cell_feats(np, g, R, cols, info)
            f["V"] = np.array([rd["bl1_by_col"][str(c)] for c in cols])
            f["table"] = np.array([v["table"]] * len(cols))
            f["macro"] = np.array([mname] * len(cols))
            f["src"] = np.array([src] * len(cols))
            parts.append(f)
    return S.stack(np, parts)


def fit(H, np, X, y, Xs, ys, w):
    wt = np.concatenate([np.ones(len(y)), np.full(len(ys), w)])
    return H(max_iter=400, learning_rate=0.1, max_leaf_nodes=63, min_samples_leaf=5,
             random_state=0).fit(np.vstack([X, Xs]), np.concatenate([y, ys]), sample_weight=wt)


# ------------------------------------------------------------------ select
def cmd_select(a):
    import numpy as np
    import sklearn
    from sklearn.ensemble import HistGradientBoostingRegressor as H
    t0 = time.time()
    here = os.path.dirname(os.path.abspath(__file__))
    S, a10md5 = load_a10(here)
    root = os.path.join(a.paper2, "reports", "e8_rom")
    inputs = {"export E8.4a-8": os.path.join(root, "e8_4a8", "export_cells_tables.json.gz"),
              "export E8.4a-10": os.path.join(root, "e8_4a10", "export_cells_e8_4a10.json.gz"),
              "E8.4a-9 log": os.path.join(a.paper2, "reports", "e8_4a9_rom_tables.log"),
              "synthetic": os.path.join(root, "e8_4a9", "tables", "e8rom_X_syn_l00_16x2496.bin")}
    syn_j = inputs["synthetic"] + ".json"
    print(f"P2R-E8.4a-11 selection  {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"   script : {md5(os.path.abspath(__file__))}  {os.path.abspath(__file__)}")
    print(f"   features and model of scripts/e8_4a10_select.py ({a10md5})")
    print(f"   python {sys.version.split()[0]} ({sys.executable}), numpy {np.__version__}, "
          f"scikit-learn {sklearn.__version__}")
    for nm, p in list(inputs.items()) + [("design", syn_j)]:
        if not os.path.isfile(p):
            sys.exit(f"missing input {p}")
        h = md5(p)
        note = "" if nm not in SANDBOX_INPUTS else \
            ("  (the file the sandbox used)" if h == SANDBOX_INPUTS[nm] else "  (NOT the file the sandbox used)")
        print(f"   {nm:<15}: {h}  {p}{note}")
    print(f"   rule: T_COV {T_COV:.3f} V = {V_RULE} + {PENALTY} + {FAR}; LOW {LOW} V; H pattern zmax >= {ZMAX_H}; "
          f"sparse group < {N_BIN} measured cells; {N_SEL} macros")
    d8 = json.load(gzip.open(inputs["export E8.4a-8"], "rt"))
    d10 = json.load(gzip.open(inputs["export E8.4a-10"], "rt"))
    th = d8["tables"]
    tr8 = measured_cells(S, np, d8, th, "E8.4a-8", False)
    tr10 = measured_cells(S, np, d10, th, "E8.4a-10", True)
    tr = {k: np.concatenate([tr8[k], tr10[k]]) for k in tr8}
    syn, n_ent, n_used, n_miss = S.synthetic_cells(np, inputs["E8.4a-9 log"], inputs["synthetic"], syn_j)
    sim_tables = sorted(set(tr8["table"]))
    sim_macros = sorted(set(tr10["macro"]))
    tabs = sorted(set(tr["table"]))
    print(f"   training: {len(tr8['V'])} + {len(tr10['V'])} = {len(tr['V'])} one cells of {len(tabs)} tables "
          f"(sandbox {SANDBOX_COUNTS['training']}, {SANDBOX_COUNTS['tables']}); synthetic {len(syn['V'])} "
          f"(sandbox {SANDBOX_COUNTS['synthetic']}; {n_used} of {n_ent} log entries, {n_miss} designs without one)")
    X, y = S.X_of(np, tr), tr["V"]
    Xs, ys = S.X_of(np, syn), syn["V"]
    # ---- groups of the cells with both neighbours discharging (measured cells of all 30 tables)
    gtr = gidx(np, tr)
    gcount = np.bincount(gtr[gtr >= 0], minlength=32)
    # sparse in a fold: counted on the tables the fold is fitted on
    hcls = tr["zmax_dis"] >= ZMAX_H
    sparse_f = np.zeros(len(y), dtype=bool)
    for t in tabs:
        m = tr["table"] == t
        cnt = np.bincount(gtr[(gtr >= 0) & ~m], minlength=32)
        sparse_f[m] = (gtr[m] >= 0) & (cnt[np.maximum(gtr[m], 0)] < N_BIN)
    hs_tr = hcls | sparse_f
    print(f"\n   leave one table out ({len(tabs)} tables x {len(WEIGHTS)} weights); held-out cells in a sparse group "
          f"{int(sparse_f.sum())}, with the H pattern {int(hcls.sum())}:")
    E, loto_rows = {}, {}
    for w in WEIGHTS:
        p = np.full(len(y), np.nan)
        for t in tabs:
            m = tr["table"] == t
            p[m] = fit(H, np, X[~m], y[~m], Xs, ys, w).predict(X[m])
        err = (p - y) * 1000.0
        low = (y < LOW) | (p < LOW)
        eh = float(err[low & hs_tr].max())
        em = float(err[low & ~hs_tr].max())
        ea = float(err.max())
        E[w] = (round(eh, 1), round(em, 1), round(ea, 1))
        ih = np.nonzero(low & hs_tr)[0][int(np.argmax(err[low & hs_tr]))]
        im = np.nonzero(low & ~hs_tr)[0][int(np.argmax(err[low & ~hs_tr]))]
        lab = lambda i: f"{tr['macro'][i].replace('e8rom_', '').replace('_16x2496', '')} row {tr['R'][i]} col {tr['col'][i]}"
        print(f"      weight {w:4.0f}: E_HS {eh:+6.1f} mV ({int((low & hs_tr).sum())} cells; {lab(ih)})  E_M {em:+6.1f} mV "
              f"({int((low & ~hs_tr).sum())} cells; {lab(im)})  E_A {ea:+6.1f} mV ({len(y)} cells); every cell: "
              f"mean {err.mean():+.2f} SD {err.std():.2f} mV   ({time.time() - t0:.0f} s)")
        for mac in sorted(set(tr["macro"])):
            mm = tr["macro"] == mac
            i, j = int(np.argmin(y[mm])), int(np.argmin(p[mm]))
            loto_rows.setdefault(mac, {})[w] = (float(y[mm][i]), float(p[mm][j]), (float(p[mm][j]) - float(y[mm][i])) * 1000)
    if SANDBOX_E:
        same = all(tuple(SANDBOX_E[w]) == E[w] for w in WEIGHTS)
        print(f"      E {'THE SAME AS' if same else 'DIFFERENT FROM'} the sandbox ({SANDBOX_E})")
    print("      macro minimum, leave one table out (mV, + = predicted higher than measured), the 10 largest at weight 20:")
    for mac in sorted(loto_rows, key=lambda m_: -loto_rows[m_][W_CHECK][2])[:10]:
        r = loto_rows[mac]
        print(f"         {mac.replace('e8rom_', '').replace('_16x2496', ''):<22} measured {r[W_CHECK][0]:.3f}  " +
              "  ".join(f"w{int(w)} {r[w][1]:.3f} ({r[w][2]:+6.1f})" for w in WEIGHTS))
    # ---- fit on all data, predict the 400 macros
    models = {w: fit(H, np, X, y, Xs, ys, w) for w in WEIGHTS}
    print(f"\n   three models fitted on all data ({time.time() - t0:.0f} s)")
    macros, cells_sel, n_pred = {}, {}, 0
    for t, hx in sorted(th.items()):
        for k, g in enumerate(S.grids(np, S.words_of_hex(hx))):
            kname = f"{t}_r48k{k}"
            f = S.macro_cells(np, g)
            Xm = S.X_of(np, f)
            n_pred += len(Xm)
            hpat = f["zmax_dis"] >= ZMAX_H
            gm = gidx(np, f)
            sparse = (gm >= 0) & (gcount[np.maximum(gm, 0)] < N_BIN)
            rec = {"table": t, "simulated": (t in sim_tables) or (kname in sim_macros),
                   "h_cells": int(hpat.sum()), "sparse_cells": int(sparse.sum())}
            best = None
            preds = {}
            for w in WEIGHTS:
                pw = models[w].predict(Xm)
                preds[w] = pw
                lb = lower(np, pw, hpat | sparse, E[w])
                ecell = (pw - lb) * 1000.0
                i = int(np.argmin(lb))
                rec[f"min_w{int(w)}"] = round(float(pw.min()), 5)
                rec[f"lb_w{int(w)}"] = round(float(lb[i]), 5)
                if best is None or lb[i] < best[0]:
                    best = (float(lb[i]), w, i, float(pw[i]), float(ecell[i]))
                if w == W_CHECK:
                    j = int(np.argmin(pw))
                    rec["row"], rec["col"] = int(f["R"][j]), int(f["col"][j])
                    rmin = {int(R): float(pw[f["R"] == R].min()) for R in np.unique(f["R"])}
                    rec["rows8"] = sorted(rmin, key=lambda r_: (rmin[r_], r_))[:8]
            lb, wb, i, pb, eb = best
            rec["LB"] = round(lb, 5)
            rec["LB_at"] = {"weight": wb, "row": int(f["R"][i]), "col": int(f["col"][i]), "pred": round(pb, 5),
                            "E_mV": eb, "H": bool(hpat[i]), "sparse": bool(sparse[i]),
                            "group": group_name(int(gm[i])) if gm[i] >= 0 else "-"}
            macros[kname] = rec
    print(f"   predicted: {n_pred} one cells of {len(macros)} macros (sandbox {SANDBOX_COUNTS['predicted']}); "
          f"{time.time() - t0:.0f} s")
    others = sorted((r["LB"], k) for k, r in macros.items() if not r["simulated"])
    r1 = [k for lb, k in others if lb < T_COV]
    sel = list(r1)
    for lb, k in others:
        if len(sel) >= N_SEL:
            break
        if k not in sel:
            sel.append(k)
    sel = sorted(sel)
    print(f"\n   macros not simulated: {len(others)}; R1 (LB < {T_COV:.3f} V): {len(r1)}; with R2: {len(sel)}")
    print(f"   {'macro':<24} {'LB':>6}  {'w5':>6} {'w20':>6} {'w50':>6}  LB at: weight row col pred   E  H S group")
    for lb, k in others[:max(N_SEL + 8, len(r1) + 8)]:
        r = macros[k]
        at = r["LB_at"]
        tag = "R1" if k in r1 else ("R2" if k in sel else "")
        print(f"   {k.replace('e8rom_', '').replace('_16x2496', ''):<24} {r['LB']:6.3f}  {r['min_w5']:6.3f} "
              f"{r['min_w20']:6.3f} {r['min_w50']:6.3f}  {at['weight']:4.0f} {at['row']:3d} {at['col']:3d} "
              f"{at['pred']:.3f} {at['E_mV']:4.0f} {'H' if at['H'] else '-'} {'S' if at['sparse'] else '-'} "
              f"{at['group']:<26} {tag}")
    rest = [lb for lb, k in others if k not in sel]
    print(f"   macros neither simulated nor selected: {len(rest)}; their lowest LB {min(rest):.3f} V (T_COV {T_COV:.3f})")
    if SELECTED:
        same = sel == sorted(SELECTED)
        print(f"   recomputed selection: {len(sel)} macros, {'THE SAME AS' if same else 'DIFFERENT FROM'} the "
              f"sandbox selection ({len(SELECTED)} macros)")
        if not same:
            print(f"      only recomputed: {sorted(set(sel) - set(SELECTED))}")
            print(f"      only sandbox   : {sorted(set(SELECTED) - set(sel))}")
            print("      the run simulates the sandbox selection (fixed before the run); report this difference")
    run_sel = sorted(SELECTED) if SELECTED else sel
    for kname in run_sel:
        t, k = kname.rsplit("_r48k", 1)
        f = S.macro_cells(np, S.grids(np, S.words_of_hex(th[t]))[int(k)])
        Xm = S.X_of(np, f)
        gm = gidx(np, f)
        hs = (f["zmax_dis"] >= ZMAX_H) | ((gm >= 0) & (gcount[np.maximum(gm, 0)] < N_BIN))
        pr = [models[w].predict(Xm) for w in WEIGHTS]
        lbc = np.min(np.vstack([lower(np, pw, hs, E[w]) for pw, w in zip(pr, WEIGHTS)]), axis=0)
        if abs(float(lbc.min()) - macros[kname]["LB"]) > 1e-5:
            sys.exit(f"{kname}: the cell bounds give {lbc.min():.5f}, the macro bound is {macros[kname]['LB']:.5f}")
        cells_sel[kname] = {f"{int(r_)},{int(c_)}": [round(float(pr[0][n_]), 5), round(float(pr[1][n_]), 5),
                                                    round(float(pr[2][n_]), 5), round(float(lbc[n_]), 5)]
                            for n_, (r_, c_) in enumerate(zip(f["R"], f["col"]))}
    # ---- data files of the selected tables, rebuilt from data/
    spec = importlib.util.spec_from_file_location("e86a2", os.path.join(here, "e8_6a2_rom_energy.py"))
    E6 = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(E6)
    out_dir = os.path.join(root, "e8_4a11", "tables")
    os.makedirs(out_dir, exist_ok=True)
    tabs_sel = sorted(set(k.rsplit("_r48k", 1)[0] for k in run_sel))
    print(f"\n   data files of the {len(tabs_sel)} tables (from data/rtl_inputs_<model>_v3, equal to the export):")
    for t in tabs_sel:
        _, M, side, ln, _ = t.split("_")
        wds = E6.table_words(a.paper2, M, side, int(ln[1:]), 2496)
        if "".join(f"{x:04x}" for x in wds) != th[t]:
            sys.exit(f"{t}: the table rebuilt from data/ differs from the export")
        fpath = os.path.join(out_dir, f"{t}.bin")
        with open(fpath, "wb") as fh:
            fh.write(bytes(b for x in wds for b in ((x >> 8) & 0xFF, x & 0xFF)))
        ks = [k for k in run_sel if k.startswith(t + "_")]
        print(f"   {t}: {md5(fpath)}  macro {', '.join('k' + k.rsplit('k', 1)[1] for k in ks)}")
    with open(os.path.join(out_dir, "selected.txt"), "w") as fh:
        fh.write(" ".join(tabs_sel) + "\n")
    with open(os.path.join(out_dir, "selected_macros.txt"), "w") as fh:
        fh.write("\n".join(run_sel) + "\n")
    pj = os.path.join(out_dir, "predictions.json")
    json.dump({"created": time.strftime("%Y-%m-%d %H:%M:%S"), "script_md5": md5(os.path.abspath(__file__)),
               "a10_select_md5": a10md5,
               "versions": {"python": sys.version.split()[0], "numpy": np.__version__, "sklearn": sklearn.__version__},
               "rule": {"T_COV_V": T_COV, "V_RULE": V_RULE, "PENALTY": PENALTY, "FAR": FAR, "LOW": LOW,
                        "ZMAX_H": ZMAX_H, "N_BIN": N_BIN, "N_SEL": N_SEL, "weights": WEIGHTS, "w_check": W_CHECK},
               "E_mV": {str(int(w)): {"HS": E[w][0], "M": E[w][1], "A": E[w][2]} for w in WEIGHTS},
               "groups": {group_name(k): int(gcount[k]) for k in range(32) if gcount[k]},
               "simulated_tables": sim_tables, "simulated_macros_e8_4a10": sim_macros,
               "selected": run_sel, "recomputed": sel, "macros": macros,
               "cells_selected": {k: v for k, v in cells_sel.items() if k in run_sel},
               "cells_note": "per cell: prediction at weight 5, 20, 50, and its lower bound (lowest over the weights)"},
              open(pj, "w"), indent=1)
    print(f"   written to {out_dir}: selected.txt ({len(tabs_sel)} tables), selected_macros.txt ({len(run_sel)} "
          f"macros), predictions.json ({md5(pj)})")
    print(f"done ({time.time() - t0:.0f} s)")
    return 0


# ------------------------------------------------------------------ check
def cmd_check(a):
    work = a.work or os.path.join(a.paper2, "reports", "e8_rom", "e8_4a11")
    pj = json.load(open(os.path.join(a.in_dir or os.path.join(work, "tables"), "predictions.json")))
    rule = pj["rule"]
    print(f"P2R-E8.4a-11 model check  {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"   predictions of {pj['created']}; J3: every selected macro, all {ROWS - 1} rows read, has its measured "
          f"lowest one-cell bitline at or above its bound LB (lowest over the weights of prediction - E)")
    print("   E (mV): " + "; ".join(f"weight {w}: HS {e['HS']:+.1f}, M {e['M']:+.1f}, A {e['A']:+.1f}"
                                     for w, e in pj["E_mV"].items()))
    print(f"   {'macro':<20} {'rows':>4} {'measured':>8} {'row':>4} {'col':>4}  {'LB':>6}  {'meas-LB':>8}  "
          f"{'pred w20':>8} {'row':>4} {'col':>4} {'w20-meas':>8}  {'cells':>5} {'below own LB':>12}  worst row in 8")
    beyond, missing, n, hit, allres = 0, 0, 0, 0, []
    for kname in pj["selected"]:
        lab = kname.replace("e8rom_", "").replace("_16x2496", "")
        rj = os.path.join(work, kname, "tt_cs", "result.json")
        if not os.path.isfile(rj):
            print(f"   {lab:<20} no screening result")
            missing += 1
            continue
        r_ = json.load(open(rj))
        cells = pj["cells_selected"].get(kname, {})
        best, res, rows, below = None, [], set(), 0
        for cy, x in zip(r_["meta"]["cycles"], r_["cycles"]):
            if cy["kind"] != "read" or not x.get("complete") or cy["row"] == 0:
                continue
            rows.add(cy["row"])
            for c, v in (x.get("bl1_by_col") or {}).items():
                if best is None or v < best[0]:
                    best = (v, cy["row"], int(c))
                q = cells.get(f"{cy['row']},{int(c)}")
                if q is not None:
                    res.append(q[1] - v)
                    below += v < q[3]
        p = pj["macros"][kname]
        if best is None:
            print(f"   {lab:<20} {len(rows):4d} no one-cell bitline in the result")
            missing += 1
            continue
        ok = best[0] >= p["LB"]
        full = len(rows) == ROWS - 1
        inrows = best[1] in p["rows8"]
        n += 1
        hit += inrows
        beyond += not ok
        missing += not full
        allres += res
        print(f"   {lab:<20} {len(rows):4d} {best[0]:8.3f} {best[1]:4d} {best[2]:4d}  {p['LB']:6.3f}  "
              f"{(best[0] - p['LB']) * 1000:+8.1f}  {p['min_w20']:8.3f} {p['row']:4d} {p['col']:4d} "
              f"{(p['min_w20'] - best[0]) * 1000:+8.1f}  {len(res):5d} {below:12d}  {'yes' if inrows else 'NO'}"
              f"{'' if ok else '   <- below its bound (J3)'}{'' if full else '   (not all rows read)'}")
    if allres:
        m = sum(allres) / len(allres)
        sd = (sum((x - m) ** 2 for x in allres) / len(allres)) ** 0.5
        print(f"   every measured one cell (prediction w20 - measurement, mV): {len(allres)} cells, mean {m * 1000:+.1f}, "
              f"SD {sd * 1000:.1f}, largest {max(allres) * 1000:+.1f}, smallest {min(allres) * 1000:+.1f}")
    print(f"   {n} of {len(pj['selected'])} macros measured; measured lowest row among the 8 rows with the lowest "
          f"prediction (w20): {hit} of {n}")
    # condition penalty of the new tables and the coverage of the macros not simulated
    pen, pf = None, os.path.join(work, "penalty.txt")
    if os.path.isfile(pf):
        vals = [float(ln.split()[1]) for ln in open(pf) if len(ln.split()) == 2]
        pen = max(vals) if vals else None
    tcov = round(rule["V_RULE"] + max(rule["PENALTY"], pen or 0.0) + rule["FAR"], 3)
    rest = sorted((r["LB"], k) for k, r in pj["macros"].items() if not r["simulated"] and k not in pj["selected"])
    under = [(lb, k) for lb, k in rest if lb < tcov]
    print(f"   condition penalty of the new tables: {'-' if pen is None else f'{pen:.3f} V'} (before {rule['PENALTY']:.3f} V);"
          f" coverage level {tcov:.3f} V")
    print(f"   macros neither simulated nor selected: {len(rest)}; lowest LB {rest[0][0]:.3f} V; below the coverage level: "
          f"{len(under)}" + (": " + ", ".join(f"{k.replace('e8rom_', '').replace('_16x2496', '')} {lb:.3f}"
                                              for lb, k in under) if under else ""))
    if beyond:
        print(f"   J3 DOES NOT HOLD ({beyond} macro(s) below their bound): the macros not simulated are not covered")
        return 1
    if missing:
        print(f"   J3 NOT JUDGED YET: {missing} macro(s) without a screening of all {ROWS - 1} rows")
        return 2
    print("   J3 HOLDS: the bound holds on every selected macro" +
          ("" if not under else f"; {len(under)} macro(s) not simulated are below the coverage level"))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("select")
    p.add_argument("--paper2", required=True)
    p = sp.add_parser("check")
    p.add_argument("--paper2", required=True)
    p.add_argument("--work", default="", help="output folder of the run (default reports/e8_rom/e8_4a11)")
    p.add_argument("--in-dir", default="", help="folder of predictions.json (default <work>/tables)")
    a = ap.parse_args()
    return cmd_select(a) if a.cmd == "select" else cmd_check(a)


if __name__ == "__main__":
    sys.exit(main())
