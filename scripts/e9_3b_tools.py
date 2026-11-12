#!/usr/bin/env python3
"""P2R-E9.3b tools (run by scripts/e9_3b_rom_check.sh): new held-out windows for the lookup model of the
address-map ROM of E9 (rules: protocol P2R-E9.3b of 2026-11-12).

Why: the check window of A k1 in E9.3 was 12.3 % above its fit (gate V3, limit 10 %). The read energy of
this NAND-type ROM grows with the row's distance from the footer (about 0.6 pJ per row; the 658 reads of
E9.2 confirm it, r2 0.987-0.999 per macro), and the fits of E9.3 had only zero bits. I chose on
2026-11-12 17:04 to fix a lookup model with the row position before any new run and to test it on
windows it has not seen.

  plan   one run per macro: 300 ns unread; macro 0 six lookup-and-park pairs of the convolution layers that
         E9.3 did not use (the quantiles 1/12, 3/12, ..., 11/12 of the zero bits of the rest; a collision
         takes the nearest unused one), each after 300 ns parked; one window N of 16 consecutive real lookups
         of a dense run that shares no lookup with the windows of E9.3 and whose mean row position (47 - row)
         is the farthest from every row position E9.3 sampled in that macro (ties: the earliest), ended by
         the parking read 5 cycles after the last lookup and 400 ns parked.
  judge  W4 (the inputs the rules were fixed on): the lookup model refitted from the 420 E9.3 lookups equals
         FIXED, and the replay with the fits of E9.3 equals E9.3's D_ROM. Then the models fixed before the
         runs predict the new samples: W0 every read correct (data, row and word selection), W1 every run
         complete (ngspice exit 0, every cycle simulated), W2 per model the measured sum of the 7 new windows
         (lookups 2..15 of each) within 5 % of the fixed lookup model, W3 per model the measured sum of the
         6 new pairs within 10 % of E9.3's pair fit. Final D_ROM: the lookup model refitted on every window
         of E9.3 and E9.3b, the pair fit of each model refitted on its 12 pairs (the E9.3 rule), everything
         else as in E9.3; replayed over the inference as in E9.3.

Lookup model, one set of coefficients for the 14 macros (the same circuit), for the energy from a lookup's
rising clock edge to the next read's, normalised to 9 cycles low (E9 of E9.3):
    E9 = c0 + c1 * (47 - row) + c2 * zero bits of the row + c3 * zero bits of the word   [pJ]
Energy is E_vdd of scripts/e8_4_rom_bench.py, as in E9.3.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e9_3_tools as T  # noqa: E402  (the E9.3 tools, unchanged)

E93_PLAN_MD5 = "df6400b4c7f49cf82f451ed111559cc5"
# the lookup model fitted on the 420 lookups of E9.3 (windows L, H, C; lookups 2..15), fixed before E9.3b
FIXED = [9.674265994669717, 0.6014292941852739, 0.16986581071515877, 0.8069207105200343]
E93_D_ROM = {"A": 0.11674358900410067, "B": 0.1143948284786322}     # e9_3_summary.json of E9.3
NEW_CONV_Q = (1 / 12, 3 / 12, 5 / 12, 7 / 12, 9 / 12, 11 / 12)
G_DENSE = 0.05
G_CONV = 0.10
NROWS = T.NWORDS // T.WPR
PARTS = ("dense lookups (to the next read, 9 cycles low)", "static of unparked gaps beyond 9 cycles",
         "last lookup of a dense run (parked 5 cycles later)", "parking reads after a dense run",
         "convolution lookup-and-park pairs (macro 0)", "parked", "unread (before the first read)")


def pos(addr):
    """the row's distance from the footer end of the bitline chains (row 47: 0, row 0: 47)"""
    return NROWS - 1 - addr // T.WPR


def lpred(c, s):
    return c[0] + c[1] * s["pos"] + c[2] * s["z_row"] + c[3] * s["z_word"]


def lfit(samples):
    return T.lstsq([[1.0, s["pos"], s["z_row"], s["z_word"]] for s in samples], [s["E9"] for s in samples])


def name_of(M, m):
    return f"e9rom_{M}_40x2688_w8_r48k{m}"


def close(a, b, rel=1e-9):
    return abs(a - b) <= rel * max(abs(a), abs(b), 1e-300)


# ------------------------------------------------------------------ plan
def cmd_plan(a):
    if T.md5(a.plan3) != E93_PLAN_MD5:
        sys.exit(f"{a.plan3}: not the plan of E9.3 the rules were fixed on (md5 {E93_PLAN_MD5})")
    p3 = json.load(open(a.plan3))
    plan = {"rules": "protocol P2R-E9.3b (2026-11-12), fixed before the run", "e9_3_plan_md5": E93_PLAN_MD5, "runs": {}, "models": {}}
    for M in ("A", "B"):
        evp = os.path.join(a.e91, f"e9ev_normal_{M}.txt")
        bm = T.by_macro(T.read_events(evp))
        plan["models"][M] = {"events_md5": T.md5(evp)}
        for m in range(T.NM):
            key = f"{M}_k{m}"
            r3 = p3["runs"][key]
            name = name_of(M, m)
            words = T.read_words(os.path.join(a.bins, f"{name}.bin"))
            if words[T.PARK] != (1 << T.WBITS) - 1:
                sys.exit(f"{name}: word {T.PARK} is not all ones")
            rz = T.row_zeros(words)
            seq = bm[m]
            used = {x["cycle"] for x in r3["roles"] if x.get("role") == "dense"}
            sampled = sorted({pos(x["addr"]) for x in r3["roles"]
                              if x.get("role") == "dense" and 1 <= x["j"] <= T.NWIN - 2})
            cand = []
            for w in T.windows(seq, words):
                if any(seq[i][2] in used for i in w[0]):
                    continue
                mp = sum(pos(seq[i][4]) for i in w[0]) / T.NWIN
                cand.append((min(abs(mp - p) for p in sampled), w, mp))
            if not cand:
                sys.exit(f"{name}: no window of {T.NWIN} lookups apart from the windows of E9.3")
            dist, wn, mp = max(cand, key=lambda x: (x[0], -x[1][0][0]))
            segs = [("wait", T.W_UNREAD, "unread")]
            conv = []
            if m == 0:
                done3 = set(r3["conv_pairs"])
                cc = [i for i, e in enumerate(seq) if e[0] == "L" and e[1] == "I" and i + 1 < len(seq)
                      and seq[i + 1][0] == "P" and (i == 0 or seq[i - 1][0] == "P") and e[2] not in done3]
                order = sorted(cc, key=lambda i: (T.zeros(words[seq[i][4]]), i))
                pick = []
                for q in NEW_CONV_Q:
                    k = round(q * (len(order) - 1))
                    for dk in range(len(order)):
                        hit = next((kk for kk in (k + dk, k - dk) if 0 <= kk < len(order) and order[kk] not in pick), None)
                        if hit is not None:
                            pick.append(order[hit])
                            break
                conv = sorted(pick)
                for j, i in enumerate(conv):
                    e = seq[i]
                    segs.append(("wait", T.W_CONV, "parked_conv"))
                    segs.append(("read", e[4], 5, "conv_L", {"j": j, "cycle": e[2], "z_word": T.zeros(words[e[4]]),
                                                             "z_row": rz[e[4] // T.WPR]}))
                    segs.append(("read", T.PARK, 5, "conv_P", {"j": j, "z_word": 0, "z_row": rz[T.PARK // T.WPR]}))
            segs += T.plan_window(seq, words, wn[0], rz, "N", T.W_PARKED_END)
            toks, roles = T.seq_tokens(segs)
            plan["runs"][key] = {
                "model": M, "macro": m, "name": name, "seq": toks, "roles": roles,
                "windows": {"N": {"first_cycle": seq[wn[0][0]][2], "mean_z": wn[1], "mean_pos": mp, "distance": dist,
                                  "rows": sorted({seq[i][4] // T.WPR for i in wn[0]})}},
                "sampled_pos_e9_3": sampled, "conv_pairs": [seq[i][2] for i in conv],
                "conv_pairs_z": [T.zeros(words[seq[i][4]]) for i in conv]}
    json.dump(plan, open(a.out, "w"), indent=1)
    tot = 0.0
    for k, r in plan["runs"].items():
        nread = sum(1 for x in r["roles"] if x.get("addr") is not None)
        t = T.PERIOD * nread + sum(float(tok[1:]) for tok in r["seq"].split(",") if tok[0] == "w")
        tot += t
        w = r["windows"]["N"]
        print(f"   {k:5s} {r['name']}: {nread} reads, {t / 1000:.2f} us simulated; window N from cycle {w['first_cycle']}, "
              f"rows {w['rows'][0]}..{w['rows'][-1]} (mean position {w['mean_pos']:.1f}, {w['distance']:.1f} rows from the "
              f"positions of E9.3 {r['sampled_pos_e9_3'][0]}..{r['sampled_pos_e9_3'][-1]}), mean zero bits {w['mean_z']:.2f}"
              + (f"; new convolution pairs at cycles {r['conv_pairs']} (zero bits {r['conv_pairs_z']})" if r["conv_pairs"] else ""))
    print(f"   {len(plan['runs'])} runs, {tot / 1000:.1f} us simulated in all; written {a.out}")
    return 0


# ------------------------------------------------------------------ judge
def extract(d, roles):
    """the samples of one run, in the way of the E9.3 judge"""
    cr, why = T.run_cycles(d, roles)
    if cr is None:
        return None, why
    out = {"dense": [], "last": [], "parks": [], "conv": [], "unread": None}
    rd = [c for c, rr in cr if c["kind"] == "read"]
    out["reads"] = len(rd)
    out["reads_ok"] = sum(1 for c in rd if c.get("ok") and c.get("selection_ok", True))
    out["selection_shown"] = sum(1 for c in rd if "selection_ok" in c)
    for (i, e, p_last, e_own) in T.periods(cr):
        rr = cr[i][1]
        if rr["role"] == "dense":
            s = {"win": rr["win"], "j": rr["j"], "addr": rr["addr"], "z_word": rr["z_word"], "z_row": rr["z_row"],
                 "pos": pos(rr["addr"]), "low_after": rr["low_after"]}
            if 1 <= rr["j"] <= T.NWIN - 2:
                s["P_s"] = p_last
                s["E"] = e
                s["E9"] = e - p_last * 1e-6 * (rr["low_after"] - 9) * T.CYC * 1e-9 * 1e12
                out["dense"].append(s)
            elif rr["j"] == T.NWIN - 1:
                s["E5"] = e_own
                out["last"].append(s)
        elif rr["role"] == "park_end":
            out["parks"].append({"win": rr["win"], "E_window": e_own, "P_parked": p_last})
        elif rr["role"] == "conv_L":
            out["conv"].append({"j": rr["j"], "addr": rr["addr"], "z_word": rr["z_word"], "z_row": rr["z_row"],
                                "pos": pos(rr["addr"]), "E_L5": e_own})
        elif rr["role"] == "conv_P":
            out["conv"][-1]["E_P"] = e_own
            out["conv"][-1]["P_parked_after"] = p_last
    for c, rr in cr:
        if rr["role"] == "unread" and out["unread"] is None:
            out["unread"] = c["P_after_uW"]
    for x in out["conv"]:
        x["E_pair"] = x["E_L5"] + x["E_P"]
    return out, None


def replay(M, e91, bins, mf):
    """the replay of the E9.3 judge; mf(m) gives e9(s), ps(s), conv(s) or None, e_park, p_parked, unread"""
    uJ_static = lambda p_uW, ns: p_uW * 1e-6 * ns * 1e-9 * 1e6      # noqa: E731
    bm = T.by_macro(T.read_events(os.path.join(e91, f"e9ev_normal_{M}.txt")))
    parts = {k: 0.0 for k in PARTS}
    counts = {"L": 0, "P": 0}
    for m in range(T.NM):
        f = mf(m)
        words = T.read_words(os.path.join(bins, f"{name_of(M, m)}.bin"))
        rz = T.row_zeros(words)
        seq = [e for e in bm[m] if e[1] != "B"]
        pre = [e for e in bm[m] if e[1] == "B"]
        first = seq[0][2] if seq else T.T_INF_CYCLES
        if pre:
            parts["parked"] += uJ_static(f["p_parked"], first * T.CYC)
        else:
            parts["unread (before the first read)"] += uJ_static(f["unread"], first * T.CYC)
        paired = False
        for n, e in enumerate(seq):
            nxt = seq[n + 1] if n + 1 < len(seq) else None
            prev = seq[n - 1] if n > 0 else None
            lo = nxt[5] if nxt else max(T.T_INF_CYCLES - e[2] - 5, 0)
            s = {"z_word": T.zeros(words[e[4]]), "z_row": rz[e[4] // T.WPR], "pos": pos(e[4])}
            if e[0] == "L":
                counts["L"] += 1
                paired = False
                if nxt and nxt[0] == "P" and lo == 5:
                    if f["conv"] is not None and (prev is None or prev[0] == "P"):
                        parts["convolution lookup-and-park pairs (macro 0)"] += f["conv"](s) * 1e-6
                        paired = True
                    else:
                        parts["last lookup of a dense run (parked 5 cycles later)"] += \
                            (f["e9"](s) - f["ps"](s) * 1e-6 * 4 * T.CYC * 1e-9 * 1e12) * 1e-6
                else:
                    parts["dense lookups (to the next read, 9 cycles low)"] += f["e9"](s) * 1e-6
                    if lo != 9:
                        parts["static of unparked gaps beyond 9 cycles"] += uJ_static(f["ps"](s), (lo - 9) * T.CYC)
            else:
                counts["P"] += 1
                if not paired:
                    parts["parking reads after a dense run"] += f["e_park"] * 1e-6
                paired = False
                parts["parked"] += uJ_static(f["p_parked"], max(lo * T.CYC - T.PERIOD / 2, 0.0))
    return sum(parts.values()), parts, counts


def cmd_judge(a):
    out = {"rules": "protocol P2R-E9.3b (2026-11-12), fixed before the run", "gates": {}, "new_windows": {}, "new_pairs": {},
           "static_check": {}, "D_ROM_fixed_models": {}, "D_ROM_final": {}}
    print("P2R-E9.3b held-out check of the lookup model (rules written before the run: "
          "protocol P2R-E9.3b of 2026-11-12)")
    exp_coef = [float(x) for x in a.expect_coef.split(",")] if a.expect_coef else FIXED
    exp_d = dict(zip("AB", (float(x) for x in a.expect_d_rom.split(",")))) if a.expect_d_rom else E93_D_ROM
    # ---- W4: the inputs the rules were fixed on
    w4 = [T.md5(a.plan3) == E93_PLAN_MD5 or bool(a.expect_d_rom)]
    p3 = json.load(open(a.plan3))
    e93, bad3 = {}, []
    for key, r in p3["runs"].items():
        x, why = extract(os.path.join(a.runs3, key), r["roles"])
        if x is None:
            bad3.append(f"{key}: {why}")
        else:
            e93[key] = x
    w4.append(not bad3 and len(e93) == 2 * T.NM)
    fits3 = {}
    for key, x in e93.items():
        lh = [s for s in x["dense"] if s["win"] in ("L", "H")]
        r = p3["runs"][key]
        fits3[(r["model"], r["macro"])] = {
            "fe": T.fit(lh, "E9"), "fp": T.fit(lh, "P_s"),
            "fc": T.fit(x["conv"], "E_pair") if len(x["conv"]) >= 4 else None,
            "e_park": sum(p["E_window"] for p in x["parks"]) / len(x["parks"]),
            "p_parked": sum(p["P_parked"] for p in x["parks"]) / len(x["parks"]), "unread": x["unread"]}
    d93 = {}
    if all(w4):
        for M in ("A", "B"):
            mf = lambda m, M=M: {"e9": lambda s, f=fits3[(M, m)]: T.pred(f["fe"], s),          # noqa: E731
                                 "ps": lambda s, f=fits3[(M, m)]: T.pred(f["fp"], s),
                                 "conv": (lambda s, f=fits3[(M, m)]: T.pred(f["fc"], s)) if fits3[(M, m)]["fc"] else None,
                                 "e_park": fits3[(M, m)]["e_park"], "p_parked": fits3[(M, m)]["p_parked"],
                                 "unread": fits3[(M, m)]["unread"]}
            d93[M] = replay(M, a.e91, a.bins, mf)
        w4.append(all(close(d93[M][0], exp_d[M]) for M in "AB"))
    all3 = [s for x in e93.values() for s in x["dense"]]
    coef3 = lfit(all3) if all3 else None
    w4.append(coef3 is not None and len(all3) == 420 and all(close(c, e) for c, e in zip(coef3, exp_coef)))
    g4 = all(w4)
    out["gates"]["W4"] = g4
    print(f"   {'PASS' if g4 else 'FAIL'}  W4 the inputs of the rules: plan of E9.3 {T.md5(a.plan3)[:8]}..; "
          + (f"{len(e93)} runs of E9.3; " if not bad3 else f"E9.3 runs: {'; '.join(bad3)}; ")
          + (f"replay with the fits of E9.3 {d93['A'][0]:.6f} / {d93['B'][0]:.6f} uJ (E9.3: {exp_d['A']:.6f} / "
             f"{exp_d['B']:.6f}); " if d93 else "")
          + (f"lookup model from the {len(all3)} lookups of E9.3: {', '.join(f'{c:.6g}' for c in coef3)} "
             f"(fixed: {', '.join(f'{c:.6g}' for c in exp_coef)})" if coef3 else "no lookup model"))
    if not g4:
        json.dump(out, open(a.out, "w"), indent=1)
        print("   NOT ALL PASS (W4: the inputs are not the ones the rules were fixed on; nothing else judged)")
        return 1
    # ---- the new runs
    plan = json.load(open(a.plan))
    eb, bad = {}, []
    reads = ok = shown = 0
    for key, r in plan["runs"].items():
        d = os.path.join(a.runs, key)
        if not os.path.isfile(os.path.join(d, "result.json")):
            bad.append(f"{key}: no result.json")
            continue
        ec = os.path.join(d, "exit_code")
        if os.path.isfile(ec) and open(ec).read().strip() != "0":
            bad.append(f"{key}: ngspice exit {open(ec).read().strip()}")
            continue
        x, why = extract(d, r["roles"])
        if x is None:
            bad.append(f"{key}: {why}")
            continue
        reads += x["reads"]
        ok += x["reads_ok"]
        shown += x["selection_shown"]
        if len([s for s in x["dense"] if s["win"] == "N"]) != T.NWIN - 2 or (r["macro"] == 0 and len(x["conv"]) != len(NEW_CONV_Q)):
            bad.append(f"{key}: the run lacks a part of the plan")
            continue
        eb[key] = x
    g01 = not bad and len(eb) == 2 * T.NM and ok == reads and reads > 0
    out["gates"]["W0_W1"] = g01
    out["reads"] = {"total": reads, "correct": ok, "selection_shown": shown}
    print(f"   {'PASS' if g01 else 'FAIL'}  W0/W1 every run complete, every read correct: {ok} of {reads} reads "
          f"(data; row and word selection shown for {shown}), {len(eb)} of {2 * T.NM} runs"
          + ("" if not bad else "; " + "; ".join(bad)))
    # ---- W2: the new windows against the fixed lookup model
    g2 = g01
    print("   new windows (lookups 2..15), measured and fixed model (E9 + static beyond 9 cycles of the E9.3 fit):")
    for M in ("A", "B"):
        meas = prd = 0.0
        for m in range(T.NM):
            key = f"{M}_k{m}"
            if key not in eb:
                continue
            fp = fits3[(M, m)]["fp"]
            ss = [s for s in eb[key]["dense"] if s["win"] == "N"]
            me = sum(s["E"] for s in ss)
            pr = sum(lpred(exp_coef, s) + T.pred(fp, s) * 1e-6 * (s["low_after"] - 9) * T.CYC * 1e-9 * 1e12 for s in ss)
            meas += me
            prd += pr
            w = plan["runs"][key]["windows"]["N"]
            out["new_windows"][key] = {"measured_pJ": me, "predicted_pJ": pr, "rel": pr / me - 1, "rows": w["rows"],
                                       "mean_pos": w["mean_pos"]}
            print(f"      {key}: rows {w['rows'][0]}..{w['rows'][-1]} (position {w['mean_pos']:.1f}): measured {me:.1f} pJ, "
                  f"model {pr:.1f} pJ ({pr / me - 1:+.1%})")
        rel = prd / meas - 1 if meas else float("nan")
        okM = meas > 0 and abs(rel) <= G_DENSE
        g2 = g2 and okM
        out["new_windows"][M] = {"measured_pJ": meas, "predicted_pJ": prd, "rel": rel}
        print(f"      model {M}: the 7 new windows together: measured {meas:.1f} pJ, model {prd:.1f} pJ ({rel:+.2%})")
    out["gates"]["W2"] = g2
    print(f"   {'PASS' if g2 else 'FAIL'}  W2 per model the sum of the new windows within {G_DENSE:.0%} of the fixed lookup model")
    # ---- W3: the new pairs against E9.3's pair fit
    g3 = g01
    for M in ("A", "B"):
        key = f"{M}_k0"
        fc = fits3[(M, 0)]["fc"]
        if key not in eb or fc is None:
            g3 = False
            continue
        meas = sum(x["E_pair"] for x in eb[key]["conv"])
        prd = sum(T.pred(fc, x) for x in eb[key]["conv"])
        rel = prd / meas - 1
        g3 = g3 and abs(rel) <= G_CONV
        out["new_pairs"][M] = {"measured_pJ": meas, "predicted_pJ": prd, "rel": rel, "pairs": eb[key]["conv"]}
        print(f"      model {M}: 6 new convolution pairs: measured {meas:.1f} pJ, E9.3 fit ({fc['form']}) {prd:.1f} pJ ({rel:+.2%}); "
              + ", ".join(f"z {x['z_word']} row {x['addr'] // T.WPR}: {x['E_pair']:.1f} ({T.pred(fc, x):.1f})" for x in eb[key]["conv"]))
    out["gates"]["W3"] = g3
    print(f"   {'PASS' if g3 else 'FAIL'}  W3 per model the sum of the new pairs within {G_CONV:.0%} of the E9.3 fit")
    # ---- static levels measured again (reported)
    print("   static levels again (E9.3b against E9.3; reported, not gated): unread uW, parked uW")
    for key in sorted(eb):
        r = plan["runs"][key]
        f3 = fits3[(r["model"], r["macro"])]
        pk = [p["P_parked"] for p in eb[key]["parks"]]
        out["static_check"][key] = {"unread": [eb[key]["unread"], f3["unread"]], "parked": [pk[0] if pk else None, f3["p_parked"]]}
        print(f"      {key}: unread {eb[key]['unread']:.3f} ({f3['unread']:.3f}); parked {pk[0]:.3f} ({f3['p_parked']:.3f})")
    ok_all = g4 and g01 and g2 and g3
    # ---- D_ROM: the models fixed before the runs, and the final refit
    allb = [s for x in eb.values() for s in x["dense"]]
    coef_f = lfit(all3 + allb)
    fc_f = {}
    for M in ("A", "B"):
        key = f"{M}_k0"
        pairs = e93[key]["conv"] + (eb[key]["conv"] if key in eb else [])
        fc_f[M] = T.fit(pairs, "E_pair")

    def mfun(M, coef, fcs):
        def mf(m):
            f = fits3[(M, m)]
            return {"e9": lambda s: lpred(coef, s), "ps": lambda s: T.pred(f["fp"], s),
                    "conv": (lambda s: T.pred(fcs[M], s)) if m == 0 and fcs.get(M) else None,
                    "e_park": f["e_park"], "p_parked": f["p_parked"], "unread": f["unread"]}
        return mf
    print(f"==== D_ROM: replay of every ROM read of one inference (E9.1 event lists) over {T.T_INF_CYCLES} cycles")
    print(f"   lookup model refitted on {len(all3 + allb)} lookups (E9.3 and E9.3b): "
          f"E9 = {coef_f[0]:.4f} + {coef_f[1]:.4f} * position + {coef_f[2]:.4f} * row zero bits + {coef_f[3]:.4f} * word zero bits pJ")
    for M in ("A", "B"):
        t0, p0, _ = replay(M, a.e91, a.bins, mfun(M, exp_coef, {M: fits3[(M, 0)]["fc"]}))
        t1, p1, c1 = replay(M, a.e91, a.bins, mfun(M, coef_f, fc_f))
        out["D_ROM_fixed_models"][M] = {"uJ": t0, "parts_uJ": p0}
        out["D_ROM_final"][M] = {"uJ": t1, "parts_uJ": p1, "reads": c1, "pair_fit": fc_f[M],
                                 "valid": ok_all}
        print(f"   model {M}: D_ROM {t1:.4f} uJ per inference{'' if ok_all else ' (NOT VALID: a gate failed)'} "
              f"({c1['L']} lookups, {c1['P']} parking reads); with the models fixed before the runs {t0:.4f}; "
              f"E9.3 {d93[M][0]:.4f}")
        for k in PARTS:
            print(f"      {k:52s} {p1[k]:.5f} uJ")
        print(f"      convolution pair fit on {len(e93[f'{M}_k0']['conv']) + len(eb.get(f'{M}_k0', {}).get('conv', []))} pairs: "
              f"{fc_f[M]['form']}, {', '.join(f'{c:.4g}' for c in fc_f[M]['coef'])} (leave-one-out {fc_f[M]['loo_rel']:.1%})")
    out["lookup_model_final"] = coef_f
    out["lookup_model_fixed"] = exp_coef
    out["all_pass"] = ok_all
    json.dump(out, open(a.out, "w"), indent=1)
    print(f"   {'ALL PASS' if ok_all else 'NOT ALL PASS'}; written {a.out}")
    return 0 if ok_all else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("plan")
    s.add_argument("--plan3", required=True, help="the plan of E9.3 (reports/e9_rom/e9_3/plan.json)")
    s.add_argument("--e91", required=True, help="the E9.1 event lists (reports/e9/e9_1/rtl)")
    s.add_argument("--bins", required=True, help="the macro images of E9.2 (reports/e9_rom/e9_2/bins)")
    s.add_argument("--out", required=True)
    s = sp.add_parser("judge")
    s.add_argument("--plan3", required=True)
    s.add_argument("--runs3", required=True, help="the runs of E9.3 (reports/e9_rom/e9_3/runs)")
    s.add_argument("--plan", required=True)
    s.add_argument("--runs", required=True)
    s.add_argument("--e91", required=True)
    s.add_argument("--bins", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--expect-coef", default="", help=argparse.SUPPRESS)      # for tests only
    s.add_argument("--expect-d-rom", default="", help=argparse.SUPPRESS)     # for tests only
    a = ap.parse_args()
    return {"plan": cmd_plan, "judge": cmd_judge}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
