#!/usr/bin/env python3
"""P2R-E10.2a tools (run by scripts/e10_2a_pool_energy.sh).

  wrapper  completes the wrapper of the banked pool written by scripts/e8_7_tools.py core (module
           sram_pool_25bank_2c = the logic netlist + the 25 bank models) with what the full-inference run
           reads from the RTL pool, for simulation only: the pool image sram_pool_mem loaded from DATA_DIR
           (the E8.5e monitor reads it) and the contents of the bank models (bank b, row r = pool word
           r * 25 + b, loaded at 1 ns as rtl/e10/sram_pool_25bank_2c.v does); and it counts the reads of
           every bank (chip select low at a rising edge of the clock out of reset, the count of the
           "E10 POOL" line of the RTL pool) and prints them at the end ("E10.2a POOL").
  judge    the gates of the gate-level runs of both pools (ng: the E10.0 pool; cg: the pool with clock
           gating) and the energy of the pool logic per inference (summary).
"""
import argparse
import hashlib
import json
import os
import re
import sys


def md5(p):
    h = hashlib.md5()
    with open(p, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def _read(p):
    try:
        return open(p, errors="replace").read()
    except OSError:
        return ""


def _jload(p):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return None


# ------------------------------------------------------------------ wrapper
def cmd_wrapper(a):
    bb = json.load(open(a.bb))
    w = open(a.inp).read()
    banks = {}
    for b in bb["black_boxes"]:
        m = re.fullmatch(r"BANK\[(\d+)\]\.U_BANK", b["flat"])
        if b["type"] != "sram_bank_128x8" or not m:
            print(f"   FAIL: black box {b['flat']} ({b['type']}) is not a bank of the pool")
            return 1
        banks[int(m.group(1))] = b["inst"]
    if sorted(banks) != list(range(25)):
        print(f"   FAIL: banks found {sorted(banks)}, expected 0..24")
        return 1
    if w.count("endmodule") != 1 or "module sram_pool_25bank_2c(" not in w:
        print("   FAIL: the wrapper is not one module sram_pool_25bank_2c")
        return 1
    for p in ("DATA_DIR", "SRAM_TOTAL", "DATA_WIDTH"):
        if not re.search(r"^\s*parameter " + p + r"\b", w, re.M):
            print(f"   FAIL: parameter {p} not declared in the wrapper")
            return 1
    for b, inst in banks.items():
        if not re.search(r"\bsram_bank_128x8\b[^;]*\)\s*" + inst + r"\s*\(", w, re.S):
            print(f"   FAIL: bank instance {inst} not found in the wrapper")
            return 1
    add = ["    // ---- P2R-E10.2a, simulation only (scripts/e10_2a_tools.py wrapper) ----",
           "    // the pool image of rtl/e10/sram_pool_25bank_2c.v (read by the E8.5e monitor) and the contents of",
           "    // the bank models: bank b holds pool word r * 25 + b in row r, loaded at 1 ns as in the RTL pool",
           "    reg signed [DATA_WIDTH-1:0] sram_pool_mem [0:SRAM_TOTAL-1];",
           "    integer e10_p, e10_r;",
           "    initial begin",
           "        for (e10_p = 0; e10_p < SRAM_TOTAL; e10_p = e10_p + 1) sram_pool_mem[e10_p] = {DATA_WIDTH{1'b0}};",
           '        if (DATA_DIR != "") $readmemh({DATA_DIR, "/sram_pool.hex"}, sram_pool_mem);',
           "        #1;",
           "        for (e10_r = 0; e10_r < 128; e10_r = e10_r + 1) begin"]
    for b in range(25):
        add.append(f"            if (e10_r * 25 + {b} < SRAM_TOTAL) {banks[b]}.mem[e10_r] = sram_pool_mem[e10_r * 25 + {b}];"
                   f"   // BANK[{b}].U_BANK")
    add += ["        end",
            "    end",
            "    // reads of every bank: chip select low at a rising edge of the clock out of reset (the count of",
            "    // the \"E10 POOL\" line of the RTL pool), printed at the end of the run",
            "    integer e10_reads [0:24];",
            "    integer e10_k, e10_n, e10_lo, e10_hi;",
            "    initial for (e10_k = 0; e10_k < 25; e10_k = e10_k + 1) e10_reads[e10_k] = 0;",
            "    always @(posedge clk) begin",
            "        if (rst_n) begin"]
    for b in range(25):
        add.append(f"            if ({banks[b]}.csb === 1'b0) e10_reads[{b}] = e10_reads[{b}] + 1;   // BANK[{b}].U_BANK")
    add += ["        end",
            "    end",
            "    final begin",
            "        e10_n = 0; e10_lo = e10_reads[0]; e10_hi = e10_reads[0];",
            "        for (e10_k = 0; e10_k < 25; e10_k = e10_k + 1) begin",
            "            e10_n = e10_n + e10_reads[e10_k];",
            "            if (e10_reads[e10_k] < e10_lo) e10_lo = e10_reads[e10_k];",
            "            if (e10_reads[e10_k] > e10_hi) e10_hi = e10_reads[e10_k];",
            "        end",
            '        $display("E10.2a POOL: bank reads %0d (per bank %0d to %0d)", e10_n, e10_lo, e10_hi);',
            "    end"]
    k = w.rindex("endmodule")
    out = w[:k] + "\n".join(add) + "\n" + w[k:]
    open(a.out, "w").write(out)
    print(f"   written {a.out} (md5 {md5(a.out)}): pool image, contents of the 25 banks, bank-read count "
          f"({', '.join(f'BANK[{b}]={banks[b]}' for b in (0, 1, 24))}, ...)")
    return 0


# ------------------------------------------------------------------ judge
POOL_RTL_RE = re.compile(r"^E10 POOL: lane reads (\d+), bank reads (\d+) \(per bank (\d+) to (\d+)\)", re.M)
POOL_GATE_RE = re.compile(r"^E10\.2a POOL: bank reads (\d+) \(per bank (\d+) to (\d+)\)", re.M)
VCD_RE = re.compile(r"^E10\.2a VCD: from ([\d.]+) ns \(cycle_after_start (-?\d+)\) to ([\d.]+) ns \(end of the run\); "
                    r"done seen at (-?[\d.]+) ns \(done_cycle (-?\d+)\)", re.M)
INST_POW_RE = re.compile(r"^\s*([-\d.eE+]+)\s+([-\d.eE+]+)\s+([-\d.eE+]+)\s+([-\d.eE+]+)\s+(\S+)\s*$", re.M)
CELL_RE = re.compile(r"^\s*(sky130_fd_sc_hd__\w+)\s+(\S+)\s*\((.*?)\);", re.M | re.S)
PIN_RE = re.compile(r"\.(\w+)\(\s*([^()]*?)\s*\)")
READS = {"A": 149543, "B": 88064}
VARIANT_NAME = {"ng": "E10.0 pool (no clock gating)", "cg": "pool with clock gating"}


def liberty_pin_caps(lib, wanted):
    """capacitance (pF) of the pins (cell, pin) in wanted, from the liberty text"""
    t = open(lib, errors="replace").read()
    caps = {}
    for cell, pin in wanted:
        i = t.find(f'cell ("{cell}")')
        if i < 0:
            continue
        j = t.find("cell (", i + 10)
        c = t[i:j if j > 0 else len(t)]
        k = c.find(f'pin ("{pin}")')
        if k < 0:
            continue
        m = re.search(r"\bcapacitance\s*:\s*([\d.eE+-]+)", c[k:k + 4000])
        if m:
            caps[(cell, pin)] = float(m.group(1))
    v = re.search(r"nom_voltage\s*:\s*([\d.]+)", t)
    return caps, (float(v.group(1)) if v else None)


def clock_root(core_v, lib, period_ns, dur_ns):
    """pins on the clock port net of the logic netlist and their capacitance from the liberty: the switching
    of this net (driven by the port, no clock tree) is not part of report_power"""
    pins = {}
    for mo in CELL_RE.finditer(open(core_v, errors="replace").read()):
        for p, net in PIN_RE.findall(mo.group(3)):
            if net == "clk":
                pins[(mo.group(1), p)] = pins.get((mo.group(1), p), 0) + 1
    caps, vdd = liberty_pin_caps(lib, list(pins))
    if len(caps) != len(pins) or vdd is None:
        return {"pins": {f"{c}/{p}": n for (c, p), n in pins.items()}, "error": "capacitance not found"}
    c_pf = sum(n * caps[k] for k, n in pins.items())
    e_uj = c_pf * 1e-12 * vdd * vdd * (dur_ns / period_ns) * 1e6     # C V^2 per clock period (2 transitions)
    return {"pins": {f"{c}/{p}": n for (c, p), n in pins.items()},
            "pin_cap_pF": {f"{c}/{p}": v for (c, p), v in caps.items()},
            "C_pF": round(c_pf, 6), "V": vdd, "E_uJ_not_included": round(e_uj, 6)}


def judge_design(a, v):
    """S1, E1, C1 of one pool netlist"""
    W = os.path.join(a.work, v)
    bb = _jload(os.path.join(W, "syn", "bb.json"))
    n0p = os.path.join(W, "syn", "n0.v")
    n0 = _read(n0p)
    src = a.net_ng if v == "ng" else a.net_cg
    stat = a.stat_ng if v == "ng" else a.stat_cg
    nbad = len(re.findall(r"sky130_fd_sc_hd__(?:lpflow|probe)", n0))
    byt = bb.get("std_cells_by_type", {}) if bb else {}
    nff = sum(n for k, n in byt.items() if re.search(r"__(s?e?df|dl[xr])", k))
    nicg = sum(n for k, n in byt.items() if "dlclkp" in k)
    nbb = len(bb.get("black_boxes", [])) if bb else 0
    same_net = os.path.isfile(n0p) and os.path.isfile(src) and md5(n0p) == md5(src)
    s1 = bool(bb) and same_net and nbad == 0 and nbb == 25 and nff == 375 and \
        all(b["type"] == "sram_bank_128x8" for b in bb["black_boxes"]) and (nicg == 0 if v == "ng" else nicg >= 25)
    area = re.findall(r"Chip area for (?:top )?module '\\?\S+?': ([\d.]+)", _read(stat))
    c = _jload(os.path.join(W, "core.v.json"))
    cs = _jload(os.path.join(W, "sim", "core_sim.v.json"))
    d = {"S1": s1, "E1": bool(c and c.get("E1")), "C1": bool(cs and cs.get("C1")),
         "netlist": src, "netlist_md5": md5(n0p) if os.path.isfile(n0p) else None, "same_as_source": same_net,
         "black_boxes": nbb, "lpflow_probe": nbad, "flip_flops": nff, "clock_gates": nicg,
         "std_cells": bb.get("std_cells") if bb else None, "area_logic_um2": float(area[-1]) if area else None,
         "cells_core": c.get("cells") if c else None,
         "clock_buffers_removed_for_simulation": cs.get("removed_buffers") if cs else None,
         "removed_by_type": cs.get("removed_by_type") if cs else None,
         "clock_gates_on_the_clock_net": cs.get("clock_gates") if cs else None}
    return d


def judge_run(a, v, R, M, removed):
    W = os.path.join(a.work, v)
    D = os.path.join(W, "runs", f"{R}_{M}")
    g, info = {}, {}
    log = _read(os.path.join(D, "sim.log"))
    deps = _read(os.path.join(D, "deps.txt"))
    g["G0"] = ("wrapper_sim.v" in deps and "core_sim.v" in deps and "pcm_imc_unit_e10.v" in deps
               and "sram_bank_128x8.v" in deps and "e10_2a_vcd.v" in deps and "sky130_fd_sc_hd" in deps
               and not re.search(r"sram_pool_25bank_2c(_cg)?\.v|sram_pool_25lane|pcm_imc_unit_e8c\.v|"
                                 r"rtl/src/pcm_imc_unit\.v", deps))
    g["G1"] = "RESULT: ALL TESTS PASSED" in log and "inference complete at cycle 617573" in log
    same = {}
    for f in ("res", "e8t", "e85t", "e85e"):
        p0 = os.path.join(D, f"{f}.txt")
        p1 = os.path.join(a.ref, f"{f}_{R}_{M}.txt")
        same[f] = os.path.isfile(p0) and os.path.isfile(p1) and md5(p0) == md5(p1)
    g["G2"] = all(same.values())
    info["identical_to_E8.5e"] = same
    mg = POOL_GATE_RE.findall(log)
    rtl_log = os.path.join(a.e10, f"sim_{R}_{M}.log") if v == "ng" else os.path.join(a.rtl_cg, f"sim_{R}_{M}.log")
    mr = POOL_RTL_RE.findall(_read(rtl_log))
    info["bank_reads_gate"] = [int(x) for x in mg[-1]] if mg else None
    info["bank_reads_rtl"] = [int(x) for x in mr[-1][1:]] if mr else None
    info["bank_reads_rtl_log"] = rtl_log
    g["G3"] = bool(mg and mr) and info["bank_reads_gate"] == info["bank_reads_rtl"] and \
        (R != "conce" or info["bank_reads_gate"][0] == READS[M])
    mw = VCD_RE.findall(log)
    pw = _jload(os.path.join(W, "power", f"{R}_{M}.json"))
    gw = False
    if mw:
        t0, n0x, t1, td, dc = float(mw[-1][0]), int(mw[-1][1]), float(mw[-1][2]), float(mw[-1][3]), int(mw[-1][4])
        info["window_sim_ns"] = [t0, t1]
        info["done_edge_ns"] = td
        info["done_cycle"] = dc
        gw = n0x == 0 and dc == 617573 and abs(td - (t0 + 10.0 * (dc + 1))) < 0.01 and abs(t1 - (td + 5.0)) < 0.01
        if pw:
            info["window_power_ns"] = pw.get("window_ns")
            gw = gw and abs(pw["window_ns"][0] - t0) < 0.5 and abs(pw["window_ns"][1] - t1) < 0.5
        else:
            gw = False
    g["W"] = gw
    # A1 as E8.7: every pin annotated except those of the cells removed for simulation; every port annotated
    t = _read(os.path.join(W, "power", f"{R}_{M}_annotation.rpt"))
    nv = re.findall(r"^vcd\s+(\d+)", t, re.M)
    pins = re.findall(r"^ (\S+)$", t.split("Unannotated pins:")[-1], re.M) if "Unannotated pins:" in t else []
    cells = {p.rsplit("/", 1)[0] for p in pins if "/" in p}
    ports = [p for p in pins if "/" not in p]
    notrem = sorted(x for x in cells if x not in removed)
    info["annotation"] = {"vcd": int(nv[-1]) if nv else None, "unannotated_pins": len(pins),
                          "unannotated_cells": len(cells), "unannotated_ports": len(ports),
                          "unannotated_not_removed": notrem[:20]}
    g["A1"] = bool(nv) and not notrem and not ports
    if pw:
        dur = pw["duration_ms"] * 1e6
        info["energy_uJ"] = pw["energy_uJ"].get("Total")
        info["energy_by_group_uJ"] = {k: round(x, 6) for k, x in pw["energy_uJ"].items() if k != "Total"}
        info["power_mW"] = {k: round(x["total"] * 1e3, 6) for k, x in pw["groups_W"].items()}
        info["duration_ms"] = pw["duration_ms"]
        rem_w, icg_w, n_inst = 0.0, 0.0, 0
        icgs = set(a._icg.get(v, ()))
        for mo in INST_POW_RE.finditer(_read(os.path.join(W, "power", f"{R}_{M}_instances.rpt"))):
            n_inst += 1
            if mo.group(5) in removed:
                rem_w += float(mo.group(4))
            if mo.group(5) in icgs:
                icg_w += float(mo.group(4))
        info["energy_removed_clock_buffers_uJ"] = round(rem_w * dur * 1e-9 * 1e6, 6)
        info["energy_clock_gates_uJ"] = round(icg_w * dur * 1e-9 * 1e6, 6)
        info["instances_in_report"] = n_inst
        if a.lib:
            info["clock_root_net"] = clock_root(os.path.join(W, "core.v"), a.lib, 10.0, dur)
    return g, info


def cmd_judge(a):
    out = {"design": {}, "runs": {}, "paper": {}}
    ok_all = True
    print("P2R-E10.2a gates and results (gate level; written before the run: protocol P2R-E10.2a of 2026-11-10)")
    names = {"G0": "compile: the synthesised pool (wrapper_sim.v, core_sim.v, cell models), not an RTL pool",
             "G1": "ALL TESTS PASSED, inference complete at cycle 617573",
             "G2": "results, E8.2 and E8.5 traces, E8.5e events byte for byte the files of E8.5e",
             "G3": "bank reads of the synthesised pool = those of its RTL run (total, per bank min, max)",
             "W": "waveform from the edge that samples the start to the end of the run, the window of the power",
             "A1": "every pin annotated by the waveform except those of the cells removed for simulation"}
    a._icg = {}
    for v in a.variants:
        d = judge_design(a, v)
        out["design"][v] = d
        W = os.path.join(a.work, v)
        removed = set(re.findall(r"// E8\.7 clock-network cell removed for simulation: \S+ (\S+)",
                                 _read(os.path.join(W, "sim", "core_sim.v"))))
        a._icg[v] = [mo.group(2) for mo in CELL_RE.finditer(_read(os.path.join(W, "core.v")))
                     if "dlclkp" in mo.group(1)]
        print(f"==== {v}: {VARIANT_NAME[v]}")
        print(f"   {'PASS' if d['S1'] else 'FAIL'}  S1 netlist {d['netlist']} (byte for byte: {d['same_as_source']}): "
              f"25 bank black boxes, 375 flip-flops, no lpflow or probe cells, "
              f"{'no clock gate' if v == 'ng' else 'at least the 25 bank clock gates'} ({d['black_boxes']} black "
              f"boxes, {d['flip_flops']} flip-flops, {d['clock_gates']} clock gates, {d['lpflow_probe']} lpflow/probe; "
              f"{d['std_cells']} cells; logic area {d['area_logic_um2']} um2)")
        print(f"   {'PASS' if d['E1'] else 'FAIL'}  E1 logic + wrapper = the synthesised netlist (e8_7_tools.py core)")
        print(f"   {'PASS' if d['C1'] else 'FAIL'}  C1 only buffers on the clock net removed for simulation "
              f"({d['clock_buffers_removed_for_simulation']} {d['removed_by_type']}; clock gates on the clock net "
              f"{d['clock_gates_on_the_clock_net']})")
        ok_all = ok_all and d["S1"] and d["E1"] and d["C1"]
        for run in a.runs:
            R, M = run.split(":")
            g, info = judge_run(a, v, R, M, removed)
            out["runs"][f"{v}:{run}"] = {"gates": g, "info": info}
            ok_all = ok_all and all(g.values())
            print(f"   ---- {v}, {R}, model {M}")
            for k in ("G0", "G1", "G2", "G3", "W", "A1"):
                print(f"      {'PASS' if g[k] else 'FAIL'}  {k} {names[k]}")
            print(f"         identical to E8.5e: {info['identical_to_E8.5e']}; bank reads (total, per bank min, max): "
                  f"gate level {info['bank_reads_gate']}, RTL {info['bank_reads_rtl']}")
            print(f"         window: run {info.get('window_sim_ns')} ns, done edge {info.get('done_edge_ns')} ns "
                  f"(done_cycle {info.get('done_cycle')}), power {info.get('window_power_ns')}; "
                  f"annotation {info['annotation']}")
            if "energy_uJ" in info:
                pm = info["power_mW"]
                print(f"         pool logic: {info['energy_uJ']:.4f} uJ per inference over {info['duration_ms']:.6f} ms "
                      f"({pm.get('Total', 0):.4f} mW: sequential {pm.get('Sequential', 0):.4f}, combinational "
                      f"{pm.get('Combinational', 0):.4f}, clock {pm.get('Clock', 0):.4f}); of which "
                      f"{len(removed)} buffers to the bank clocks {info['energy_removed_clock_buffers_uJ']:.4f} uJ, "
                      f"{len(a._icg[v])} clock gates {info['energy_clock_gates_uJ']:.4f} uJ")
                cr = info.get("clock_root_net")
                if cr and "C_pF" in cr:
                    print(f"         not included (no clock tree, as E8.7): the clock net from the port to {cr['pins']}, "
                          f"pin capacitance {cr['C_pF']:.4f} pF, C V^2 per cycle over the window "
                          f"{cr['E_uJ_not_included']:.4f} uJ")
    # ---- the paper (rule written before the run): the pool with clock gating, conce; the rest next to it
    print("==== for the paper (rule written before the run): cg, conce; ng and cache next to it")
    for M in ("A", "B"):
        row = {}
        for v in a.variants:
            for R in ("conce", "cache"):
                r = out["runs"].get(f"{v}:{R}:{M}")
                if r and "energy_uJ" in r["info"]:
                    row[f"{v}_{R}"] = r["info"]["energy_uJ"]
        out["paper"][M] = row
        if "cg_conce" in row:
            print(f"   model {M}: pool logic {row['cg_conce']:.4f} uJ per inference (cg, conce); "
                  + ", ".join(f"{k} {x:.4f}" for k, x in row.items() if k != "cg_conce"))
    out["all_pass"] = ok_all
    json.dump(out, open(a.out, "w"), indent=1)
    print(f"   {'ALL PASS' if ok_all else 'NOT ALL PASS'}; written {a.out}")
    return 0 if ok_all else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("wrapper")
    s.add_argument("--bb", required=True)
    s.add_argument("--in", dest="inp", required=True)
    s.add_argument("--out", required=True)
    s = sp.add_parser("judge")
    s.add_argument("--work", required=True, help="the work folder (one folder per pool: ng, cg)")
    s.add_argument("--variants", nargs="+", default=["ng", "cg"], choices=["ng", "cg"])
    s.add_argument("--ref", required=True, help="the E8.5e results (reports/e8_rom/e8_5e)")
    s.add_argument("--e10", required=True, help="the E10.0 results (reports/e10/e10_0): RTL runs of ng")
    s.add_argument("--rtl-cg", dest="rtl_cg", required=True, help="the RTL runs of cg (part A of this run)")
    s.add_argument("--net-ng", dest="net_ng", required=True, help="the netlist of ng (E10.0)")
    s.add_argument("--net-cg", dest="net_cg", required=True, help="the netlist of cg (part A of this run)")
    s.add_argument("--stat-ng", dest="stat_ng", required=True)
    s.add_argument("--stat-cg", dest="stat_cg", required=True)
    s.add_argument("--lib", default="", help="the tt liberty (for the clock-net note)")
    s.add_argument("--runs", nargs="+", required=True)
    s.add_argument("--out", required=True)
    a = ap.parse_args()
    return {"wrapper": cmd_wrapper, "judge": cmd_judge}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
