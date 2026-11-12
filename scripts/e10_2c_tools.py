#!/usr/bin/env python3
"""P2R-E10.2c tools (run by scripts/e10_2c_pool_energy.sh).

  judge    the gates of the gate-level runs of the pool with clock gating (cg, rtl/e10/sram_pool_25bank_2c_cg.v,
           the netlist of E10.2a) in the unit without the conv1 cache (rtl/e10/pcm_imc_unit_e10n.v), and the
           energy of the pool logic per inference, also by cell class (flip-flops, bank clock gates, register
           clock gates, combinational). Uses the helpers of scripts/e10_2a_tools.py (same folder, unchanged).
"""
import argparse
import collections
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e10_2a_tools as t2a          # noqa: E402  (md5, _read, _jload, regexes, clock_root)

READS_NC = {"A": 267143, "B": 205664}          # SRAM reads per inference without the conv1 cache (E8.5c)
REFNAME = {"cache": "new", "conce": "once"}    # the E8.5c runs with the same pool behaviour


def cell_names(path):
    m = {}
    for ln in open(path, errors="replace"):
        f = ln.split()
        if len(f) >= 4 and f[1] == "cell":
            m[f[0]] = (f[2], f[3])
    return m


def klass(names, inst):
    orig, typ = names.get(inst, ("?", "?"))
    t = typ.replace("sky130_fd_sc_hd__", "")
    if re.match(r"s?e?df", t):
        return "flip-flops"
    if t.startswith("dlclkp"):
        return "bank clock gates" if "U_BCG" in orig else "register clock gates"
    if t.startswith("buf") and "insbuf" in orig:
        return "bank clock buffers (stage 3)"
    return "combinational"


def cmd_judge(a):
    W = a.work
    out = {"design": {}, "runs": {}, "paper": {}}
    ok_all = True
    print("P2R-E10.2c gates and results (gate level; written before the run: protocol P2R-E10.2c of 2026-11-11)")
    # ---- the netlist (E10.2a, cg), the logic netlist and its simulation copy
    bb = t2a._jload(os.path.join(W, "syn", "bb.json"))
    n0p = os.path.join(W, "syn", "n0.v")
    n0 = t2a._read(n0p)
    byt = bb.get("std_cells_by_type", {}) if bb else {}
    nff = sum(n for k, n in byt.items() if re.search(r"__(s?e?df|dl[xr])", k))
    nicg = sum(n for k, n in byt.items() if "dlclkp" in k)
    nbad = len(re.findall(r"sky130_fd_sc_hd__(?:lpflow|probe)", n0))
    nbb = len(bb.get("black_boxes", [])) if bb else 0
    same = os.path.isfile(n0p) and os.path.isfile(a.net) and t2a.md5(n0p) == t2a.md5(a.net)
    s1 = bool(bb) and same and nbad == 0 and nbb == 25 and nff == 375 and nicg >= 25 and \
        all(b["type"] == "sram_bank_128x8" for b in bb["black_boxes"])
    c = t2a._jload(os.path.join(W, "core.v.json"))
    cs = t2a._jload(os.path.join(W, "sim", "core_sim.v.json"))
    e1, c1 = bool(c and c.get("E1")), bool(cs and cs.get("C1"))
    out["design"] = {"S1": s1, "E1": e1, "C1": c1, "netlist": a.net, "netlist_md5": t2a.md5(n0p) if os.path.isfile(n0p) else None,
                     "same_as_E10.2a": same, "black_boxes": nbb, "flip_flops": nff, "clock_gates": nicg, "lpflow_probe": nbad,
                     "std_cells": bb.get("std_cells") if bb else None,
                     "clock_buffers_removed_for_simulation": cs.get("removed_buffers") if cs else None}
    print(f"   {'PASS' if s1 else 'FAIL'}  S1 netlist {a.net} (byte for byte: {same}): 25 bank black boxes, 375 flip-flops, "
          f"at least the 25 bank clock gates, no lpflow or probe cells ({nbb} black boxes, {nff} flip-flops, {nicg} clock "
          f"gates, {nbad} lpflow/probe; {out['design']['std_cells']} cells)")
    print(f"   {'PASS' if e1 else 'FAIL'}  E1 logic + wrapper = the synthesised netlist (e8_7_tools.py core)")
    print(f"   {'PASS' if c1 else 'FAIL'}  C1 only buffers on the clock net removed for simulation "
          f"({out['design']['clock_buffers_removed_for_simulation']} removed)")
    ok_all = ok_all and s1 and e1 and c1
    removed = set(re.findall(r"// E8\.7 clock-network cell removed for simulation: \S+ (\S+)",
                             t2a._read(os.path.join(W, "sim", "core_sim.v"))))
    names = cell_names(os.path.join(W, "names.tsv"))
    gname = {"G0": "compile: the synthesised pool (wrapper_sim.v, core_sim.v, cell models) in the unit without the "
                   "conv1 cache; no RTL pool, no cache",
             "G1": "ALL TESTS PASSED, inference complete at cycle 617573",
             "G2": "results, E8.2 and E8.5 traces, E8.5 events byte for byte the files of E8.5c (new / once)",
             "G3": "bank reads of the synthesised pool = those of its RTL run (part A); conce: the E8.5c SRAM reads",
             "W": "waveform from the edge that samples the start to the end of the run, the window of the power",
             "A1": "every pin annotated by the waveform except those of the cells removed for simulation"}
    for run in a.runs:
        R, M = run.split(":")
        D = os.path.join(W, "runs", f"{R}_{M}")
        g, info = {}, {}
        log = t2a._read(os.path.join(D, "sim.log"))
        deps = t2a._read(os.path.join(D, "deps.txt"))
        g["G0"] = ("wrapper_sim.v" in deps and "core_sim.v" in deps and "pcm_imc_unit_e10n.v" in deps
                   and "sram_bank_128x8.v" in deps and "e10_2a_vcd.v" in deps and "sky130_fd_sc_hd" in deps
                   and not re.search(r"conv1_cache\.v|sram_pool_25bank_2c(_cg)?\.v|sram_pool_25lane|pcm_imc_unit_e8[cs]?\.v|"
                                     r"pcm_imc_unit_e10\.v|rtl/src/pcm_imc_unit\.v", deps))
        g["G1"] = "RESULT: ALL TESTS PASSED" in log and "inference complete at cycle 617573" in log
        same_f = {}
        for f in ("res", "e8t", "e85t", "e85e"):
            p0 = os.path.join(D, f"{f}.txt")
            p1 = os.path.join(a.ref, f"{f}_{REFNAME[R]}_{M}.txt")
            same_f[f] = os.path.isfile(p0) and os.path.isfile(p1) and t2a.md5(p0) == t2a.md5(p1)
        g["G2"] = all(same_f.values())
        info["identical_to_E8.5c"] = same_f
        mg = t2a.POOL_GATE_RE.findall(log)
        rtl_log = os.path.join(a.rtl, f"sim_{R}_{M}.log")
        mr = t2a.POOL_RTL_RE.findall(t2a._read(rtl_log))
        info["bank_reads_gate"] = [int(x) for x in mg[-1]] if mg else None
        info["bank_reads_rtl"] = [int(x) for x in mr[-1][1:]] if mr else None
        info["lane_reads_rtl"] = int(mr[-1][0]) if mr else None
        g["G3"] = bool(mg and mr) and info["bank_reads_gate"] == info["bank_reads_rtl"] and \
            (R != "conce" or info["bank_reads_gate"][0] == READS_NC[M])
        mw = t2a.VCD_RE.findall(log)
        pw = t2a._jload(os.path.join(W, "power", f"{R}_{M}.json"))
        gw = False
        if mw:
            t0, n0x, t1, td, dc = float(mw[-1][0]), int(mw[-1][1]), float(mw[-1][2]), float(mw[-1][3]), int(mw[-1][4])
            info["window_sim_ns"] = [t0, t1]
            info["done_edge_ns"], info["done_cycle"] = td, dc
            gw = n0x == 0 and dc == 617573 and abs(td - (t0 + 10.0 * (dc + 1))) < 0.01 and abs(t1 - (td + 5.0)) < 0.01
            if pw:
                info["window_power_ns"] = pw.get("window_ns")
                gw = gw and abs(pw["window_ns"][0] - t0) < 0.5 and abs(pw["window_ns"][1] - t1) < 0.5
            else:
                gw = False
        g["W"] = gw
        t = t2a._read(os.path.join(W, "power", f"{R}_{M}_annotation.rpt"))
        nv = re.findall(r"^vcd\s+(\d+)", t, re.M)
        pins = re.findall(r"^ (\S+)$", t.split("Unannotated pins:")[-1], re.M) if "Unannotated pins:" in t else []
        cells = {p.rsplit("/", 1)[0] for p in pins if "/" in p}
        ports = [p for p in pins if "/" not in p]
        notrem = sorted(x for x in cells if x not in removed)
        info["annotation"] = {"vcd": int(nv[-1]) if nv else None, "unannotated_pins": len(pins),
                              "unannotated_not_removed": notrem[:20], "unannotated_ports": len(ports)}
        g["A1"] = bool(nv) and not notrem and not ports
        if pw:
            dur = pw["duration_ms"] * 1e6
            info["energy_uJ"] = pw["energy_uJ"].get("Total")
            info["power_mW"] = {k: round(x["total"] * 1e3, 6) for k, x in pw["groups_W"].items()}
            info["duration_ms"] = pw["duration_ms"]
            parts = collections.defaultdict(float)
            for mo in t2a.INST_POW_RE.finditer(t2a._read(os.path.join(W, "power", f"{R}_{M}_instances.rpt"))):
                parts[klass(names, mo.group(5))] += float(mo.group(4))
            info["energy_by_class_uJ"] = {k: round(x * dur * 1e-9 * 1e6, 6) for k, x in sorted(parts.items())}
            if a.lib:
                info["clock_root_net"] = t2a.clock_root(os.path.join(W, "core.v"), a.lib, 10.0, dur)
        out["runs"][run] = {"gates": g, "info": info}
        ok_all = ok_all and all(g.values())
        print(f"   ---- cg in the unit without the conv1 cache, {R}, model {M}")
        for k in ("G0", "G1", "G2", "G3", "W", "A1"):
            print(f"      {'PASS' if g[k] else 'FAIL'}  {k} {gname[k]}")
        print(f"         identical to E8.5c: {same_f}; bank reads (total, per bank min, max): gate level "
              f"{info['bank_reads_gate']}, RTL {info['bank_reads_rtl']} (lane reads {info['lane_reads_rtl']})")
        print(f"         window: run {info.get('window_sim_ns')} ns, done edge {info.get('done_edge_ns')} ns "
              f"(done_cycle {info.get('done_cycle')}), power {info.get('window_power_ns')}; annotation {info['annotation']}")
        if "energy_uJ" in info:
            pm = info["power_mW"]
            print(f"         pool logic: {info['energy_uJ']:.4f} uJ per inference over {info['duration_ms']:.6f} ms "
                  f"({pm.get('Total', 0):.4f} mW: sequential {pm.get('Sequential', 0):.4f}, combinational "
                  f"{pm.get('Combinational', 0):.4f}, clock {pm.get('Clock', 0):.4f})")
            print("         by class (uJ): " + ", ".join(f"{k} {x:.4f}" for k, x in info["energy_by_class_uJ"].items()))
            cr = info.get("clock_root_net")
            if cr and "C_pF" in cr:
                print(f"         not included (no clock tree, as E8.7): the clock net from the port to {cr['pins']}, "
                      f"pin capacitance {cr['C_pF']:.4f} pF, C V^2 per cycle over the window {cr['E_uJ_not_included']:.4f} uJ")
    # ---- for E10.2b (rule written before the run): cg, conce, without the conv1 cache; E10.2a (with it) next to it
    prev = t2a._jload(a.e10_2a) if a.e10_2a else None
    print("==== for E10.2b (rule written before the run): cg, conce, unit without the conv1 cache")
    for M in ("A", "B"):
        rc = out["runs"].get(f"conce:{M}")
        rk = out["runs"].get(f"cache:{M}")
        if rc and "energy_uJ" in rc["info"]:
            row = {"pool_logic_uJ": rc["info"]["energy_uJ"], "lane_reads": rc["info"]["lane_reads_rtl"]}
            if rk and "energy_uJ" in rk["info"]:
                row["cache_mode_uJ"] = rk["info"]["energy_uJ"]
            if prev and "paper" in prev and M in prev["paper"] and "cg_conce" in prev["paper"][M]:
                row["E10.2a_with_conv1_cache_uJ"] = prev["paper"][M]["cg_conce"]
                row["difference_uJ"] = round(row["pool_logic_uJ"] - row["E10.2a_with_conv1_cache_uJ"], 6)
            out["paper"][M] = row
            print(f"   model {M}: pool logic {row['pool_logic_uJ']:.4f} uJ per inference (conce; {row['lane_reads']} bank "
                  f"reads); cache mode {row.get('cache_mode_uJ', float('nan')):.4f}; E10.2a with the conv1 cache "
                  f"{row.get('E10.2a_with_conv1_cache_uJ', float('nan')):.4f} ({row.get('difference_uJ', float('nan')):+.4f})")
    out["all_pass"] = ok_all
    json.dump(out, open(a.out, "w"), indent=1)
    print(f"   {'ALL PASS' if ok_all else 'NOT ALL PASS'}; written {a.out}")
    return 0 if ok_all else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("judge")
    s.add_argument("--work", required=True, help="the work folder of the cg pool (syn/, core.v, sim/, runs/, power/)")
    s.add_argument("--net", required=True, help="the cg netlist of E10.2a (reports/e10/e10_2a/rtl_cg/bankpool_cg_sta.v)")
    s.add_argument("--ref", required=True, help="the E8.5c results (reports/e8_rom/e8_5c)")
    s.add_argument("--rtl", required=True, help="the RTL runs of part A (sim_<run>_<model>.log)")
    s.add_argument("--e10-2a", dest="e10_2a", default="", help="the E10.2a summary (e10_2a_summary.json), for comparison")
    s.add_argument("--lib", default="", help="the tt liberty (for the clock-net note)")
    s.add_argument("--runs", nargs="+", required=True)
    s.add_argument("--out", required=True)
    a = ap.parse_args()
    return {"judge": cmd_judge}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
