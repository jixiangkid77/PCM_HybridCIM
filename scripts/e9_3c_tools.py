#!/usr/bin/env python3
"""P2R-E9.3c tools (run by scripts/e9_3c_rom_rest.sh): the power of an address-map ROM macro of E9 at
rest on its parking word, from the parking read to 1 ms, and D_ROM with this measured rest power.

Why: E9.3 and E9.3b took the parked power of a macro from one sample 0.4-0.5 us after the parking read and
held it constant over rests of up to 474 us. The power is still falling at that time; the method of E8.5f
and E8.5g integrates the measured power over the rest instead. I measure it here for the macros of E9.

  plan   the 8 runs (rules fixed before the run: protocol P2R-E9.3c of 2026-11-12), all from the E9.1 event
         lists; per model A and B:
           - macro 0: the lookup-and-park pair before the longest rest of the inference (address 5, then
             474 us parked), then the real next lookup (address 6);
           - macro 1: its last 4 lookups with their real clock-low times and its parking read 5 cycles
             later (it rests there to the end of the inference), then a read of address 0;
           - each history after 300 + 250 ns unread (the first address change falls in the 250 ns);
           - fine runs: maximum time step 2 ns (as E9.3), rest windows 0.10-0.15-0.20-0.35-1.10 us and
             1 us windows to 10.10 us after the rising edge of the parking read, then two 1 us windows
             (the second one ends with the address change of the final read: 6 or 8 bits fall);
           - coarse runs: maximum time step 500 ns (as E8.5f), rest windows 0.1-2.1-5.1-10.1-20-100-1000 us,
             then the final read.
         No checkpoints inside a run: E9.3 showed that the pause at a checkpoint disturbs a power sample
         taken within a few ns of it (7 parked samples at 3000 ns: 0.54-4.48 uW, the others 1.68-1.78 uW).
  judge  gates G0 (the inputs), G1 (the replay with E9.3's constant parked power gives E9.3b's final D_ROM),
         V0 (every read right), V1 (every run complete), R1 (the fine runs of macro 0 give E9.3's first four
         windows again), S2 (fine and coarse runs agree from 5.1 to 10.1 us); then D_ROM: the energy of
         every parked segment is the measured rest power integrated over it (fine windows to 10.1 us,
         coarse windows after that), and the address changes of the shared address bus (rom_addr of
         amu9_core.v drives all 7 macros) cost each idle macro the measured energy per bit. Reported: the
         settled level and the time to reach it, the first microsecond, the read after a long rest, the
         energy per address bit, the pin capacitances (clock, chip select, address) and the energy of
         charging the pins, and D_ROM with the parked power of E9.3 and E9.3b and two simpler forms.

Energy is the supply energy of the macro (E_vdd of scripts/e8_4_rom_bench.py), as in E9.3 and E9.3b.
"""
import argparse
import bisect
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e9_3b_tools as B                                            # noqa: E402
T = B.T                                                            # e9_3_tools

VDD = 1.8
E93_PLAN_MD5 = "df6400b4c7f49cf82f451ed111559cc5"                  # the plan of E9.3
E93B_PLAN_MD5 = "db634e9131b282e60f1f82c9b6c0a20b"                 # the plan of E9.3b
FINE_REST = (50, 50, 150, 750) + (1000,) * 9                       # ns: rest windows 0.10 .. 10.10 us
COARSE_REST = (2000, 3000, 5000, 9900, 80000, 900000)              # ns: rest windows 0.1 .. 1000 us
G_R1 = 1e-3                                                        # R1: relative
G_S2 = 0.05                                                        # S2: relative
SETTLED = 0.05                                                     # report: within 5 % of the settled level
FINE_SPLIT = 10100.0                                               # ns after the parking read's rising edge


def md5(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


# --------------------------------------------------------------------------------------------- plan
def histories(e91):
    """per model: macro 0's pair before its longest rest and the next lookup; macro 1's last lookups"""
    out = {}
    for M in "AB":
        bm = T.by_macro(T.read_events(os.path.join(e91, f"e9ev_normal_{M}.txt")))
        s0 = [e for e in bm[0] if e[1] != "B"]
        best = None
        for n in range(len(s0) - 2):
            L, P, N = s0[n], s0[n + 1], s0[n + 2]
            if L[0] == "L" and P[0] == "P" and P[5] == 5 and N[0] == "L":
                rest = N[5] * T.CYC - T.PERIOD / 2
                if best is None or rest > best[0]:
                    best = (rest, L[4], N[4])
        s1 = [e for e in bm[1] if e[1] != "B"]
        ip = max(i for i, e in enumerate(s1) if e[0] == "P")
        last = s1[ip - 4:ip]
        ok1 = (len(last) == 4 and all(e[0] == "L" for e in last) and s1[ip][5] == 5
               and all(e[5] == 9 for e in last[1:]) and ip == len(s1) - 1)
        if best is None or not ok1:
            sys.exit(f"model {M}: the histories are not as the protocol expects")
        out[M] = {"k0": {"lookup": best[1], "next": best[2], "rest_ns": best[0]},
                  "k1": {"lookups": [e[4] for e in last], "lows": [e[5] for e in last[1:]]}}
    return out


def build(M, m, kind, h):
    """tokens and roles of one run"""
    tok = ["w300", "w250"]
    roles = [{"role": "unread"}, {"role": "pre"}]
    if m == 0:
        hist = [h["lookup"]]
        tok += [f"r{h['lookup']}"]
        roles += [{"role": "hist", "addr": h["lookup"]}]
        final = h["next"]
    else:
        hist = h["lookups"]
        tok += [f"r{hist[0]}"]
        roles += [{"role": "hist", "addr": hist[0]}]
        for a, lo in zip(hist[1:], h["lows"]):
            tok += [f"w{lo * 10 - 50}", f"r{a}"]
            roles += [{"role": "hist_wait"}, {"role": "hist", "addr": a}]
        final = 0
    tok += [f"r{T.PARK}"]
    roles += [{"role": "park", "addr": T.PARK}]
    t = 100.0
    for w in (FINE_REST if kind == "fine" else COARSE_REST):
        tok.append(f"w{w}")
        roles.append({"role": "rest", "t0": t, "t1": t + w})
        t += w
    if kind == "fine":
        tok += ["w1000", "w1000"]
        roles += [{"role": "ref", "t0": t, "t1": t + 1000}, {"role": "toggle", "t0": t + 1000, "t1": t + 2000,
                  "fall": bin(T.PARK & ~final & 511).count("1"), "rise": bin(final & ~T.PARK & 511).count("1")}]
    tok += [f"r{final}"]
    roles += [{"role": "final", "addr": final}]
    return ",".join(tok), roles, hist, final


def cmd_plan(a):
    h = histories(a.e91)
    runs = {}
    for kind in ("fine", "coarse"):
        for M in "AB":
            for m in (0, 1):
                seq, roles, hist, final = build(M, m, kind, h[M][f"k{m}"])
                runs[f"{kind[0].upper()}_{M}_k{m}"] = {
                    "model": M, "macro": m, "name": B.name_of(M, m), "kind": kind, "seq": seq, "roles": roles,
                    "tmax_ns": None if kind == "fine" else 500, "history": hist, "final": final}
    plan = {"rules": "protocol P2R-E9.3c (2026-11-12), fixed before the run", "histories": h, "runs": runs}
    json.dump(plan, open(a.out, "w"), indent=1, sort_keys=True)
    for k, r in runs.items():
        print(f"   {k}: {r['name']}, {r['kind']}, maximum time step {r['tmax_ns'] or 2} ns, "
              f"{len(r['roles'])} cycles: {r['seq'][:96]}{' ...' if len(r['seq']) > 96 else ''}")
    for M in "AB":
        print(f"   model {M}: macro 0 parks after address {h[M]['k0']['lookup']} and rests "
              f"{h[M]['k0']['rest_ns'] / 1e3:.2f} us (the longest rest); macro 1's last lookups "
              f"{', '.join(map(str, h[M]['k1']['lookups']))}")
    return 0


# --------------------------------------------------------------------------------------------- judge
def cycles(d, roles):
    """the result's cycles matched to the plan, or None and why"""
    f = os.path.join(d, "result.json")
    if not os.path.isfile(f):
        return None, "no result.json"
    ec = os.path.join(d, "exit_code")
    if os.path.isfile(ec) and open(ec).read().strip() != "0":
        return None, f"ngspice exit {open(ec).read().strip()}"
    res = json.load(open(f))
    cy = res["cycles"]
    if len(cy) != len(roles):
        return None, f"{len(cy)} cycles in the result, {len(roles)} in the plan"
    for c, r in zip(cy, roles):
        if not c.get("complete"):
            return None, f"cycle {c.get('k')} not complete"
        if r.get("addr") is not None and (c.get("kind") != "read" or c.get("addr") != r["addr"]):
            return None, f"cycle {c.get('k')}: {c.get('kind')} {c.get('addr')}, plan read {r['addr']}"
    return cy, None


def curve(cy, roles, kind):
    """rest windows (t0, t1 in ns after the parking read's rising edge, energy in pJ)"""
    return [(r["t0"], r["t1"], c["E_vdd_pJ"]) for c, r in zip(cy, roles) if r["role"] == "rest"]


def span(win, a, b):
    """pJ of the windows over [a, b] (ns), each window's energy spread evenly over it"""
    e = 0.0
    for t0, t1, en in win:
        o = min(b, t1) - max(a, t0)
        if o > 0:
            e += en * o / (t1 - t0)
    return e


def rest_curve(fine, coarse):
    """the rest windows used for D_ROM: the fine ones to 10.1 us, then the coarse ones"""
    return [w for w in fine if w[1] <= FINE_SPLIT + 1e-6] + [w for w in coarse if w[0] >= FINE_SPLIT - 1e-6]


def mean_uW(win, a, b):
    return span(win, a, b) / (b - a) * 1e3


def edges_charge(d, meta):
    """charge (pC) the ideal sources deliver on the rising edges of the clock, chip select and address pins,
    from tb_out.txt: the integral of -i over 0.2 ns before to 3 ns after each rising edge"""
    path = os.path.join(d, "tb_out.txt")
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        head = f.readline().split()
        col = {n: i for i, n in enumerate(head)}
        need = ["time", "i(vclk)", "i(vcs)"]
        if any(n not in col for n in need):
            return None
        rows = [list(map(float, ln.split())) for ln in f if ln.strip()]
    tt = [r[col["time"]] for r in rows]

    tr = meta.get("edge_ns", 0.1) * 1e-9

    def q(name, te):
        # whole time steps of the simulator from the last one at or before te - 0.2 ns to the first one at or
        # after te + 3 ns; ngspice takes a backward-Euler step after each corner of a PWL source, whose
        # current holds for the whole step (the trapezoid there loses half of it), the trapezoid elsewhere
        i = col.get(name)
        if i is None:
            return None
        k0 = max(bisect.bisect_right(tt, te - 0.2e-9) - 1, 0)
        k1 = min(bisect.bisect_left(tt, te + 3e-9), len(tt) - 1)
        corners = (te - tr / 2, te + tr / 2)
        s = 0.0
        for k in range(k0 + 1, k1 + 1):
            dt = tt[k] - tt[k - 1]
            if any(abs(tt[k - 1] - c) < 5e-13 for c in corners):
                s += -rows[k][i] * dt
            else:
                s += -(rows[k - 1][i] + rows[k][i]) / 2 * dt
        return s * 1e12
    out = {"clk": [], "cs": [], "addr_bit": []}
    prev = 0
    csd = meta.get("cs_delay_ns") or 0.0
    for c in meta["cycles"]:
        if c["kind"] != "read":
            continue
        out["clk"].append(q("i(vclk)", c["trise"]))
        out["cs"].append(q("i(vcs)", c["trise"] + csd * 1e-9))
        a = c["addr"]
        tin = c["t0"] + meta["period_ns"] * 1e-9 / 4
        for bit in range(meta["addr_bits"]):
            if (a >> bit) & 1 and not (prev >> bit) & 1:
                out["addr_bit"].append(q(f"i(va{bit})", tin))
        prev = a
    return {k: [x for x in v if x is not None] for k, v in out.items()}


def replay_rest(M, e91, bins, mf, rest, toggle_uJ=0.0):
    """B.replay with the parked segments' energy from rest(m, L_ns, pre) (uJ); the same parts in the same
    order of additions, so that rest = constant power x L gives B.replay's numbers bit for bit"""
    bm = T.by_macro(T.read_events(os.path.join(e91, f"e9ev_normal_{M}.txt")))
    parts = {k: 0.0 for k in B.PARTS}
    counts = {"L": 0, "P": 0}
    for m in range(T.NM):
        f = mf(m)
        words = T.read_words(os.path.join(bins, f"{B.name_of(M, m)}.bin"))
        rz = T.row_zeros(words)
        seq = [e for e in bm[m] if e[1] != "B"]
        pre = [e for e in bm[m] if e[1] == "B"]
        first = seq[0][2] if seq else T.T_INF_CYCLES
        if pre:
            parts["parked"] += rest(m, first * T.CYC, True)
        else:
            parts["unread (before the first read)"] += f["unread"] * 1e-6 * (first * T.CYC) * 1e-9 * 1e6
        paired = False
        for n, e in enumerate(seq):
            nxt = seq[n + 1] if n + 1 < len(seq) else None
            prev = seq[n - 1] if n > 0 else None
            lo = nxt[5] if nxt else max(T.T_INF_CYCLES - e[2] - 5, 0)
            s = {"z_word": T.zeros(words[e[4]]), "z_row": rz[e[4] // T.WPR], "pos": B.pos(e[4])}
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
                        parts["static of unparked gaps beyond 9 cycles"] += \
                            f["ps"](s) * 1e-6 * ((lo - 9) * T.CYC) * 1e-9 * 1e6
            else:
                counts["P"] += 1
                if not paired:
                    parts["parking reads after a dense run"] += f["e_park"] * 1e-6
                paired = False
                parts["parked"] += rest(m, max(lo * T.CYC - T.PERIOD / 2, 0.0), False)
    if toggle_uJ:
        parts["address changes seen by the idle macros"] = toggle_uJ
    return sum(parts.values()), parts, counts


def bus(e91, M):
    """changes of the shared address bus in the inference window: count, rising and falling bits"""
    ev = T.read_events(os.path.join(e91, f"e9ev_normal_{M}.txt"))
    pre = [e for e in ev if e[1] == "B"]
    v = pre[-1][4] if pre else 0
    n = r = f = 0
    for e in sorted((e for e in ev if e[1] != "B"), key=lambda e: (e[2], e[3])):
        if e[4] != v:
            n += 1
            r += bin(e[4] & ~v & 511).count("1")
            f += bin(v & ~e[4] & 511).count("1")
            v = e[4]
    return {"reads": sum(1 for e in ev if e[1] != "B"), "changes": n, "rising_bits": r, "falling_bits": f}


def fits_e93b(a):
    """the fits of the E9.3b final replay, rebuilt from the runs of E9.3 and E9.3b as its judge does"""
    p3 = json.load(open(a.plan3))
    pb = json.load(open(a.plan3b))
    e93, eb, bad = {}, {}, []
    for tag, p, runs, dst in (("E9.3", p3, a.runs3, e93), ("E9.3b", pb, a.runs3b, eb)):
        for key, r in p["runs"].items():
            x, why = B.extract(os.path.join(runs, key), r["roles"])
            if x is None:
                bad.append(f"{tag} {key}: {why}")
            else:
                dst[key] = x
    if bad:
        return None, bad
    fits3 = {}
    for key, x in e93.items():
        lh = [s for s in x["dense"] if s["win"] in ("L", "H")]
        r = p3["runs"][key]
        fits3[(r["model"], r["macro"])] = {"fp": T.fit(lh, "P_s"),
                                           "e_park": sum(p["E_window"] for p in x["parks"]) / len(x["parks"]),
                                           "p_parked": sum(p["P_parked"] for p in x["parks"]) / len(x["parks"]),
                                           "unread": x["unread"]}
    allx = [s for x in e93.values() for s in x["dense"]] + [s for x in eb.values() for s in x["dense"]]
    coef = B.lfit(allx)
    fc = {M: T.fit(e93[f"{M}_k0"]["conv"] + eb[f"{M}_k0"]["conv"], "E_pair") for M in "AB"}
    clean = {(pb["runs"][k]["model"], pb["runs"][k]["macro"]): eb[k]["parks"][0]["P_parked"] for k in eb}

    def mfun(M):
        def mf(m):
            f = fits3[(M, m)]
            return {"e9": lambda s: B.lpred(coef, s), "ps": lambda s: T.pred(f["fp"], s),
                    "conv": (lambda s: T.pred(fc[M], s)) if m == 0 and fc.get(M) else None,
                    "e_park": f["e_park"], "p_parked": f["p_parked"], "unread": f["unread"]}
        return mf
    return {"fits3": fits3, "coef": coef, "fc": fc, "clean": clean, "mfun": mfun, "n": len(allx)}, None


def first_change(runs_dirs):
    """E9.3 / E9.3b: the window before each run's first read holds its first address change (clock low,
    unread); energy above the flat unread level, per rising bit, and the runs whose first address is 0"""
    out = []
    for base in runs_dirs:
        for key in sorted(os.listdir(base)):
            f = os.path.join(base, key, "result.json")
            if not os.path.isfile(f):
                continue
            cy = json.load(open(f))["cycles"]
            i = next(n for n, c in enumerate(cy) if c["kind"] == "read")
            w = cy[i - 1]
            out.append({"run": key, "dE": w["E_vdd_pJ"] - cy[0]["P_after_uW"] * w["len_ns"] * 1e-3,
                        "rise": bin(cy[i]["addr"]).count("1")})
    return out


def cmd_judge(a):
    out = {"rules": "protocol P2R-E9.3c (2026-11-12), fixed before the run", "gates": {}, "runs": {}, "levels": {},
           "D_ROM": {}, "bus": {}, "pins": {}}
    print("P2R-E9.3c rest power of the address-map ROM macros of E9 and D_ROM (rules fixed before the run)")
    # ---- G0 inputs
    g0 = []
    g0.append(md5(a.plan3) == E93_PLAN_MD5 or a.test)
    g0.append(md5(a.plan3b) == E93B_PLAN_MD5 or a.test)
    sb = json.load(open(a.summary3b))
    g0.append(bool(sb.get("all_pass")))
    F, bad = fits_e93b(a)
    g0.append(F is not None)
    out["gates"]["G0"] = all(g0)
    print(f"   {'PASS' if all(g0) else 'FAIL'}  G0 inputs: plan of E9.3 {md5(a.plan3)[:8]}.. (rules: {E93_PLAN_MD5[:8]}..), "
          f"plan of E9.3b {md5(a.plan3b)[:8]}.. (rules: {E93B_PLAN_MD5[:8]}..), E9.3b all gates passed: {bool(sb.get('all_pass'))}"
          + (f"; {len(F['fits3'])} macro fits, lookup model on {F['n']} lookups" if F else "; " + "; ".join(bad)))
    if not all(g0):
        json.dump(out, open(a.out, "w"), indent=1)
        print("   NOT ALL PASS (G0)")
        return 1
    # ---- G1 the new replay with E9.3's constant parked power gives E9.3b's final D_ROM
    g1 = True
    for M in "AB":
        mf = F["mfun"](M)
        t, _, _ = replay_rest(M, a.e91, a.bins, mf,
                              lambda m, L, pre, mf=mf: mf(m)["p_parked"] * 1e-6 * L * 1e-9 * 1e6)
        ref = sb["D_ROM_final"][M]["uJ"]
        okM = B.close(t, ref, 1e-9)
        g1 = g1 and okM
        out["D_ROM"].setdefault("E9.3b final (check)", {})[M] = {"uJ": t, "E9.3b": ref}
        print(f"      model {M}: replay with E9.3's parked power {t:.9f} uJ, E9.3b final {ref:.9f} uJ")
    out["gates"]["G1"] = g1
    print(f"   {'PASS' if g1 else 'FAIL'}  G1 the replay of this tool gives E9.3b's final D_ROM (relative 1e-9)")
    # ---- the runs
    plan = json.load(open(a.plan))
    R, bad, reads, ok = {}, [], 0, 0
    for key, r in plan["runs"].items():
        d = os.path.join(a.runs, key)
        cy, why = cycles(d, r["roles"])
        if cy is None:
            bad.append(f"{key}: {why}")
            continue
        rd = [c for c in cy if c["kind"] == "read"]
        reads += len(rd)
        ok += sum(1 for c in rd if c.get("ok") and c.get("selection_ok", True))
        R[key] = {"cy": cy, "roles": r["roles"], "meta": os.path.join(d, "tb_meta.json"), "dir": d}
    v0 = reads > 0 and ok == reads and not bad
    v1 = len(R) == len(plan["runs"])
    out["gates"]["V0"], out["gates"]["V1"] = v0, v1
    print(f"   {'PASS' if v0 else 'FAIL'}  V0 every read right: {ok} of {reads} reads (data; row and word selection)")
    print(f"   {'PASS' if v1 else 'FAIL'}  V1 every run complete: {len(R)} of {len(plan['runs'])}"
          + ("" if not bad else "; " + "; ".join(bad)))
    # ---- R1 the fine runs of macro 0 give E9.3's first four windows again
    r1 = v1
    for M in "AB":
        key = f"F_{M}_k0"
        if key not in R:
            r1 = False
            continue
        ref = json.load(open(os.path.join(a.runs3, f"{M}_k0", "result.json")))["cycles"][:4]
        mine = R[key]["cy"][:4]
        rel = [abs(x["E_vdd_pJ"] - y["E_vdd_pJ"]) / abs(y["E_vdd_pJ"]) for x, y in zip(mine, ref)]
        same = [x["kind"] == y["kind"] and x.get("addr") == y.get("addr") for x, y in zip(mine, ref)]
        r1 = r1 and all(same) and max(rel) <= G_R1
        fine = curve(R[key]["cy"], R[key]["roles"], "fine")
        e3 = json.load(open(os.path.join(a.runs3, f"{M}_k0", "result.json")))["cycles"][4]["E_vdd_pJ"]
        out["runs"].setdefault(key, {})["R1"] = {"rel": rel, "first_250ns_after_park": [span(fine, 100, 350), e3]}
        print(f"      {key}: windows 0-3 against E9.3 {M}_k0: largest difference {max(rel):.2e} (relative); "
              f"0.10-0.35 us after the parking read {span(fine, 100, 350):.4f} pJ (E9.3, with its next address change "
              f"and a checkpoint in it: {e3:.4f} pJ)")
    out["gates"]["R1"] = r1
    print(f"   {'PASS' if r1 else 'FAIL'}  R1 the fine runs of macro 0 give E9.3's first four windows within {G_R1:.1e}")
    # ---- curves, S2 and the reported levels
    s2 = v1
    cur = {}
    for M in "AB":
        for m in (0, 1):
            fk, ck = f"F_{M}_k{m}", f"C_{M}_k{m}"
            if fk not in R or ck not in R:
                s2 = False
                continue
            fine = curve(R[fk]["cy"], R[fk]["roles"], "fine")
            coarse = curve(R[ck]["cy"], R[ck]["roles"], "coarse")
            ef, ec = span(fine, 5100, 10100), span(coarse, 5100, 10100)
            rel = ec / ef - 1
            s2 = s2 and abs(rel) <= G_S2
            cur[(M, m)] = rest_curve(fine, coarse)
            settled = mean_uW(coarse, 100000, 1000000)
            unread = R[fk]["cy"][0]["P_after_uW"]
            ws = [w for w in fine if w[0] >= 1100 - 1e-6]
            t_set = None
            for i, w in enumerate(ws):
                if all(abs(x[2] / (x[1] - x[0]) * 1e3 / settled - 1) <= SETTLED for x in ws[i:]):
                    t_set = w[0]
                    break
            ref = [(c, r) for c, r in zip(R[fk]["cy"], R[fk]["roles"]) if r["role"] == "ref"][0]
            lv = {"unread_uW": unread, "first_us_uW": mean_uW(fine, 100, 1100),
                  "0.10-0.35us_uW": mean_uW(fine, 100, 350), "1.1-2.1us_uW": mean_uW(fine, 1100, 2100),
                  "9.1-10.1us_uW": mean_uW(fine, 9100, 10100),
                  "10.1-11.1us_uW (fine)": ref[0]["E_vdd_pJ"] / 1000 * 1e3,
                  "coarse_0.1-2.1us_uW (not used)": mean_uW(coarse, 100, 2100),
                  "coarse_2.1-5.1us_uW": mean_uW(coarse, 2100, 5100), "fine_2.1-5.1us_uW": mean_uW(fine, 2100, 5100),
                  "coarse_5.1-10.1us_uW": mean_uW(coarse, 5100, 10100), "fine_5.1-10.1us_uW": mean_uW(fine, 5100, 10100),
                  "10.1-20us_uW": mean_uW(coarse, 10100, 20000), "20-100us_uW": mean_uW(coarse, 20000, 100000),
                  "settled_100-1000us_uW": settled,
                  "settled_P_after_0.91-0.98ms_uW": [c for c, r in zip(R[ck]["cy"], R[ck]["roles"]) if r["role"] == "rest"][-1]["P_after_uW"],
                  "settled_over_unread": settled / unread, "settled_within_5pct_from_us": None if t_set is None else (t_set - 100) / 1e3,
                  "S2_rel": rel}
            out["levels"][f"{M}_k{m}"] = lv
            print(f"      {M} macro {m}: unread {unread:.4f} uW; after parking: first us {lv['first_us_uW']:.3f}, "
                  f"1.1-2.1 us {lv['1.1-2.1us_uW']:.3f}, 9.1-10.1 us {lv['9.1-10.1us_uW']:.4f}, 10.1-20 us {lv['10.1-20us_uW']:.4f}, "
                  f"20-100 us {lv['20-100us_uW']:.4f}, 100-1000 us {settled:.4f} uW (settled / unread {settled / unread:.4f}); "
                  f"5.1-10.1 us fine {lv['fine_5.1-10.1us_uW']:.4f}, coarse {lv['coarse_5.1-10.1us_uW']:.4f} ({rel:+.2%})")
    out["gates"]["S2"] = s2
    print(f"   {'PASS' if s2 else 'FAIL'}  S2 fine and coarse runs within {G_S2:.0%} from 5.1 to 10.1 us after the parking read")
    allp = all(out["gates"][g] for g in ("G0", "G1", "V0", "V1", "R1", "S2"))
    # ---- address changes on a macro with its clock low
    fall = []
    for key, x in R.items():
        if not key.startswith("F_"):
            continue
        rr = x["roles"]
        win = [(c["E_vdd_pJ"], r) for c, r in zip(x["cy"], rr) if r["role"] in ("rest", "ref", "toggle")]
        e = [w[0] for w in win]
        y = e[-4:-1]                                  # the last two 1 us rest windows and the reference
        ext = y[2] + (y[2] - y[0]) / 2                # linear through them, one window on
        t = win[-1][1]
        fall.append({"run": key, "falling_bits": t["fall"], "rising_bits": t["rise"], "dE_pJ": e[-1] - ext,
                     "per_falling_bit_pJ": (e[-1] - ext) / t["fall"] if t["fall"] else None})
    e_fall = sum(f["dE_pJ"] for f in fall) / max(sum(f["falling_bits"] for f in fall), 1)
    fc = first_change([a.runs3, a.runs3b])
    base0 = [f["dE"] for f in fc if f["rise"] == 0]
    off = sum(base0) / len(base0) if base0 else 0.0
    rr = [f for f in fc if f["rise"] > 0]
    e_rise = sum(f["dE"] - off for f in rr) / max(sum(f["rise"] for f in rr), 1)
    out["bus"]["falling"] = fall
    out["bus"]["e_fall_pJ_per_bit"] = e_fall
    out["bus"]["e_rise_pJ_per_bit"] = e_rise
    out["bus"]["first_changes_E9.3_E9.3b"] = {"n": len(fc), "offset_no_change_pJ": off, "n_no_change": len(base0)}
    each = ", ".join("%s %d bits %+.1f fJ" % (f["run"], f["falling_bits"], f["dE_pJ"] * 1e3) for f in fall)
    print(f"   address changes with the clock low: {e_fall * 1e3:+.2f} fJ per falling bit (parked, about 11 us after the "
          f"parking read; {each}); {e_rise * 1e3:+.2f} fJ per rising bit (unread, the first change of the {len(rr)} runs "
          f"of E9.3 and E9.3b, against the {len(base0)} runs without one)")
    # ---- pins
    caps = {"clk": [], "cs": [], "addr_bit": []}
    for key, x in R.items():
        if not key.startswith("F_"):
            continue
        q = edges_charge(x["dir"], json.load(open(x["meta"])))
        if q:
            for k in caps:
                caps[k] += q[k]
    cpin = {k: (sum(v) / len(v) / VDD * 1e3 if v else None) for k, v in caps.items()}   # fF
    out["pins"]["C_fF"] = cpin
    out["pins"]["edges"] = {k: len(v) for k, v in caps.items()}
    # ---- D_ROM
    rows = {}
    for M in "AB":
        mf = F["mfun"](M)
        bz = bus(a.e91, M)
        out["bus"][M] = bz
        tog = (e_fall * bz["falling_bits"] + e_rise * bz["rising_bits"]) * (T.NM - 1) * 1e-6
        lv = {m: out["levels"].get(f"{M}_k{min(m, 1)}") for m in range(T.NM)}

        def rest_main(m, L, pre, M=M):
            w = cur[(M, min(m, 1))]
            e = span(w, 100.0, 100.0 + L)
            if 100.0 + L > w[-1][1]:                  # beyond the last window (no segment is): its mean power
                e += w[-1][2] / (w[-1][1] - w[-1][0]) * (100.0 + L - w[-1][1])
            return e * 1e-6

        def rest_flat(level):
            return lambda m, L, pre: level(m) * 1e-6 * L * 1e-9 * 1e6

        def rest_two(m, L, pre, lv=lv):
            x = lv[m]
            return (x["first_us_uW"] * min(L, 1000.0) + x["settled_100-1000us_uW"] * max(L - 1000.0, 0.0)) * 1e-9
        variants = [
            ("main: measured rest power, address changes on idle macros", rest_main, tog),
            ("E9.3 rule (one sample, held constant)", rest_flat(lambda m: mf(m)["p_parked"]), 0.0),
            ("E9.3b clean sample 0.48 us after parking, held constant", rest_flat(lambda m: F["clean"][(M, m)]), 0.0),
            ("settled level from the parking read on", rest_flat(lambda m: lv[m]["settled_100-1000us_uW"]), 0.0),
            ("first microsecond, then the settled level (the form of E8.5g)", rest_two, 0.0),
            ("main without the address changes on idle macros", rest_main, 0.0)]
        have = all((M, m) in cur for m in (0, 1))
        for name, fn, tg in variants:
            if not have and not name.startswith("E9.3"):
                continue
            t, parts, c = replay_rest(M, a.e91, a.bins, mf, fn, tg)
            rows.setdefault(name, {})[M] = {"uJ": t, "parts_uJ": parts, "reads": c}
        dpins = None
        if all(cpin.get(k) for k in ("clk", "cs", "addr_bit")):
            dpins = (bz["reads"] * (cpin["clk"] + cpin["cs"]) + bz["rising_bits"] * T.NM * cpin["addr_bit"]) * 1e-15 * VDD ** 2 * 1e6
        out["pins"][M] = {"uJ_not_in_D": dpins}
    out["D_ROM"].update(rows)
    print("==== D_ROM per inference (uJ): E9.3b final replay, parked segments from the measured rest power")
    for name, v in rows.items():
        print(f"   {name:66s} A {v['A']['uJ']:.5f}   B {v['B']['uJ']:.5f}")
    main = rows.get("main: measured rest power, address changes on idle macros")
    if main:
        for M in "AB":
            print(f"   model {M} parts ({main[M]['reads']['L']} lookups, {main[M]['reads']['P']} parking reads):")
            for k, v in main[M]["parts_uJ"].items():
                print(f"      {k:56s} {v:.5f} uJ")
    if cpin.get("clk"):
        print(f"   pins (from the source currents of the fine runs): clock {cpin['clk']:.2f} fF, chip select {cpin['cs']:.2f} fF, "
              f"address {cpin['addr_bit']:.2f} fF per pin ({out['pins']['edges']['clk']} / {out['pins']['edges']['cs']} / "
              f"{out['pins']['edges']['addr_bit']} rising edges); charging them in one inference (7 macros on the address bus, "
              f"not in D_ROM or the unit's logic): A {out['pins']['A']['uJ_not_in_D'] * 1e3:.3f} nJ, "
              f"B {out['pins']['B']['uJ_not_in_D'] * 1e3:.3f} nJ")
    # the read after a long rest
    for M in "AB":
        e3 = [c for c in json.load(open(os.path.join(a.runs3, f"{M}_k0", "result.json")))["cycles"] if c["kind"] == "read"]
        nxt = plan["runs"][f"F_{M}_k0"]["final"]
        ref = [c["E_vdd_pJ"] for c in e3 if c["addr"] == nxt]
        got = {k: [c for c in R[k]["cy"] if c["kind"] == "read"][-1]["E_vdd_pJ"] for k in (f"F_{M}_k0", f"C_{M}_k0") if k in R}
        out["runs"].setdefault(f"read_after_rest_{M}", {"E9.3_after_300ns": ref[:1], "after_12us_and_1ms": got})
        r3 = f"{ref[0]:.2f} pJ after 300 ns parked (E9.3)" if ref else "not read in E9.3"
        print(f"   model {M} lookup of address {nxt}: {r3}; "
              + ", ".join(f"{k} {v:.2f} pJ" for k, v in got.items()) + " (C: maximum time step 500 ns, reported only)")
    out["all_pass"] = allp
    json.dump(out, open(a.out, "w"), indent=1)
    print(f"   {'ALL PASS' if allp else 'NOT ALL PASS'}: G0 {out['gates']['G0']}, G1 {out['gates']['G1']}, V0 {v0}, V1 {v1}, "
          f"R1 {out['gates']['R1']}, S2 {out['gates']['S2']}")
    return 0 if allp else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sp = ap.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("plan")
    s.add_argument("--e91", required=True, help="the E9.1 event lists (reports/e9/e9_1/rtl)")
    s.add_argument("--out", required=True)
    s = sp.add_parser("judge")
    s.add_argument("--plan3", required=True, help="reports/e9_rom/e9_3/plan.json")
    s.add_argument("--runs3", required=True, help="reports/e9_rom/e9_3/runs")
    s.add_argument("--plan3b", required=True, help="reports/e9_rom/e9_3b/plan.json")
    s.add_argument("--runs3b", required=True, help="reports/e9_rom/e9_3b/runs")
    s.add_argument("--summary3b", required=True, help="reports/e9_rom/e9_3b/e9_3b_summary.json")
    s.add_argument("--plan", required=True)
    s.add_argument("--runs", required=True)
    s.add_argument("--e91", required=True)
    s.add_argument("--bins", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--test", action="store_true", help=argparse.SUPPRESS)
    a = ap.parse_args()
    return cmd_plan(a) if a.cmd == "plan" else cmd_judge(a)


if __name__ == "__main__":
    sys.exit(main())
