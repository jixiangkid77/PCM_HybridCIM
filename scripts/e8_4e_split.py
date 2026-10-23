#!/usr/bin/env python3
"""
e8_4e_split.py   (P2R-E8.4e, ROM part)

The split of D_ROM (E8.6a-3, bits form, RTL schedule) that the scaling of
P2R-E8.4e needs, per side (PCM, SRAM): reads, parking reads, static power above
the parked level, and the parked level split into
  parked_leak : leakage-level static (the macro parked on a word of 0xFFFF, or
                a word whose model static power is not above the parked power)
  parked_zero : static of a word with zero bits that a macro stays parked on
                (the macros without a word of 0xFFFF: E8.6a-3 parks them on the
                word with the fewest zero bits; the output-buffer current of
                its zero bits flows for the whole parked time)
The two parts of the parked level scale differently with temperature and
corner (leakage against the current through a half-on output buffer), so
scripts/e8_4e_compare.py scales them by different measured ratios.

It runs E8.6a-3's computation again (scripts/e8_6a3_rom_energy.py and
scripts/e8_6a2_rom_energy.py, imported, not changed) with a copy of its replay
that also adds up these parts. Checks (all must pass):
  S1 the copy gives E8.6a-3's replay result for every table and both models
     (read, park, static, by layer, by bucket; relative difference < 1e-9)
  S2 the totals equal reports/e8_rom/e8_6a3_rel5/d_rom.json (D, reads, parks,
     static, by side, by layer, parked level; relative difference < 1e-9)
Only reads; a few seconds.

Usage:
  python3 scripts/e8_4e_split.py --paper2 /mnt/d/Project/hybrid_memory/paper2
Reads reports/e8_rom/e8_4b_rel5/model.json, reports/e8_rom/e8_6a3_rel5/d_rom.json,
reports/e8_rom/e8_5/ and the E8.3 tables; writes reports/e8_rom/e8_4e_split.json.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import sys
import time


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def replay_split(E, tab, ev, sm, t_end_ns):
    """E8.6a-3's replay() (scripts/e8_6a3_rom_energy.py), unchanged, plus the parked level split into
    leakage-level static and the static of a word with zero bits (pJ)"""
    rows = tab.rows
    st_w = [tab.park[k][1] for k in range(tab.nmac)]          # start: every macro parked
    st_rb = [rows - 1 - tab.park[k][0] for k in range(tab.nmac)]
    st_b = [5] * tab.nmac
    t_free = [0.0] * tab.nmac
    En = {"read": 0.0, "park": 0.0, "static": 0.0, "idle": 0.0}
    by_layer = [0.0] * 5
    by_bucket = [0.0] * 6
    split = {"parked_leak": 0.0, "parked_zero": 0.0}
    n_read = n_park = overlap = 0

    def gap(k, t1):
        d = t1 - t_free[k]
        if d <= 0:
            return
        bkt = st_b[k] if sm.ps[st_w[k]] > sm.leak else 5
        e = sm.ps[st_w[k]] * d * 1e-3
        En["static"] += e
        by_bucket[bkt] += e
        if bkt == 5:
            split["parked_zero" if sm.ps[st_w[k]] > sm.leak else "parked_leak"] += e

    for T, kind, k, ent in ev:
        if T < t_free[k] - 1e-9:
            overlap += 1
        gap(k, T)
        if kind == "L":
            kk, r, w = tab.loc(ent)
            if kk != k:
                raise ValueError(f"entry {ent} is in macro {kk}, the pulse was on macro {k}")
            er = sm.read(rows - 1 - r, tab.zr[k][r], w, st_w[k])
            lay = layer_of(E, ent)
            En["read"] += er
            by_layer[lay] += er
            st_w[k], st_rb[k], st_b[k] = w, rows - 1 - r, lay
            n_read += 1
        else:
            rp, wp = tab.park[k]
            ep = sm.park(rows - 1 - rp, tab.zr[k][rp], st_w[k], st_rb[k])
            En["park"] += ep
            by_layer[st_b[k] if st_b[k] < 5 else 4] += ep
            st_w[k], st_rb[k], st_b[k] = wp, rows - 1 - rp, 5
            n_park += 1
        t_free[k] = max(t_free[k], T + E.SLOT_NS)
    for k in range(tab.nmac):
        gap(k, max(t_end_ns, t_free[k]))
    return En, by_layer, by_bucket, n_read, n_park, overlap, split


def layer_of(E, e):
    for i in range(5):
        if E.OFFSET[i] <= e < E.OFFSET[i] + E.DEPTH[i]:
            return i
    return 4


def rel(a, b):
    return abs(a - b) / max(abs(a), abs(b), 1e-12)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--paper2", required=True)
    ap.add_argument("--model-json", default=None, help="default reports/e8_rom/e8_4b_rel5/model.json")
    ap.add_argument("--d-rom", default=None, help="default reports/e8_rom/e8_6a3_rel5/d_rom.json")
    ap.add_argument("--e85-dir", default=None, help="default reports/e8_rom/e8_5")
    ap.add_argument("--rows", type=int, default=48)
    ap.add_argument("--wpr", type=int, default=13)
    ap.add_argument("--table-words", type=int, default=2496)
    ap.add_argument("--out", default=None, help="default reports/e8_rom/e8_4e_split.json")
    a = ap.parse_args()
    t0 = time.time()
    here = os.path.dirname(os.path.abspath(__file__))
    f3 = os.path.join(here, "e8_6a3_rom_energy.py")
    f2 = os.path.join(here, "e8_6a2_rom_energy.py")
    E3 = load_module(f3, "e8_6a3_rom_energy")
    E = load_module(f2, "e8_6a2_rom_energy")
    root = os.path.join(a.paper2, "reports", "e8_rom")
    mj = a.model_json or os.path.join(root, "e8_4b_rel5", "model.json")
    dj = a.d_rom or os.path.join(root, "e8_6a3_rel5", "d_rom.json")
    e85 = a.e85_dir or os.path.join(root, "e8_5")
    print(f"P2R-E8.4e split of D_ROM  {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"   script     : {md5(os.path.abspath(__file__))}  {os.path.abspath(__file__)}")
    print(f"   E8.6a-3    : {md5(f3)}  {f3}")
    print(f"   E8.6a-2    : {md5(f2)}  {f2}")
    print(f"   E8.4b model: {md5(mj)}  {mj}")
    print(f"   D_ROM      : {md5(dj)}  {dj}")
    model = json.load(open(mj))
    dref = json.load(open(dj))
    if dref.get("model_json_md5") != md5(mj):
        print(f"   WARNING: d_rom.json was computed from model.json {dref.get('model_json_md5')}, not this one")
    sides = sorted(model["models"])
    leak, idle, choice = {}, {}, {}
    for side in sides:                                   # as E8.6a-3
        lm = [p["leak_mean_uW"] for p in model["parta"] if p["side"] == side and p["leak_mean_uW"] < 10.0]
        leak[side] = sum(lm) / len(lm)
        idle[side] = model["models"][side]["idle_parked_pJ"]
        print(f"   {side}: parked power {leak[side]:.3f} uW (mean of {len(lm)} macros)")
    for r in model["runs"]:
        if r["kind"] == "parta" and r.get("park_choice"):
            tok = r["park_choice"].split()[0]
            choice.setdefault(r["table"], {})[r["k"]] = int(tok) if tok.isdigit() else None
    sm = {s: E.SideModel(model["models"][s], "bits", leak[s], idle[s]) for s in sides}
    nfail = 0

    def gate(ok, txt):
        nonlocal nfail
        print(f"  {'PASS' if ok else 'FAIL'}  {txt}")
        if not ok:
            nfail += 1

    out = {"script_md5": md5(os.path.abspath(__file__)), "e86a3_md5": md5(f3), "e86a2_md5": md5(f2),
           "model_json_md5": md5(mj), "d_rom_md5": md5(dj), "models": {}}
    worst1 = 0.0
    for M in ("A", "B"):
        evp = os.path.join(e85, f"e85_events_{M}.txt")
        tp = os.path.join(root, "trace", f"trace_{M}.txt")
        print(f"\n==== model {M} ====")
        print(f"   events : {md5(evp)}  {evp}")
        ev = E3.read_events(evp)
        _, done, _, _ = E.parse_trace(tp)
        t_end = done * E.CYCLE_NS
        res = {s: {"read": 0.0, "park": 0.0, "static_above": 0.0, "parked_leak": 0.0, "parked_zero": 0.0,
                   "by_layer": [0.0] * 5, "zero_parked_macros": []} for s in sides}
        for side in sides:
            for lane in range(E.K):
                name = f"e8rom_{M}_{side}_l{lane:02d}_16x{a.table_words}"
                tab = E.Table(E.table_words(a.paper2, M, side, lane, a.table_words), a.rows, a.wpr, choice.get(name))
                evi = E3.table_events(ev, side, lane, ("I",))
                En1, bl1, bb1, nr1, np1, ov1 = E3.replay(E, tab, evi, sm[side], t_end)
                En2, bl2, bb2, nr2, np2, ov2, sp = replay_split(E, tab, evi, sm[side], t_end)
                d = [rel(En1[c], En2[c]) for c in ("read", "park", "static")] + \
                    [rel(x, y) for x, y in zip(bl1 + bb1, bl2 + bb2)] + [rel(sp["parked_leak"] + sp["parked_zero"], bb2[5])]
                worst1 = max(worst1, max(d), 0.0 if (nr1, np1, ov1) == (nr2, np2, ov2) else 1.0)
                r = res[side]
                r["read"] += En2["read"]
                r["park"] += En2["park"]
                r["static_above"] += sum(bb2[:5])
                r["parked_leak"] += sp["parked_leak"]
                r["parked_zero"] += sp["parked_zero"]
                r["by_layer"] = [x + y + z for x, y, z in zip(r["by_layer"], bl2, bb2[:5])]
                for k in range(tab.nmac):
                    if tab.park[k][1] != E.MISS:
                        r["zero_parked_macros"].append(
                            f"{name} k{k}: row {tab.park[k][0]} word {tab.park[k][1]:04x}, "
                            f"model static {sm[side].ps[tab.park[k][1]]:.1f} uW")
        mo = {}
        for s in sides:
            r = res[s]
            mo[s] = {k: (v * 1e-6 if isinstance(v, float) else v) for k, v in r.items() if k != "by_layer"}
            mo[s]["by_layer_uJ"] = {E.LAYERS[i]: r["by_layer"][i] * 1e-6 for i in range(5)}
            mo[s]["D_uJ"] = (r["read"] + r["park"] + r["static_above"] + r["parked_leak"] + r["parked_zero"]) * 1e-6
            print(f"   {s}: D {mo[s]['D_uJ']:.4f} uJ = reads {mo[s]['read']:.4f} + parks {mo[s]['park']:.4f} + static above "
                  f"the parked level {mo[s]['static_above']:.4f} + parked: leakage level {mo[s]['parked_leak']:.4f}, "
                  f"words with zero bits {mo[s]['parked_zero']:.4f}")
            for t in r["zero_parked_macros"]:
                print(f"      parked on a word with zero bits: {t}")
        b = dref["models"][M]["bits"]
        tot = {"D_uJ": sum(mo[s]["D_uJ"] for s in sides), "read_uJ": sum(mo[s]["read"] for s in sides),
               "park_uJ": sum(mo[s]["park"] for s in sides),
               "static_uJ": sum(mo[s]["static_above"] + mo[s]["parked_leak"] + mo[s]["parked_zero"] for s in sides),
               "parked": sum(mo[s]["parked_leak"] + mo[s]["parked_zero"] for s in sides)}
        d2 = [rel(tot["D_uJ"], b["D_uJ"]), rel(tot["read_uJ"], b["read_uJ"]), rel(tot["park_uJ"], b["park_uJ"]),
              rel(tot["static_uJ"], b["static_uJ"]), rel(tot["parked"], b["by_layer_uJ"]["parked"])]
        d2 += [rel(mo[s]["D_uJ"], b["by_side_uJ"][s]) for s in sides]
        d2 += [rel(sum(mo[s]["by_layer_uJ"][L] for s in sides), b["by_layer_uJ"][L]) for L in E.LAYERS]
        gate(max(d2) < 1e-9, f"S2 model {M}: totals = d_rom.json (D {tot['D_uJ']:.4f} / {b['D_uJ']:.4f} uJ; "
                             f"largest relative difference {max(d2):.1e})")
        out["models"][M] = {"sides": mo, "totals": tot, "corrected_uJ": b["corrected_uJ"]}
    gate(worst1 < 1e-9, f"S1 replay copy = E8.6a-3's replay, every table of both models (largest relative difference "
                        f"{worst1:.1e})")
    od = a.out or os.path.join(root, "e8_4e_split.json")
    json.dump(out, open(od, "w"), indent=1)
    print(f"\nwritten: {od}  md5 {md5(od)}  ({time.time() - t0:.0f} s)")
    print("ALL CHECKS PASS" if nfail == 0 else f"{nfail} CHECK(S) FAILED: the split is not to be used")
    return 0 if nfail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
