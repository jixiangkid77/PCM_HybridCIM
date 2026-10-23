#!/usr/bin/env python3
"""
e8_5e_check.py   (P2R-E8.5e)

Gate checks of the E8.5e runs (scripts/e8_5e_conv1cache.sh): the conv1 register
cache (rtl/e8/conv1_cache.v, rtl/e8/pcm_imc_unit_e8c.v) against E8.5c's runs new
and once (rtl/e8/pcm_imc_unit_e8s.v). Exit status 0 = all pass.

  unit  --log LOG
      U1  rtl/e8/conv1_cache.v against the testbench's reference: 0 errors,
          at least 100000 cached lane outputs and 1000 cache writes

  full  --model M --work DIR --e85c-dir DIR --e82-trace T [--fake-data]
      Runs: cache (normal) and conce (-DE85C_READ_ONCE), files in --work;
      references: E8.5c new and once in --e85c-dir.
      G0  compile file lists: pcm_imc_unit_e8c.v, conv1_cache.v and
          sram_pool_25lane_2c.v; none of pcm_imc_unit_e8s.v,
          pcm_imc_unit_e8.v, rtl/src/pcm_imc_unit.v, rtl/src/
          sram_pool_25lane.v; all other files = E8.5c new
      G1  ALL TESTS PASSED; inference complete at cycle 617573; testbench
          SRAM lookups 267143 (A) / 205664 (B)
      G2  E8.2 monitor trace, E8.5 trace and ROM events = E8.5c new
          (cache and conce); E8.2 monitor trace = E8.2 trace
      G3  results (cycle and value of every result): cache = E8.5c new,
          conce = E8.5c once, line by line; 16684 results; each 10 cycles
          after its datapath start
      G4  E8.5e monitor: SRAM macro reads 149543 (A) / 88064 (B) = lookups -
          117600, conv1 macro reads 0; cache reads 117600, 4704 on every
          lane; cache entries different from the pool word 0; cache reads
          outside conv1 0; cycles with a pool hit in conv1 0
      G5  E8.5c monitor (SRAM_LATENCY / ALIGN_DELAY 2 / 6, 16684 starts,
          lookups at the start, intervals) and E8.5 monitor summary =
          E8.5c new (conce: E8.5c once), apart from file names and the
          E8.5c line "cycles with a pool hit while the datapath start is
          low": in the normal mode the pool sees no hit during conv1 any
          more, so this count must be lower than E8.5c new (reported); in
          the strict mode it must stay 0
      With --fake-data (sandbox, random data): ALL TESTS PASSED, the read
      numbers of G1/G4 and the comparison with the E8.2 trace are reported,
      not gated.
"""
import argparse
import hashlib
import os
import re
import sys
import time

LOOKUPS = {"A": 267143, "B": 205664}
CONV1_READS = 117600
CONV1_PER_LANE = 4704
N_OPS = 16684
DONE_CYCLE = 617573
RUNS = {"cache": "new", "conce": "once"}     # E8.5e run -> E8.5c reference run
NEW_FILES = ("rtl/e8/pcm_imc_unit_e8c.v", "rtl/e8/conv1_cache.v", "rtl/e8/sram_pool_25lane_2c.v")
NEW_MON = "rtl/e8/tb/e8_5e_monitor.v"                # the E8.5e monitor (new testbench file)
POOL_OFF_START = "cycles with a pool hit while the datapath start is low"   # E8.5c monitor line that the cache changes
NEVER = ("rtl/e8/pcm_imc_unit_e8s.v", "rtl/e8/pcm_imc_unit_e8.v", "rtl/src/pcm_imc_unit.v", "rtl/src/sram_pool_25lane.v")
E85C_ONLY = ("rtl/e8/pcm_imc_unit_e8s.v",)
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


def monitor_lines(t, tag):
    return [re.sub(r"\S*/\S+", "<file>", ln.strip()) for ln in t.splitlines() if tag in ln]


def cmd_unit(a):
    R = Report()
    t = open(a.log, errors="replace").read()
    R.say(f"P2R-E8.5e unit test: {a.log}  (md5 {md5(a.log)})")
    g = grab(t, r"U1 cycles (\d+), lane checks (\d+), conv1 cycles (\d+), cached lane outputs (\d+), cache writes (\d+), "
                r"ignored writes (\d+), errors (\d+)")
    R.gate(g is not None and g[6] == 0 and g[3] >= 100000 and g[4] >= 1000 and "U1 PASS" in t,
           f"U1 conv1_cache = reference: cycles {g[0] if g else None}, lane checks {g[1] if g else None}, cached lane "
           f"outputs {g[3] if g else None} (>= 100000), cache writes {g[4] if g else None} (>= 1000), ignored writes "
           f"{g[5] if g else None}, errors {g[6] if g else None} (0)")
    return 0 if R.ok else 1


def cmd_full(a):
    R = Report()
    M, W, C, fake = a.model, a.work, a.e85c_dir, a.fake_data
    R.say(f"P2R-E8.5e full-inference checks, model {M}   {time.strftime('%Y-%m-%d %H:%M:%S')}"
          + ("   (FAKE DATA: sandbox)" if fake else ""))
    R.say(f"   script     {md5(os.path.abspath(__file__))}")
    f = {}
    for r, ref in RUNS.items():
        f[r] = {k: os.path.join(W, f"{k}_{r}_{M}.txt") for k in ("e8t", "e85t", "e85e", "res", "deps")}
        f[r]["log"] = os.path.join(W, f"sim_{r}_{M}.log")
        f[ref] = {k: os.path.join(C, f"{k}_{ref}_{M}.txt") for k in ("e8t", "e85t", "e85e", "res", "deps")}
        f[ref]["log"] = os.path.join(C, f"sim_{ref}_{M}.log")
    for r in list(RUNS) + list(RUNS.values()):
        for k in ("log", "e8t", "e85t", "e85e", "res"):
            p = f[r][k]
            R.say(f"   {r:5s} {k:4s}  {md5(p) if os.path.exists(p) else 'MISSING'}  {p}")
    missing = [f[r][k] for r in f for k in f[r] if not os.path.exists(f[r][k])]
    if missing:
        R.gate(False, f"files missing: {missing}")
        return 1
    logs = {r: open(f[r]["log"], errors="replace").read() for r in f}

    # ---- G0 ----
    dn = read_deps(f["new"]["deps"])
    for r in RUNS:
        d = read_deps(f[r]["deps"])
        ok = all(x in d for x in NEW_FILES) and not any(x in d for x in NEVER) and TOP in d
        ok = ok and NEW_MON in d
        rest = d - set(NEW_FILES) - {NEW_MON}
        common = dn - set(E85C_ONLY) - {"rtl/e8/sram_pool_25lane_2c.v"}
        R.gate(ok and rest == common,
               f"G0 {r} compile: {', '.join(NEW_FILES)}, {NEW_MON} and {TOP}; none of {', '.join(NEVER)}; other files "
               + ("= E8.5c new" if rest == common else f"DIFFERENT (+{sorted(rest - common)} -{sorted(common - rest)})"))

    # ---- G1 ----
    for r in RUNS:
        t = logs[r]
        R.gate_or_info("RESULT: ALL TESTS PASSED" in t, f"G1 {r}: RESULT: ALL TESTS PASSED", fake)
        R.gate(f"inference complete at cycle {DONE_CYCLE}" in t, f"G1 {r}: inference complete at cycle {DONE_CYCLE}")
        n = grab(t, r"SRAM protected-weight reads \(per MAC op\): (\d+)")
        nref = grab(logs[RUNS[r]], r"SRAM protected-weight reads \(per MAC op\): (\d+)")
        R.gate(n is not None and n == nref, f"G1 {r}: testbench SRAM lookups {n[0] if n else None} = E8.5c "
                                            f"{nref[0] if nref else None}")
        R.gate_or_info(n == (LOOKUPS[M],), f"G1 {r}: testbench SRAM lookups {n[0] if n else None} ({LOOKUPS[M]})", fake)

    # ---- G2 ----
    for r in RUNS:
        for k, nm in (("e8t", "E8.2 monitor trace"), ("e85t", "E8.5 trace"), ("e85e", "ROM events")):
            a_, ad = data_lines(f["new"][k])
            b_, bd = data_lines(f[r][k])
            ok, txt, det = compare(a_, b_)
            R.gate(ok and ad == bd and len(b_) > 0, f"G2 {r}, {nm} = E8.5c new: {txt}"
                   + ("" if ad == bd else "; done line DIFFERENT"))
            for x in det:
                R.say(x)
    ref82, _ = data_lines(a.e82_trace)
    b82, _ = data_lines(f["cache"]["e8t"])
    ok, txt, det = compare(ref82, b82)
    R.gate_or_info(ok, f"G2 cache, E8.2 monitor trace = E8.2 trace {a.e82_trace}: {txt}", fake)

    # ---- G3 ----
    for r, ref in RUNS.items():
        a_, _ = data_lines(f[ref]["res"])
        b_, _ = data_lines(f[r]["res"])
        ok, txt, det = compare(a_, b_)
        R.gate(ok and len(b_) == N_OPS, f"G3 {r}, results (cycle and value) = E8.5c {ref}: {txt}; {len(b_)} results ({N_OPS})")
        for x in det:
            R.say(x)
        starts = [int(x.split()[0]) for x in data_lines(f[r]["e85t"])[0]]
        res = [int(x.split()[0]) for x in b_]
        lat = sorted(set(q - p for p, q in zip(starts, res)))
        R.gate(len(starts) == len(res) == N_OPS and lat == [10],
               f"G3 {r}: every result 10 cycles after its datapath start: offsets {lat}")

    # ---- G4 ----
    for r in RUNS:
        t = logs[r]
        g = grab(t, r"\[E8\.5e MONITOR\] datapath starts (\d+); SRAM macro reads (\d+) \(conv1 (\d+), conv2 (\d+), fc1 (\d+), "
                    r"fc2 (\d+), fc3 (\d+)\); conv1 cache reads (\d+)")
        lane = grab(t, r"\[E8\.5e MONITOR\] cache reads per lane: min (\d+) max (\d+)")
        chk = grab(t, r"\[E8\.5e MONITOR\] cache entries different from the pool word: (\d+); cache reads outside conv1: "
                      r"(\d+); cycles with a pool hit in conv1: (\d+)")
        n = grab(t, r"SRAM protected-weight reads \(per MAC op\): (\d+)")
        if g is None or lane is None or chk is None or n is None:
            R.gate(False, f"G4 {r}: E8.5e monitor lines missing")
            continue
        R.gate(g[0] == N_OPS and g[1] + g[7] == n[0] and g[2] == 0,
               f"G4 {r}: starts {g[0]} ({N_OPS}); macro reads {g[1]} + cache reads {g[7]} = lookups {n[0]}; conv1 macro "
               f"reads {g[2]} (0); conv2 {g[3]}, fc1 {g[4]}, fc2 {g[5]}, fc3 {g[6]}")
        R.gate_or_info(g[1] == LOOKUPS[M] - CONV1_READS and g[7] == CONV1_READS and lane == (CONV1_PER_LANE, CONV1_PER_LANE),
                       f"G4 {r}: macro reads {g[1]} ({LOOKUPS[M] - CONV1_READS}), cache reads {g[7]} ({CONV1_READS}), "
                       f"per lane {lane[0]}-{lane[1]} ({CONV1_PER_LANE})", fake)
        R.gate(chk == (0, 0, 0), f"G4 {r}: cache entries different from the pool word {chk[0]} (0); cache reads outside "
                                 f"conv1 {chk[1]} (0); cycles with a pool hit in conv1 {chk[2]} (0)")

    # ---- G5 ----
    for r, ref in RUNS.items():
        ha = grab(logs[ref], POOL_OFF_START + r": (\d+)")
        hb = grab(logs[r], POOL_OFF_START + r": (\d+)")
        if r == "conce":
            R.gate(ha == (0,) and hb == (0,), f"G5 {r}: {POOL_OFF_START} {hb[0] if hb else None} (0; E8.5c once "
                                              f"{ha[0] if ha else None})")
        else:
            R.gate(ha is not None and hb is not None and hb[0] < ha[0],
                   f"G5 {r}: {POOL_OFF_START} {hb[0] if hb else None} < E8.5c new {ha[0] if ha else None} "
                   f"(no pool hits in conv1)")
        for tag in ("[E8.5c MONITOR]", "[E8.5 MONITOR]"):
            la = [x for x in monitor_lines(logs[ref], tag) if "results" not in x and POOL_OFF_START not in x]
            lb = [x for x in monitor_lines(logs[r], tag) if "results" not in x and POOL_OFF_START not in x]
            ok, txt, det = compare(la, lb)
            R.gate(ok and len(la) > 0, f"G5 {r}, {tag} summary = E8.5c {ref}: {txt}")
            for x in det:
                R.say(x)

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
    fu.add_argument("--e85c-dir", required=True)
    fu.add_argument("--e82-trace", required=True)
    fu.add_argument("--fake-data", action="store_true")
    a = ap.parse_args()
    return cmd_unit(a) if a.cmd == "unit" else cmd_full(a)


if __name__ == "__main__":
    sys.exit(main())
