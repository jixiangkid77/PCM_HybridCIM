#!/usr/bin/env python3
"""
e8_6a2_rom_energy.py   (P2R-E8.6a-2)

E8.6a (scripts/e8_6a_rom_energy.py: D_ROM, the energy of the address-map ROM
over one inference, from the E8.4b models, for all 100 tables and every lookup
of the E8.2 trace) with, in one run:

  1. R (repeat skip): the interface keeps the result of the last lookup of
     each lane and reads the ROM only when the entry changes. In the E8.2
     trace conv1 applies each weight to consecutive outputs (E8.4b: the conv1
     train read entry 0 thirteen times in a row), so most conv1 lookups repeat
     the entry before them; the run prints the ROM reads per layer with and
     without R. Every way of running and every option is computed for all
     lookups (as E8.6a; these numbers must equal E8.6a's) and with R.
  2. D by layer: reads and parks by the layer of the lookup, and the static
     energy above the parked level by the layer of the read that left it;
     the parked level (leakage) separately.
  3. Macros without a word of 0xFFFF: parked with the word of fewest zero bits
     (E8.6a), and, as a sensitivity, with the word of the lowest static power
     of the model (bits form).
  4. O2 (merged tables): the reserved parking word placed in the row chosen by
     the Pd rule of E8.4b (deep row, few zero cells); E8.6a put it in the
     deepest row. Both sides' models in turn, as in E8.6a.
  5. Merged tables against the current tables: the cells that set the read
     margin. In E8.4a-7 the lowest 1-cell bitlines were 1 cells whose two
     neighbouring columns discharge in the same read (column = bit x 13 +
     word), with a long string of 0 cells above them in their column. Per
     table: the share of such two-sided 1 cells, the longest string of 0 cells
     above a two-sided cell, and the number of two-sided cells with at least
     30 above (A_pcm_l00 k3 row 43 column 12, the lowest of E8.4a-7, has 32).
     These are indicators, not margins.
  6. Shared entry: for every operation of the trace, whether all lanes that
     look up use the same entry (if so, the 25 tables of a side are always
     read at the same entry, and one table with 400-bit words would serve an
     operation with one read).

Ways of running (as E8.6a):
  GPp  gated clock (a pulse only for a read), every macro parked on its own
  GPs  gated, one read per 100 ns slot per table, parks only in free slots
  GN   gated, no parking
  FP   free-running ROM clock, parking as GPp
  FN   free-running, no parking
Energy of each event: the E8.4b model of each side in two forms (bits, count);
static power while the clock is low: the measured parked power after a word
without zero bits, else the model's static power (not below the parked power).
Uncertainty (GPp, GPs): E8.4b leave-one-table-out errors of the conv1, conv2
(parking) and fc1 trains per table, weighted by the lane's ROM reads of each
layer (all lookups, or with R) x the measured energy per lookup; per side mean
and standard error over 6 tables; range = D_side / (1 + mean +- 2 SE).
Options (estimates from the same models, bits form; the energy of added devices
or logic not included): O1 no static current after a read (generator change);
O2 the two sides of a lane merged into one table (RTL change); O3 both.

Usage:
  python3 scripts/e8_6a2_rom_energy.py --paper2 /mnt/d/Project/hybrid_memory/paper2
Writes reports/e8_rom/e8_6a2/d_rom.json; reads everything else only.
Imports scripts/e8_4b_energy_tools.py (same directory) for the checks.
"""
import argparse
import hashlib
import json
import math
import os
import statistics
import sys
import time

K = 25
LAYERS = ["conv1", "conv2", "fc1", "fc2", "fc3"]
DEPTH = [6, 96, 1920, 420, 40]
OFFSET = [0, 6, 102, 2022, 2442]
IN_RANGE = [150, 2400, 48000, 10080, 840]
MISS = 0xFFFF
CYCLE_NS = 10.0
SLOT_NS = 100.0                      # one ROM read: 50 ns clock low + 50 ns high
SRAM_SLOTS, PCM_SLOTS = 3074, 58396  # pcm_imc_unit parameters (E8.2)
MANUSCRIPT_D_UJ = 9.85               # 833,040 x 11.82 pJ (manuscript; locked figure, compared only)
POLICIES = ["GPp", "GPs", "GN", "FP", "FN"]
POLICY_TEXT = {"GPp": "gated, parking per macro",
               "GPs": "gated, parking in free slots",
               "GN": "gated, no parking",
               "FP": "free-running, parking per macro",
               "FN": "free-running, no parking"}
VARIANTS = [("all", "all lookups (as E8.6a)"), ("R", "R: a repeated entry is not read again")]
BUCKETS = LAYERS + ["parked"]        # static and idle energy at the parked level go to "parked"
# sandbox fit of E8.4a-7 (r32k0, tt): 1-cell bitline ~ 1.821 - 1.35 mV x row - 152.1 mV x discharging neighbours
# - 0.78 mV x 0 cells directly above; ranks cells only (E8.4a-7: the lowest cells are far below the fit)
LONG_ZERO_STRING = 30


# ------------------------------------------------------------------ tables and lookups
def read_memh(path, depth):
    """$readmemh replica (as scripts/e8_3_rom_tools.py): unloaded words keep 0xFFFF"""
    mem = [MISS] * depth
    addr = 0
    with open(path) as fh:
        for raw in fh:
            line = raw.split("//", 1)[0]
            for tok in line.split():
                if tok.startswith("@"):
                    addr = int(tok[1:], 16)
                    continue
                if addr < depth:
                    mem[addr] = int(tok, 16)
                addr += 1
    return mem


def table_words(paper2, model, side, lane, n_words):
    d = os.path.join(paper2, "data", f"rtl_inputs_{model}_v3")
    words = []
    for li, name in enumerate(LAYERS):
        f = os.path.join(d, f"addr_to_slot_{name}_{side}_lane{lane:02d}.hex")
        if not os.path.isfile(f):
            sys.exit(f"missing table file {f}")
        words += read_memh(f, DEPTH[li])
    return words + [MISS] * (n_words - len(words))


def decode(layer, o16, lane):
    """replica of the RTL decoders' index arithmetic (as scripts/e8_2_trace_summary.py, checked in E8.2)"""
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


def parse_trace(path):
    """per lane [(cycle, layer, entry)], the done cycle, the number of operations, and per layer the operations whose
    looking-up lanes do not all use the same entry, the operations without a lookup, and the lanes looking up"""
    lk = [[] for _ in range(K)]
    done, ops = None, 0
    shared = {"mixed": [0] * 5, "none": [0] * 5, "lanes": [0] * 5, "ops": [0] * 5}
    with open(path) as fh:
        for line in fh:
            if line.startswith("# done_cycle"):
                done = int(line.split()[2])
                break
            if line.startswith("#") or not line.strip():
                continue
            f = line.split()
            if len(f) != 6 + K:
                sys.exit(f"{path}: malformed line {line[:80]}")
            ops += 1
            cyc, layer = int(f[0]), int(f[1])
            ents = set()
            for lane in range(K):
                idx = decode(layer, int(f[6 + lane].split(":")[0], 16), lane)
                if idx is not None:
                    lk[lane].append((cyc, layer, OFFSET[layer] + idx))
                    ents.add(idx)
                    if layer < 5:
                        shared["lanes"][layer] += 1
            if layer < 5:
                shared["ops"][layer] += 1
                shared["mixed"][layer] += len(ents) > 1
                shared["none"][layer] += not ents
    if done is None:
        sys.exit(f"{path}: no '# done_cycle' line")
    return lk, done, ops, shared


def skip_repeats(lk):
    """R: the lookups that read the ROM when the result of the last lookup is kept"""
    out = []
    for x in lk:
        if out and out[-1][2] == x[2]:
            continue
        out.append(x)
    return out


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def zbits(w):
    return 16 - bin(w & 0xFFFF).count("1")


def zvec(w):
    """zero indicator per output bit, dout0[0] (= the entry's most significant bit) first"""
    return [0 if (w >> (15 - b)) & 1 else 1 for b in range(16)]


# ------------------------------------------------------------------ models
class SideModel:
    """the E8.4b model of one side in one form; f() precomputed for every 16-bit word"""

    def __init__(self, ms, variant, leak_uW, idle_pJ, no_static=False):
        self.variant, self.leak, self.idle = variant, leak_uW, idle_pJ
        if variant == "bits":
            sb = ms["static_bits"]
            c = sb["per_bit_uW"]
            pm = [sb["P0_uW"] + sum(c[b] for b in range(16) if not (w >> (15 - b)) & 1) for w in range(65536)]
            self.fread, self.fpark = pm, pm                      # regressor: the model's static power (uW)
            self.rc, self.pc = ms["read_bits"]["coef"], ms["park_bits"]["coef"]
        else:
            st = ms["static"]
            pm = [st["P0_uW"] + st["per_zero_bit_uW"] * zbits(w) for w in range(65536)]
            zc = [zbits(w) for w in range(65536)]
            self.fread, self.fpark = zc, zc
            self.rc, self.pc = ms["read"]["coef"], ms["park"]["coef"]
        self.pm = pm                                            # the fitted static power, as e8_4b_energy_tools
        # static power while the clock is low: the measured parked power after a word without zero bits; the fitted
        # value for other words, not below the parked power (bits with a zero coefficient leave P0, which can be < 0)
        self.ps = [leak_uW if w == MISS else max(pm[w], leak_uW) for w in range(65536)]
        if no_static:                                           # option O1: no static current after a read
            f0 = self.fread[MISS]
            self.fread = self.fpark = [f0] * 65536
            self.ps = [leak_uW] * 65536

    def read(self, rb, zr, w, w_before):
        a = self.rc
        return a[0] + a[1] * rb + a[2] * zr + a[3] * self.fread[w] + a[4] * self.fread[w_before]

    def park(self, rb_p, zr_p, w_lookup, rb_lookup):
        a = self.pc
        return a[0] + a[1] * rb_p + a[2] * zr_p + a[3] * self.fpark[w_lookup] + a[4] * rb_lookup


def pd_key(rows, zr_row, r):
    """the Pd rule of E8.4b: deep row, few zero cells"""
    return 0.3 * (rows - 1 - r) + 0.18 * zr_row


class Table:
    def __init__(self, words, rows, wpr, park_choice=None, virtual_park=False, fallback=None):
        """fallback: key over words for a macro without a word of 0xFFFF (default: fewest zero bits);
        virtual_park: such a macro gets a reserved word of 0xFFFF in the row of the Pd rule (option tables)"""
        self.words, self.rows, self.wpr = words, rows, wpr
        self.per = rows * wpr
        self.nmac = len(words) // self.per
        self.zr = [[sum(zbits(x) for x in words[k * self.per + r * wpr:k * self.per + (r + 1) * wpr]) for r in range(rows)]
                   for k in range(self.nmac)]
        self.park, self.park_src = [], []
        for k in range(self.nmac):
            got = None
            if park_choice and park_choice.get(k) is not None:
                a = park_choice[k]
                r, w = a >> 4, a & 15
                if r < rows and w < wpr and words[k * self.per + r * wpr + w] == MISS:
                    got, src = (r, w), "E8.4b"
            if got is None:
                ones = [(r, w) for r in range(rows) for w in range(wpr) if words[k * self.per + r * wpr + w] == MISS]
                if ones:          # Pd rule of E8.4b: deep row, few zero cells
                    got = min(ones, key=lambda rw: (pd_key(rows, self.zr[k][rw[0]], rw[0]), rw))
                    src = "Pd rule"
                elif virtual_park:  # option tables: a reserved word of 0xFFFF in the row of the Pd rule
                    r = min(range(rows), key=lambda rr: (pd_key(rows, self.zr[k][rr], rr), rr))
                    self.park.append((r, MISS))
                    self.park_src.append("added (estimate)")
                    continue
                else:             # no word without zero bits: the fewest zero bits, or the given key
                    key = fallback or (lambda x: zbits(x))
                    got = min(((r, w) for r in range(rows) for w in range(wpr)),
                              key=lambda rw: (key(words[k * self.per + rw[0] * wpr + rw[1]]), rw))
                    src = "no word without zero bits"
            self.park.append((got[0], words[k * self.per + got[0] * wpr + got[1]]))
            self.park_src.append(src)

    def loc(self, e):
        k = e // self.per
        r = (e % self.per) // self.wpr
        return k, r, self.words[e]


def simulate(tab, lk, sm, policy, t_end_ns):
    """energy (pJ) of one table over the inference: read, park, static, idle; parks; reads and parks by layer;
    static and idle energy by bucket (above the parked level: the layer of the read that left the state)"""
    rows = tab.rows
    free = policy in ("FP", "FN")
    parking = policy in ("GPp", "GPs", "FP")
    serial = policy == "GPs"
    st_w = [tab.park[k][1] for k in range(tab.nmac)]          # last word read on each macro
    st_rb = [rows - 1 - tab.park[k][0] for k in range(tab.nmac)]
    st_b = [5] * tab.nmac                                      # bucket of the state: layer of the last lookup read
    t_free = [0.0] * tab.nmac                                   # end of each macro's last read window
    pend = []                                                   # macros left with a word that has zero bits
    E = {"read": 0.0, "park": 0.0, "static": 0.0, "idle": 0.0}
    by_layer = [0.0] * 5
    by_bucket = [0.0] * 6
    nparks = 0
    idle0 = sm.idle

    def gap(k, t1):
        d = t1 - t_free[k]
        if d <= 0:
            return
        bkt = st_b[k] if sm.ps[st_w[k]] > sm.leak else 5
        if free:
            n = round(d / SLOT_NS)
            e = n * (idle0 + (sm.ps[st_w[k]] - sm.leak) * SLOT_NS * 1e-3)
            E["idle"] += e
        else:
            e = sm.ps[st_w[k]] * d * 1e-3
            E["static"] += e
        by_bucket[bkt] += e

    def do_park(k, t, layer):
        nonlocal nparks
        gap(k, t)
        rp, wp = tab.park[k]
        e = sm.park(rows - 1 - rp, tab.zr[k][rp], st_w[k], st_rb[k])
        E["park"] += e
        by_layer[layer] += e
        st_w[k], st_rb[k], t_free[k], st_b[k] = wp, rows - 1 - rp, t + SLOT_NS, 5
        nparks += 1
        if k in pend:
            pend.remove(k)

    n = len(lk)
    for i, (cyc, layer, e) in enumerate(lk):
        T = cyc * CYCLE_NS
        if free:
            T = math.floor(T / SLOT_NS) * SLOT_NS
        k, r, w = tab.loc(e)
        if T < t_free[k]:
            T = t_free[k]                       # never earlier than the end of the macro's last read
        gap(k, T)
        er = sm.read(rows - 1 - r, tab.zr[k][r], w, st_w[k])
        E["read"] += er
        by_layer[layer] += er
        st_w[k], st_rb[k], t_free[k], st_b[k] = w, rows - 1 - r, T + SLOT_NS, layer
        if k in pend:
            pend.remove(k)
        if zbits(w) and tab.park[k][1] != w:
            pend.append(k)
        if not parking:
            continue
        if i + 1 < n:
            Tn = lk[i + 1][0] * CYCLE_NS
            if free:
                Tn = math.floor(Tn / SLOT_NS) * SLOT_NS
            kn = tab.loc(lk[i + 1][2])[0]
        else:
            Tn, kn = None, None
        if serial:
            slots = len(pend) if Tn is None else max(0, int((Tn - T) // SLOT_NS) - 1)
            order = ([k] if k in pend else []) + [x for x in pend if x != k]
            t = T + SLOT_NS
            for kk in order[:slots]:
                do_park(kk, t, layer)
                t += SLOT_NS
        else:
            # each macro on its own: park macro k right away unless the lane reads it again within 200 ns
            if k in pend and not (kn == k and Tn - T < 2 * SLOT_NS):
                do_park(k, T + SLOT_NS, layer)
    for k in list(pend):                         # the end of the inference: park what is left (parking policies)
        if parking:
            do_park(k, max(t_free[k], lk[-1][0] * CYCLE_NS + SLOT_NS) if lk else t_free[k], 4)
    for k in range(tab.nmac):
        gap(k, max(t_end_ns, t_free[k]))
    return E, by_layer, nparks, by_bucket


def new_acc():
    return {"read": 0.0, "park": 0.0, "static": 0.0, "idle": 0.0, "parks": 0, "by_layer": [0.0] * 5,
            "by_bucket": [0.0] * 6, "lookups": 0}


def add(acc, E, bl, npk, bb, nlk):
    for c in ("read", "park", "static", "idle"):
        acc[c] += E[c]
    acc["parks"] += npk
    acc["lookups"] += nlk
    acc["by_layer"] = [x + y for x, y in zip(acc["by_layer"], bl)]
    acc["by_bucket"] = [x + y for x, y in zip(acc["by_bucket"], bb)]


def tot(r):
    return r["read"] + r["park"] + r["static"] + r["idle"]


# ------------------------------------------------------------------ cells that set the read margin
def cell_stats(words, rows, wpr):
    """two-sided 1 cells (both neighbouring columns are 0 cells in the same row; column = bit x wpr + word) and the
    string of 0 cells directly above them in their column; per table"""
    per = rows * wpr
    ncol = 16 * wpr
    n1 = two = long_ = 0
    za_max = 0
    worst = None
    for k in range(len(words) // per):
        grid = [[(words[k * per + r * wpr + (c % wpr)] >> (15 - c // wpr)) & 1 for c in range(ncol)] for r in range(rows)]
        for r in range(rows):
            g = grid[r]
            for c in range(ncol):
                if g[c] != 1:
                    continue
                n1 += 1
                if not (c > 0 and g[c - 1] == 0 and c < ncol - 1 and g[c + 1] == 0):
                    continue
                two += 1
                za, rr = 0, r - 1
                while rr >= 0 and grid[rr][c] == 0:
                    za += 1
                    rr -= 1
                long_ += za >= LONG_ZERO_STRING
                if za > za_max:
                    za_max, worst = za, (k, r, c)
    return {"ones": n1, "two_sided": two, "share": two / n1 if n1 else 0.0, "max_zeros_above": za_max,
            "long": long_, "worst": worst}


# ------------------------------------------------------------------ validation-based uncertainty
def validation_errors(model, lk_counts):
    """per side and form: per-table errors of the parking mix (conv1, conv2 with parking, fc1), weighted by the lane's
    ROM reads of each layer x the measured energy per lookup; mean, SD, SE"""
    out = {}
    by = {}
    for v in model.get("validation", []):
        by.setdefault(v["table"], {})[(v["train"], v["park"] is not None)] = v
    for form in ("bits", "count"):
        for side in ("pcm", "sram"):
            errs, used = [], []
            for t, d in sorted(by.items()):
                if f"_{side}_" not in t:
                    continue
                parts = []
                for tr in ("conv1", "conv2", "fc1"):
                    rec = d.get((tr, True)) or (d.get((tr, False)) if tr != "conv2" else None)
                    if rec is None or f"model_{form}_pJ" not in rec:
                        break
                    parts.append((tr, rec))
                if len(parts) != 3:
                    continue
                lane = int(t.split("_l")[1][:2])
                model_ = t.split("_")[1]
                cnt = lk_counts.get((model_, lane), {"conv1": 4704, "conv2": 9600, "fc1": 1920})
                num = den = 0.0
                for tr, rec in parts:
                    w = cnt[tr] * rec["measured_pJ"] / rec["segments"]
                    num += w * (rec[f"model_{form}_pJ"] / rec["measured_pJ"] - 1)
                    den += w
                errs.append(num / den)
                used.append(t)
            if len(errs) >= 2:
                m, sd = statistics.mean(errs), statistics.stdev(errs)
                out[(form, side)] = {"tables": used, "errors": errs, "mean": m, "sd": sd, "se": sd / math.sqrt(len(errs))}
    return out


# ------------------------------------------------------------------ check: trains from table contents vs records
def check_trains(paper2, model, models_by_form, rows, wpr):
    """replay every E8.4b train two ways with the all-table model: (1) from the measured records in model.json with
    e8_4b_energy_tools.segments/predict_segment, (2) from the table contents and the plan (this script's formulas);
    the sums over segments 2 to the end must agree"""
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, here)
    try:
        import e8_4b_energy_tools as T4
    except ImportError:
        print("   (scripts/e8_4b_energy_tools.py not found: train check skipped)")
        return None
    reads = model.get("reads", [])
    waits = model.get("waits", [])
    runs = {}
    for rec in reads:
        runs.setdefault(rec["run"], []).append(("read", rec))
    for rec in waits:
        runs.setdefault(rec["run"], []).append(("wait", rec))
    res = []
    for v in model.get("validation", []):
        cyc = sorted(runs.get(v["run"], []), key=lambda kr: kr[1]["i"])
        run = {"cycles": cyc}
        segs = T4.segments(run)[1:]
        plan_p = os.path.join(paper2, "reports", "e8_rom", "e8_4b", v["table"], "plan.json")
        try:
            plan = json.load(open(plan_p))
        except (OSError, ValueError):
            continue
        tr = plan["trains"].get(v["train"])
        if tr is None:
            continue
        mac = plan["macros"][tr["macro"]]
        for form in ("bits", "count"):
            m = models_by_form[form].get(v["side"])
            ms = model["models"].get(v["side"])
            if m is None or ms is None:
                continue
            a = sum(T4.predict_segment(sg, ms, form) or float("nan") for sg in segs)
            # (2) from the plan: the same sequence as e8_4b_energy_tools.train_seq; waits at the fitted static power
            park = v["park"]
            prow = pz_row = None
            if park is not None:
                pinfo = mac["Pd"] if mac["Pd"]["addr"] == park else (mac["Ps"] if mac["Ps"]["addr"] == park else None)
                if pinfo is None:
                    continue
                prow, pz_row = pinfo["row"], pinfo["z_row"]
            seg_e = []
            w_before = None
            nlk = len(tr["lookups"])
            for j, x in enumerate(tr["lookups"]):
                w = int(x["value"], 16)
                rb, zr = rows - 1 - x["row"], x["z_row"]
                e = 0.0
                wb = MISS if w_before is None else w_before
                e += m.read(rb, zr, w, wb)
                parked = park is not None and x["z"] > 0 and (j == nlk - 1 or x["gap_cycles"] * CYCLE_NS >= 2 * SLOT_NS)
                state = w
                if parked:
                    e += m.park(rows - 1 - prow, pz_row, w, rb)
                    state = MISS
                rest = 1000.0 if j == nlk - 1 else x["gap_cycles"] * CYCLE_NS - (2 if parked else 1) * SLOT_NS
                e += m.pm[state] * rest * 1e-3        # the fitted static power, as predict_segment (a code check)
                seg_e.append(e)
                w_before = state
            b = sum(seg_e[1:])
            res.append({"run": v["run"], "form": form, "records_pJ": a, "table_pJ": b, "measured_pJ": v["measured_pJ"]})
    return res


# ------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--paper2", required=True)
    ap.add_argument("--model-json", default=None, help="default: reports/e8_rom/e8_4b/model.json")
    ap.add_argument("--rows", type=int, default=48)
    ap.add_argument("--wpr", type=int, default=13)
    ap.add_argument("--table-words", type=int, default=2496)
    ap.add_argument("--lanes", type=int, default=K)
    ap.add_argument("--out", default=None, help="default: reports/e8_rom/e8_6a2/d_rom.json")
    a = ap.parse_args()
    t0 = time.time()
    root = os.path.join(a.paper2, "reports", "e8_rom")
    mj = a.model_json or os.path.join(root, "e8_4b", "model.json")
    model = json.load(open(mj))
    here_f = os.path.abspath(__file__)
    print(f"P2R-E8.6a-2  {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"   script     : {md5(here_f)}  {here_f}")
    t4 = os.path.join(os.path.dirname(here_f), "e8_4b_energy_tools.py")
    if os.path.isfile(t4):
        print(f"   tools      : {md5(t4)}  {t4}")
    print(f"   E8.4b model: {md5(mj)}  {mj}")
    for M in ("A", "B"):
        tp = os.path.join(root, "trace", f"trace_{M}.txt")
        if os.path.isfile(tp):
            print(f"   trace      : {md5(tp)}  {tp}")
    if model.get("rows") != a.rows:
        print(f"   WARNING: the model was fitted on {model.get('rows')}-row macros; this run uses {a.rows} rows")
    sides = sorted(model["models"])
    leak, idle, choice = {}, {}, {}
    for side in sides:
        lm = [p["leak_mean_uW"] for p in model["parta"] if p["side"] == side and p["leak_mean_uW"] < 10.0]
        leak[side] = statistics.mean(lm)
        idle[side] = model["models"][side]["idle_parked_pJ"]
        print(f"   {side}: parked power {leak[side]:.3f} uW (mean of {len(lm)} macros), idle cycle when parked "
              f"{idle[side]:.3f} pJ; model tables: {len(model['models'][side]['tables'])}")
    for r in model["runs"]:
        if r["kind"] == "parta" and r.get("park_choice"):
            tok = r["park_choice"].split()[0]
            choice.setdefault(r["table"], {})[r["k"]] = int(tok) if tok.isdigit() else None
    forms = {f: {s: SideModel(model["models"][s], f, leak[s], idle[s]) for s in sides} for f in ("bits", "count")}
    o1 = {s: SideModel(model["models"][s], "bits", leak[s], idle[s], no_static=True) for s in sides}

    here = os.path.dirname(here_f)
    sys.path.insert(0, here)
    try:
        import e8_4b_energy_tools as T4
        dif = 0.0
        for s in sides:
            ms = model["models"][s]
            for w, wb in ((0x0000, 0xFFFF), (0x027F, 0x0C08), (0x8480, 0x0000), (0xFFFF, 0x1234)):
                r = {"rows_below": 20, "z_row": 50, "z": zbits(w), "zv": zvec(w), "z_before": zbits(wb), "zv_before": zvec(wb)}
                for f in ("bits", "count"):
                    x1 = sum(c * x for c, x in zip(ms["read_bits" if f == "bits" else "read"]["coef"],
                                                   T4.read_x(r, ms) if f == "bits" else T4.read_x(r)))
                    dif = max(dif, abs(x1 - forms[f][s].read(20, 50, w, wb)))
        print(f"   formula check against e8_4b_energy_tools (read windows): largest difference {dif:.2e} pJ")
    except ImportError:
        print("   (e8_4b_energy_tools.py not next to this script: formula check skipped)")

    out = {"model_json": os.path.abspath(mj), "model_json_md5": md5(mj), "script_md5": md5(here_f), "leak_uW": leak,
           "idle_pJ": idle, "variants": dict(VARIANTS), "models": {}, "cells": {}}
    lk_counts = {"all": {}, "R": {}}
    traces = {}
    for M in ("A", "B"):
        tp = os.path.join(root, "trace", f"trace_{M}.txt")
        lk, done, ops, shared = parse_trace(tp)
        lkr = [skip_repeats(x) for x in lk]
        traces[M] = ({"all": lk, "R": lkr}, done)
        n = sum(len(x) for x in lk[:a.lanes])
        nr = sum(len(x) for x in lkr[:a.lanes])
        print(f"\ntrace {M}: {ops} operations, done at cycle {done} ({done * CYCLE_NS / 1e6:.3f} ms); "
              f"{n} lookups per side over {a.lanes} lanes ({2 * n} ROM lookups)")
        per_layer = [sum(1 for x in lk[lane] if x[1] == i) for lane in range(a.lanes) for i in range(5)]
        per_layer_r = [sum(1 for x in lkr[lane] if x[1] == i) for lane in range(a.lanes) for i in range(5)]
        print("   ROM reads per side, all lanes, by layer: all lookups " +
              ", ".join(f"{LAYERS[i]} {sum(per_layer[i::5])}" for i in range(5)) + "; with R " +
              ", ".join(f"{LAYERS[i]} {sum(per_layer_r[i::5])}" for i in range(5)) +
              f" -> {nr} per side ({2 * nr} ROM reads, {100 * (1 - nr / n):.1f} % fewer)")
        print("   shared entry (operations by layer: all, with lanes on different entries, without a lookup; lanes looking "
              "up): " + ", ".join(f"{LAYERS[i]} {shared['ops'][i]} / {shared['mixed'][i]} / {shared['none'][i]}; "
                                  f"{shared['lanes'][i]}" for i in range(5)))
        print(f"   -> operations whose looking-up lanes use different entries: {sum(shared['mixed'])} of {ops}"
              + (" (every operation reads one entry in all its tables)" if sum(shared["mixed"]) == 0 else ""))
        out["shared_entry"] = out.get("shared_entry", {})
        out["shared_entry"][M] = shared
        for lane in range(K):
            lk_counts["all"][(M, lane)] = {LAYERS[i]: sum(1 for x in lk[lane] if x[1] == i) for i in range(5)}
            lk_counts["R"][(M, lane)] = {LAYERS[i]: sum(1 for x in lkr[lane] if x[1] == i) for i in range(5)}

    print("\ntables rebuilt from data/rtl_inputs_<model>_v3 (as E8.3), compared with reports/e8_rom/bins:")
    same = differ = 0
    for M in ("A", "B"):
        for side in ("sram", "pcm"):
            for lane in (0, 12, 24):
                b = os.path.join(root, "bins", f"e8rom_{M}_{side}_l{lane:02d}_16x{a.table_words}.bin")
                if not os.path.isfile(b):
                    continue
                w = table_words(a.paper2, M, side, lane, a.table_words)
                d = bytes(x for v in w for x in ((v >> 8) & 0xFF, v & 0xFF))
                if d == open(b, "rb").read():
                    same += 1
                else:
                    differ += 1
                    print(f"   DIFFERENT: {os.path.basename(b)}")
    print(f"   {same} equal, {differ} different")

    errs = {}
    for var, txt in VARIANTS:
        errs[var] = validation_errors(model, lk_counts[var])
        print(f"\nmodel error of the parking trains per table, {txt} (E8.4b, leave one table out; conv1, conv2, fc1 "
              f"weighted by the lane's ROM reads x measured energy per lookup):")
        for (form, side), e in sorted(errs[var].items()):
            print(f"   {form:<5} {side:<4}: " + " ".join(f"{100 * x:+.1f}" for x in e["errors"]) +
                  f" %  -> mean {100 * e['mean']:+.1f} %, SE {100 * e['se']:.1f} % ({len(e['errors'])} tables)")

    for M in ("A", "B"):
        lks, done = traces[M]
        t_end = done * CYCLE_NS
        res = {}
        nopark_macros = []
        per_table = {}
        sens = {var: [0.0, 0.0] for var, _ in VARIANTS}       # GPp bits: tables with a macro without 0xFFFF
        cells_cur = {}
        for side in ("sram", "pcm"):
            if side not in sides:
                continue
            for lane in range(a.lanes):
                name = f"e8rom_{M}_{side}_l{lane:02d}_16x{a.table_words}"
                words = table_words(a.paper2, M, side, lane, a.table_words)
                tab = Table(words, a.rows, a.wpr, choice.get(name))
                cells_cur[name] = cell_stats(words, a.rows, a.wpr)
                lacking = [k for k in range(tab.nmac) if tab.park_src[k] == "no word without zero bits"]
                nopark_macros += [f"{name} k{k}" for k in lacking]
                tab_low = Table(words, a.rows, a.wpr, choice.get(name), fallback=lambda x, s=side: forms["bits"][s].pm[x]) \
                    if lacking else None
                for var, _ in VARIANTS:
                    lk = lks[var][lane]
                    for form in ("bits", "count"):
                        for pol in POLICIES:
                            E, bl, npk, bb = simulate(tab, lk, forms[form][side], pol, t_end)
                            add(res.setdefault((var, form, pol, side), new_acc()), E, bl, npk, bb, len(lk))
                            if form == "bits" and pol == "GPp":
                                per_table.setdefault(var, {})[name] = tot(E)
                                if tab_low is not None:
                                    E2, _, _, _ = simulate(tab_low, lk, forms[form][side], pol, t_end)
                                    sens[var][0] += tot(E)
                                    sens[var][1] += tot(E2)
                    E, bl, npk, bb = simulate(tab, lk, o1[side], "GN", t_end)
                    add(res.setdefault((var, "bits", "O1", side), new_acc()), E, bl, npk, bb, len(lk))
        # merged tables (O2, O3): both side models in turn
        conflicts = added = 0
        cells_mrg = {}
        for lane in range(a.lanes):
            ws = table_words(a.paper2, M, "sram", lane, a.table_words)
            wp = table_words(a.paper2, M, "pcm", lane, a.table_words)
            mw = []
            for s_, p_ in zip(ws, wp):
                if s_ != MISS and p_ != MISS:
                    conflicts += 1
                mw.append(s_ if s_ != MISS else (SRAM_SLOTS + p_ if p_ != MISS else MISS))
            cells_mrg[f"merged_{M}_l{lane:02d}"] = cell_stats(mw, a.rows, a.wpr)
            tab = Table(mw, a.rows, a.wpr, virtual_park=True)
            added += sum(1 for x in tab.park_src if x == "added (estimate)")
            for var, _ in VARIANTS:
                lk = lks[var][lane]
                for key, sm, pol in [(("bits", f"O2_{s}", "merged"), forms["bits"][s], "GPp") for s in sides] + \
                                    [(("bits", f"O3_{s}", "merged"), o1[s], "GN") for s in sides]:
                    E, bl, npk, bb = simulate(tab, lk, sm, pol, t_end)
                    add(res.setdefault((var,) + key, new_acc()), E, bl, npk, bb, len(lk))

        mres = {}
        for var, vtxt in VARIANTS:
            nl = sum(len(x) for x in lks[var][:a.lanes])
            print(f"\n==== model {M}, {vtxt}: D_ROM per inference ({a.lanes} lanes; {t_end / 1e6:.3f} ms; "
                  f"4 macros per table) ====")
            print(f"   pJ/read: per ROM read ({2 * nl} = {nl} per side); static: clock low; idle: free-running cycles "
                  f"without a read")
            print(f"   {'way of running':<36} {'form':<5} {'D uJ':>7} {'x 9.85':>6} | {'reads':>6} {'parks':>6} {'static':>7} "
                  f"{'idle':>6} uJ | {'parks':>7} {'pJ/read':>8}")
            vres = {}
            for pol in POLICIES:
                for form in ("bits", "count"):
                    r = {c: sum(res[(var, form, pol, s)][c] for s in sides) for c in ("read", "park", "static", "idle",
                                                                                    "parks", "lookups")}
                    D = tot(r) * 1e-6
                    vres[f"{pol}_{form}"] = dict(r, D_uJ=D, by_side={s: tot(res[(var, form, pol, s)]) * 1e-6 for s in sides})
                    print(f"   {pol + ' ' + POLICY_TEXT[pol]:<36} {form:<5} {D:7.2f} {D / MANUSCRIPT_D_UJ:6.2f} | "
                          f"{r['read'] * 1e-6:6.2f} {r['park'] * 1e-6:6.2f} {r['static'] * 1e-6:7.2f} {r['idle'] * 1e-6:6.2f}"
                          f"    | {r['parks']:7d} {tot(r) / r['lookups']:8.1f}")
            for pol in ("GPp", "GPs"):
                for form in ("bits", "count"):
                    lo = hi = 0.0
                    ok = True
                    for s in sides:
                        e = errs[var].get((form, s))
                        if e is None:
                            ok = False
                            break
                        Ds = vres[f"{pol}_{form}"]["by_side"][s]
                        lo += Ds / (1 + e["mean"] + 2 * e["se"])
                        hi += Ds / (1 + e["mean"] - 2 * e["se"])
                    if ok:
                        vres[f"{pol}_{form}"]["range_uJ"] = [lo, hi]
                        print(f"   {pol} {form}: D {vres[pol + '_' + form]['D_uJ']:.2f} uJ, range from the E8.4b trains "
                              f"(mean +- 2 SE per side) {lo:.2f}-{hi:.2f} uJ")
            b = vres["GPp_bits"]
            print("   GPp, bits: by side " + ", ".join(f"{s} {v:.2f} uJ" for s, v in b["by_side"].items()))
            bl = [sum(res[(var, "bits", "GPp", s)]["by_layer"][i] for s in sides) for i in range(5)]
            bb = [sum(res[(var, "bits", "GPp", s)]["by_bucket"][i] for s in sides) for i in range(6)]
            print("   GPp, bits, by layer (reads + parks + static above the parked level; uJ): " +
                  ", ".join(f"{LAYERS[i]} {(bl[i] + bb[i]) * 1e-6:.2f} ({bl[i] * 1e-6:.2f} + {bb[i] * 1e-6:.2f})"
                            for i in range(5)) + f"; parked level (leakage) {bb[5] * 1e-6:.2f}")
            vres["GPp_bits"]["by_layer_uJ"] = {LAYERS[i]: (bl[i] + bb[i]) * 1e-6 for i in range(5)}
            vres["GPp_bits"]["by_layer_uJ"]["parked"] = bb[5] * 1e-6
            if sens[var][0]:
                d_low = b["D_uJ"] + (sens[var][1] - sens[var][0]) * 1e-6
                print(f"   macros without a word of 0xFFFF ({len(nopark_macros)}: {', '.join(nopark_macros)}): their tables "
                      f"{sens[var][0] * 1e-6:.2f} uJ when parked with the word of fewest zero bits, "
                      f"{sens[var][1] * 1e-6:.2f} uJ with the word of the lowest static power of the model (GPp, bits; "
                      f"D {d_low:.2f} uJ)")
                vres["GPp_bits"]["lowest_static_parking_D_uJ"] = d_low
            print("   GN, FN: the static current flows for milliseconds; its rise (measured to 20 us only) is not included")
            print("   design options (estimates from the same models in the bits form, not simulated; the energy of added "
                  "devices or logic not included):")
            o = {}
            opts = [(("bits", "O1"), "O1 no static current after a read, no parking")]
            for s in sides:
                opts.append((("bits", f"O2_{s}"), f"O2 merged tables, parking (GPp), {s.upper()}-side model"))
            for s in sides:
                opts.append((("bits", f"O3_{s}"), f"O3 merged tables, no static current, {s.upper()}-side model"))
            for key, txt in opts:
                ss = ["merged"] if key[1] != "O1" else sides
                r = {c: sum(res[(var,) + key + (s,)][c] for s in ss) for c in ("read", "park", "static", "idle", "parks",
                                                                               "lookups")}
                D = tot(r) * 1e-6
                o[key[1]] = dict(r, D_uJ=D)
                print(f"      {txt:<56} {D:7.2f} uJ ({D / b['D_uJ']:.2f} x GPp; {D / MANUSCRIPT_D_UJ:.2f} x 9.85): reads "
                      f"{r['read'] * 1e-6:.2f}, parks {r['park'] * 1e-6:.2f}, static {r['static'] * 1e-6:.2f} uJ; "
                      f"{r['parks']} parks; {r['lookups']} ROM reads, {tot(r) / r['lookups']:.1f} pJ each")
            if added:
                print(f"      (merged tables: {added} macros have no word of 0xFFFF; a reserved word 0xFFFF was assumed in "
                      f"the row of the Pd rule)")
            if conflicts:
                print(f"      WARNING: {conflicts} entries hold a slot on both sides; the merged table took the SRAM slot")
            vres["options"] = o
            vres["per_table_GPp_bits_uJ"] = {k: v * 1e-6 for k, v in per_table[var].items()}
            mres[var] = vres
        mres["no_parking_word_macros"] = nopark_macros
        out["models"][M] = mres

        # cells that set the read margin: current tables against merged tables
        print(f"\n   model {M}: two-sided 1 cells (both neighbouring columns discharge) and 0 cells directly above them "
              f"(indicators of the read margin, not margins; E8.4a-7's lowest cell, A_pcm_l00 k3 row 43 col 12, has 32):")
        groups = [("SRAM-side tables", {k: v for k, v in cells_cur.items() if "_sram_" in k}),
                  ("PCM-side tables", {k: v for k, v in cells_cur.items() if "_pcm_" in k}),
                  ("merged tables", cells_mrg)]
        for gname, g in groups:
            if not g:
                continue
            sh = [v["share"] for v in g.values()]
            zm = max(g.items(), key=lambda kv: kv[1]["max_zeros_above"])
            nl_ = [v["long"] for v in g.values()]
            print(f"      {gname:<17}: two-sided share {100 * min(sh):.1f}-{100 * max(sh):.1f} % (median "
                  f"{100 * statistics.median(sh):.1f} %); longest string of 0 cells above a two-sided cell "
                  f"{zm[1]['max_zeros_above']} ({zm[0]} k{zm[1]['worst'][0]} row {zm[1]['worst'][1]} col "
                  f"{zm[1]['worst'][2]}); two-sided cells with >= {LONG_ZERO_STRING} above: {sum(nl_)} in "
                  f"{sum(1 for x in nl_ if x)} of {len(g)} tables")
        for nm in (f"e8rom_{M}_pcm_l00_16x{a.table_words}", f"e8rom_{M}_pcm_l12_16x{a.table_words}",
                   f"e8rom_{M}_pcm_l24_16x{a.table_words}", f"e8rom_{M}_sram_l00_16x{a.table_words}"):
            if nm in cells_cur:
                v = cells_cur[nm]
                print(f"      {nm}: two-sided {100 * v['share']:.1f} %, longest {v['max_zeros_above']}, >= "
                      f"{LONG_ZERO_STRING}: {v['long']}")
        out["cells"][M] = {"current": cells_cur, "merged": cells_mrg}

    print("\ncheck: E8.4b trains, segments 2 to the end, the all-table model applied two ways:")
    chk = check_trains(a.paper2, model, forms, model.get("rows", a.rows), a.wpr)
    if chk:
        worst = max(abs(c["table_pJ"] / c["records_pJ"] - 1) for c in chk if c["records_pJ"] == c["records_pJ"])
        print(f"   {len(chk)} train x form: largest difference between the two {100 * worst:.3f} % (must be 0: the same "
              f"model and sequence; a difference means the tables or plans differ from the records)")
        for form in ("bits", "count"):
            cc = [c for c in chk if c["form"] == form]
            if cc:
                e = [c["table_pJ"] / c["measured_pJ"] - 1 for c in cc]
                print(f"   {form}: against the measured trains (in-sample) median |error| "
                      f"{100 * statistics.median(abs(x) for x in e):.1f} %, all together "
                      f"{100 * (sum(c['table_pJ'] for c in cc) / sum(c['measured_pJ'] for c in cc) - 1):+.2f} %")
        out["train_check"] = chk

    print("\nsummary (D_ROM per inference, uJ; manuscript 9.85):")
    for M in ("A", "B"):
        for var, _ in VARIANTS:
            r = out["models"][M][var]
            line = []
            for pol in ("GPp", "GPs"):
                x = r[f"{pol}_bits"]
                rg = x.get("range_uJ")
                line.append(f"{pol} {x['D_uJ']:.2f}" + (f" ({rg[0]:.2f}-{rg[1]:.2f})" if rg else "") +
                            f" / count {r[pol + '_count']['D_uJ']:.2f}")
            line.append("GN " + f"{r['GN_bits']['D_uJ']:.1f}")
            line.append("options " + ", ".join(f"{k} {v['D_uJ']:.2f}" for k, v in r["options"].items()))
            print(f"   model {M}, {var:<3}: " + "; ".join(line))
    od = a.out or os.path.join(root, "e8_6a2", "d_rom.json")
    os.makedirs(os.path.dirname(od), exist_ok=True)
    json.dump(out, open(od, "w"), indent=1)
    print(f"\nwritten: {od}  ({time.time() - t0:.0f} s)")


if __name__ == "__main__":
    main()
