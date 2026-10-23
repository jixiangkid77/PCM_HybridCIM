#!/usr/bin/env python3
"""
e8_4e_sram_tools.py   (P2R-E8.4e, SRAM part: the protected-weight SRAM macro at other corners and temperatures)

The SRAM energies of the paper come from E8.4f: the 4-KB macro with the sense-side precharge drawn in the layout,
extracted and simulated at tt, 25 C, 1.80 V (scripts/e8_4c_sram_char.sh v7, run r10). E8.4e simulates the same
extracted netlist with the same bench options at five further conditions and at tt, 25 C as the reference of the same
sequence. This script derives the sequence, checks the decks and judges the results; scripts/e8_4e_sram_corners.sh
runs it.

seq      the E8.4e sequence from the cycles of E8.4f's r10 (its tb_meta.json): the leading cycles without access, the
         first NW writes of r10, one cycle without access, a gated read (read, then the clock stopped for 10 ns) of each
         of the first NW-1 written words in the order written, and a read of the last written word followed by a 60 ns
         stopped clock (the static power after a read). Prints a JSON line with both sequences (r10 rebuilt from its
         cycles, for the deck check, and E8.4e).
deckcmp  compares a deck written now with E8.4f's r10 deck: tb.sp line by line (only the .include line of the netlist
         copy may differ, and only by its folder), netlist.sp (md5), .spiceinit, tb_meta.json (every field). Exit 0
         when identical.
compare  the gates and results of all conditions (claude/p2r-e8-4e-sram-sandbox.md, section 3, written before the run):
         P1 model check, P3 deck of each condition, V reads, R reference against E8.4f's r10; energies per read, static
         power after a read and its trend over the 60 ns stop, access time; ratios to tt 25 C of this experiment.

Usage:
  python3 e8_4e_sram_tools.py seq --meta <E8.4f work>/r10/tb_meta.json [--nw 5]
  python3 e8_4e_sram_tools.py deckcmp --ref <E8.4f work>/r10 --new <dir>
  python3 e8_4e_sram_tools.py compare --work <E8.4e work> --ref-r10 <E8.4f work>/r10 --ref-modelcheck <E8.4f
          work>/modelcheck/modelcheck.json --rb scripts/e8_4_rom_bench.py --conds "tt:25 ss:25 ..." [--json <file>]

Place  : scripts/
Status : 2026-10-20 v1 (new)
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
import re
import sys

STOP_GATED_NS = 10.0      # the stop after each gated read (as r10: the lane's clock gated for one system cycle)
STOP_STATIC_NS = 60.0     # the stop after the last read (as the stops of r10 that give the static power)
SETTLE_TOL = 0.10         # static power still changing by more than this between the last two windows: not settled


def tag_of(cond):
    corner, temp = cond.split(":")
    t = float(temp)
    return f"c_{corner}_{'m' if t < 0 else ''}{abs(t):g}"


def parse_cond(cond):
    m = re.match(r"^(tt|ff|ss|fs|sf):(-?\d+(?:\.\d+)?)$", cond)
    if not m:
        sys.exit(f"bad condition {cond} (corner:temperature, e.g. ff:85)")
    return m.group(1), float(m.group(2))


def tokens_from_cycles(cyc):
    out = []
    for c in cyc:
        k = c["kind"]
        if k == "write":
            out.append(f"w:{c['addr']}:{c['data']:02x}")
        elif k == "read":
            out.append(f"r:{c['addr']}")
        elif k == "idle":
            out.append("i")
        elif k == "stop":
            out.append(f"s:{c['stop_ns']:g}")
        else:
            sys.exit(f"unknown cycle kind {k}")
    return out


def e84e_cycles(cyc, nw):
    """(leading idles, the first nw writes) of r10; the r10 structure is checked"""
    lead = 0
    while lead < len(cyc) and cyc[lead]["kind"] == "idle":
        lead += 1
    writes = []
    k = lead
    while k < len(cyc) and cyc[k]["kind"] == "write":
        writes.append(cyc[k])
        k += 1
    if lead < 1 or len(writes) < nw:
        sys.exit(f"r10 does not start with idle cycles and at least {nw} writes (idle {lead}, writes {len(writes)})")
    addrs = [w["addr"] for w in writes[:nw]]
    if len(set(addrs)) != nw:
        sys.exit(f"the first {nw} writes of r10 do not go to {nw} different words: {addrs}")
    gated = [c for i, c in enumerate(cyc[:-1]) if c["kind"] == "read" and cyc[i + 1]["kind"] == "stop"
             and abs(cyc[i + 1]["stop_ns"] - STOP_GATED_NS) < 1e-9]
    if [g["addr"] for g in gated[:nw]] != [w["addr"] for w in writes[:nw]]:
        sys.exit("the gated reads of r10 do not read the written words in the order written")
    return lead, writes[:nw]


def cmd_seq(a):
    meta = json.load(open(a.meta))
    cyc = meta["cycles"]
    lead, writes = e84e_cycles(cyc, a.nw)
    toks = ["i"] * lead + [f"w:{w['addr']}:{w['data']:02x}" for w in writes] + ["i"]
    for w in writes[:-1]:
        toks += [f"r:{w['addr']}", f"s:{STOP_GATED_NS:g}"]
    toks += [f"r:{writes[-1]['addr']}", f"s:{STOP_STATIC_NS:g}"]
    print(json.dumps({"r10": " ".join(tokens_from_cycles(cyc)), "e84e": " ".join(toks), "lead_idle": lead,
                      "words": [{"addr": w["addr"], "data": w["data"]} for w in writes], "period_ns": meta["period_ns"]}))
    return 0


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def cmd_deckcmp(a):
    diffs = []
    ta = open(os.path.join(a.ref, "tb.sp")).read().split("\n")
    tb = open(os.path.join(a.new, "tb.sp")).read().split("\n")
    inc = re.compile(r'^\.include "(.*)/netlist\.sp"$')
    if len(ta) != len(tb):
        diffs.append(f"tb.sp: {len(ta)} against {len(tb)} lines")
    for i, (x, y) in enumerate(zip(ta, tb)):
        if x == y:
            continue
        if inc.match(x) and inc.match(y):
            continue
        diffs.append(f"tb.sp line {i + 1}: '{x[:90]}' against '{y[:90]}'")
    ma, mb = md5(os.path.join(a.ref, "netlist.sp")), md5(os.path.join(a.new, "netlist.sp"))
    if ma != mb:
        diffs.append(f"netlist.sp: md5 {ma} against {mb}")
    sa, sb = (open(os.path.join(d, ".spiceinit")).read() for d in (a.ref, a.new))
    if sa != sb:
        diffs.append(".spiceinit differs")
    ja, jb = (json.load(open(os.path.join(d, "tb_meta.json"))) for d in (a.ref, a.new))
    for k in sorted(set(ja) | set(jb)):
        x, y = ja.get(k), jb.get(k)
        if k == "netlist" and isinstance(x, str) and isinstance(y, str):
            x, y = os.path.realpath(x), os.path.realpath(y)     # the same extracted netlist, however the folder is named
        if x != y:
            diffs.append(f"tb_meta.json field {k} differs")
    if diffs:
        print("DECK DIFFERENT: " + "; ".join(diffs[:12]) + (f" (and {len(diffs) - 12} more)" if len(diffs) > 12 else ""))
        return 1
    print(f"DECK IDENTICAL (tb.sp {len(ta)} lines, only the folder of the netlist copy differs; netlist.sp md5 {ma}; "
          f".spiceinit; tb_meta.json)")
    return 0


def load_rb(path):
    spec = importlib.util.spec_from_file_location("e8bench", path)
    rb = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rb)
    return rb


def reads_of(res):
    """the reads of a result.json with the cycle that follows each"""
    cyc = res["cycles"]
    out = []
    for i, c in enumerate(cyc):
        if c["kind"] != "read":
            continue
        nx = cyc[i + 1] if i + 1 < len(cyc) else None
        out.append((i, c, nx))
    return out


def gated_energy(c, nx):
    if nx is None or nx["kind"] != "stop":
        return None
    return c["E_vdd_pJ"] + nx["E_vdd_pJ"] - nx["P_end_uW"] * 1e-6 * nx["stop_ns"] * 1e-9 * 1e12


def static_trend(rb, d, meta, res):
    """average supply power in three windows of the last stop (10-20, 30-40 and the last 12 ns of the 60 ns)"""
    pout = os.path.join(d, "tb_out.txt")
    if not os.path.isfile(pout):
        return None
    cyc = res["cycles"]
    last = cyc[-1]
    if last["kind"] != "stop":
        return None
    mc = meta["cycles"][last["k"]]
    t1, t2 = mc["trise"], mc["tend"]
    header, c = rb.read_wrdata(pout)
    t = c[header[0]]
    key = next((h for h in header if h.lower() == "i(vvdd)"), None)
    if key is None or t[-1] < t2 - 1e-12:
        return None
    p = [-meta["vdd"] * x for x in c[key]]
    span = (t2 - t1) * 1e9
    wins = [(10.0, 20.0), (30.0, 40.0), (span - span / 5, span)]
    out = []
    for lo, hi in wins:
        lo_t, hi_t = t1 + lo * 1e-9, t1 + hi * 1e-9
        out.append({"from_ns": round(lo, 3), "to_ns": round(hi, 3),
                    "P_uW": rb.integ(t, p, lo_t, hi_t) / (hi_t - lo_t) * 1e6})
    return out


def one_condition(rb, d, nw):
    """everything about one condition's run that does not need the reference"""
    r = {"dir": d, "state": "missing"}
    meta_p, res_p = os.path.join(d, "tb_meta.json"), os.path.join(d, "result.json")
    if os.path.isfile(os.path.join(d, "skip")):
        r["state"] = "skipped"
        r["skip"] = open(os.path.join(d, "skip")).read().strip()
        return r
    if not os.path.isfile(meta_p):
        return r
    meta = json.load(open(meta_p))
    r.update({"corner": meta["corner"], "temp": meta["temp"], "vdd": meta["vdd"]})
    if not os.path.isfile(res_p):
        r["state"] = "no result"
        return r
    res = json.load(open(res_p))
    s = res["summary"]
    r["state"] = "finished" if s.get("complete") else "incomplete"
    rd = reads_of(res)
    r["reads"] = [{"k": c["k"], "addr": c["addr"], "expected": c["expected"], "read_after_stop": c["read_after_stop"],
                   "ok_after_stop": c["ok_after_stop"], "read_end": c["read_end"], "t_acc_gated_ns": c["t_acc_gated_ns"],
                   "E_cycle_pJ": c["E_vdd_pJ"], "E_gated_pJ": gated_energy(c, nx),
                   "stop_ns": None if nx is None else nx.get("stop_ns")} for i, c, nx in rd]
    r["n_reads"] = len(rd)
    r["reads_ok_after_stop"] = sum(1 for x in r["reads"] if x["ok_after_stop"])
    r["valid"] = (r["state"] == "finished" and len(rd) == nw and r["reads_ok_after_stop"] == nw
                  and all(x["stop_ns"] is not None for x in r["reads"]))
    sys_reads = [x for x in r["reads"][1:nw - 1] if x["stop_ns"] is not None and abs(x["stop_ns"] - STOP_GATED_NS) < 1e-9]
    vals = [x["E_gated_pJ"] for x in sys_reads if x["E_gated_pJ"] is not None]
    r["E_sys_pJ"] = sum(vals) / len(vals) if vals else None
    r["E_sys_n"] = len(vals)
    r["E_first_gated_pJ"] = r["reads"][0]["E_gated_pJ"] if rd else None
    r["E_last_read_cycle_pJ"] = r["reads"][-1]["E_cycle_pJ"] if rd else None
    cyc = res["cycles"]
    r["P_static_uW"] = cyc[-1]["P_end_uW"] if cyc and cyc[-1]["kind"] == "stop" else None
    w = [c["E_vdd_pJ"] for c in cyc if c["kind"] == "write"]
    i_ = [c["E_vdd_pJ"] for c in cyc if c["kind"] == "idle"]
    r["E_write_pJ"] = sum(w) / len(w) if w else None
    r["E_idle_pJ"] = sum(i_) / len(i_) if i_ else None
    ta = [x["t_acc_gated_ns"] for x in r["reads"] if x["t_acc_gated_ns"] is not None]
    r["t_acc_gated_ns_max"] = max(ta) if ta else None
    r["trend"] = static_trend(rb, d, meta, res) if r["state"] == "finished" else None
    r["static_direction"] = None
    if r["trend"]:
        a_, b_ = r["trend"][-2]["P_uW"], r["trend"][-1]["P_uW"]
        r["static_settled"] = abs(b_ - a_) <= SETTLE_TOL * abs(b_) if b_ else False
        r["static_direction"] = "falling" if b_ < a_ else "rising"
    else:
        r["static_settled"] = None
    r["cycles_E"] = [c["E_vdd_pJ"] for c in cyc]
    return r


def cmd_compare(a):
    rb = load_rb(a.rb)
    conds = a.conds.split()
    for c in conds:
        parse_cond(c)
    ref_mc = json.load(open(a.ref_modelcheck)) if a.ref_modelcheck and os.path.isfile(a.ref_modelcheck) else None
    r10 = json.load(open(os.path.join(a.ref_r10, "result.json")))
    r10_meta = json.load(open(os.path.join(a.ref_r10, "tb_meta.json")))
    lead, writes = e84e_cycles(r10_meta["cycles"], a.nw)
    ref_net = os.path.join(a.ref_r10, "netlist.sp")
    ref_md5 = md5(ref_net) if os.path.isfile(ref_net) else None
    out = {"nw": a.nw, "conditions": conds, "reference": "tt:25", "per": {}, "notes": []}
    print("P2R-E8.4e SRAM: gates and results (rules: claude/p2r-e8-4e-sram-sandbox.md, section 3)")
    print(f"   sequence: {lead} cycles without access, {a.nw} writes of E8.4f's r10, 1 without access, "
          f"{a.nw - 1} gated reads (10 ns stop), 1 read with a {STOP_STATIC_NS:g} ns stop; system reads = reads 2-{a.nw - 1}")
    # ---- per condition: P1, P3, V and the numbers
    for c in conds:
        corner, temp = parse_cond(c)
        tg = tag_of(c)
        d = os.path.join(a.work, tg)
        r = one_condition(rb, d, a.nw)
        r["cond"] = c
        # P1: the model check at the corner (the scripts write <work>/modelcheck_<corner>/modelcheck.json)
        mcp = os.path.join(a.work, f"modelcheck_{corner}", "modelcheck.json")
        if os.path.isfile(mcp):
            mc = json.load(open(mcp))
            same = ref_mc is None or bool(mc.get("pfet_pass_alias")) == bool(ref_mc.get("pfet_pass_alias"))
            r["P1"] = "PASS" if mc.get("verdict") == "OK" and same else "FAIL"
            r["P1_detail"] = f"verdict {mc.get('verdict')}, pfet_pass alias {mc.get('pfet_pass_alias')}" + \
                             ("" if same else " (E8.4f: " + str(ref_mc.get("pfet_pass_alias")) + ")")
        else:
            r["P1"], r["P1_detail"] = "NOT RUN", "no model check"
        # P3: the deck of the condition: the netlist copy identical to E8.4f's r10, the corner and temperature in tb.sp
        tbp = os.path.join(d, "tb.sp")
        if os.path.isfile(tbp):
            tb = open(tbp).read()
            lib_ok = re.search(r'^\.lib "[^"]+" ' + re.escape(corner) + r"\s*$", tb, re.M) is not None
            tmp_ok = re.search(r"^\.temp " + re.escape(f"{temp}") + r"\s*$", tb, re.M) is not None
            net = os.path.join(d, "netlist.sp")
            net_ok = ref_md5 is not None and os.path.isfile(net) and md5(net) == ref_md5
            seq_ok = None
            mp = os.path.join(d, "tb_meta.json")
            if os.path.isfile(mp):
                m = json.load(open(mp))
                seq_ok = m["period_ns"] == r10_meta["period_ns"] and m["vdd"] == r10_meta["vdd"] and \
                    m["cload_fF"] == r10_meta["cload_fF"] and m["notes"] == r10_meta["notes"] and \
                    m["probes"] == r10_meta["probes"] and m["models"] == r10_meta["models"]
            r["P3"] = "PASS" if (lib_ok and tmp_ok and net_ok and seq_ok) else "FAIL"
            r["P3_detail"] = (f"netlist copy {'identical to' if net_ok else 'DIFFERENT FROM'} E8.4f r10; .lib {corner} "
                              f"{'yes' if lib_ok else 'NO'}; .temp {temp:g} {'yes' if tmp_ok else 'NO'}; period, supply, load, "
                              f"notes, probes and model library as r10: {'yes' if seq_ok else 'NO'}")
        else:
            r["P3"], r["P3_detail"] = "NOT RUN", "no deck"
        out["per"][c] = r
    # ---- R: the reference of this experiment against E8.4f's r10
    ref = out["per"].get("tt:25")
    R = {"verdict": "NOT JUDGED"}
    if ref and ref.get("state") == "finished":
        ncmp = lead + a.nw - 1      # the cycles before the last write: their inputs and the next cycle's are the same
        diffs = []
        for k in range(ncmp):
            e1, e2 = r10["cycles"][k]["E_vdd_pJ"], ref["cycles_E"][k]
            diffs.append({"k": k, "kind": r10["cycles"][k]["kind"], "r10": e1, "e84e": e2, "diff_pJ": e2 - e1,
                          "ok": abs(e2 - e1) <= max(1e-3 * abs(e1), 0.01)})
        r10_gated = [gated_energy(c, nx) for i, c, nx in reads_of(r10)]
        soft = []
        for j in range(1, a.nw - 1):
            x, y = r10_gated[j], ref["reads"][j]["E_gated_pJ"]
            if x is not None and y is not None:
                soft.append({"read": j + 1, "r10": x, "e84e": y, "rel": (y - x) / x})
        R = {"verdict": "PASS" if all(x["ok"] for x in diffs) else "FAIL", "cycles": diffs, "system_reads": soft}
    out["R"] = R
    # ---- ratios to the reference of this experiment
    ok_ref = ref is not None and ref.get("valid")
    for c, r in out["per"].items():
        r["usable"] = bool(r.get("valid") and r.get("P1") == "PASS" and r.get("P3") == "PASS")
        if ok_ref and r["usable"]:
            r["r_read"] = r["E_sys_pJ"] / ref["E_sys_pJ"] if ref["E_sys_pJ"] else None
            r["r_static"] = r["P_static_uW"] / ref["P_static_uW"] if ref["P_static_uW"] else None
            r["r_write"] = r["E_write_pJ"] / ref["E_write_pJ"] if ref["E_write_pJ"] else None
            r["r_idle"] = r["E_idle_pJ"] / ref["E_idle_pJ"] if ref["E_idle_pJ"] else None
            per_read = []
            for j in range(1, a.nw - 1):
                x, y = ref["reads"][j]["E_gated_pJ"], r["reads"][j]["E_gated_pJ"]
                if x and y is not None:
                    per_read.append(y / x)
            r["r_read_per_read"] = per_read
        else:
            r["r_read"] = r["r_static"] = r["r_write"] = r["r_idle"] = None
            r["r_read_per_read"] = []
    # ---- print
    hx = lambda v: "--" if v is None else f"{v:02x}"
    f3 = lambda v, n=3: "-" if v is None else f"{v:.{n}f}"
    print()
    print(f"{'condition':10} {'state':11} {'P1':5} {'P3':5} {'reads ok':8} {'E_sys pJ':>9} {'r_read':>7} "
          f"{'P_static uW':>12} {'r_static':>9} {'settled':>7} {'t_acc ns':>8} {'E_write':>8} {'E_idle':>7}")
    for c in conds:
        r = out["per"][c]
        okr = f"{r.get('reads_ok_after_stop', '-')}/{r.get('n_reads', '-')}" if r["state"] != "missing" else "-"
        st = r.get("static_settled")
        print(f"{c:10} {r['state']:11} {r.get('P1', '-'):5} {r.get('P3', '-'):5} {okr:8} {f3(r.get('E_sys_pJ')):>9} "
              f"{f3(r.get('r_read'), 4):>7} {f3(r.get('P_static_uW'), 4):>12} {f3(r.get('r_static'), 3):>9} "
              f"{'-' if st is None else ('yes' if st else 'NO'):>7} {f3(r.get('t_acc_gated_ns_max')):>8} "
              f"{f3(r.get('E_write_pJ')):>8} {f3(r.get('E_idle_pJ')):>7}")
    print()
    for c in conds:
        r = out["per"][c]
        if r["state"] in ("missing", "skipped"):
            print(f"   {c}: not simulated" + (f" ({r.get('skip')})" if r.get("skip") else ""))
            continue
        print(f"   {c}: P1 {r.get('P1_detail')}; P3 {r.get('P3_detail')}")
        if r.get("reads"):
            print("      reads: " + "; ".join(
                f"{x['addr']} exp {hx(x['expected'])} got {hx(x['read_after_stop'])} "
                f"{'ok' if x['ok_after_stop'] else 'WRONG'} {f3(x['E_gated_pJ'])} pJ t_acc {f3(x['t_acc_gated_ns'])} ns"
                for x in r["reads"]))
        if r.get("trend"):
            print("      static power over the last stop: " + ", ".join(
                f"{w['from_ns']:g}-{w['to_ns']:g} ns {w['P_uW']:.4f} uW" for w in r["trend"]))
        if r.get("r_read_per_read"):
            print(f"      ratio per system read: {', '.join(f'{x:.4f}' for x in r['r_read_per_read'])}")
    print()
    if R["verdict"] != "NOT JUDGED":
        worst = max(R["cycles"], key=lambda x: abs(x["diff_pJ"]))
        print(f"   R reference (tt 25 C of this experiment against E8.4f r10, the {len(R['cycles'])} cycles before the last "
              f"write): {R['verdict']}; largest difference {worst['diff_pJ']:+.4f} pJ (cycle {worst['k']}, {worst['kind']})")
        if R["system_reads"]:
            print("      system reads against r10 (other words written before, not a gate): " + ", ".join(
                f"read {x['read']} {100 * x['rel']:+.2f} %" for x in R["system_reads"]))
    else:
        print("   R reference: not judged (tt:25 of this experiment not finished)")
    # ---- conclusions (written before the run)
    concl = []
    unsettled = lambda r: ("" if r.get("static_settled") is not False else
                           f" The static power still changed by more than 10 % between 30-40 ns and the last 12 ns of the "
                           f"60 ns stop ({r['static_direction']}): not settled; the value at 60 ns is "
                           f"{'an upper' if r['static_direction'] == 'falling' else 'a lower'} bound of the later static power.")
    if not ok_ref:
        concl.append("No valid reference (tt 25 C of this experiment): no ratios.")
    else:
        concl.append(f"tt:25 (reference): energy per system read {ref['E_sys_pJ']:.2f} pJ; static power after a read "
                     f"{ref['P_static_uW']:.4g} uW; data within {ref['t_acc_gated_ns_max']:.2f} ns of the rising edge."
                     + unsettled(ref))
    for c in conds:
        if c == "tt:25":
            continue
        r = out["per"][c]
        if r["state"] == "missing":
            concl.append(f"{c}: not simulated.")
        elif r["state"] == "skipped":
            concl.append(f"{c}: not simulated ({r.get('skip')}).")
        elif r.get("P1") != "PASS" or r.get("P3") != "PASS":
            concl.append(f"{c}: the deck or the models do not meet the rules (P1 {r.get('P1')}, P3 {r.get('P3')}); no numbers.")
        elif r["state"] != "finished":
            concl.append(f"{c}: the simulation did not finish ({r['state']}); no numbers.")
        elif not r["valid"]:
            bad = [x for x in r["reads"] if not x["ok_after_stop"]]
            concl.append(f"{c}: {len(bad)} of {r['n_reads']} reads wrong at the end of the two-cycle window: outside the "
                         f"verified range of the two-cycle read at 100 MHz; energies reported only for the record.")
        elif ok_ref:
            s = (f"{c}: energy per system read {r['E_sys_pJ']:.2f} pJ, {r['r_read']:.3f} times tt 25 C; static power after "
                 f"a read {r['P_static_uW']:.4g} uW, {r['r_static']:.3g} times; data within {r['t_acc_gated_ns_max']:.2f} ns "
                 f"of the rising edge.")
            concl.append(s + unsettled(r))
    if R["verdict"] == "FAIL":
        concl.append("R failed: the reference of this experiment differs from E8.4f's r10 in the cycles that must be "
                     "identical; the ratios hold within this experiment only, and the deck must be checked before the "
                     "absolute values are used.")
    out["conclusions"] = concl
    print()
    print("conclusions:")
    for x in concl:
        print("   " + x)
    for r in out["per"].values():
        r.pop("cycles_E", None)
    if a.json:
        json.dump(out, open(a.json, "w"), indent=1)
        print(f"\nsummary written: {a.json}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("seq")
    s.add_argument("--meta", required=True)
    s.add_argument("--nw", type=int, default=5)
    d = sp.add_parser("deckcmp")
    d.add_argument("--ref", required=True)
    d.add_argument("--new", required=True)
    c = sp.add_parser("compare")
    c.add_argument("--work", required=True)
    c.add_argument("--ref-r10", required=True)
    c.add_argument("--ref-modelcheck", default="")
    c.add_argument("--rb", required=True)
    c.add_argument("--conds", required=True)
    c.add_argument("--nw", type=int, default=5)
    c.add_argument("--json", default="")
    a = ap.parse_args()
    if a.cmd in ("seq", "compare") and a.nw < 3:
        sys.exit("--nw must be at least 3 (one read before the system reads, at least one system read, the last read)")
    return {"seq": cmd_seq, "deckcmp": cmd_deckcmp, "compare": cmd_compare}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
