#!/usr/bin/env python3
"""P2R-E9.3 tools (run by scripts/e9_3_rom_energy.sh): the energy of the address-map ROM of E9 (D_ROM).

  plan   the read sequences of the post-layout runs, chosen by rules fixed before the run
         (protocol P2R-E9.3 of 2026-11-12), from the E9.1 event lists and the macro images; one run
         per macro:
           - 300 ns with the clock low before any read (the unread state);
           - macro 0 only: 6 real lookup-and-park pairs of the convolution layers (the lookups at the
             quantiles 0, 0.2, ..., 1 of their zero bits), each after 300 ns parked;
           - two windows of 16 consecutive real lookups of the macro's dense runs with their real
             clock-low times, L the fewest zero bits on average and H the most (not overlapping); each
             ends with the parking read 5 cycles after the last lookup (as the unit parks) and 300 ns
             parked (400 ns after the last window);
           - model A macro 1 and model B macro 6: a third window C (the mean closest to the mean of all
             dense lookups of the macro), to check the fit.
         A read with L cycles of clock low before it is the bench tokens w(L*10-50) r<addr>.
  judge  per macro, from the lookups 2..15 of the windows L and H (28 samples): the energy of a lookup
         period (rising clock edge to the next one, normalised to 9 cycles low) and the static power at the
         end of the clock-low time after it, each fitted on the zero bits of the word, of its row, or both
         (the form with the lowest leave-one-out error); the parking read and the parked static power; the
         unread static power; macro 0 the lookup-and-park pairs. Then the replay of every ROM read of one
         inference (E9.1 event lists) over the inference window of E9.4 -> D_ROM per model and its parts.
         Gates: V0 every read correct (data, and the row and word selected where the probes show them),
         V1 every run complete (ngspice exit 0, every cycle simulated), V2 per macro the leave-one-out error
         of the lookup period <= 10 %, V3 the two check windows within 10 % of the fit.

Energy is the supply energy of the macro (E_vdd of scripts/e8_4_rom_bench.py), as in E8.4b / E8.6a-3; the
energy the ideal input sources of the bench deliver (E_in) is not used, as in E8.
"""
import argparse
import json
import math
import os
import sys

NM = 7                 # macros per model
WPR = 8                # words per row
WBITS = 40
NWORDS = 384           # words per macro (383 entries + the parking word at 383)
PARK = 383
PERIOD = 100.0         # ns, a read cycle of the bench: 50 ns clock low, 50 ns high
CYC = 10.0             # ns, the system clock
NWIN = 16              # lookups of a dense window
DENSE_LOW = 12         # a lookup is dense if the clock was low at most this many cycles before it
NCONV = 6              # lookup-and-park pairs of macro 0
W_UNREAD = 300         # ns
W_PARKED_END = 400     # ns, parked at the end of a run
W_PARKED_MID = 300     # ns, parked between two windows
W_CONV = 250           # ns of wait before each convolution lookup (+ 50 ns of the read cycle = 300 ns low)
T_INF_CYCLES = 617574  # the inference window of E9.4: 6.17574 ms (8165 ns to 6183910 ns, 10 ns cycles)


# ------------------------------------------------------------------ inputs
def read_words(path):
    b = open(path, "rb").read()
    if len(b) != NWORDS * 5:
        sys.exit(f"{path}: {len(b)} bytes, expected {NWORDS * 5}")
    return [int.from_bytes(b[5 * i:5 * i + 5], "big") for i in range(NWORDS)]


def zeros(w):
    return WBITS - bin(w).count("1")


def row_zeros(words):
    return [sum(zeros(words[r * WPR + k]) for k in range(WPR)) for r in range(NWORDS // WPR)]


def read_events(path):
    """events of the E9.1 event list: (kind, phase, cycle, macro, addr or None, low)"""
    ev = []
    for ln in open(path, errors="replace"):
        f = ln.split()
        if not f or f[0].startswith("#"):
            continue
        if f[0] == "L":
            ev.append(("L", f[1], int(f[2]), int(f[3]), int(f[4], 16), int(f[7])))
        elif f[0] == "P":
            ev.append(("P", f[1], int(f[2]), int(f[3]), PARK, int(f[4])))
    return ev


def by_macro(ev):
    out = {m: [] for m in range(NM)}
    for e in ev:
        out[e[3]].append(e)
    return out


def dense_runs(seq):
    """maximal runs of consecutive lookups of one macro, each after the first at most DENSE_LOW cycles
    after the previous read; returns lists of indices into seq"""
    runs, cur = [], []
    for i, e in enumerate(seq):
        if e[0] == "L" and e[1] == "I" and cur and seq[i - 1][0] == "L" and e[5] <= DENSE_LOW:
            cur.append(i)
        else:
            if len(cur) > 1:
                runs.append(cur)
            cur = [i] if (e[0] == "L" and e[1] == "I") else []
    if len(cur) > 1:
        runs.append(cur)
    return runs


def windows(seq, words):
    """every window of NWIN consecutive lookups inside a dense run whose next event exists, with the
    mean and the variance of the zero bits of its words"""
    out = []
    for run in dense_runs(seq):
        for s in range(len(run) - NWIN + 1):
            idx = run[s:s + NWIN]
            if idx[-1] + 1 >= len(seq):
                continue
            z = [zeros(words[seq[i][4]]) for i in idx]
            mz = sum(z) / NWIN
            out.append((idx, mz, sum((x - mz) ** 2 for x in z) / NWIN))
    return out


# ------------------------------------------------------------------ plan
def seq_tokens(segs):
    """bench tokens and roles: a read with L cycles of clock low before it is w(L*10-50) r<addr>"""
    toks, roles = [], []
    for s in segs:
        if s[0] == "wait":
            toks.append(f"w{s[1]:g}")
            roles.append({"role": s[2]})
        else:                                   # ("read", addr, low_cycles, role, extra)
            _, addr, low, role, extra = s
            pre = low * CYC - PERIOD / 2
            if pre > 0.5:
                toks.append(f"w{pre:g}")
                roles.append({"role": "pre", "of": role})
            toks.append(f"r{addr}")
            r = {"role": role, "addr": addr}
            r.update(extra)
            roles.append(r)
    return ",".join(toks), roles


def plan_window(seq, words, idx, rz, tag, wait_after):
    """a dense window of real lookups (the first after 9 cycles low), the parking read 5 cycles after the
    last one, as the unit parks at the end of a dense run, then the clock low for wait_after ns"""
    segs = []
    for j, i in enumerate(idx):
        e = seq[i]
        low = 9 if j == 0 else e[5]
        nxt = seq[idx[j + 1]][5] if j + 1 < len(idx) else 5
        segs.append(("read", e[4], low, "dense", {"win": tag, "j": j, "cycle": e[2], "low_before": low,
                                                    "low_after": nxt, "z_word": zeros(words[e[4]]),
                                                    "z_row": rz[e[4] // WPR]}))
    segs.append(("read", PARK, 5, "park_end", {"win": tag, "z_word": 0, "z_row": rz[PARK // WPR]}))
    segs.append(("wait", wait_after, "parked"))
    return segs


def overlap(a_, b_):
    return bool(set(a_) & set(b_))


def cmd_plan(a):
    plan = {"rules": "protocol P2R-E9.3 (2026-11-12), fixed before the run", "nwin": NWIN, "dense_low": DENSE_LOW,
            "nconv": NCONV, "runs": {}, "models": {}}
    for M in ("A", "B"):
        ev = read_events(os.path.join(a.e91, f"e9ev_normal_{M}.txt"))
        bm = by_macro(ev)
        plan["models"][M] = {"events": len(ev), "events_md5": md5(os.path.join(a.e91, f"e9ev_normal_{M}.txt"))}
        for m in range(NM):
            name = f"e9rom_{M}_40x2688_w8_r48k{m}"
            words = read_words(os.path.join(a.bins, f"{name}.bin"))
            if words[PARK] != (1 << WBITS) - 1:
                sys.exit(f"{name}: word {PARK} is not all ones")
            rz = row_zeros(words)
            seq = bm[m]
            win = windows(seq, words)
            if not win:
                sys.exit(f"{name}: no dense window of {NWIN} lookups")
            dl = [i for run in dense_runs(seq) for i in run]
            mean_all = sum(zeros(words[seq[i][4]]) for i in dl) / len(dl)
            # fit windows: the fewest and the most zero bits on average (the fit interpolates between
            # them); ties: the earliest; the second does not overlap the first
            wl = min(win, key=lambda x: (x[1], x[0][0]))
            rest = [x for x in win if not overlap(x[0], wl[0])] or win
            wh = max(rest, key=lambda x: (x[1], -x[0][0]))
            chosen = [("L", wl), ("H", wh)]
            if (M, m) in (("A", 1), ("B", 6)):
                # check window: the closest to the mean of the dense lookups, not overlapping the others
                rest2 = [x for x in win if not overlap(x[0], wl[0]) and not overlap(x[0], wh[0])] or win
                chosen.append(("C", min(rest2, key=lambda x: (abs(x[1] - mean_all), x[0][0]))))
            segs = [("wait", W_UNREAD, "unread")]
            conv = []
            if m == 0:
                cand = [i for i, e in enumerate(seq) if e[0] == "L" and e[1] == "I" and i + 1 < len(seq)
                        and seq[i + 1][0] == "P" and (i == 0 or seq[i - 1][0] == "P")]
                order = sorted(cand, key=lambda i: (zeros(words[seq[i][4]]), i))
                pick = sorted({order[round(q * (len(order) - 1))] for q in (0, 0.2, 0.4, 0.6, 0.8, 1.0)})
                k = 0
                while len(pick) < NCONV and k < len(order):        # quantiles collided: fill in order
                    if order[k] not in pick:
                        pick = sorted(pick + [order[k]])
                    k += 1
                conv = pick
                for j, i in enumerate(conv):
                    e = seq[i]
                    segs.append(("wait", W_CONV, "parked_conv"))
                    segs.append(("read", e[4], 5, "conv_L", {"j": j, "cycle": e[2], "z_word": zeros(words[e[4]]),
                                                             "z_row": rz[e[4] // WPR]}))
                    segs.append(("read", PARK, 5, "conv_P", {"j": j, "z_word": 0, "z_row": rz[PARK // WPR]}))
            for n, (tag, w) in enumerate(chosen):
                segs += plan_window(seq, words, w[0], rz, tag, W_PARKED_END if n == len(chosen) - 1 else W_PARKED_MID)
            toks, roles = seq_tokens(segs)
            plan["runs"][f"{M}_k{m}"] = {"model": M, "macro": m, "name": name, "seq": toks, "roles": roles,
                                          "windows": {tag: {"first_cycle": seq[w[0][0]][2], "mean_z": w[1]}
                                                      for tag, w in chosen},
                                          "dense_mean_z": mean_all, "dense_lookups": len(dl),
                                          "conv_pairs": [seq[i][2] for i in conv]}
    json.dump(plan, open(a.out, "w"), indent=1)
    tot = 0.0
    for k, r in plan["runs"].items():
        nread = sum(1 for x in r["roles"] if x.get("addr") is not None)
        t = PERIOD * nread + sum(float(tok[1:]) for tok in r["seq"].split(",") if tok[0] == "w")
        tot += t
        ws = ", ".join(f"{tag} from cycle {w['first_cycle']} (mean zero bits {w['mean_z']:.2f})"
                       for tag, w in r["windows"].items())
        print(f"   {k:5s} {r['name']}: {nread} reads, {t / 1000:.2f} us simulated; windows {ws}; all dense lookups "
              f"{r['dense_mean_z']:.2f}" + (f"; convolution pairs at cycles {r['conv_pairs']}" if r["conv_pairs"] else ""))
    print(f"   {len(plan['runs'])} runs, {tot / 1000:.1f} us simulated in all; written {a.out}")
    return 0


# ------------------------------------------------------------------ judge
def md5(p):
    import hashlib
    return hashlib.md5(open(p, "rb").read()).hexdigest()


def lstsq(X, y):
    """least squares for a few columns (normal equations, Gauss-Jordan)"""
    n = len(X[0])
    A = [[sum(r[i] * r[j] for r in X) for j in range(n)] for i in range(n)]
    b = [sum(r[i] * yy for r, yy in zip(X, y)) for i in range(n)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(A[r][c]))
        if abs(A[p][c]) < 1e-12:
            return None
        A[c], A[p] = A[p], A[c]
        b[c], b[p] = b[p], b[c]
        for r in range(n):
            if r != c:
                f = A[r][c] / A[c][c]
                A[r] = [x - f * yv for x, yv in zip(A[r], A[c])]
                b[r] -= f * b[c]
    return [b[i] / A[i][i] for i in range(n)]


FORMS = {"word": lambda s: [1.0, s["z_word"]], "row": lambda s: [1.0, s["z_row"]],
         "word+row": lambda s: [1.0, s["z_word"], s["z_row"]]}


def fit(samples, key):
    """the form with the lowest leave-one-out mean absolute error (ties: the simpler one)"""
    best = None
    for name in ("word", "row", "word+row"):
        X = [FORMS[name](s) for s in samples]
        y = [s[key] for s in samples]
        cf = lstsq(X, y)
        if cf is None:
            continue
        loo = []
        for i in range(len(samples)):
            c2 = lstsq(X[:i] + X[i + 1:], y[:i] + y[i + 1:])
            if c2 is None:
                loo = None
                break
            loo.append(abs(sum(a_ * x for a_, x in zip(c2, X[i])) - y[i]))
        if loo is None:
            continue
        mae = sum(loo) / len(loo)
        if best is None or mae < best["loo_mae"] - 1e-12:
            best = {"form": name, "coef": cf, "loo_mae": mae, "mean": sum(y) / len(y),
                    "loo_rel": mae / (sum(y) / len(y)) if sum(y) else float("nan")}
    return best


def pred(f, s):
    return sum(c * x for c, x in zip(f["coef"], FORMS[f["form"]](s)))


def run_cycles(d, roles):
    res = json.load(open(os.path.join(d, "result.json")))
    cyc = res["cycles"]
    if len(cyc) != len(roles):
        return None, f"{len(cyc)} cycles in the result, {len(roles)} in the plan"
    for c, r in zip(cyc, roles):
        if not c.get("complete"):
            return None, f"cycle {c.get('k')} not complete"
        if r.get("addr") is not None and (c.get("kind") != "read" or c.get("addr") != r["addr"]):
            return None, f"cycle {c.get('k')}: {c.get('kind')} {c.get('addr')}, plan read {r['addr']}"
    return list(zip(cyc, roles)), None


def periods(cr):
    """the energy from each read's rising edge to the next read's (its own window plus the waits after
    it) and the static power at the end of the last wait after it (90 ns after its falling edge for a
    lookup with 9 cycles low after it)"""
    out = []
    reads = [i for i, (c, r) in enumerate(cr) if c["kind"] == "read"]
    for n, i in enumerate(reads):
        j_end = reads[n + 1] if n + 1 < len(reads) else len(cr)
        e = sum(cr[j][0]["E_vdd_pJ"] for j in range(i, j_end))
        p_last = cr[j_end - 1][0]["P_after_uW"]
        out.append((i, e, p_last, cr[i][0]["E_vdd_pJ"]))
    return out


def cmd_judge(a):
    plan = json.load(open(a.plan))
    out = {"macros": {}, "checks": {}, "D_ROM": {}, "gates": {}}
    ok_all = True
    print("P2R-E9.3 ROM energy (rules written before the run: protocol P2R-E9.3 of 2026-11-12)")
    runs, bad_runs = {}, []
    reads_ok = reads_n = 0
    sel_n = [0]                      # reads whose row and word selection the probes show
    for key, r in plan["runs"].items():
        d = os.path.join(a.runs, key)
        if not os.path.isfile(os.path.join(d, "result.json")):
            bad_runs.append(f"{key}: no result.json")
            continue
        ec = os.path.join(d, "exit_code")
        if os.path.isfile(ec) and open(ec).read().strip() != "0":
            bad_runs.append(f"{key}: ngspice exit {open(ec).read().strip()}")
            continue
        cr, why = run_cycles(d, r["roles"])
        if cr is None:
            bad_runs.append(f"{key}: {why}")
            continue
        rd = [c for c, rr in cr if c["kind"] == "read"]
        reads_n += len(rd)
        reads_ok += sum(1 for c in rd if c.get("ok") and c.get("selection_ok", True))
        sel_n[0] += sum(1 for c in rd if "selection_ok" in c)
        runs[key] = (r, cr)
    fits = {}
    for key, (r, cr) in sorted(runs.items()):
        dense, check, last_dense, parks, conv_pairs, unread = [], [], [], [], [], None
        for (i, e, p_last, e_own) in periods(cr):
            rr = cr[i][1]
            if rr["role"] == "dense":
                s = {"z_word": rr["z_word"], "z_row": rr["z_row"], "low_after": rr["low_after"], "win": rr["win"]}
                if 1 <= rr["j"] <= NWIN - 2:
                    s["P_s"] = p_last            # static power at the end of the low time after the read
                    s["E"] = e
                    s["E9"] = e - p_last * 1e-6 * (rr["low_after"] - 9) * CYC * 1e-9 * 1e12
                    (check if rr["win"] == "C" else dense).append(s)
                elif rr["j"] == NWIN - 1:
                    s["E5"] = e_own              # the last lookup: 50 ns high, 50 ns low, then the parking read
                    last_dense.append(s)
            elif rr["role"] == "park_end":
                parks.append({"win": rr["win"], "E_window": e_own, "P_parked": p_last})
            elif rr["role"] == "conv_L":
                conv_pairs.append({"j": rr["j"], "z_word": rr["z_word"], "z_row": rr["z_row"], "E_L5": e_own})
            elif rr["role"] == "conv_P":
                conv_pairs[-1]["E_P"] = e_own
                conv_pairs[-1]["P_parked_after"] = p_last
        for c, rr in cr:
            if rr["role"] == "unread" and unread is None:
                unread = c["P_after_uW"]
        fe, fp = fit(dense, "E9"), fit(dense, "P_s")
        if fe is None or fp is None or not parks or unread is None or not last_dense:
            bad_runs.append(f"{key}: the run lacks a part of the plan (fit, parking, unread or last lookup)")
            continue
        info = {"run": key, "dense_samples": len(dense), "fit_E9": fe, "fit_P_static": fp, "parks": parks,
                "E_park_pJ": sum(x["E_window"] for x in parks) / len(parks),
                "P_parked_uW": sum(x["P_parked"] for x in parks) / len(parks), "unread_uW": unread,
                "last_dense": last_dense}
        for x in last_dense:
            x["E5_pred"] = pred(fe, x) - pred(fp, x) * 1e-6 * 4 * CYC * 1e-9 * 1e12
        if conv_pairs:
            for x in conv_pairs:
                x["E_pair"] = x["E_L5"] + x["E_P"]
                x["E_L5_pred_dense"] = pred(fe, x) - pred(fp, x) * 1e-6 * 4 * CYC * 1e-9 * 1e12
            info["conv_pairs"] = conv_pairs
            info["fit_conv_pair"] = fit(conv_pairs, "E_pair") if len(conv_pairs) >= 4 else None
        if check:
            meas = sum(x["E"] for x in check)
            prd = sum(pred(fe, x) + pred(fp, x) * 1e-6 * (x["low_after"] - 9) * CYC * 1e-9 * 1e12 for x in check)
            out["checks"][key] = {"lookups": len(check), "measured_pJ": meas, "predicted_pJ": prd,
                                  "rel": prd / meas - 1 if meas else float("nan"),
                                  "window_mean_z": plan["runs"][key]["windows"]["C"]["mean_z"]}
        fits[(r["model"], r["macro"])] = info
        out["macros"][key] = info
    g0 = not bad_runs and reads_ok == reads_n and reads_n > 0 and len(fits) == 2 * NM
    out["gates"]["V0_V1"] = g0
    out["reads"] = {"total": reads_n, "correct": reads_ok, "selection_shown": sel_n[0]}
    print(f"   {'PASS' if g0 else 'FAIL'}  V0/V1 every run complete, every read correct: {reads_ok} of {reads_n} reads "
          f"(data; row and word selection shown for {sel_n[0]}), {len(fits)} of {2 * NM} macros"
          + ("" if not bad_runs else "; " + "; ".join(bad_runs)))
    ok_all = ok_all and g0
    worst = max((f["fit_E9"]["loo_rel"] for f in fits.values()), default=float("nan"))
    g2 = len(fits) == 2 * NM and all(f["fit_E9"]["loo_rel"] <= 0.10 for f in fits.values())
    out["gates"]["V2"] = g2
    print(f"   {'PASS' if g2 else 'FAIL'}  V2 per macro the leave-one-out error of the lookup period <= 10 % (worst {worst * 100:.1f} %)")
    ok_all = ok_all and g2
    g3 = len(out["checks"]) == 2 and all(abs(c["rel"]) <= 0.10 for c in out["checks"].values())
    out["gates"]["V3"] = g3
    for key, c in out["checks"].items():
        print(f"      check window of {key} (mean zero bits {c['window_mean_z']:.2f}, {c['lookups']} lookups): measured "
              f"{c['measured_pJ']:.1f} pJ, model of the fit windows {c['predicted_pJ']:.1f} pJ ({c['rel'] * 100:+.1f} %)")
    print(f"   {'PASS' if g3 else 'FAIL'}  V3 the model within 10 % of the measured sum of each check window")
    ok_all = ok_all and g3
    # ---- replay of the inference
    print(f"==== D_ROM: replay of every ROM read of one inference (E9.1 event lists) over {T_INF_CYCLES} cycles")
    uJ_static = lambda p_uW, ns: p_uW * 1e-6 * ns * 1e-9 * 1e6      # uW over ns -> uJ
    for M in ("A", "B"):
        ev = read_events(os.path.join(a.e91, f"e9ev_normal_{M}.txt"))
        bm = by_macro(ev)
        parts = {"dense lookups (to the next read, 9 cycles low)": 0.0,
                 "static of unparked gaps beyond 9 cycles": 0.0,
                 "last lookup of a dense run (parked 5 cycles later)": 0.0,
                 "parking reads after a dense run": 0.0,
                 "convolution lookup-and-park pairs (macro 0)": 0.0,
                 "parked": 0.0, "unread (before the first read)": 0.0}
        counts = {"L": 0, "P": 0}
        for m in range(NM):
            f = fits.get((M, m))
            if not f:
                continue
            words = read_words(os.path.join(a.bins, f"e9rom_{M}_40x2688_w8_r48k{m}.bin"))
            rz = row_zeros(words)
            seq = [e for e in bm[m] if e[1] != "B"]
            pre = [e for e in bm[m] if e[1] == "B"]
            parked_level = f["P_parked_uW"]
            first = seq[0][2] if seq else T_INF_CYCLES
            if pre:                                      # read ahead and parked before the start
                parts["parked"] += uJ_static(parked_level, first * CYC)
            else:
                parts["unread (before the first read)"] += uJ_static(f["unread_uW"], first * CYC)
            paired = False                               # the previous lookup and this parking read form a pair
            for n, e in enumerate(seq):
                nxt = seq[n + 1] if n + 1 < len(seq) else None
                prev = seq[n - 1] if n > 0 else None
                lo = nxt[5] if nxt else max(T_INF_CYCLES - e[2] - 5, 0)     # cycles low after this read
                s = {"z_word": zeros(words[e[4]]), "z_row": rz[e[4] // WPR]}
                if e[0] == "L":
                    counts["L"] += 1
                    paired = False
                    if nxt and nxt[0] == "P" and lo == 5:
                        # out of the parked state and parked again (the convolution layers), measured as pairs
                        # in macro 0; otherwise the last lookup of a dense run
                        if f.get("fit_conv_pair") and (prev is None or prev[0] == "P"):
                            parts["convolution lookup-and-park pairs (macro 0)"] += pred(f["fit_conv_pair"], s) * 1e-6
                            paired = True
                        else:
                            parts["last lookup of a dense run (parked 5 cycles later)"] += \
                                (pred(f["fit_E9"], s) - pred(f["fit_P_static"], s) * 1e-6 * 4 * CYC * 1e-9 * 1e12) * 1e-6
                    else:
                        parts["dense lookups (to the next read, 9 cycles low)"] += pred(f["fit_E9"], s) * 1e-6
                        if lo != 9:
                            parts["static of unparked gaps beyond 9 cycles"] += \
                                uJ_static(pred(f["fit_P_static"], s), (lo - 9) * CYC)
                else:
                    counts["P"] += 1
                    if not paired:                       # a pair already holds its parking read
                        parts["parking reads after a dense run"] += f["E_park_pJ"] * 1e-6
                    paired = False
                    parts["parked"] += uJ_static(parked_level, max(lo * CYC - PERIOD / 2, 0.0))
        tot = sum(parts.values())
        out["D_ROM"][M] = {"uJ": tot, "parts_uJ": parts, "reads": counts}
        print(f"   model {M}: D_ROM {tot:.4f} uJ per inference ({counts['L']} lookups, {counts['P']} parking reads)")
        for k2, v in parts.items():
            print(f"      {k2:40s} {v:.5f} uJ")
    # ---- per macro table
    print("==== per macro: lookup period (90 ns low after the read) and static 90 ns after a lookup (fits of the "
          "windows L and H), last lookup before parking, parking read, parked and unread static")
    for (M, m), f in sorted(fits.items()):
        fe, fp = f["fit_E9"], f["fit_P_static"]
        e5 = " / ".join(f"{x['E5']:.2f} ({x['E5_pred']:.2f})" for x in f["last_dense"])
        print(f"   {M} k{m}: period {fe['mean']:.2f} pJ mean ({fe['form']}: {', '.join(f'{c:.4g}' for c in fe['coef'])}; "
              f"leave-one-out {fe['loo_rel'] * 100:.1f} %); static {fp['mean']:.1f} uW ({fp['form']}, "
              f"{fp['loo_rel'] * 100:.1f} %); last lookup measured (model) {e5} pJ; parking read {f['E_park_pJ']:.2f} pJ; "
              f"parked {f['P_parked_uW']:.3f} uW; unread {f['unread_uW']:.3f} uW")
        fc = f.get("fit_conv_pair")
        if fc:
            print(f"      convolution lookup-and-park pairs: {fc['mean']:.2f} pJ mean ({fc['form']}: "
                  f"{', '.join(f'{c:.4g}' for c in fc['coef'])}; leave-one-out {fc['loo_rel'] * 100:.1f} %)")
        for x in f.get("conv_pairs", []):
            print(f"      convolution pair {x['j']}: zero bits {x['z_word']} (row {x['z_row']}): lookup {x['E_L5']:.2f} pJ "
                  f"(dense model {x['E_L5_pred_dense']:.2f}), parking {x['E_P']:.2f} pJ, parked after {x['P_parked_after']:.3f} uW")
    out["all_pass"] = ok_all
    json.dump(out, open(a.out, "w"), indent=1)
    print(f"   {'ALL PASS' if ok_all else 'NOT ALL PASS'}; written {a.out}")
    return 0 if ok_all else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("plan")
    s.add_argument("--e91", required=True, help="the E9.1 event lists (reports/e9/e9_1/rtl)")
    s.add_argument("--bins", required=True, help="the macro images of E9.2 (reports/e9_rom/e9_2/bins)")
    s.add_argument("--out", required=True)
    s = sp.add_parser("judge")
    s.add_argument("--plan", required=True)
    s.add_argument("--runs", required=True, help="the folder of the runs (one sub-folder per run of the plan)")
    s.add_argument("--e91", required=True)
    s.add_argument("--bins", required=True)
    s.add_argument("--out", required=True)
    a = ap.parse_args()
    return {"plan": cmd_plan, "judge": cmd_judge}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
