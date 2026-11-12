#!/usr/bin/env python3
"""P2R-E9.4 tools (run by scripts/e9_4_amu_energy.sh).

  wrapper  completes the wrapper of the address-map unit written by scripts/e8_7_tools.py core (module
           amu9_top = the logic netlist + the 7 ROM models) for simulation only: it checks that the black
           boxes are the 7 ROM macros mac[m].U_ROM with MACRO = m, and adds a recorder of the read pulses
           of the 7 macros in the format of the E9.1 event list (rtl/e9/tb/e9_1_amu_monitor.v) without the
           entry and buffer-slot columns, which are internal to the logic netlist (+e9_events=<file>), and
           the "E9.4 ROM" line at the end (pulses; reads and protocol errors counted by the 7 models).
  judge    the gates of the gate-level runs of the synthesised address-map unit of E9.1 in the full
           inference (the rest RTL) and its logic energy per inference, by cell class and by part.
           Uses the helpers of scripts/e10_2a_tools.py (same folder, unchanged).
"""
import argparse
import collections
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e10_2a_tools as t2a          # noqa: E402  (md5, _read, _jload, INST_POW_RE, clock_root)

NM = 7
PARK_ADDR = 383
REFNAME = {"normal": "new", "once": "once"}        # the E8.5c runs with the same pool behaviour
READS_ONCE = {"A": 267143, "B": 205664}            # SRAM reads per inference of E8.5c (no conv1 cache)
POOL_RE = re.compile(r"^E10 POOL: lane reads (\d+), bank reads (\d+) \(per bank (\d+) to (\d+)\), conflict cycles (\d+), "
                     r"address errors (\d+), deepest row (\d+)", re.M)
E87_AMU = {"A": 9.871, "B": 9.717}                 # E8.7: the E8.5 address-map unit in the whole chip (uJ)
VCD_RE = re.compile(r"^E9\.4 VCD: from ([\d.]+) ns \(cycle_after_start (-?\d+)\) to ([\d.]+) ns \(end of the run\); "
                    r"done seen at (-?[\d.]+) ns \(done_cycle (-?\d+)\)", re.M)
ROM_RE = re.compile(r"^E9\.4 ROM: lookup pulses (\d+), parking pulses (\d+); model reads (\d+), parking word (\d+); "
                    r"protocol errors: CS at the clock edge (\d+), address changed while high (\d+), invalid word (\d+); "
                    r"shortest clock low before a read ([\d.e+-]+) ns", re.M)


# ------------------------------------------------------------------ wrapper
def macro_of(params):
    m = re.search(r"\.MACRO\(\s*(?:\d+'s?[dD])?(\d+)\s*\)", params or "")
    return int(m.group(1)) if m else None


def cmd_wrapper(a):
    bb = json.load(open(a.bb))
    w = open(a.inp).read()
    rom = {}
    for b in bb["black_boxes"]:
        m = re.fullmatch(r"mac\[(\d+)\]\.U_ROM", b["flat"])
        if b["type"] != "e9_rom" or not m:
            print(f"   FAIL: black box {b['flat']} ({b['type']}) is not a ROM macro of the address map")
            return 1
        k = int(m.group(1))
        if macro_of(b["params"]) != k:
            print(f"   FAIL: black box {b['flat']}: MACRO {macro_of(b['params'])} (parameters {b['params']!r})")
            return 1
        names = {p["name"] for p in b["ports"]}
        if not {"clk0", "cs0", "addr0", "dout0"} <= names:
            print(f"   FAIL: black box {b['flat']}: ports {sorted(names)}")
            return 1
        rom[k] = b
    if sorted(rom) != list(range(NM)):
        print(f"   FAIL: ROM macros found {sorted(rom)}, expected 0..{NM - 1}")
        return 1
    if w.count("endmodule") != 1 or "module amu9_top(" not in w:
        print("   FAIL: the wrapper is not one module amu9_top")
        return 1
    for k, b in rom.items():
        if not re.search(r"\be9_rom\b[^;]*\)\s*" + re.escape(b["inst"]) + r"\s*\(", w, re.S):
            print(f"   FAIL: ROM instance {b['inst']} not found in the wrapper")
            return 1
        for p in ("clk0", "addr0"):
            if not re.search(r"\bwire\b[^;]*\bbb%04d_%s\s*;" % (b["k"], p), w):
                print(f"   FAIL: wire bb{b['k']:04d}_{p} of ROM macro {k} not declared in the wrapper")
                return 1
    clk = "{" + ", ".join(f"bb{rom[k]['k']:04d}_clk0" for k in reversed(range(NM))) + "}"
    tb = "tb_lenet5_full_inference_v3"
    add = ["    // ---- P2R-E9.4, simulation only (scripts/e9_4_tools.py wrapper) ----",
           "    // The read pulses of the 7 ROM models in the format of the event list of E9.1",
           "    // (rtl/e9/tb/e9_1_amu_monitor.v) without its entry and buffer-slot columns, which are internal to",
           "    // the logic netlist; with +e9_events=<file>. A parking read is a read of address 383 (the lookups",
           "    // read addresses 0..382). Sampled at the falling clock edge, as the E9.1 monitor does:",
           "    //   L <phase> <cycle_after_start> <macro> <address, 3 hex digits> <clock-low cycles before the read>",
           "    //   P <phase> <cycle_after_start> <macro> <clock-low cycles before the read>",
           "    // (phase B before the start, I during the inference, A after done). At the end it prints the",
           "    // \"E9.4 ROM\" line: the pulses, and the reads and protocol errors counted by the 7 models.",
           "    reg  [8*512-1:0] e94_fn;",
           "    integer e94_fd = 0, e94_cyc = 0, e94_low, e94_k, e94_nl = 0, e94_np = 0;",
           f"    integer e94_lf [0:{NM - 1}];",
           f"    reg  [{NM - 1}:0] e94_q = {NM}'d0;",
           "    reg  e94_done = 1'b0;",
           "    reg  [7:0] e94_ph;",
           f"    wire [{NM - 1}:0] e94_clk = {clk};",
           f"    wire [8:0] e94_a [0:{NM - 1}];"]
    for k in range(NM):
        add.append(f"    assign e94_a[{k}] = bb{rom[k]['k']:04d}_addr0;   // {rom[k]['flat']}, {rom[k]['inst']}")
    add += ["    initial begin",
            f"        for (e94_k = 0; e94_k < {NM}; e94_k = e94_k + 1) e94_lf[e94_k] = -1;",
            '        if ($value$plusargs("e9_events=%s", e94_fn)) begin',
            '            e94_fd = $fopen(e94_fn, "w");',
            '            $fdisplay(e94_fd, "# P2R-E9.4 ROM clock pulses of the synthesised address-map unit (gate level)");',
            '            $fdisplay(e94_fd, "# L phase cycle macro addr_hex low_cycles   (lookup read)");',
            '            $fdisplay(e94_fd, "# P phase cycle macro low_cycles            (parking read of address 383)");',
            "        end",
            "    end",
            "    always @(negedge clk) begin",
            "        e94_cyc = e94_cyc + 1;",
            f"        if ({tb}.done_seen) e94_done = 1'b1;",
            f'        e94_ph = !{tb}.started_flag ? "B" : (e94_done ? "A" : "I");',
            f"        for (e94_k = 0; e94_k < {NM}; e94_k = e94_k + 1) begin",
            "            if (e94_clk[e94_k] && !e94_q[e94_k]) begin",
            "                e94_low = (e94_lf[e94_k] < 0) ? 99999 : e94_cyc - e94_lf[e94_k];",
            f"                if (e94_a[e94_k] == 9'd{PARK_ADDR}) begin",
            f'                    if (e94_fd) $fwrite(e94_fd, "P %0s %0d %0d %0d\\n", e94_ph, {tb}.cycle_after_start, e94_k, e94_low);',
            "                    e94_np = e94_np + 1;",
            "                end else begin",
            f'                    if (e94_fd) $fwrite(e94_fd, "L %0s %0d %0d %03h %0d\\n", e94_ph, {tb}.cycle_after_start, e94_k,',
            "                                        e94_a[e94_k], e94_low);",
            "                    e94_nl = e94_nl + 1;",
            "                end",
            "            end",
            "            if (!e94_clk[e94_k] && e94_q[e94_k]) e94_lf[e94_k] = e94_cyc;",
            "        end",
            "        e94_q = e94_clk;",
            "    end",
            "    real e94_lmin;",
            "    final begin",
            "        if (e94_fd) $fclose(e94_fd);",
            "        e94_lmin = 1.0e9;"]
    for k in range(NM):
        i = rom[k]["inst"]
        add.append(f"        if ({i}.n_reads != 0 && {i}.low_min < e94_lmin) e94_lmin = {i}.low_min;")
    s = lambda f: " + ".join(f"{rom[k]['inst']}.{f}" for k in range(NM))
    add += ['        $display("E9.4 ROM: lookup pulses %0d, parking pulses %0d; model reads %0d, parking word %0d; protocol errors: '
            'CS at the clock edge %0d, address changed while high %0d, invalid word %0d; shortest clock low before a read %0.1f ns",',
            f"                 e94_nl, e94_np, {s('n_reads')}, {s('n_park_reads')},",
            f"                 {s('n_err_cs')}, {s('n_err_addr')}, {s('n_err_word')}, e94_lmin);",
            "    end"]
    k = w.rindex("endmodule")
    out = w[:k] + "\n".join(add) + "\n" + w[k:]
    open(a.out, "w").write(out)
    shown = ", ".join("mac[%d]=%s" % (m, rom[m]["inst"]) for m in range(NM))
    print(f"   written {a.out} (md5 {t2a.md5(a.out)}): ROM event recorder and counts ({shown})")
    return 0


# ------------------------------------------------------------------ judge
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
        return "clock gates"
    if t.startswith("buf") and "insbuf" in orig:
        return "port buffers (stage 3)"
    return "combinational"


def part(names, inst):
    orig = names.get(inst, ("?", "?"))[0]
    for p in ("U_CORE", "U_DEC", "U_ENTRY", "U_LANES"):
        if orig.startswith(p + "."):
            return p
    return "top (entry buffer, ROM word select)"


def events(path, gate):
    """the read pulses of an event list as tuples; E9.1 lines lose the entry and slot columns"""
    ev = []
    for ln in open(path, errors="replace"):
        f = ln.split()
        if not f or f[0].startswith("#"):
            continue
        if f[0] == "L":
            ev.append(tuple(f[:5] + [f[5] if gate else f[7]]))
        elif f[0] == "P":
            ev.append(tuple(f[:5]))
    return ev


def cmd_judge(a):
    W = a.work
    out = {"design": {}, "runs": {}, "paper": {}}
    ok_all = True
    print("P2R-E9.4 gates and results (gate level; written before the run: protocol P2R-E9.4 of 2026-11-11)")
    bb = t2a._jload(os.path.join(W, "syn", "bb.json"))
    n0p = os.path.join(W, "syn", "n0.v")
    n0 = t2a._read(n0p)
    byt = bb.get("std_cells_by_type", {}) if bb else {}
    nff = sum(n for k, n in byt.items() if re.search(r"__(s?e?df|dl[xr])", k))
    nicg = sum(n for k, n in byt.items() if "dlclkp" in k)
    nbad = len(re.findall(r"sky130_fd_sc_hd__(?:lpflow|probe)", n0))
    bbs = bb.get("black_boxes", []) if bb else []
    roms = sorted(macro_of(b["params"]) for b in bbs if b["type"] == "e9_rom")
    same = os.path.isfile(n0p) and os.path.isfile(a.net) and t2a.md5(n0p) == t2a.md5(a.net)
    s1 = bool(bb) and same and nbad == 0 and len(bbs) == NM and roms == list(range(NM)) and nff > 0
    c = t2a._jload(os.path.join(W, "core.v.json"))
    cs = t2a._jload(os.path.join(W, "sim", "core_sim.v.json"))
    e1, c1 = bool(c and c.get("E1")), bool(cs and cs.get("C1"))
    area = re.findall(r"Chip area for (?:top )?module '\\?amu9_top':\s*([\d.]+)", t2a._read(a.stat))
    out["design"] = {"S1": s1, "E1": e1, "C1": c1, "netlist": a.net,
                     "netlist_md5": t2a.md5(n0p) if os.path.isfile(n0p) else None, "same_as_E9.1": same,
                     "black_boxes": len(bbs), "rom_macros": roms, "flip_flops": nff, "clock_gates": nicg,
                     "lpflow_probe": nbad, "std_cells": bb.get("std_cells") if bb else None,
                     "area_um2_E9.1": float(area[-1]) if area else None,
                     "clock_buffers_removed_for_simulation": cs.get("removed_buffers") if cs else None}
    print(f"   {'PASS' if s1 else 'FAIL'}  S1 netlist {a.net} (byte for byte the E9.1 netlist: {same}): 7 ROM black boxes "
          f"with MACRO 0..6 {roms}, no lpflow or probe cells ({nbad}); {out['design']['std_cells']} cells, {nff} flip-flops, "
          f"{nicg} clock gates; area {out['design']['area_um2_E9.1']} um2 (E9.1)")
    print(f"   {'PASS' if e1 else 'FAIL'}  E1 logic + wrapper = the synthesised netlist (e8_7_tools.py core)")
    print(f"   {'PASS' if c1 else 'FAIL'}  C1 only buffers on the clock net removed for simulation "
          f"({out['design']['clock_buffers_removed_for_simulation']} removed)")
    ok_all = ok_all and s1 and e1 and c1
    removed = set(re.findall(r"// E8\.7 clock-network cell removed for simulation: \S+ (\S+)",
                             t2a._read(os.path.join(W, "sim", "core_sim.v"))))
    names = cell_names(os.path.join(W, "names.tsv"))
    gname = {"G0": "compile: the synthesised unit (wrapper_sim.v, core_sim.v, cell models) and the ROM, pool and bank "
                   "models in the E9 unit; no RTL of the address map, no E8.5 address map, no conv1 cache",
             "G1": "ALL TESTS PASSED, inference complete at cycle 617573",
             "G2": "results, E8.2 and E8.5 traces byte for byte the files of E8.5c (new / once)",
             "G3": "every ROM read pulse (kind, phase, cycle, macro, address, clock-low cycles) = the E9.1 RTL event "
                   "list; model reads = pulses; ROM protocol errors 0",
             "G4": "banked pool: its line (lane and bank reads, per bank, conflicts, address errors, deepest row) "
                   "= that of the E9.1 RTL run; read-once: 267,143 / 205,664 reads (E8.5c)",
             "W": "waveform from the edge that samples the start to the end of the run, the window of the power",
             "A1": "every pin annotated by the waveform except those of the cells removed for simulation"}
    for run in a.runs:
        R, M = run.split(":")
        D = os.path.join(W, "runs", f"{R}_{M}")
        g, info = {}, {}
        log = t2a._read(os.path.join(D, "sim.log"))
        deps = t2a._read(os.path.join(D, "deps.txt"))
        g["G0"] = all(x in deps for x in ("wrapper_sim.v", "core_sim.v", "pcm_imc_unit_e9.v", "e9_rom.v",
                                            "sram_pool_25bank_2c_cg.v", "sram_bank_128x8.v", "e9_4_monitor.v",
                                            "sky130_fd_sc_hd")) and \
            not re.search(r"/(amu9_top|amu9_core|amu9_decode|amu_entry|amu_lanes|amu_top|amu_core|amu_table|amu_buf|"
                          r"amu_pflags|e8_rom_r48[a-z_]*|conv1_cache|sram_pool_25bank_2c|sram_pool_25lane[a-z0-9_]*|"
                          r"pcm_imc_unit|pcm_imc_unit_e8[a-z]*|pcm_imc_unit_e10[a-z]*)\.v$", deps, re.M)
        g["G1"] = "RESULT: ALL TESTS PASSED" in log and "inference complete at cycle 617573" in log
        same_f = {}
        for f in ("res", "e8t", "e85t"):
            p0 = os.path.join(D, f"{f}.txt")
            p1 = os.path.join(a.ref, f"{f}_{REFNAME[R]}_{M}.txt")
            same_f[f] = os.path.isfile(p0) and os.path.isfile(p1) and t2a.md5(p0) == t2a.md5(p1)
        g["G2"] = all(same_f.values())
        info["identical_to_E8.5c"] = same_f
        ev_g = events(os.path.join(D, "e9ev.txt"), True) if os.path.isfile(os.path.join(D, "e9ev.txt")) else None
        p_r = os.path.join(a.e91, f"e9ev_{R}_{M}.txt")
        ev_r = events(p_r, False) if os.path.isfile(p_r) else None
        mr = ROM_RE.findall(log)
        rom = None
        if mr:
            x = mr[-1]
            rom = {"lookup": int(x[0]), "parking": int(x[1]), "model_reads": int(x[2]), "model_parking_word": int(x[3]),
                   "err_cs": int(x[4]), "err_addr": int(x[5]), "err_word": int(x[6]), "low_min_ns": float(x[7])}
        info["rom"] = rom
        first_diff = None
        if ev_g is not None and ev_r is not None:
            for i, (u, v) in enumerate(zip(ev_g, ev_r)):
                if u != v:
                    first_diff = {"index": i, "gate": " ".join(u), "rtl": " ".join(v)}
                    break
            if first_diff is None and len(ev_g) != len(ev_r):
                first_diff = {"index": min(len(ev_g), len(ev_r)), "gate_events": len(ev_g), "rtl_events": len(ev_r)}
        info["events"] = {"gate": len(ev_g) if ev_g is not None else None, "rtl_E9.1": len(ev_r) if ev_r is not None else None,
                          "first_difference": first_diff}
        g["G3"] = ev_g is not None and ev_r is not None and first_diff is None and rom is not None and \
            rom["model_reads"] == rom["lookup"] + rom["parking"] == len(ev_g) and \
            rom["model_parking_word"] == rom["parking"] and rom["err_cs"] == rom["err_addr"] == rom["err_word"] == 0
        pg = POOL_RE.findall(log)
        pr = POOL_RE.findall(t2a._read(os.path.join(a.e91, f"sim_{R}_{M}.log")))
        info["pool_gate"] = [int(x) for x in pg[-1]] if pg else None
        info["pool_rtl_E9.1"] = [int(x) for x in pr[-1]] if pr else None
        g["G4"] = bool(pg and pr) and info["pool_gate"] == info["pool_rtl_E9.1"] and \
            info["pool_gate"][0] == info["pool_gate"][1] and info["pool_gate"][4] == 0 and \
            info["pool_gate"][5] == 0 and info["pool_gate"][6] < 128 and \
            (R != "once" or info["pool_gate"][0] == READS_ONCE[M])
        mw = VCD_RE.findall(log)
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
            by_c, by_p = collections.defaultdict(float), collections.defaultdict(float)
            for mo in t2a.INST_POW_RE.finditer(t2a._read(os.path.join(W, "power", f"{R}_{M}_instances.rpt"))):
                by_c[klass(names, mo.group(5))] += float(mo.group(4))
                by_p[part(names, mo.group(5))] += float(mo.group(4))
            info["energy_by_class_uJ"] = {k: round(x * dur * 1e-9 * 1e6, 6) for k, x in sorted(by_c.items())}
            info["energy_by_part_uJ"] = {k: round(x * dur * 1e-9 * 1e6, 6) for k, x in sorted(by_p.items())}
            if a.lib:
                info["clock_root_net"] = t2a.clock_root(os.path.join(W, "core.v"), a.lib, 10.0, dur)
        out["runs"][run] = {"gates": g, "info": info}
        ok_all = ok_all and all(g.values())
        print(f"   ---- the synthesised address-map unit of E9.1, {R}, model {M}")
        for k in ("G0", "G1", "G2", "G3", "G4", "W", "A1"):
            print(f"      {'PASS' if g[k] else 'FAIL'}  {k} {gname[k]}")
        print(f"         identical to E8.5c: {same_f}; ROM: {rom}; events {info['events']}")
        print(f"         pool (lane reads, bank reads, per bank min, max, conflicts, address errors, deepest row): "
              f"gate level {info['pool_gate']}, E9.1 RTL {info['pool_rtl_E9.1']}")
        print(f"         window: run {info.get('window_sim_ns')} ns, done edge {info.get('done_edge_ns')} ns "
              f"(done_cycle {info.get('done_cycle')}), power {info.get('window_power_ns')}; annotation {info['annotation']}")
        if "energy_uJ" in info:
            pm = info["power_mW"]
            print(f"         address-map logic: {info['energy_uJ']:.4f} uJ per inference over {info['duration_ms']:.6f} ms "
                  f"({pm.get('Total', 0):.4f} mW: sequential {pm.get('Sequential', 0):.4f}, combinational "
                  f"{pm.get('Combinational', 0):.4f}, clock {pm.get('Clock', 0):.4f})")
            print("         by class (uJ): " + ", ".join(f"{k} {x:.4f}" for k, x in info["energy_by_class_uJ"].items()))
            print("         by part (uJ): " + ", ".join(f"{k} {x:.4f}" for k, x in info["energy_by_part_uJ"].items()))
            cr = info.get("clock_root_net")
            if cr and "C_pF" in cr:
                print(f"         not included (no clock tree, as E8.7): the clock net from the port to {cr['pins']}, "
                      f"pin capacitance {cr['C_pF']:.4f} pF, C V^2 per cycle over the window {cr['E_uJ_not_included']:.4f} uJ")
    # ---- for E9.5 (rule written before the run): the read-once runs (the configuration of the SRAM reads of E10.2b)
    print("==== for E9.5 (rule written before the run): the read-once runs; the normal runs next to them")
    for M in ("A", "B"):
        ro, rn = out["runs"].get(f"once:{M}"), out["runs"].get(f"normal:{M}")
        if ro and "energy_uJ" in ro["info"]:
            row = {"amu_logic_uJ": ro["info"]["energy_uJ"], "E8.7_amu_uJ": E87_AMU[M],
                   "difference_uJ": round(ro["info"]["energy_uJ"] - E87_AMU[M], 6),
                   "area_um2": out["design"]["area_um2_E9.1"]}
            if rn and "energy_uJ" in rn["info"]:
                row["normal_run_uJ"] = rn["info"]["energy_uJ"]
            out["paper"][M] = row
            print(f"   model {M}: address-map logic {row['amu_logic_uJ']:.4f} uJ per inference (read-once run); normal run "
                  f"{row.get('normal_run_uJ', float('nan')):.4f}; E8.7, the E8.5 unit in the whole chip, {E87_AMU[M]:.3f} "
                  f"({row['difference_uJ']:+.4f}); logic area {row['area_um2']} um2")
    out["all_pass"] = ok_all
    json.dump(out, open(a.out, "w"), indent=1)
    print(f"   {'ALL PASS' if ok_all else 'NOT ALL PASS'}; written {a.out}")
    return 0 if ok_all else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("wrapper")
    s.add_argument("--bb", required=True, help="bb.json of e8_7_tools.py stage3")
    s.add_argument("--in", dest="inp", required=True, help="the wrapper of e8_7_tools.py core")
    s.add_argument("--out", required=True)
    s = sp.add_parser("judge")
    s.add_argument("--work", required=True, help="the work folder (syn/, core.v, sim/, runs/, power/)")
    s.add_argument("--net", required=True, help="the E9.1 netlist (reports/e9/e9_1/syn/amu9_sta.v)")
    s.add_argument("--stat", required=True, help="its statistics (reports/e9/e9_1/syn/amu9_stat_final.txt)")
    s.add_argument("--ref", required=True, help="the E8.5c results (reports/e8_rom/e8_5c)")
    s.add_argument("--e91", required=True, help="the E9.1 event lists (reports/e9/e9_1/rtl)")
    s.add_argument("--lib", default="", help="the tt liberty (for the clock-net note)")
    s.add_argument("--runs", nargs="+", required=True)
    s.add_argument("--out", required=True)
    a = ap.parse_args()
    return {"wrapper": cmd_wrapper, "judge": cmd_judge}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
