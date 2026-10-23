#!/usr/bin/env python3
"""
e8_5c_check.py   (P2R-E8.5c)

Gate checks of the E8.5c runs (scripts/e8_5c_sram2c.sh): the two-cycle SRAM
read (rtl/e8/sram_pool_25lane_2c.v, pcm_imc_unit_e8s.v; SRAM_LATENCY, the
combiner and lenet5_top unchanged) against the E8.5 design. Exit status 0 = all pass.

  unit  --log LOG
      U1  sram_pool_25lane_2c against rtl/src/sram_pool_25lane one cycle
          earlier: at least 200000 cycles compared, the sweep read every one
          of the 3074 addresses on all 25 lanes (76850 lane reads), reset
          check 0 bad, 0 mismatches

  full  --model M --work DIR --e82-trace T --e85-dir DIR [--fake-data]
      Runs (files in --work, written by e8_5c_sram2c.sh):
        base  the E8.5 design (rtl/e8/pcm_imc_unit_e8.v,
              rtl/src/sram_pool_25lane.v)
        new   the two-cycle SRAM read (rtl/e8/pcm_imc_unit_e8s.v,
              rtl/e8/sram_pool_25lane_2c.v)
        once  the two-cycle SRAM read, pool read only in the cycle of the
              datapath start (-DE85C_READ_ONCE)
      F0  compile file lists: base uses pcm_imc_unit_e8.v and rtl/src
          sram_pool_25lane.v and none of the two new files; new and once
          use the two new files and none of rtl/src pcm_imc_unit.v,
          sram_pool_25lane.v and rtl/e8/pcm_imc_unit_e8.v; all three use
          rtl/src/lenet5_top.v; all other files identical to base
      F1  every run: ALL TESTS PASSED, inference complete at cycle 617573,
          SRAM reads 267143 (A) / 205664 (B)
      F2  base, E8.2 monitor trace = E8.2 trace (reports/e8_rom/trace);
          new and once, E8.2 monitor trace = base (with the done line)
      F3  E8.5 monitor trace and ROM events: new and once = base; base = the
          files of E8.5 (reports/e8_rom/e8_5)
      F4  results of the unit (cycle and value of every result_valid):
          new = base and once = base, line by line; 16684 results; in
          every run each result comes 10 cycles after its datapath start
          (SRAM sum taken in cycle s+3, PCM result in s+9)
      F5  E8.5c monitor: SRAM_LATENCY / ALIGN_DELAY 2 / 6 in all three runs;
          16684 datapath starts; SRAM reads at the datapath start =
          the testbench's count; no two SRAM reads of one lane less than 2
          cycles apart; once: no pool hit outside the datapath start
      F6  E8.5 monitor summary lines identical in the three runs
      With --fake-data (sandbox, random data): ALL TESTS PASSED, the SRAM
      read numbers of F1 and the comparisons with the E8.2 / E8.5 files are
      reported, not gated.
"""
import argparse
import hashlib
import os
import re
import sys
import time

SRAM_READS = {"A": 267143, "B": 205664}
N_OPS = 16684
DONE_CYCLE = 617573
RUNS = ("base", "new", "once")
NEW_FILES = ("rtl/e8/pcm_imc_unit_e8s.v", "rtl/e8/sram_pool_25lane_2c.v")
BASE_ONLY = ("rtl/e8/pcm_imc_unit_e8.v", "rtl/src/sram_pool_25lane.v")
NEVER_NEW = ("rtl/src/pcm_imc_unit.v", "rtl/src/sram_pool_25lane.v", "rtl/e8/pcm_imc_unit_e8.v")
TOP = "rtl/src/lenet5_top.v"


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        h.update(fh.read())
    return h.hexdigest()


class Report:
    def __init__(self):
        self.ok = True

    def say(self, s=""):
        print(s)

    def gate(self, ok, label):
        self.say(f"  {'PASS' if ok else 'FAIL'}  {label}")
        self.ok &= bool(ok)

    def gate_or_info(self, ok, label, info_only):
        if info_only:
            self.say(f"  info  {label} ({'yes' if ok else 'no'}; fake data, not a gate)")
        else:
            self.gate(ok, label)


def grab(text, pat, conv=int):
    m = re.search(pat, text)
    return tuple(conv(x) for x in m.groups()) if m else None


def data_lines(path):
    """Lines that are not comments, and the comment lines that start with '# done' (E8.2 monitor)."""
    body, done = [], None
    with open(path, errors="replace") as fh:
        for ln in fh:
            ln = ln.rstrip("\n")
            if ln.startswith("# done_cycle"):
                done = ln
            elif ln and not ln.startswith("#"):
                body.append(ln)
    return body, done


def compare(a, b):
    first = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), None)
    ok = len(a) == len(b) and first is None
    txt = f"{len(b)} lines against {len(a)}, " + (
        "all identical" if ok else (f"first difference at line {first}" if first is not None else "different count"))
    det = [f"      ref : {a[first][:150]}", f"      this: {b[first][:150]}"] if first is not None else []
    return ok, txt, det


def rel(p):
    p = p.replace("\\", "/")
    i = p.find("/rtl/")
    return p[i + 1:] if i >= 0 else p


def read_deps(path):
    with open(path) as fh:
        return set(rel(x.strip()) for x in fh if x.strip())


def cmd_unit(a):
    R = Report()
    t = open(a.log, errors="replace").read()
    R.say(f"P2R-E8.5c unit test: {a.log}  (md5 {md5(a.log)})")
    g = grab(t, r"(\d+) cycles compared, (\d+) lane hits, sweep (\d+) lane reads \(every address on every lane\), "
                r"reset check (\d+) bad, (\d+) mismatches")
    R.gate(g is not None and g[0] >= 200000 and g[2] == 25 * 3074 and g[3] == 0 and g[4] == 0,
           f"U1 two-cycle pool = one-cycle pool one cycle earlier: cycles {g[0] if g else None} (>= 200000), "
           f"sweep lane reads {g[2] if g else None} (76850), reset check bad {g[3] if g else None} (0), "
           f"mismatches {g[4] if g else None} (0); lane hits {g[1] if g else None}")
    return 0 if R.ok else 1


def cmd_full(a):
    R = Report()
    M, W, fake = a.model, a.work, a.fake_data
    R.say(f"P2R-E8.5c full-inference checks, model {M}   {time.strftime('%Y-%m-%d %H:%M:%S')}"
          + ("   (FAKE DATA: sandbox)" if fake else ""))
    R.say(f"   script     {md5(os.path.abspath(__file__))}")
    f = {r: {"log": os.path.join(W, f"sim_{r}_{M}.log"), "e82": os.path.join(W, f"e8t_{r}_{M}.txt"),
             "e85t": os.path.join(W, f"e85t_{r}_{M}.txt"), "e85e": os.path.join(W, f"e85e_{r}_{M}.txt"),
             "res": os.path.join(W, f"res_{r}_{M}.txt"), "deps": os.path.join(W, f"deps_{r}_{M}.txt")}
         for r in RUNS}
    for r in RUNS:
        for k in ("log", "e82", "e85t", "e85e", "res"):
            p = f[r][k]
            R.say(f"   {r:4s} {k:4s}  {md5(p) if os.path.exists(p) else 'MISSING'}  {p}")
    missing = [f[r][k] for r in RUNS for k in f[r] if not os.path.exists(f[r][k])]
    if missing:
        R.gate(False, f"files missing: {missing}")
        return 1
    logs = {r: open(f[r]["log"], errors="replace").read() for r in RUNS}

    # ---- F0 ----
    deps = {r: read_deps(f[r]["deps"]) for r in RUNS}
    ok = all(x in deps["base"] for x in BASE_ONLY) and not any(x in deps["base"] for x in NEW_FILES) and TOP in deps["base"]
    R.gate(ok, "F0 base compile: rtl/e8/pcm_imc_unit_e8.v, rtl/src/sram_pool_25lane.v, rtl/src/lenet5_top.v; none of the new files")
    common = deps["base"] - set(BASE_ONLY)
    for r in ("new", "once"):
        ok = all(x in deps[r] for x in NEW_FILES) and not any(x in deps[r] for x in NEVER_NEW) and TOP in deps[r]
        rest = deps[r] - set(NEW_FILES)
        R.gate(ok and rest == common,
               f"F0 {r} compile: the two new files and {TOP}, none of {', '.join(NEVER_NEW)}; other files "
               + ("identical to base" if rest == common else f"DIFFERENT (+{sorted(rest - common)} -{sorted(common - rest)})"))
    R.say(f"        files per compile: base {len(deps['base'])}, new {len(deps['new'])}, once {len(deps['once'])}")

    # ---- F1 ----
    for r in RUNS:
        t = logs[r]
        R.gate_or_info("RESULT: ALL TESTS PASSED" in t, f"F1 {r}: RESULT: ALL TESTS PASSED", fake)
        R.gate(f"inference complete at cycle {DONE_CYCLE}" in t, f"F1 {r}: inference complete at cycle {DONE_CYCLE}")
        n = grab(t, r"SRAM protected-weight reads \(per MAC op\): (\d+)")
        R.gate_or_info(n == (SRAM_READS[M],), f"F1 {r}: SRAM reads {n[0] if n else None} ({SRAM_READS[M]})", fake)

    # ---- F2 ----
    base82, base82_done = data_lines(f["base"]["e82"])
    ref82, ref82_done = data_lines(a.e82_trace)
    ok, txt, det = compare(ref82, base82)
    R.gate_or_info(ok and base82_done == ref82_done,
                   f"F2 base, E8.2 monitor = E8.2 trace {a.e82_trace}: {txt}; done line "
                   f"{'identical' if base82_done == ref82_done else 'different'}", fake)
    for d in det:
        R.say(d)
    for r in ("new", "once"):
        b, bd = data_lines(f[r]["e82"])
        ok, txt, det = compare(base82, b)
        R.gate(ok and bd == base82_done and len(b) == N_OPS,
               f"F2 {r}, E8.2 monitor = base: {txt}; done line {'identical' if bd == base82_done else 'DIFFERENT'}; "
               f"{len(b)} operations ({N_OPS})")
        for d in det:
            R.say(d)

    # ---- F3 ----
    for k, nm in (("e85t", "E8.5 trace"), ("e85e", "ROM events")):
        bb, _ = data_lines(f["base"][k])
        for r in ("new", "once"):
            b, _ = data_lines(f[r][k])
            ok, txt, det = compare(bb, b)
            R.gate(ok and len(b) > 0, f"F3 {r}, {nm} = base: {txt}")
            for d in det:
                R.say(d)
        ref = os.path.join(a.e85_dir, f"{'e85_trace' if k == 'e85t' else 'e85_events'}_{M}.txt")
        if os.path.exists(ref):
            rr, _ = data_lines(ref)
            ok, txt, det = compare(rr, bb)
            R.gate_or_info(ok, f"F3 base, {nm} = E8.5 ({ref}, md5 {md5(ref)}): {txt}", fake)
            for d in det:
                R.say(d)
        else:
            R.gate_or_info(False, f"F3 base, {nm}: E8.5 file {ref} not found", fake)

    # ---- F4 ----
    rb, _ = data_lines(f["base"]["res"])
    R.gate(len(rb) == N_OPS, f"F4 base: {len(rb)} results ({N_OPS})")
    for r in ("new", "once"):
        b, _ = data_lines(f[r]["res"])
        ok, txt, det = compare(rb, b)
        R.gate(ok, f"F4 {r}, results (cycle and value) = base: {txt}")
        for d in det:
            R.say(d)
    nz = sum(1 for x in rb if x.split()[1] != "0")
    R.say(f"  info  results different from 0: {nz} of {len(rb)}")
    for r in RUNS:
        starts = [int(x.split()[0]) for x in data_lines(f[r]["e85t"])[0]]
        res = [int(x.split()[0]) for x in data_lines(f[r]["res"])[0]]
        lat = sorted(set(b - a for a, b in zip(starts, res)))
        R.gate(len(starts) == len(res) == N_OPS and lat == [10],
               f"F4 {r}: every result 10 cycles after its datapath start: offsets {lat} over {len(res)} results "
               f"and {len(starts)} starts")

    # ---- F5 ----
    want = {"base": (2, 6), "new": (2, 6), "once": (2, 6)}
    for r in RUNS:
        t = logs[r]
        lat = grab(t, r"\[E8\.5c MONITOR\] SRAM_LATENCY (\d+), ALIGN_DELAY (\d+)")
        R.gate(lat == want[r], f"F5 {r}: SRAM_LATENCY, ALIGN_DELAY {lat} ({want[r]})")
        st = grab(t, r"\[E8\.5c MONITOR\] datapath starts (\d+), SRAM reads (\d+)")
        tbn = grab(t, r"SRAM protected-weight reads \(per MAC op\): (\d+)")
        R.gate(st is not None and st[0] == N_OPS and tbn is not None and st[1] == tbn[0],
               f"F5 {r}: datapath starts {st[0] if st else None} ({N_OPS}); SRAM reads at the datapath start "
               f"{st[1] if st else None} = testbench {tbn[0] if tbn else None}")
        gp = grab(t, r"shortest interval between two SRAM reads of one lane (-?\d+) cycles \(lane (-?\d+)\); "
                     r"intervals below 2: (\d+)")
        R.gate(gp is not None and gp[0] >= 2 and gp[2] == 0,
               f"F5 {r}: shortest interval between two SRAM reads of one lane {gp[0] if gp else None} cycles "
               f"(lane {gp[1] if gp else None}; >= 2), intervals below 2: {gp[2] if gp else None} (0)")
        ho = grab(t, r"cycles with a pool hit while the datapath start is low: (\d+)")
        if r == "once":
            R.gate(ho == (0,), f"F5 once: cycles with a pool hit outside the datapath start {ho[0] if ho else None} (0)")
        else:
            R.say(f"  info  {r}: cycles with a pool hit outside the datapath start {ho[0] if ho else None} "
                  f"(addresses held while the operation runs)")

    # ---- F6 ----
    def e85_lines(t):
        out = []
        for ln in t.splitlines():
            if "[E8.5 MONITOR]" in ln:
                out.append(re.sub(r"\S*/\S+", "<file>", ln.strip()))
        return out
    lb = e85_lines(logs["base"])
    for r in ("new", "once"):
        ok, txt, det = compare(lb, e85_lines(logs[r]))
        R.gate(ok and len(lb) > 0, f"F6 {r}, E8.5 monitor summary = base: {txt}")
        for d in det:
            R.say(d)
    err = grab(logs["base"], r"error flags \{queue,lane0,mismatch\} ([01]{3}); parking rule violations (\d+); "
                             r"macros unparked at the end (\d+)", str)
    R.say(f"  info  base E8.5 monitor: errors {err[0] if err else None}, parking rule violations "
          f"{err[1] if err else None}, unparked {err[2] if err else None}")
    for r in RUNS:
        raw = grab(logs[r], r"raw lane-cycles, NOT the energy count: (\d+)")
        R.say(f"  info  {r}: raw SRAM lane-cycles {raw[0] if raw else None} (not a gate)")

    R.say(f"   model {M}: {'ALL CHECKS PASS' if R.ok else 'A CHECK FAILED'}")
    return 0 if R.ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    u = sp.add_parser("unit")
    u.add_argument("--log", required=True)
    fu = sp.add_parser("full")
    fu.add_argument("--model", required=True, choices=("A", "B"))
    fu.add_argument("--work", required=True)
    fu.add_argument("--e82-trace", required=True)
    fu.add_argument("--e85-dir", required=True)
    fu.add_argument("--fake-data", action="store_true")
    a = ap.parse_args()
    return cmd_unit(a) if a.cmd == "unit" else cmd_full(a)


if __name__ == "__main__":
    sys.exit(main())
