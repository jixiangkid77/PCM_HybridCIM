#!/usr/bin/env python3
"""
e8_5_check.py   (P2R-E8.5)

Gate checks of the E8.5 runs (scripts/e8_5_amu.sh), from the simulation logs,
the lookup traces and the recorded ROM clock pulses. Exit status 0 = all pass.

  engine  --log eng_<M>.log
      U2  REF 16684 = NEW 16684 operations, 0 mismatches; errors 000; 0
          parking-rule violations, 0 macros unparked; ROM protocol 0 / 0 / 0;
          clock low >= 90.0 ns before lookups, >= 50.0 ns before parks;
          engine watchdogs 00000. Stall cycles are reported.

  full    --model M --e82-trace T --base-log L --base-trace T --e85-log L
          --ext-trace T --go-trace T --events E --out DIR
      F1  G1 of E8.2 in the baseline and the E8.5 run: ALL TESTS PASSED,
          inference complete at cycle 617573, SRAM reads 267143 (A) / 205664 (B)
      F2  baseline trace (E8.2 monitor) = E8.2 trace, line by line
      F3  E8.5 run, E8.2 monitor (engine start pulse) = E8.2 trace
      F4  E8.5 run, E8.5 monitor (datapath start, amu start_go) = E8.2 trace
          (if not, also compared without the cycle field, for the report)
      F5  every lookup pulse reads its entry's macro and word
          (macro = entry / 624, row = entry % 624 / 13, word = entry % 13,
          address = row * 16 + word)
      F6  E8.5 monitor: errors 000, 0 parking-rule violations, 0 macros left
          unparked at the end, macro reads counted by the 200 models equal the
          reads implied by the pulses, ROM protocol 0 / 0 / 0
      Writes DIR/e8_5_summary_<M>.json / .txt: per-layer operations, entry
      changes and lookup pulses, parking pulses, macro reads per side.

  syn     --stat amu_<M>_stat_final.txt
      area per module of the Yosys report (the 50 amu_table modules grouped);
      the modules must add up to the top-module area
"""
import argparse
import hashlib
import json
import os
import re
import sys
import time

LAYERS = ("conv1", "conv2", "fc1", "fc2", "fc3")
OFFS = (0, 6, 102, 2022, 2442, 2482)
SRAM_READS = {"A": 267143, "B": 205664}


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        h.update(fh.read())
    return h.hexdigest()


def entry_of(layer, a0):
    """Lane-0 table entry (E8.2 decoder arithmetic; rtl/e8/amu_entry.v); None = no lookup."""
    if layer == 0:
        return a0 // 25 if (a0 < 150 and a0 % 25 == 0) else None
    if layer == 1:
        return 6 + a0 // 25 if (a0 < 2400 and a0 % 25 == 0) else None
    dims = {2: (400, 48000, 102, 16), 3: (120, 10080, 2022, 5), 4: (84, 840, 2442, 4)}
    if layer in dims:
        ind, lim, off, nsb = dims[layer]
        oc, fl = divmod(a0, ind)
        if a0 < lim and fl % 25 == 0:
            return off + oc * nsb + fl // 25
    return None


def layer_of(e):
    for i in range(5):
        if OFFS[i] <= e < OFFS[i + 1]:
            return i
    return None


def read_trace(path):
    ops, done = [], None
    with open(path) as fh:
        for ln in fh:
            ln = ln.rstrip("\n")
            if ln.startswith("# done_cycle"):
                done = ln
            elif ln and not ln.startswith("#"):
                ops.append(ln)
    return ops, done


def compare(ref, got, strip_cycle=False):
    a = [(" ".join(x.split()[1:]) if strip_cycle else x) for x in ref]
    b = [(" ".join(x.split()[1:]) if strip_cycle else x) for x in got]
    first = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), None)
    ok = len(a) == len(b) and first is None
    txt = f"{len(b)} operations against {len(a)}, " + (
        "all lines identical" if ok else
        (f"first difference at operation {first}" if first is not None else "different count"))
    det = [f"      E8.2: {ref[first][:150]}", f"      this: {got[first][:150]}"] if first is not None else []
    return ok, txt, det


class Report:
    def __init__(self):
        self.lines, self.ok = [], True

    def say(self, s=""):
        self.lines.append(s)
        print(s)

    def gate(self, ok, label):
        self.say(f"  {'PASS' if ok else 'FAIL'}  {label}")
        self.ok &= bool(ok)


def grab(text, pat, conv=int):
    m = re.search(pat, text)
    return tuple(conv(x) for x in m.groups()) if m else None


def cmd_engine(a):
    R = Report()
    t = open(a.log, errors="replace").read()
    R.say(f"P2R-E8.5 engine-level checks: {a.log}  (md5 {md5(a.log)})")
    ops = grab(t, r"operations: REF (\d+), NEW (\d+), mismatches (\d+)")
    R.gate(ops == (16684, 16684, 0), f"REF / NEW operations and mismatches: {ops} (16684, 16684, 0)")
    unit = grab(t, r"starts (\d+), stall cycles (\d+), lookup read pulses (\d+), parking pulses (\d+), "
                   r"errors \{queue,lane0,mismatch\} ([01]{3})", str)
    R.gate(unit is not None and unit[4] == "000", f"unit errors {unit[4] if unit else None} (000)")
    if unit:
        R.say(f"        starts {unit[0]}, stall cycles {unit[1]}, lookup pulses {unit[2]}, parking pulses {unit[3]}")
    pk = grab(t, r"(\d+) violations; macros left unparked at the end (\d+)")
    R.gate(pk == (0, 0), f"parking rule violations, macros left unparked: {pk} (0, 0)")
    low = grab(t, r"lookup >= ([0-9.]+) ns \((\d+)\), park >= ([0-9.]+) ns \((\d+)\)", float)
    R.gate(low is not None and low[0] >= 90.0 - 1e-9 and low[2] >= 50.0 - 1e-9,
           f"ROM clock low before lookups / parks: {low[0] if low else None} / {low[2] if low else None} ns (>= 90 / >= 50)")
    prot = grab(t, r"reads (\d+), CS at the edge (\d+), address changed while high (\d+), invalid word (\d+), "
                   r"shortest low before a read ([0-9.]+) ns", float)
    R.gate(prot is not None and prot[1:4] == (0, 0, 0),
           f"ROM models: CS at the edge / address changed / invalid word {prot[1:4] if prot else None} (0, 0, 0); "
           f"reads {int(prot[0]) if prot else None}, shortest low {prot[4] if prot else None} ns")
    wd = grab(t, r"engine watchdogs: ([01]{5})", str)
    R.gate(wd == ("00000",), f"engine watchdogs {wd[0] if wd else None} (00000)")
    cyc = grab(t, r"total cycles (\d+)")
    R.say(f"        total cycles {cyc[0] if cyc else None}")
    R.say(f"   engine level: {'ALL CHECKS PASS' if R.ok else 'A CHECK FAILED'}")
    return 0 if R.ok else 1


def cmd_full(a):
    R = Report()
    M = a.model
    R.say(f"P2R-E8.5 full-inference checks, model {M}   {time.strftime('%Y-%m-%d %H:%M:%S')}")
    R.say(f"   script      {md5(os.path.abspath(__file__))}")
    for nm, p in (("E8.2 trace", a.e82_trace), ("base log", a.base_log), ("base trace", a.base_trace),
                  ("E8.5 log", a.e85_log), ("E8.5 ext", a.ext_trace), ("E8.5 go", a.go_trace), ("events", a.events)):
        R.say(f"   {nm:11s} {md5(p)}  {p}")

    # ---- F1 ----
    pats = ("RESULT: ALL TESTS PASSED", "inference complete at cycle 617573",
            f"SRAM protected-weight reads (per MAC op): {SRAM_READS[M]}")
    for nm, p in (("baseline", a.base_log), ("E8.5 unit", a.e85_log)):
        t = open(p, errors="replace").read()
        for pat in pats:
            R.gate(pat in t, f"F1 {nm}: {pat}")
    e85 = open(a.e85_log, errors="replace").read()

    # ---- F2-F4 ----
    ref, ref_done = read_trace(a.e82_trace)
    R.say(f"   E8.2 trace: {len(ref)} operations; {ref_done}")
    for tag, nm, p in (("F2", "baseline, E8.2 monitor", a.base_trace),
                       ("F3", "E8.5 unit, E8.2 monitor (engine start)", a.ext_trace)):
        ops, done = read_trace(p)
        ok, txt, det = compare(ref, ops)
        R.gate(ok and done == ref_done, f"{tag} {nm}: {txt}; done line {'identical' if done == ref_done else 'DIFFERENT: ' + str(done)}")
        for d in det:
            R.say(d)
    g_ops, _ = read_trace(a.go_trace)
    ok, txt, det = compare(ref, g_ops)
    R.gate(ok, f"F4 E8.5 unit, E8.5 monitor (datapath start): {txt}")
    for d in det:
        R.say(d)
    if not ok:
        ok2, txt2, det2 = compare(ref, g_ops, strip_cycle=True)
        R.say(f"  info  F4 without the cycle field: {txt2}")
        for d in det2:
            R.say(d)

    # ---- operations ----
    op_e, op_l = [], []
    for ln in ref:
        f = ln.split()
        layer, a0 = int(f[1]), int(f[6].split(":")[0], 16)
        op_e.append(entry_of(layer, a0))
        op_l.append(layer)
    used = set(e for e in op_e if e is not None)
    n_ops = [op_l.count(i) for i in range(5)]
    n_chg, prev = [0] * 5, None
    for e, l in zip(op_e, op_l):
        if e != prev:
            n_chg[l] += 1
        prev = e

    # ---- F5 and the pulse counts ----
    look = {p: [0] * 6 for p in "BIA"}
    park = {p: 0 for p in "BIA"}
    rl, rp = [0, 0], [0, 0]
    bad, not_used = 0, 0
    with open(a.events) as fh:
        for ln in fh:
            if ln.startswith("#") or not ln.strip():
                continue
            f = ln.split()
            if f[0] == "L":
                ph, m, addr, e, lanes = f[1], int(f[3]), int(f[4], 16), int(f[5]), int(f[7], 16)
                l = layer_of(e)
                look[ph][5 if l is None else l] += 1
                mm, r = divmod(e, 624)
                if mm != m or addr != (r // 13) * 16 + r % 13:
                    bad += 1
                if e not in used:
                    not_used += 1
                n = bin(lanes).count("1")
                rl[0] += n
                rl[1] += n
            elif f[0] == "P":
                park[f[1]] += 1
                rp[0] += bin(int(f[4], 16)).count("1")
                rp[1] += bin(int(f[5], 16)).count("1")
    R.gate(bad == 0, f"F5 lookup pulses reading another word than their entry's: {bad}")
    R.say(f"  info  lookups of an entry no operation uses: {not_used}")

    # ---- F6 ----
    err = grab(e85, r"error flags \{queue,lane0,mismatch\} ([01]{3}); parking rule violations (\d+); "
                    r"macros unparked at the end (\d+)", str)
    R.gate(err is not None and err == ("000", "0", "0"),
           f"F6 unit errors {err[0] if err else None} (000), parking rule violations {err[1] if err else None} (0), "
           f"macros left unparked at the end {err[2] if err else None} (0)")
    eq = grab(e85, r"macro reads counted by the 200 models: (\d+) \((\w+)\)", str)
    R.gate(eq is not None and eq[1] == "equal", f"F6 macro reads counted by the models {eq[0] if eq else None}: {eq[1] if eq else None} to the pulses")
    pr = grab(e85, r"CS at the clock edge (\d+), address changed while high (\d+), invalid word (\d+), "
                   r"shortest clock low before a read ([0-9.]+) ns", float)
    R.gate(pr is not None and pr[:3] == (0, 0, 0), f"F6 ROM protocol {pr[:3] if pr else None} (0, 0, 0); shortest low {pr[3] if pr else None} ns")
    st = grab(e85, r"stall cycles (\d+), lookup pulses (\d+), parking pulses (\d+)")
    if st:
        R.say(f"  info  unit counters: stall cycles {st[0]}, lookup pulses {st[1]}, parking pulses {st[2]}")
    raw = {nm: grab(open(p, errors="replace").read(), r"raw lane-cycles, NOT the energy count: (\d+)")
           for nm, p in (("baseline", a.base_log), ("E8.5", a.e85_log))}
    R.say(f"  info  raw SRAM lane-cycles (not a gate; the E8.5 hits appear when the entry is in the buffer): "
          f"baseline {raw['baseline'][0] if raw['baseline'] else None}, E8.5 {raw['E8.5'][0] if raw['E8.5'] else None}")

    R.say("")
    R.say("   layer   operations  entry changes  lookup pulses")
    for i in range(5):
        R.say(f"   {LAYERS[i]:6s} {n_ops[i]:10d} {n_chg[i]:14d} {look['I'][i]:14d}")
    R.say(f"   total  {sum(n_ops):10d} {sum(n_chg):14d} {sum(look['I']):14d}")
    R.say(f"   lookup pulses before the start {sum(look['B'])}, after done {sum(look['A'])}; "
          f"parking pulses before {park['B']}, during {park['I']}, after {park['A']}")
    R.say(f"   macro reads: lookup SRAM {rl[0]}, PCM {rl[1]}; parking SRAM {rp[0]}, PCM {rp[1]}; "
          f"total {sum(rl) + sum(rp)}")
    summ = {"model": M, "operations": dict(zip(LAYERS, n_ops)), "entry_changes": dict(zip(LAYERS, n_chg)),
            "lookup_pulses": dict(zip(LAYERS, look["I"][:5])),
            "lookup_pulses_before_start": sum(look["B"]), "lookup_pulses_after_done": sum(look["A"]),
            "parking_pulses": park, "macro_reads_lookup_sram_pcm": rl, "macro_reads_parking_sram_pcm": rp,
            "stall_cycles": st[0] if st else None, "all_checks_pass": R.ok,
            "inputs_md5": {"e82_trace": md5(a.e82_trace), "events": md5(a.events), "e85_log": md5(a.e85_log)}}
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, f"e8_5_summary_{M}.json"), "w") as fh:
        json.dump(summ, fh, indent=1)
    R.say(f"   model {M}: {'ALL CHECKS PASS' if R.ok else 'A CHECK FAILED'}")
    with open(os.path.join(a.out, f"e8_5_summary_{M}.txt"), "w") as fh:
        fh.write("\n".join(R.lines) + "\n")
    return 0 if R.ok else 1


def cmd_syn(a):
    """Area per module from a Yosys 'stat -liberty' report (hierarchical design)."""
    R = Report()
    R.say(f"P2R-E8.5 area by module: {a.stat}  (md5 {md5(a.stat)})")
    areas, top = {}, None
    for ln in open(a.stat, errors="replace"):
        m = re.search(r"Chip area for module '(.+)': ([0-9.]+)\s*$", ln)
        if m:
            areas[m.group(1)] = float(m.group(2))
            continue
        m = re.search(r"Chip area for top module '(.+)': ([0-9.]+)\s*$", ln)
        if m:
            top = float(m.group(2))
    groups = {}
    for name, ar in areas.items():
        parts = name.split("\\")
        base = next((x for x in parts if x.startswith("amu_")), parts[-1])
        for key in ("amu_table", "amu_buf", "amu_pflags", "amu_core", "amu_lanes", "amu_entry", "amu_top"):
            if base.startswith(key):
                break
        else:
            key = base
        g = groups.setdefault(key, [])
        g.append(ar)
    tot = sum(sum(v) for v in groups.values())
    R.say(f"   {'module':12s} {'count':>5s} {'area um2':>12s} {'share':>7s}   per instance")
    for key in ("amu_buf", "amu_table", "amu_core", "amu_lanes", "amu_entry", "amu_pflags", "amu_top"):
        if key in groups:
            v = groups[key]
            per = f"{min(v):.1f}-{max(v):.1f}" if len(v) > 1 else f"{v[0]:.1f}"
            R.say(f"   {key:12s} {len(v):5d} {sum(v):12.1f} {100 * sum(v) / tot:6.1f}%   {per}")
    for key, v in groups.items():
        if key not in ("amu_buf", "amu_table", "amu_core", "amu_lanes", "amu_entry", "amu_pflags", "amu_top"):
            R.say(f"   {key:12s} {len(v):5d} {sum(v):12.1f}   (other)")
    R.say(f"   sum of modules {tot:.1f} um2; top module {top} um2")
    R.gate(top is not None and abs(tot - top) < 0.5, "the modules add up to the top-module area")
    return 0 if R.ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    e = sp.add_parser("engine")
    e.add_argument("--log", required=True)
    y = sp.add_parser("syn")
    y.add_argument("--stat", required=True)
    f = sp.add_parser("full")
    f.add_argument("--model", required=True, choices=("A", "B"))
    for k in ("e82-trace", "base-log", "base-trace", "e85-log", "ext-trace", "go-trace", "events", "out"):
        f.add_argument("--" + k, required=True)
    a = ap.parse_args()
    return {"engine": cmd_engine, "full": cmd_full, "syn": cmd_syn}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
