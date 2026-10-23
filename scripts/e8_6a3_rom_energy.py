#!/usr/bin/env python3
"""
e8_6a3_rom_energy.py   (P2R-E8.6a-3)

D_ROM, the energy of the address-map ROM over one inference, recomputed from the
ROM clock pulses that the RTL of the address-map unit actually issues (E8.5:
reports/e8_rom/e8_5/e85_events_<M>.txt), instead of the read sequence that
E8.6a-2 derived from the E8.2 trace. The energy of each event comes from the
E8.4b models, through the functions of scripts/e8_6a2_rom_energy.py (imported,
not copied):
  lookup read  : model read energy of the word, given the word read before on
                 that macro (SideModel.read)
  parking read : model parking energy (SideModel.park)
  between reads: static power of the last word read (SideModel.ps), over the
                 time outside the 100 ns read windows (clock gated: no idle
                 clock energy)
The RTL decides everything else: which tables read (only the lanes that look up
the entry), when (cycle of the ROM clock edge x 10 ns), the 8-entry buffer
(an entry in the buffer is not read again), the reading ahead, and which tables
park and when (a table parks a macro after a lookup whose word has a zero bit).
Per inference: the pulses during the inference (phase I of the event list).
The pulses before the start (one lookup and one park of entry 0) are left out:
in back-to-back inferences entry 0 is already in the buffer (the idle bus reads
it again at the end of the inference, inside phase I).

Checks (all must pass before D is reported):
  C1 parking words: the words the RTL parks on (amu_park_<M>.vh) are those of
     E8.6a-2's choice (Table) for all 200 macros of each model (row and word
     value, which set the energy)
  C2 code: the replay function, given the reads and parks that E8.6a-2's
     simulate() makes for policy GPp on the E8.2 lookups with R, returns the
     same energy as simulate() for every table and both model forms
  C3 events: the reads and parks taken per table add up to those the event list
     implies, and to the counts of E8.5 (e8_5_summary_<M>.json); every lookup
     reads the macro of its entry; no read window of a macro overlaps the next
Uncertainty as E8.6a-2: E8.4b leave-one-table-out errors of the conv1, conv2
(parking) and fc1 trains per table, weighted by the lane's ROM reads of each
layer (here: the RTL lookups) x the measured energy per lookup; per side mean
and SE over 6 tables; range = D_side / (1 + mean +- 2 SE); corrected value =
D_side / (1 + mean).
Also printed: E8.6a-2's parking rule (GPp) applied to the RTL lookups, to show
the effect of the RTL's parking times; and E8.6a-2's figures for comparison.

Usage:
  python3 scripts/e8_6a3_rom_energy.py --paper2 /mnt/d/Project/hybrid_memory/paper2
Reads reports/e8_rom/e8_5/ (events, parking words, summaries), reports/e8_rom/trace/,
reports/e8_rom/e8_4b/model.json, data/; writes reports/e8_rom/e8_6a3/d_rom.json.
Imports scripts/e8_6a2_rom_energy.py (same directory).
"""
import argparse
import hashlib
import importlib.util
import json
import os
import re
import sys
import time

# E8.6a-2's figures (claude/p2r-e8-6a2-results.md), printed for comparison only
E86A2_R_GPP_BITS = {"A": 39.22, "B": 39.08}
E86A2_R_CORRECTED = {"A": 40.83, "B": 40.35}


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


def read_events(path):
    """lines 'L phase cycle m addr entry slot lanes' and 'P phase cycle m park_sram park_pcm' (E8.5 monitor)"""
    ev = []
    with open(path) as fh:
        for n, ln in enumerate(fh):
            if ln.startswith("#") or not ln.strip():
                continue
            f = ln.split()
            if f[0] == "L" and len(f) == 8:
                ev.append({"kind": "L", "phase": f[1], "cyc": int(f[2]), "m": int(f[3]), "addr": int(f[4], 16),
                           "entry": int(f[5]), "slot": int(f[6]), "lanes": int(f[7], 16), "line": n})
            elif f[0] == "P" and len(f) == 6:
                ev.append({"kind": "P", "phase": f[1], "cyc": int(f[2]), "m": int(f[3]),
                           "ps": int(f[4], 16), "pp": int(f[5], 16), "line": n})
            else:
                sys.exit(f"{path}: malformed line {n + 1}: {ln[:80]}")
    return ev


def read_park_vh(path):
    """index (side*100 + lane*4 + macro) -> address (row*16 + word), from amu_park_<M>.vh"""
    out = {}
    with open(path) as fh:
        for ln in fh:
            m = re.match(r"\s*(\d+):\s*amu_park\s*=\s*10'd(\d+);", ln)
            if m:
                out[int(m.group(1))] = int(m.group(2))
    return out


def table_events(ev, side, lane, phases):
    """the reads of one table, in time order: (T_ns, kind, macro, entry)"""
    out = []
    for e in ev:
        if e["phase"] not in phases:
            continue
        if e["kind"] == "L":
            if (e["lanes"] >> lane) & 1:
                out.append((e["cyc"] * 10.0, "L", e["m"], e["entry"]))
        else:
            mask = e["ps"] if side == "sram" else e["pp"]
            if (mask >> lane) & 1:
                out.append((e["cyc"] * 10.0, "P", e["m"], None))
    return out


def layer_of(E, e):
    for i in range(5):
        if E.OFFSET[i] <= e < E.OFFSET[i] + E.DEPTH[i]:
            return i
    return 4                                   # padding entries (not read by any operation)


def replay(E, tab, ev, sm, t_end_ns):
    """energy (pJ) of one table for an explicit list of reads; returns E, by layer, by bucket, reads, parks,
    overlapping windows (accounting as E8.6a-2's simulate: read window SLOT_NS, static outside the windows)"""
    rows = tab.rows
    st_w = [tab.park[k][1] for k in range(tab.nmac)]          # start: every macro parked
    st_rb = [rows - 1 - tab.park[k][0] for k in range(tab.nmac)]
    st_b = [5] * tab.nmac
    t_free = [0.0] * tab.nmac
    En = {"read": 0.0, "park": 0.0, "static": 0.0, "idle": 0.0}
    by_layer = [0.0] * 5
    by_bucket = [0.0] * 6
    n_read = n_park = overlap = 0

    def gap(k, t1):
        d = t1 - t_free[k]
        if d <= 0:
            return
        bkt = st_b[k] if sm.ps[st_w[k]] > sm.leak else 5
        e = sm.ps[st_w[k]] * d * 1e-3
        En["static"] += e
        by_bucket[bkt] += e

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
    return En, by_layer, by_bucket, n_read, n_park, overlap


def gpp_schedule(E, tab, lk):
    """the reads and parks that E8.6a-2's simulate() makes for policy GPp, as an explicit list (code check C2)"""
    out = []
    t_free = [0.0] * tab.nmac
    pend = []
    n = len(lk)
    for i, (cyc, layer, e) in enumerate(lk):
        T = cyc * E.CYCLE_NS
        k, r, w = tab.loc(e)
        if T < t_free[k]:
            T = t_free[k]
        out.append((T, "L", k, e))
        t_free[k] = T + E.SLOT_NS
        if k in pend:
            pend.remove(k)
        if E.zbits(w) and tab.park[k][1] != w:
            pend.append(k)
        if i + 1 < n:
            Tn, kn = lk[i + 1][0] * E.CYCLE_NS, tab.loc(lk[i + 1][2])[0]
        else:
            Tn, kn = None, None
        if k in pend and not (kn == k and Tn - T < 2 * E.SLOT_NS):
            out.append((T + E.SLOT_NS, "P", k, None))
            t_free[k] = T + 2 * E.SLOT_NS
            pend.remove(k)
    for k in list(pend):
        t = max(t_free[k], lk[-1][0] * E.CYCLE_NS + E.SLOT_NS) if lk else t_free[k]
        out.append((t, "P", k, None))
        t_free[k] = t + E.SLOT_NS
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--paper2", required=True)
    ap.add_argument("--model-json", default=None, help="default reports/e8_rom/e8_4b/model.json")
    ap.add_argument("--e85-dir", default=None, help="default reports/e8_rom/e8_5")
    ap.add_argument("--rows", type=int, default=48)
    ap.add_argument("--wpr", type=int, default=13)
    ap.add_argument("--table-words", type=int, default=2496)
    ap.add_argument("--out", default=None, help="default reports/e8_rom/e8_6a3/d_rom.json")
    a = ap.parse_args()
    t0 = time.time()
    here_f = os.path.abspath(__file__)
    e2_f = os.path.join(os.path.dirname(here_f), "e8_6a2_rom_energy.py")
    E = load_module(e2_f, "e8_6a2_rom_energy")
    root = os.path.join(a.paper2, "reports", "e8_rom")
    e85 = a.e85_dir or os.path.join(root, "e8_5")
    mj = a.model_json or os.path.join(root, "e8_4b", "model.json")
    print(f"P2R-E8.6a-3  {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"   script     : {md5(here_f)}  {here_f}")
    print(f"   E8.6a-2    : {md5(e2_f)}  {e2_f}")
    print(f"   E8.4b model: {md5(mj)}  {mj}")
    model = json.load(open(mj))
    if model.get("rows") != a.rows:
        print(f"   WARNING: the model was fitted on {model.get('rows')}-row macros; this run uses {a.rows} rows")
    sides = sorted(model["models"])
    leak, idle, choice = {}, {}, {}
    for side in sides:
        lm = [p["leak_mean_uW"] for p in model["parta"] if p["side"] == side and p["leak_mean_uW"] < 10.0]
        leak[side] = sum(lm) / len(lm)
        idle[side] = model["models"][side]["idle_parked_pJ"]
        print(f"   {side}: parked power {leak[side]:.3f} uW (mean of {len(lm)} macros)")
    for r in model["runs"]:
        if r["kind"] == "parta" and r.get("park_choice"):
            tok = r["park_choice"].split()[0]
            choice.setdefault(r["table"], {})[r["k"]] = int(tok) if tok.isdigit() else None
    forms = {f: {s: E.SideModel(model["models"][s], f, leak[s], idle[s]) for s in sides} for f in ("bits", "count")}
    out = {"script_md5": md5(here_f), "e86a2_md5": md5(e2_f), "model_json_md5": md5(mj), "models": {}}
    nfail = 0

    def gate(ok, txt):
        nonlocal nfail
        print(f"  {'PASS' if ok else 'FAIL'}  {txt}")
        if not ok:
            nfail += 1

    tables = {}
    for M in ("A", "B"):
        for side in sides:
            for lane in range(E.K):
                name = f"e8rom_{M}_{side}_l{lane:02d}_16x{a.table_words}"
                words = E.table_words(a.paper2, M, side, lane, a.table_words)
                tables[(M, side, lane)] = E.Table(words, a.rows, a.wpr, choice.get(name))

    # ---------------- C2: code check against E8.6a-2's simulate (GPp, R lookups of the E8.2 trace)
    print("\n==== C2 code check: replay of the GPp reads and parks of E8.6a-2 against simulate() ====")
    worst, nchk = 0.0, 0
    for M in ("A", "B"):
        tp = os.path.join(root, "trace", f"trace_{M}.txt")
        print(f"   trace {M}: {md5(tp)}  {tp}")
        lk, done, _, _ = E.parse_trace(tp)
        t_end = done * E.CYCLE_NS
        for side in sides:
            for lane in range(E.K):
                tab = tables[(M, side, lane)]
                lkr = E.skip_repeats(lk[lane])
                sch = gpp_schedule(E, tab, lkr)
                for form in ("bits", "count"):
                    sm = forms[form][side]
                    e1, _, _, _ = E.simulate(tab, lkr, sm, "GPp", t_end)
                    e2, _, _, _, _, _ = replay(E, tab, sch, sm, t_end)
                    for c in ("read", "park", "static"):
                        d = abs(e1[c] - e2[c]) / max(abs(e1[c]), 1e-12)
                        worst = max(worst, d)
                    nchk += 1
    gate(worst < 1e-9, f"C2 {nchk} table x form: largest relative difference {worst:.2e} (read, park, static)")

    for M in ("A", "B"):
        print(f"\n==== model {M} ====")
        evp = os.path.join(e85, f"e85_events_{M}.txt")
        vhp = os.path.join(e85, f"amu_park_{M}.vh")
        smp = os.path.join(e85, f"e8_5_summary_{M}.json")
        tp = os.path.join(root, "trace", f"trace_{M}.txt")
        for nm, p in (("events", evp), ("parking", vhp), ("E8.5 summary", smp)):
            print(f"   {nm:<12}: {md5(p)}  {p}")
        rv = os.path.join(a.paper2, "rtl", "e8", f"amu_park_{M}.vh")
        if os.path.isfile(rv):
            print(f"   rtl/e8 copy : {md5(rv)} ({'same' if md5(rv) == md5(vhp) else 'DIFFERENT'})")
        ev = read_events(evp)
        _, done, _, _ = E.parse_trace(tp)
        t_end = done * E.CYCLE_NS
        nL = {p: sum(1 for e in ev if e["kind"] == "L" and e["phase"] == p) for p in "BIA"}
        nP = {p: sum(1 for e in ev if e["kind"] == "P" and e["phase"] == p) for p in "BIA"}
        print(f"   pulses: lookup {nL}, parking {nP}; inference ends at cycle {done} ({t_end / 1e6:.3f} ms)")

        # C1: parking words
        pv = read_park_vh(vhp)
        same = diff = 0
        for si, side in enumerate(("sram", "pcm")):
            for lane in range(E.K):
                tab = tables[(M, side, lane)]
                for k in range(tab.nmac):
                    # Table keeps (row, word value); the RTL word must be in that row and hold that value
                    row = tab.park[k][0]
                    wpr = tab.wpr
                    cand = [w for w in range(wpr) if tab.words[k * tab.per + row * wpr + w] == tab.park[k][1]]
                    addr = pv.get(si * 100 + lane * 4 + k)
                    if addr is not None and (addr >> 4) == row and (addr & 15) in cand:
                        same += 1
                    else:
                        diff += 1
                        if diff <= 3:
                            print(f"      differs: {side} lane {lane} k{k}: RTL {addr}, Table row {row} word value "
                                  f"{tab.park[k][1]:04x}")
        nmac = sum(tables[(M, s_, ln)].nmac for s_ in ("sram", "pcm") for ln in range(E.K))
        gate(diff == 0 and same == nmac == 200, f"C1 parking words of the RTL = E8.6a-2's choice (row and word value, "
                                                f"which set the energy): {same} of {nmac} macros")

        # C3: events
        bad_map = sum(1 for e in ev if e["kind"] == "L" and (e["entry"] // (a.rows * a.wpr) != e["m"] or e["addr"] !=
                      ((e["entry"] % (a.rows * a.wpr)) // a.wpr) * 16 + e["entry"] % a.wpr))
        imp_l = [sum(bin(e["lanes"]).count("1") for e in ev if e["kind"] == "L")] * 2
        imp_p = [sum(bin(e["ps"]).count("1") for e in ev if e["kind"] == "P"),
                 sum(bin(e["pp"]).count("1") for e in ev if e["kind"] == "P")]
        got_l, got_p, ovl = [0, 0], [0, 0], 0
        res = {}
        for si, side in enumerate(("sram", "pcm")):
            for lane in range(E.K):
                tab = tables[(M, side, lane)]
                eva = table_events(ev, side, lane, ("B", "I", "A"))
                got_l[si] += sum(1 for x in eva if x[1] == "L")
                got_p[si] += sum(1 for x in eva if x[1] == "P")
                evi = table_events(ev, side, lane, ("I",))
                for form in ("bits", "count"):
                    En, bl, bb, nr, npk, ov = replay(E, tab, evi, forms[form][side], t_end)
                    if form == "bits":
                        ovl += ov
                    acc = res.setdefault((form, side), {"read": 0.0, "park": 0.0, "static": 0.0, "reads": 0,
                                                       "parks": 0, "by_layer": [0.0] * 5, "by_bucket": [0.0] * 6})
                    for c in ("read", "park", "static"):
                        acc[c] += En[c]
                    acc["reads"] += nr
                    acc["parks"] += npk
                    acc["by_layer"] = [x + y for x, y in zip(acc["by_layer"], bl)]
                    acc["by_bucket"] = [x + y for x, y in zip(acc["by_bucket"], bb)]
                # E8.6a-2's parking rule on the RTL lookups (information)
                lk_rtl = [(x[0] / E.CYCLE_NS, layer_of(E, x[3]), x[3]) for x in evi if x[1] == "L"]
                e1, _, npk1, _ = E.simulate(tab, lk_rtl, forms["bits"][side], "GPp", t_end)
                acc2 = res.setdefault(("rule", side), {"D": 0.0, "parks": 0})
                acc2["D"] += sum(e1[c] for c in ("read", "park", "static", "idle"))
                acc2["parks"] += npk1
        summ = json.load(open(smp)) if os.path.isfile(smp) else {}
        s_l = summ.get("macro_reads_lookup_sram_pcm")
        s_p = summ.get("macro_reads_parking_sram_pcm")
        gate(bad_map == 0, f"C3 lookup pulses on the macro and word of their entry: {bad_map} differ")
        gate(got_l == imp_l and got_p == imp_p,
             f"C3 reads per side taken by the tables = implied by the pulses: lookup {got_l} / {imp_l}, "
             f"parking {got_p} / {imp_p}")
        gate(s_l == got_l and s_p == got_p, f"C3 = E8.5 summary: lookup {s_l}, parking {s_p}")
        gate(ovl == 0, f"C3 read windows of a macro that overlap the next read: {ovl}")

        # uncertainty: E8.4b validation, weighted by the RTL lookups per lane and layer (inference only)
        lk_counts = {}
        for lane in range(E.K):
            c = {L: 0 for L in E.LAYERS}
            for x in table_events(ev, "sram", lane, ("I",)):
                if x[1] == "L":
                    c[E.LAYERS[layer_of(E, x[3])]] += 1
            lk_counts[(M, lane)] = c
        errs = E.validation_errors(model, lk_counts)
        print("   model error of the parking trains (E8.4b, leave one table out), weighted by the RTL lookups:")
        for (form, side), e in sorted(errs.items()):
            print(f"      {form:<5} {side:<4}: " + " ".join(f"{100 * x:+.1f}" for x in e["errors"]) +
                  f" %  -> mean {100 * e['mean']:+.1f} %, SE {100 * e['se']:.1f} %")

        mres = {}
        print("   D_ROM per inference, RTL schedule (E8.5), clock gated, parking as the RTL does it:")
        print(f"   {'form':<6} {'D uJ':>7} {'x 9.85':>7} | {'reads':>6} {'parks':>6} {'static':>7} uJ | "
              f"{'ROM reads':>9} {'parks':>6} | range (mean +- 2 SE) | corrected")
        for form in ("bits", "count"):
            r = {c: sum(res[(form, s)][c] for s in sides) for c in ("read", "park", "static", "reads", "parks")}
            D = (r["read"] + r["park"] + r["static"]) * 1e-6
            by_side = {s: (res[(form, s)]["read"] + res[(form, s)]["park"] + res[(form, s)]["static"]) * 1e-6
                       for s in sides}
            lo = hi = cor = 0.0
            ok = True
            for s in sides:
                e = errs.get((form, s))
                if e is None:
                    ok = False
                    break
                lo += by_side[s] / (1 + e["mean"] + 2 * e["se"])
                hi += by_side[s] / (1 + e["mean"] - 2 * e["se"])
                cor += by_side[s] / (1 + e["mean"])
            rng = f"{lo:7.3f}-{hi:7.3f}" if ok else "       -       "
            cs = f"{cor:.3f}" if ok else "-"
            print(f"   {form:<6} {D:7.3f} {D / E.MANUSCRIPT_D_UJ:7.2f} | {r['read'] * 1e-6:6.3f} {r['park'] * 1e-6:6.3f} "
                  f"{r['static'] * 1e-6:7.3f}    | {r['reads']:9d} {r['parks']:6d} | {rng}      | {cs}")
            mres[form] = {"D_uJ": D, "by_side_uJ": by_side, "read_uJ": r["read"] * 1e-6, "park_uJ": r["park"] * 1e-6,
                          "static_uJ": r["static"] * 1e-6, "rom_reads": r["reads"], "parks": r["parks"],
                          "range_uJ": [lo, hi] if ok else None, "corrected_uJ": cor if ok else None}
        b = mres["bits"]
        bl = [sum(res[("bits", s)]["by_layer"][i] for s in sides) for i in range(5)]
        bb = [sum(res[("bits", s)]["by_bucket"][i] for s in sides) for i in range(6)]
        print("   bits, by side: " + ", ".join(f"{s} {v:.3f} uJ" for s, v in b["by_side_uJ"].items()))
        print("   bits, by layer (reads + parks + static above the parked level; uJ): " +
              ", ".join(f"{E.LAYERS[i]} {(bl[i] + bb[i]) * 1e-6:.3f}" for i in range(5)) +
              f"; parked level (leakage) {bb[5] * 1e-6:.3f}")
        b["by_layer_uJ"] = {E.LAYERS[i]: (bl[i] + bb[i]) * 1e-6 for i in range(5)}
        b["by_layer_uJ"]["parked"] = bb[5] * 1e-6
        rule = sum(res[("rule", s)]["D"] for s in sides) * 1e-6
        rparks = sum(res[("rule", s)]["parks"] for s in sides)
        print(f"   information: E8.6a-2's parking rule (GPp) on the same RTL lookups: {rule:.3f} uJ, {rparks} parks "
              f"(RTL: {b['D_uJ']:.3f} uJ, {b['parks']} parks)")
        b["e86a2_rule_on_rtl_lookups_uJ"] = rule
        print(f"   E8.6a-2 (R, GPp, bits; read sequence from the E8.2 trace): {E86A2_R_GPP_BITS[M]:.2f} uJ, corrected "
              f"{E86A2_R_CORRECTED[M]:.2f} uJ -> now {b['D_uJ']:.3f} uJ, corrected "
              + (f"{b['corrected_uJ']:.3f} uJ" if b["corrected_uJ"] is not None else "-"))
        out["models"][M] = mres

    print("\nsummary (D_ROM per inference, uJ, bits form; manuscript 9.85):")
    for M in ("A", "B"):
        b = out["models"][M]["bits"]
        rg = b["range_uJ"]
        print(f"   model {M}: {b['D_uJ']:.3f}" + (f" (range {rg[0]:.3f}-{rg[1]:.3f}; corrected {b['corrected_uJ']:.3f})"
                                                  if rg else "") +
              f"; count form {out['models'][M]['count']['D_uJ']:.3f}; {b['rom_reads']} ROM reads, {b['parks']} parks")
    od = a.out or os.path.join(root, "e8_6a3", "d_rom.json")
    os.makedirs(os.path.dirname(od), exist_ok=True)
    json.dump(out, open(od, "w"), indent=1)
    print(f"\nwritten: {od}  ({time.time() - t0:.0f} s)")
    print("ALL CHECKS PASS" if nfail == 0 else f"{nfail} CHECK(S) FAILED: D is not to be used")
    return 0 if nfail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
