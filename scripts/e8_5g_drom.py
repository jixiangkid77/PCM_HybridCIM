#!/usr/bin/env python3
"""
e8_5g_drom.py   (P2R-E8.5g, computed in the sandbox from KID's files; method written before the computation in
claude/p2r-e8-5f-results.md, section 5)

D_ROM again with the measured parked floor of E8.5f for the all-ones state (the static of a macro after a read of
a word whose model static power is not above the parked level: parked on 0xFFFF, or after a lookup of such a word).
E8.6a-3's replay is copied (not changed) as in scripts/e8_4e_split.py and scripts/e8_5d_tools.py drom; the macros
parked on a word with zero bits keep E8.5d's measured curves.

All-ones state, interval [a0, a1] (ns since the end of the read that started the state):
  energy = ps(w) x [G(a1) - G(a0)] x 1e-3 pJ (ps in uW, G in ns)
  main  : G(t) = [P_f t + (L_s - P_f) min(t, 1 us)] / L_s   (the first us as rel5 measured it, then the floor)
  lower : G(t) = P_f t / L_s
  upper : G(t) = [P_f t + (L_s - P_f) min(t, 10 us)] / L_s
  curve : G(t) = mean over the side's tt 25 C runs of E_k(t) / L_k (E8.5f energy curves; for comparison only)
L_s: the side's parked level of D_ROM (SideModel.leak, rel5); P_f: the mean floor of the side's tt 25 C runs.
Checks: G0 the tables = the E8.4a-8 export; G1 with G(t) = t and constant zero-parked power the copy = E8.6a-3
(D = d_rom.json, parts = e8_4e_split.json, relative difference < 1e-9); G2 with G(t) = t and E8.5d's curves
D = d_rom_e85d.json; G3 the input md5s are those recorded on KID's machine.
Conditions: f_s(c) = sum ps dG_c / sum ps dt over the all-ones intervals at tt 25 C, G_c as main with P_f(c) the
floor of A_pcm_l00 k0 at c and L_s(c) the E8.4e parked level of the side at c; E8.4e's parked level x f_s(c).
"""
import argparse
import gzip
import hashlib
import importlib.util
import json
import os
import sys

from scipy.optimize import fsolve

ROWS, WPR, TW = 48, 13, 2496
TT = "tt:25:1.80"
KID_MD5 = {"reports/e8_rom/e8_5/e85_events_A.txt": "0a4ee0258b239eb239c888559ef753b7",
           "reports/e8_rom/e8_5/e85_events_B.txt": "397e3540050a9a99dcfce86d6323a4cd",
           "reports/e8_rom/e8_5d_park/park.json": "a58182f65f31ddca465db4a521b4dc32",
           "reports/e8_rom/e8_5f_park/park.json": "c64284f867481499fbac1ada33d46490",
           "reports/e8_rom/e8_4b_rel5/model.json": "fd281561e7bf1865040ffcd75a7217a3",
           "reports/e8_rom/e8_6a3_rel5/d_rom.json": "bfdf7fe6ce88b3cd2c2be64445e3dc32",
           "reports/e8_rom/e8_5d_park/d_rom_e85d.json": "52e3edb5d90fe43c4f70e61f7a915ed5",
           "reports/e8_rom/e8_5d/candidates.json": "426d99ccd82992ff29fd0e52bed66aa8",
           "scripts/e8_6a3_rom_energy.py": "1e216cf0983787bb4fe4cab0d816fdb6",
           "scripts/e8_6a2_rom_energy.py": "a4f7fb7aca7f7c672b74e24882c51050",
           "scripts/e8_5d_tools.py": "464d276cd13dd994b67646473c75901e"}
BINS = [(0, 1e4, "< 10 us"), (1e4, 1e5, "10-100 us"), (1e5, 1e6, "0.1-1 ms"), (1e6, 1e12, "> 1 ms")]


def md5(path):
    return hashlib.md5(open(path, "rb").read()).hexdigest()


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", required=True)
    ap.add_argument("--e84e-compare", required=True)
    ap.add_argument("--e84e-split", required=True)
    ap.add_argument("--rule-c", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    P = a.paper2
    root = os.path.join(P, "reports", "e8_rom")
    nfail = 0

    def gate(ok, txt):
        nonlocal nfail
        print(f"  {'PASS' if ok else 'FAIL'}  {txt}")
        if not ok:
            nfail += 1

    print("P2R-E8.5g D_ROM with the measured parked floor (sandbox, KID's files)")
    bad = [f for f, h in KID_MD5.items() if md5(os.path.join(P, f)) != h]
    gate(not bad, "G3 inputs = the md5s recorded on KID's machine" + (f"; DIFFERENT: {bad}" if bad else
                                                                        f" ({len(KID_MD5)} files)"))
    for nm, f in (("E8.4e compare", a.e84e_compare), ("E8.4e split", a.e84e_split), ("rule C", a.rule_c)):
        print(f"   {nm:<14}: {md5(f)}  {f}")
    E3 = load(os.path.join(P, "scripts", "e8_6a3_rom_energy.py"), "e8_6a3_rom_energy")
    E = load(os.path.join(P, "scripts", "e8_6a2_rom_energy.py"), "e8_6a2_rom_energy")
    T5 = load(os.path.join(P, "scripts", "e8_5d_tools.py"), "e8_5d_tools")
    model = json.load(open(os.path.join(root, "e8_4b_rel5", "model.json")))
    dref = json.load(open(os.path.join(root, "e8_6a3_rel5", "d_rom.json")))
    e85d = json.load(open(os.path.join(root, "e8_5d_park", "d_rom_e85d.json")))
    park5d = json.load(open(os.path.join(root, "e8_5d_park", "park.json")))
    park5f = json.load(open(os.path.join(root, "e8_5f_park", "park.json")))
    cand = json.load(open(os.path.join(root, "e8_5d", "candidates.json")))["macros"]
    cmpj = json.load(open(a.e84e_compare))
    split = json.load(open(a.e84e_split))
    rulec = json.load(open(a.rule_c))
    exp = json.load(gzip.open(os.path.join(root, "e8_4a8", "export_cells_tables.json.gz")))["tables"]

    sides = sorted(model["models"])
    leak, idle, choice = {}, {}, {}
    for side in sides:
        lm = [p["leak_mean_uW"] for p in model["parta"] if p["side"] == side and p["leak_mean_uW"] < 10.0]
        leak[side] = sum(lm) / len(lm)
        idle[side] = model["models"][side]["idle_parked_pJ"]
    for r in model["runs"]:
        if r["kind"] == "parta" and r.get("park_choice"):
            tok = r["park_choice"].split()[0]
            choice.setdefault(r["table"], {})[r["k"]] = int(tok) if tok.isdigit() else None
    sm = {s: E.SideModel(model["models"][s], "bits", leak[s], idle[s]) for s in sides}
    print(f"   L_s (rel5 parked level): " + ", ".join(f"{s} {leak[s]:.4f} uW" for s in sides))

    # ---- E8.5f floors and curves
    floor, curves = {}, {}
    k0c = {}
    for r in park5f["runs"]:
        i = r["info"]
        side = "sram" if "_sram_" in i["macro"] else "pcm"
        if not (r.get("p1") and r.get("t_wait_s")):
            continue
        if i["cond"] == TT:
            floor.setdefault(side, []).append(r["P_end_uW"])
            Lk = next(p["leak_mean_uW"] for p in model["parta"] if p["macro"] == i["macro"])
            curves.setdefault(side, []).append((r, Lk))
        elif i["macro"].endswith("r48k0") and "_pcm_l00_" in i["macro"]:
            k0c[i["cond"]] = r["P_end_uW"]
    Pf = {s: sum(v) / len(v) for s, v in floor.items()}
    print("   P_f (E8.5f tt 25 C floors): " + "; ".join(f"{s} {Pf[s]:.4f} uW (mean of {len(floor[s])}: "
                                                    f"{', '.join(f'{x:.3f}' for x in floor[s])})" for s in sides))
    print("   floors of A_pcm_l00 k0 at the other conditions: " + ", ".join(f"{c} {v:.3f} uW" for c, v in k0c.items()))

    # t < 0 occurs only in the first interval of a macro whose last read of the inference ends after t_end (the
    # steady state then starts the state after t = 0); the formula as written gives G(t) = t there for every
    # variant (min(t, tx) = t), i.e. the constant level of rel5, which is also what E8.6a-3 charges
    def g_lin(Pfs, Ls, tx):
        return lambda t: (Pfs * t + (Ls - Pfs) * min(t, tx)) / Ls

    def g_curve(side):
        lst = curves[side]

        def G(t):
            if t <= 0:
                return t
            return sum(T5.e_parked(r, t * 1e-9) / (Lk * 1e-6) for r, Lk in lst) / len(lst) * 1e9
        return G
    ident = lambda t: t
    variants = {"main": {s: g_lin(Pf[s], leak[s], 1000.0) for s in sides},
                "lower": {s: g_lin(Pf[s], leak[s], 0.0) for s in sides},
                "upper": {s: g_lin(Pf[s], leak[s], 10000.0) for s in sides},
                "curve": {s: g_curve(s) for s in sides}}
    cnames = {c: c for c in k0c}
    tag = {"tt:-40:1.80": "ttm40", "tt:85:1.80": "tt85", "ff:25:1.80": "ff25", "ss:25:1.80": "ss25", "ff:85:1.80": "ff85"}
    for c, P_c in k0c.items():
        cs = cmpj["conditions"][tag[c]]["sides"]
        variants[f"cond {c}"] = {s: g_lin(P_c, cs[s]["leak_uW"], 1000.0) for s in sides}

    # ---- E8.5d curves of the zero-parked macros
    usable = {}
    for r in park5d["runs"]:
        i = r["info"]
        if r.get("p1") and r.get("t_wait_s"):
            usable[(i["macro"], i["cond"], i["addr"])] = r

    def replay_g(tab, ev, smod, t_end, zcur, offset, Gs):
        """E8.6a-3's replay; static split: 'leak' (ps <= parked level) with G, 'zero' (parked, ps above) with the
        E8.5d curve when given, 'above' (not parked, ps above) constant. Returns energies (pJ) and the leak
        intervals [(ps, a0, a1)] and the 'above' durations"""
        rows = tab.rows
        st_w = [tab.park[k][1] for k in range(tab.nmac)]
        st_rb = [rows - 1 - tab.park[k][0] for k in range(tab.nmac)]
        parked = [True] * tab.nmac
        t_free = [0.0] * tab.nmac
        t_state = [-offset.get(k, 1e12) for k in range(tab.nmac)]
        En = {"read": 0.0, "park": 0.0, "above": 0.0, "leak": 0.0, "zero": 0.0}
        li, ab = [], []

        def gap(k, t1):
            d = t1 - t_free[k]
            if d <= 0:
                return
            ps = smod.ps[st_w[k]]
            if ps <= smod.leak:
                a0, a1 = t_free[k] - t_state[k], t1 - t_state[k]
                En["leak"] += ps * (Gs(a1) - Gs(a0)) * 1e-3
                li.append((ps, a0, a1))
            elif parked[k]:
                if k in zcur:
                    a0, a1 = (t_free[k] - t_state[k]) * 1e-9, (t1 - t_state[k]) * 1e-9
                    En["zero"] += (zcur[k](a1) - zcur[k](a0)) * 1e12
                else:
                    En["zero"] += ps * d * 1e-3
            else:
                En["above"] += ps * d * 1e-3
                ab.append((ps, d))

        for T, kind, k, ent in ev:
            gap(k, T)
            if kind == "L":
                kk, r, w = tab.loc(ent)
                En["read"] += smod.read(rows - 1 - r, tab.zr[k][r], w, st_w[k])
                st_w[k], st_rb[k], parked[k] = w, rows - 1 - r, False
            else:
                rp, wp = tab.park[k]
                En["park"] += smod.park(rows - 1 - rp, tab.zr[k][rp], st_w[k], st_rb[k])
                st_w[k], st_rb[k], parked[k] = wp, rows - 1 - rp, True
            t_state[k] = T + E.SLOT_NS
            t_free[k] = max(t_free[k], T + E.SLOT_NS)
        for k in range(tab.nmac):
            gap(k, max(t_end, t_free[k]))
        return En, li, ab

    out = {"inputs": {f: KID_MD5[f] for f in KID_MD5}, "L_s_uW": leak, "P_f_uW": Pf, "floors": floor,
           "k0_floors": k0c, "models": {}, "conditions": {}}
    sigma = {"A": [0.014, 0.016], "B": [0.041, 0.010]}
    for M in ("A", "B"):
        print(f"\n==== model {M} ====")
        ev = E3.read_events(os.path.join(root, "e8_5", f"e85_events_{M}.txt"))
        _, done, _, _ = E.parse_trace(os.path.join(root, "trace", f"trace_{M}.txt"))
        t_end = done * E.CYCLE_NS
        acc = {s: {} for s in sides}
        leaks = {s: [] for s in sides}
        aboves = {s: [] for s in sides}
        worst, g0bad = 0.0, []
        nneg = [0, 0]
        for side in sides:
            for lane in range(E.K):
                tn = f"e8rom_{M}_{side}_l{lane:02d}_16x{TW}"
                words = E.table_words(P, M, side, lane, TW)
                if "".join(f"{x:04x}" for x in words) != exp[tn]:
                    g0bad.append(tn)
                tab = E.Table(words, ROWS, WPR, choice.get(tn))
                evi = E3.table_events(ev, side, lane, ("I",))
                zks = [k for k in range(tab.nmac) if tab.park[k][1] != E.MISS]
                offset = {}
                for k in range(tab.nmac):
                    ek = [(T, kind) for T, kind, kk, _ in evi if kk == k]
                    if k in zks:
                        lastp = [T for T, kind in ek if kind == "P"]
                        offset[k] = t_end - (lastp[-1] + E.SLOT_NS)
                    elif ek:
                        offset[k] = t_end - (ek[-1][0] + E.SLOT_NS)
                nneg[0] += sum(1 for v in offset.values() if v < 0)
                nneg[1] += sum(1 for k in range(tab.nmac) if k not in offset)
                const = {k: (lambda T, w=tab.park[k][1], s=sm[side]: s.ps[w] * 1e-6 * T) for k in zks}
                cur = {}
                for k in zks:
                    n = f"{tn}_r{ROWS}k{k}"
                    rr = usable.get((n, TT, cand[n]["words"][0]["addr"])) if n in cand else None
                    if rr is None:
                        sys.exit(f"{n}: no E8.5d curve at tt 25 C (not in candidates.json or not passing P1)")
                    cur[k] = (lambda T, rr=rr: T5.e_parked(rr, T))
                En1, _, _, _, _, _ = E3.replay(E, tab, evi, sm[side], t_end)
                Ec, li, ab = replay_g(tab, evi, sm[side], t_end, const, offset, ident)
                st = Ec["above"] + Ec["leak"] + Ec["zero"]
                for c, v in (("read", Ec["read"]), ("park", Ec["park"]), ("static", st)):
                    worst = max(worst, abs(En1[c] - v) / max(abs(En1[c]), 1e-12))
                res = {"const": Ec}
                res["e85d"], _, _ = replay_g(tab, evi, sm[side], t_end, cur, offset, ident)
                for vn in ("main", "lower", "upper", "curve"):
                    res[vn], _, _ = replay_g(tab, evi, sm[side], t_end, cur, offset, variants[vn][side])
                for vn, Ev in res.items():
                    x = acc[side].setdefault(vn, {kk: 0.0 for kk in Ev})
                    for kk in Ev:
                        x[kk] += Ev[kk]
                leaks[side] += li
                aboves[side] += ab
        gate(not g0bad, f"G0 model {M}: the 50 tables = the E8.4a-8 export" + (f"; DIFFERENT {g0bad}" if g0bad else ""))
        print(f"   macros whose last read ends after t_end (state starts after t = 0): {nneg[0]}; "
              f"macros without any read: {nneg[1]}")
        b = dref["models"][M]["bits"]
        Dc = sum(sum(acc[s]["const"].values()) for s in sides) * 1e-6
        gate(worst < 1e-9 and abs(Dc - b["D_uJ"]) <= 1e-9 * b["D_uJ"],
             f"G1 model {M}: the copy with G(t) = t = E8.6a-3 (largest relative difference {worst:.1e}); "
             f"D {Dc:.6f} uJ, d_rom.json {b['D_uJ']:.6f}")
        sp = split["models"][M]["sides"]
        dif = max(abs(acc[s]["const"][mine] * 1e-6 - sp[s][theirs]) / max(abs(sp[s][theirs]), 1e-12)
                  if abs(sp[s][theirs]) > 0 else (0.0 if acc[s]["const"][mine] == 0 else 1.0)
                  for s in sides for mine, theirs in (("read", "read"), ("park", "park"), ("above", "static_above"),
                                                      ("leak", "parked_leak"), ("zero", "parked_zero")))
        gate(dif < 1e-9, f"G1 model {M}: parts = e8_4e_split.json (largest relative difference {dif:.1e})")
        D2 = sum(sum(acc[s]["e85d"].values()) for s in sides) * 1e-6
        gate(abs(D2 - e85d["models"][M]["D_uJ"]) <= 1e-9 * e85d["models"][M]["D_uJ"],
             f"G2 model {M}: with E8.5d's curves D {D2:.6f} uJ, d_rom_e85d.json {e85d['models'][M]['D_uJ']:.6f}")
        err = e85d["models"][M]["mean_model_error"]
        # SE per side from rel5's range (as claude/p2r-e8-5d-results.md, section 4)
        Ds = b["by_side_uJ"]
        lo, hi = b["range_uJ"]
        f = lambda x: [Ds["pcm"] / (1 + err["pcm"] + 2 * x[0]) + Ds["sram"] / (1 + err["sram"] + 2 * x[1]) - lo,
                       Ds["pcm"] / (1 + err["pcm"] - 2 * x[0]) + Ds["sram"] / (1 + err["sram"] - 2 * x[1]) - hi]
        se = dict(zip(("pcm", "sram"), fsolve(f, sigma[M], xtol=1e-14)))
        rec = {"G1_D_uJ": Dc, "G2_D_uJ": D2, "se": se, "mean_model_error": err, "variants": {}}
        for vn in ("main", "lower", "upper", "curve"):
            parts = {s: {kk: acc[s][vn][kk] * 1e-6 for kk in acc[s][vn]} for s in sides}
            D = sum(sum(parts[s].values()) for s in sides)
            modelp = {s: parts[s]["read"] + parts[s]["park"] + parts[s]["above"] for s in sides}
            meas = sum(parts[s]["leak"] + parts[s]["zero"] for s in sides)
            cor = sum(modelp[s] / (1 + err[s]) for s in sides) + meas
            rlo = sum(modelp[s] / (1 + err[s] + 2 * se[s]) for s in sides) + meas
            rhi = sum(modelp[s] / (1 + err[s] - 2 * se[s]) for s in sides) + meas
            rec["variants"][vn] = {"D_uJ": D, "corrected_uJ": cor, "range_uJ": [rlo, rhi], "parts_uJ": parts}
        mv = rec["variants"]["main"]
        lc = sum(acc[s]["const"]["leak"] for s in sides) * 1e-6
        print(f"   SE: pcm {100 * se['pcm']:.3f} %, sram {100 * se['sram']:.3f} %")
        print(f"   all-ones static: constant {lc:.4f} uJ -> main {sum(mv['parts_uJ'][s]['leak'] for s in sides):.4f}, "
              f"lower {sum(rec['variants']['lower']['parts_uJ'][s]['leak'] for s in sides):.4f}, "
              f"upper {sum(rec['variants']['upper']['parts_uJ'][s]['leak'] for s in sides):.4f}, "
              f"curve {sum(rec['variants']['curve']['parts_uJ'][s]['leak'] for s in sides):.4f} uJ")
        for vn in ("main", "lower", "upper", "curve"):
            v = rec["variants"][vn]
            print(f"   {vn:<6}: D_ROM {v['D_uJ']:.4f} uJ, corrected {v['corrected_uJ']:.4f}, range "
                  f"{v['range_uJ'][0]:.4f}-{v['range_uJ'][1]:.4f}")
        alt = sum((mv["parts_uJ"][s]["read"] + mv["parts_uJ"][s]["park"] + mv["parts_uJ"][s]["above"] +
                   mv["parts_uJ"][s]["leak"]) / (1 + err[s]) + mv["parts_uJ"][s]["zero"] for s in sides)
        rec["corrected_if_allones_divided_uJ"] = alt
        print(f"   (information: if the new all-ones energy were divided as in E8.5d, corrected {alt:.4f} uJ)")
        dcm = abs(rec["variants"]["curve"]["D_uJ"] - mv["D_uJ"]) / mv["D_uJ"]
        print(f"   main vs curve: {100 * dcm:.2f} % of D_ROM" + ("  (MORE THAN 2 %: flagged)" if dcm > 0.02 else ""))
        for s in sides:
            p = mv["parts_uJ"][s]
            print(f"   {s}: read {p['read']:.4f}, park {p['park']:.4f}, above {p['above']:.4f}, all-ones {p['leak']:.4f} "
                  f"(constant {acc[s]['const']['leak'] * 1e-6:.4f}), zero-parked {p['zero']:.4f} uJ")
        # duration distributions
        dist = {}
        for s in sides:
            for nm, lst, en in (("all-ones (constant)", leaks[s], lambda ps, a0, a1: ps * (a1 - a0) * 1e-3),
                                ("all-ones (main)", leaks[s],
                                 lambda ps, a0, a1, s=s: ps * (variants["main"][s](a1) - variants["main"][s](a0)) * 1e-3)):
                tot = [0.0] * len(BINS)
                for ps, a0, a1 in lst:
                    d = a1 - a0
                    for j, (b0, b1, _) in enumerate(BINS):
                        if b0 <= d < b1:
                            tot[j] += en(ps, a0, a1)
                dist[f"{s} {nm}"] = tot
            tot = [0.0] * len(BINS)
            for ps, d in aboves[s]:
                for j, (b0, b1, _) in enumerate(BINS):
                    if b0 <= d < b1:
                        tot[j] += ps * d * 1e-3
            dist[f"{s} after a lookup (constant)"] = tot
        print("   energy by interval length (uJ): " + " | ".join(x[2] for x in BINS))
        for nm, tot in dist.items():
            print(f"      {nm:<34} " + " | ".join(f"{t * 1e-6:.4f}" for t in tot))
        rec["by_length_uJ"] = {nm: [t * 1e-6 for t in tot] for nm, tot in dist.items()}
        # conditions: factor per side on the tt 25 C intervals
        fac = {}
        for c in k0c:
            for s in sides:
                num = sum(ps * (variants[f'cond {c}'][s](a1) - variants[f'cond {c}'][s](a0)) for ps, a0, a1 in leaks[s])
                den = sum(ps * (a1 - a0) for ps, a0, a1 in leaks[s])
                fac.setdefault(c, {})[s] = num / den
        rec["cond_factor"] = fac
        out["models"][M] = rec
    # conditions table (E8.4e after rule C, then the all-ones factor)
    print("\n==== conditions (E8.4e after rule C; all-ones static x f_s(c)) ====")
    for c, t in tag.items():
        if c not in k0c:
            continue
        row = {}
        for M in ("A", "B"):
            p = cmpj["conditions"][t]["models"][M]["parts_uJ"]
            f = out["models"][M]["cond_factor"][c]
            rc = rulec["models"][M][t]
            old_leak = p["pcm_parked_leak"] + p["sram_parked_leak"]
            new_leak = p["pcm_parked_leak"] * f["pcm"] + p["sram_parked_leak"] * f["sram"]
            D = rc["D_new"] - old_leak + new_leak
            err = out["models"][M]["mean_model_error"]
            modelp = {s: sum(v for k, v in p.items() if k.startswith(s + "_") and k not in (s + "_parked_zero", s + "_parked_leak"))
                      for s in ("pcm", "sram")}
            cor = sum(modelp[s] / (1 + err[s]) for s in ("pcm", "sram")) + rc["zero_new"] + new_leak
            row[M] = {"D_uJ": D, "corrected_uJ": cor, "factor": f, "parked_leak_old_uJ": old_leak,
                      "parked_leak_new_uJ": new_leak, "D_ruleC_uJ": rc["D_new"], "leak_share": new_leak / D}
        out["conditions"][c] = row
        print(f"   {c:<12} " + "; ".join(
            f"{M}: f pcm {row[M]['factor']['pcm']:.3f} sram {row[M]['factor']['sram']:.3f}, parked level "
            f"{row[M]['parked_leak_old_uJ']:.3f} -> {row[M]['parked_leak_new_uJ']:.3f}, D_ROM {row[M]['D_ruleC_uJ']:.3f} -> "
            f"{row[M]['D_uJ']:.3f} (corrected {row[M]['corrected_uJ']:.3f}), share {100 * row[M]['leak_share']:.1f} %"
            for M in ("A", "B")))
    for M in ("A", "B"):
        tt = out["models"][M]["variants"]["main"]["D_uJ"]
        print(f"   ratios to tt 25 C, model {M}: " + ", ".join(f"{c} {out['conditions'][c][M]['D_uJ'] / tt:.2f}"
                                                            for c in out["conditions"]))
    json.dump(out, open(a.out, "w"), indent=1)
    print(f"\n   written {a.out}  md5 {md5(a.out)}")
    print("ALL CHECKS PASS" if nfail == 0 else f"{nfail} CHECK(S) FAILED")
    return 0 if nfail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
