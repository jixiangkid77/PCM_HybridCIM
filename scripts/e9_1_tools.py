#!/usr/bin/env python3
"""
e9_1_tools.py   P2R-E9.1: gates and summary of the RTL runs with the address map of E9.

  judge   reads the logs, traces and event lists of the runs of scripts/e9_1_amu_rtl.sh, the
          tables of scripts/e9_1_tables.py and the synthesis statistics, checks the gates and
          writes e9_1_summary.json and e9_1_summary.txt

Gates (written before the runs, protocol P2R-E9.1 of 2026-11-11):
  T0  tables: every weight of both models decoded from the ROM image alone equals the E8.5 slot
      tables (0 differences); the image reads back; for model A the image equals the table of
      the E9.0 probe (8 words per row), if that file is given
  G0  (in the shell script) compile lists: the E9 unit, amu9_*, e9_rom, the clock-gated banked
      pool and the bank model; none of the E8.5 address map, the conv1 cache or another unit
  G1  every run: all tests passed, inference complete at cycle 617573
  G2  every run: results, E8.2 trace and E8.5 trace identical to E8.5c (new for the normal run,
      once for the read-once run)
  G3  every run, E9 monitor: stall cycles 0; error flags 000; slots different from the E8.5
      tables 0 (SRAM, PCM) over all lane lookups; ROM protocol errors 0; clock low before a
      lookup >= 9 cycles, before a parking read >= 5 cycles; parking reads without a zero bit
      to park 0; reads counted by the models = pulses of the event list
  G4  every run, banked pool: lane reads = bank reads, conflict cycles 0, address errors 0,
      deepest row < 128; read-once runs: lane reads = SRAM reads of E8.5c (267,143 / 205,664)
  S1  (if run) synthesis of amu9_top: yosys exit 0, 7 ROM macros as black boxes
Usage:
  python3 scripts/e9_1_tools.py judge --work <runs> --ref reports/e8_rom/e8_5c \
      --tables reports/e9/e9_1/tables/e9_1_tables.json [--e90 <E9.0 table of model A>] \
      [--syn <yosys output folder>] --out reports/e9/e9_1
"""
import argparse
import filecmp
import hashlib
import json
import os
import re
import sys

READS_ONCE = {"A": 267143, "B": 205664}          # SRAM reads per inference of E8.5c (no conv1 cache)
REFNAME = {"normal": "new", "once": "once"}
RUNS = [("normal", "A"), ("normal", "B"), ("once", "A"), ("once", "B")]


def md5(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()


def grab(pat, text, cast=int):
    m = re.search(pat, text)
    if not m:
        return None
    return [cast(x) if x is not None and re.fullmatch(r"-?\d+", x) else x for x in m.groups()]


def parse_sim(log):
    t = open(log, errors="replace").read()
    r = {"all_passed": "RESULT: ALL TESTS PASSED" in t,
         "complete_617573": "inference complete at cycle 617573" in t}
    v = grab(r"E10 POOL: lane reads (\d+), bank reads (\d+) \(per bank (\d+) to (\d+)\), conflict cycles (\d+), "
             r"address errors (\d+), deepest row (-?\d+)", t)
    r["pool"] = None if v is None else dict(zip(["lane_reads", "bank_reads", "per_bank_min", "per_bank_max",
                                                 "conflict_cycles", "address_errors", "deepest_row"], v))
    v = grab(r"datapath starts (\d+), SRAM reads (\d+)", t)
    r["e85c"] = None if v is None else {"datapath_starts": v[0], "sram_reads": v[1]}
    mon = {}
    v = grab(r"operations at the datapath start (\d+), engine start pulses (\d+)", t)
    if v:
        mon["operations"], mon["engine_starts"] = v
    v = grab(r"unit counters: starts (\d+), stall cycles (\d+), lookup pulses (\d+), parking pulses (\d+)", t)
    if v:
        mon.update(dict(zip(["unit_starts", "stall_cycles", "unit_lookups", "unit_parkings"], v)))
    v = grab(r"error flags \{queue,lane0,mismatch\} ([01]{3}); parking reads without a zero bit to park (\d+); "
             r"macros unparked at the end (\d+)", t, cast=str)
    if v:
        mon["error_flags"], mon["park_without_zero"], mon["unparked_at_end"] = v[0], int(v[1]), int(v[2])
    v = grab(r"ROM pulses in the event list: lookup (\d+), parking (\d+) \(before start (\d+), after done (\d+)\)", t)
    if v:
        mon.update(dict(zip(["ev_lookups", "ev_parkings", "ev_before_start", "ev_after_done"], v)))
    mon["macros"] = [dict(zip(["macro", "lookups", "parkings", "model_reads", "model_park_reads"], map(int, x)))
                     for x in re.findall(r"macro (\d): lookup (\d+), parking (\d+); model reads (\d+) \(parking word (\d+)\)", t)]
    v = grab(r"macro reads counted by the 7 models: (\d+) \((equal to the events|DIFFERENT from the events)\), "
             r"of them the parking word (\d+) \((equal|DIFFERENT)\)", t, cast=str)
    if v:
        mon["model_reads"], mon["model_reads_equal"] = int(v[0]), v[1] == "equal to the events"
        mon["model_park_reads"], mon["model_park_equal"] = int(v[2]), v[3] == "equal"
    v = grab(r"ROM protocol at the models: CS at the clock edge (\d+), address changed while high (\d+), "
             r"invalid word (\d+), shortest clock low before a read ([\d.]+) ns", t, cast=str)
    if v:
        mon["err_cs"], mon["err_addr"], mon["err_word"] = int(v[0]), int(v[1]), int(v[2])
        mon["model_low_min_ns"] = float(v[3])
    v = grab(r"shortest clock low before a lookup (\d+) cycles, before a parking read (\d+) cycles", t)
    if v:
        mon["low_min_lookup_cycles"], mon["low_min_park_cycles"] = v
    v = grab(r"slot check at (\d+) operations: (\d+) lane lookups \(SRAM (\d+), PCM (\d+)\); slots different from "
             r"the E8.5 tables: SRAM (\d+), PCM (\d+)", t)
    if v:
        mon.update(dict(zip(["chk_operations", "chk_lanes", "chk_sram", "chk_pcm", "bad_sram", "bad_pcm"], v)))
    r["monitor"] = mon
    return r


def judge(a):
    gates, lines = {}, []

    def gate(name, ok, detail):
        gates[name] = bool(ok)
        lines.append(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}")

    out = {"runs": {}, "tables": {}, "synthesis": None}
    tj = json.load(open(a.tables))
    for M in ("A", "B"):
        m = tj["models"][M]
        d = m["decode_differences"]
        ok = sum(d.values()) == 0 and m["image_reads_back"] and m["weights_decoded"] == 61470
        out["tables"][M] = {k: m[k] for k in ("entries", "macros", "image_words", "map_bits", "protected",
                                              "weights_decoded", "decode_differences", "bin_md5", "hex_md5")}
        out["tables"][M]["macro_zeros"] = m["macro_zeros"]
        gate(f"T0 model {M}: decoded weights equal the slot tables", ok,
             f"{m['weights_decoded']} weights, differences {d}, image reads back {m['image_reads_back']}, "
             f"{m['macros']} macros, {m['map_bits']} map bits")
    if a.e90:
        same = os.path.exists(a.e90) and md5(a.e90) == tj["models"]["A"]["bin_md5"]
        out["tables"]["A"]["equals_e9_0_table"] = same
        gate("T0 model A: image = the table of the E9.0 probe", same, a.e90)
    for R, M in RUNS:
        key = f"{R}_{M}"
        log = os.path.join(a.work, f"sim_{key}.log")
        if not os.path.exists(log):
            gate(f"G1 {key}", False, "no log")
            continue
        r = parse_sim(log)
        gate(f"G1 {key}: all tests passed, complete at cycle 617573", r["all_passed"] and r["complete_617573"],
             f"passed {r['all_passed']}, 617573 {r['complete_617573']}")
        cmp_ = {}
        for f in ("res", "e8t", "e85t"):
            p1 = os.path.join(a.work, f"{f}_{key}.txt")
            p0 = os.path.join(a.ref, f"{f}_{REFNAME[R]}_{M}.txt")
            cmp_[f] = os.path.exists(p1) and os.path.exists(p0) and filecmp.cmp(p1, p0, shallow=False)
        r["identical_to_e8_5c"] = cmp_
        gate(f"G2 {key}: results, E8.2 and E8.5 traces identical to E8.5c {REFNAME[R]}", all(cmp_.values()), str(cmp_))
        mon = r["monitor"]
        need = ["stall_cycles", "error_flags", "bad_sram", "bad_pcm", "err_cs", "err_addr", "err_word",
                "low_min_lookup_cycles", "low_min_park_cycles", "park_without_zero", "model_reads_equal", "chk_lanes"]
        ok = all(k in mon for k in need) and mon["stall_cycles"] == 0 and mon["error_flags"] == "000" and \
            mon["bad_sram"] == 0 and mon["bad_pcm"] == 0 and mon["chk_lanes"] > 0 and \
            mon["err_cs"] == 0 and mon["err_addr"] == 0 and mon["err_word"] == 0 and \
            mon["low_min_lookup_cycles"] >= 9 and mon["low_min_park_cycles"] >= 5 and \
            mon["park_without_zero"] == 0 and mon["model_reads_equal"] and mon.get("model_park_equal", False)
        gate(f"G3 {key}: E9 address map (stalls, errors, slots, ROM protocol, parking)", ok,
             f"stalls {mon.get('stall_cycles')}, flags {mon.get('error_flags')}, slot differences "
             f"{mon.get('bad_sram')}/{mon.get('bad_pcm')} of {mon.get('chk_lanes')} lane lookups, protocol "
             f"{mon.get('err_cs')}/{mon.get('err_addr')}/{mon.get('err_word')}, low before lookup "
             f"{mon.get('low_min_lookup_cycles')} / parking {mon.get('low_min_park_cycles')} cycles, parking without "
             f"zero {mon.get('park_without_zero')}, lookups {mon.get('ev_lookups')}, parkings {mon.get('ev_parkings')}")
        p = r["pool"]
        ok = p is not None and p["lane_reads"] == p["bank_reads"] and p["conflict_cycles"] == 0 and \
            p["address_errors"] == 0 and 0 <= p["deepest_row"] < 128
        if ok and R == "once":
            ok = p["lane_reads"] == READS_ONCE[M]
        gate(f"G4 {key}: banked pool", ok, str(p))
        evf = os.path.join(a.work, f"e9ev_{key}.txt")
        r["events_file"] = os.path.basename(evf)
        r["events_md5"] = md5(evf) if os.path.exists(evf) else None
        out["runs"][key] = r
    if a.syn:
        st = os.path.join(a.syn, "amu9_stat_final.txt")
        sta = os.path.join(a.syn, "amu9_sta.v")
        rc_f = os.path.join(a.syn, "yosys_rc.txt")
        s = {"rc": int(open(rc_f).read().strip()) if os.path.exists(rc_f) else None}
        if os.path.exists(st):
            t = open(st).read()
            v = re.findall(r"Chip area for (?:top )?module '\\?amu9_top':\s*([\d.]+)", t)
            s["area_um2"] = float(v[-1]) if v else None
            v = re.findall(r"of which used for sequential elements:\s*([\d.]+)", t)
            s["sequential_um2"] = float(v[-1]) if v else None
        if os.path.exists(sta):
            t = open(sta).read()
            s["rom_instances"] = len(re.findall(r"^\s*e9_rom\s", t, re.M))
            s["flip_flops"] = len(re.findall(r"sky130_fd_sc_hd__(?:s?e?dfx|s?e?dfr|s?e?dfs|dfbb|dfrb|dfsb|dfxb)\w*\s", t))
            s["icg"] = len(re.findall(r"sky130_fd_sc_hd__dlclkp_\d\s", t))
        out["synthesis"] = s
        gate("S1 synthesis of amu9_top (ROM macros as black boxes)",
             s.get("rc") == 0 and s.get("area_um2") is not None and s.get("rom_instances") == 7, str(s))
    out["gates"] = gates
    out["all_pass"] = all(gates.values())
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "e9_1_summary.json"), "w") as fh:
        json.dump(out, fh, indent=1)
    txt = lines + [("All gates pass" if out["all_pass"] else "NOT ALL GATES PASS")]
    with open(os.path.join(a.out, "e9_1_summary.txt"), "w") as fh:
        fh.write("\n".join(txt) + "\n")
    print("\n".join(txt))
    return 0 if out["all_pass"] else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    j = sub.add_parser("judge")
    j.add_argument("--work", required=True)
    j.add_argument("--ref", required=True)
    j.add_argument("--tables", required=True)
    j.add_argument("--e90", default="")
    j.add_argument("--syn", default="")
    j.add_argument("--out", required=True)
    a = ap.parse_args()
    if a.cmd == "judge":
        sys.exit(judge(a))


if __name__ == "__main__":
    main()
