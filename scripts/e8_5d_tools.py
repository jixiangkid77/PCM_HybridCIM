#!/usr/bin/env python3
"""
e8_5d_tools.py   (P2R-E8.5d: the parked current of the macros without a word of 0xFFFF)

Background (claude/p2r-e8-5d-sandbox.md): after a read of a word with zero bits and the clock held low, the
output-buffer input of every zero bit floats (one NMOS per column in the column multiplexer, all off) and the
buffer draws current. D_ROM (E8.6a-3) counts this as a constant power over the whole parked time (about
6 ms per inference for the three macros without a word of 0xFFFF). In the sandbox the current decays to the
leakage level within about 1-2 ms. This step measures it on the real macros.

Commands
  prep     --paper2 P
           1. finds the macros without a word of 0xFFFF in the 200 macros of each model (r48: 4 macros of
              624 words per table, data/rtl_inputs_<M>_v3 through scripts/e8_6a2_rom_energy.py); they must
              be A_pcm_l04 k1, A_pcm_l18 k1, B_pcm_l00 k1 (E8.6a-3)
           2. for each: Z (as e8_4b_energy_tools.py plan: most zero bits, then most zero cells in the row,
              then the lowest row and word), the current parking word (rtl/e8/amu_park_<M>.vh), and three
              candidates: the lowest static power of the per-bit model of E8.4b-rel5 (PCM side;
              reports/e8_rom/e8_4b_rel5/model.json), ties by zero bits, row, word; the current word excluded
           3. writes reports/e8_rom/e8_5d/tables/: <table>.bin of the tables whose macros E8.5d generates
              (big-endian 16-bit words, as E8.4a-11), selected.txt, selected_macros.txt; and
              reports/e8_rom/e8_5d/candidates.json. The tables are compared with the export of E8.4a-8
              (reports/e8_rom/e8_4a8/export_cells_tables.json.gz) when it is present
  verify   --paper2 P [--macros NAME...]
           for the macros of candidates.json (default all): V1 the data file of the macro
           (reports/e8_rom/<macro_from>/bins/<macro>.bin) equals its part of the table (data/, big-endian
           16-bit words); V2 the extracted netlist is there and its extraction log reports no errors; V3 LVS
           "match uniquely" (<macro>/lvs/netgen.log); V4 Z, the current word and the candidates hold the values
           of candidates.json at their addresses. Exit 1 if any check fails
  addprobes --deck TB.SP --top NAME
           adds the 16 output-buffer inputs (<top>_rom_output_buffer_0__in_0..15) to the saved vectors and
           writes them with every checkpoint to tb_buf.txt (the bench's deck, after it is written)
  analyze  --paper2 P --runs DIR... [--margin 0.10] [--out J]
           every run directory: info.json (written by the run script: macro, word, role, condition), the
           bench's result.json (reads, margins), tb_out.txt, tb_buf.txt (the 16 output-buffer inputs,
           sampled from 1 us to 3 ms into the wait). References of the run's condition: the switching
           level of the bitline inverter (vm.txt of reports/e8_rom/e8_5d, e8_4a7 or the E8.4e folders
           e8_4b_c_*) and the leakage reference (the mean parked power of the PCM-side part A macros of the
           E8.4b model at that condition: e8_4b_rel5 at tt 25 C, else the E8.4e folder of the condition; the
           macros of candidates.json left out). Per run: P1 complete, reads correct with the right selection,
           margins >= 0.10 V where the switching level is known; the parked power against time: the energy
           from the start of the clock-low wait E(t) on a grid, P_start (first us), P_end (mean of the last
           100 us); A1 (information) the integral equals the bench's energy of the wait within 1 %.
           E(T) beyond the simulated wait: E(t_end) + P_end x (T - t_end) if P_end <= 2 x the leakage
           reference ("settled"); else the leakage reference x (T - t_end) plus an exponential tail fitted on
           the excess over the leakage reference in the last third of the wait (flagged); with no reference,
           P_end x (T - t_end) (flagged)
  drom     --paper2 P --park J [--events-dir D] [--cond-macro NAME] [--out J]
           D_ROM again (E8.6a-3's computation, imported, not changed), with the parked intervals of the
           zero-parked macros taken from the measured curves (tt 25 C, current parking words; runs that pass
           P1) instead of a constant power. Checks: D1 with the constant power put back, the copy of the
           replay gives E8.6a-3's energies and d_rom.json's D (relative difference < 1e-9); D1b the corrected
           value recomputed as E8.6a-3 (per side D / (1 + mean model error of the trains)) equals d_rom.json's;
           D2 every zero-parked macro has a measured curve; D3 the zero-parked macros and their parking words
           (row and value) are those of candidates.json. The new corrected value divides only the modelled
           part by (1 + mean error); the measured parked energy is added as it is.
           P3 (word-change rule, written before the run): for each zero-parked macro, the candidate with the
           lowest D_ROM among those whose run passes P1; change the parking word only if that candidate's
           parked energy over 6.08 ms is <= 50 % of the current word's AND the model's D_ROM falls by
           >= 0.05 uJ. Conditions: for each condition run of the current word of --cond-macro (default
           A_pcm_l04 k1), the ratio of its parked energy over 6.08 ms to the tt 25 C run's, and the
           zero-parked energy of each model at that condition (tt 25 C measured value x that ratio)
"""
import argparse
import bisect
import copy
import glob
import gzip
import hashlib
import importlib.util
import json
import math
import os
import re
import sys
import time

ROWS, WPR, TW = 48, 13, 2496
PER = ROWS * WPR
EXPECTED = {"A": [("pcm", 4, 1), ("pcm", 18, 1)], "B": [("pcm", 0, 1)]}
N_CAND = 3
T_RULE = 6.08e-3          # s: the parked interval of the rule (about the parked time per inference, E8.6a-3)
TT = "tt:25:1.80"


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def zbits(w):
    return 16 - bin(w & 0xFFFF).count("1")


def tname(M, side, lane):
    return f"e8rom_{M}_{side}_l{lane:02d}_16x{TW}"


def mname(M, side, lane, k):
    return f"{tname(M, side, lane)}_r{ROWS}k{k}"


def read_park_vh(path):
    out = {}
    for ln in open(path):
        m = re.match(r"\s*(\d+):\s*amu_park\s*=\s*10'd(\d+);", ln)
        if m:
            out[int(m.group(1))] = int(m.group(2))
    return out


def per_bit_power(model, w):
    """E8.6a-2 SideModel 'bits' static power of word w (uW): index b of per_bit_uW is bit 15 - b"""
    sb = model["models"]["pcm"]["static_bits"]
    return sb["P0_uW"] + sum(sb["per_bit_uW"][b] for b in range(16) if not (w >> (15 - b)) & 1)


# ---------------------------------------------------------------- prep
def cmd_prep(a):
    root = os.path.join(a.paper2, "reports", "e8_rom")
    E = load_module(os.path.join(a.paper2, "scripts", "e8_6a2_rom_energy.py"), "e8_6a2_rom_energy")
    mj = os.path.join(root, "e8_4b_rel5", "model.json")
    model = json.load(open(mj))
    out_dir = os.path.join(root, "e8_5d")
    tdir = os.path.join(out_dir, "tables")
    os.makedirs(tdir, exist_ok=True)
    print(f"P2R-E8.5d prep  {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"   script     : {md5(os.path.abspath(__file__))}  {os.path.abspath(__file__)}")
    print(f"   E8.4b model: {md5(mj)}  {mj}")
    exp = None
    ep = os.path.join(root, "e8_4a8", "export_cells_tables.json.gz")
    if os.path.isfile(ep):
        exp = json.load(gzip.open(ep))["tables"]
        print(f"   export     : {md5(ep)}  {ep}")
    else:
        print(f"   export     : not found ({ep}); the tables are not compared with it")
    cands, gen_tables, gen_macros, bad = {}, [], [], 0
    for M in ("A", "B"):
        vh = os.path.join(a.paper2, "rtl", "e8", f"amu_park_{M}.vh")
        park = read_park_vh(vh)
        print(f"   parking words model {M}: {md5(vh)}  {vh} ({len(park)} macros)")
        found = []
        for si, side in enumerate(("sram", "pcm")):
            for lane in range(E.K):
                words = E.table_words(a.paper2, M, side, lane, TW)
                if exp is not None and "".join(f"{x:04x}" for x in words) != exp[tname(M, side, lane)]:
                    sys.exit(f"{tname(M, side, lane)}: data/ differs from the E8.4a-8 export")
                for k in range(len(words) // PER):
                    wk = words[k * PER:(k + 1) * PER]
                    if all(x != E.MISS for x in wk):
                        found.append((side, lane, k, wk, park.get(si * 100 + lane * 4 + k)))
        keys = [(s, l, k) for s, l, k, _, _ in found]
        ok = keys == EXPECTED[M]
        print(f"   model {M}: macros without a word of 0xFFFF: {', '.join(f'{s}_l{l:02d} k{k}' for s, l, k in keys)} "
              f"({'as E8.6a-3' if ok else 'DIFFERENT FROM E8.6a-3'})")
        if not ok:
            bad += 1
            continue
        for side, lane, k, wk, paddr in found:
            n = mname(M, side, lane, k)
            zr = [sum(zbits(x) for x in wk[r * WPR:(r + 1) * WPR]) for r in range(ROWS)]
            cand = [(r, w) for r in range(ROWS) for w in range(WPR)]
            z = {rw: zbits(wk[rw[0] * WPR + rw[1]]) for rw in cand}
            Z = max(cand, key=lambda rw: (z[rw], zr[rw[0]], -rw[0], -rw[1]))     # as e8_4b_energy_tools.py plan
            if paddr is None:
                sys.exit(f"{n}: no parking word in {vh}")
            cur = (paddr >> 4, paddr & 15)

            def rec(rw, role):
                v = wk[rw[0] * WPR + rw[1]]
                return {"role": role, "addr": (rw[0] << 4) | rw[1], "row": rw[0], "word": rw[1], "value": f"{v:04x}",
                        "z": zbits(v), "z_row": zr[rw[0]], "model_uW": round(per_bit_power(model, v), 3)}
            rank = sorted((rw for rw in cand if rw != cur),
                          key=lambda rw: (per_bit_power(model, wk[rw[0] * WPR + rw[1]]), z[rw], rw))
            words = [rec(cur, "current")] + [rec(rw, f"candidate {i + 1}") for i, rw in enumerate(rank[:N_CAND])]
            src = "e8_4a7" if (M, side, lane) == ("B", "pcm", 0) else "e8_5d"
            cands[n] = {"model": M, "side": side, "lane": lane, "k": k, "macro_from": src, "Z": rec(Z, "Z"), "words": words}
            print(f"      {n} (macro from {src}): Z {rec(Z, 'Z')['value']} (row {Z[0]} word {Z[1]}, {z[Z]} zero bits)")
            for x in words:
                print(f"         {x['role']:<12} addr {x['addr']:4d} row {x['row']:2d} word {x['word']:2d} = {x['value']}  "
                      f"{x['z']} zero bits, {x['z_row']} zero cells in the row, model {x['model_uW']:7.1f} uW")
            if src == "e8_5d":
                t = tname(M, side, lane)
                if t not in gen_tables:
                    gen_tables.append(t)
                    full = E.table_words(a.paper2, M, side, lane, TW)
                    with open(os.path.join(tdir, f"{t}.bin"), "wb") as fh:
                        fh.write(bytes(b for x in full for b in ((x >> 8) & 0xFF, x & 0xFF)))
                gen_macros.append(n)
    if bad:
        sys.exit("the macros without a word of 0xFFFF are not those of E8.6a-3: nothing written")
    with open(os.path.join(tdir, "selected.txt"), "w") as fh:
        fh.write(" ".join(gen_tables) + "\n")
    with open(os.path.join(tdir, "selected_macros.txt"), "w") as fh:
        fh.write("\n".join(gen_macros) + "\n")
    cj = os.path.join(out_dir, "candidates.json")
    json.dump({"created": time.strftime("%Y-%m-%d %H:%M:%S"), "script_md5": md5(os.path.abspath(__file__)),
               "model_json_md5": md5(mj), "macros": cands}, open(cj, "w"), indent=1)
    for t in gen_tables:
        print(f"   written {os.path.join(tdir, t + '.bin')}  md5 {md5(os.path.join(tdir, t + '.bin'))}")
    print(f"   written {tdir}/selected.txt ({len(gen_tables)} tables), selected_macros.txt ({len(gen_macros)} macros)")
    print(f"   written {cj}  md5 {md5(cj)}")
    return 0


# ---------------------------------------------------------------- verify
def cmd_verify(a):
    root = os.path.join(a.paper2, "reports", "e8_rom")
    E = load_module(os.path.join(a.paper2, "scripts", "e8_6a2_rom_energy.py"), "e8_6a2_rom_energy")
    cj = os.path.join(root, "e8_5d", "candidates.json")
    cand = json.load(open(cj))["macros"]
    names = a.macros or list(cand)
    nfail = 0
    print(f"P2R-E8.5d verify  {time.strftime('%Y-%m-%d %H:%M:%S')}   candidates.json {md5(cj)}")
    for n in names:
        if n not in cand:
            print(f"  FAIL  {n}: not in {cj}")
            nfail += 1
            continue
        m = cand[n]
        src = os.path.join(root, m["macro_from"])
        words = E.table_words(a.paper2, m["model"], m["side"], m["lane"], TW)[m["k"] * PER:(m["k"] + 1) * PER]
        want = bytes(b for x in words for b in ((x >> 8) & 0xFF, x & 0xFF))
        b = os.path.join(src, "bins", f"{n}.bin")
        sp = os.path.join(src, n, "extract", f"{n}.flat_pex.spice")
        xl = os.path.join(src, n, "extract", "magic_extract.log")
        lv = os.path.join(src, n, "lvs", "netgen.log")
        msg = []
        if not os.path.isfile(b):
            msg.append(f"V1 no data file {b}")
        elif open(b, "rb").read() != want:
            msg.append(f"V1 {b} differs from the table")
        if not (os.path.isfile(sp) and os.path.getsize(sp) > 0):
            msg.append(f"V2 no extracted netlist {sp}")
        elif os.path.isfile(xl) and re.search(r"Total of \d+ errors", open(xl, errors="replace").read()):
            msg.append(f"V2 extraction errors in {xl}")
        if not (os.path.isfile(lv) and "match uniquely" in open(lv, errors="replace").read()):
            msg.append(f"V3 no 'match uniquely' in {lv}")
        for w in [m["Z"]] + m["words"]:
            v = words[w["row"] * WPR + w["word"]]
            if v != int(w["value"], 16) or w["addr"] != (w["row"] << 4 | w["word"]):
                msg.append(f"V4 {w['role']} at row {w['row']} word {w['word']} holds {v:04x}, not {w['value']}")
        if msg:
            nfail += 1
            for x in msg:
                print(f"  FAIL  {n}: {x}")
        else:
            print(f"  PASS  {n} (from {m['macro_from']}): data = table, extracted, LVS matched, "
                  f"{1 + len(m['words'])} words as candidates.json")
    print("ALL CHECKS PASS" if nfail == 0 else f"{nfail} MACRO(S) FAILED")
    return 0 if nfail == 0 else 1


# ---------------------------------------------------------------- addprobes
def cmd_addprobes(a):
    s = open(a.deck).read().split("\n")
    buf = "".join(f" v(xrom.{a.top}_rom_output_buffer_0__in_{b})" for b in range(16))
    out, nsave, nwr = [], 0, 0
    for ln in s:
        if ln.startswith("save ") and nsave == 0:
            ln = ln + buf
            nsave += 1
        out.append(ln)
        if ln.strip() == "shell mv -f tb_out.part tb_out.txt":
            ind = ln[:len(ln) - len(ln.lstrip())]
            out.append(f"{ind}wrdata tb_buf.part{buf}")
            out.append(f"{ind}shell mv -f tb_buf.part tb_buf.txt")
            nwr += 1
    if nsave != 1 or nwr < 2:
        sys.exit(f"{a.deck}: save lines {nsave}, checkpoint writes {nwr}: deck layout not as expected")
    open(a.deck, "w").write("\n".join(out))
    net = open(os.path.join(os.path.dirname(a.deck), "netlist.sp")).read()
    miss = [b for b in range(16) if f"{a.top}_rom_output_buffer_0__in_{b} " not in net and
            f"{a.top}_rom_output_buffer_0__in_{b}\n" not in net]
    if miss:
        sys.exit(f"output-buffer inputs not in the netlist: {miss}")
    print(f"probes: 16 output-buffer inputs added to {a.deck} ({nwr} checkpoint writes)")
    return 0


# ---------------------------------------------------------------- analyze
def load_cols(path):
    with open(path) as fh:
        hdr = fh.readline().split()
        cols = [[] for _ in hdr]
        for ln in fh:
            f = ln.split()
            if len(f) != len(hdr):
                continue
            for i, x in enumerate(f):
                cols[i].append(float(x))
    return hdr, cols


class Curve:
    def __init__(self, t, P):
        self.t, self.P = t, P
        self.cum = [0.0]
        for i in range(1, len(t)):
            self.cum.append(self.cum[-1] + (t[i] - t[i - 1]) * (P[i] + P[i - 1]) / 2)

    def p_at(self, x):
        t, P = self.t, self.P
        i = bisect.bisect_left(t, x)
        if i <= 0:
            return P[0]
        if i >= len(t):
            return P[-1]
        return P[i - 1] + (P[i] - P[i - 1]) * (x - t[i - 1]) / (t[i] - t[i - 1]) if t[i] > t[i - 1] else P[i]

    def e_to(self, x):
        """energy (J) from t[0] to x"""
        t = self.t
        i = bisect.bisect_right(t, x) - 1
        if i < 0:
            return 0.0
        if i >= len(t) - 1:
            return self.cum[-1]
        return self.cum[i] + (x - t[i]) * (self.P[i] + self.p_at(x)) / 2


def cond_refs(paper2, cond, exclude):
    """switching level of the bitline inverter and leakage reference (uW) at a condition 'corner:temp:vdd'"""
    root = os.path.join(paper2, "reports", "e8_rom")
    vm = vsrc = None
    for f in ([os.path.join(root, "e8_5d", "vm", "vm.txt"), os.path.join(root, "e8_4a7", "vm", "vm.txt")]
              + sorted(glob.glob(os.path.join(root, "e8_4b_c_*", "vm", "vm.txt")))):
        if vm is not None or not os.path.isfile(f):
            continue
        for ln in open(f):
            p = ln.split()
            if len(p) >= 2 and p[0] == cond:
                try:
                    vm, vsrc = float(p[1]), f
                except ValueError:
                    pass
                break
    mj = None
    if cond == TT:
        mj = os.path.join(root, "e8_4b_rel5", "model.json")
    else:
        for f in sorted(glob.glob(os.path.join(root, "e8_4b_c_*", "condition.txt"))):
            c = open(f).read().split()
            if c and c[0] == cond:
                mj = os.path.join(os.path.dirname(f), "model.json")
    leak, nl = None, 0
    if mj and os.path.isfile(mj):
        v = [p["leak_mean_uW"] for p in json.load(open(mj)).get("parta", []) if p.get("side") == "pcm"
             and p.get("leak_mean_uW") is not None and p.get("macro") not in exclude]
        if v:
            leak, nl = sum(v) / len(v), len(v)
    else:
        mj = None
    return {"vm_V": vm, "vm_from": vsrc, "leak_uW": leak, "leak_from": mj, "leak_macros": nl}


def analyze_run(d, refs, margin):
    info = json.load(open(os.path.join(d, "info.json")))
    out = {"dir": d, "info": info, "refs": refs, "complete": False, "t_wait_s": None, "p1": False, "settled": False,
           "tail": None, "leak_ref_uW": refs["leak_uW"], "reads": [], "reads_ok": False}
    try:
        meta = json.load(open(os.path.join(d, "tb_meta.json")))
        hdr, cols = load_cols(os.path.join(d, "tb_out.txt"))
    except (OSError, ValueError) as e:
        out["error"] = str(e)
        return out
    res = json.load(open(os.path.join(d, "result.json"))) if os.path.exists(os.path.join(d, "result.json")) else None
    vdd = float(meta.get("vdd", 1.8))
    t = cols[0]
    P = [-x * vdd for x in cols[hdr.index("i(vvdd)")]]
    waits = [c for c in meta["cycles"] if c.get("kind") == "wait"]
    if not waits or not t:
        return out
    t0 = waits[-1]["t0"]
    t_end = min(t[-1], t0 + waits[-1]["len"])
    i0 = bisect.bisect_left(t, t0)
    c = Curve(t[i0:], P[i0:]) if len(t) - i0 > 2 else None
    if c is None or t_end <= t0:
        return out
    out["complete"] = t[-1] >= t0 + waits[-1]["len"] - 1e-9 and not (res or {}).get("summary", {}).get("failed")
    out["t_wait_s"] = t_end - t0
    grid = [x * 1e-6 for x in (1, 2, 5, 10, 20, 50, 100, 200, 300, 500, 700, 1000, 1500, 2000, 2500, 3000, 4000, 5000, 6000)]
    E = [(g, c.e_to(t0 + g)) for g in grid if t0 + g <= t_end]
    if not E or E[-1][0] < t_end - t0:
        E.append((t_end - t0, c.e_to(t_end)))
    out["E_curve"] = [[g, e] for g, e in E]
    w = min(100e-6, 0.1 * (t_end - t0))
    out["P_start_uW"] = (c.e_to(t0 + 1e-6) / 1e-6) * 1e6 if t_end - t0 >= 1e-6 else None
    out["P_end_uW"] = (c.e_to(t_end) - c.e_to(t_end - w)) / w * 1e6
    out["E_end_J"] = c.e_to(t_end)
    out["P_at_uW"] = {f"{x:g}": (c.e_to(t0 + x * 1e-6 + 0.02 * x * 1e-6) - c.e_to(t0 + x * 1e-6 - 0.02 * x * 1e-6))
                      / (0.04 * x * 1e-6) * 1e6 for x in (10, 100, 200, 500, 1000, 1500, 2000, 2500)
                      if t0 + 1.02 * x * 1e-6 <= t_end}
    bf = os.path.join(d, "tb_buf.txt")
    if os.path.isfile(bf):          # the 16 output-buffer inputs (in_0 .. in_15 = bit 15 .. bit 0 of the word)
        bh, bc = load_cols(bf)
        tb = bc[0]

        def vat(col, x):
            i = bisect.bisect_left(tb, x)
            if i <= 0:
                return col[0]
            if i >= len(tb):
                return col[-1]
            return col[i - 1] + (col[i] - col[i - 1]) * (x - tb[i - 1]) / (tb[i] - tb[i - 1]) if tb[i] > tb[i - 1] else col[i]
        out["nodes_V"] = {f"{x:g}": [round(vat(bc[j], t0 + x * 1e-6), 4) for j in range(1, len(bh))]
                          for x in (1, 10, 100, 500, 1000, 2000, 3000) if tb and t0 + x * 1e-6 <= tb[-1]}
    leak = refs["leak_uW"]
    out["settled"] = leak is not None and out["P_end_uW"] <= 2 * leak
    if leak is not None and not out["settled"]:
        # exponential tail: the excess over the leakage reference in 8 windows of the last third of the wait
        a_, b_ = t0 + 2 * (t_end - t0) / 3, t_end
        pts = []
        for j in range(8):
            x0, x1 = a_ + (b_ - a_) * j / 8, a_ + (b_ - a_) * (j + 1) / 8
            p = (c.e_to(x1) - c.e_to(x0)) / (x1 - x0) * 1e6 - leak
            if p > 0:
                pts.append(((x0 + x1) / 2 - t0, math.log(p)))
        if len(pts) >= 4:
            mx = sum(x for x, _ in pts) / len(pts)
            my = sum(y for _, y in pts) / len(pts)
            sxx = sum((x - mx) ** 2 for x, _ in pts)
            slope = sum((x - mx) * (y - my) for x, y in pts) / sxx if sxx else 0.0
            if slope < 0:
                out["tail"] = {"tau_s": -1.0 / slope, "excess_end_uW": out["P_end_uW"] - leak, "points": len(pts)}
    rd = []
    if res:
        for cyc in res.get("cycles", []):
            if cyc.get("kind") == "read":
                rd.append({"addr": cyc.get("addr"), "complete": cyc.get("complete"), "ok": cyc.get("ok"),
                           "sel_ok": cyc.get("selection_ok"), "bl1_min": cyc.get("bl1_min_V"),
                           "bl0_max": cyc.get("bl0_max_V"), "E_pJ": cyc.get("E_vdd_pJ"),
                           "P_after_uW": cyc.get("P_after_uW"), "zeros": cyc.get("zeros_in_word")})
            elif cyc.get("kind") == "wait":
                out["bench_wait_pJ"] = cyc.get("E_vdd_pJ")
    out["reads"] = rd
    vm = refs["vm_V"]
    m1 = [r["bl1_min"] - vm for r in rd if r.get("bl1_min") is not None and vm is not None]
    m0 = [vm - r["bl0_max"] for r in rd if r.get("bl0_max") is not None and vm is not None]
    out["reads_ok"] = (len(rd) == 2 and all(r.get("ok") for r in rd) and all(r.get("sel_ok") for r in rd)
                       and [r["addr"] for r in rd] == [info["z_addr"], info["addr"]])
    out["margin_one_V"] = min(m1) if m1 else None
    out["margin_zero_V"] = min(m0) if m0 else None
    out["margin_ok"] = None if vm is None else bool(m1 and m0 and min(m1) >= margin and min(m0) >= margin)
    out["p1"] = bool(out["complete"] and out["reads_ok"] and out["margin_ok"] is not False)
    bw = out.get("bench_wait_pJ")
    out["a1_rel"] = (out["E_end_J"] * 1e12 - bw) / bw if bw and out["complete"] else None
    return out


def e_parked(run, T):
    """energy (J) of a parked interval of length T (s) after the parking read, from a run of analyze"""
    curve = run["E_curve"]
    tw = run["t_wait_s"]
    if T <= tw:
        xs = [0.0] + [g for g, _ in curve]
        ys = [0.0] + [e for _, e in curve]
        i = bisect.bisect_left(xs, T)
        if i >= len(xs):
            return ys[-1]
        if i == 0:
            return 0.0
        return ys[i - 1] + (ys[i] - ys[i - 1]) * (T - xs[i - 1]) / (xs[i] - xs[i - 1])
    extra = T - tw
    if run["settled"] or run["tail"] is None:
        return run["E_end_J"] + run["P_end_uW"] * 1e-6 * extra
    tau = run["tail"]["tau_s"]
    ex = run["tail"]["excess_end_uW"] * 1e-6
    leak = run["leak_ref_uW"] * 1e-6
    return run["E_end_J"] + leak * extra + ex * tau * (1 - math.exp(-extra / tau))


def extension(run):
    if run["settled"]:
        return "settled"
    if run["tail"]:
        return f"tail tau {run['tail']['tau_s'] * 1e3:.2f} ms"
    return "NOT SETTLED, linear" if run["leak_ref_uW"] is not None else "no leakage reference, linear"


def cmd_analyze(a):
    cj = os.path.join(a.paper2, "reports", "e8_rom", "e8_5d", "candidates.json")
    exclude = set(json.load(open(cj))["macros"]) if os.path.isfile(cj) else set()
    print(f"P2R-E8.5d parked current  {time.strftime('%Y-%m-%d %H:%M:%S')}   script {md5(os.path.abspath(__file__))}")
    refs, runs = {}, []
    for d in a.runs:
        try:
            info = json.load(open(os.path.join(d, "info.json")))
        except (OSError, ValueError):
            print(f"   {d}: no info.json, skipped")
            continue
        c = info["cond"]
        if c not in refs:
            refs[c] = cond_refs(a.paper2, c, exclude)
        runs.append(analyze_run(d, refs[c], a.margin))
    print("   references per condition:")
    for c, r in refs.items():
        print(f"      {c:<12} switching level " + (f"{r['vm_V']:.3f} V ({r['vm_from']})" if r["vm_V"] is not None
                                                   else "not found: margins not judged")
              + "; leakage reference " + (f"{r['leak_uW']:.3f} uW (mean of {r['leak_macros']} PCM part A macros, "
                                          f"{r['leak_from']})" if r["leak_uW"] is not None else "not found"))
    print(f"\n   {'run':<40} {'word':>5} {'z':>2} {'P1':>4} {'margin 1/0 V':>15} {'P start':>8} {'P 0.5ms':>8} "
          f"{'P 1ms':>7} {'P end':>7} | {'E 1 ms':>7} {'E wait':>7} {'E 6.08ms':>8} | beyond the wait")
    print(f"   {'':<40} {'':>5} {'':>2} {'':>4} {'':>15} {'uW':>8} {'uW':>8} {'uW':>7} {'uW':>7} | {'nJ':>7} {'nJ':>7} "
          f"{'nJ':>8} |")
    npass = 0
    for r in runs:
        i = r["info"]
        if not r["t_wait_s"]:
            print(f"   {i['label']:<40} {i['value']:>5} {i['z']:2d} FAIL  no data ({r.get('error', 'no wait reached')})")
            continue
        npass += r["p1"]
        mg = (f"{r['margin_one_V']:+.3f}/{r['margin_zero_V']:+.3f}" if r["margin_one_V"] is not None else "-")
        pa = r["P_at_uW"]
        print(f"   {i['label']:<40} {i['value']:>5} {i['z']:2d} {('PASS' if r['p1'] else 'FAIL'):>4} {mg:>15} "
              f"{(r['P_start_uW'] or 0):8.2f} {pa.get('500', float('nan')):8.2f} {pa.get('1000', float('nan')):7.2f} "
              f"{r['P_end_uW']:7.3f} | {e_parked(r, 1e-3) * 1e9:7.2f} {r['E_end_J'] * 1e9:7.2f} "
              f"{e_parked(r, T_RULE) * 1e9:8.2f} | {extension(r)}"
              + ("" if r["complete"] else "  (INCOMPLETE)")
              + ("" if r["reads_ok"] else "  (READS WRONG)")
              + ("  (margin below the rule)" if r.get("margin_ok") is False else ""))
    a1 = [r["a1_rel"] for r in runs if r.get("a1_rel") is not None]
    if a1:
        w = max(a1, key=abs)
        print(f"\n   A1 (information): integral of the wait against the bench's energy of the wait: largest difference "
              f"{100 * w:+.3f} % ({'within' if abs(w) <= 0.01 else 'NOT within'} 1 %)")
    print(f"   P1: {npass} of {len(a.runs)} runs pass (complete, both reads correct with the right selection, "
          f"margins >= {a.margin:.2f} V where the switching level is known)")
    if a.out:
        json.dump({"created": time.strftime("%Y-%m-%d %H:%M:%S"), "script_md5": md5(os.path.abspath(__file__)),
                   "margin_V": a.margin, "runs": runs}, open(a.out, "w"), indent=1)
        print(f"   written {a.out}  md5 {md5(a.out)}")
    return 0


# ---------------------------------------------------------------- drom
def cmd_drom(a):
    root = os.path.join(a.paper2, "reports", "e8_rom")
    f3 = os.path.join(a.paper2, "scripts", "e8_6a3_rom_energy.py")
    f2 = os.path.join(a.paper2, "scripts", "e8_6a2_rom_energy.py")
    E3 = load_module(f3, "e8_6a3_rom_energy")
    E = load_module(f2, "e8_6a2_rom_energy")
    mj = os.path.join(root, "e8_4b_rel5", "model.json")
    dj = os.path.join(root, "e8_6a3_rel5", "d_rom.json")
    cj = os.path.join(root, "e8_5d", "candidates.json")
    e85 = a.events_dir or os.path.join(root, "e8_5")
    model = json.load(open(mj))
    dref = json.load(open(dj))
    park = json.load(open(a.park))
    cand = json.load(open(cj))["macros"]
    print(f"P2R-E8.5d D_ROM with the measured parked current  {time.strftime('%Y-%m-%d %H:%M:%S')}")
    for nm, p in (("script", os.path.abspath(__file__)), ("E8.6a-3", f3), ("E8.6a-2", f2), ("E8.4b model", mj),
                  ("D_ROM rel5", dj), ("candidates", cj), ("parked runs", a.park)):
        print(f"   {nm:<12}: {md5(p)}  {p}")
    usable, unused = {}, []
    for r in park["runs"]:
        i = r["info"]
        if r.get("p1") and r.get("t_wait_s"):
            usable[(i["macro"], i["cond"], i["addr"])] = r
        else:
            unused.append(i["label"])
    print(f"   runs: {len(usable)} pass P1 and are used" + (f"; not used (P1 not passed): {', '.join(unused)}"
                                                           if unused else ""))
    sides = sorted(model["models"])
    leak, idle, choice = {}, {}, {}
    for side in sides:
        lm = [p["leak_mean_uW"] for p in model["parta"] if p["side"] == side and p["leak_mean_uW"] < 10.0]
        leak[side] = sum(lm) / len(lm)
        idle[side] = model["models"][side]["idle_parked_pJ"]
    for r in model["runs"]:
        if r["kind"] == "parta" and r.get("park_choice"):
            tok = r["park_choice"].split()[0]
            choice.setdefault(r["table"], {})[r["k"]] = int(tok) if tok.isdigit() else None
    sm = {s: E.SideModel(model["models"][s], "bits", leak[s], idle[s]) for s in sides}
    nfail = 0

    def gate(ok, txt):
        nonlocal nfail
        print(f"  {'PASS' if ok else 'FAIL'}  {txt}")
        if not ok:
            nfail += 1

    def replay_c(tab, ev, smod, t_end, cfun, offset):
        """E8.6a-3's replay (read, park, static); the parked intervals of the macros k in cfun from cfun[k](T), the
        energy (J) from the end of the parking read to T (s) after it, instead of the constant power; offset[k]: ns
        since the macro's parking read at t = 0 (steady state: the last parking read of the inference)"""
        rows = tab.rows
        st_w = [tab.park[k][1] for k in range(tab.nmac)]
        st_rb = [rows - 1 - tab.park[k][0] for k in range(tab.nmac)]
        parked = [True] * tab.nmac
        t_free = [0.0] * tab.nmac
        t_park = [-offset.get(k, 0.0) for k in range(tab.nmac)]
        En = {"read": 0.0, "park": 0.0, "static": 0.0}
        zp = {k: 0.0 for k in cfun}
        span = {k: [] for k in cfun}

        def gap(k, t1):
            d = t1 - t_free[k]
            if d <= 0:
                return
            if k in cfun and parked[k]:
                a0, a1 = (t_free[k] - t_park[k]) * 1e-9, (t1 - t_park[k]) * 1e-9
                e = (cfun[k](a1) - cfun[k](a0)) * 1e12
                zp[k] += e
                span[k].append((a0, a1))
            else:
                e = smod.ps[st_w[k]] * d * 1e-3
            En["static"] += e

        for T, kind, k, ent in ev:
            gap(k, T)
            if kind == "L":
                kk, r, w = tab.loc(ent)
                En["read"] += smod.read(rows - 1 - r, tab.zr[k][r], w, st_w[k])
                st_w[k], st_rb[k], parked[k] = w, rows - 1 - r, False
            else:
                rp, wp = tab.park[k]
                En["park"] += smod.park(rows - 1 - rp, tab.zr[k][rp], st_w[k], st_rb[k])
                st_w[k], st_rb[k], parked[k] = wp, rows - 1 - rp, True
                t_park[k] = T + E.SLOT_NS
            t_free[k] = max(t_free[k], T + E.SLOT_NS)
        for k in range(tab.nmac):
            gap(k, max(t_end, t_free[k]))
        return En, zp, span

    def tot(En):
        return En["read"] + En["park"] + En["static"]

    def mname_(M, side, lane, k):
        return f"e8rom_{M}_{side}_l{lane:02d}_16x{TW}_r{ROWS}k{k}"

    tables, zpm = {}, {}
    for M in ("A", "B"):
        for side in sides:
            for lane in range(E.K):
                tab = E.Table(E.table_words(a.paper2, M, side, lane, TW), ROWS, WPR,
                              choice.get(f"e8rom_{M}_{side}_l{lane:02d}_16x{TW}"))
                tables[(M, side, lane)] = tab
                for k in range(tab.nmac):
                    if tab.park[k][1] != E.MISS:
                        zpm[mname_(M, side, lane, k)] = (M, side, lane, k)
    bad = [n for n, (M, side, lane, k) in zpm.items() if n in cand and
           (cand[n]["words"][0]["row"], int(cand[n]["words"][0]["value"], 16)) != tables[(M, side, lane)].park[k]]
    gate(set(zpm) == set(cand) and not bad,
         f"D3 macros parked on a word with zero bits (E8.6a-3's tables): {', '.join(sorted(zpm))}; = candidates.json, "
         f"parking words (row, value) the same" + (f"; DIFFERENT: {', '.join(bad)}" if bad else ""))

    def curve(n, cond, addr):
        r = usable.get((n, cond, addr))
        return None if r is None else (lambda T, r=r: e_parked(r, T))

    out = {"created": time.strftime("%Y-%m-%d %H:%M:%S"), "script_md5": md5(os.path.abspath(__file__)),
           "inputs": {"e8_6a3": md5(f3), "e8_6a2": md5(f2), "model_json": md5(mj), "d_rom_rel5": md5(dj),
                      "candidates": md5(cj), "park": md5(a.park)},
           "T_rule_s": T_RULE, "models": {}, "macros": {}, "rule": {}, "conditions": {}}
    for M in ("A", "B"):
        print(f"\n==== model {M} ====")
        evp = os.path.join(e85, f"e85_events_{M}.txt")
        tp = os.path.join(root, "trace", f"trace_{M}.txt")
        print(f"   events: {md5(evp)}  {evp}")
        ev = E3.read_events(evp)
        _, done, _, _ = E.parse_trace(tp)
        t_end = done * E.CYCLE_NS
        lk_counts = {}
        for lane in range(E.K):
            cnt = {L: 0 for L in E.LAYERS}
            for x in E3.table_events(ev, "sram", lane, ("I",)):
                if x[1] == "L":
                    cnt[E.LAYERS[E3.layer_of(E, x[3])]] += 1
            lk_counts[(M, lane)] = cnt
        errs = E.validation_errors(model, lk_counts)
        acc = {s: {"orig": 0.0, "new": 0.0, "zp_const": 0.0, "zp_new": 0.0} for s in sides}
        worst, complete = 0.0, True
        keep = {}
        for side in sides:
            for lane in range(E.K):
                tab = tables[(M, side, lane)]
                evi = E3.table_events(ev, side, lane, ("I",))
                zks = [k for k in range(tab.nmac) if tab.park[k][1] != E.MISS]
                offset = {}
                for k in zks:
                    ek = [(T, kind) for T, kind, kk, _ in evi if kk == k]
                    lastp = [T for T, kind in ek if kind == "P"]
                    if not lastp:
                        sys.exit(f"{mname_(M, side, lane, k)}: never parked in the inference")
                    if ek[-1][1] != "P":
                        print(f"   WARNING {mname_(M, side, lane, k)}: its last read in the inference is a lookup, not a "
                              f"parking read; the steady state assumed (parked at the start) is not exact")
                    offset[k] = t_end - (lastp[-1] + E.SLOT_NS)
                En1, _, _, _, _, _ = E3.replay(E, tab, evi, sm[side], t_end)
                const = {k: (lambda T, w=tab.park[k][1], s=sm[side]: s.ps[w] * 1e-6 * T) for k in zks}
                En2, z2, _ = replay_c(tab, evi, sm[side], t_end, const, offset)
                for c in ("read", "park", "static"):
                    worst = max(worst, abs(En1[c] - En2[c]) / max(abs(En1[c]), 1e-12))
                acc[side]["orig"] += tot(En1)
                acc[side]["zp_const"] += sum(z2.values())
                if not zks:
                    acc[side]["new"] += tot(En1)
                    continue
                cur = {}
                for k in zks:
                    n = mname_(M, side, lane, k)
                    cv = curve(n, TT, cand[n]["words"][0]["addr"]) if n in cand else None
                    gate(cv is not None, f"D2 {n}: measured curve of its current parking word at tt 25 C "
                                         f"({'used' if cv else 'MISSING or not passing P1'})")
                    if cv is not None:
                        cur[k] = cv
                if len(cur) != len(zks):
                    complete = False
                    continue
                En3, z3, span = replay_c(tab, evi, sm[side], t_end, cur, offset)
                acc[side]["new"] += tot(En3)
                acc[side]["zp_new"] += sum(z3.values())
                keep[(side, lane)] = (tab, evi, offset, cur, tot(En3))
                for k in zks:
                    n = mname_(M, side, lane, k)
                    longest = max(b - a_ for a_, b in span[k])
                    out["macros"][n] = {"model": M, "parking_word": f"{tab.park[k][1]:04x}", "row": tab.park[k][0],
                                        "parked_intervals": len(span[k]), "longest_ms": longest * 1e3,
                                        "total_parked_ms": sum(b - a_ for a_, b in span[k]) * 1e3,
                                        "const_model_uW": sm[side].ps[tab.park[k][1]],
                                        "zero_parked_const_nJ": z2[k] * 1e-3, "zero_parked_measured_nJ": z3[k] * 1e-3}
                    print(f"   {n}: parking word {tab.park[k][1]:04x} (row {tab.park[k][0]}); {len(span[k])} parked "
                          f"intervals, longest {longest * 1e3:.3f} ms, in all {sum(b - a_ for a_, b in span[k]) * 1e3:.3f} "
                          f"ms; constant model {sm[side].ps[tab.park[k][1]]:.1f} uW -> {z2[k] * 1e-3:.1f} nJ; "
                          f"measured {z3[k] * 1e-3:.2f} nJ")
        b = dref["models"][M]["bits"]
        D_orig = sum(acc[s]["orig"] for s in sides) * 1e-6
        gate(worst < 1e-9 and abs(D_orig - b["D_uJ"]) <= 1e-9 * b["D_uJ"],
             f"D1 model {M}: the copy of the replay with the constant power = E8.6a-3 (largest relative difference "
             f"{worst:.1e}); D {D_orig:.6f} uJ, d_rom.json {b['D_uJ']:.6f}")
        okerr = all(("bits", s) in errs for s in sides)
        cor_orig = sum(acc[s]["orig"] * 1e-6 / (1 + errs[("bits", s)]["mean"]) for s in sides) if okerr else None
        gate(okerr and b.get("corrected_uJ") is not None and abs(cor_orig - b["corrected_uJ"]) <= 1e-9 * b["corrected_uJ"],
             f"D1b model {M}: corrected value recomputed as E8.6a-3 "
             + (f"{cor_orig:.6f} uJ, d_rom.json {b['corrected_uJ']:.6f}" if okerr else "not possible (model errors missing)"))
        rec = {"D_rel5_uJ": b["D_uJ"], "corrected_rel5_uJ": b.get("corrected_uJ"),
               "zero_parked_const_uJ": sum(acc[s]["zp_const"] for s in sides) * 1e-6,
               "mean_model_error": {s: errs[("bits", s)]["mean"] for s in sides} if okerr else None}
        if complete:
            Dn = sum(acc[s]["new"] for s in sides) * 1e-6
            zpn = sum(acc[s]["zp_new"] for s in sides) * 1e-6
            cor_new = (sum((acc[s]["new"] - acc[s]["zp_new"]) * 1e-6 / (1 + errs[("bits", s)]["mean"]) + acc[s]["zp_new"] * 1e-6
                           for s in sides) if okerr else None)
            rec.update({"D_uJ": Dn, "corrected_uJ": cor_new, "zero_parked_measured_uJ": zpn,
                        "by_side_uJ": {s: acc[s]["new"] * 1e-6 for s in sides}})
            print(f"   model {M}: parked on words with zero bits: constant model {rec['zero_parked_const_uJ']:.4f} uJ -> "
                  f"measured {zpn:.4f} uJ")
            print(f"   model {M}: D_ROM {b['D_uJ']:.3f} -> {Dn:.3f} uJ ({100 * (Dn / b['D_uJ'] - 1):+.1f} %); corrected "
                  f"{b['corrected_uJ']:.3f} -> " + (f"{cor_new:.3f} uJ (the measured parked part not divided by 1 + mean "
                                                    f"error)" if cor_new is not None else "-"))
        else:
            print(f"   model {M}: D_ROM with the measured curves NOT computed (a curve is missing)")
        out["models"][M] = rec
        # P3: the word-change rule
        for n, (MM, side, lane, k) in sorted(zpm.items()):
            if MM != M or (side, lane) not in keep or n not in cand:
                continue
            tab, evi, offset, cur, Dt = keep[(side, lane)]
            e_cur = cur[k](T_RULE)
            rows_ = []
            for w in cand[n]["words"][1:]:
                cv = curve(n, TT, w["addr"])
                if cv is None:
                    rows_.append({"role": w["role"], "addr": w["addr"], "value": w["value"], "usable": False})
                    continue
                tc = copy.copy(tab)
                tc.park = list(tab.park)
                tc.park[k] = (w["row"], int(w["value"], 16))
                cf = dict(cur)
                cf[k] = cv
                En4, _, _ = replay_c(tc, evi, sm[side], t_end, cf, offset)
                rows_.append({"role": w["role"], "addr": w["addr"], "value": w["value"], "usable": True,
                              "E_rule_nJ": cv(T_RULE) * 1e9, "ratio": cv(T_RULE) / e_cur if e_cur > 0 else None,
                              "dD_uJ": (tot(En4) - Dt) * 1e-6})
            el = [x for x in rows_ if x["usable"]]
            best = min(el, key=lambda x: x["dD_uJ"]) if el else None
            change = bool(best and best["ratio"] is not None and best["ratio"] <= 0.5 and best["dD_uJ"] <= -0.05)
            out["rule"][n] = {"current": {"addr": cand[n]["words"][0]["addr"], "value": cand[n]["words"][0]["value"],
                                          "E_rule_nJ": e_cur * 1e9}, "candidates": rows_,
                              "best": best["role"] if best else None, "change": change}
            print(f"   P3 {n}: current {cand[n]['words'][0]['value']} (addr {cand[n]['words'][0]['addr']}): "
                  f"{e_cur * 1e9:.2f} nJ over {T_RULE * 1e3:.2f} ms")
            for x in rows_:
                if x["usable"]:
                    print(f"      {x['role']:<12} {x['value']} (addr {x['addr']:3d}): {x['E_rule_nJ']:8.2f} nJ = "
                          f"{100 * x['ratio']:6.1f} % of the current word; D_ROM of model {M} {x['dD_uJ']:+.4f} uJ")
                else:
                    print(f"      {x['role']:<12} {x['value']} (addr {x['addr']:3d}): no run passing P1, not eligible")
            print(f"      -> {'CHANGE the parking word to ' + best['value'] + ' (' + best['role'] + ')' if change else 'keep the parking word'}"
                  f" (rule: the best candidate <= 50 % of the current word's parked energy and D_ROM -0.05 uJ or more)")
    # conditions (the current word of the condition macro)
    cm = a.cond_macro or f"e8rom_A_pcm_l04_16x{TW}_r{ROWS}k1"
    if cm in cand:
        addr = cand[cm]["words"][0]["addr"]
        ref = usable.get((cm, TT, addr))
        others = sorted(c for (n, c, ad) in usable if n == cm and ad == addr and c != TT)
        if others:
            print(f"\n==== conditions ({cm}, current word {cand[cm]['words'][0]['value']}) ====")
        for c in others:
            r = usable[(cm, c, addr)]
            e = e_parked(r, T_RULE)
            ratio = e / e_parked(ref, T_RULE) if ref else None
            zc = {M: out["models"][M]["zero_parked_measured_uJ"] * ratio for M in ("A", "B")
                  if ratio is not None and "zero_parked_measured_uJ" in out["models"][M]}
            out["conditions"][c] = {"E_rule_nJ": e * 1e9, "ratio_to_tt": ratio, "extension": extension(r),
                                    "zero_parked_uJ": zc}
            print(f"   {c:<12}: {e * 1e9:8.2f} nJ over {T_RULE * 1e3:.2f} ms ({extension(r)}); "
                  + (f"{ratio:.3f} x tt 25 C; zero-parked energy " + ", ".join(f"{M} {v:.4f} uJ" for M, v in zc.items())
                     if ratio is not None else "no tt 25 C run to compare"))
    od = a.out or os.path.join(os.path.dirname(os.path.abspath(a.park)), "d_rom_e85d.json")
    json.dump(out, open(od, "w"), indent=1)
    print(f"\n   written {od}  md5 {md5(od)}")
    print("ALL CHECKS PASS" if nfail == 0 else f"{nfail} CHECK(S) FAILED")
    return 0 if nfail == 0 else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("prep")
    p.add_argument("--paper2", required=True)
    v = sp.add_parser("verify")
    v.add_argument("--paper2", required=True)
    v.add_argument("--macros", nargs="*", default=None)
    q = sp.add_parser("addprobes")
    q.add_argument("--deck", required=True)
    q.add_argument("--top", required=True)
    r = sp.add_parser("analyze")
    r.add_argument("--paper2", required=True)
    r.add_argument("--runs", nargs="+", required=True)
    r.add_argument("--margin", type=float, default=0.10)
    r.add_argument("--out", default=None)
    d = sp.add_parser("drom")
    d.add_argument("--paper2", required=True)
    d.add_argument("--park", required=True)
    d.add_argument("--events-dir", default=None)
    d.add_argument("--cond-macro", default=None)
    d.add_argument("--out", default=None)
    a = ap.parse_args()
    return {"prep": cmd_prep, "verify": cmd_verify, "addprobes": cmd_addprobes, "analyze": cmd_analyze,
            "drom": cmd_drom}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
