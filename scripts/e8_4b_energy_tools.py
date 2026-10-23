#!/usr/bin/env python3
"""
e8_4b_energy_tools.py   (P2R-E8.4b; used by scripts/e8_4b_rom_energy.sh)

Read sequences, parking-word choice and energy model of the address-map ROM
energy characterisation. The read sequences come from the real lookup trace
of E8.2 and the E8.3 table contents; the model is what E8.6 applies to every
lookup of the trace. Only the Python standard library is used.

Terms
  table      one 16-bit x 2,496-word address-map table of E8.3, e.g.
             e8rom_A_pcm_l00_16x2496 = model A, PCM side, lane 00
  macro k    the k-th 48-row ROM macro of a table (r48, 13 words per row):
             entries k*624 .. k*624+623; entry e is in row (e // 13) % 48,
             word e % 13 of macro e // 624
  address    what the bench reads: (row << 4) | word
  z          zero bits of a 16-bit word; z_row: zero cells of the 208-cell row
  rows below 47 - row: rows of the series chain below the row read
  lookup     one read of the table in one MAC operation (E8.2: both decoders
             of a lane read the same entry number); system cycle 10 ns
  window     the bench's energy window of a cycle: from its rising clock edge
             to the next one (a read: 50 ns high, then 50 ns low)
  parking    a read of a word without zero bits right after a lookup. A zero
             output bit leaves its output-buffer input at about VDD - Vth
             (one NMOS per column in the column multiplexer), so the buffer
             draws current until the next read (E8.4a-7: up to about 1 mW per
             macro; sandbox 2026-10-13: it depends on which bits are zero, not
             on how many); a word without zero bits ends it
  segment    a lookup and everything up to the next lookup (its read window,
             the parking read if any, the clock-low wait)

Commands
  lookups  --trace T --model A --lane L --out J
           the lookups of lane L in the trace: [cycle, layer, entry]
  plan     --bin TABLE.bin --lookups J --out P [--rows 48 --wpr 13 --train-len 13]
           per macro: Z (most zero bits), H (about half of Z's), Ps (no zero
           bit, shallowest row), Pd (no zero bit, deep row with few zero cells);
           trains of real consecutive lookups of the lane with their real
           intervals: conv1 and conv2 in macro 0 (86 % of all lookups are
           there), fc1 in macro 1 (intervals of 140-170 ns)
  seq      --plan P --what parta|drift|conv1|conv2|fc1 [--macro K] [--park ADDR|none]
           the bench sequence (e8_4_rom_bench.py --seq syntax)
  select   --plan P --macro K --result R.json --vm V [--margin 0.10] [--tol 10]
           after the macro's part-A run: the parking word (the cheaper of Pd
           and Ps among those that read correctly 50 ns after Z with the margin
           rule and leave at most the lowest parked power + 10 uW and 5 % of
           the power after Z); prints "PARK <addr> <name> ..." or
           "PARK none ..."
  fit      --dirs RUN_DIR... --vm V --out J [--rows 48] [--margin 0.10] [--ref SIDE=DIR...]
           [--train-tol 10] [--total-tol 5]
           every run directory has info.json (written by the shell script) and
           result.json (bench analyze). Per side (PCM, SRAM) two forms of the
           model: zero bits counted, or the static power of each output bit
           (non-negative fit) used for the static power, the read window (the
           word's own and the one the read before left) and the parking read.
           Each train is predicted by the model fitted without its table
           (leave one table out); criterion fixed before the run: every train
           within +-10 %, all trains together within +-5 %. Prints the tables
           and writes the models and all data (JSON) for E8.6
"""
import argparse
import json
import os
import statistics
import sys

K = 25
LAYERS = ["conv1", "conv2", "fc1", "fc2", "fc3"]
DEPTH = [6, 96, 1920, 420, 40]
OFFSET = [0, 6, 102, 2022, 2442]
IN_RANGE = [150, 2400, 48000, 10080, 840]
E82_LOOKUPS = [4704, 9600, 1920, 420, 40]      # lookups of one lane per layer at most (E8.2)
COL_BITS = 4                                   # 13 words per row -> 4 column-address bits
CYCLE_NS = 10.0                                # system clock 100 MHz (E8.2)
PERIOD_NS = 100.0                              # ROM read: 50 ns clock low (precharge) + 50 ns high


# ------------------------------------------------------------------ lookups
def decode(layer, o16, lane):
    """Replica of the index arithmetic of rtl/src/{sram,pcm}_addr_decoder.v, identical to
    scripts/e8_2_trace_summary.py (E8.2 checked it against the RTL hit bits, lookup by lookup).
    Returns the per-layer table index, or None when the lane looks nothing up."""
    if layer > 4:
        return None
    if layer in (0, 1):
        compact = o16 // 25
        lane_ok = (o16 % 25) == lane
    else:
        in_dim, groups = {2: (400, 16), 3: (120, 5), 4: (84, 4)}[layer]
        oc = o16 // in_dim
        flat = o16 - oc * in_dim
        sb = (flat - lane) // 25 if flat >= lane else 0
        compact = oc * groups + sb
        lane_ok = (flat % 25) == lane
    if not (o16 < IN_RANGE[layer] and lane_ok and compact < DEPTH[layer]):
        return None
    return compact


def cmd_lookups(a):
    out, ops = [], 0
    with open(a.trace) as fh:
        for line in fh:
            if line.startswith("# done_cycle"):
                break
            if line.startswith("#") or not line.strip():
                continue
            f = line.split()
            if len(f) != 6 + K:
                sys.exit(f"{a.trace}: malformed line: {line.strip()[:80]}")
            ops += 1
            cyc, layer = int(f[0]), int(f[1])
            addr = int(f[6 + a.lane].split(":")[0], 16)
            idx = decode(layer, addr, a.lane)
            if idx is not None:
                out.append([cyc, layer, OFFSET[layer] + idx])
    if not out:
        sys.exit(f"{a.trace}: no lookup of lane {a.lane}")
    per = [sum(1 for x in out if x[1] == li) for li in range(5)]
    gaps = {}
    for x, y in zip(out, out[1:]):
        if x[1] == y[1]:
            gaps.setdefault(x[1], []).append(y[0] - x[0])
    json.dump({"model": a.model, "lane": a.lane, "trace": os.path.abspath(a.trace), "ops": ops,
               "lookups": out}, open(a.out, "w"))
    print(f"model {a.model} lane {a.lane:02d}: {ops} operations, {len(out)} lookups ("
          + ", ".join(f"{LAYERS[i]} {per[i]}" for i in range(5)) + "); intervals within a layer (cycles): "
          + ", ".join(f"{LAYERS[i]} {min(g)}-{max(g)}" for i, g in sorted(gaps.items())))
    bad = [LAYERS[i] for i in range(5) if per[i] > E82_LOOKUPS[i] or (i < 3 and per[i] != E82_LOOKUPS[i])]
    if bad:
        print(f"   WARNING: lookups of {', '.join(bad)} differ from E8.2 (conv1 4,704, conv2 9,600, fc1 1,920, "
              f"fc2 <= 420, fc3 <= 40 per lane)")


# ------------------------------------------------------------------ plan
def words_of(path):
    d = open(path, "rb").read()
    if len(d) % 2:
        sys.exit(f"{path}: odd length")
    return [int.from_bytes(d[2 * i:2 * i + 2], "big") for i in range(len(d) // 2)]


def zbits(w):
    return 16 - bin(w & 0xFFFF).count("1")


def macro_layout(words, rows, wpr):
    per = rows * wpr
    return [[words[k * per + r * wpr:k * per + (r + 1) * wpr] for r in range(rows)] for k in range(len(words) // per)]


def cmd_plan(a):
    words = words_of(a.bin)
    lk = json.load(open(a.lookups))["lookups"]
    rows, wpr = a.rows, a.wpr
    per = rows * wpr
    mac = macro_layout(words, rows, wpr)
    if not mac:
        sys.exit(f"{a.bin}: fewer than {per} words")
    plan = {"bin": os.path.abspath(a.bin), "lookups": os.path.abspath(a.lookups), "rows": rows, "wpr": wpr,
            "words_per_macro": per, "macros": [], "trains": {}}
    addr = lambda rw: (rw[0] << COL_BITS) | rw[1]
    for k, m in enumerate(mac):
        zr = [sum(zbits(w) for w in r) for r in m]
        cand = [(r, w) for r in range(rows) for w in range(wpr)]
        z = {rw: zbits(m[rw[0]][rw[1]]) for rw in cand}
        Z = max(cand, key=lambda rw: (z[rw], zr[rw[0]], -rw[0], -rw[1]))
        target = max(1, z[Z] // 2)
        Hc = [rw for rw in cand if 0 < z[rw] < z[Z] and rw[0] != Z[0]] or [rw for rw in cand if 0 < z[rw] and rw != Z]
        H = min(Hc, key=lambda rw: (abs(z[rw] - target), -zr[rw[0]], rw)) if Hc else Z
        ones = [rw for rw in cand if z[rw] == 0]
        note = ""
        if ones:
            Ps = min(ones, key=lambda rw: (rw[0], zr[rw[0]], rw[1]))
            # E8.4a-7 read-energy fit (tt): about 0.25-0.38 pJ per row below the row read and 0.18 pJ per
            # zero cell of the row; the cheapest parking word is deep and in a row with few zero cells
            Pd = min(ones, key=lambda rw: (0.3 * (rows - 1 - rw[0]) + 0.18 * zr[rw[0]], rw))
        else:
            Ps = Pd = min(cand, key=lambda rw: (z[rw], rw[0], rw[1]))
            note = f"no word without zero bits (the fewest: {z[Ps]})"
        if z[Z] == 0:
            note = (note + "; " if note else "") + "no zero bit in the macro"
        info = {"k": k, "note": note, "ones_words": len(ones), "zero_bits": sum(z.values())}
        for name, rw in (("Z", Z), ("H", H), ("Ps", Ps), ("Pd", Pd)):
            info[name] = {"addr": addr(rw), "row": rw[0], "word": rw[1], "value": f"{m[rw[0]][rw[1]]:04x}",
                          "z": z[rw], "z_row": zr[rw[0]]}
        plan["macros"].append(info)

    def loc(e):
        return e // per, (e % per) // wpr, e % wpr

    def train(name, layer, kk, pick):
        sel = [x for x in lk if x[1] == layer and x[2] < len(mac) * per]
        runs, cur = [], []
        for x in sel:
            if loc(x[2])[0] == kk:
                cur.append(x)
            else:
                if cur:
                    runs.append(cur)
                cur = []
        if cur:
            runs.append(cur)
        runs = [r for r in runs if len(r) >= a.train_len + 1]
        if not runs:
            return None
        if pick == "middle":
            r = max(runs, key=len)
            s = (len(r) - a.train_len - 1) // 2
            r = r[s:]
        else:
            r = runs[0]
        r = r[:a.train_len + 1]                 # the last one only gives the interval after the one before
        out = []
        for i in range(a.train_len):
            cyc, layer_, e = r[i]
            k, row, w = loc(e)
            val = mac[k][row][w]
            out.append({"cycle": cyc, "layer": LAYERS[layer_], "entry": e, "row": row, "word": w,
                        "addr": (row << COL_BITS) | w, "value": f"{val:04x}", "z": zbits(val),
                        "z_row": sum(zbits(x) for x in mac[k][row]), "gap_cycles": r[i + 1][0] - cyc})
        return {"name": name, "macro": kk, "lookups": out}

    for name, layer, kk, pick in (("conv1", 0, 0, "first"), ("conv2", 1, 0, "middle"), ("fc1", 2, 1, "first")):
        if kk < len(mac):
            t = train(name, layer, kk, pick)
            if t:
                plan["trains"][name] = t
    json.dump(plan, open(a.out, "w"), indent=1)
    for m in plan["macros"]:
        print(f"   macro {m['k']}: Z {m['Z']['value']} (row {m['Z']['row']}, {m['Z']['z']} zero bits)  H {m['H']['value']} "
              f"({m['H']['z']})  Ps row {m['Ps']['row']} word {m['Ps']['word']} ({m['Ps']['z_row']} zero cells in "
              f"the row)  Pd row {m['Pd']['row']} word {m['Pd']['word']} ({m['Pd']['z_row']})  words without zero "
              f"bits {m['ones_words']}" + (f"  [{m['note']}]" if m["note"] else ""))
    for n, t in plan["trains"].items():
        g = [x["gap_cycles"] for x in t["lookups"]]
        zz = [x["z"] for x in t["lookups"]]
        print(f"   train {n}: macro {t['macro']}, {len(t['lookups'])} lookups from cycle {t['lookups'][0]['cycle']}, "
              f"entries {min(x['entry'] for x in t['lookups'])}-{max(x['entry'] for x in t['lookups'])}, rows "
              f"{min(x['row'] for x in t['lookups'])}-{max(x['row'] for x in t['lookups'])}, intervals {min(g)}-{max(g)} "
              f"cycles, zero bits per word {min(zz)}-{max(zz)} (mean {sum(zz) / len(zz):.1f})")
    missing = [n for n in ("conv1", "conv2", "fc1") if n not in plan["trains"]]
    if missing:
        print(f"   no train for: {', '.join(missing)} (fewer than {a.train_len + 1} consecutive lookups of the lane "
              f"in that macro)")


# ------------------------------------------------------------------ sequences
PARTA = ["i", "rZ", "w1000", "rPd", "w1000", "rZ", "rPs", "w1000", "rZ", "rPd", "w1000", "rH", "w1000", "rPs",
         "i", "i", "i", "i", "i", "w1000"]
# 0 idle | 1 Z (first read) | 2 static after Z | 3 Pd after the wait | 4 parked | 5 Z | 6 Ps 50 ns after Z (parking)
# | 7 parked | 8 Z | 9 Pd 50 ns after Z (parking) | 10 parked | 11 H | 12 static after H | 13 Ps | 14-18 idle clock,
# parked | 19 parked   (7.4 us)
DRIFT_IDLE = 5


def drift_seq(n):
    return ["i", "rZ"] + ["i"] * DRIFT_IDLE + ["w2000"] * n + ["rPs"] + ["i"] * DRIFT_IDLE + ["w1000"]


def train_seq(t, park):
    """one idle cycle; every lookup at its real interval; with a parking word, a parking read right after
    every lookup that has zero bits when the interval leaves room for it (>= 2 ROM reads), and after the
    last lookup (the end of the burst); then 1 us with the clock low"""
    seq = ["i"]
    n = len(t["lookups"])
    for j, x in enumerate(t["lookups"]):
        last = j == n - 1
        gap_ns = x["gap_cycles"] * CYCLE_NS
        seq.append(f"r{x['addr']}")
        parked = park is not None and x["z"] > 0 and (last or gap_ns >= 2 * PERIOD_NS)
        if parked:
            seq.append(f"r{park}")
        if last:
            break
        rest = gap_ns - (2 if parked else 1) * PERIOD_NS
        if rest < 0:
            sys.exit(f"interval {gap_ns:g} ns is shorter than one ROM read ({PERIOD_NS:g} ns)")
        if rest > 0:
            seq.append(f"w{rest:g}")
    seq.append("w1000")
    return seq


def cmd_seq(a):
    plan = json.load(open(a.plan))
    if a.what in ("parta", "drift"):
        m = plan["macros"][a.macro]
        sub = {"rZ": m["Z"]["addr"], "rH": m["H"]["addr"], "rPs": m["Ps"]["addr"], "rPd": m["Pd"]["addr"]}
        seq = PARTA if a.what == "parta" else drift_seq(a.drift_n)
        print(",".join(f"r{sub[x]}" if x in sub else x for x in seq))
        return
    t = plan["trains"].get(a.what)
    if not t:
        sys.exit(f"no train {a.what} in {a.plan}")
    park = None if a.park in (None, "none", "") else int(a.park)
    print(",".join(train_seq(t, park)))


# ------------------------------------------------------------------ results
def load_run(d):
    try:
        res = json.load(open(os.path.join(d, "result.json")))
    except (OSError, ValueError):
        return None
    meta = res["meta"]
    cc = list(zip(meta["cycles"], res["cycles"]))
    return {"meta": meta, "cc": cc, "complete": len(cc) == len(meta["cycles"]) and all(x.get("complete") for _, x in cc),
            "failed": res.get("summary", {}).get("failed", False)}


def wlen_ns(cy):
    return cy["len"] * 1e9


def read_margin(x, vm):
    """(one-cell margin, zero-cell margin) in V, None if not available"""
    b1, b0 = x.get("bl1_min_V"), x.get("bl0_max_V")
    return (None if b1 is None else b1 - vm), (None if b0 is None else vm - b0)


def cmd_select(a):
    plan = json.load(open(a.plan))
    m = plan["macros"][a.macro]
    r = load_run(os.path.dirname(a.result) if a.result.endswith(".json") else a.result)
    if r is None or len(r["cc"]) < len(PARTA) or not all(x.get("complete") for _, x in r["cc"][:len(PARTA)]):
        print("PARK none the part-A run is missing or incomplete")
        return
    cc = r["cc"]
    # average supply power of a wait (uW); the power at the very end of a wait can carry small slow transients
    # (a few uW either way after a parking read), so waits are judged by their mean power
    p = lambda i: cc[i][1]["E_vdd_pJ"] / wlen_ns(cc[i][0]) * 1e3
    # a parking read must leave at most the lowest parked power + tol, and remove at least 95 % of the power after Z
    limit = min(min(p(i) for i in (4, 7, 10, 19)) + a.tol, 0.05 * max(p(2), 0.0) + a.tol)

    def check(i_read, i_wait, name):
        x = cc[i_read][1]
        m1, m0 = read_margin(x, a.vm)
        why = []
        if m[name]["z"] != 0:
            why.append(f"it has {m[name]['z']} zero bits")
        if not x.get("ok"):
            why.append("misread")
        if x.get("selection_ok") is False:
            why.append("wrong selection")
        if m1 is not None and m1 < a.margin:
            why.append(f"one-cell margin {m1:+.3f} V")
        if m0 is not None and m0 < a.margin:
            why.append(f"zero-cell margin {m0:+.3f} V")
        if p(i_wait) > limit:
            why.append(f"left {p(i_wait):.1f} uW (limit {limit:.1f} uW; after Z {p(2):.0f} uW)")
        txt = (f"{name} row {m[name]['row']} word {m[name]['word']}: {x['E_vdd_pJ']:.1f} pJ 50 ns after Z, then "
               f"{p(i_wait):.2f} uW on average, margins " + (f"{m1:+.3f}" if m1 is not None else "-") + " / "
               + (f"{m0:+.3f}" if m0 is not None else "-") + " V")
        return (not why), x["E_vdd_pJ"], txt, why

    cands = []
    for name, i_read, i_wait in (("Pd", 9, 10), ("Ps", 6, 7)):
        ok, e, txt, why = check(i_read, i_wait, name)
        print(f"   {txt}" + ("" if ok else f"  -> not usable: {', '.join(why)}"))
        if ok:
            cands.append((e, name))
    if not cands:
        print("PARK none neither Pd nor Ps qualifies (the four waits after them: "
              + ", ".join(f"{p(i):.1f}" for i in (4, 7, 10, 19)) + " uW)")
        return
    e, name = min(cands)
    after = statistics.mean(p(i) for i in ((4, 10) if name == "Pd" else (7, 19)))
    print(f"PARK {m[name]['addr']} {name} the cheaper usable parking word ({e:.1f} pJ); afterwards {after:.2f} uW "
          f"(mean of the two waits after it)")


# ------------------------------------------------------------------ fit
def lsq(X, y):
    n = len(X[0])
    M = [[sum(r[i] * r[j] for r in X) for j in range(n)] for i in range(n)]
    v = [sum(r[i] * t for r, t in zip(X, y)) for i in range(n)]
    for i in range(n):
        p = max(range(i, n), key=lambda k: abs(M[k][i]))
        if abs(M[p][i]) < 1e-12:
            return None
        M[i], M[p], v[i], v[p] = M[p], M[i], v[p], v[i]
        for k in range(n):
            if k != i:
                f = M[k][i] / M[i][i]
                M[k] = [x - f * z for x, z in zip(M[k], M[i])]
                v[k] -= f * v[i]
    return [v[i] / M[i][i] for i in range(n)]


def fit_lin(X, y, min_n):
    """least squares; drops constant columns (coefficient 0); returns (coefs, r2, max |residual|) or None"""
    if len(y) < min_n:
        return None
    n = len(X[0])
    keep = [0] + [j for j in range(1, n) if len(set(r[j] for r in X)) > 1]
    co_k = lsq([[r[j] for j in keep] for r in X], y)
    if co_k is None:
        return None
    co = [0.0] * n
    for j, c in zip(keep, co_k):
        co[j] = c
    pred = [sum(c * xi for c, xi in zip(co, r)) for r in X]
    ym = sum(y) / len(y)
    ss = sum((t - ym) ** 2 for t in y)
    sr = sum((t - q) ** 2 for t, q in zip(y, pred))
    return co, (1 - sr / ss if ss > 0 else float("nan")), max(abs(t - q) for t, q in zip(y, pred))


READ_TERMS = ["pJ", "per row below", "per zero cell of the row", "per zero bit of the word",
              "per zero bit of the word read before"]
READ_TERMS_B = ["pJ", "per row below", "per zero cell of the row", "pJ per uW of the word's static power",
                "pJ per uW of the static power left by the read before"]
PARK_TERMS = ["pJ", "per row below (parking row)", "per zero cell (parking row)", "per zero bit of the lookup",
              "per row below (lookup row)"]
PARK_TERMS_B = ["pJ", "per row below (parking row)", "per zero cell (parking row)",
                "pJ per uW of the lookup's static power", "per row below (lookup row)"]
VARIANTS = ("count", "bits")
VARIANT_TEXT = {"count": "zero bits counted", "bits": "static power of each zero bit (non-negative fit per bit)"}


def nnls_bits(X, y, sweeps=4000):
    """least squares with an unconstrained intercept (column 0) and non-negative other coefficients
    (coordinate descent on the normal equations); columns that are never non-zero get 0"""
    n = len(X[0])
    G = [[sum(r[i] * r[j] for r in X) for j in range(n)] for i in range(n)]
    h = [sum(r[i] * t for r, t in zip(X, y)) for i in range(n)]
    b = [0.0] * n
    b[0] = sum(y) / len(y)
    for _ in range(sweeps):
        delta = 0.0
        for j in range(n):
            if G[j][j] <= 0:
                continue
            g = h[j] - sum(G[j][k] * b[k] for k in range(n))
            nb = b[j] + g / G[j][j]
            if j > 0 and nb < 0:
                nb = 0.0
            delta = max(delta, abs(nb - b[j]))
            b[j] = nb
        if delta < 1e-9:
            break
    pred = [sum(c * xi for c, xi in zip(b, r)) for r in X]
    ym = sum(y) / len(y)
    ss = sum((t - ym) ** 2 for t in y)
    sr = sum((t - q) ** 2 for t, q in zip(y, pred))
    return b, (1 - sr / ss if ss > 0 else float("nan")), max(abs(t - q) for t, q in zip(y, pred))


def p_bits(m, zv):
    """static power (uW) after a word with the zero-bit vector zv, by the per-bit model"""
    sb = m["static_bits"]
    return sb["P0_uW"] + sum(c * z for c, z in zip(sb["per_bit_uW"], zv))


def p_count(m, z):
    st = m["static"]
    return st["P0_uW"] + st["per_zero_bit_uW"] * z


def read_x(r, m=None):
    """a read's regressors; the read before it (any read of the same macro, also before a wait) still leaves its
    static current flowing until this read has switched the outputs"""
    if m is None:
        return (1.0, r["rows_below"], r["z_row"], r["z"], r["z_before"])
    return (1.0, r["rows_below"], r["z_row"], p_bits(m, r["zv"]), p_bits(m, r["zv_before"]))


def park_x(r, m=None):
    if m is None:
        return (1.0, r["rows_below"], r["z_row"], r["z_prev"], r["rb_prev"])
    return (1.0, r["rows_below"], r["z_row"], p_bits(m, r["zv_prev"]), r["rb_prev"])


def collect(dirs, rows):
    runs, reads, waits, idles = [], [], [], []
    for d in dirs:
        try:
            info = json.load(open(os.path.join(d, "info.json")))
        except (OSError, ValueError):
            continue
        r = load_run(d)
        if r is None:
            continue
        run = dict(info)
        run["dir"] = d
        run["complete"] = r["complete"]
        run["cycles"] = []
        runs.append(run)
        park = info.get("park")
        last = None                      # the last read: its record
        prev_kind = None
        n_wait = 0
        for i, (cy, x) in enumerate(r["cc"]):
            if not x.get("complete"):
                break
            base = {"run": info["label"], "table": info["table"], "side": info["side"], "macro": info["macro"],
                    "kind": info["kind"], "i": i, "E": x["E_vdd_pJ"], "P_after": x.get("P_after_uW")}
            if cy["kind"] == "read":
                z = x.get("zeros_in_word")
                eb = x.get("expected_bits") or cy.get("expected")
                zv = [1 - int(b) for b in eb] if eb else None
                rec = dict(base, addr=cy["addr"], row=cy["row"], word=cy.get("word"), rows_below=rows - 1 - cy["row"],
                           z_row=cy.get("zeros_in_row"), z=z, zv=zv, ok=x.get("ok"), sel_ok=x.get("selection_ok"),
                           bl1_min=x.get("bl1_min_V"), bl0_max=x.get("bl0_max_V"), t_acc=x.get("t_access_ns"),
                           pre=x.get("precharge_before_ns"), first=last is None,
                           z_before=None if last is None else last["z"], zv_before=None if last is None else last["zv"],
                           park=(prev_kind == "read" and z == 0 and (park is None or cy["addr"] == park)))
                if rec["park"] and last is not None:
                    rec["z_prev"], rec["rb_prev"], rec["zv_prev"] = last["z"], last["rows_below"], last["zv"]
                reads.append(rec)
                run["cycles"].append(("read", rec))
                last = rec
                n_wait = 0
            elif cy["kind"] == "wait":
                n_wait += 1
                rec = dict(base, len_ns=wlen_ns(cy), z_state=None if last is None else last["z"],
                           zv_state=None if last is None else last["zv"], after=prev_kind, nth_wait=n_wait,
                           word_state=None if last is None else last["word"],
                           rb_last=None if last is None else last["rows_below"])
                waits.append(rec)
                run["cycles"].append(("wait", rec))
            else:
                rec = dict(base, z_state=None if last is None else last["z"],
                           zv_state=None if last is None else last["zv"], after=prev_kind)
                idles.append(rec)
                run["cycles"].append((cy["kind"], rec))
            prev_kind = cy["kind"]
    return runs, reads, waits, idles


def static_waits(waits, side, exclude_table=None):
    """waits that measure the static power after one read: the first wait after a read (or after the idle
    cycles of a drift run), at least 200 ns long, in part-A, drift and train runs"""
    return [w for w in waits if w["side"] == side and w["table"] != exclude_table and w["len_ns"] >= 200
            and w["z_state"] is not None and w["zv_state"] is not None and w["nth_wait"] == 1]


def side_models(reads, waits, idles, exclude_table=None):
    """per side and variant: read window, parking read, static power (None where there are too few data)"""
    out = {}
    for side in sorted(set(r["side"] for r in reads)):
        rr = [r for r in reads if r["side"] == side and r["table"] != exclude_table and r["ok"] and not r["first"]
              and not r["park"] and r["z_row"] is not None and r["zv"] is not None and r["zv_before"] is not None
              and r["kind"] in ("parta", "train")]
        pp = [r for r in reads if r["side"] == side and r["table"] != exclude_table and r["ok"] and r["park"]
              and "z_prev" in r and r["z_row"] is not None and r.get("zv_prev") is not None]
        ww = static_waits(waits, side, exclude_table)
        m = {"tables": sorted(set(r["table"] for r in rr))}
        pw = [w["E"] / w["len_ns"] * 1e3 for w in ww]
        f = fit_lin([(1.0, w["z_state"]) for w in ww], pw, 4)
        if f:
            m["static"] = {"P0_uW": f[0][0], "per_zero_bit_uW": f[0][1], "r2": f[1], "max_resid_uW": f[2], "n": len(ww)}
        if len(ww) >= 8:
            b, r2_, mx = nnls_bits([[1.0] + w["zv_state"] for w in ww], pw)
            m["static_bits"] = {"P0_uW": b[0], "per_bit_uW": b[1:], "r2": r2_, "max_resid_uW": mx, "n": len(ww),
                                "bits_seen_zero": [sum(w["zv_state"][j] for w in ww) for j in range(16)]}
        f = fit_lin([read_x(r) for r in rr], [r["E"] for r in rr], 8)
        if f:
            m["read"] = {"coef": f[0], "r2": f[1], "max_resid_pJ": f[2], "n": len(rr)}
        if "static_bits" in m:
            f = fit_lin([read_x(r, m) for r in rr], [r["E"] for r in rr], 8)
            if f:
                m["read_bits"] = {"coef": f[0], "r2": f[1], "max_resid_pJ": f[2], "n": len(rr)}
        f = fit_lin([park_x(r) for r in pp], [r["E"] for r in pp], 8)
        if f:
            m["park"] = {"coef": f[0], "r2": f[1], "max_resid_pJ": f[2], "n": len(pp)}
        if "static_bits" in m:
            f = fit_lin([park_x(r, m) for r in pp], [r["E"] for r in pp], 8)
            if f:
                m["park_bits"] = {"coef": f[0], "r2": f[1], "max_resid_pJ": f[2], "n": len(pp)}
        ip = [i["E"] for i in idles if i["side"] == side and i["table"] != exclude_table and i["kind"] == "parta"
              and i["z_state"] == 0]
        if ip:
            m["idle_parked_pJ"] = statistics.median(ip)
        out[side] = m
    return out


def predict_segment(seg, m, variant):
    """model energy of one segment (list of (kind, rec)); None if a part has no model"""
    need = ("read", "park", "static") if variant == "count" else ("read_bits", "park_bits", "static_bits")
    e = 0.0
    state = None                       # the last read of the segment
    for kind, r in seg:
        if kind == "read":
            if r["park"]:
                key = need[1]
                if key not in m:
                    return None
                x = park_x(r) if variant == "count" else park_x(r, m)
            else:
                key = need[0]
                if key not in m:
                    return None
                x = read_x(r) if variant == "count" else read_x(r, m)
            e += sum(c * xi for c, xi in zip(m[key]["coef"], x))
            state = r
        elif kind == "wait":
            if need[2] not in m or state is None:
                return None
            p = p_count(m, state["z"]) if variant == "count" else p_bits(m, state["zv"])
            e += p * r["len_ns"] * 1e-3
        else:
            return None                    # trains have no idle cycle after their first lookup
    return e


def segments(run):
    """the lookups of a train run and what follows each one up to the next lookup"""
    cyc = run["cycles"]
    idx = [i for i, (k, r) in enumerate(cyc) if k == "read" and not r["park"]]
    return [cyc[s:(idx[j + 1] if j + 1 < len(idx) else len(cyc))] for j, s in enumerate(idx)]


def fmt_terms(co, terms):
    return " ".join(f"{c:+.3f} {t}" if j else f"{c:.2f} {t}" for j, (c, t) in enumerate(zip(co, terms)))


def cmd_fit(a):
    runs, reads, waits, idles = collect(a.dirs, a.rows)
    out = {"rows": a.rows, "vm_V": a.vm, "runs": [{k: v for k, v in r.items() if k != "cycles"} for r in runs]}
    print(f"   {len(runs)} runs with results ({sum(1 for r in runs if r['complete'])} complete): "
          f"{sum(1 for r in runs if r['kind'] == 'parta')} part A, {sum(1 for r in runs if r['kind'] == 'drift')} drift, "
          f"{sum(1 for r in runs if r['kind'] == 'train')} trains; {len(reads)} reads "
          f"({sum(1 for r in reads if r['park'])} parking reads), {len(waits)} waits, {len(idles)} idle cycles")
    if not reads:
        json.dump(out, open(a.out, "w"), indent=1)
        return

    # ---- read margins and correctness of every read of E8.4b
    print(f"\n   reads (rule: every read correct, no wrong selection, lowest one-cell bitline - {a.vm:.3f} V >= "
          f"{a.margin:.2f} V, {a.vm:.3f} V - highest zero-cell bitline >= {a.margin:.2f} V):")
    groups = [("lookups of the trains", [r for r in reads if r["kind"] == "train" and not r["park"]]),
              ("parking reads (50 ns after a read)", [r for r in reads if r["park"]]),
              ("part-A and drift reads (not parking)", [r for r in reads if r["kind"] != "train" and not r["park"]])]
    allok = True
    marg = {}
    for name, rr in groups:
        if not rr:
            continue
        m1 = [r["bl1_min"] - a.vm for r in rr if r["bl1_min"] is not None]
        m0 = [a.vm - r["bl0_max"] for r in rr if r["bl0_max"] is not None]
        wrong = sum(1 for r in rr if not r["ok"])
        sel = sum(1 for r in rr if r["sel_ok"] is False)
        good = wrong == 0 and sel == 0 and (not m1 or min(m1) >= a.margin) and (not m0 or min(m0) >= a.margin)
        allok = allok and good
        ta = [r["t_acc"] for r in rr if r["t_acc"] is not None]
        marg[name] = {"reads": len(rr), "wrong": wrong, "wrong_selection": sel, "min_margin_one_V": min(m1) if m1 else None,
                      "min_margin_zero_V": min(m0) if m0 else None, "t_access_max_ns": max(ta) if ta else None}
        worst = min((r for r in rr if r["bl1_min"] is not None), key=lambda r: r["bl1_min"], default=None)
        print(f"      {name:<38} {len(rr):5d} reads, {wrong} wrong, {sel} wrong selections, margin one cells "
              + (f"{min(m1):+.3f}" if m1 else "-") + " V, zero cells " + (f"{min(m0):+.3f}" if m0 else "-") + " V"
              + (f", access <= {max(ta):.2f} ns" if ta else "") + ("" if good else "   X")
              + (f"   (lowest: {worst['run']} cycle {worst['i']}, row {worst['row']}, precharge "
                 f"{worst['pre']:.0f} ns)" if worst and worst.get("pre") is not None else ""))
    out["margins"] = marg
    out["margins_ok"] = allok

    # ---- part A per macro
    print("\n   part A per macro (tt, 25 C, 1.80 V; mean supply power of each wait with the clock low; Z/H: zero bits;")
    print("   uW/bit = (P after Z - parked) / zero bits of Z; parked = mean of the 4 waits after parking reads (range);")
    print("   park = Ps / Pd read 50 ns after Z; idle = an idle clock cycle (CS low) when parked; E Z = Z read after 1 us parked)")
    print(f"      {'macro':<30} {'Z/H':>5} {'P Z uW':>8} {'uW/bit':>7} {'P H uW':>7} {'parked uW':>17} {'park pJ':>13} "
          f"{'idle pJ':>7} {'E Z pJ':>7}  parking word")
    pm = []
    for run in sorted((r for r in runs if r["kind"] == "parta"), key=lambda r: r["macro"]):
        cyc = run["cycles"]
        if len(cyc) < len(PARTA):
            print(f"      {run['macro']:<30} incomplete ({len(cyc)} of {len(PARTA)} cycles)")
            continue
        g = lambda i: cyc[i][1]
        pav = lambda i: g(i)["E"] / g(i)["len_ns"] * 1e3          # average power of a wait, uW
        zZ, zH = g(1)["z"], g(11)["z"]
        lk = [pav(i) for i in (4, 7, 10, 19)]
        leak = statistics.mean(lk)
        pz, ph = pav(2), pav(12)
        per_bit = (pz - leak) / zZ if zZ else None
        idle = statistics.median(g(i)["E"] for i in range(14, 19))
        rec = {"macro": run["macro"], "table": run["table"], "side": run["side"], "k": run["k"], "z_Z": zZ, "z_H": zH,
               "P_Z_uW": pz, "P_Z_end_uW": g(2)["P_after"], "P_H_uW": ph, "leak_uW": lk, "leak_mean_uW": leak,
               "per_zero_bit_uW": per_bit, "H_check_uW": None if per_bit is None else leak + per_bit * zH,
               "park_Ps_pJ": g(6)["E"], "park_Pd_pJ": g(9)["E"], "idle_parked_pJ": idle, "E_Z_pJ": [g(i)["E"] for i in (1, 5, 8)],
               "E_Pd_after_wait_pJ": g(3)["E"], "E_H_pJ": g(11)["E"], "E_Ps_after_wait_pJ": g(13)["E"],
               "park_choice": run.get("park_choice", "")}
        pm.append(rec)
        print(f"      {run['macro']:<30} {zZ:2d}/{zH:<2d} {pz:8.1f} " + (f"{per_bit:7.2f}" if per_bit is not None else f"{'-':>7}")
              + f" {ph:7.1f} {leak:6.2f} ({min(lk):+.1f}..{max(lk):+.1f}) {g(6)['E']:6.1f}/{g(9)['E']:<6.1f} {idle:7.2f} "
              f"{g(5)['E']:7.1f}  {rec['park_choice']}")
    out["parta"] = pm
    if pm:
        hz = [(r["P_H_uW"], r["H_check_uW"]) for r in pm if r["H_check_uW"] is not None and r["z_H"] > 0]
        if hz:
            dev = [abs(p - q) / q * 100 for p, q in hz if q > 0]
            print(f"      proportional to the zero bits? the power after H against parked + (uW per bit) x zero bits of H: "
                  f"deviation {min(dev):.0f}-{max(dev):.0f} % (median {statistics.median(dev):.0f} %) over {len(dev)} macros")
        dr = [(r["P_Z_uW"] / r["P_Z_end_uW"] - 1) * 100 for r in pm if r["P_Z_end_uW"] > 0]
        print(f"      within the 1 us after Z: mean power / power at the end = {min(dr):+.2f} to {max(dr):+.2f} %")

    # ---- drift
    print("\n   drift runs (the power after Z while the clock stays low):")
    dd = []
    for run in (r for r in runs if r["kind"] == "drift"):
        cyc = run["cycles"]
        wl = [(k, r) for k, r in cyc if k == "wait"]
        if not wl:
            print(f"      {run['macro']}: no wait finished")
            continue
        t, pts, seen = 0.0, [], False
        z = next(r["z"] for k, r in cyc if k == "read")
        for k, r in cyc:
            if k == "read":
                if seen:
                    break
                seen = True
                continue
            if not seen:
                continue
            t += r["len_ns"] if k == "wait" else PERIOD_NS
            if k == "wait":
                pts.append((t / 1000, r["P_after"]))
        idle_z = [r["E"] for k, r in cyc[2:2 + DRIFT_IDLE] if k == "idle"]
        idle_p = [r["E"] for k, r in cyc if k == "idle" and r["z_state"] == 0]
        slope = None
        if len(pts) >= 3:
            co = lsq([(1.0, x) for x, _ in pts], [y for _, y in pts])
            slope = co[1] / co[0] * 100 if co and co[0] else None
        rec = {"macro": run["macro"], "z": z, "points_us_uW": pts, "slope_pct_per_us": slope,
               "idle_after_Z_pJ": idle_z, "idle_parked_pJ": idle_p}
        dd.append(rec)
        print(f"      {run['macro']}: Z with {z} zero bits; " + ", ".join(f"{x:.0f} us {y:.1f}" for x, y in pts)
              + " uW" + (f"; {slope:+.3f} % per us (linear fit)" if slope is not None else "")
              + (f"; idle clock after Z {statistics.median(idle_z):.1f} pJ per cycle" if idle_z else "")
              + (f", parked {statistics.median(idle_p):.2f} pJ" if idle_p else ""))
    out["drift"] = dd

    # ---- models per side (all tables) and leave-one-table-out validation on the trains
    models = side_models(reads, waits, idles)
    out["models"] = models
    print("\n   models per side, fitted on all tables (E8.6 applies them to every lookup of the trace):")
    for side, m in models.items():
        print(f"      {side} ({len(m['tables'])} tables):")
        if "static" in m:
            f = m["static"]
            print(f"         static power with the clock low after a read, zero bits counted: P = {f['P0_uW']:.2f} uW + "
                  f"{f['per_zero_bit_uW']:.2f} uW x zero bits  (r^2 {f['r2']:.3f}, {f['n']} waits, largest residual "
                  f"{f['max_resid_uW']:.0f} uW)")
        if "static_bits" in m:
            f = m["static_bits"]
            print(f"         static power, each output bit (dout0[0] .. [15]) on its own: P = {f['P0_uW']:.2f} uW + "
                  f"the bits' values  (r^2 {f['r2']:.3f}, largest residual {f['max_resid_uW']:.0f} uW)")
            print("            uW per zero bit: " + " ".join(f"{c:.0f}" for c in f["per_bit_uW"])
                  + "   (waits in which the bit was zero: " + " ".join(str(c) for c in f["bits_seen_zero"]) + ")")
        for key, terms in (("read", READ_TERMS), ("read_bits", READ_TERMS_B)):
            if key in m:
                f = m[key]
                print(f"         read window ({'zero bits counted' if key == 'read' else 'static power of the word'}): "
                      f"E = {fmt_terms(f['coef'], terms)}  (r^2 {f['r2']:.3f}, {f['n']} reads, largest residual "
                      f"{f['max_resid_pJ']:.1f} pJ)")
        for key, terms in (("park", PARK_TERMS), ("park_bits", PARK_TERMS_B)):
            if key in m:
                f = m[key]
                print(f"         parking read ({'zero bits counted' if key == 'park' else 'static power of the lookup'}): "
                      f"E = {fmt_terms(f['coef'], terms)}  (r^2 {f['r2']:.3f}, {f['n']} parking reads, largest "
                      f"residual {f['max_resid_pJ']:.1f} pJ)")
        if "idle_parked_pJ" in m:
            print(f"         idle clock cycle (CS low) when parked: {m['idle_parked_pJ']:.2f} pJ (median of part A)")
        if "static_bits" in m:
            # does the static power of a zero bit also depend on the word position (column-select line)?
            ww = [w for w in static_waits(waits, side) if w["word_state"] is not None and w["z_state"] > 0]
            byw = {}
            for w in ww:
                byw.setdefault(w["word_state"], []).append(w["E"] / w["len_ns"] * 1e3 - p_bits(m, w["zv_state"]))
            if byw:
                print("         static power, per-bit model, residual by word position of the word read (mean uW, waits): "
                      + "  ".join(f"w{k} {statistics.mean(v):+.0f} ({len(v)})" for k, v in sorted(byw.items())))
    tables = sorted(set(r["table"] for r in runs if r["kind"] == "train"))
    loto = {t: side_models(reads, waits, idles, exclude_table=t) for t in tables}
    val = []
    print("\n   trains: measured energy against the model (segments 2 to the end; the first lookup follows the start of")
    print("   the simulation). The model of each train is fitted without the train's table (leave one table out);")
    print("   'in-sample' marks a side with only this table, where the model includes the train itself.")
    print(f"      {'run':<36} {'lookups':>7} {'parks':>5} {'measured pJ':>11} | {'counted pJ':>10} {'error':>7} | "
          f"{'per bit pJ':>10} {'error':>7} | {'model':>9}")
    for t in tables:
        for run in sorted((r for r in runs if r["kind"] == "train" and r["table"] == t), key=lambda r: r["label"]):
            if not run["complete"]:
                print(f"      {run['label']:<36} incomplete")
                continue
            segs = segments(run)[1:]
            if not segs:
                continue
            m = loto[t].get(run["side"], {})
            how = "LOTO"
            if not any(k in m for k in ("read", "read_bits")):
                m, how = models.get(run["side"], {}), "in-sample"
            meas = sum(r["E"] for sg in segs for _, r in sg)
            nparks = sum(1 for sg in segs for k, r in sg if k == "read" and r["park"])
            rec = {"run": run["label"], "table": t, "side": run["side"], "train": run.get("train"), "park": run.get("park"),
                   "segments": len(segs), "parks": nparks, "measured_pJ": meas, "how": how,
                   "seg_measured_pJ": [sum(r["E"] for _, r in sg) for sg in segs]}
            line = f"      {run['label']:<36} {len(segs):7d} {nparks:5d} {meas:11.1f}"
            for v in VARIANTS:
                pred = [predict_segment(sg, m, v) for sg in segs]
                if any(q is None for q in pred):
                    line += f" | {'no model':>10} {'':>7}"
                    continue
                P = sum(pred)
                rec[f"model_{v}_pJ"] = P
                rec[f"error_{v}_pct"] = (P / meas - 1) * 100
                rec[f"seg_model_{v}_pJ"] = pred
                line += f" | {P:10.1f} {rec[f'error_{v}_pct']:+6.1f}%"
            val.append(rec)
            print(line + f" | {how:>9}")
    summary = {}
    for v in VARIANTS:
        vv = [x for x in val if f"error_{v}_pct" in x]
        if not vv:
            continue
        e = [abs(x[f"error_{v}_pct"]) for x in vv]
        se = [abs(p / q - 1) * 100 for x in vv for p, q in zip(x[f"seg_model_{v}_pJ"], x["seg_measured_pJ"]) if q > 0]
        tm, tp = sum(x["measured_pJ"] for x in vv), sum(x[f"model_{v}_pJ"] for x in vv)
        summary[v] = {"trains": len(vv), "median_abs_error_pct": statistics.median(e), "max_abs_error_pct": max(e),
                      "total_error_pct": (tp / tm - 1) * 100, "segment_median_abs_error_pct": statistics.median(se),
                      "in_sample": sum(1 for x in vv if x["how"] == "in-sample")}
        print(f"      {VARIANT_TEXT[v]}: {len(vv)} trains; |error| of a train median {statistics.median(e):.1f} %, "
              f"largest {max(e):.1f} %; all trains together {(tp / tm - 1) * 100:+.2f} %; single segments median "
              f"{statistics.median(se):.1f} %")
        for kind in ("with parking", "without parking"):
            ww = [x for x in vv if (x["park"] is not None) == (kind == "with parking")]
            if ww:
                print(f"         {kind:<16}: {len(ww)} trains, together "
                      f"{(sum(x[f'model_{v}_pJ'] for x in ww) / sum(x['measured_pJ'] for x in ww) - 1) * 100:+.2f} %, "
                      f"largest |error| {max(abs(x[f'error_{v}_pct']) for x in ww):.1f} %")
    if summary:
        ok = {v: s_["max_abs_error_pct"] <= a.train_tol and abs(s_["total_error_pct"]) <= a.total_tol
              for v, s_ in summary.items()}
        print(f"      criterion (set before the run): every train within +-{a.train_tol:g} % and all trains together "
              f"within +-{a.total_tol:g} %: " + ", ".join(f"{VARIANT_TEXT[v]} {'MET' if ok[v] else 'NOT MET'}"
                                                         for v in summary))
        if any(s_["in_sample"] for s_ in summary.values()):
            print("      (some trains were checked in-sample: the criterion is meant for leave-one-table-out)")
        out["validation_summary"] = {v: dict(summary[v], criterion_met=ok[v]) for v in summary}
    out["validation"] = val

    # ---- the same trains with and without parking (conv2 of every table)
    pairs = []
    for t in tables:
        a_ = next((r for r in runs if r["table"] == t and r.get("train") == "conv2" and r.get("park") is not None
                   and r["complete"]), None)
        b_ = next((r for r in runs if r["table"] == t and r.get("train") == "conv2" and r.get("park") is None
                   and r["complete"]), None)
        if a_ and b_:
            ea = sum(r["E"] for s in segments(a_)[1:] for _, r in s)
            eb = sum(r["E"] for s in segments(b_)[1:] for _, r in s)
            n = len(segments(a_)) - 1
            pairs.append({"table": t, "side": a_["side"], "park_pJ": ea, "nopark_pJ": eb, "lookups": n})
    if pairs:
        print("\n   conv2 trains, the same lookups with and without parking (segments 2 to the end):")
        for p in pairs:
            print(f"      {p['table']:<28} {p['side']:<5} with parking {p['park_pJ'] / p['lookups']:7.1f} pJ per lookup, "
                  f"without {p['nopark_pJ'] / p['lookups']:7.1f} pJ ({(p['park_pJ'] / p['nopark_pJ'] - 1) * 100:+.1f} %)")
    out["conv2_pairs"] = pairs

    # ---- E8.4a-7 screening reads against the read model (a different preceding read: row 0, 90 ns before)
    if a.ref:
        print("\n   E8.4a-7 screening reads (each 90 ns after a read of row 0, not a system sequence) against the read "
              "models fitted here:")
        ref = []
        for spec in a.ref:
            side, d = spec.split("=", 1)
            r = load_run(d)
            m = models.get(side, {})
            if r is None or "read" not in m:
                continue
            first = None
            before = None                    # (z, zero vector) of the read before
            for cy, x in r["cc"]:
                if cy["kind"] != "read" or not x.get("complete") or not x.get("ok"):
                    continue
                eb = x.get("expected_bits")
                zv = [1 - int(b) for b in eb] if eb else None
                prev, before = before, (x.get("zeros_in_word"), zv)
                if first is None:
                    first = cy["addr"]
                if cy["addr"] == first or prev is None:
                    continue                 # the reads of row 0 before every target
                rec = {"rows_below": a.rows - 1 - cy["row"], "z_row": cy.get("zeros_in_row"), "z": x.get("zeros_in_word"),
                       "zv": zv, "z_before": prev[0], "zv_before": prev[1]}
                if rec["z_row"] is None or rec["z"] is None or rec["z_before"] is None:
                    continue
                pc = sum(c * v for c, v in zip(m["read"]["coef"], read_x(rec)))
                pb = (sum(c * v for c, v in zip(m["read_bits"]["coef"], read_x(rec, m)))
                      if "read_bits" in m and rec["zv"] is not None and rec["zv_before"] is not None else None)
                ref.append((side, x["E_vdd_pJ"], pc, pb))
        for side in sorted(set(x[0] for x in ref)):
            rr = [x for x in ref if x[0] == side]
            line = f"      {side}: {len(rr)} reads (measured mean {statistics.mean(x[1] for x in rr):.1f} pJ); model - measured, "
            for j, v in ((2, "count"), (3, "bits")):
                dif = [x[j] - x[1] for x in rr if x[j] is not None]
                if dif:
                    line += (f"{VARIANT_TEXT[v].split(' (')[0]}: median {statistics.median(dif):+.2f} pJ, mean "
                             f"{statistics.mean(dif):+.2f} pJ; ")
            print(line.rstrip("; "))
        out["ref_check"] = [{"side": x[0], "E": x[1], "model_count": x[2], "model_bits": x[3]} for x in ref]
    out["reads"] = reads
    out["waits"] = waits
    out["idles"] = idles
    json.dump(out, open(a.out, "w"), indent=1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("lookups")
    p.add_argument("--trace", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--lane", type=int, required=True)
    p.add_argument("--out", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--bin", required=True)
    p.add_argument("--lookups", required=True)
    p.add_argument("--rows", type=int, default=48)
    p.add_argument("--wpr", type=int, default=13)
    p.add_argument("--train-len", type=int, default=13)
    p.add_argument("--out", required=True)
    p = sub.add_parser("seq")
    p.add_argument("--plan", required=True)
    p.add_argument("--what", required=True)
    p.add_argument("--macro", type=int, default=0)
    p.add_argument("--park", default=None)
    p.add_argument("--drift-n", type=int, default=10)
    p = sub.add_parser("select")
    p.add_argument("--plan", required=True)
    p.add_argument("--macro", type=int, required=True)
    p.add_argument("--result", required=True)
    p.add_argument("--vm", type=float, required=True)
    p.add_argument("--margin", type=float, default=0.10)
    p.add_argument("--tol", type=float, default=10.0,
                   help="uW above the lowest parked power (and above 5 %% of the power after Z) still counted as parked")
    p = sub.add_parser("fit")
    p.add_argument("--dirs", nargs="+", required=True)
    p.add_argument("--vm", type=float, required=True)
    p.add_argument("--rows", type=int, default=48)
    p.add_argument("--margin", type=float, default=0.10)
    p.add_argument("--ref", nargs="*", default=[], help="SIDE=DIR: E8.4a-7 screening runs of that side")
    p.add_argument("--train-tol", type=float, default=10.0, help="criterion: largest |error| of one train, %%")
    p.add_argument("--total-tol", type=float, default=5.0, help="criterion: |error| of all trains together, %%")
    p.add_argument("--out", required=True)
    a = ap.parse_args()
    {"lookups": cmd_lookups, "plan": cmd_plan, "seq": cmd_seq, "select": cmd_select, "fit": cmd_fit}[a.cmd](a)


if __name__ == "__main__":
    main()
