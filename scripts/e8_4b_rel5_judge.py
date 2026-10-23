#!/usr/bin/env python3
"""P2R-E8.4b-rel5 judgment, written 2026-10-19 before the run (claude/p2r-e8-4b-rel4-results.md, section 6-1b).

Gate 1 (validity):
  - main log: banner 'Finished', solver line with the expected reltol, output line with the expected folder;
  - model.json: 98 runs, each complete; every read correct with the right selection; margins_ok
    (every read margin >= 0.10 V);
  - the main log's 'finished ... (complete)' lines: 98, none 'failed': true in the summaries;
  - E8.6a-3 log: 'ALL CHECKS PASS'; d_rom.json records the md5 of this model.json and the
    unchanged E8.6a-3 script (1e216cf0...).
Gate 3 (convergence): four numbers of d_rom.json, models/{A,B}/bits/{D_uJ, corrected_uJ};
  every |NEW - REF| / REF <= 1 %  -> CONVERGED; any > 1 % -> REPORT TO KID.
Listed only (not a gate): side, layer and component split of D_ROM, ranges, and the per-side
  comparison of model.json records as in sections 2 and 3 of the rel4 record.

usage: judge_rel5.py MAIN_LOG E86_LOG NEW_MODEL NEW_DROM REF_MODEL REF_DROM [RELTOL OUTNAME]
       (RELTOL default 1e-5, OUTNAME default e8_4b_rel5)
"""
import hashlib, json, re, statistics as st, sys

a = sys.argv[1:]
if len(a) not in (6, 8):
    sys.exit(__doc__)
main_log, e86_log, new_model, new_drom, ref_model, ref_drom = a[:6]
RELTOL, OUTNAME = (a[6], a[7]) if len(a) == 8 else ("1e-5", "e8_4b_rel5")
E86_SCRIPT_MD5 = "1e216cf0983787bb4fe4cab0d816fdb6"
NRUNS = 98

ok_all = True
def gate(cond, text):
    global ok_all
    ok_all &= bool(cond)
    print(f"   [{'PASS' if cond else 'FAIL'}] {text}")

def md5(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()

print("=" * 78)
print(f"P2R-E8.4b-rel5 judgment: NEW {new_model}\n   against REF {ref_model}")
print("=" * 78)

# ---------------------------------------------------------------- gate 1
print("\n1. validity")
log = open(main_log, encoding="utf-8", errors="replace").read().splitlines()
solver = [l for l in log if l.startswith("solver")]
output = [l for l in log if l.startswith("output")]
gate(solver and f"reltol {RELTOL} (E8_RELTOL)" in solver[0], f"solver line: {solver[0].strip() if solver else 'missing'}")
gate(output and output[0].rstrip().endswith(f"{OUTNAME} (E8_OUT_NAME={OUTNAME})"), f"output line: {output[0].strip() if output else 'missing'}")
fin = [l for l in log if re.match(r"\s+finished \S+ at ", l)]
fin_runs = {re.match(r"\s+finished (\S+) at ", l).group(1) for l in fin}
fin_complete = {re.match(r"\s+finished (\S+) at ", l).group(1) for l in fin if l.rstrip().endswith("(complete)")}
gate(len(fin_runs) == NRUNS and fin_complete == fin_runs, f"log: {len(fin_runs)} runs finished, {len(fin_complete)} complete (expected {NRUNS})")
failed = [l for l in log if l.startswith("summary:") and '"failed": true' in l]
gate(not failed, f"log: summaries with \"failed\": true: {len(failed)}")
gate(any(re.match(r"Finished \d{4}-\d\d-\d\d", l) for l in log), "log: banner 'Finished <date>' present")

m = json.load(open(new_model)); r = json.load(open(ref_model))
gate(len(m["runs"]) == NRUNS and all(x.get("complete") for x in m["runs"]), f"model.json: {len(m['runs'])} runs, complete {sum(bool(x.get('complete')) for x in m['runs'])}")
nbad = sum(1 for x in m["reads"] if not (x["ok"] and x["sel_ok"]))
gate(nbad == 0, f"model.json: {len(m['reads'])} reads, wrong or wrong selection {nbad}")
gate(m["margins_ok"] is True, "model.json: margins_ok (every read margin >= 0.10 V)")
for k, v in m["margins"].items():
    rv = r["margins"].get(k, {})
    print(f"      {k:40s} {v['reads']:4d} reads, wrong {v['wrong']}, wrong sel {v['wrong_selection']}, "
          f"one {v['min_margin_one_V']:+.3f} V (REF {rv.get('min_margin_one_V', float('nan')):+.3f}), "
          f"zero {v['min_margin_zero_V']:+.3f} V, access <= {v['t_access_max_ns']:.2f} ns (REF {rv.get('t_access_max_ns', float('nan')):.2f})")
e86 = open(e86_log, encoding="utf-8", errors="replace").read()
gate("ALL CHECKS PASS" in e86, "E8.6a-3 log: ALL CHECKS PASS")
d = json.load(open(new_drom)); dr = json.load(open(ref_drom))
gate(d["model_json_md5"] == md5(new_model), f"d_rom.json model_json_md5 {d['model_json_md5']} = md5 of NEW model.json {md5(new_model)}")
gate(d["script_md5"] == E86_SCRIPT_MD5, f"d_rom.json script_md5 {d['script_md5']} (expected {E86_SCRIPT_MD5}, unchanged)")
valid = ok_all
print(f"   -> run {'VALID' if valid else 'NOT VALID (report to KID before anything else)'}")

# ---------------------------------------------------------------- gate 3
print("\n3. convergence: D_ROM, bits form (gate: every |difference| <= 1 %)")
conv = True
for mod in ("A", "B"):
    for f, name in (("D_uJ", "per bit"), ("corrected_uJ", "corrected")):
        x, y = dr["models"][mod]["bits"][f], d["models"][mod]["bits"][f]
        p = 100.0 * (y - x) / x
        conv &= abs(p) <= 1.0
        print(f"   model {mod} {name:9s}: REF {x:.3f} uJ -> NEW {y:.3f} uJ ({p:+.2f} %)  {'within' if abs(p) <= 1.0 else 'OUTSIDE'} 1 %")
print(f"   -> {'CONVERGED: D_ROM final = NEW; the differences are the numerical uncertainty' if conv else 'NOT CONVERGED: REPORT TO KID'}"
      + ("" if valid else "  (but the run is not valid: gate 1)"))

# ---------------------------------------------------------------- listed only
print("\n4. listed only (not a gate)")
for mod in ("A", "B"):
    b, br = d["models"][mod]["bits"], dr["models"][mod]["bits"]
    print(f"   model {mod}: range {br['range_uJ'][0]:.3f}-{br['range_uJ'][1]:.3f} -> {b['range_uJ'][0]:.3f}-{b['range_uJ'][1]:.3f} uJ; "
          f"count form corrected {dr['models'][mod]['count']['corrected_uJ']:.3f} -> {d['models'][mod]['count']['corrected_uJ']:.3f} uJ")
    for grp in ("by_side_uJ", "by_layer_uJ"):
        print("      " + grp[:-3] + ": " + ", ".join(f"{k} {br[grp][k]:.3f}->{b[grp][k]:.3f}" for k in b[grp]))
    print("      parts: " + ", ".join(f"{k[:-3]} {br[k]:.3f}->{b[k]:.3f}" for k in ("read_uJ", "park_uJ", "static_uJ"))
          + f"; ROM reads {br['rom_reads']}->{b['rom_reads']}, parks {br['parks']}->{b['parks']}")

def pct(x, y):
    return (y - x) / x * 100 if x not in (0, None) else None

# same definitions as the rel4 record (sections 2 and 3): sums over all records of a group;
# relative changes only where |old| or |new| >= thr (and old != 0)
def summarize(name, ro, rn, field, thr=None, by=("side", "kind")):
    do = {(x["run"], x["i"]): x for x in ro}; dn = {(x["run"], x["i"]): x for x in rn}
    if set(do) != set(dn):
        print(f"   {name}: records differ: {len(set(do) ^ set(dn))} unmatched")
    groups = {}
    for k in do:
        if k not in dn: continue
        a, b = do[k][field], dn[k][field]
        if a is None or b is None: continue
        groups.setdefault(tuple(do[k][x] for x in by), []).append((a, b))
    print(f"   == {name}.{field}" + (f" (relative change where |x| >= {thr})" if thr else ""))
    for g, v in sorted(groups.items()):
        relc = [pct(a, b) for a, b in v if (thr is None or abs(a) >= thr or abs(b) >= thr) and a != 0]
        sa = sum(a for a, _ in v); sb = sum(b for _, b in v)
        tail = (f", each median {st.median(relc):+.2f} % min {min(relc):+.1f} % max {max(relc):+.1f} %" if relc else "")
        print(f"      {g[0]:4s} {g[1]:5s}: n={len(v)}, sum {sa:.1f} -> {sb:.1f} ({pct(sa, sb):+.2f} %)" + tail)

summarize("reads", r["reads"], m["reads"], "E")
summarize("reads", r["reads"], m["reads"], "P_after", thr=20)
summarize("waits", r["waits"], m["waits"], "E")
summarize("waits", r["waits"], m["waits"], "P_after", thr=20)
summarize("idles", r["idles"], m["idles"], "E")
do = {(x["run"], x["i"]): x for x in r["reads"]}; dn = {(x["run"], x["i"]): x for x in m["reads"]}
ks = [k for k in do if k in dn]
d1 = [(dn[k]["bl1_min"] - do[k]["bl1_min"]) * 1000 for k in ks if do[k]["bl1_min"] is not None and dn[k]["bl1_min"] is not None]
d0 = [(dn[k]["bl0_max"] - do[k]["bl0_max"]) * 1000 for k in ks if do[k].get("bl0_max") is not None and dn[k].get("bl0_max") is not None]
ta = [dn[k]["t_acc"] - do[k]["t_acc"] for k in ks if do[k]["t_acc"] is not None and dn[k]["t_acc"] is not None]
print(f"   bitline of the one cells, lowest per read: n={len(d1)}, change {min(d1):+.2f}...{max(d1):+.2f} mV (median {st.median(d1):+.2f})")
print(f"   bitline of the zero cells, highest per read: n={len(d0)}, change {min(d0):+.2f}...{max(d0):+.2f} mV")
print(f"   access time change {min(ta):+.3f}...{max(ta):+.3f} ns")

po = {p["macro"]: p for p in r["parta"]}; pn = {p["macro"]: p for p in m["parta"]}
for side in ("pcm", "sram"):
    rz = []; rh = []
    for k in po:
        if k not in pn or po[k]["side"] != side: continue
        a, b = po[k], pn[k]
        if a["P_Z_uW"] and a["P_Z_uW"] > 20: rz.append(pct(a["P_Z_uW"], b["P_Z_uW"]))
        if a["P_H_uW"] and a["P_H_uW"] > 20: rh.append(pct(a["P_H_uW"], b["P_H_uW"]))
    print(f"   part A {side:4s}: after Z (REF > 20 uW) n={len(rz)} median {st.median(rz):+.1f} % ({min(rz):+.1f}...{max(rz):+.1f}); "
          f"after H n={len(rh)} median {st.median(rh):+.1f} % ({min(rh):+.1f}...{max(rh):+.1f})")
    lo = [p["leak_mean_uW"] for p in r["parta"] if p["side"] == side and p["leak_mean_uW"] is not None and p["leak_mean_uW"] < 20]
    ln = [p["leak_mean_uW"] for p in m["parta"] if p["side"] == side and p["leak_mean_uW"] is not None and p["leak_mean_uW"] < 20]
    print(f"   part A {side:4s}: parked power, mean of macros < 20 uW: {sum(lo)/len(lo):.3f} (n={len(lo)}) -> {sum(ln)/len(ln):.3f} uW (n={len(ln)})")
    same = sum(1 for k in po if k in pn and po[k]["side"] == side and po[k]["park_choice"].split(" ")[:1] == pn[k]["park_choice"].split(" ")[:1])
    print(f"   part A {side:4s}: parking word the same in {same} of {sum(1 for k in po if po[k]['side'] == side)} macros")

vo = {v["run"]: v for v in r["validation"]}; vn = {v["run"]: v for v in m["validation"]}
for side in ("pcm", "sram"):
    ch = [pct(vo[k]["measured_pJ"], vn[k]["measured_pJ"]) for k in vo if k in vn and vo[k]["side"] == side]
    so = sum(vo[k]["measured_pJ"] for k in vo if k in vn and vo[k]["side"] == side); sn = sum(vn[k]["measured_pJ"] for k in vo if k in vn and vo[k]["side"] == side)
    print(f"   measured trains {side:4s}: n={len(ch)}, total {so:.0f} -> {sn:.0f} pJ ({pct(so, sn):+.2f} %), each median {st.median(ch):+.2f} % ({min(ch):+.2f}...{max(ch):+.2f})")
    for kind in ("conv1", "conv2", "conv2_nopark", "fc1"):
        c = [pct(vo[k]["measured_pJ"], vn[k]["measured_pJ"]) for k in vo if k in vn and vo[k]["side"] == side and k.endswith("/" + kind)]
        print(f"      {kind:12s}: " + ", ".join(f"{x:+.2f} %" for x in c))
for dd in m["drift"]:
    rd = next((x for x in r["drift"] if x["macro"] == dd["macro"]), None)
    if rd:
        print(f"   drift {dd['macro']}: 2.5 us {rd['points_us_uW'][0][1]:.1f} -> {dd['points_us_uW'][0][1]:.1f} uW ({pct(rd['points_us_uW'][0][1], dd['points_us_uW'][0][1]):+.2f} %)")
for side in ("pcm", "sram"):
    s0, s1 = r["models"][side], m["models"][side]
    print(f"   model {side:4s}: static per zero bit {s0['static']['per_zero_bit_uW']:.2f} -> {s1['static']['per_zero_bit_uW']:.2f} uW "
          f"(r2 {s0['static']['r2']:.3f} -> {s1['static']['r2']:.3f}); per bit r2 {s0['static_bits']['r2']:.3f} -> {s1['static_bits']['r2']:.3f}; "
          f"read r2 {s0['read']['r2']:.3f} -> {s1['read']['r2']:.3f}, per bit {s0['read_bits']['r2']:.3f} -> {s1['read_bits']['r2']:.3f}")
for f in ("count", "bits"):
    x, y = r["validation_summary"][f], m["validation_summary"][f]
    print(f"   LOTO {f:5s}: largest |error| {x['max_abs_error_pct']:.1f} -> {y['max_abs_error_pct']:.1f} %, total {x['total_error_pct']:+.2f} -> {y['total_error_pct']:+.2f} %, "
          f"criterion met {x['criterion_met']} -> {y['criterion_met']}")

print("\nSUMMARY: run " + ("VALID" if valid else "NOT VALID") + "; " + ("CONVERGED" if conv else "NOT CONVERGED -> REPORT TO KID"))
