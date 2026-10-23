#!/usr/bin/env python3
"""
e8_5b_check.py   (P2R-E8.5b: gate-level power of the address-map unit)

Subcommands, called by scripts/e8_5b_amu_power.sh:

netlists  Input: the netlist of E8.5 (reports/e8_rom/e8_5/amu_top_<M>_sta.v, not changed)
          and the copy that Yosys flattened from it (flatten -noscopeinfo, splitnets,
          write_verilog -noattr -simple-lhs: one module, every internal net a single bit).
          Why flattened: in the hierarchical netlist the 8-slot buffer drives a
          6,400-bit bus bit by bit, and the simulator rebuilds and re-sends the whole
          bus at every bit change; in the layers with many lookups (fc1 on) this made
          the gate-level run about 100 times slower than in the convolution layers.
          Writes:
            - the name list: every escaped name of the flattened netlist (nets and cell
              instances, e.g. "tab[3].U_PTAB._0123_") gets a plain name (e85b_n<k> for
              nets, e85b_c<k> for cells), so the simulator, the waveform and OpenSTA all
              use the same plain names, whatever an OpenSTA version does with escaped
              names; the list keeps the original name and the top-level instance;
            - the simulation copy: top module renamed amu_top_gl (the wrapper
              rtl/e8/tb/amu_top_gl_wrap.v is amu_top), the data folder of the model
              given to the 200 ROM black boxes (the netlist has no DATA_DIR);
            - the OpenSTA copy: the parameter lists of the 200 ROM black boxes removed
              and "signed" removed from declarations (OpenSTA's Verilog reader stops at
              them).
          Checks: every cell instance (name and type) of the hierarchical netlist, with
          its hierarchical path, is in the flattened netlist and nothing else is; every
          cell pin bit and top-level port bit is on the same electrical net in both
          (nets followed through module ports and assignments); no multi-bit internal
          net is left; the renaming is undone exactly (round trip); the two copies have
          the same cells; the per-type cell counts of Yosys before and after flattening
          are equal. The counts (cells, pin bits, nets) go to <name list>.json.
sim       Compares the RTL run and the gate-level run of one model with each other
          and with the references (E8.2 trace, E8.5 trace and summary): result of
          the testbench, inference cycles, SRAM reads, the E8.2 monitor trace, the
          trace at the datapath start, every ROM macro read (time, side, lane, macro,
          address, clock-low time), the unit's port counters (they count only in
          simulation: 0 in the netlist), protocol errors.
vcd       Writes the waveform for OpenSTA: only wire and reg values (parameters,
          reals, integers, events and times dropped) and the time shifted so the
          waveform starts at 0 (the window of the inference), so every OpenSTA
          version reads the same window. Prints the window.
power     Reads the OpenSTA log: annotated pins (to equal the pin bits of the netlist),
          the power groups, the power of every cell grouped by the top-level instance of
          the unit (from the name list); energy per inference = total power x window.
"""
import argparse
import collections
import hashlib
import json
import os
import re
import sys


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


# ------------------------------------------------------------------ netlists
ID = r"(?:\\\S+|[A-Za-z_][\w$]*)"
# a module instance: type, optional parameter list (one level of nested parentheses), name, "("
INST_RE = re.compile(rf"^\s*({ID})\s*(#\((?:[^()]|\([^()]*\))*\))?\s*({ID})\s*\(", re.M)
MOD_RE = re.compile(rf"^module\s+({ID})\s*\((.*?)^endmodule", re.M | re.S)
DECL_RE = re.compile(rf"^\s*(wire|input|output|inout|reg)\s+(?:signed\s+)?(?:\[\s*(\d+)\s*:\s*(\d+)\s*\]\s*)?({ID})\s*;",
                     re.M)
# tokens of a Verilog netlist: comment, string, escaped name, other text; together they are the whole text
TOKEN_RE = re.compile(r'/\*.*?\*/|"(?:[^"\\\n]|\\.)*"|\\\S+|[^"\\/]+|.', re.S)
ROM_PAR_RE = re.compile(r"e8_rom_r48\s*#\(((?:[^()]|\([^()]*\))*)\)\s*")
NEW_RE = re.compile(r"\be85b_[nc]\d+\b")


def unesc(s):
    return s[1:] if s.startswith("\\") else s


def modules_of(text):
    """{module name: [(instance type, instance name), ...]} of a structural netlist."""
    mods = {}
    for m in MOD_RE.finditer(text):
        insts = [(unesc(a), unesc(c)) for a, _, c in INST_RE.findall(m.group(2)) if a not in ("module",)]
        mods[unesc(m.group(1))] = insts
    return mods


def expand(mods, top):
    """Leaf cells under top: {flat name: (type, path list)}; flat name = path joined by '.' (Yosys flatten)."""
    out = {}

    def rec(mod, path):
        for typ, nm in mods[mod]:
            p = path + [nm]
            if typ in mods:
                rec(typ, p)
            else:
                out[".".join(p)] = (typ, p)

    rec(top, [])
    return out


def yosys_stat_counts(path):
    """Per-type cell counts of a Yosys 'stat' output (the whole design: the 'design hierarchy'
    part when there is one). Either column order (count type / type count)."""
    t = open(path, errors="replace").read()
    i = t.find("design hierarchy")
    if i >= 0:
        t = t[i:]
    c = {}
    for m in re.finditer(r"^\s*(\d+)\s+(sky130_fd_sc_hd__\w+|e8_rom_r48)\s*$|^\s*(sky130_fd_sc_hd__\w+|e8_rom_r48)\s+(\d+)\s*$",
                         t, re.M):
        if m.group(1):
            c[m.group(2)] = int(m.group(1))
        else:
            c[m.group(3)] = int(m.group(4))
    return c


def cells_of(text):
    """Sorted (name, type) of the leaf cells of a one-module netlist."""
    return sorted((unesc(c), unesc(a)) for a, _, c in INST_RE.findall(text) if a != "module")


# ---- connectivity of a structural netlist (as Yosys writes it): every leaf-cell pin bit and every
# ---- top-level port bit, grouped into electrical nets across the hierarchy
STRUCT_TOK = re.compile(r"/\*.*?\*/|\"(?:[^\"\\\n]|\\.)*\"|\\\S+|[A-Za-z_][\w$]*|\d+'[sS]?[bodhBODH][0-9a-fA-FxXzZ_?]+"
                        r"|\d+|[(){}\[\]:,;.#=]|\S", re.S)


class _Mod:
    def __init__(self, ports):
        self.ports, self.rng, self.assigns, self.insts = ports, {}, [], []


def _const_bits(tok):
    w, rest = tok.split("'", 1)
    w = int(w)
    rest = rest.lstrip("sS")
    base, digs = rest[0].lower(), rest[1:].replace("_", "").lower()
    if base == "d":
        bits = list(bin(int(digs))[2:])
    else:
        per = {"b": 1, "o": 3, "h": 4}[base]
        bits = []
        for ch in digs:
            if ch in "xz?":
                bits += [ch if ch != "?" else "z"] * per
            else:
                bits += list(bin(int(ch, 16 if base == "h" else 8 if base == "o" else 2))[2:].zfill(per))
    fill = bits[0] if bits and bits[0] in "xz" else "0"
    bits = ([fill] * max(0, w - len(bits)) + bits)[-w:]
    return [("const", b) for b in bits]


def parse_struct(text):
    """Modules of a structural netlist: ports, net ranges, assigns, instances (type, name, {pin: tokens})."""
    toks = [t for t in STRUCT_TOK.findall(text) if not t.startswith("/*")]
    mods, cur, i, n = {}, None, 0, len(toks)

    def upto(i, stop):
        j = i
        while toks[j] != stop:
            j += 1
        return j

    while i < n:
        t = toks[i]
        if t == "module":
            name = unesc(toks[i + 1])
            j = upto(i, ";")
            ports = [unesc(x) for x in toks[i + 3:j - 1] if x != ","]
            cur = mods[name] = _Mod(ports)
            i = j + 1
        elif t == "endmodule":
            cur, i = None, i + 1
        elif t in ("input", "output", "inout", "wire", "reg"):
            i += 1
            if toks[i] == "signed":
                i += 1
            rng = (0, 0, True)
            if toks[i] == "[":
                rng = (int(toks[i + 1]), int(toks[i + 3]), False)
                i += 5
            while toks[i] != ";":
                if toks[i] != ",":
                    cur.rng.setdefault(unesc(toks[i]), rng)
                i += 1
            i += 1
        elif t == "assign":
            j = upto(i, "=")
            k = upto(j, ";")
            cur.assigns.append((toks[i + 1:j], toks[j + 1:k]))
            i = k + 1
        else:
            typ = unesc(t)
            i += 1
            if toks[i] == "#":
                depth, i = 0, i + 1
                while True:
                    depth += {"(": 1, ")": -1}.get(toks[i], 0)
                    i += 1
                    if depth == 0:
                        break
            name = unesc(toks[i])
            i += 2                      # name and "("
            conns = {}
            while toks[i] != ")":
                if toks[i] == ",":
                    i += 1
                    continue
                pin = toks[i + 1]       # "." pin "("
                depth, j = 1, i + 3
                while depth:
                    depth += {"(": 1, ")": -1}.get(toks[j], 0)
                    j += 1
                conns[pin] = toks[i + 3:j - 1]
                i = j
            cur.insts.append((typ, name, conns))
            i += 2                      # ")" ";"
    return mods


def _bits(tk, mod, path):
    """MSB-first bit list of an expression (tokens): ((path, net, index) | ("const", v))."""
    out = []

    def expr(i):
        t = tk[i]
        if t == "{":
            if re.fullmatch(r"\d+", tk[i + 1]) and tk[i + 2] == "{":
                inner, j = expr(i + 2)
                return inner * int(tk[i + 1]), j + 1
            res, i = [], i + 1
            while True:
                b, i = expr(i)
                res += b
                if tk[i] == ",":
                    i += 1
                    continue
                return res, i + 1
        if "'" in t:
            return _const_bits(t), i + 1
        name = unesc(t)
        if name not in mod.rng:
            raise ValueError(f"undeclared net {t} in {'.'.join(path) or 'top'}")
        if i + 1 < len(tk) and tk[i + 1] == "[":
            a = int(tk[i + 2])
            if tk[i + 3] == ":":
                b = int(tk[i + 4])
                st = -1 if a >= b else 1
                return [(path, name, x) for x in range(a, b + st, st)], i + 6
            return [(path, name, a)], i + 4
        a, b, _ = mod.rng[name]
        st = -1 if a >= b else 1
        return [(path, name, x) for x in range(a, b + st, st)], i + 1

    i = 0
    while i < len(tk):
        b, i = expr(i)
        out += b
    return out


def connectivity(text, top):
    """{pin: representative pin of its electrical net} over every leaf-cell pin bit (flat cell name, pin,
    bit from the LSB) and every top-level port bit ("PORT", name, bit); assigns and module ports join
    nets; constants are nets of their own value."""
    mods = parse_struct(text)
    parent = {}

    def find(x):
        root = x
        while parent.get(root, root) != root:
            root = parent[root]
        while parent.get(x, x) != root:
            parent[x], x = root, parent[x]
        return root

    def union(x, y):
        rx, ry = find(x), find(y)
        if rx != ry:
            parent[rx] = ry

    pins = []

    def rec(mname, path):
        m = mods[mname]
        for lhs, rhs in m.assigns:
            lb, rb = _bits(lhs, m, path), _bits(rhs, m, path)
            if len(lb) != len(rb):
                raise ValueError(f"assign of {len(rb)} bits to {len(lb)} bits in {mname}")
            for x, y in zip(lb, rb):
                union(x, y)
        for typ, name, conns in m.insts:
            if typ in mods:
                c, cp = mods[typ], path + (name,)
                for pin, tk in conns.items():
                    if not tk:
                        continue
                    eb = _bits(tk, m, path)
                    pb = _bits([pin], c, cp)
                    if len(eb) != len(pb):
                        raise ValueError(f"port {pin} of {name}: {len(eb)} bits to {len(pb)}")
                    for x, y in zip(pb, eb):
                        union(x, y)
                rec(typ, cp)
            else:
                flatname = ".".join(path + (name,))
                for pin, tk in conns.items():
                    for k, node in enumerate(reversed(_bits(tk, m, path) if tk else [])):
                        pins.append(((flatname, pin, k), node))

    rec(top, ())
    m = mods[top]
    for p in m.ports:
        for k, node in enumerate(reversed(_bits([p], m, ()))):
            pins.append((("PORT", p, k), node))
    groups = {}
    for pin, node in pins:
        groups.setdefault(find(node), []).append(pin)
    rep = {}
    for g in groups.values():
        r = min(g)
        for pin in g:
            rep[pin] = r
    return rep, len(groups)


def cmd_netlists(a):
    hier = open(a.hier).read()
    flat = open(a.flat).read()
    print(f"   E8.5 netlist     : {md5(a.hier)}  {a.hier}")
    print(f"   flattened (Yosys): {md5(a.flat)}  {a.flat}")
    bad = []

    # 1. the cells of the flattened netlist = the leaf cells of the hierarchy
    hmods = modules_of(hier)
    exp = expand(hmods, "amu_top")
    fmods = modules_of(flat)
    fl = cells_of(flat)
    ok1 = list(fmods) == ["amu_top"] and fl == sorted((k, v[0]) for k, v in exp.items())
    n_type = collections.Counter(t for _, t in fl)
    print(f"   hierarchy: {len(hmods)} modules, {len(exp)} leaf cells ({n_type.get('e8_rom_r48', 0)} ROM black boxes); "
          f"flattened: {len(fmods)} module(s) {list(fmods)[:3]}, {len(fl)} cells; names and types the same: "
          f"{'yes' if ok1 else 'NO'}")
    if not ok1:
        bad.append("cells of the flattened netlist")
        fs, es = set(fl), set((k, v[0]) for k, v in exp.items())
        for x in sorted(fs - es)[:5]:
            print(f"      only flattened: {x}")
        for x in sorted(es - fs)[:5]:
            print(f"      only hierarchy: {x}")
    ch, nh = {}, 0
    try:
        ch, nh = connectivity(hier, "amu_top")
        cf, nf = connectivity(flat, "amu_top")
        ok_c = ch == cf
        print(f"   connections: {len(ch)} pin bits (cell pins and top-level ports) in {nh} nets in the hierarchy, "
              f"{len(cf)} in {nf} nets flattened; every pin on the same net as before: {'yes' if ok_c else 'NO'}")
        if not ok_c:
            diff = [p for p in set(ch) | set(cf) if ch.get(p) != cf.get(p)]
            for p in sorted(diff)[:5]:
                print(f"      {p}: hierarchy net of {ch.get(p)}, flattened net of {cf.get(p)}")
    except (ValueError, KeyError, IndexError) as e:
        ok_c = False
        print(f"   connections: could not be read ({e!r})")
    if not ok_c:
        bad.append("connections")
    sh, sf = yosys_stat_counts(a.stat_hier), yosys_stat_counts(a.stat_flat)
    if sh and sf:
        ok2 = sh == sf == dict(n_type)
        print(f"   Yosys stat, cells per type: {len(sh)} types, {sum(sh.values())} cells before flattening, "
              f"{sum(sf.values())} after; equal to each other and to the netlist: {'yes' if ok2 else 'NO'}")
        if not ok2:
            bad.append("Yosys per-type counts")
    else:
        print(f"   Yosys stat: per-type counts not found in {a.stat_hier} / {a.stat_flat} (format); "
              f"the comparison by name above stands")

    # 2. internal nets: single bits (ports keep their width)
    hdr = re.search(r"^module\s+amu_top\s*\((.*?)\);", flat, re.M | re.S)
    ports = [p.strip() for p in hdr.group(1).split(",")] if hdr else []
    decl = DECL_RE.findall(flat)
    wide = [(d[3], int(d[1]) - int(d[2]) + 1) for d in decl
            if d[0] == "wire" and d[1] and unesc(d[3]) not in ports and int(d[1]) != int(d[2])]
    n_assign = len(re.findall(r"^\s*assign\s", flat, re.M))
    print(f"   ports {len(ports)}; internal multi-bit nets {len(wide)} (0 expected){'' if not wide else ' ' + str(wide[:3])}; "
          f"assign statements {n_assign}")
    if wide:
        bad.append("multi-bit internal nets")

    # 3. plain names for every escaped name (nets e85b_n<k>, cells e85b_c<k>)
    toks = TOKEN_RE.findall(flat)
    if "".join(toks) != flat:
        print("   ERROR: the tokens do not give back the text")
        return 1
    if NEW_RE.search(flat):
        print("   ERROR: the netlist already has names of the form e85b_n<k> / e85b_c<k>")
        return 1
    nets = {unesc(d[3]) for d in decl}
    cell_names = {n for n, _ in fl}
    newname, kinds = {}, collections.Counter()
    out = []
    for tk in toks:
        if tk.startswith("\\"):
            nm = tk[1:]
            nn = newname.get(nm)
            if nn is None:
                if nm in nets:
                    nn = f"e85b_n{kinds['n']}"
                    kinds["n"] += 1
                elif nm in cell_names:
                    nn = f"e85b_c{kinds['c']}"
                    kinds["c"] += 1
                else:
                    print(f"   ERROR: escaped name that is neither a declared net nor a cell: {tk}")
                    return 1
                newname[nm] = nn
            out.append(nn)
        else:
            out.append(tk)
    ren = "".join(out)
    inv = {v: k for k, v in newname.items()}
    back = NEW_RE.sub(lambda m: "\\" + inv[m.group(0)], ren)
    ok3 = back == flat and "\\" not in re.sub(r'"(?:[^"\\\n]|\\.)*"', "", ren)
    print(f"   plain names: {kinds['n']} nets, {kinds['c']} cells; renaming undone exactly and no escaped name "
          f"left: {'yes' if ok3 else 'NO'}")
    if not ok3:
        bad.append("renaming")
    with open(a.map_out, "w") as fh:
        fh.write("# P2R-E8.5b plain names of the flattened netlist: new_name kind original_name top_level_instance\n")
        for nm, nn in sorted(newname.items(), key=lambda x: (x[1][5], int(x[1][6:]))):
            if nn.startswith("e85b_c"):
                p = exp.get(nm, (None, [nm]))[1]
                top = p[0] if len(p) > 1 else "(top)"
                fh.write(f"{nn} cell {nm} {top}\n")
            else:
                fh.write(f"{nn} net {nm} -\n")
        for nm, _ in fl:
            if nm not in newname:            # plain cell names keep their name
                p = exp.get(nm, (None, [nm]))[1]
                fh.write(f"{nm} cell {nm} {p[0] if len(p) > 1 else '(top)'}\n")
    print(f"   name list -> {md5(a.map_out)}  {a.map_out}")

    # 4. the simulation copy and the OpenSTA copy
    sim, n_top = re.subn(r"^module amu_top\(", "module amu_top_gl(", ren, flags=re.M)
    dd = f'"data/rtl_inputs_{a.model}_v3"'
    n_dd = 0

    def set_dd(m):
        nonlocal n_dd
        n_dd += 1
        body = m.group(1)
        if re.search(r"\.DATA_DIR\(", body):
            body = re.sub(r'\.DATA_DIR\((?:"[^"]*")?\)', f".DATA_DIR({dd})", body)
        else:
            body = f"\n    .DATA_DIR({dd}),{body}"
        return f"e8_rom_r48 #({body}) "

    sim = ROM_PAR_RE.sub(set_dd, sim)
    sta, n_par = ROM_PAR_RE.subn("e8_rom_r48 ", ren)
    sta, n_sig = re.subn(r"^(\s*(?:wire|input|output|reg))\s+signed\s+", r"\1 ", sta, flags=re.M)
    n_rom = n_type.get("e8_rom_r48", 0)
    with open(a.sim_out, "w") as fh:
        fh.write(sim)
    with open(a.sta_out, "w") as fh:
        fh.write(sta)
    c_ren, c_sim, c_sta = cells_of(ren), cells_of(sim), cells_of(sta)
    ok4 = n_top == 1 and n_rom == 200 and n_dd == 200 and n_par == 200 and c_ren == c_sim == c_sta \
        and len(c_ren) == len(fl) and sim.count(f".DATA_DIR({dd})") == 200
    print(f"   simulation copy: top module renamed {n_top} (1 expected); DATA_DIR {dd} in {n_dd} ROM black boxes "
          f"(200 expected) -> {md5(a.sim_out)}  {a.sim_out}")
    print(f"   OpenSTA copy   : ROM parameter lists removed {n_par} (200 expected); 'signed' removed from {n_sig} "
          f"declarations -> {md5(a.sta_out)}  {a.sta_out}")
    print(f"   cell instances: {len(c_ren)} in each copy, same names and types: "
          f"{'yes' if c_ren == c_sim == c_sta else 'NO'}")
    if not ok4:
        bad.append("simulation / OpenSTA copies")
    info = {"cells": len(fl), "rom_black_boxes": n_rom, "pin_bits": len(ch), "nets": nh,
            "flip_flops_by_type": {k: v for k, v in n_type.items() if "df" in k}, "renamed_nets": kinds["n"],
            "renamed_cells": kinds["c"], "netlist_md5": md5(a.hier), "flattened_md5": md5(a.flat)}
    json.dump(info, open(a.map_out + ".json", "w"), indent=1)
    print(f"   counts -> {a.map_out}.json (OpenSTA should annotate {len(ch)} pin bits: every cell pin and port bit)")
    if bad:
        print(f"   FAILED: {', '.join(bad)}")
    return 0 if not bad else 1


# ------------------------------------------------------------------ sim
def tb_facts(path):
    t = open(path, errors="replace").read()
    f = {}
    m = re.search(r"RESULT: (.+)", t)
    f["result"] = m.group(1).strip() if m else None
    m = re.search(r"inference complete at cycle (\d+)", t)
    f["cycles"] = int(m.group(1)) if m else None
    m = re.search(r"SRAM protected-weight reads \(per MAC op\): (\d+)", t)
    f["sram_reads"] = int(m.group(1)) if m else None
    m = re.search(r"\[E8 MONITOR\] (\d+) MAC operations", t)
    f["e8_ops"] = int(m.group(1)) if m else None
    m = re.search(r"unit port counters: starts (\d+), stall cycles (\d+), lookup pulses (\d+), parking pulses (\d+); "
                  r"error flags \{queue,lane0,mismatch\} (\w+)", t)
    f["counters"] = m.groups() if m else None
    m = re.search(r"ROM protocol errors: CS at the clock edge (\d+), address changed while high (\d+), invalid word "
                  r"(\d+); models without data (\d+); shortest clock low before a read (\d+) ps", t)
    f["protocol"] = tuple(int(x) for x in m.groups()) if m else None
    m = re.search(r"operations at the datapath start (\d+)", t)
    f["go_ops"] = int(m.group(1)) if m else None
    return f


def reads_of(path):
    """ROM macro reads: lines 'R phase cycle t_ps side lane macro addr low_ps'. Returns the sorted keys
    (t_ps side lane macro addr low_ps), {key: cycle}, counts by phase and by side."""
    keys, cyc, by_ph, by_side = [], {}, {"B": 0, "I": 0, "A": 0}, [0, 0]
    for ln in open(path):
        if ln.startswith("R "):
            p = ln.split()
            k = " ".join(p[3:])
            keys.append(k)
            cyc[k] = int(p[2])
            by_ph[p[1]] += 1
            by_side[int(p[4])] += 1
    return sorted(keys), cyc, by_ph, by_side


def cmd_sim(a):
    bad = 0

    def gate(ok, label):
        nonlocal bad
        print(f"  {'PASS' if ok else 'FAIL'}  {label}")
        bad += not ok

    r, g = tb_facts(a.rtl_log), tb_facts(a.gate_log)
    print(f"   RTL run : result {r['result']}, {r['cycles']} cycles, SRAM reads {r['sram_reads']}, counters {r['counters']}")
    print(f"   gate run: result {g['result']}, {g['cycles']} cycles, SRAM reads {g['sram_reads']}, counters {g['counters']}")
    ref = tb_facts(a.e85_log) if a.e85_log and os.path.isfile(a.e85_log) else None
    if ref:
        print(f"   E8.5 run: result {ref['result']}, {ref['cycles']} cycles, SRAM reads {ref['sram_reads']}")
    gate(r["result"] == "ALL TESTS PASSED" and g["result"] == "ALL TESTS PASSED",
         f"F1 model {a.model}: both runs ALL TESTS PASSED")
    same_g1 = r["cycles"] is not None and r["cycles"] == g["cycles"] and r["sram_reads"] == g["sram_reads"] and \
        (ref is None or (ref["cycles"] == r["cycles"] and ref["sram_reads"] == r["sram_reads"]))
    gate(same_g1, f"F1 model {a.model}: cycles and SRAM reads equal in the RTL run, the gate run and E8.5")
    e82 = md5(a.e82_trace)
    for lab, p in (("RTL", a.rtl_e8trace), ("gate", a.gate_e8trace)):
        gate(md5(p) == e82, f"F2 E8.2 monitor trace of the {lab} run = E8.2 trace ({md5(p)} / {e82})")
    e85 = md5(a.e85_trace)
    for lab, p in (("RTL", a.rtl_trace), ("gate", a.gate_trace)):
        gate(md5(p) == e85, f"F3 trace at the datapath start of the {lab} run = E8.5 trace ({md5(p)} / {e85})")
    rr, rc, rph, rside = reads_of(a.rtl_reads)
    gr, gc, gph, gside = reads_of(a.gate_reads)
    print(f"   ROM macro reads: RTL {len(rr)} {rph} sides {rside}; gate {len(gr)} {gph} sides {gside}")
    gate(rr == gr, "F4 every ROM macro read (time, side, lane, macro, address, clock-low time) the same in both runs")
    if rr == gr:
        off = collections.Counter(gc[k] - rc[k] for k in rr)
        print(f"   cycle number written with a read, gate minus RTL (the same time; only the order of events "
              f"within the time step differs): {dict(sorted(off.items()))}")
    if a.e85_summary and os.path.isfile(a.e85_summary):
        s = json.load(open(a.e85_summary))
        exp = [s["macro_reads_lookup_sram_pcm"][i] + s["macro_reads_parking_sram_pcm"][i] for i in (0, 1)]
        gate(rside == exp and gside == exp, f"F4 reads per side = E8.5 summary (lookup + parking) {exp}")
    # The unit's four counters count only in simulation (`ifndef SYNTHESIS in rtl/e8/amu_core.v): the netlist
    # has them tied to 0. So: RTL run 0 stall cycles; error flags 000 in both runs; gate-run counters 0.
    gate(r["counters"] is not None and g["counters"] is not None and r["counters"][1] == "0" and
         r["counters"][4] == "000" and g["counters"][4] == "000" and g["counters"][:4] == ("0", "0", "0", "0"),
         "F4 RTL run 0 stall cycles; error flags 000 in both runs; the gate run's counters 0 (they count only in "
         "simulation, `ifndef SYNTHESIS in rtl/e8/amu_core.v, so the netlist has them tied to 0)")
    lows = [int(x.split()[-1]) for x in rr]
    lk = [int(x.split()[-1]) for x in gr]
    if lows and lk:
        print(f"   shortest clock low before a read: RTL {min(lows) / 1000:.1f} ns, gate {min(lk) / 1000:.1f} ns")
    for lab, f in (("RTL", r), ("gate", g)):
        gate(f["protocol"] is not None and f["protocol"][:4] == (0, 0, 0, 0) and f["protocol"][4] >= 50000,
             f"F4 {lab} run: ROM protocol errors 0 / 0 / 0, every model has its data, clock low >= 50 ns "
             f"({f['protocol']})")
    print(f"   {'all checks pass' if bad == 0 else f'{bad} CHECK(S) FAILED'} (model {a.model})")
    return 0 if bad == 0 else 1


# ------------------------------------------------------------------ vcd
def cmd_vcd(a):
    keep_types = {"wire", "reg"}
    ids_keep, ids_drop, types = set(), set(), {}
    n_lines = n_val = n_drop = 0
    t0 = None
    t_last = 0
    with open(a.inp, errors="replace") as fi, open(a.out, "w") as fo:
        in_hdr = True
        for ln in fi:
            n_lines += 1
            if in_hdr:
                s = ln.strip()
                if s.startswith("$var"):
                    p = s.split()
                    types[p[1]] = types.get(p[1], 0) + 1
                    if p[1] in keep_types:
                        ids_keep.add(p[3])
                        fo.write(ln)
                    else:
                        ids_drop.add(p[3])
                    continue
                if s.startswith("$enddefinitions"):
                    in_hdr = False
                    ids_drop -= ids_keep
                fo.write(ln)
                continue
            c = ln[:1]
            if c == "#":
                t = int(ln[1:])
                if t0 is None:
                    t0 = t
                t_last = t
                fo.write(f"#{t - t0}\n")
                continue
            if c == "$":
                fo.write(ln)
                continue
            s = ln.rstrip("\n")
            if not s:
                continue
            if c in "bBrR":
                vid = s.split()[1]
            else:
                vid = s[1:]
            if vid in ids_drop:
                n_drop += 1
                continue
            n_val += 1
            fo.write(ln)
    print(f"   waveform: {a.inp} ({os.path.getsize(a.inp)} bytes, {n_lines} lines)")
    print(f"   variables by type: {types}; kept {len(ids_keep)} identifiers (wire, reg), dropped "
          f"{len(ids_drop)} (other types) and their {n_drop} value changes; {n_val} value changes kept")
    print(f"   window: first time {t0}, last time {t_last} (file time unit), {t_last - (t0 or 0)} long; shifted to 0")
    print(f"   written: {a.out} ({os.path.getsize(a.out)} bytes)")
    json.dump({"t0": t0, "t_last": t_last, "window": t_last - (t0 or 0), "types": types, "kept_ids": len(ids_keep),
               "dropped_ids": len(ids_drop), "values_kept": n_val, "values_dropped": n_drop},
              open(a.out + ".json", "w"), indent=1)
    return 0 if t0 is not None and n_val > 0 else 1


# ------------------------------------------------------------------ power
def cmd_power(a):
    t = open(a.log, errors="replace").read()
    win = json.load(open(a.window_json))
    unit_s = {"1fs": 1e-15, "1ps": 1e-12, "10ps": 1e-11, "100ps": 1e-10, "1ns": 1e-9}
    m = re.search(r"\$timescale\s+(\S+)", open(a.vcd, errors="replace").read(1 << 16))
    unit = m.group(1) if m else ""
    if unit not in unit_s:
        print(f"   unknown time unit of the waveform: '{unit}'")
        return 1
    window_s = win["window"] * unit_s[unit]
    # "Annotated N pin activities." (read_vcd); else the "vcd N" line of report_activity_annotation
    m = re.search(r"Annotated (\d+) pin activities", t) or re.search(r"^\s*vcd\s+(\d+)\s*$", t, re.M)
    ann = int(m.group(1)) if m else None
    m = re.search(r"unannotated\s+(\d+)", t)
    unann = int(m.group(1)) if m else None
    if ann is None:
        print("   the number of annotated pins was not found in the OpenSTA log (the wording differs by version): "
              "P1 cannot be judged; please send the log")
    m = re.search(r"FLIPFLOP_COUNT (\d+)", t)
    ffs = int(m.group(1)) if m else None
    groups = {}
    for g in ("Sequential", "Combinational", "Clock", "Macro", "Pad", "Total"):
        m = re.search(rf"^{g}\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)", t, re.M)
        if m:
            groups[g] = [float(x) for x in m.groups()]
    top_of, orig = {}, {}
    if a.names and os.path.isfile(a.names):
        for ln in open(a.names):
            p = ln.split()
            if len(p) == 4 and p[1] == "cell":
                top_of[p[0]], orig[p[0]] = p[3], p[2]
    inst = {}
    for m in re.finditer(r"^\s*([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+(\S+)\s*$", t, re.M):
        inst[m.group(5)] = [float(m.group(i)) for i in range(1, 5)]
    tot = groups.get("Total", [0, 0, 0, 0])[3]
    e_uj = tot * window_s * 1e6
    print(f"   window {win['window']} x {unit} = {window_s * 1e3:.6f} ms; flip-flops {ffs}; annotated pins {ann}"
          f"{'' if unann is None else f', unannotated {unann}'}")
    print(f"   {'group':<14} {'internal W':>12} {'switching W':>12} {'leakage W':>12} {'total W':>12} {'energy uJ':>10}")
    for g, v in groups.items():
        print(f"   {g:<14} {v[0]:12.6e} {v[1]:12.6e} {v[2]:12.6e} {v[3]:12.6e} {v[3] * window_s * 1e6:10.4f}")
    by_top = {}
    if inst:
        for k, v in inst.items():
            tp = top_of.get(k, "(not in the name list)")
            if re.match(r"tab\[\d+\]\.U_PTAB$", tp):
                tp = "tab[*].U_PTAB (25 PCM-side tables)"
            elif re.match(r"tab\[\d+\]\.U_STAB$", tp):
                tp = "tab[*].U_STAB (25 SRAM-side tables)"
            s = by_top.setdefault(tp, [0.0, 0.0, 0.0, 0.0, 0])
            for i in range(4):
                s[i] += v[i]
            s[4] += 1
        s_all = sum(v[3] for v in by_top.values())
        print(f"   cells reported {len(inst)}; their total {s_all:.6e} W ({100 * s_all / tot if tot else 0:.2f} % of "
              f"the Total line); by top-level instance of the unit:")
        print(f"      {'instance':<38} {'cells':>6} {'internal W':>12} {'switching W':>12} {'leakage W':>12} "
              f"{'total W':>12} {'energy uJ':>9}")
        for k, v in sorted(by_top.items(), key=lambda x: -x[1][3]):
            print(f"      {k:<38} {v[4]:6d} {v[0]:12.6e} {v[1]:12.6e} {v[2]:12.6e} {v[3]:12.6e} "
                  f"{v[3] * window_s * 1e6:9.4f}")
    print(f"   ENERGY of the address-map unit logic per inference (the ROM macros not included): {e_uj:.4f} uJ")
    json.dump({"window_s": window_s, "annotated_pins": ann, "unannotated": unann, "flipflops": ffs, "groups_W": groups,
               "by_top_level_instance_W": by_top, "cells_reported": len(inst), "energy_uJ": e_uj},
              open(a.out, "w"), indent=1)
    exp_pins = None
    if a.names and os.path.isfile(a.names + ".json"):
        exp_pins = json.load(open(a.names + ".json")).get("pin_bits")
        print(f"   annotated pins {ann} of {exp_pins} pin bits of the netlist (every cell pin and port bit): "
              f"{'all' if ann == exp_pins else 'NOT all'}")
    ok = ann is not None and ann > 0 and tot > 0 and (unann is None or unann == 0) and "Sequential" in groups \
        and groups["Sequential"][0] > 0 and (exp_pins is None or ann == exp_pins)
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("netlists")
    p.add_argument("--hier", required=True)
    p.add_argument("--flat", required=True)
    p.add_argument("--stat-hier", required=True)
    p.add_argument("--stat-flat", required=True)
    p.add_argument("--model", required=True, choices=["A", "B"])
    p.add_argument("--sim-out", required=True)
    p.add_argument("--sta-out", required=True)
    p.add_argument("--map-out", required=True)
    p = sp.add_parser("sim")
    p.add_argument("--model", required=True)
    for x in ("rtl-log", "gate-log", "e82-trace", "rtl-e8trace", "gate-e8trace", "e85-trace", "rtl-trace",
              "gate-trace", "rtl-reads", "gate-reads"):
        p.add_argument(f"--{x}", required=True)
    p.add_argument("--e85-log", default="")
    p.add_argument("--e85-summary", default="")
    p = sp.add_parser("vcd")
    p.add_argument("--in", dest="inp", required=True)
    p.add_argument("--out", required=True)
    p = sp.add_parser("power")
    p.add_argument("--log", required=True)
    p.add_argument("--vcd", required=True)
    p.add_argument("--window-json", required=True)
    p.add_argument("--names", default="")
    p.add_argument("--out", required=True)
    a = ap.parse_args()
    return {"netlists": cmd_netlists, "sim": cmd_sim, "vcd": cmd_vcd, "power": cmd_power}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
