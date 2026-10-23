#!/usr/bin/env python3
"""Compare the per-read and per-wait records of a reference E8.4b model.json (REF, e.g. reltol 1e-5)
with another (TEST, e.g. reltol 1e-4) for the runs present in REF. Criterion (E8.4b-rc, written before
the run): every read correct in both with the same selection; every read energy and every static power
after a read or during a wait (> 20 uW) within +-2 %; every train's measured energy within +-1 %.
usage: cmp_rc.py REF.json TEST.json"""
import json, sys, statistics as st
ref = json.load(open(sys.argv[1])); tst = json.load(open(sys.argv[2]))
runs = sorted(set(r["run"] for r in ref["reads"]))
print(f"runs in REF: {len(runs)}: {', '.join(runs)}")
ok = True
def pairs(key):
    a = {(r["run"], r["i"]): r for r in ref[key] if r["run"] in runs}
    b = {(r["run"], r["i"]): r for r in tst[key] if r["run"] in runs}
    missing = set(a) ^ set(b)
    return a, b, missing
a, b, miss = pairs("reads")
print(f"reads: {len(a)} in REF, {len(b)} in TEST, unmatched {len(miss)}")
ok &= not miss
bad_ok = [k for k in a if k in b and (a[k]["ok"], a[k]["sel_ok"]) != (b[k]["ok"], b[k]["sel_ok"])]
allok = all(a[k]["ok"] and a[k]["sel_ok"] for k in a)
print(f"   reads correct in REF: {allok}; outcome differs: {len(bad_ok)}")
ok &= allok and not bad_ok
def rel(x, y): return 100.0 * (y - x) / x
for fld, thr, lim in (("E", 0.0, 2.0), ("P_after", 20.0, 2.0)):
    d = [(rel(a[k][fld], b[k][fld]), k) for k in a if k in b and a[k][fld] is not None and b[k][fld] is not None and abs(a[k][fld]) > thr]
    worst = max(d, key=lambda t: abs(t[0])) if d else (0, None)
    good = all(abs(x) <= lim for x, _ in d)
    print(f"   read {fld} (> {thr}): n={len(d)}, TEST - REF median {st.median([x for x,_ in d]):+.3f} %, worst {worst[0]:+.3f} % at {worst[1]} -> {'within' if good else 'OUTSIDE'} +-{lim} %")
    ok &= good
a, b, miss = pairs("waits")
d = [(rel(a[k]["P_after"], b[k]["P_after"]), k) for k in a if k in b and a[k]["P_after"] is not None and b[k]["P_after"] is not None and abs(a[k]["P_after"]) > 20]
worst = max(d, key=lambda t: abs(t[0])) if d else (0, None)
good = all(abs(x) <= 2.0 for x, _ in d) and not miss
print(f"waits: {len(a)} in REF, unmatched {len(miss)}; P_after (> 20 uW) n={len(d)}, median {st.median([x for x,_ in d]) if d else 0:+.3f} %, worst {worst[0]:+.3f} % at {worst[1]} -> {'within' if good else 'OUTSIDE'} +-2 %")
ok &= good
va = {v["run"]: v for v in ref["validation"] if v["run"] in runs}; vb = {v["run"]: v for v in tst["validation"] if v["run"] in runs}
for r in sorted(va):
    x = rel(va[r]["measured_pJ"], vb[r]["measured_pJ"])
    print(f"   train {r}: REF {va[r]['measured_pJ']:.1f} pJ, TEST {vb[r]['measured_pJ']:.1f} pJ ({x:+.3f} %) -> {'within' if abs(x) <= 1.0 else 'OUTSIDE'} +-1 %")
    ok &= abs(x) <= 1.0
pa = {p["macro"]: p for p in ref["parta"]}; pb = {p["macro"]: p for p in tst["parta"]}
for m in sorted(pa):
    if m in pb:
        print(f"   part A {m}: P_Z {pa[m]['P_Z_uW']:.1f} / {pb[m]['P_Z_uW']:.1f} uW, P_H {pa[m]['P_H_uW']:.1f} / {pb[m]['P_H_uW']:.1f} uW, parked {pa[m]['leak_mean_uW']:.3f} / {pb[m]['leak_mean_uW']:.3f} uW (REF / TEST)")
print("CRITERION MET: reltol of TEST is converged for these runs" if ok else "CRITERION NOT MET")
