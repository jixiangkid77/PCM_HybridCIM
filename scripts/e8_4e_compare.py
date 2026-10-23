#!/usr/bin/env python3
"""P2R-E8.4e (ROM part): energy at other operating conditions against E8.4b-rel5 (tt, 25 C, 1.80 V).

Written 2026-10-19 before the runs (claude/p2r-e8-plan.md, E8.4e); version 2 (2026-10-19, still before any
run): the components of D_ROM are taken per side from scripts/e8_4e_split.py, and the parked level is split
into leakage and the static of a word with zero bits (version 1 scaled the whole parked level by the
leakage ratio, which is wrong for the macros parked on a word with zero bits).
For every condition:
  1. validity: the runs of the two tables (part A of 4 macros each, the conv2 and fc1 trains: 12 runs) are
     complete; every read correct with the right selection (if not: the condition is outside the validated
     range and no D_ROM is given for it); margins with the switching level at the condition
  2. ratios to rel5 for the same runs and read numbers, per side (PCM side: A_pcm_l00, SRAM side:
     A_sram_l00):
       r_read   sum of read-window energies (part A and trains)
       r_static sum of the static power after a read (reads with > 20 uW at either condition)
       r_park   sum of the parking-read energies in the trains
       r_leak   mean parked power of the 4 macros (part A)
       r_conv2, r_fc1  measured energy of the trains
  3. D_ROM at the condition (primary, component by component, per side): rel5's split of D_ROM (bits form,
     RTL schedule; e8_4e_split.json) into reads, parking reads, static above the parked level, the parked
     level at leakage and the parked level on words with zero bits; each scaled by its ratio of the same
     side (reads r_read, parking reads r_park, static above r_static, leakage r_leak, words with zero bits
     r_static); the corrected D_ROM with rel5's correction factor.
     Cross-check: the layers of each side scaled by its train ratios (conv1, conv2 by r_conv2; fc1-fc3 by
     r_fc1), the parked level as above.
usage: e8_4e_compare.py --ref REL5_MODEL.json --split E8_4E_SPLIT.json [--out OUT.json] NAME=MODEL.json ...
"""
import argparse
import json
import math
import statistics as st

ap = argparse.ArgumentParser()
ap.add_argument("--ref", required=True, help="reports/e8_rom/e8_4b_rel5/model.json")
ap.add_argument("--split", required=True, help="reports/e8_rom/e8_4e_split.json (scripts/e8_4e_split.py)")
ap.add_argument("--out", default=None)
ap.add_argument("conds", nargs="+", help="NAME=model.json of a condition")
a = ap.parse_args()

ref = json.load(open(a.ref))
spl = json.load(open(a.split))
TABLES = {"pcm": "A_pcm_l00", "sram": "A_sram_l00"}


def tab_of(run):
    return run.split("/")[0]


def recs(m, key, side):
    return {(x["run"], x["i"]): x for x in m[key] if tab_of(x["run"]) == TABLES[side]}


def ratio(sa, sb):
    return sb / sa if sa else float("nan")


def side_ratios(m, side):
    out = {}
    R = recs(ref, "reads", side)
    C = recs(m, "reads", side)
    keys = [k for k in C if k in R]
    out["n_reads"] = len(keys)
    runs_c = {k[0] for k in C}
    out["missing_reads"] = len([k for k in R if k[0] in runs_c and k not in C])   # should be 0: same sequences
    out["r_read"] = ratio(sum(R[k]["E"] for k in keys), sum(C[k]["E"] for k in keys))
    ks = [k for k in keys if R[k]["P_after"] is not None and C[k]["P_after"] is not None
          and (abs(R[k]["P_after"]) > 20 or abs(C[k]["P_after"]) > 20)]
    out["n_static"] = len(ks)
    out["r_static"] = ratio(sum(R[k]["P_after"] for k in ks), sum(C[k]["P_after"] for k in ks))
    kp = [k for k in keys if R[k].get("park") and R[k]["kind"] == "train"]
    out["n_park_reads"] = len(kp)
    out["r_park"] = ratio(sum(R[k]["E"] for k in kp), sum(C[k]["E"] for k in kp)) if kp else float("nan")
    pa = {p["macro"]: p for p in ref["parta"] if p["side"] == side and p["table"].startswith("e8rom_" + TABLES[side])}
    pc = {p["macro"]: p for p in m["parta"] if p["side"] == side and p["table"].startswith("e8rom_" + TABLES[side])}
    mk = [k for k in pc if k in pa and pa[k]["leak_mean_uW"] is not None and pc[k]["leak_mean_uW"] is not None]
    out["n_leak_macros"] = len(mk)
    out["leak_ref_uW"] = st.mean(pa[k]["leak_mean_uW"] for k in mk) if mk else float("nan")
    out["leak_uW"] = st.mean(pc[k]["leak_mean_uW"] for k in mk) if mk else float("nan")
    out["r_leak"] = ratio(out["leak_ref_uW"], out["leak_uW"])
    va = {v["run"]: v for v in ref["validation"] if tab_of(v["run"]) == TABLES[side]}
    vc = {v["run"]: v for v in m["validation"] if tab_of(v["run"]) == TABLES[side]}
    for t in ("conv2", "fc1"):
        r = f"{TABLES[side]}/{t}"
        out[f"r_{t}"] = ratio(va[r]["measured_pJ"], vc[r]["measured_pJ"]) if r in va and r in vc else float("nan")
    return out


res = {}
for c in a.conds:
    name, path = c.split("=", 1)
    m = json.load(open(path))
    v = {"name": name, "model_json": path}
    runs = [r for r in m["runs"] if tab_of(r["label"]) in TABLES.values()]
    v["runs"] = len(runs)
    v["complete"] = sum(1 for r in runs if r.get("complete"))
    mine = [r for r in m["reads"] if tab_of(r["run"]) in TABLES.values()]
    bad = [r for r in mine if not (r["ok"] and r["sel_ok"])]
    v["reads"] = len(mine)
    v["bad_reads"] = len(bad)
    v["margins"] = m.get("margins")
    v["margins_ok"] = m.get("margins_ok")
    v["valid"] = v["runs"] == 12 and v["complete"] == 12 and not bad
    v["sides"] = {s: side_ratios(m, s) for s in TABLES}
    res[name] = v

print("P2R-E8.4e (ROM): ratios to E8.4b-rel5 (tt, 25 C, 1.80 V); same runs and read numbers\n")
print("condition | runs complete | reads (bad) | side | r_read | r_static | r_park | leak uW (rel5) | r_leak | r_conv2 | r_fc1")
for n, v in res.items():
    for s in TABLES:
        x = v["sides"][s]
        print(f"{n} | {v['complete']}/{v['runs']} | {v['reads']} ({v['bad_reads']}) | {s} | {x['r_read']:.3f} | "
              f"{x['r_static']:.3f} | {x['r_park']:.3f} | {x['leak_uW']:.3f} ({x['leak_ref_uW']:.3f}) | {x['r_leak']:.2f} | "
              f"{x['r_conv2']:.3f} | {x['r_fc1']:.3f}")
print()
for n, v in res.items():
    if v["margins"]:
        print(f"{n}: margins ok {v['margins_ok']}; " + "; ".join(
            f"{k}: one {x['min_margin_one_V']:+.3f} V, zero {x['min_margin_zero_V']:+.3f} V, wrong {x['wrong']}, "
            f"wrong sel {x['wrong_selection']}" for k, x in v["margins"].items()))
print()
COMP = (("read", "r_read"), ("park", "r_park"), ("static_above", "r_static"), ("parked_leak", "r_leak"),
        ("parked_zero", "r_static"))
out = {"ref": a.ref, "split": a.split, "conditions": {}}
for mod in ("A", "B"):
    sm = spl["models"][mod]
    D = sm["totals"]["D_uJ"]
    corr = sm["corrected_uJ"] / D
    print(f"model {mod}: rel5 D_ROM {D:.3f} uJ (corrected {sm['corrected_uJ']:.3f})")
    for s in TABLES:
        x = sm["sides"][s]
        print(f"   {s}: " + ", ".join(f"{c} {x[c]:.3f}" for c, _ in COMP) + f" (sum {x['D_uJ']:.3f})")
    for n, v in res.items():
        S = v["sides"]
        Dx = Dt = 0.0
        notes = []
        parts = {}
        for s in TABLES:
            x = sm["sides"][s]
            for c, r in COMP:
                rr = S[s][r]
                if c == "park" and math.isnan(rr):
                    rr = S[s]["r_read"]
                    notes.append(f"{s}: no parking reads, parking scaled by r_read")
                parts[f"{s}_{c}"] = x[c] * rr
                Dx += x[c] * rr
            lay = x["by_layer_uJ"]
            Dt += (lay["conv1"] + lay["conv2"]) * S[s]["r_conv2"] + (lay["fc1"] + lay["fc2"] + lay["fc3"]) * S[s]["r_fc1"]
            Dt += x["parked_leak"] * S[s]["r_leak"] + x["parked_zero"] * S[s]["r_static"]
        flag = "" if v["valid"] else "  (NOT VALID at this condition: outside the validated range; no D_ROM given)"
        print(f"   {n}: D_ROM {Dx:.3f} uJ ({100 * (Dx / D - 1):+.1f} %), corrected {Dx * corr:.3f}; cross-check by "
              f"trains {Dt:.3f} uJ ({100 * (Dt / D - 1):+.1f} %){flag}" + ("; " + "; ".join(notes) if notes else ""))
        out["conditions"].setdefault(n, {"valid": v["valid"], "bad_reads": v["bad_reads"], "sides": v["sides"],
                                         "margins": v["margins"], "models": {}})
        out["conditions"][n]["models"][mod] = {"D_uJ": Dx, "corrected_uJ": Dx * corr, "D_trains_uJ": Dt,
                                               "parts_uJ": parts, "notes": notes}
if a.out:
    json.dump(out, open(a.out, "w"), indent=1)
    print(f"\nwritten {a.out}")
