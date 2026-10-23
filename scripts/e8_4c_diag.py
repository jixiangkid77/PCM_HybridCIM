#!/usr/bin/env python3
"""
e8_4c_diag.py  (diagnosis of an E8.4c run of the 4-KB SRAM macro; reads <run>/tb_out.txt, tb_meta.json, result.json)

For every read: when the precharge enable (p_en_bar low), the wordline enable and the sense-amplifier enable
(s_en) switch, relative to the rising clock edge of the read; the two sense-amplifier inputs of every data bit
(the column-mux side, bl_k and br_k) when the wordline enable rises (start of the read), at their highest
during the precharge of this cycle, and when s_en rises; the sign of bl_k - br_k at s_en against the
expected bit; the output at the end.

Usage: python3 scripts/e8_4c_diag.py RUN_FOLDER [OUT_JSON]
The waveforms (tb_out.txt) of the analyzed runs are not in the repository;
reports/e8_rom/e8_4c_resume2_diag/ holds the output for the r10 and r20 runs of
reports/e8_4c_sram_char_resume2.log (the 4-KB macro before the sense-input
precharge was added), and scripts/e8_4c_diag_summary.py summarizes it.
"""
import json
import os
import re
import sys

import numpy as np


def nbits(col):
    return len([n for n in col if re.search(r'sense_amp_array_0__bl_\d+\)$', n)])


def load(d):
    meta = json.load(open(os.path.join(d, "tb_meta.json")))
    res = json.load(open(os.path.join(d, "result.json")))
    with open(os.path.join(d, "tb_out.txt")) as fh:
        head = fh.readline().split()
        data = np.loadtxt(fh)
    col = {n: i for i, n in enumerate(head)}
    return meta, res, data, col


def find(col, suffix):
    hits = [n for n in col if n.endswith(suffix + ")")]
    if len(hits) != 1:
        raise SystemExit(f"node ending with {suffix}: {hits}")
    return hits[0]


def cross(t, v, thr, t0, t1, rising=True):
    """first crossing of thr in [t0, t1] (linear interpolation); None if none"""
    m = (t >= t0) & (t <= t1)
    idx = np.nonzero(m)[0]
    if len(idx) < 2:
        return None
    for i in idx[:-1]:
        a, b = v[i], v[i + 1]
        if (rising and a < thr <= b) or ((not rising) and a > thr >= b):
            return t[i] + (thr - a) * (t[i + 1] - t[i]) / (b - a)
    return None


def at(t, v, x):
    return float(np.interp(x, t, v))


def main():
    d = sys.argv[1]
    meta, res, data, col = load(d)
    NBITS = nbits(col)
    t = data[:, col["time"]]
    vdd = 1.8
    T = meta["period_ns"] * 1e-9
    pen = data[:, col[find(col, "__p_en_bar0")]]
    wle = data[:, col[find(col, "__wl_en0")]]
    sen = data[:, col[find(col, "__s_en0")]]
    rbl = data[:, col[find(col, "__rbl_bl_0_0")]]
    bl = [data[:, col[find(col, f"sense_amp_array_0__bl_{k}")]] for k in range(NBITS)]
    br = [data[:, col[find(col, f"sense_amp_array_0__br_{k}")]] for k in range(NBITS)]
    dout = [data[:, col[f"v(d{k})"]] for k in range(NBITS)]
    print(f"run {d}: period {T*1e9:.1f} ns, {len(t)} points, last {t[-1]*1e9:.1f} ns, "
          f"median step {np.median(np.diff(t))*1e12:.0f} ps, max step {np.max(np.diff(t))*1e12:.0f} ps")
    cyc = meta["cycles"]
    rows = []
    for i, c in enumerate(cyc):
        if c["kind"] != "read":
            continue
        t0 = c["trise"]
        nxt = cyc[i + 1] if i + 1 < len(cyc) else None
        tend = nxt["tend"] if (nxt and nxt["kind"] == "stop") else c["tend"]
        # precharge window of this cycle: p_en_bar below VDD/2
        p_on = cross(t, pen, vdd / 2, t0, t0 + T, rising=False)
        p_off = cross(t, pen, vdd / 2, (p_on or t0), t0 + T, rising=True) if p_on else None
        w_on = cross(t, wle, vdd / 2, t0, tend, rising=True)
        s_on = cross(t, sen, vdd / 2, t0, tend, rising=True)
        exp = c["expected"]
        r = {"k": c["k"], "addr": c["addr"], "exp": exp,
             "p_on": None if p_on is None else (p_on - t0) * 1e9, "p_off": None if p_off is None else (p_off - t0) * 1e9,
             "wl_en": None if w_on is None else (w_on - t0) * 1e9, "s_en": None if s_on is None else (s_on - t0) * 1e9,
             "rbl_at_sen": None if s_on is None else at(t, rbl, s_on)}
        bits = []
        for k in range(NBITS):
            e = (exp >> k) & 1
            b0 = at(t, bl[k], w_on) if w_on else None
            r0 = at(t, br[k], w_on) if w_on else None
            if p_on and p_off:
                m = (t >= p_on) & (t <= p_off)
                bmax = float(bl[k][m].max()) if m.any() else None
                rmax = float(br[k][m].max()) if m.any() else None
            else:
                bmax = rmax = None
            bs = at(t, bl[k], s_on) if s_on else None
            rs = at(t, br[k], s_on) if s_on else None
            out = at(t, dout[k], tend - 0.02e-9)
            bits.append({"bit": k, "exp": e, "bl_wl": b0, "br_wl": r0, "bl_pmax": bmax, "br_pmax": rmax,
                         "bl_sen": bs, "br_sen": rs, "diff_sen": None if bs is None else bs - rs,
                         "out_end": int(out > vdd / 2)})
        r["bits"] = bits
        rows.append(r)
    # convention: in reads that came out right, does bit 1 mean bl > br at s_en?
    agree = disagree = 0
    for r in rows:
        for b in r["bits"]:
            if b["diff_sen"] is None:
                continue
            if b["out_end"] == b["exp"]:
                if (b["diff_sen"] > 0) == (b["exp"] == 1):
                    agree += 1
                else:
                    disagree += 1
    print(f"convention check on correct bits: bit 1 <-> bl > br at s_en: {agree} agree, {disagree} disagree")
    for r in rows:
        f = lambda x: "  -  " if x is None else f"{x:5.2f}"
        print(f"k{r['k']:>3} addr {r['addr']:>5} exp {r['exp']:02x}  precharge {f(r['p_on'])}-{f(r['p_off'])} ns  "
              f"wl_en {f(r['wl_en'])}  s_en {f(r['s_en'])}  rbl@s_en {f(r['rbl_at_sen'])} V")
        for b in r["bits"]:
            ok = "ok " if b["out_end"] == b["exp"] else "BAD"
            dirn = "-" if b["diff_sen"] is None else ("right" if (b["diff_sen"] > 0) == (b["exp"] == 1) else "WRONG")
            print(f"      bit {b['bit']} exp {b['exp']} out {b['out_end']} {ok}  start bl/br {f(b['bl_wl'])}/{f(b['br_wl'])}  "
                  f"precharge max {f(b['bl_pmax'])}/{f(b['br_pmax'])}  at s_en {f(b['bl_sen'])}/{f(b['br_sen'])} "
                  f"diff {f(b['diff_sen'])} ({dirn})")
    if len(sys.argv) > 2:
        json.dump(rows, open(sys.argv[2], "w"), indent=1)


if __name__ == "__main__":
    main()
