#!/usr/bin/env python3
"""
e8_4d_rom_mc.py   (P2R-E8.4d: local-mismatch Monte Carlo of the address-map ROM read margin)

The read margin of E8.4a (rule of E8.4a-6): the lowest bitline of the read row's one cells while the array evaluates
minus the switching level of the bitline inverter must be >= 0.10 V; the highest zero-cell bitline at the sampling
time must be <= the switching level - 0.10 V. E8.4a-10 found the lowest margins of all simulated macros on two
macros (B_pcm_l01 k0, B_pcm_l07 k1). This script repeats their worst reads with local mismatch:

  - the PDK's own mismatch sections of sky130.lib.spice (tt_mm, fs_mm: mc_mm_switch=1): every transistor of the
    macro gets its own Gaussian variation of vth0, toxe and voff (the PDK's slopes over sqrt(W L)); one sample =
    one ngspice run with ".options seed=<n>";
  - each sample measures the switching level of every column's bitline inverter in the same run, with the same
    random values: after the transient a switch (1e12 ohm while the transient runs) from every bitline to a common
    node closes and a DC sweep of that node gives each inverter's output against its input.

Subcommands
  sites    --bench F --work DIR --out DIR [--tables SPEC] [--conds C ...] [--wait NS]
           the worst read of each macro at each condition, from the E8.4a-10 runs -> OUT/sites.json
  prepare  --bench F --models F --out DIR --site NAME [--reltol X] [--tmax NS] [--span V] [--step V]
           the deck of a site: the bench of E8.4a-10 (same options), the switches, the DC sweep -> OUT/NAME/base/
  samples  --out DIR --site NAME --n N [--repeat K]
           the sample decks: s0000 nominal section; s0001..sN mismatch section, seed = 100000 (site index + 1) + k;
           r0001..rK repeat the first K mismatch samples (the same seed must give the same numbers)
  analyze  --bench F --out DIR [--margin V] [--json F] [--keep-waves]
           every finished sample: reads, margins with its own switching levels; per site and overall: the gates and
           the verdict written in claude/p2r-e8-4d-sandbox.md
"""
import argparse
import gzip
import hashlib
import importlib.util
import json
import math
import os
import re
import shutil
import subprocess
import sys

TABLES_DEFAULT = "B_pcm01=e8rom_B_pcm_l01_16x2496:e8rom_B_pcm_l01_16x2496_r48k0," \
                 "B_pcm07=e8rom_B_pcm_l07_16x2496:e8rom_B_pcm_l07_16x2496_r48k1"
CONDS_DEFAULT = ["tt:25:1.80", "fs:25:1.80", "tt:25:1.60", "fs:-40:1.60"]
OUTPUT_EXEMPT = {"fs:-40:1.60"}       # E8.4a-6 onwards: only the bitlines are judged at this condition
INV_P = (5.0, 0.15)                   # bitline inverter of the generator (pinv_dec_3): PMOS W, L (um)
INV_N = (1.68, 0.15)                  # NMOS W, L
SEED_BASE = 100000


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def load_bench(path):
    spec = importlib.util.spec_from_file_location("e8_4_rom_bench", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def corner_tag(c):
    s, t, v = c.split(":")
    return f"{s}_{t.replace('-', 'm')}C_{v.replace('.', 'v')}"


def site_name(short, c):
    return f"{short}_{corner_tag(c)}"


def wjson(path, obj):
    tmp = path + ".part"
    with open(tmp, "w") as fh:
        json.dump(obj, fh, indent=1)
    os.replace(tmp, path)


def fmt(x, n=3):
    return "-" if x is None else f"{x:.{n}f}"


# --------------------------------------------------------------------------
# sites
# --------------------------------------------------------------------------
def read_vm_file(path):
    out = {}
    if os.path.isfile(path):
        for line in open(path):
            t = line.split()
            if len(t) >= 2:
                try:
                    out[t[0]] = float(t[1])
                except ValueError:
                    pass
    return out


def run_result(bench, run_dir, out_json):
    """the run's analysis: its result.json if present (E8.4a-10's own), else analyzed again into out_json"""
    rj = os.path.join(run_dir, "result.json")
    if os.path.isfile(rj):
        return json.load(open(rj)), "result.json of the run"
    if not os.path.isfile(os.path.join(run_dir, "tb_out.txt")):
        return None, "no result.json and no waveforms"
    r = subprocess.run([sys.executable, bench, "analyze", "--dir", run_dir, "--json-out", out_json],
                       capture_output=True, text=True)
    if r.returncode != 0 or not os.path.isfile(out_json):
        return None, "analyze failed: " + (r.stderr or r.stdout)[-300:]
    return json.load(open(out_json)), "analyzed again (bench analyze --json-out)"


def cmd_sites(a):
    os.makedirs(a.out, exist_ok=True)
    vmfile = os.path.join(a.work, "vm", "vm.txt")
    vms = read_vm_file(vmfile)
    sites, errors = [], []
    tables = [x for x in a.tables.split(",") if x]
    for ti, spec in enumerate(tables):
        short, rest = spec.split("=")
        table, macro = rest.split(":")
        wm = os.path.join(a.work, table, "worst_macro")
        got = open(wm).read().strip() if os.path.isfile(wm) else None
        if got != macro:
            errors.append(f"{table}: worst_macro is {got!r}, expected {macro} (E8.4a-10 results)")
            continue
        sp = os.path.join(a.work, macro, "extract", f"{macro}.flat_pex.spice")
        binf = os.path.join(a.work, "bins", f"{macro}.bin")
        lvs = os.path.join(a.work, macro, "lvs", "netgen.log")
        for f in (sp, binf):
            if not os.path.isfile(f):
                errors.append(f"{macro}: missing {f}")
        lvs_ok = os.path.isfile(lvs) and "match uniquely" in open(lvs, errors="replace").read()
        if not lvs_ok:
            errors.append(f"{macro}: {lvs} does not say 'match uniquely'")
        for c in a.conds:
            rd = os.path.join(a.work, macro, "tt_cs") if c == "tt:25:1.80" else \
                os.path.join(a.work, table, "corner_" + corner_tag(c))
            name = site_name(short, c)
            res, how = run_result(a.bench, rd, os.path.join(a.out, f"e84a10_{name}.json"))
            if res is None:
                errors.append(f"{name}: {rd}: {how}")
                continue
            reads = [r for r in res["cycles"] if r.get("kind") == "read" and r.get("complete")
                     and r.get("bl1_min_V") is not None]
            if not reads:
                errors.append(f"{name}: {rd}: no complete read with bitline data")
                continue
            w = min(reads, key=lambda r: r["bl1_min_V"])
            vm = vms.get(c)
            r = subprocess.run([sys.executable, a.bench, "pick", "--bin", binf, "--word-bytes", "2",
                                "--words-per-row", str(a.wpr), "--mode", "words", "--addrs", str(w["addr"]),
                                "--waits", str(a.wait)], capture_output=True, text=True)
            seq = r.stdout.strip().split("\n")[-1].strip() if r.returncode == 0 else ""
            if not re.match(r"^i,r\d+,w\d+,r\d+$", seq):
                errors.append(f"{name}: no sequence from pick ({r.stderr.strip()[-200:]})")
                continue
            sites.append({
                "name": name, "index": len(sites), "table": table, "short": short, "macro": macro, "cond": c,
                "section": c.split(":")[0], "temp": float(c.split(":")[1]), "vdd": float(c.split(":")[2]),
                "run_dir": rd, "analysis": how, "reads_in_run": len(reads),
                "addr": w["addr"], "row": w["row"], "word": w["word"],
                "bl1_min_V": w["bl1_min_V"], "bl1_min_col": w["bl1_min_col"],
                "bl0_max_V": w.get("bl0_max_V"), "read_ok": w.get("ok"), "selection_ok": w.get("selection_ok"),
                "vm_e84a10": vm, "margin_e84a10": (w["bl1_min_V"] - vm) if vm is not None else None,
                "output_exempt": c in OUTPUT_EXEMPT, "netlist": sp, "bin": binf, "seq": seq,
                "netlist_md5": md5(sp) if os.path.isfile(sp) else None})
    out = {"work": os.path.abspath(a.work), "vm_file": vmfile, "vm": vms, "conds": a.conds, "wait_ns": a.wait,
           "sites": sites, "errors": errors}
    wjson(os.path.join(a.out, "sites.json"), out)
    print(f"E8.4d sites from {a.work} (switching levels {vmfile}: "
          + ", ".join(f"{k} {v:.3f}" for k, v in vms.items()) + ")")
    print(f"   {'site':28s} {'addr':>5s} {'row':>4s} {'col':>4s} {'bitline':>8s} {'VM':>6s} {'margin':>7s}  sequence")
    for s in sites:
        print(f"   {s['name']:28s} {s['addr']:5d} {s['row']:4d} {s['bl1_min_col']:4d} {s['bl1_min_V']:8.3f} "
              f"{fmt(s['vm_e84a10'])} {fmt(s['margin_e84a10'], 3):>7s}  {s['seq']}   ({s['analysis']})")
    for e in errors:
        print("   ERROR: " + e)
    if errors:
        return 1
    return 0


# --------------------------------------------------------------------------
# prepare
# --------------------------------------------------------------------------
def find_site(out, name):
    sj = json.load(open(os.path.join(out, "sites.json")))
    for s in sj["sites"]:
        if s["name"] == name:
            return s, sj
    sys.exit(f"no site {name} in {out}/sites.json")


def num(params, key):
    v = params.get(key, params.get(key.upper()))
    if v is None:
        return None
    try:
        return float(v)
    except ValueError:
        return None


def inverters(bench, netlist, top, bl_nodes):
    """the bitline inverter of every column: the PMOS (W 5, L 0.15) and the NMOS (W 1.68, L 0.15) whose gate is the
    bitline and which share their other non-supply terminal (the output)"""
    subs, _ = bench.parse_netlist(netlist)
    if top not in subs:
        sys.exit(f"{top} not in {netlist}")
    by_gate = {}
    for (name, nodes, cell, params) in subs[top]["inst"]:
        if len(nodes) != 4:
            continue
        cl = cell.lower()
        if cl.endswith("pfet_01v8") or cl.endswith("nfet_01v8"):
            by_gate.setdefault(nodes[1].lower(), []).append((name, nodes, cl, params))
    sup = {"vccd1", "vssd1", "0", "gnd", "vdd"}
    out, problems = {}, []
    for col, bl in bl_nodes.items():
        devs = by_gate.get(bl.lower(), [])
        ps = [d for d in devs if d[2].endswith("pfet_01v8") and abs((num(d[3], "w") or 0) - INV_P[0]) < 1e-3
              and abs((num(d[3], "l") or 0) - INV_P[1]) < 1e-3]
        ns = [d for d in devs if d[2].endswith("nfet_01v8") and abs((num(d[3], "w") or 0) - INV_N[0]) < 1e-3
              and abs((num(d[3], "l") or 0) - INV_N[1]) < 1e-3]
        if len(ps) != 1 or len(ns) != 1:
            problems.append(f"column {col}: {len(ps)} PMOS and {len(ns)} NMOS of the inverter sizes on {bl}")
            continue
        p, n = ps[0], ns[0]
        po = [x for x in (p[1][0], p[1][2]) if x.lower() not in sup]
        no = [x for x in (n[1][0], n[1][2]) if x.lower() not in sup]
        if len(po) != 1 or len(no) != 1 or po[0].lower() != no[0].lower():
            problems.append(f"column {col}: PMOS {p[0]} and NMOS {n[0]} do not share one output ({po}, {no})")
            continue
        out[col] = {"bitline": bl, "out": po[0], "pmos": p[0], "nmos": n[0]}
    return out, problems


def cmd_prepare(a):
    bench = load_bench(a.bench)
    site, sj = find_site(a.out, a.site)
    sdir = os.path.join(a.out, a.site)
    base = os.path.join(sdir, "base")
    pj = os.path.join(base, "prepare.json")
    if a.keep and os.path.isfile(pj):
        old = json.load(open(pj))
        same = {k: (old.get("site_record") or {}).get(k) == site.get(k)
                for k in ("macro", "cond", "addr", "seq", "netlist_md5")}
        if all(same.values()) and old.get("models_md5") == md5(a.models) and old.get("reltol") == a.reltol:
            print(f"   {a.site}: deck written in an earlier run, kept")
            return 0
        sys.exit(f"{a.site}: the deck of an earlier run differs from the current site or settings "
                 f"({', '.join(k for k, v in same.items() if not v) or 'models or reltol'}); "
                 f"remove {sdir} to start this site again")
    if os.path.isdir(base):
        shutil.rmtree(base)
    os.makedirs(base)
    sec = site["section"]
    cmd = [sys.executable, a.bench, "bench", "--sp", site["netlist"], "--top", site["macro"], "--bin", site["bin"],
           "--word-bytes", "2", "--words-per-row", str(a.wpr), "--out", base, "--models", a.models,
           "--period", str(a.period), "--seq", site["seq"], "--sanitize", "--plain-nfet", "--probes", "full",
           "--bitlines", "all", "--corner", sec, "--temp", f"{site['temp']:g}", "--vdd", f"{site['vdd']:g}",
           "--cs-delay", str(a.cs_delay), "--reltol", f"{a.reltol:g}"]
    if a.tmax:
        cmd += ["--tmax", f"{a.tmax:g}"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    open(os.path.join(base, "bench.txt"), "w").write(r.stdout + r.stderr)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        sys.exit(f"{a.site}: bench failed")
    meta = json.load(open(os.path.join(base, "tb_meta.json")))
    pm = meta.get("probe_map", {})
    cols = meta["cols"]
    bl_nodes = {}
    for c in range(cols):
        v = pm.get(f"bl{c}")
        m = re.match(r"^v\(xrom\.(.+)\)$", v or "", re.I)
        if m:
            bl_nodes[c] = m.group(1)
    if len(bl_nodes) != cols:
        sys.exit(f"{a.site}: {len(bl_nodes)} of {cols} bitlines found by the bench")
    netlist = os.path.join(base, "netlist.sp")
    inv, problems = inverters(bench, netlist, site["macro"], bl_nodes)
    if problems or len(inv) != cols:
        for p in problems[:10]:
            print("   " + p)
        sys.exit(f"{a.site}: inverters found for {len(inv)} of {cols} columns")
    # the netlist with the switches (inside the top subcircuit, before its .ends)
    mc_net = os.path.join(base, "netlist_mc.sp")
    top = site["macro"].lower()
    in_top, done = False, False
    with open(netlist, errors="replace") as fi, open(mc_net, "w") as fo:
        for line in fi:
            s = line.strip().lower()
            if s.startswith(".subckt"):
                t = s.split()
                in_top = len(t) > 1 and t[1] == top
            elif s.startswith(".ends") and in_top and not done:
                fo.write("* P2R-E8.4d: one switch per bitline to the forcing node (open while the transient runs)\n")
                for c in range(cols):
                    fo.write(f"Se8f{c} {inv[c]['bitline']} e8_vforce e8_ctl 0 e8sw\n")
                done = True
                in_top = False
            fo.write(line)
    if not done:
        sys.exit(f"{a.site}: .ends of {site['macro']} not found in {netlist}")
    # the deck template: after the bench's sequence (tstop) the switches close and the forcing node ramps up and
    # down through every inverter's switching level within the same transient (a DC sweep of this macro needs
    # gmin stepping at every point: sandbox 2026-10-20, about 17 s per point)
    tb = open(os.path.join(base, "tb.sp")).read().split("\n")
    vm0 = site["vm_e84a10"] if site["vm_e84a10"] is not None else 0.5 * site["vdd"]
    lo, hi = max(0.0, vm0 - a.span), min(site["vdd"], vm0 + a.span)
    tstop = meta["tstop"]
    tc = tstop + 1e-9                       # the switches close (control 0 -> 1 V in 1 ns)
    tu0 = tstop + 3e-9                      # up ramp lo -> hi
    tr = (hi - lo) / (a.rate * 1e9)         # ramp duration (s), rate in V/ns
    tu1 = tu0 + tr
    td1 = tu1 + tr                          # down ramp hi -> lo
    tend = td1 + 2e-9
    ramp = {"lo": lo, "hi": hi, "rate_V_per_ns": a.rate, "t_close": tc, "t_up0": tu0, "t_up1": tu1, "t_down1": td1,
            "t_end": tend, "win_up": [tu0 + 2e-9, tu1], "win_down": [tu1 + 2e-9, td1]}
    outs = [f"v(xrom.{inv[c]['out']})" for c in range(cols)]
    new, n_lib, n_inc, n_done, n_tran, n_save = [], 0, 0, 0, 0, 0
    for line in tb:
        if line.startswith(".lib "):
            m = re.match(r'^\.lib\s+(".*?"|\S+)\s+(\S+)\s*$', line)
            if not m or m.group(2) != sec:
                sys.exit(f"{a.site}: unexpected .lib line: {line}")
            new.append(f".lib {m.group(1)} @SECTION@")
            new.append(".options seed=@SEED@")
            n_lib += 1
            continue
        if line.startswith(".include") and line.rstrip().endswith('netlist.sp"'):
            new.append(line.replace('netlist.sp"', 'netlist_mc.sp"'))
            new += [".global e8_vforce e8_ctl",
                    f"Ve8f e8_vforce 0 PWL(0 {lo:.5f} {tu0:.6e} {lo:.5f} {tu1:.6e} {hi:.5f} {td1:.6e} {lo:.5f})",
                    f"Ve8c e8_ctl 0 PWL(0 0 {tc:.6e} 0 {tc + 1e-9:.6e} 1)",
                    ".model e8sw sw vt=0.5 vh=0.1 ron=1 roff=1e12"]
            n_inc += 1
            continue
        if line.startswith(".tran "):
            t = line.split()
            if len(t) < 5 or abs(float(t[2]) - tstop) > 1e-12:
                sys.exit(f"{a.site}: unexpected .tran line: {line}")
            t[2] = f"{tend:.6e}"
            new.append(" ".join(t))
            n_tran += 1
            continue
        if line.startswith("save ") and n_save == 0:
            new.append(line + " v(e8_vforce) " + " ".join(outs))
            n_save += 1
            continue
        new.append(line)
        if line.strip() == "shell touch tb_done":
            n_done += 1
            new.append("* P2R-E8.4d: the switching level of every bitline inverter (output = input) on the up and the "
                       "down ramp")
            for c in range(cols):
                new += [f"let e8d{c} = {outs[c]} - v(e8_vforce)",
                        f"meas tran e8u{c} when e8d{c}=0 cross=1 from={ramp['win_up'][0]:.6e} to={ramp['win_up'][1]:.6e}",
                        f"meas tran e8w{c} when e8d{c}=0 cross=1 from={ramp['win_down'][0]:.6e} "
                        f"to={ramp['win_down'][1]:.6e}"]
            new.append("shell touch vm_done")
    if (n_lib, n_inc, n_done, n_tran, n_save) != (1, 1, 1, 1, 1):
        sys.exit(f"{a.site}: deck not as expected (.lib {n_lib}, netlist include {n_inc}, tb_done {n_done}, "
                 f".tran {n_tran}, save {n_save})")
    open(os.path.join(base, "tb_template.sp"), "w").write("\n".join(new))
    info = {"site": a.site, "bench": os.path.abspath(a.bench), "bench_md5": md5(a.bench),
            "models": os.path.abspath(a.models), "models_md5": md5(a.models), "section_nominal": sec,
            "section_mismatch": sec + "_mm", "reltol": a.reltol, "tmax_ns": a.tmax, "period_ns": a.period,
            "cs_delay_ns": a.cs_delay, "tstop_bench_s": tstop, "ramp": ramp, "netlist_md5": md5(netlist),
            "netlist_mc_md5": md5(mc_net), "switches": cols, "inverters": {str(c): inv[c] for c in range(cols)},
            "bench_cmd": cmd[1:], "site_record": site}
    wjson(os.path.join(base, "prepare.json"), info)
    print(f"   {a.site}: deck written ({tstop * 1e9:.1f} ns, {len(meta['cycles'])} cycles, sequence "
          f"{site['seq']}); {cols} inverters found (PMOS {INV_P[0]}/{INV_P[1]}, NMOS {INV_N[0]}/{INV_N[1]}); "
          f"then switches closed and the forcing node ramped {lo:.3f} -> {hi:.3f} -> {lo:.3f} V at "
          f"{a.rate * 1e3:g} mV/ns (to {tend * 1e9:.1f} ns)")
    return 0


# --------------------------------------------------------------------------
# samples
# --------------------------------------------------------------------------
def cmd_samples(a):
    site, sj = find_site(a.out, a.site)
    sdir = os.path.join(a.out, a.site)
    tmpl = open(os.path.join(sdir, "base", "tb_template.sp")).read()
    sec = site["section"]
    made = []

    def write(tag, section, seed):
        d = os.path.join(sdir, tag)
        if os.path.isfile(os.path.join(d, "tb.sp")):
            old = open(os.path.join(d, "tb.sp")).read()
            new = tmpl.replace("@SECTION@", section).replace("@SEED@", str(seed))
            if old == new:
                return
            shutil.rmtree(d)
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "tb.sp"), "w").write(tmpl.replace("@SECTION@", section).replace("@SEED@", str(seed)))
        shutil.copy(os.path.join(sdir, "base", "tb_meta.json"), os.path.join(d, "tb_meta.json"))
        wjson(os.path.join(d, "sample.json"), {"site": a.site, "tag": tag, "section": section, "seed": seed})
        made.append(tag)

    base_seed = SEED_BASE * (site["index"] + 1)
    write("s0000", sec, base_seed)
    for k in range(1, a.n + 1):
        write(f"s{k:04d}", sec + "_mm", base_seed + k)
    for k in range(1, a.repeat + 1):
        write(f"r{k:04d}", sec + "_mm", base_seed + k)
    print(f"   {a.site}: {a.n} mismatch samples (seeds {base_seed + 1}-{base_seed + a.n}), the nominal run, "
          f"{a.repeat} repeat(s); {len(made)} deck(s) written now")
    return 0


# --------------------------------------------------------------------------
# analyze
# --------------------------------------------------------------------------
def read_vm(log, cols, ramp):
    """the switching level of every column from the meas lines of ngspice.log: the crossing time of output = input
    on the up ramp (e8u<c>) and on the down ramp (e8w<c>), turned into the forcing voltage; the level is their mean
    (the output's lag shifts the two crossings in opposite directions), the half difference is reported"""
    got = {}
    rx = re.compile(r"^\s*(e8[uw])(\d+)\s*=\s*([-+0-9.eE]+)")
    with open(log, errors="replace") as fh:
        for line in fh:
            for part in line.split("\r"):
                m = rx.match(part)
                if m:
                    got[(m.group(1), int(m.group(2)))] = float(m.group(3))
    lo, hi, r = ramp["lo"], ramp["hi"], ramp["rate_V_per_ns"] * 1e9
    vm, lag, bad = [], [], []
    for c in range(cols):
        tu, tw = got.get(("e8u", c)), got.get(("e8w", c))
        if tu is None or tw is None:
            bad.append(c)
            vm.append(None)
            lag.append(None)
            continue
        vu = lo + (tu - ramp["t_up0"]) * r
        vw = hi - (tw - ramp["t_up1"]) * r
        vm.append(0.5 * (vu + vw))
        lag.append(0.5 * (vu - vw))
    if bad:
        return vm, lag, f"no crossing on both ramps for {len(bad)} column(s), e.g. {bad[:5]}"
    return vm, lag, None


def sample_state(d):
    if not os.path.isfile(os.path.join(d, "exit_code")):
        return "not finished"
    ec = open(os.path.join(d, "exit_code")).read().strip()
    if ec != "0":
        return f"ngspice exit {ec}"
    if os.path.isfile(os.path.join(d, "tb_failed")) or not os.path.isfile(os.path.join(d, "tb_done")):
        return "transient incomplete"
    if not os.path.isfile(os.path.join(d, "vm_done")):
        return "switching levels not measured"
    return "finished"


def analyze_sample(a, d, site):
    st = sample_state(d)
    rec = {"tag": os.path.basename(d), "state": st}
    sj = os.path.join(d, "sample.json")
    if os.path.isfile(sj):
        rec.update({k: v for k, v in json.load(open(sj)).items() if k in ("section", "seed")})
    if st != "finished":
        return rec
    rj = os.path.join(d, "result_mc.json")
    if not os.path.isfile(rj) or os.path.getmtime(rj) < os.path.getmtime(os.path.join(d, "exit_code")):
        r = subprocess.run([sys.executable, a.bench, "analyze", "--dir", d, "--json-out", rj],
                           capture_output=True, text=True)
        open(os.path.join(d, "analyze.txt"), "w").write(r.stdout + r.stderr)
        if r.returncode != 0 or not os.path.isfile(rj):
            rec["state"] = "analyze failed"
            return rec
    res = json.load(open(rj))
    meta = json.load(open(os.path.join(d, "tb_meta.json")))
    cols = meta["cols"]
    reads = [r for r in res["cycles"] if r.get("kind") == "read"]
    if len(reads) != 2 or not all(r.get("complete") for r in reads):
        rec["state"] = f"{len(reads)} reads, not all complete"
        return rec
    ra, rt = reads
    if rt.get("addr") != site["addr"]:
        rec["state"] = f"target read is address {rt.get('addr')}, expected {site['addr']}"
        return rec
    prep = json.load(open(os.path.join(os.path.dirname(d), "base", "prepare.json")))
    vm, lag, err = read_vm(os.path.join(d, "ngspice.log"), cols, prep["ramp"])
    if err:
        rec["state"] = "switching levels: " + err
        return rec
    bl1 = {int(k): v for k, v in rt["bl1_by_col"].items()}
    rb = meta["cycles"][[i for i, c in enumerate(meta["cycles"]) if c["kind"] == "read"][1]].get("row_bits")
    zero_cols = [c for c in range(cols) if rb and rb[c] == 0]
    m1 = {c: bl1[c] - vm[c] for c in bl1}
    cmin = min(m1, key=lambda c: m1[c])
    vm0 = min(vm[c] for c in zero_cols) if zero_cols else None
    rec.update({
        "reads_ok": [bool(ra.get("ok")), bool(rt.get("ok"))],
        "selection_ok": [ra.get("selection_ok"), rt.get("selection_ok")],
        "wrong_bits_target": rt.get("wrong_bits"),
        "bl1_min_V": rt.get("bl1_min_V"), "bl1_min_col": rt.get("bl1_min_col"),
        "bl0_max_V": rt.get("bl0_max_V"), "bl0_max_col": rt.get("bl0_max_col"),
        "vm_by_col": vm, "vm_lag_max_mV": 1e3 * max(abs(x) for x in lag),
        "bl1_by_col": {str(c): bl1[c] for c in sorted(bl1)},
        "m1_min_V": m1[cmin], "m1_min_col": cmin, "m1_site_col_V": m1.get(site["bl1_min_col"]),
        "m0_min_V": (vm0 - rt["bl0_max_V"]) if (vm0 is not None and rt.get("bl0_max_V") is not None) else None,
        "t_access_ns": rt.get("t_access_ns"), "footer_to_wl_ns": rt.get("footer_to_wl_ns")})
    return rec


def sample_record(a, d, site):
    """the sample's record: D/mc.json if written (its waveforms may be deleted), else analysed now (and written
    when the sample is finished)"""
    mj = os.path.join(d, "mc.json")
    if os.path.isfile(mj):
        return json.load(open(mj))
    rec = analyze_sample(a, d, site)
    if rec["state"] not in ("not finished",):
        wjson(mj, rec)
    return rec


def cmd_one(a):
    d = os.path.abspath(a.dir)
    name = os.path.basename(os.path.dirname(d))
    site, _ = find_site(a.out, name)
    rec = sample_record(a, d, site)
    print(f"{name}/{os.path.basename(d)}: {rec['state']}"
          + (f", margin {rec['m1_min_V']:.4f} V (column {rec['m1_min_col']})" if rec.get("m1_min_V") is not None
             else ""))
    return 0 if rec["state"] == "finished" else 1


def stats(xs):
    xs = [x for x in xs if x is not None]
    n = len(xs)
    if n < 2:
        return {"n": n}
    mu = sum(xs) / n
    sd = math.sqrt(sum((x - mu) ** 2 for x in xs) / (n - 1))
    out = {"n": n, "mean": mu, "sd": sd, "min": min(xs), "max": max(xs)}
    if sd > 0:
        out["skew"] = sum(((x - mu) / sd) ** 3 for x in xs) / n
        out["ex_kurt"] = sum(((x - mu) / sd) ** 4 for x in xs) / n - 3.0
    try:
        from scipy import stats as st
        if 3 <= n <= 5000:
            out["shapiro_p"] = float(st.shapiro(xs).pvalue)
    except Exception:
        pass
    return out


def cmd_analyze(a):
    sj = json.load(open(os.path.join(a.out, "sites.json")))
    summary = {"margin_rule_V": a.margin, "sites": {}, "gates": {}}
    print(f"P2R-E8.4d analysis ({a.out})")
    if getattr(a, "quiet", False):
        print("   (status: only the samples analysed so far; gates are final only when every sample has finished)")
    allok = True
    for site in sj["sites"]:
        name = site["name"]
        sdir = os.path.join(a.out, name)
        if not os.path.isdir(sdir):
            print(f"\n{name}: no samples")
            allok = False
            continue
        tags = sorted(t for t in os.listdir(sdir) if re.match(r"^[sr]\d{4}$", t))
        if getattr(a, "quiet", False):
            recs = {}
            for t in tags:
                mj = os.path.join(sdir, t, "mc.json")
                recs[t] = json.load(open(mj)) if os.path.isfile(mj) else {"tag": t, "state": "no record yet"}
        else:
            recs = {t: sample_record(a, os.path.join(sdir, t), site) for t in tags}
        nom = recs.get("s0000")
        mc = [recs[t] for t in tags if t.startswith("s") and t != "s0000"]
        rep = [recs[t] for t in tags if t.startswith("r")]
        fin = [r for r in mc if r["state"] == "finished"]
        g = {}
        # G1 every sample finished, with a switching level for every column
        g["G1_finished"] = f"{len(fin)}/{len(mc)}" + (" + nominal" if nom and nom["state"] == "finished" else
                                                     " (NOMINAL NOT FINISHED)")
        g["G1"] = bool(nom and nom["state"] == "finished" and len(fin) == len(mc) and mc)
        # G2 nominal: reads right (the target read's output is exempt at fs -40 C 1.60 V), selection right,
        #    switching levels within 2 mV of E8.4a-10's
        if nom and nom["state"] == "finished":
            dvm = [v - site["vm_e84a10"] for v in nom["vm_by_col"]] if site["vm_e84a10"] is not None else []
            reads_ok = all(nom["reads_ok"]) or (site["output_exempt"])
            g["G2_vm_diff_mV"] = [1e3 * min(dvm), 1e3 * max(dvm)] if dvm else None
            g["G2"] = bool(reads_ok and all(x is not False for x in nom["selection_ok"])
                           and dvm and max(abs(x) for x in dvm) <= 2e-3)
            g["G3_bl1_new_minus_e84a10_mV"] = 1e3 * (nom["bl1_min_V"] - site["bl1_min_V"])
            g["G3"] = abs(nom["bl1_min_V"] - site["bl1_min_V"]) <= 0.015
        else:
            g["G2"] = g["G3"] = False
        # G4 repeats: the same seed gives the same numbers; different seeds give different switching levels
        rep_ok = []
        for r in rep:
            s = recs.get("s" + r["tag"][1:])
            if r["state"] == "finished" and s and s["state"] == "finished":
                dv = max(abs(x - y) for x, y in zip(r["vm_by_col"], s["vm_by_col"]))
                db = abs(r["m1_min_V"] - s["m1_min_V"])
                rep_ok.append(dv <= 1e-6 and db <= 1e-4)
            else:
                rep_ok.append(False)
        vm_sd = stats([r["vm_by_col"][site["bl1_min_col"]] for r in fin]).get("sd", 0.0) if fin else 0.0
        g["G4_repeats"] = rep_ok
        g["G4"] = bool(rep_ok and all(rep_ok) and vm_sd > 0)
        # margins
        m1 = stats([r["m1_min_V"] for r in fin])
        mcell = stats([r["m1_site_col_V"] for r in fin])
        bl = stats([r["bl1_min_V"] for r in fin])
        vmc = stats([r["vm_by_col"][site["bl1_min_col"]] for r in fin])
        blc = stats([r["bl1_by_col"].get(str(site["bl1_min_col"])) for r in fin])
        m0 = stats([r["m0_min_V"] for r in fin])
        # per one cell of the read row: sd of its margin over the samples
        sd_cells = []
        if fin:
            for c in fin[0]["bl1_by_col"]:
                xs = [r["bl1_by_col"][c] - r["vm_by_col"][int(c)] for r in fin]
                s_ = stats(xs)
                if "sd" in s_:
                    sd_cells.append((s_["sd"], int(c), s_["mean"]))
        reads_bad = sum(1 for r in fin if not all(r["reads_ok"]))
        sel_bad = sum(1 for r in fin if any(x is False for x in r["selection_ok"]))
        below = sum(1 for r in fin if r["m1_min_V"] < a.margin)
        below0 = sum(1 for r in fin if r["m1_min_V"] < 0)
        m0_below = sum(1 for r in fin if r["m0_min_V"] is not None and r["m0_min_V"] < a.margin)
        nm = nom["m1_min_V"] if nom and nom.get("m1_min_V") is not None else None
        v = {}
        if "sd" in m1 and m1["sd"] > 0:
            v["mu_minus_3sd_V"] = m1["mean"] - 3 * m1["sd"]
            v["sd_to_rule"] = (m1["mean"] - a.margin) / m1["sd"]
            v["sd_to_zero"] = m1["mean"] / m1["sd"]
            v["V1"] = (v["mu_minus_3sd_V"] >= a.margin) and below == 0
        v["reads_wrong"] = reads_bad
        v["selection_wrong"] = sel_bad
        v["samples_below_rule"] = below
        v["samples_below_zero"] = below0
        v["zero_side_below_rule"] = m0_below
        v["R_ok"] = reads_bad == 0 or bool(site["output_exempt"])
        v["S_ok"] = sel_bad == 0
        v["Z_ok"] = m0_below == 0
        v["below_zero_ok"] = below0 == 0
        summary["sites"][name] = {"site": site, "nominal": nom, "gates": g, "margin_row_min": m1,
                                  "margin_worst_cell": mcell, "bl1_row_min": bl, "bl1_worst_cell": blc,
                                  "vm_worst_cell": vmc, "margin_zero_side": m0, "verdict": v,
                                  "sd_by_cell_V": sorted(sd_cells, reverse=True),
                                  "samples": {t: recs[t] for t in tags}}
        allok = allok and g.get("G1") and g.get("G2") and g.get("G4")
        print(f"\n{name}: {site['macro']} at {site['cond']}, address {site['addr']} (row {site['row']}, worst "
              f"column {site['bl1_min_col']} in E8.4a-10: bitline {site['bl1_min_V']:.3f} V, margin "
              f"{fmt(site['margin_e84a10'])} V)")
        print(f"   G1 samples finished: {g['G1_finished']}  -> {'PASS' if g['G1'] else 'FAIL'}")
        notfin = [(t, recs[t]["state"]) for t in tags if recs[t]["state"] != "finished"]
        g["not_finished"] = notfin
        for t, st_ in notfin[:40]:
            print(f"      {t}: {st_}")
        if len(notfin) > 40:
            print(f"      ... {len(notfin) - 40} more")
        if nom and nom["state"] == "finished":
            print(f"   G2 nominal: reads {nom['reads_ok']}, selection {nom['selection_ok']}, switching levels "
                  f"{g['G2_vm_diff_mV'][0]:+.2f}..{g['G2_vm_diff_mV'][1]:+.2f} mV from E8.4a-10's "
                  f"{fmt(site['vm_e84a10'])} V  -> {'PASS' if g['G2'] else 'FAIL'}")
            print(f"   G3 nominal row minimum {nom['bl1_min_V']:.4f} V (column {nom['bl1_min_col']}), E8.4a-10 "
                  f"{site['bl1_min_V']:.4f} V: {g['G3_bl1_new_minus_e84a10_mV']:+.1f} mV  -> "
                  f"{'within 15 mV' if g['G3'] else 'MORE THAN 15 mV (reported, the samples are compared with the nominal run)'}")
            print(f"      nominal margin of the row {nm:.4f} V (column {nom['m1_min_col']})")
        else:
            print(f"   G2, G3: the nominal run is {nom['state'] if nom else 'missing'}")
        print(f"   G4 repeats {rep_ok}, switching-level sd of the worst column {1e3 * vm_sd:.2f} mV  -> "
              f"{'PASS' if g['G4'] else 'FAIL'}")
        if "sd" in m1:
            shift = f"{1e3 * (m1['mean'] - nm):+.2f} mV" if nm is not None else "- (no nominal run)"
            print(f"   margin (row minimum, own switching levels), {m1['n']} samples: mean {m1['mean']:.4f} V, "
                  f"sd {1e3 * m1['sd']:.2f} mV, min {m1['min']:.4f} V, max {m1['max']:.4f} V; "
                  f"shift of the mean from the nominal {shift}")
            print(f"      skew {fmt(m1.get('skew'), 2)}, excess kurtosis {fmt(m1.get('ex_kurt'), 2)}, Shapiro-Wilk p "
                  f"{fmt(m1.get('shapiro_p'), 3)}")
            print(f"   worst cell (column {site['bl1_min_col']}): bitline sd {1e3 * blc.get('sd', 0):.2f} mV, "
                  f"switching level sd {1e3 * vmc.get('sd', 0):.2f} mV, margin sd {1e3 * mcell.get('sd', 0):.2f} mV")
            if sd_cells:
                sds = sorted(x[0] for x in sd_cells)
                print(f"   every one cell of the row ({len(sd_cells)}): margin sd {1e3 * sds[0]:.2f}-{1e3 * sds[-1]:.2f} mV"
                      f" (median {1e3 * sds[len(sds) // 2]:.2f}); largest at column {sd_cells and max(sd_cells)[1]}")
            if "mu_minus_3sd_V" in v:
                print(f"   mean - 3 sd {v['mu_minus_3sd_V']:.4f} V; (mean - {a.margin:.2f} V) / sd = "
                      f"{v['sd_to_rule']:.1f}; mean / sd = {v['sd_to_zero']:.1f}")
            else:
                print("   sd is 0: no sd distances")
            print(f"   samples below {a.margin:.2f} V: {below}; below 0: {below0}; zero side below the rule: {m0_below};"
                  f" reads wrong: {reads_bad}{' (output exempt at this condition)' if site['output_exempt'] else ''};"
                  f" wrong selection: {sel_bad}")
            print(f"   V1 (mean - 3 sd >= {a.margin:.2f} V and no sample below it): {'YES' if v.get('V1') else 'NO'}")
    summary["gates"]["all_G1_G2_G4"] = bool(allok)
    # overall
    rows = []
    for name, s in summary["sites"].items():
        m = s["margin_row_min"]
        if "sd" not in m:
            continue
        nm = (s["nominal"] or {}).get("m1_min_V")
        rows.append((name, m, nm, s["verdict"], s["gates"]))
    if rows:
        print("\n==== all sites ====")
        print(f"   {'site':28s} {'n':>4s} {'nominal':>8s} {'mean':>8s} {'shift mV':>8s} {'sd mV':>6s} {'min':>8s} "
              f"{'mu-3sd':>8s} {'(mu-0.1)/sd':>11s} {'mu/sd':>6s} V1  G1 G2 G3 G4")
        for name, m, nm, v, g in rows:
            yn = lambda x: "y" if x else "n"
            print(f"   {name:28s} {m['n']:4d} {fmt(nm, 4):>8s} {m['mean']:8.4f} "
                  f"{(1e3 * (m['mean'] - nm)) if nm is not None else float('nan'):8.2f} {1e3 * m['sd']:6.2f} "
                  f"{m['min']:8.4f} {v.get('mu_minus_3sd_V', float('nan')):8.4f} {v.get('sd_to_rule', float('nan')):11.1f} "
                  f"{v.get('sd_to_zero', float('nan')):6.1f} {yn(v.get('V1')):>2s}  {yn(g.get('G1'))}  {yn(g.get('G2'))}  "
                  f"{yn(g.get('G3'))}  {yn(g.get('G4'))}")
        complete = len(rows) == len(sj["sites"])
        allv1 = all(r[3].get("V1") for r in rows) and complete
        other = all(r[3].get("R_ok") and r[3].get("S_ok") and r[3].get("Z_ok") for r in rows)
        anyzero = any(not r[3].get("below_zero_ok") for r in rows)
        readbad = any(not r[3].get("R_ok") for r in rows)
        gates = all(r[4].get("G1") and r[4].get("G2") and r[4].get("G4") for r in rows)
        lowest = min(rows, key=lambda r: r[1]["min"])
        if not gates or not complete:
            concl = "gates not all passed or sites missing: diagnose before any conclusion"
        elif anyzero or readbad:
            concl = ("3: a sample below 0 V or a wrong read (output exempt only at fs -40 C 1.60 V): report it, "
                     "diagnose, KID decides")
        elif allv1 and other:
            concl = "1: every site V1, zero side and reads right: the rule holds at 3 sd of local mismatch"
        else:
            concl = "2: some site not V1 (or zero side / reads), none below 0: report the sd distance per site"
        summary["overall"] = {"sites_with_stats": len(rows), "sites": len(sj["sites"]), "all_V1": allv1,
                              "reads_selection_zero_side_ok": other, "any_sample_below_zero": anyzero,
                              "gates_G1_G2_G4": gates, "conclusion": concl,
                              "lowest_sample_V": lowest[1]["min"], "lowest_site": lowest[0],
                              "sd_range_mV": [1e3 * min(r[1]["sd"] for r in rows), 1e3 * max(r[1]["sd"] for r in rows)]}
        print(f"   every site V1: {'YES' if allv1 else 'NO'}; reads, selection and zero side right: "
              f"{'YES' if other else 'NO'}; lowest sample {lowest[1]['min']:.4f} V ({lowest[0]}); "
              f"sd {summary['overall']['sd_range_mV'][0]:.2f}-{summary['overall']['sd_range_mV'][1]:.2f} mV")
        print(f"   CONCLUSION (rules of claude/p2r-e8-4d-sandbox.md): {concl}")
    if a.json:
        wjson(a.json, summary)
        print(f"\nwritten {a.json}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("sites")
    p.add_argument("--bench", required=True)
    p.add_argument("--work", required=True, help="E8.4a-10 folder (reports/e8_rom/e8_4a10)")
    p.add_argument("--out", required=True)
    p.add_argument("--tables", default=TABLES_DEFAULT)
    p.add_argument("--conds", nargs="+", default=CONDS_DEFAULT)
    p.add_argument("--wait", type=int, default=40)
    p.add_argument("--wpr", type=int, default=13)
    p = sub.add_parser("prepare")
    p.add_argument("--bench", required=True)
    p.add_argument("--models", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--site", required=True)
    p.add_argument("--reltol", type=float, default=1e-5)
    p.add_argument("--tmax", type=float, default=None, help="maximum time step (ns); default: the bench's period/50")
    p.add_argument("--period", type=float, default=100.0)
    p.add_argument("--cs-delay", type=float, default=10.0)
    p.add_argument("--wpr", type=int, default=13)
    p.add_argument("--span", type=float, default=0.15, help="forcing ramp: E8.4a-10's switching level +- this (V)")
    p.add_argument("--rate", type=float, default=0.001, help="forcing ramp rate (V/ns)")
    p.add_argument("--keep", action="store_true",
                   help="keep the deck of an earlier run if it was written for the same site and settings")
    p = sub.add_parser("samples")
    p.add_argument("--out", required=True)
    p.add_argument("--site", required=True)
    p.add_argument("--n", type=int, required=True)
    p.add_argument("--repeat", type=int, default=1)
    p = sub.add_parser("one")
    p.add_argument("--bench", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--dir", required=True, help="a sample folder OUT/<site>/<tag>")
    p = sub.add_parser("analyze")
    p.add_argument("--bench", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--margin", type=float, default=0.10)
    p.add_argument("--json", default=None)
    p.add_argument("--quiet", action="store_true", help="status: only the samples that have a record")
    a = ap.parse_args()
    return {"sites": cmd_sites, "prepare": cmd_prepare, "samples": cmd_samples, "one": cmd_one,
            "analyze": cmd_analyze}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
