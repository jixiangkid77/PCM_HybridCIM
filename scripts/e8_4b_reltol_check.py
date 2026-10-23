#!/usr/bin/env python3
"""Numerical settings of the ROM energy runs (E8.4b): the same runs at three relative tolerances.

The 98 runs of E8.4b (12 tables, 1,173 reads, maximum time step 2 ns, one fiftieth of the 100-ns
period) exist with the default relative tolerance of ngspice, 1e-3 (reports/e8_rom/e8_4b/), with
1e-4 (e8_4b_rel4/) and with 1e-5 (e8_4b_rel5/, used for all ROM energies). The 8 runs of table
e8rom_B_sram_l00_16x2496 were also made at 1e-5 in a separate earlier run (e8_4b_rc/).
This script compares 1e-3 and 1e-4 with 1e-5, read by read:
  - whether every read returned the right word with the right selection, and the lowest one-cell
    bit line of each read;
  - the energy of each read, and the static power after each read over the reads that leave more
    than 20 uW at 1e-5 (relative differences, 1e-5 as the reference);
  - D_ROM per inference at 1e-4 and 1e-5 (reports/e8_rom/e8_6a3_rel4/ and e8_6a3_rel5/); the
    final D_ROM of reports/e8_6/e8_6_summary.json replaces the parked static power of these
    with measured floors and exists only at 1e-5, so the difference is also given as a share
    of it;
and the two runs at 1e-5 of the same table, every measured value.

Usage: python3 scripts/e8_4b_reltol_check.py [--paper2 REPO_ROOT]
"""
import argparse
import json
import os
import statistics as st

THR_UW = 20.0


def load(root, *p):
    return json.load(open(os.path.join(root, *p)))


def by_key(m, key, runs=None):
    return {(r["run"], r["i"]): r for r in m[key] if runs is None or r["run"] in runs}


def rel(ref, x):
    return 100.0 * (x - ref) / ref


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".", help="repository root")
    a = ap.parse_args()
    root = a.paper2
    rom = os.path.join("reports", "e8_rom")
    m5 = load(root, rom, "e8_4b_rel5", "model.json")
    r5 = by_key(m5, "reads")
    tables = sorted(set(r["table"] for r in m5["reads"]))
    print(f"reference: {rom}/e8_4b_rel5/model.json (relative tolerance 1e-5): {len(m5['runs'])} runs, "
          f"{len(tables)} tables, {len(r5)} reads")
    for name, tol in (("e8_4b", "1e-3"), ("e8_4b_rel4", "1e-4")):
        m = load(root, rom, name, "model.json")
        r = by_key(m, "reads")
        common = [k for k in r5 if k in r]
        ok = sum(1 for k in common if r5[k]["ok"] and r5[k]["sel_ok"] and r[k]["ok"] and r[k]["sel_ok"])
        dbl = [1e3 * (r[k]["bl1_min"] - r5[k]["bl1_min"]) for k in common
               if r5[k]["bl1_min"] is not None and r[k]["bl1_min"] is not None]
        de = [rel(r5[k]["E"], r[k]["E"]) for k in common]
        dp = [(rel(r5[k]["P_after"], r[k]["P_after"]), k) for k in common
              if r5[k]["P_after"] is not None and r[k]["P_after"] is not None and abs(r5[k]["P_after"]) > THR_UW]
        wp = max(dp, key=lambda t: abs(t[0]))
        print(f"\n{rom}/{name}/model.json (relative tolerance {tol}) against 1e-5, {len(common)} reads in both:")
        print(f"   right word with the right selection in both runs: {ok} of {len(common)}")
        print(f"   lowest one-cell bit line of a read: {len(dbl)} reads, difference {min(dbl):+.2f} to {max(dbl):+.2f} mV, "
              f"largest |difference| {max(abs(x) for x in dbl):.2f} mV")
        print(f"   read energy: median |difference| {st.median(abs(x) for x in de):.2f}%, largest {max(de, key=abs):+.2f}%")
        print(f"   static power after a read, {len(dp)} reads above {THR_UW:.0f} uW at 1e-5: median |difference| "
              f"{st.median(abs(x) for x, _ in dp):.2f}%, |difference| >= 20% in {sum(1 for x, _ in dp if abs(x) >= 20)}, "
              f"largest {wp[0]:+.1f}% ({r5[wp[1]]['P_after']:.2f} -> {r[wp[1]]['P_after']:.2f} uW, "
              f"x{r[wp[1]]['P_after'] / r5[wp[1]]['P_after']:.1f}, {wp[1][0]} read {wp[1][1]})")

    d4 = load(root, rom, "e8_6a3_rel4", "d_rom.json")["models"]
    d5 = load(root, rom, "e8_6a3_rel5", "d_rom.json")["models"]
    fin = load(root, "reports", "e8_6", "e8_6_summary.json")["energy"]
    print(f"\nD_ROM per inference (bits form, corrected), {rom}/e8_6a3_rel4 against e8_6a3_rel5:")
    for mdl in ("A", "B"):
        x4, x5 = d4[mdl]["bits"]["corrected_uJ"], d5[mdl]["bits"]["corrected_uJ"]
        p4, p5 = d4[mdl]["bits"], d5[mdl]["bits"]
        print(f"   model {mdl}: 1e-4 {x4:.3f} uJ, 1e-5 {x5:.3f} uJ, difference {x5 - x4:+.3f} uJ = "
              f"{100 * (x5 - x4) / x4:+.2f}% (reads {p5['read_uJ'] - p4['read_uJ']:+.3f}, parking reads "
              f"{p5['park_uJ'] - p4['park_uJ']:+.3f}, static {p5['static_uJ'] - p4['static_uJ']:+.3f} uJ before the "
              f"correction); {100 * abs(x5 - x4) / fin[mdl]['D_rom_uJ']:.2f}% of the final D_ROM "
              f"{fin[mdl]['D_rom_uJ']:.2f} uJ (reports/e8_6/e8_6_summary.json)")

    mrc = load(root, rom, "e8_4b_rc", "model.json")
    runs = sorted(set(r["run"] for r in mrc["reads"]))
    print(f"\nthe same runs twice at 1e-5: {rom}/e8_4b_rc/model.json against e8_4b_rel5, {len(runs)} runs of "
          f"{mrc['runs'][0]['table']}:")
    for key in ("reads", "waits", "idles"):
        x, y = by_key(mrc, key), by_key(m5, key, set(runs))
        same = sum(1 for k in x if x[k] == y.get(k))
        print(f"   {key}: {len(x)} records, identical {same}, records in only one run {len(set(x) ^ set(y))}")
    pa = {p["macro"]: p for p in mrc["parta"]}
    pb = {p["macro"]: p for p in m5["parta"]}
    print(f"   part A of the macros: {len(pa)} records, identical {sum(1 for k in pa if pa[k] == pb.get(k))}")
    va = {v["run"]: v for v in mrc["validation"]}
    vb = {v["run"]: v for v in m5["validation"]}
    same = sum(1 for k in va if (va[k]["measured_pJ"], va[k]["seg_measured_pJ"]) ==
               (vb[k]["measured_pJ"], vb[k]["seg_measured_pJ"]))
    print(f"   measured energy of the lookup trains: {len(va)} trains, identical {same} "
          f"(their model predictions differ because each model is fitted to the tables of its own run)")


if __name__ == "__main__":
    main()
