#!/usr/bin/env python3
"""
e8_5f_tools.py   (P2R-E8.5f: the power of a ROM macro parked on a word of 0xFFFF, over milliseconds)

Background (claude/p2r-e8-5d-results.md, section 8): the three macros parked on a word with zero bits settle
at 0.284-0.295 uW at tt 25 C after 3 ms, a quarter of the parked level that D_ROM uses for the macros parked
on a word of 0xFFFF (rel5: 1.173 uW, the mean power of the first microsecond after a parking read). D_ROM
holds that level constant over milliseconds. This step measures it over 3 ms.

Commands
  prep    --paper2 P [--macros M:SIDE:LANE:K ...]
          the macros (default A:pcm:0:0..3 and A:sram:0:0..1, all extracted in E8.4a-7): Z (as
          e8_4b_energy_tools.py plan: most zero bits, then most zero cells in the row, then the lowest row and
          word) and the current parking word (rtl/e8/amu_park_<M>.vh); the parking word must be 0xFFFF;
          the rel5 part-A parked level of the macro (reports/e8_rom/e8_4b_rel5/model.json, parta
          leak_mean_uW) for comparison. Writes reports/e8_rom/e8_5f/words.json
  verify  --paper2 P [--macros NAME...]
          for the macros of words.json: V1 the data file (reports/e8_rom/e8_4a7/bins/<macro>.bin) equals its
          part of the table (data/); V2 the extracted netlist is there and its extraction log reports no
          errors; V3 LVS "match uniquely"; V4 Z and the parking word hold the values of words.json at their
          addresses, and the parking word is 0xFFFF. Exit 1 if any check fails
  judge   --paper2 P --park J [--out J]
          J: the output of scripts/e8_5d_tools.py analyze on the runs of this step. Rules written before the
          run (claude/p2r-e8-5f-sandbox.md):
          F0 a run is used only if it passes P1 of E8.5d (complete; both reads correct with the right
             selection; margins >= 0.10 V where the switching level is known)
          F1 for each side (PCM, SRAM): Q = E(6.08 ms) / (L x 6.08 ms) of every tt 25 C run of that side,
             where L is the macro's parked level that D_ROM holds constant (the part-A leak_mean_uW of the
             macro: reports/e8_rom/e8_4b_rel5/model.json at tt 25 C, the E8.4e folder of the condition
             otherwise) and E(6.08 ms) the measured energy of a parked interval of 6.08 ms (beyond 3 ms
             extended as E8.5d, P2); the side "decays" if the median Q < 0.90 (D_ROM's constant overstates a
             long parked interval by more than 10 %), else it is "constant". At least 3 PCM runs and 1 SRAM
             run must be used, else the side is "not judged"
          F2 (information) R = P_end / L (P_end: the last 100 us, at 3 ms); P_start (the first microsecond
             of this run, resolved only coarsely at the maximum time step of 500 ns) against L; Q and R at the
             other conditions (A_pcm_l00 k0)
          What follows (written before the run): a side that decays has its all-ones static of D_ROM
          recomputed in a separate step with the measured normalized curve; a constant side leaves D_ROM
          unchanged
"""
import argparse
import glob
import hashlib
import importlib.util
import json
import os
import re
import statistics
import sys
import time

ROWS = int(os.environ.get("E8_ROWS", "48"))
WPR = 13
TW = int(os.environ.get("E8_TABLE_WORDS", "2496"))
PER = ROWS * WPR
DEFAULT_MACROS = ["A:pcm:0:0", "A:pcm:0:1", "A:pcm:0:2", "A:pcm:0:3", "A:sram:0:0", "A:sram:0:1"]
FFFF = 0xFFFF
TT = "tt:25:1.80"
T_RULE = 6.08e-3
Q_LIMIT = 0.90


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


def words_json(paper2):
    return os.path.join(paper2, "reports", "e8_rom", "e8_5f", "words.json")


# ---------------------------------------------------------------- prep
def cmd_prep(a):
    root = os.path.join(a.paper2, "reports", "e8_rom")
    f2 = os.path.join(a.paper2, "scripts", "e8_6a2_rom_energy.py")
    E = load_module(f2, "e8_6a2_rom_energy")
    mj = os.path.join(root, "e8_4b_rel5", "model.json")
    model = json.load(open(mj))
    parta = {p["macro"]: p for p in model.get("parta", [])}
    print(f"P2R-E8.5f prep  {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"   script     : {md5(os.path.abspath(__file__))}  {os.path.abspath(__file__)}")
    print(f"   E8.6a-2    : {md5(f2)}  {f2}")
    print(f"   E8.4b model: {md5(mj)}  {mj}")
    out, bad, parks = {}, 0, {}
    for spec in (a.macros or DEFAULT_MACROS):
        try:
            M, side, lane, k = spec.split(":")
            lane, k = int(lane), int(k)
            si = ("sram", "pcm").index(side)
        except ValueError:
            sys.exit(f"bad macro {spec} (M:SIDE:LANE:K, SIDE pcm or sram)")
        if M not in parks:
            vh = os.path.join(a.paper2, "rtl", "e8", f"amu_park_{M}.vh")
            parks[M] = read_park_vh(vh)
            print(f"   parking words model {M}: {md5(vh)}  {vh} ({len(parks[M])} macros)")
        n = mname(M, side, lane, k)
        words = E.table_words(a.paper2, M, side, lane, TW)
        wk = words[k * PER:(k + 1) * PER]
        if len(wk) != PER:
            print(f"   ERROR {n}: the table has no macro {k}")
            bad += 1
            continue
        zr = [sum(zbits(x) for x in wk[r * WPR:(r + 1) * WPR]) for r in range(ROWS)]
        cand = [(r, w) for r in range(ROWS) for w in range(WPR)]
        z = {rw: zbits(wk[rw[0] * WPR + rw[1]]) for rw in cand}
        Z = max(cand, key=lambda rw: (z[rw], zr[rw[0]], -rw[0], -rw[1]))     # as e8_4b_energy_tools.py plan
        paddr = parks[M].get(si * 100 + lane * 4 + k)
        if paddr is None:
            print(f"   ERROR {n}: no parking word in amu_park_{M}.vh")
            bad += 1
            continue
        P = (paddr >> 4, paddr & 15)

        def rec(rw, role):
            v = wk[rw[0] * WPR + rw[1]]
            return {"role": role, "addr": (rw[0] << 4) | rw[1], "row": rw[0], "word": rw[1], "value": f"{v:04x}",
                    "z": zbits(v), "z_row": zr[rw[0]]}
        pz, pp = rec(Z, "Z"), rec(P, "parking")
        ref = parta.get(n, {}).get("leak_mean_uW")
        print(f"      {n}: Z {pz['value']} (addr {pz['addr']}, row {pz['row']} word {pz['word']}, {pz['z']} zero bits); "
              f"parking word {pp['value']} (addr {pp['addr']}, row {pp['row']} word {pp['word']}, "
              f"{pp['z_row']} zero cells in the row); rel5 part-A parked level "
              + (f"{ref:.3f} uW" if ref is not None else "not in model.json"))
        if pp["value"] != "ffff":
            print(f"   ERROR {n}: the parking word is {pp['value']}, not ffff")
            bad += 1
            continue
        out[n] = {"model": M, "side": side, "lane": lane, "k": k, "macro_from": "e8_4a7", "Z": pz, "park": pp,
                  "rel5_parked_uW": ref}
    if bad:
        sys.exit(f"{bad} macro(s) not usable: nothing written")
    wj = words_json(a.paper2)
    os.makedirs(os.path.dirname(wj), exist_ok=True)
    json.dump({"created": time.strftime("%Y-%m-%d %H:%M:%S"), "script_md5": md5(os.path.abspath(__file__)),
               "model_json_md5": md5(mj), "macros": out}, open(wj, "w"), indent=1)
    print(f"   written {wj}  md5 {md5(wj)}")
    return 0


# ---------------------------------------------------------------- verify
def cmd_verify(a):
    root = os.path.join(a.paper2, "reports", "e8_rom")
    E = load_module(os.path.join(a.paper2, "scripts", "e8_6a2_rom_energy.py"), "e8_6a2_rom_energy")
    wj = words_json(a.paper2)
    mac = json.load(open(wj))["macros"]
    names = a.macros or list(mac)
    nfail = 0
    print(f"P2R-E8.5f verify  {time.strftime('%Y-%m-%d %H:%M:%S')}   words.json {md5(wj)}")
    for n in names:
        if n not in mac:
            print(f"  FAIL  {n}: not in {wj}")
            nfail += 1
            continue
        m = mac[n]
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
        for w in (m["Z"], m["park"]):
            v = words[w["row"] * WPR + w["word"]]
            if v != int(w["value"], 16) or w["addr"] != (w["row"] << 4 | w["word"]):
                msg.append(f"V4 {w['role']} at row {w['row']} word {w['word']} holds {v:04x}, not {w['value']}")
        if int(m["park"]["value"], 16) != FFFF:
            msg.append(f"V4 the parking word is {m['park']['value']}, not ffff")
        if msg:
            nfail += 1
            for x in msg:
                print(f"  FAIL  {n}: {x}")
        else:
            print(f"  PASS  {n} (from {m['macro_from']}): data = table, extracted, LVS matched, Z and the parking "
                  f"word (ffff) as words.json")
    print("ALL CHECKS PASS" if nfail == 0 else f"{nfail} MACRO(S) FAILED")
    return 0 if nfail == 0 else 1


# ---------------------------------------------------------------- judge
def level_of(paper2, macro, cond):
    """the part-A parked level (uW) of a macro at a condition, and the model.json it comes from"""
    root = os.path.join(paper2, "reports", "e8_rom")
    mj = None
    if cond == TT:
        mj = os.path.join(root, "e8_4b_rel5", "model.json")
    else:
        for f in sorted(glob.glob(os.path.join(root, "e8_4b_c_*", "condition.txt"))):
            c = open(f).read().split()
            if c and c[0] == cond:
                mj = os.path.join(os.path.dirname(f), "model.json")
    if not mj or not os.path.isfile(mj):
        return None, None
    for p in json.load(open(mj)).get("parta", []):
        if p.get("macro") == macro and p.get("leak_mean_uW") is not None:
            return p["leak_mean_uW"], mj
    return None, mj


def cmd_judge(a):
    wj = words_json(a.paper2)
    mac = json.load(open(wj))["macros"]
    T5 = load_module(os.path.join(a.paper2, "scripts", "e8_5d_tools.py"), "e8_5d_tools")
    park = json.load(open(a.park))
    print(f"P2R-E8.5f judge  {time.strftime('%Y-%m-%d %H:%M:%S')}")
    for nm, p in (("script", os.path.abspath(__file__)), ("words", wj), ("parked runs", a.park)):
        print(f"   {nm:<12}: {md5(p)}  {p}")
    rows, used = [], {}
    print(f"\n   {'run':<36} {'P1':>4} {'L':>7} {'P 1us':>8} {'P 100us':>8} {'P 1ms':>8} {'P 3ms':>8} {'R':>6} | "
          f"{'E 6.08ms':>9} {'L x 6.08':>9} {'Q':>6} | L from")
    print(f"   {'':<36} {'':>4} {'uW':>7} {'uW':>8} {'uW':>8} {'uW':>8} {'uW':>8} {'':>6} | {'nJ':>9} {'nJ':>9} "
          f"{'':>6} |")
    f = lambda v, w=8, d=3: f"{v:{w}.{d}f}" if v is not None else f"{'-':>{w}}"
    for r in park["runs"]:
        i = r["info"]
        m = mac.get(i["macro"], {})
        ok = bool(r.get("p1") and r.get("t_wait_s"))
        L, lsrc = level_of(a.paper2, i["macro"], i["cond"])
        x = {"label": i["label"], "macro": i["macro"], "side": m.get("side"), "cond": i["cond"], "p1": ok,
             "L_uW": L, "L_from": lsrc}
        if r.get("t_wait_s"):
            pa = r.get("P_at_uW", {})
            x.update({"P_start_uW": r.get("P_start_uW"), "P_100us_uW": pa.get("100"), "P_1ms_uW": pa.get("1000"),
                      "P_end_uW": r["P_end_uW"], "E_6.08ms_nJ": T5.e_parked(r, T_RULE) * 1e9})
            if L:
                x["E_const_nJ"] = L * T_RULE * 1e3
                x["Q"] = x["E_6.08ms_nJ"] / x["E_const_nJ"]
                x["R"] = r["P_end_uW"] / L
            print(f"   {i['label']:<36} {('PASS' if ok else 'FAIL'):>4} {f(L, 7)} {f(x['P_start_uW'])} "
                  f"{f(x['P_100us_uW'])} {f(x['P_1ms_uW'])} {f(x['P_end_uW'])} {f(x.get('R'), 6)} | "
                  f"{x['E_6.08ms_nJ']:9.3f} {f(x.get('E_const_nJ'), 9)} {f(x.get('Q'), 6)} | "
                  + (os.path.relpath(lsrc, a.paper2) if lsrc else "no model.json for this condition")
                  + ("" if L else " (NO LEVEL FOR THIS MACRO: not used)"))
        else:
            print(f"   {i['label']:<36} FAIL  no data")
        rows.append(x)
        if ok and i["cond"] == TT and x.get("Q") is not None:
            used.setdefault(m.get("side"), []).append(x["Q"])
    need = {"pcm": 3, "sram": 1}
    verdict = {}
    print()
    for side in ("pcm", "sram"):
        qs = used.get(side, [])
        if len(qs) < need[side]:
            verdict[side] = {"verdict": "not judged", "runs": len(qs), "Q": qs}
            print(f"   F1 {side}: NOT JUDGED ({len(qs)} usable tt 25 C runs, {need[side]} needed)")
            continue
        med = statistics.median(qs)
        v = "decays" if med < Q_LIMIT else "constant"
        verdict[side] = {"verdict": v, "runs": len(qs), "Q": qs, "median_Q": med}
        print(f"   F1 {side}: median Q {med:.3f} over {len(qs)} tt 25 C runs (Q {', '.join(f'{q:.3f}' for q in qs)}) "
              f"-> {v.upper()} (rule: decays if the median Q < {Q_LIMIT:.2f})")
    cond = [x for x in rows if x["cond"] != TT and x.get("Q") is not None]
    if cond:
        print("   F2 (information) other conditions: " + "; ".join(
            f"{x['cond']} Q {x['Q']:.3f}, R {x['R']:.3f}" + ("" if x["p1"] else " (P1 FAIL)") for x in cond))
    tt = [x for x in rows if x["cond"] == TT and x.get("P_start_uW") and x.get("L_uW")]
    if tt:
        print("   F2 (information) P_start (first us, coarse) / L: " + ", ".join(
            f"{x['macro'].replace('e8rom_', '').replace(f'_16x{TW}', '')} {x['P_start_uW'] / x['L_uW']:.3f}"
            for x in tt))
    dec = [s for s, v in verdict.items() if v["verdict"] == "decays"]
    nj = [s for s, v in verdict.items() if v["verdict"] == "not judged"]
    if nj:
        print(f"\n   -> not judged for {', '.join(nj)}: rerun the missing runs (the second run keeps the finished ones)")
    if dec:
        print(f"\n   -> {', '.join(dec)}: the all-ones static of D_ROM is to be recomputed with the measured curve "
              f"(a separate step, written before this run)")
    if not nj and not dec:
        print("\n   -> both sides constant: D_ROM unchanged")
    if a.out:
        json.dump({"created": time.strftime("%Y-%m-%d %H:%M:%S"), "script_md5": md5(os.path.abspath(__file__)),
                   "inputs": {"words": md5(wj), "park": md5(a.park)}, "Q_limit": Q_LIMIT, "runs": rows,
                   "verdict": verdict}, open(a.out, "w"), indent=1)
        print(f"   written {a.out}  md5 {md5(a.out)}")
    return 1 if nj else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("prep")
    p.add_argument("--paper2", required=True)
    p.add_argument("--macros", nargs="*", default=None)
    v = sp.add_parser("verify")
    v.add_argument("--paper2", required=True)
    v.add_argument("--macros", nargs="*", default=None)
    j = sp.add_parser("judge")
    j.add_argument("--paper2", required=True)
    j.add_argument("--park", required=True)
    j.add_argument("--out", default=None)
    a = ap.parse_args()
    return {"prep": cmd_prep, "verify": cmd_verify, "judge": cmd_judge}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
