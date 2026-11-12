#!/usr/bin/env python3
"""P2R-E9.5: energy and area per inference with the address map of E9, for the TVLSI manuscript
(Table II, Figs. 5 to 7, Sections III-B to VI-C).

E9 holds the address map as one word per entry: the assignment bits of the 25 weights of the entry
(1 = not protected) and the number of protected weights of its layer before the entry (12 bits, stored
inverted), in seven ROM macros of 48 rows x 8 words x 40 bits per model (E9.1, E9.2). This script puts it
in place of the 50-table map of E8 in the accounting of E10.2b (25 SRAM banks, no conv1 cache):

  D = D_ROM + AMU logic
    D_ROM      the ROM reads of one inference (E9.1 event lists) replayed as the E9.3b judge does, with the
               measured power of a parked macro integrated over each rest (E9.3c: the fine runs to 10.1 us
               after the parking read, then the settled level of the coarse runs, their mean power 910 to
               982 us after it, where no window boundary falls) and the address changes that the idle macros
               see on the shared address bus (E9.3c). Then the rule of E8 for the parts that come from fitted
               models: each is divided by 1 + the mean held-out error of its model, and its range takes that
               mean +- 2 standard errors. Lookup model (one set of coefficients for the 14 macros): each macro
               left out of the fit in turn, the error of the sum over its simulated lookups as in gate W2 of
               E9.3b. Convolution pair fit (one per model, macro 0): each of the 12 pairs left out in turn,
               the fit made again from the other 11 by the same rule. The measured parts (parking reads after
               a dense run, rest after parking, unread leakage, address changes) are not changed.
    AMU logic  gate-level energy of the synthesised address-map unit within the RTL inference (E9.4,
               read-once runs, as fixed before that run)
  area of the map = 7 macros (drawn layout extent, E9.2) + AMU logic (synthesis, E9.1)

A (digital periphery), B (25 SRAM banks and their pool logic), C (crossbar), their ranges, the other
blocks' areas and the SRAM figures come from reports/e10/e10_2b/e10_2b_summary.json (scripts/e10_2b_recost.py).
Also written: the data of Figs. 5 to 7 (bit lines and margins of the 14 macros, power at rest after
parking, area against the budget) and the numbers of Sections III to VI that depend on the map.

Inputs (paths relative to --paper2; the md5 of each is recorded in the output):
  reports/e10/e10_2b/e10_2b_summary.json, reports/e8_6/e8_6_summary.json
  reports/e9/e9_1/e9_1_summary.json, tables/e9_1_tables.json, syn/amu9_stat_final.txt, rtl/e9ev_normal_{A,B}.txt
  reports/e9_rom/e9_2/: area/*.box.log, bins/*.bin, <macro>/tt_cs/result.json, <macro>/lvs/netgen.log,
                        logs/bitcheck_<macro>.txt, e9rom_{A,B}_40x2688_w8/corner_*/result.json, vm/vm.txt
  reports/e9_rom/e9_3/ (plan.json, runs), e9_3b/ (plan.json, runs, e9_3b_summary.json),
                        e9_3c/ (plan.json, runs, e9_3c_summary.json)
  reports/e9/e9_4/e9_4_summary.json, names.tsv.gz, power/once_{A,B}_instances.rpt.gz
  scripts/e9_3_tools.py, e9_3b_tools.py, e9_3c_tools.py (imported; the versions that judged E9.3 to E9.3c)

Usage: python3 scripts/e9_5_recost.py --paper2 . --out reports/e9/e9_5
"""
import argparse
import glob
import gzip
import hashlib
import json
import math
import os
import re
import statistics
import sys

MODELS = ("A", "B")
NM = 7                                   # macros per model
TOOLS_MD5 = {"e9_3_tools.py": "1332055cd19b7577cb56b00efa7b69ff",
             "e9_3b_tools.py": "88dbecfd3c9a5d9a2864911fdc955147",
             "e9_3c_tools.py": "08259d6e84b347ce477ca4f4999cd067"}
LAYERS = ("conv1", "conv2", "fc1", "fc2", "fc3")
LAYER_WEIGHTS = {"conv1": 150, "conv2": 2400, "fc1": 48000, "fc2": 10080, "fc3": 840}   # N_L, Section III-B
ENTRY_BITS = 25 + 12                     # assignment bits and the count; the word's other 3 bits are constant
LANES = 25
RESNET_LARGEST_LAYER = 512 * 512 * 9     # ResNet-50: the 3 x 3 convolutions of its last stage
COND_DIRS = {"fs_25C_1v80": "fs:25:1.80", "tt_25C_1v60": "tt:25:1.60", "fs_m40C_1v60": "fs:-40:1.60"}
RULE_V = 0.10                            # margin rule of the bit lines (V)


def md5(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def box_extent(path):
    """width and height (um) of the root cell box that Magic prints"""
    t = open(path, errors="replace").read()
    m = re.search(r"Root cell box:.*?microns:\s+([\d.]+)\s+x\s+([\d.]+)", t, re.S)
    if not m:
        raise SystemExit(f"no root cell box in {path}")
    return float(m.group(1)), float(m.group(2))


def stat_areas(path):
    """chip area of each module and of the top in a Yosys stat report"""
    t = open(path, errors="replace").read()
    mods = {m.group(1): float(m.group(2)) for m in re.finditer(r"Chip area for module '\\?([^']+)': ([\d.]+)", t)}
    top = re.search(r"Chip area for top module '\\?([^']+)': ([\d.]+)", t)
    seq = re.search(r"of which used for sequential elements: ([\d.]+)", t)
    return mods, (top.group(1), float(top.group(2))) if top else None, float(seq.group(1)) if seq else None


def short(mod):
    """amu9_decode from $paramod$<hash>\\amu9_decode"""
    return mod.split("\\")[-1]


def cell_energy(rpt_gz, names_gz, dur_ms):
    """energy (uJ) per cell type and per top-level part from the instance power report of E9.4"""
    names = {}
    with gzip.open(names_gz, "rt") as f:
        for ln in f:
            if ln.startswith("#"):
                continue
            x = ln.rstrip("\n").split(" ")
            if len(x) >= 4 and x[1] == "cell":
                names[x[0]] = (x[2], x[3])
    by_type, by_part, n_type, total = {}, {}, {}, 0.0
    with gzip.open(rpt_gz, "rt") as f:
        for ln in f:
            x = ln.split()
            if len(x) != 5 or x[4] not in names:
                continue
            try:
                p = float(x[3])
            except ValueError:
                continue
            orig, typ = names[x[4]]
            e = p * dur_ms * 1e-3 * 1e6
            total += e
            by_type[typ] = by_type.get(typ, 0.0) + e
            n_type[typ] = n_type.get(typ, 0) + 1
            part = orig.split(".")[0] if "." in orig else "top"
            key = (part, typ)
            by_part[key] = by_part.get(key, 0.0) + e
    return total, by_type, n_type, by_part


def vmin(xs):
    xs = [x for x in xs if x is not None]
    return min(xs) if xs else None


def vmax(xs):
    xs = [x for x in xs if x is not None]
    return max(xs) if xs else None


def log2_binom(n, k):
    return (math.lgamma(n + 1) - math.lgamma(k + 1) - math.lgamma(n - k + 1)) / math.log(2)


def mean_se(x):
    m = statistics.mean(x)
    sd = statistics.stdev(x)
    return m, sd, sd / math.sqrt(len(x))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--paper2", default=".")
    ap.add_argument("--out", default="reports/e9/e9_5")
    a = ap.parse_args()
    P = lambda *x: os.path.join(a.paper2, *x)  # noqa: E731
    checks = []

    def check(name, ok, detail):
        checks.append({"check": name, "ok": bool(ok), "detail": detail})

    # ---- the tools of E9.3 to E9.3c, unchanged ----------------------------------------------------------------
    sdir = os.path.abspath(P("scripts"))
    tools = {k: md5(os.path.join(sdir, k)) for k in TOOLS_MD5}
    bad = {k: v for k, v in tools.items() if v != TOOLS_MD5[k]}
    if bad:
        raise SystemExit(f"the tools differ from the versions that judged E9.3 to E9.3c: {bad}")
    sys.path.insert(0, sdir)
    import e9_3c_tools as C                                     # noqa: E402  (imports e9_3b_tools, e9_3_tools)
    B, T = C.B, C.T

    f_e10 = P("reports", "e10", "e10_2b", "e10_2b_summary.json")
    f_e86 = P("reports", "e8_6", "e8_6_summary.json")
    d91 = P("reports", "e9", "e9_1")
    f_91 = os.path.join(d91, "e9_1_summary.json")
    f_91t = os.path.join(d91, "tables", "e9_1_tables.json")
    f_stat = os.path.join(d91, "syn", "amu9_stat_final.txt")
    e91 = os.path.join(d91, "rtl")
    f_ev = {M: os.path.join(e91, f"e9ev_normal_{M}.txt") for M in MODELS}
    R2 = P("reports", "e9_rom", "e9_2")
    bins = os.path.join(R2, "bins")
    mac = {(M, m): f"e9rom_{M}_40x2688_w8_r48k{m}" for M in MODELS for m in range(NM)}
    f_box = {k: os.path.join(R2, "area", f"{n}.box.log") for k, n in mac.items()}
    f_bin = {k: os.path.join(bins, f"{n}.bin") for k, n in mac.items()}
    f_tt = {k: os.path.join(R2, n, "tt_cs", "result.json") for k, n in mac.items()}
    f_lvs = {k: os.path.join(R2, n, "lvs", "netgen.log") for k, n in mac.items()}
    f_bit = {k: os.path.join(R2, "logs", f"bitcheck_{n}.txt") for k, n in mac.items()}
    f_cond = {(M, c): os.path.join(R2, f"e9rom_{M}_40x2688_w8", f"corner_{c}", "result.json") for M in MODELS for c in COND_DIRS}
    f_worst = {M: os.path.join(R2, f"e9rom_{M}_40x2688_w8", "worst_macro") for M in MODELS}
    f_vm = os.path.join(R2, "vm", "vm.txt")
    f_tab = {M: os.path.join(R2, "tables", f"e9rom_{M}_40x2688_w8.bin") for M in MODELS}
    R3, R3b, R3c = (P("reports", "e9_rom", x) for x in ("e9_3", "e9_3b", "e9_3c"))
    f_3b, f_3c = os.path.join(R3b, "e9_3b_summary.json"), os.path.join(R3c, "e9_3c_summary.json")
    d94 = P("reports", "e9", "e9_4")
    f_94 = os.path.join(d94, "e9_4_summary.json")
    f_names = os.path.join(d94, "names.tsv.gz")
    f_inst = {M: os.path.join(d94, "power", f"once_{M}_instances.rpt.gz") for M in MODELS}
    plans = {x: os.path.join(R, "plan.json") for x, R in (("e9_3", R3), ("e9_3b", R3b), ("e9_3c", R3c))}
    inputs = [f_e10, f_e86, f_91, f_91t, f_stat, *f_ev.values(), *f_box.values(), *f_bin.values(), *f_tt.values(),
              *f_cond.values(), *f_worst.values(), f_vm, *f_tab.values(), f_3b, f_3c, *plans.values(), f_94, f_names, *f_inst.values()]
    miss = [p for p in inputs if not os.path.isfile(p)]
    if miss:
        raise SystemExit("missing inputs:\n   " + "\n   ".join(miss))
    out = {"inputs": {os.path.relpath(p, a.paper2): md5(p) for p in inputs},
           "tools": tools,
           "runs_md5": {}}
    e10 = json.load(open(f_e10))
    e86 = json.load(open(f_e86))
    s91 = json.load(open(f_91))
    t91 = json.load(open(f_91t))
    s94 = json.load(open(f_94))
    s3b = json.load(open(f_3b))
    s3c = json.load(open(f_3c))
    con = e10["constants"]
    t_inf_ms, macs = con["inference_ms"], con["macs"]
    check("E10.2b: all checks pass", e10.get("all_checks_pass") is True, str(e10.get("all_checks_pass")))
    check("E9.1, E9.3b, E9.3c, E9.4: all gates passed",
          all(x.get("all_pass") is True for x in (s91, s3b, s3c, s94)),
          ", ".join(f"{n} {x.get('all_pass')}" for n, x in (("E9.1", s91), ("E9.3b", s3b), ("E9.3c", s3c), ("E9.4", s94))))

    # ---- the map: tables (E9.1) ------------------------------------------------------------------------------
    tab = {}
    for M in MODELS:
        x = t91["models"][M]
        lay = x["layers"]
        nw = sum(LAYER_WEIGHTS.values())
        bound = sum(log2_binom(LAYER_WEIGHTS[L], lay[L]["protected"]) for L in LAYERS)
        tab[M] = {"entries": x["entries"], "macros": x["macros"], "protected": x["protected"],
                  "layers": lay, "map_bits_content": x["entries"] * ENTRY_BITS, "map_bits_words": x["map_bits"],
                  "stored_bits": x["macros"] * t91["words_per_macro"] * t91["word_bits"],
                  "zero_fraction": [z["zero_fraction"] for z in x["macro_zeros"]],
                  "assignment_bits": x["entries"] * LANES, "count_bits": x["entries"] * (ENTRY_BITS - LANES),
                  "information_bound_bits": bound, "content_over_bound": x["entries"] * ENTRY_BITS / bound,
                  "decode_differences": x["decode_differences"]}
        check(f"E9.1 model {M}: the images decode to the slot tables of every weight (0 differences, {x['weights_decoded']} weights)",
              x["weights_decoded"] == nw and not any(x["decode_differences"].values()) and x.get("image_reads_back") is True,
              json.dumps(x["decode_differences"]))
        check(f"model {M}: protected weights per layer sum to {x['protected']}",
              sum(lay[L]["protected"] for L in LAYERS) == x["protected"] == e86["constants"]["protected"][0],
              ", ".join(f"{L} {lay[L]['protected']}" for L in LAYERS))
    flat_bits = 50 * e86["constants"]["weights"][0] * 16                          # 50 tables of every weight, 16 bit
    per_lane_bits = 50 * tab["A"]["entries"] * 16                                     # 50 tables of each lane's share, 16 bit
    out["map"] = {"word": {"bits": t91["word_bits"], "assignment_bits": LANES, "count_bits": ENTRY_BITS - LANES,
                           "constant_bits": t91["word_bits"] - ENTRY_BITS, "rows": t91["rows"],
                           "words_per_row": t91["words_per_row"], "columns": t91["columns"],
                           "words_per_macro": t91["words_per_macro"], "entries_per_macro": t91["entries_per_macro"],
                           "parking_address": t91["parking_address"]},
                  "tables": tab, "flat_tables_bits": flat_bits, "per_lane_tables_bits": per_lane_bits,
                  "flat_over_map": flat_bits / tab["A"]["map_bits_content"],
                  "per_lane_over_map": per_lane_bits / tab["A"]["map_bits_content"]}
    check("weights of the layers = the network's 61,470", sum(LAYER_WEIGHTS.values()) == e86["constants"]["weights"][0],
          str(sum(LAYER_WEIGHTS.values())))

    # ---- ROM macros (E9.2): extents, generation checks, bit lines and margins ------------------------------------
    for M in MODELS:
        whole = open(f_tab[M], "rb").read()
        cut = b"".join(open(f_bin[(M, m)], "rb").read() for m in range(NM))
        check(f"model {M}: the 14 macro images are the table of E9.2, which is the image of E9.1",
              whole == cut and md5(f_tab[M]) == t91["models"][M]["bin_md5"], f"{md5(f_tab[M])}")
    ext = {k: box_extent(p) for k, p in f_box.items()}
    w0, h0 = ext[("A", 0)]
    check("E9.2: the 14 macros have one drawn extent", all(v == (w0, h0) for v in ext.values()),
          f"{w0} x {h0} um" + ("" if all(v == (w0, h0) for v in ext.values()) else f"; {ext}"))
    lvs = {k: "Circuits match uniquely" in open(p, errors="replace").read() for k, p in f_lvs.items() if os.path.isfile(p)}
    bit = {k: "STORES THE DATA EXACTLY" in open(p, errors="replace").read() for k, p in f_bit.items() if os.path.isfile(p)}
    check("E9.2: LVS of the 14 macros match uniquely (netgen)", len(lvs) == 14 and all(lvs.values()), f"{sum(lvs.values())} of {len(lvs)}")
    check("E9.2: the 14 macros store the data exactly (bit check)", len(bit) == 14 and all(bit.values()), f"{sum(bit.values())} of {len(bit)}")
    vm = {}
    for ln in open(f_vm):
        x = ln.split()
        if len(x) == 2:
            vm[x[0]] = float(x[1])

    def cond_key(meta):
        return f"{meta['corner']}:{meta['temp']:g}:{meta['vdd']:.2f}"
    macros = {}
    for k in mac:
        r = json.load(open(f_tt[k]))
        key = cond_key(r["meta"])
        rd = [c for c in r["cycles"] if c["kind"] == "read"]
        tg = [c for c in rd if c["row"] != 0]
        rows = []
        for c in tg:
            rows.append({"row": c["row"], "addr": c["addr"], "bl1_min_V": c["bl1_min_V"], "bl0_max_V": c["bl0_max_V"],
                         "zeros_in_row": c["zeros_in_row"], "zeros_in_word": c["zeros_in_word"], "E_vdd_pJ": c["E_vdd_pJ"],
                         "t_access_ns": c["t_access_ns"]})
        # one cells next to discharging columns: the bit lines of every one cell of the read row (bl1_by_col)
        nb = []
        for c in tg:
            b1 = {int(col): v for col, v in c.get("bl1_by_col", {}).items()}
            if not b1:
                continue
            ones = set(b1)
            for col, v in b1.items():
                n = sum(1 for d in (-1, 1) if 0 <= col + d < T.WPR * T.WBITS and (col + d) not in ones)
                nb.append((v, n, c["row"]))
        slope = None
        if len(nb) > 3:
            cf = T.lstsq([[1.0, n, r_] for v, n, r_ in nb], [v for v, n, r_ in nb])
            slope = {"per_discharging_neighbour_V": cf[1], "per_row_V": cf[2], "cells": len(nb)} if cf else None
        macros[f"{k[0]}_k{k[1]}"] = {
            "condition": key, "reads": len(rd), "reads_ok": sum(1 for c in rd if c.get("ok")),
            "selection_ok": sum(1 for c in rd if c.get("selection_ok")), "targets": len(tg),
            "complete": r["summary"]["cycles_complete"] == r["summary"]["cycles_total"] and not r["summary"]["failed"],
            "bl1_min_V": vmin(c["bl1_min_V"] for c in tg), "bl0_max_V": vmax(c["bl0_max_V"] for c in rd),
            "margin_one_V": vmin(c["bl1_min_V"] for c in tg) - vm[key], "margin_zero_V": vm[key] - vmax(c["bl0_max_V"] for c in rd),
            "t_access_ns_max": vmax(c["t_access_ns"] for c in rd), "E_read_pJ_mean": r["summary"]["E_read_pJ_mean"],
            "rows": rows, "neighbour_fit": slope}
    ok_tt = all(v["complete"] and v["reads_ok"] == v["reads"] == v["selection_ok"] == 94 and v["targets"] == 47 for v in macros.values())
    check("E9.2 tt, 25 C, 1.80 V: every row of the 14 macros read right (47 rows and 47 reads of row 0 each)", ok_tt,
          ", ".join(f"{k} {v['reads_ok']}/{v['reads']}" for k, v in macros.items()))
    cond = {}
    for M in MODELS:
        worst = open(f_worst[M]).read().strip()
        for c in COND_DIRS:
            r = json.load(open(f_cond[(M, c)]))
            key = cond_key(r["meta"])
            rd = [x for x in r["cycles"] if x["kind"] == "read"]
            tg = [x for x in rd if x["row"] != 0]
            only_bl = key == "fs:-40:1.60"
            cond[f"{M} {key}"] = {
                "macro": worst, "condition": key, "only_bit_lines": only_bl, "reads": len(rd),
                "reads_ok": sum(1 for x in rd if x.get("ok")), "selection_ok": sum(1 for x in rd if x.get("selection_ok")),
                "words": [x["addr"] for x in tg], "bl1_min_V": vmin(x["bl1_min_V"] for x in tg),
                "bl0_max_V": vmax(x["bl0_max_V"] for x in rd), "vm_V": vm[key],
                "margin_one_V": vmin(x["bl1_min_V"] for x in tg) - vm[key], "margin_zero_V": vm[key] - vmax(x["bl0_max_V"] for x in rd),
                "t_access_ns_max": None if only_bl else vmax(x["t_access_ns"] for x in rd),
                "per_word": [{"addr": x["addr"], "row": x["row"], "bl1_min_V": x["bl1_min_V"], "margin_V": x["bl1_min_V"] - vm[key]}
                             for x in tg]}
    ok_c = all((v["only_bit_lines"] or v["reads_ok"] == v["reads"]) and v["selection_ok"] == v["reads"] for v in cond.values())
    ok_rule = all(v["margin_one_V"] >= RULE_V and v["margin_zero_V"] >= RULE_V for v in list(cond.values()) + list(macros.values()))
    check("E9.2 other conditions: reads right (bit lines only at fs, -40 C, 1.60 V), selection right", ok_c,
          ", ".join(f"{k} {v['reads_ok']}/{v['reads']}" for k, v in cond.items()))
    check(f"E9.2: every one cell {RULE_V:.2f} V above and every zero cell {RULE_V:.2f} V below the switching level", ok_rule,
          f"smallest one-cell margin {min(v['margin_one_V'] for v in list(cond.values()) + list(macros.values())):.3f} V")
    mm = {}
    for M in MODELS:
        tt = [v for k, v in macros.items() if k.startswith(M)]
        mm[M] = {"tt:25:1.80": min(v["margin_one_V"] for v in tt)}
        for c in COND_DIRS.values():
            mm[M][c] = cond[f"{M} {c}"]["margin_one_V"]
    nfit = [v["neighbour_fit"]["per_discharging_neighbour_V"] for v in macros.values() if v["neighbour_fit"]]
    rfit = [v["neighbour_fit"]["per_row_V"] for v in macros.values() if v["neighbour_fit"]]
    rom_um2 = w0 * h0
    out["rom"] = {"extent_um": [w0, h0], "macro_um2": rom_um2, "macro_mm2": rom_um2 * 1e-6, "macros_per_model": NM,
                  "model_mm2": NM * rom_um2 * 1e-6, "um2_per_stored_bit": rom_um2 / (t91["words_per_macro"] * t91["word_bits"]),
                  "vm_V": vm, "macros_tt": macros, "conditions": cond, "smallest_margin_V": mm,
                  "smallest_margin_all_V": {c: min(mm[M][c] for M in MODELS) for c in mm["A"]},
                  "t_access_ns_max": {"tt:25:1.80": max(v["t_access_ns_max"] for v in macros.values()),
                                      **{c: max(cond[f"{M} {c}"]["t_access_ns_max"] or 0 for M in MODELS)
                                         for c in ("fs:25:1.80", "tt:25:1.60")}},
                  "neighbour_V": [min(nfit), max(nfit)] if nfit else None, "per_row_V": [min(rfit), max(rfit)] if rfit else None,
                  "E8_rom_model_mm2": e86["area"]["rom_mm2"]}

    # ---- ROM reads of one inference (E9.1 event lists) ------------------------------------------------------------
    reads = {}
    for M in MODELS:
        ev = T.read_events(f_ev[M])
        inf = [e for e in ev if e[1] == "I"]
        per = [{"macro": m, "lookups": sum(1 for e in inf if e[3] == m and e[0] == "L"),
                "parking": sum(1 for e in inf if e[3] == m and e[0] == "P")} for m in range(NM)]
        bz = C.bus(e91, M)
        mon = s91["runs"][f"normal_{M}"]["monitor"]
        reads[M] = {"lookups": sum(1 for e in inf if e[0] == "L"), "parking": sum(1 for e in inf if e[0] == "P"),
                    "before_start": sum(1 for e in ev if e[1] == "B"), "per_macro": per, "bus": bz,
                    "steps": mon["operations"], "stall_cycles": mon["stall_cycles"],
                    "low_min_cycles": {"lookup": mon["low_min_lookup_cycles"], "parking": mon["low_min_park_cycles"]}}
        reads[M]["total"] = reads[M]["lookups"] + reads[M]["parking"]
        check(f"model {M}: ROM reads in the inference = those of E9.4's gate-level run minus the 2 before the start",
              reads[M]["total"] + reads[M]["before_start"] == s94["runs"][f"once:{M}"]["info"]["rom"]["model_reads"]
              and reads[M]["before_start"] == mon["ev_before_start"],
              f"{reads[M]['lookups']} lookups + {reads[M]['parking']} parking reads, {reads[M]['before_start']} before the start")
        check(f"model {M}: the datapath start is never held ({mon['stall_cycles']} cycles), {mon['operations']} steps",
              mon["stall_cycles"] == 0, str(mon["stall_cycles"]))
    out["reads"] = reads

    # ---- D_ROM (E9.3, E9.3b, E9.3c) -----------------------------------------------------------------------------------
    class Args:
        pass
    a3 = Args()
    a3.plan3, a3.runs3 = plans["e9_3"], os.path.join(R3, "runs")
    a3.plan3b, a3.runs3b = plans["e9_3b"], os.path.join(R3b, "runs")
    F, bad = C.fits_e93b(a3)
    if F is None:
        raise SystemExit("the runs of E9.3 / E9.3b cannot be read: " + "; ".join(bad))
    p3c = json.load(open(plans["e9_3c"]))
    cyc = {}
    for key, r in p3c["runs"].items():
        cy, why = C.cycles(os.path.join(R3c, "runs", key), r["roles"])
        if cy is None:
            raise SystemExit(f"E9.3c run {key}: {why}")
        cyc[key] = cy
    for tag, R in (("e9_3", R3), ("e9_3b", R3b), ("e9_3c", R3c)):
        for key in json.load(open(plans[tag]))["runs"]:
            out["runs_md5"][f"{tag}/{key}"] = md5(os.path.join(R, "runs", key, "result.json"))
    e_fall, e_rise = s3c["bus"]["e_fall_pJ_per_bit"], s3c["bus"]["e_rise_pJ_per_bit"]
    fine, coarse, settled, unread, rest = {}, {}, {}, {}, {}
    for M in MODELS:
        for m in (0, 1):
            fk, ck = f"F_{M}_k{m}", f"C_{M}_k{m}"
            fine[(M, m)] = C.curve(cyc[fk], p3c["runs"][fk]["roles"], "fine")
            coarse[(M, m)] = C.curve(cyc[ck], p3c["runs"][ck]["roles"], "coarse")
            last = [c for c, r in zip(cyc[ck], p3c["runs"][ck]["roles"]) if r["role"] == "rest"][-1]
            settled[(M, m)] = last["P_after_uW"]              # mean power 910 to 982 us after the parking read
            unread[(M, m)] = cyc[fk][0]["P_after_uW"]
            lv = s3c["levels"][f"{M}_k{m}"]
            rest[f"{M}_k{m}"] = {"unread_uW": unread[(M, m)], "first_us_uW": C.mean_uW(fine[(M, m)], 100, 1100),
                                 "1.1-2.1us_uW": C.mean_uW(fine[(M, m)], 1100, 2100),
                                 "9.1-10.1us_uW": C.mean_uW(fine[(M, m)], 9100, 10100),
                                 "10.1-11.1us_uW": lv["10.1-11.1us_uW (fine)"],
                                 "20-100us_uW": C.mean_uW(coarse[(M, m)], 20000, 100000), "settled_uW": settled[(M, m)],
                                 "settled_over_unread": settled[(M, m)] / unread[(M, m)],
                                 "settled_minus_unread_uW": settled[(M, m)] - unread[(M, m)],
                                 "20-100us_over_settled": C.mean_uW(coarse[(M, m)], 20000, 100000) / settled[(M, m)] - 1,
                                 "10.1-11.1us_over_settled": lv["10.1-11.1us_uW (fine)"] / settled[(M, m)] - 1,
                                 "fine_windows": fine[(M, m)],
                                 "coarse_windows": [w for w in coarse[(M, m)] if w[0] >= 20000 - 1e-6]}
    out["rest"] = rest
    drom = {}
    for M in MODELS:
        mf = F["mfun"](M)
        bz = C.bus(e91, M)
        tog = (e_fall * bz["falling_bits"] + e_rise * bz["rising_bits"]) * (NM - 1) * 1e-6
        # the replay with E9.3's constant parked power gives E9.3b's final D_ROM (gate G1 of E9.3c)
        t0, _, _ = C.replay_rest(M, e91, bins, mf, lambda m, L, pre, mf=mf: mf(m)["p_parked"] * 1e-6 * L * 1e-9 * 1e6)
        check(f"model {M}: replay with E9.3's parked power = E9.3b's final D_ROM", B.close(t0, s3b["D_ROM_final"][M]["uJ"], 1e-9),
              f"{t0:.9f} / {s3b['D_ROM_final'][M]['uJ']:.9f} uJ")

        # E9.3c's main value (fine windows to 10.1 us, then the coarse windows) from these inputs
        def rest_v1(m, L, pre, M=M):
            w = C.rest_curve(fine[(M, min(m, 1))], coarse[(M, min(m, 1))])
            e = C.span(w, 100.0, 100.0 + L)
            if 100.0 + L > w[-1][1]:
                e += w[-1][2] / (w[-1][1] - w[-1][0]) * (100.0 + L - w[-1][1])
            return e * 1e-6
        t1, _, _ = C.replay_rest(M, e91, bins, mf, rest_v1, tog)
        ref1 = s3c["D_ROM"]["main: measured rest power, address changes on idle macros"][M]["uJ"]
        check(f"model {M}: E9.3c's main D_ROM from these inputs", B.close(t1, ref1, 1e-9), f"{t1:.9f} / {ref1:.9f} uJ")

        # the final form: fine windows to 10.1 us, then the settled level (no window boundary in it)
        def rest_v2(m, L, pre, M=M):
            w = fine[(M, min(m, 1))]
            e = C.span(w, 100.0, min(100.0 + L, C.FINE_SPLIT))
            if 100.0 + L > C.FINE_SPLIT:
                e += settled[(M, min(m, 1))] * (100.0 + L - C.FINE_SPLIT) * 1e-3
            return e * 1e-6
        t2, parts, cnt = C.replay_rest(M, e91, bins, mf, rest_v2, tog)
        check(f"model {M}: replay counts = the inference's reads", cnt["L"] == reads[M]["lookups"] and cnt["P"] == reads[M]["parking"],
              f"{cnt['L']} / {cnt['P']}")
        check(f"model {M}: D_ROM parts sum to D_ROM", abs(sum(parts.values()) - t2) < 1e-12, f"{t2:.9f} uJ")
        drom[M] = {"uJ": t2, "parts_uJ": parts, "reads": cnt, "E9.3c_main_uJ": t1, "E9.3b_final_uJ": t0,
                   "address_bus": bz, "address_changes_uJ": tog}

    # held-out errors of the two fitted models
    p3, pb = json.load(open(plans["e9_3"])), json.load(open(plans["e9_3b"]))
    samples, pairs = [], {M: [] for M in MODELS}
    for tag, p, runs in (("E9.3", p3, a3.runs3), ("E9.3b", pb, a3.runs3b)):
        for key, r in p["runs"].items():
            x, why = B.extract(os.path.join(runs, key), r["roles"])
            if x is None:
                raise SystemExit(f"{tag} {key}: {why}")
            for s in x["dense"]:
                samples.append(dict(s, M=r["model"], m=r["macro"]))
            if r["macro"] == 0:
                pairs[r["model"]] += x["conv"]
    coef = B.lfit(samples)
    check("lookup model refitted on the samples = the one of the final replay",
          len(samples) == F["n"] and all(B.close(x, y, 1e-12) for x, y in zip(coef, F["coef"])),
          f"{len(samples)} lookups; " + ", ".join(f"{c:.4f}" for c in coef))

    def adj(M, m, s):
        return T.pred(F["fits3"][(M, m)]["fp"], s) * 1e-6 * (s["low_after"] - 9) * T.CYC * 1e-9 * 1e12
    lomo = {}
    for M in MODELS:
        for m in range(NM):
            tr = [s for s in samples if (s["M"], s["m"]) != (M, m)]
            te = [s for s in samples if (s["M"], s["m"]) == (M, m)]
            cf = B.lfit(tr)
            me = sum(s["E"] for s in te)
            pr = sum(B.lpred(cf, s) + adj(M, m, s) for s in te)
            lomo[f"{M}_k{m}"] = {"lookups": len(te), "measured_pJ": me, "model_pJ": pr, "error": pr / me - 1}
    eL, sdL, seL = mean_se([v["error"] for v in lomo.values()])
    lopo = {}
    for M in MODELS:
        pp = pairs[M]
        el = []
        for i in range(len(pp)):
            f = T.fit(pp[:i] + pp[i + 1:], "E_pair")
            el.append(T.pred(f, pp[i]) / pp[i]["E_pair"] - 1)
        mu, sd, se = mean_se(el)
        lopo[M] = {"pairs": len(pp), "form": F["fc"][M]["form"], "errors": el, "mean": mu, "sd": sd, "se": se}
        check(f"model {M}: 12 convolution pairs (E9.3 and E9.3b)", len(pp) == 12, str(len(pp)))
    check("lookup model: 14 macros left out in turn", len(lomo) == 14, str(len(lomo)))
    LOOK = ("dense lookups (to the next read, 9 cycles low)", "static of unparked gaps beyond 9 cycles",
            "last lookup of a dense run (parked 5 cycles later)")
    CONV = ("convolution lookup-and-park pairs (macro 0)",)
    READ = LOOK[:1] + LOOK[2:] + CONV + ("parking reads after a dense run",)
    STATIC = ("static of unparked gaps beyond 9 cycles", "parked", "unread (before the first read)")
    for M in MODELS:
        d = drom[M]
        pr = d["parts_uJ"]
        Lp = sum(pr[k] for k in LOOK)
        Cp = sum(pr[k] for k in CONV)
        meas = d["uJ"] - Lp - Cp
        eC, seC = lopo[M]["mean"], lopo[M]["se"]
        cor = Lp / (1 + eL) + Cp / (1 + eC) + meas
        lo = Lp / (1 + eL + 2 * seL) + Cp / (1 + eC + 2 * seC) + meas
        hi = Lp / (1 + eL - 2 * seL) + Cp / (1 + eC - 2 * seC) + meas
        pc = {k: (v / (1 + eL) if k in LOOK else v / (1 + eC) if k in CONV else v) for k, v in pr.items()}
        d.update({"model_parts_uJ": {"lookup model": Lp, "convolution pair fit": Cp}, "measured_parts_uJ": meas,
                  "corrected_uJ": cor, "range_uJ": [lo, hi], "corrected_parts_uJ": pc,
                  "reads_share": sum(pc[k] for k in READ) / cor, "static_share": sum(pc[k] for k in STATIC) / cor,
                  "unread_share_of_static": pc["unread (before the first read)"] / sum(pc[k] for k in STATIC),
                  "address_changes_share": pc.get("address changes seen by the idle macros", 0.0) / cor,
                  "reads_uJ": sum(pc[k] for k in READ), "static_uJ": sum(pc[k] for k in STATIC),
                  "pins_not_included_uJ": s3c["pins"][M]["uJ_not_in_D"]})
        check(f"model {M}: corrected D_ROM inside its range", lo <= cor <= hi, f"{lo:.5f} <= {cor:.5f} <= {hi:.5f}")
    out["d_rom"] = {"models": drom, "lookup_model": {"coef": coef, "lookups": len(samples), "leave_one_macro_out": lomo,
                                                     "mean": eL, "sd": sdL, "se": seL},
                    "pair_fit": lopo, "pins_C_fF": s3c["pins"]["C_fF"],
                    "rule": "model parts / (1 + mean held-out error); range with mean +- 2 SE; measured parts unchanged"}

    # mean energy of a lookup read over its cycle (9 cycles low), Model A and B, from the lookup model
    lk = {}
    for M in MODELS:
        ev = [e for e in T.read_events(f_ev[M]) if e[1] == "I" and e[0] == "L"]
        words = {m: T.read_words(f_bin[(M, m)]) for m in range(NM)}
        rz = {m: T.row_zeros(words[m]) for m in range(NM)}
        es = [B.lpred(coef, {"z_word": T.zeros(words[e[3]][e[4]]), "z_row": rz[e[3]][e[4] // T.WPR], "pos": B.pos(e[4])})
              for e in ev]
        zw = [T.zeros(words[e[3]][e[4]]) for e in ev]
        lk[M] = {"lookups": len(ev), "mean_pJ": statistics.mean(es) / (1 + eL), "mean_uncorrected_pJ": statistics.mean(es),
                 "min_pJ": min(es) / (1 + eL), "max_pJ": max(es) / (1 + eL), "zero_bits_per_word_mean": statistics.mean(zw)}
    sim = [s["E9"] for s in samples]
    park_e = [x["E_P"] for M in MODELS for x in pairs[M]]
    ps = [s["P_s"] for s in samples]
    out["lookup_read"] = {"models": lk, "simulated_lookups_E9_pJ": [min(sim), statistics.mean(sim), max(sim)],
                          "static_end_of_low_uW": [min(ps), statistics.median(ps), max(ps)],
                          "pair_parking_read_pJ_mean": statistics.mean(park_e), "pair_parking_reads": len(park_e)}

    # ---- AMU logic (E9.1 synthesis, E9.4 gate level) ------------------------------------------------------------------
    mods, top, seq = stat_areas(f_stat)
    syn = s91["synthesis"]
    check("AMU area: Yosys report = E9.1 summary = E9.4 design", top is not None and abs(top[1] - syn["area_um2"]) < 1e-3
          and abs(syn["area_um2"] - s94["design"]["area_um2_E9.1"]) < 1e-3, f"{top[1] if top else None} um2")
    amu = {"area_um2": syn["area_um2"], "area_mm2": syn["area_um2"] * 1e-6, "sequential_um2": syn["sequential_um2"],
           "modules_um2": {short(k): v for k, v in mods.items()}, "flip_flops": syn["flip_flops"], "icg": syn["icg"],
           "energy_uJ": {}, "by_class_uJ": {}, "by_part_uJ": {}, "clock_root_net_not_included_uJ": {}, "enable_flip_flops": {}}
    for M in MODELS:
        info = s94["runs"][f"once:{M}"]["info"]
        amu["energy_uJ"][M] = s94["paper"][M]["amu_logic_uJ"]
        amu["by_class_uJ"][M] = info["energy_by_class_uJ"]
        amu["by_part_uJ"][M] = info["energy_by_part_uJ"]
        amu["clock_root_net_not_included_uJ"][M] = info["clock_root_net"]["E_uJ_not_included"]
        tot, by_t, n_t, by_p = cell_energy(f_inst[M], f_names, info["duration_ms"])
        typ = "sky130_fd_sc_hd__edfxtp_1"
        cyc_n = info["duration_ms"] * 1e6 / 10.0
        amu["enable_flip_flops"][M] = {"cells": n_t.get(typ, 0), "uJ": by_t.get(typ, 0.0),
                                       "share": by_t.get(typ, 0.0) / amu["energy_uJ"][M],
                                       "fJ_per_cell_and_cycle": by_t.get(typ, 0.0) * 1e9 / max(n_t.get(typ, 1), 1) / cyc_n,
                                       "in_U_CORE_uJ": by_p.get(("U_CORE", typ), 0.0)}
        check(f"model {M}: the instance report adds up to E9.4's energy", abs(tot - amu["energy_uJ"][M]) < 2e-3 * amu["energy_uJ"][M],
              f"{tot:.4f} / {amu['energy_uJ'][M]:.4f} uJ")
    out["amu"] = amu

    # ---- energy per inference ---------------------------------------------------------------------------------------
    energy = {}
    for M in MODELS:
        o = e10["energy"][M]
        A, b, Cx = o["A_uJ"], o["B_uJ"], o["C_uJ"]
        b_lo, b_hi = o["B_range_uJ"]
        dr = drom[M]
        d = dr["corrected_uJ"] + amu["energy_uJ"][M]
        d_lo, d_hi = (x + amu["energy_uJ"][M] for x in dr["range_uJ"])
        ac, ad = A + b + Cx, A + b + Cx + d
        e = {"A_uJ": A, "B_uJ": b, "B_parts_uJ": o["B_parts_uJ"], "B_range_uJ": [b_lo, b_hi], "C_uJ": Cx,
             "D_uJ": d, "D_range_uJ": [d_lo, d_hi], "D_rom_uJ": dr["corrected_uJ"], "D_rom_range_uJ": dr["range_uJ"],
             "amu_uJ": amu["energy_uJ"][M], "total_AC_uJ": ac, "total_AD_uJ": ad,
             "share_B_of_AC": b / ac, "share_BD_of_AD": (b + d) / ad, "share_D_of_AD": d / ad,
             "share_amu_of_D": amu["energy_uJ"][M] / d,
             "share_B_of_AC_range": [b_lo / (A + b_lo + Cx), b_hi / (A + b_hi + Cx)],
             "share_BD_of_AD_range": [(b_lo + d_lo) / (A + b_lo + Cx + d_lo), (b_hi + d_hi) / (A + b_hi + Cx + d_hi)],
             "per_mac_pJ": {"A-C": ac / macs * 1e6, "A-D": ad / macs * 1e6, "C": Cx / macs * 1e6},
             "E10.2b": {"D_uJ": o["D_uJ"], "D_rom_uJ": o["D_rom_uJ"], "amu_uJ": o["amu_uJ"], "total_AD_uJ": o["total_AD_uJ"],
                        "share_BD_of_AD": o["share_BD_of_AD"], "per_mac_AD_pJ": o["per_mac_pJ"]["A-D"]}}
        energy[M] = e
        check(f"model {M}: A-D = A + B + C + D_ROM + AMU",
              abs(ad - (A + b + Cx + dr["corrected_uJ"] + amu["energy_uJ"][M])) < 1e-12, f"{ad:.6f}")
        check(f"model {M}: A, B, C, and A-C as in E10.2b", abs(ac - o["total_AC_uJ"]) < 1e-12, f"{ac:.6f}")
    out["energy"] = energy
    out["energy_share_span_points"] = 100 * max(r[1] - r[0] for M in MODELS
                                                for r in (energy[M]["share_B_of_AC_range"], energy[M]["share_BD_of_AD_range"]))

    # ---- area -----------------------------------------------------------------------------------------------------
    ar = e10["area"]
    area = {"rom_mm2": out["rom"]["model_mm2"], "amu_mm2": amu["area_mm2"],
            "address_map_mm2": out["rom"]["model_mm2"] + amu["area_mm2"],
            "sram_mm2": ar["sram_mm2"], "banks_mm2": ar["banks_mm2"], "pool_logic_mm2": ar["pool_logic_mm2"],
            "bias_table_mm2": ar["bias_table_mm2"], "act_buffer_mm2": ar["act_buffer_mm2"], "crossbar_mm2": ar["crossbar_mm2"]}
    for M in MODELS:
        x = ar[M]
        fixed = x["digital_periphery_mm2"] + ar["act_buffer_mm2"] + ar["bias_table_mm2"] + area["address_map_mm2"]
        rng = [fixed + ar["sram_mm2"] + xb for xb in ar["crossbar_mm2"]]
        prot = area["address_map_mm2"] + ar["sram_mm2"]
        area[M] = {"digital_periphery_mm2": x["digital_periphery_mm2"], "fixed_mm2": fixed, "range_mm2": rng,
                   "protection_mm2": prot, "protection_share": [prot / v for v in rng],
                   "sram_over_map": ar["sram_mm2"] / area["address_map_mm2"],
                   "E10.2b": {"address_map_mm2": x["address_map_mm2"], "range_mm2": x["range_mm2"], "protection_mm2": x["protection_mm2"],
                              "protection_share": x["protection_share"]}}
    out["area"] = area

    # ---- Fig. 7: area against the budget (Model A), as E10.2b with the new map ---------------------------------------
    fa = area["A"]["fixed_mm2"]
    curve = []
    for c in e10["fig7"]["curve"]:
        curve.append(dict(c, total_banked_baseline_mm2=fa + ar["crossbar_mm2"][1] + c["sram_banked_mm2"],
                          total_banked_compact_mm2=fa + ar["crossbar_mm2"][0] + c["sram_banked_mm2"]))
    f7 = dict(e10["fig7"])
    f7["curve"] = curve
    f7["blocks_mm2"] = dict(f7["blocks_mm2"], address_map=area["address_map_mm2"])
    f7["as_built"] = dict(f7["as_built"], total_baseline_mm2=area["A"]["range_mm2"][1], total_compact_mm2=area["A"]["range_mm2"][0])
    out["fig7"] = f7

    # ---- Section VI-A: the ROM charged as library SRAM reads ------------------------------------------------------
    lib_read = 2 * e86["constants"]["e_analytical_pJ"][0]
    out["vi_a"] = {M: {"rom_reads": reads[M]["total"], "rom_by_library_uJ": reads[M]["total"] * lib_read * 1e-6,
                       "rom_reads_simulated_uJ": drom[M]["reads_uJ"], "d_rom_uJ": drom[M]["corrected_uJ"],
                       "lookup_over_library_read": lk[M]["mean_pJ"] / lib_read,
                       "banks_by_library_uJ": e10["vi_a"][M]["banks_by_library_uJ"],
                       "banks_post_layout_uJ": e10["vi_a"][M]["banks_post_layout_uJ"]} for M in MODELS}
    out["vi_a"]["library_read_4KB_pJ"] = lib_read

    # ---- Section VI-B: levers ----------------------------------------------------------------------------------------
    out["vi_b"] = {M: {"parking_reads": reads[M]["parking"],
                       "parking_read_energy_uJ_estimate": reads[M]["parking"] * out["lookup_read"]["pair_parking_read_pJ_mean"] * 1e-6,
                       "rest_after_parking_uJ": drom[M]["parts_uJ"]["parked"],
                       "enable_flip_flops_uJ": amu["enable_flip_flops"][M]["uJ"],
                       "information_bound_bits": tab[M]["information_bound_bits"],
                       "map_content_bits": tab[M]["map_bits_content"]} for M in MODELS}

    # ---- Section VI-C: ResNet-50 at a 50 % budget, the map in the encoding of E9 -----------------------------------
    vc = dict(e10["vi_c"])
    wr = e86["constants"]["resnet50_weights"][0]
    cnt_bits = math.ceil(math.log2(RESNET_LARGEST_LAYER + 1))
    entries = math.ceil(wr / LANES)
    bits = entries * (LANES + cnt_bits)
    vc.update({"e9_count_bits": cnt_bits, "e9_entries": entries, "e9_map_bits": bits,
               "e9_map_mm2": bits * out["rom"]["um2_per_stored_bit"] * 1e-6,
               "floor_over_lenet_AD_E9": vc["sram_energy_floor_uJ"] / energy["A"]["total_AD_uJ"]})
    out["vi_c"] = vc

    out["checks"] = checks
    out["all_checks_pass"] = all(c["ok"] for c in checks)
    os.makedirs(a.out, exist_ok=True)
    json.dump(out, open(os.path.join(a.out, "e9_5_summary.json"), "w"), indent=1)

    # ---- text summary -------------------------------------------------------------------------------------------------
    L = ["P2R-E9.5: energy and area with the address map of E9 (scripts/e9_5_recost.py)", ""]
    for k, v in out["inputs"].items():
        if "/runs/" not in k:
            L.append(f"   input {v}  {k}")
    L.append("   tools " + ", ".join(f"{k} {v}" for k, v in tools.items()))
    L.append("")
    wd = out["map"]["word"]
    L.append(f"map: one {wd['bits']}-bit word per entry ({wd['assignment_bits']} assignment bits, {wd['count_bits']}-bit count, "
             f"{wd['constant_bits']} constant), {tab['A']['entries']} entries = {tab['A']['map_bits_content']} bits of content; "
             f"flat tables {flat_bits} bits ({out['map']['flat_over_map']:.1f} x), per-lane tables {per_lane_bits} bits "
             f"({out['map']['per_lane_over_map']:.2f} x); information bound A {tab['A']['information_bound_bits']:.0f}, "
             f"B {tab['B']['information_bound_bits']:.0f} bits")
    L.append(f"ROM: {NM} macros of {wd['rows']} x {wd['words_per_row']} words x {wd['bits']} bit per model, {w0} x {h0} um = "
             f"{rom_um2 * 1e-6:.5f} mm2 each, {out['rom']['model_mm2']:.4f} mm2 per model ({out['rom']['um2_per_stored_bit']:.3f} um2 per bit); "
             f"zero cells A {min(tab['A']['zero_fraction']):.1%}-{max(tab['A']['zero_fraction']):.1%}, "
             f"B {min(tab['B']['zero_fraction']):.1%}-{max(tab['B']['zero_fraction']):.1%}")
    L.append("   smallest one-cell margin (V): " + "; ".join(f"{c} {v:.3f}" for c, v in out["rom"]["smallest_margin_all_V"].items())
             + f"; read time tt {out['rom']['t_access_ns_max']['tt:25:1.80']:.2f} ns, fs 25 C {out['rom']['t_access_ns_max']['fs:25:1.80']:.2f} ns, "
             f"1.60 V {out['rom']['t_access_ns_max']['tt:25:1.60']:.2f} ns")
    if out["rom"]["neighbour_V"]:
        L.append(f"   a one cell's bit line per discharging neighbour {1e3 * out['rom']['neighbour_V'][0]:.0f} to "
                 f"{1e3 * out['rom']['neighbour_V'][1]:.0f} mV, per row {1e3 * out['rom']['per_row_V'][0]:.2f} to {1e3 * out['rom']['per_row_V'][1]:.2f} mV")
    for M in MODELS:
        r = reads[M]
        L.append(f"reads {M}: {r['lookups']} lookups + {r['parking']} parking = {r['total']} per inference ({r['steps']} steps); "
                 f"per macro " + ", ".join(f"{x['lookups']}+{x['parking']}" for x in r["per_macro"])
                 + f"; address bus {r['bus']['changes']} changes, {r['bus']['rising_bits']} / {r['bus']['falling_bits']} bits up / down")
    L.append("")
    lm = out["d_rom"]["lookup_model"]
    L.append(f"lookup model on {lm['lookups']} lookups: " + ", ".join(f"{c:.4f}" for c in coef)
             + f"; leaving each macro out: mean {100 * eL:+.2f} %, SD {100 * sdL:.2f} %, SE {100 * seL:.2f} % ("
             + ", ".join(f"{k} {100 * v['error']:+.1f}" for k, v in lomo.items()) + ")")
    for M in MODELS:
        x = lopo[M]
        L.append(f"pair fit {M} ({x['form']}, {x['pairs']} pairs): leaving each out: mean {100 * x['mean']:+.2f} %, SE {100 * x['se']:.2f} %")
    for M in MODELS:
        d = drom[M]
        L.append(f"D_ROM {M}: {d['corrected_uJ']:.5f} uJ (range {d['range_uJ'][0]:.5f}-{d['range_uJ'][1]:.5f}; before the correction "
                 f"{d['uJ']:.5f}; E9.3c main {d['E9.3c_main_uJ']:.5f}); reads {100 * d['reads_share']:.1f} %, static "
                 f"{100 * d['static_share']:.1f} % ({100 * d['unread_share_of_static']:.0f} % of it unread), address changes "
                 f"{100 * d['address_changes_share']:.2f} %; pins not included {1e3 * d['pins_not_included_uJ']:.3f} nJ")
        for k, v in d["corrected_parts_uJ"].items():
            L.append(f"      {k:56s} {v:.5f}")
    for k, v in rest.items():
        L.append(f"rest {k}: unread {v['unread_uW']:.4f} uW; after parking first us {v['first_us_uW']:.3f}, 1.1-2.1 us {v['1.1-2.1us_uW']:.3f}, "
                 f"9.1-10.1 us {v['9.1-10.1us_uW']:.4f}, 10.1-11.1 us {v['10.1-11.1us_uW']:.4f} ({100 * v['10.1-11.1us_over_settled']:+.1f} %), "
                 f"20-100 us {v['20-100us_uW']:.4f} ({100 * v['20-100us_over_settled']:+.2f} %), settled {v['settled_uW']:.4f} "
                 f"(x{v['settled_over_unread']:.4f} the unread level)")
    for M in MODELS:
        x = lk[M]
        L.append(f"lookup read {M}: mean {x['mean_pJ']:.2f} pJ over its cycle ({x['min_pJ']:.1f}-{x['max_pJ']:.1f}), "
                 f"{x['zero_bits_per_word_mean']:.2f} zero bits per word; {out['vi_a'][M]['lookup_over_library_read']:.2f} x the library read "
                 f"of the 4-KB SRAM ({lib_read:.2f} pJ)")
    L.append(f"   simulated lookups {out['lookup_read']['simulated_lookups_E9_pJ'][0]:.1f}-{out['lookup_read']['simulated_lookups_E9_pJ'][2]:.1f} pJ; "
             f"static at the end of the 90-ns low {out['lookup_read']['static_end_of_low_uW'][0]:.1f}-{out['lookup_read']['static_end_of_low_uW'][2]:.1f} uW "
             f"(median {out['lookup_read']['static_end_of_low_uW'][1]:.1f}); a parking read of a pair {out['lookup_read']['pair_parking_read_pJ_mean']:.2f} pJ")
    L.append("")
    L.append(f"AMU: {amu['area_um2']:.2f} um2 (" + ", ".join(f"{k} {v:.0f}" for k, v in amu["modules_um2"].items())
             + f"), {amu['flip_flops']} flip-flops, {amu['icg']} ICG")
    for M in MODELS:
        ef = amu["enable_flip_flops"][M]
        L.append(f"   {M}: {amu['energy_uJ'][M]:.4f} uJ; {ef['cells']} enable flip-flops {ef['uJ']:.4f} uJ ({100 * ef['share']:.1f} %, "
                 f"{ef['fJ_per_cell_and_cycle']:.1f} fJ each per cycle); clock root net not included {amu['clock_root_net_not_included_uJ'][M]:.4f} uJ")
    L.append("")
    for M in MODELS:
        e = energy[M]
        L.append(f"model {M}: A {e['A_uJ']:.3f}  B {e['B_uJ']:.3f} ({e['B_range_uJ'][0]:.3f}-{e['B_range_uJ'][1]:.3f})  C {e['C_uJ']:.3f}  "
                 f"D {e['D_uJ']:.4f} ({e['D_range_uJ'][0]:.4f}-{e['D_range_uJ'][1]:.4f}) = D_ROM {e['D_rom_uJ']:.4f} + AMU {e['amu_uJ']:.4f}")
        L.append(f"   A-C {e['total_AC_uJ']:.3f}, A-D {e['total_AD_uJ']:.3f} uJ; B/(A-C) {100 * e['share_B_of_AC']:.2f} %; (B+D)/(A-D) "
                 f"{100 * e['share_BD_of_AD']:.2f} % ({100 * e['share_BD_of_AD_range'][0]:.2f}-{100 * e['share_BD_of_AD_range'][1]:.2f}); "
                 f"AMU {100 * e['share_amu_of_D']:.1f} % of D; per MAC A-D {e['per_mac_pJ']['A-D']:.2f} pJ, A-C {e['per_mac_pJ']['A-C']:.2f} pJ")
        L.append(f"   E10.2b (map of E8): D {e['E10.2b']['D_uJ']:.3f}, A-D {e['E10.2b']['total_AD_uJ']:.3f}, (B+D)/(A-D) "
                 f"{100 * e['E10.2b']['share_BD_of_AD']:.2f} %")
    L.append(f"   largest span of a model's protection share over the ranges: {out['energy_share_span_points']:.2f} points")
    for M in MODELS:
        x = area[M]
        L.append(f"area {M}: map {area['address_map_mm2']:.4f} (ROM {area['rom_mm2']:.4f} + AMU {area['amu_mm2']:.4f}), fixed "
                 f"{x['fixed_mm2']:.4f}, SRAM {area['sram_mm2']:.4f}, total {x['range_mm2'][0]:.3f}-{x['range_mm2'][1]:.3f} mm2; protection "
                 f"{x['protection_mm2']:.3f} mm2 = {100 * x['protection_share'][0]:.1f} / {100 * x['protection_share'][1]:.1f} %; SRAM / map "
                 f"{x['sram_over_map']:.2f} (E10.2b: total {x['E10.2b']['range_mm2'][0]:.3f}-{x['E10.2b']['range_mm2'][1]:.3f})")
    L.append(f"fig7: baseline total {curve[1]['total_banked_baseline_mm2']:.3f} mm2 at 1 %, {curve[50]['total_banked_baseline_mm2']:.3f} at 50 %")
    for M in MODELS:
        v = out["vi_a"][M]
        L.append(f"VI-A {M}: {v['rom_reads']} ROM reads as library SRAM reads {v['rom_by_library_uJ']:.4f} uJ, simulated reads "
                 f"{v['rom_reads_simulated_uJ']:.4f}, D_ROM {v['d_rom_uJ']:.4f} uJ; banks by library {v['banks_by_library_uJ']:.3f} "
                 f"against {v['banks_post_layout_uJ']:.3f}")
        w = out["vi_b"][M]
        L.append(f"VI-B {M}: {w['parking_reads']} parking reads about {1e3 * w['parking_read_energy_uJ_estimate']:.2f} nJ, rest after parking "
                 f"{1e3 * w['rest_after_parking_uJ']:.2f} nJ; enable flip-flops {w['enable_flip_flops_uJ']:.3f} uJ; map {w['map_content_bits']} bits, "
                 f"bound {w['information_bound_bits']:.0f}")
    L.append(f"VI-C: map of ResNet-50 {entries} entries x ({LANES} + {cnt_bits}) bits = {bits / 1e6:.2f} Mbit, {vc['e9_map_mm2']:.1f} mm2; "
             f"SRAM floor {vc['sram_energy_floor_uJ']:.1f} uJ = {vc['floor_over_lenet_AD_E9']:.2f} x the LeNet-5 A-D")
    L.append("")
    for c in checks:
        L.append(f"   {'PASS' if c['ok'] else 'FAIL'}  {c['check']}: {c['detail']}")
    L.append("ALL CHECKS PASS" if out["all_checks_pass"] else "NOT ALL CHECKS PASS")
    open(os.path.join(a.out, "e9_5_summary.txt"), "w").write("\n".join(L) + "\n")
    print("\n".join(L))
    return 0 if out["all_checks_pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
