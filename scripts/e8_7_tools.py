#!/usr/bin/env python3
"""
e8_7_tools.py   (P2R-E8.7: energy of the digital logic at gate level; helpers of scripts/e8_7_gate_energy.sh)

Subcommands (each prints what it checked; exit status 1 if a check fails):
  synfiles   the synthesis copy of rtl/synth/layer_desc_rom.v with the model's shift values
             (data/rtl_inputs_<M>_v3/rshift_per_layer.hex) written in place of the $readmemh that
             scripts/preprocess_synth_rtl.py strips; check S0
  stage3     from the mapped hierarchical netlist (Yosys stage 2): the list of black boxes (memory
             macros) with their flattened names, parameters and ports, and the Yosys script of stage 3
             (flatten, every black box turned into ports of the logic, the ports renamed bb<k>_<port>)
  core       after stage 3: plain names (cells c<k>, nets n<k>, name list kept), the logic netlist
             (module <top>_core), the wrapper for simulation (module <top>: the logic plus the memory
             models, with the parameters of the black boxes), check E1
  ctsfree    the netlist for simulation: the logic netlist with the non-inverting buffers between the
             clock net and the clock pins removed (their nets joined), so that a zero-delay simulation does
             not see the clock arrive at different delta cycles; check C1
  streams    the RTL run against the gate-level run (stream files of rtl/e8/tb/tb_e87_chip.v); check F2
  power      energy per inference from the OpenSTA power report of the logic netlist, by part
  judge      all checks of one model (S0, S1, E1, C1, F1, F2, A1), and the summary
"""
import argparse
import collections
import hashlib
import json
import os
import re
import sys

# ------------------------------------------------------------------ common
def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def unesc(s):
    return s[1:] if s.startswith("\\") else s


ID = r"(?:\\\S+|[A-Za-z_][\w$]*)"
INST_RE = re.compile(rf"^\s*({ID})\s*(#\((?:[^()]|\([^()]*\))*\))?\s*({ID})\s*\(", re.M)
MOD_RE = re.compile(rf"^module\s+({ID})\s*\((.*?)^endmodule", re.M | re.S)
STRUCT_TOK = re.compile(r"/\*.*?\*/|//[^\n]*|\"(?:[^\"\\\n]|\\.)*\"|\\\S+|[A-Za-z_][\w$]*"
                        r"|\d+'[sS]?[bodhBODH][0-9a-fA-FxXzZ_?]+|\d+|[(){}\[\]:,;.#=]|\S", re.S)
KEYW = {"module", "endmodule", "input", "output", "inout", "wire", "reg", "assign", "signed", "parameter",
        "localparam", "integer", "always", "initial", "begin", "end"}


def modules_of(text):
    """{module: [(type, instance name, parameter text), ...]} of a structural netlist"""
    mods = {}
    for m in MOD_RE.finditer(text):
        insts = [(unesc(a), unesc(c), b or "") for a, b, c in INST_RE.findall(m.group(2)) if a not in KEYW]
        mods[unesc(m.group(1))] = insts
    return mods


def expand(mods, top):
    """leaf cells under top: {flat name: (type, parameter text, parent module, path)}"""
    out = {}

    def rec(mod, path):
        for typ, nm, par in mods[mod]:
            p = path + [nm]
            if typ in mods:
                rec(typ, p)
            else:
                out[".".join(p)] = (typ, par, mod, p)

    rec(top, [])
    return out


class _Mod:
    def __init__(self, ports):
        self.ports, self.rng, self.dirs, self.assigns, self.insts = ports, {}, {}, [], []


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
    """modules of a structural netlist: ports, net ranges and port directions, assigns, instances"""
    text = re.sub(r"^\s*`[^\n]*", "", text, flags=re.M)                 # compiler directives
    toks = [t for t in STRUCT_TOK.findall(text) if not (t.startswith("/*") or t.startswith("//"))]
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
            ports = [unesc(x) for x in toks[i + 3:j - 1] if x not in (",", "(", ")")]
            cur = mods[name] = _Mod(ports)
            i = j + 1
        elif t == "endmodule":
            cur, i = None, i + 1
        elif t in ("parameter", "localparam"):
            i = upto(i, ";") + 1
        elif t in ("input", "output", "inout", "wire", "reg"):
            kind = t
            i += 1
            if toks[i] == "signed":
                i += 1
            rng = (0, 0, True)
            if toks[i] == "[":
                rng = (int(toks[i + 1]), int(toks[i + 3]), False)
                i += 5
            while toks[i] != ";":
                if toks[i] != ",":
                    nm = unesc(toks[i])
                    cur.rng.setdefault(nm, rng)
                    if kind in ("input", "output", "inout"):
                        cur.dirs[nm] = kind
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
            i += 2
            conns = {}
            while toks[i] != ")":
                if toks[i] == ",":
                    i += 1
                    continue
                pin = toks[i + 1]
                depth, j = 1, i + 3
                while depth:
                    depth += {"(": 1, ")": -1}.get(toks[j], 0)
                    j += 1
                conns[pin] = toks[i + 3:j - 1]
                i = j
            cur.insts.append((typ, name, conns))
            i += 2
    return mods


def _bits(tk, mod, path):
    """MSB-first bit list of an expression: ((path, net, index) | ("const", v))"""
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


def connectivity(mods, top, leaf_pins=None):
    """union-find over every leaf-cell pin bit (flat cell name, pin, bit from the LSB) and every
    top-level port bit ("PORT", name, bit); returns (pins [(pin, node)], find, union)"""
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
    return pins, find, union


def partition(pins, find):
    """{pin: smallest pin of its net}; the constant nets are kept apart by value"""
    groups = collections.defaultdict(list)
    for pin, node in pins:
        groups[find(node)].append(pin)
    rep = {}
    for g in groups.values():
        r = min(g)
        for p in g:
            rep[p] = r
    return rep, len(groups)


def stub_modules(paths):
    """black-box modules of the stub files (ANSI headers): {name: {"params": {name: default text},
    "ports": [(port, direction, msb text, lsb text)]}}"""
    out = {}
    for p in paths:
        t = open(p).read()
        t = re.sub(r"/\*.*?\*/|\(\*.*?\*\)|//[^\n]*", " ", t, flags=re.S)
        for mo in re.finditer(r"\bmodule\s+(\w+)\s*(?:#\s*\((.*?)\))?\s*\((.*?)\)\s*;", t, re.S):
            params = {}
            for item in (mo.group(2) or "").split(","):
                m2 = re.match(r"\s*parameter\s+(?:integer\s+)?(\w+)\s*=\s*(.+?)\s*$", item, re.S)
                if m2:
                    params[m2.group(1)] = m2.group(2)
            ports = []
            for item in mo.group(3).split(","):
                m3 = re.match(r"\s*(input|output|inout)\s+(?:wire\s+|reg\s+)?(?:signed\s+)?"
                              r"(?:\[\s*([^:\]]+?)\s*:\s*([^\]]+?)\s*\]\s*)?(\w+)\s*$", item, re.S)
                if not m3:
                    raise ValueError(f"{p}: port declaration not understood: {item.strip()!r}")
                ports.append((m3.group(4), m3.group(1), m3.group(2) or "0", m3.group(3) or "0"))
            out[mo.group(1)] = {"params": params, "ports": ports}
    return out


def _num(v):
    """value of a parameter as written by Yosys (32'sd25, 5, \"text\") or in a stub (25, \"\")"""
    v = v.strip()
    m = re.fullmatch(r"\d+'s?([dhbo])([0-9a-fA-F_]+)", v)
    if m:
        return int(m.group(2).replace("_", ""), {"d": 10, "h": 16, "b": 2, "o": 8}[m.group(1)])
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    return None


def port_widths(stub, par_text):
    """[(port, direction, width)] of one black-box instance, its parameters applied"""
    vals = {k: _num(v) for k, v in stub["params"].items()}
    for k, v in re.findall(r"\.(\w+)\s*\(\s*([^()]*?)\s*\)", par_text or ""):
        n = _num(v)
        if n is not None:
            vals[k] = n
    env = {k: v for k, v in vals.items() if v is not None}
    out = []
    for nm, d, msb, lsb in stub["ports"]:
        a = eval(msb, {"__builtins__": {}}, env)
        b = eval(lsb, {"__builtins__": {}}, env)
        out.append((nm, d, abs(a - b) + 1))
    return out


# ------------------------------------------------------------------ synfiles (S0)
def read_memh(path, n, width_bits):
    mem = [None] * n
    addr = 0
    for ln in open(path):
        ln = ln.split("//")[0]
        for tok in ln.split():
            if tok.startswith("@"):
                addr = int(tok[1:], 16)
                continue
            if addr >= n:
                raise ValueError(f"{path}: more than {n} words")
            v = int(tok.replace("_", ""), 16)
            if v >= 1 << width_bits:
                raise ValueError(f"{path}: word {tok} wider than {width_bits} bits")
            mem[addr] = v
            addr += 1
    return mem


def cmd_synfiles(a):
    src = os.path.join(a.paper2, "rtl", "synth", "layer_desc_rom.v")
    hexf = os.path.join(a.paper2, "data", f"rtl_inputs_{a.model}_v3", "rshift_per_layer.hex")
    rtl = os.path.join(a.paper2, "rtl", "src", "layer_desc_rom.v")
    print(f"P2R-E8.7 synthesis copy of layer_desc_rom, model {a.model}")
    for nm, p in (("rtl/synth copy", src), ("rtl/src", rtl), ("shift values", hexf)):
        print(f"   {nm:<15}: {md5(p)}  {p}")
    vals = read_memh(hexf, 5, 8)
    if any(v is None for v in vals):
        print(f"   FAIL S0: {hexf} has fewer than 5 values: {vals}")
        return 1
    t = open(src, encoding="utf-8").read()
    r = open(rtl, encoding="utf-8").read()
    ok_src = '$readmemh({DATA_DIR, "/rshift_per_layer.hex"}, rshift_table);' in r
    marker = "/* $readmemh(...) stripped */"
    n = t.count(marker)
    new = "".join(f"rshift_table[{k}] = 8'h{v:02x}; " for k, v in enumerate(vals))
    out = t.replace(marker, new + "/* E8.7: the values of rshift_per_layer.hex, loaded by $readmemh in rtl/src */")
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    open(a.out, "w", encoding="utf-8").write(out)
    # the copy differs from rtl/synth only on that line
    d = [(x, y) for x, y in zip(t.splitlines(), out.splitlines()) if x != y]
    ok = ok_src and n == 1 and len(d) == 1 and len(t.splitlines()) == len(out.splitlines())
    print(f"   shift values per layer (conv1 pool1? as rtl/src indexes them 0..4): "
          f"{' '.join(str(v) for v in vals)} (default in the netlist of E3: 8 for every layer)")
    print(f"   rtl/src loads the file with $readmemh: {'yes' if ok_src else 'NO'}; stripped calls in the copy "
          f"of rtl/synth: {n} (1 expected); lines changed: {len(d)} (1 expected)")
    print(f"   written {a.out}  md5 {md5(a.out)}")
    print(f"   {'PASS' if ok else 'FAIL'}  S0 the synthesis copy differs from rtl/synth only by the shift values")
    json.dump({"rshift": vals, "all_eight": all(v == 8 for v in vals), "ok": ok},
              open(a.out + ".json", "w"), indent=1)
    return 0 if ok else 1


# ------------------------------------------------------------------ stage3
SPECIAL = {"u_fbuf": "u_fbuf", "u_bias": "u_bias", "u_imc.U_SPOOL": "u_spool", "u_imc.U_PCB": "u_pcb"}


def cmd_stage3(a):
    n0 = open(a.n0).read()
    stubs = stub_modules(a.stubs)
    mods = modules_of(n0)
    if a.top not in mods:
        print(f"   FAIL: top module {a.top} not in {a.n0}")
        return 1
    leaves = expand(mods, a.top)
    bbs = sorted(f for f, v in leaves.items() if v[0] in stubs)
    other = collections.Counter(v[0] for f, v in leaves.items() if v[0] not in stubs)
    unknown = sorted(t for t in other if not t.startswith("sky130_fd_sc_hd__"))
    print(f"P2R-E8.7 stage 3 script: {a.n0} (md5 {md5(a.n0)})")
    print(f"   {len(mods)} modules; {len(leaves)} leaf cells: {sum(other.values())} standard cells of "
          f"{len(other)} types, {len(bbs)} black boxes "
          f"({', '.join(f'{t} {c}' for t, c in sorted(collections.Counter(leaves[f][0] for f in bbs).items()))})")
    if unknown:
        print(f"   FAIL: leaf cells that are neither standard cells nor black boxes: {unknown[:10]}")
        return 1
    lst = []
    ys = [f"# P2R-E8.7 stage 3 (written by scripts/e8_7_tools.py stage3)",
          f"read_liberty -lib {a.lib}"]
    for p in a.stubs:
        ys.append(f"read_verilog -sv {p}")
    ys += [f"read_verilog {a.n0}", f"hierarchy -top {a.top}", "flatten",
           "expose -evert " + " ".join(f"t:{t}" for t in sorted({leaves[f][0] for f in bbs})),
           f"cd {a.top}"]
    for k, f in enumerate(bbs):
        typ, par, parent, path = leaves[f]
        name = SPECIAL.get(f, f"bb{k:04d}")
        ports = port_widths(stubs[typ], par)
        lst.append({"k": k, "flat": f, "type": typ, "params": par, "inst": name,
                    "ports": [{"name": p, "dir": d, "width": w} for p, d, w in ports]})
        for p, d, w in ports:
            ys.append(f"rename \\{f}.{p} bb{k:04d}_{p}")
    ys += ["cd ..",
           "opt_clean -purge",
           f"hilomap -singleton -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO",
           "splitnets",
           "insbuf -buf sky130_fd_sc_hd__buf_4 A X",
           f"rename {a.top} {a.top}_core",
           f"tee -o {a.out_dir}/stat_core.txt stat -liberty {a.lib}",
           f"write_verilog -noattr -norename -simple-lhs {a.out_dir}/core_raw.v"]
    os.makedirs(a.out_dir, exist_ok=True)
    open(os.path.join(a.out_dir, "stage3.ys"), "w").write("\n".join(ys) + "\n")
    top = parse_struct(n0)[a.top]
    tports = [{"name": p, "dir": top.dirs.get(p, "input"), "width": abs(top.rng[p][0] - top.rng[p][1]) + 1,
               "msb": top.rng[p][0], "lsb": top.rng[p][1], "scalar": top.rng[p][2]} for p in top.ports]
    json.dump({"top": a.top, "n0": a.n0, "n0_md5": md5(a.n0), "top_ports": tports, "black_boxes": lst,
               "std_cells": sum(other.values()), "std_cells_by_type": dict(other)},
              open(os.path.join(a.out_dir, "bb.json"), "w"), indent=1)
    print(f"   written {a.out_dir}/stage3.ys ({len(ys)} lines) and bb.json")
    return 0


# ------------------------------------------------------------------ core (E1)
TOKEN_RE = re.compile(r'/\*.*?\*/|"(?:[^"\\\n]|\\.)*"|\\\S+|[A-Za-z_][\w$]*|[^"\\/A-Za-z_]+|.', re.S)


def cmd_core(a):
    info = json.load(open(a.bb))
    top = info["top"]
    core = f"{top}_core"
    raw = open(a.raw).read()
    print(f"P2R-E8.7 logic netlist and wrapper: {a.raw} (md5 {md5(a.raw)})")
    rmods = parse_struct(raw)
    if list(rmods) != [core]:
        print(f"   FAIL: expected one module {core}, found {list(rmods)[:5]}")
        return 1
    m = rmods[core]
    ports = set(m.ports)
    # plain names: every cell c<k>, every net that is not a port n<k>
    cells = [(t, n) for t, n, _ in m.insts]
    if len({n for _, n in cells}) != len(cells):
        print("   FAIL: duplicate cell names")
        return 1
    cname = {n: f"c{k}" for k, (_, n) in enumerate(cells)}
    nets = sorted(x for x in m.rng if x not in ports)
    nname = {x: f"n{k}" for k, x in enumerate(nets)}
    clash = [x for x in list(cname.values()) + list(nname.values()) if x in ports]
    if clash:
        print(f"   FAIL: new names equal to port names: {clash[:5]}")
        return 1
    toks = TOKEN_RE.findall(raw)
    if "".join(toks) != raw:
        print("   FAIL: the tokens do not give back the text")
        return 1
    out = []
    for tk in toks:
        if tk.startswith("/*") or tk.startswith('"'):
            out.append(tk)
            continue
        nm = unesc(tk)
        if nm in cname and nm not in nname:
            out.append(cname[nm] + (" " if tk.startswith("\\") else ""))
        elif nm in nname:
            out.append(nname[nm] + (" " if tk.startswith("\\") else ""))
        elif tk.startswith("\\") and nm in ports:
            out.append(tk)
        else:
            out.append(tk)
    plain = "".join(out)
    both = set(cname) & set(nname)
    if both:
        print(f"   note: {len(both)} names are both a cell and a net; renamed as nets in connections")
    # write cell renaming: the instance name token follows the type; redo the instance names explicitly
    pmods = parse_struct(plain)
    pm = pmods[core]
    # instance names: map back by order (parse order = text order)
    if len(pm.insts) != len(cells):
        print("   FAIL: cell count changed by the renaming")
        return 1
    fix = {}
    for (t0, n0), (t1, n1, _) in zip(cells, pm.insts):
        if t0 != t1:
            print(f"   FAIL: cell order changed ({t0} vs {t1})")
            return 1
        if n1 != cname[n0]:
            fix[n1] = cname[n0]
    if fix:
        # instance names that were renamed as nets (a name used for a cell and a net): rename the instance
        def _fix_inst(mo):
            return mo.group(1) + fix.get(mo.group(2), mo.group(2)) + mo.group(3)
        plain = re.sub(r"^(\s*\S+\s+)(\S+)(\s*\()", _fix_inst, plain, flags=re.M)
        pm = parse_struct(plain)[core]
    # the netlist reader of OpenROAD (OpenSTA) does not take "signed" in a declaration (STA-0171 syntax
    # error); in a netlist of cells it changes no connection (lenet5_top: input signed image_data)
    plain, n_signed = re.subn(r"^(\s*(?:input|output|inout|wire|reg))\s+signed\b", r"\1", plain, flags=re.M)
    print(f"   'signed' removed from {n_signed} declarations (the netlist reader of OpenROAD does not take it)")
    open(a.core_out, "w").write(plain)
    with open(a.names_out, "w") as fh:
        fh.write("# P2R-E8.7 plain names: new kind original\n")
        for (t, n) in cells:
            fh.write(f"{cname[n]} cell {n} {t}\n")
        for x in nets:
            fh.write(f"{nname[x]} net {x} -\n")
    # wrapper
    tp = info["top_ports"]
    bbs = info["black_boxes"]
    # black-box ports that the synthesised netlist leaves unconnected (for example an observability output
    # written ".which_is_write()" in the RTL): stage 3 still gives the logic a port for them, but the wrapper
    # leaves them open on both sides, as the synthesised netlist does, so that it adds no pin (E1)
    n0_text = open(info["n0"]).read()
    n0m = parse_struct(n0_text)
    n0_leaves = expand(modules_of(n0_text), top)
    open_ports = {}
    for b in bbs:
        lf = n0_leaves.get(b["flat"])
        conns = None
        if lf is not None:
            conns = next((c for t, n, c in n0m[lf[2]].insts if n == lf[3][-1] and t == b["type"]), None)
        if conns is None:
            print(f"   FAIL: black box {b['flat']} not found in {info['n0']}")
            return 1
        open_ports[b["k"]] = {p["name"] for p in b["ports"] if not conns.get(p["name"])}
    n_open = sum(len(v) for v in open_ports.values())
    print(f"   black-box ports left open, as in the synthesised netlist: {n_open}"
          + (" (" + ", ".join(f"{b['flat']}.{p}" for b in bbs for p in sorted(open_ports[b['k']]))[:200] + ")"
             if n_open else ""))
    w = [f"// P2R-E8.7 wrapper (written by scripts/e8_7_tools.py core): module {top} = the synthesised",
         f"// logic ({core}, instance core) + the simulation models of the {len(bbs)} memory macros it connects to.",
         f"// The parameters of every macro are those of the synthesised netlist, except DATA_DIR and COMMON_DIR,",
         f"// which come from this module (the testbench sets them for the model).",
         "`timescale 1ns/1ps",
         f"module {top}(" + ", ".join(p["name"] for p in tp) + ");",
         '    parameter DATA_DIR = "";', '    parameter COMMON_DIR = "";']
    # parameters that the enclosing RTL sets on this module and the logic no longer needs (declared, unused)
    w += [f"    parameter {pn} = 0;" for pn in a.extra_params]
    for p in tp:
        rng = "" if p["scalar"] else f"[{p['msb']}:{p['lsb']}] "
        w.append(f"    {p['dir']} {rng}{p['name']};")
        w.append(f"    wire {rng}{p['name']};")
    for b in bbs:
        for p in b["ports"]:
            if p["name"] in open_ports[b["k"]]:
                continue
            w.append(f"    wire " + (f"[{p['width'] - 1}:0] " if p["width"] > 1 else "") + f"bb{b['k']:04d}_{p['name']};")
    conns = [f".{p['name']}({p['name']})" for p in tp]
    for b in bbs:
        conns += [f".bb{b['k']:04d}_{p['name']}()" if p["name"] in open_ports[b["k"]]
                  else f".bb{b['k']:04d}_{p['name']}(bb{b['k']:04d}_{p['name']})" for p in b["ports"]]
    w.append(f"    {core} core (\n        " + ",\n        ".join(conns) + "\n    );")
    n_dd = 0
    stubs_w = stub_modules(a.stubs)
    for b in bbs:
        par = b["params"]
        body = par[2:-1].strip() if par.startswith("#(") else ""
        for pn in ("DATA_DIR", "COMMON_DIR"):
            if pn not in stubs_w[b["type"]]["params"]:
                continue
            body, nd = re.subn(r'\.' + pn + r'\(\s*(?:"[^"]*")?\s*\)', f".{pn}({pn})", body)
            if nd == 0:
                body = (body + ", " if body else "") + f".{pn}({pn})"
            n_dd += 1
        pc = ", ".join(f".{p['name']}()" if p["name"] in open_ports[b["k"]]
                       else f".{p['name']}(bb{b['k']:04d}_{p['name']})" for p in b["ports"])
        w.append(f"    // {b['flat']}")
        w.append(f"    {b['type']} " + (f"#({body}) " if body else "") + f"{b['inst']} ({pc});")
    w.append("endmodule")
    open(a.wrapper_out, "w").write("\n".join(w) + "\n")
    print(f"   cells {len(cells)} -> c<k>, nets {len(nets)} -> n<k>, ports {len(ports)}; "
          f"black boxes {len(bbs)} in the wrapper, DATA_DIR from the wrapper in {n_dd}")
    print(f"   written {a.core_out}  md5 {md5(a.core_out)}")
    print(f"           {a.wrapper_out}  md5 {md5(a.wrapper_out)}")
    print(f"           {a.names_out}  md5 {md5(a.names_out)}")
    # ---- E1: the logic plus the wrapper connect every pin as the hierarchical netlist did
    ok = True
    if a.check:
        stubs = stub_modules(a.stubs)
        hm = n0m
        for nm in stubs:
            hm.pop(nm, None)
        p0, f0, _ = connectivity(hm, top)
        r0, ng0 = partition(p0, f0)
        wm = parse_struct(open(a.wrapper_out).read())
        wm.update(parse_struct(plain))
        p1, f1, u1 = connectivity(wm, top)
        # names back: core.c<k> -> flattened name; wrapper instances -> flattened names
        inv = {cname[n]: n for _, n in cells}
        ctype = {cname[n]: t for t, n in cells}
        binst = {b["inst"]: b["flat"] for b in bbs}
        ties, bufs = {}, {}
        for c, t in ctype.items():
            orig = inv[c]
            if t == "sky130_fd_sc_hd__conb_1" and "hilomap" in orig:
                ties[c] = True
            if t == "sky130_fd_sc_hd__buf_4" and "insbuf" in orig:
                bufs[c] = True
        # tie cells: their outputs are the constants; insbuf buffers: A and X one net
        byc = collections.defaultdict(dict)
        for pin, node in p1:
            if pin[0] != "PORT" and pin[0].startswith("core."):
                byc[pin[0][5:]][(pin[1], pin[2])] = node
        for c in ties:
            for (pn, k), node in byc[c].items():
                u1(node, ("const", "1" if pn == "HI" else "0"))
        for c in bufs:
            u1(byc[c][("A", 0)], byc[c][("X", 0)])
        p1m = []
        for pin, node in p1:
            if pin[0] == "PORT":
                p1m.append((pin, node))
                continue
            c = pin[0]
            if c.startswith("core."):
                cc = c[5:]
                if cc in ties or cc in bufs:
                    continue
                p1m.append(((inv[cc], pin[1], pin[2]), node))
            elif c in binst:
                p1m.append(((binst[c], pin[1], pin[2]), node))
            else:
                p1m.append((pin, node))
        # constants as pins so that both sides keep them apart by value
        r1, ng1 = partition(p1m + [(("CONST", v, 0), ("const", v)) for v in "01"], f1)
        r0c, _ = partition(p0 + [(("CONST", v, 0), ("const", v)) for v in "01"], f0)
        # cells of the hierarchical netlist that the logic no longer has: allowed only if every output
        # of theirs drove nothing but pins of such cells (logic without loads, removed by opt_clean)
        gone = {p[0] for p in set(r0c) - set(r1)}
        members = collections.defaultdict(list)
        for p, r in r0c.items():
            members[r].append(p)
        dead_ok = True
        for p in set(r0c) - set(r1):
            if p[1] in ("X", "Y", "Q", "Q_N", "GCLK", "HI", "LO", "COUT", "SUM"):
                if any(q[0] not in gone for q in members[r0c[p]] if q != p):
                    dead_ok = False
        common = set(r0c) & set(r1)
        # partition of the common pins on each side (smallest common pin of the net)
        def sub(rep):
            m = collections.defaultdict(list)
            for p in common:
                m[rep[p]].append(p)
            out = {}
            for g in m.values():
                r = min(g)
                for p in g:
                    out[p] = r
            return out
        s0, s1 = sub(r0c), sub(r1)
        ok_pins = not (set(r1) - set(r0c)) and dead_ok
        diff = [p for p in common if s0[p] != s1[p]]
        ok = ok_pins and not diff
        if gone:
            print(f"   cells of the synthesised netlist without loads, removed in stage 3: {len(gone)} "
                  f"({', '.join(sorted(gone)[:3])}{' ...' if len(gone) > 3 else ''}); only dead logic: "
                  f"{'yes' if dead_ok else 'NO'}")
        print(f"   E1: hierarchical netlist {len(r0c)} pin bits in {ng0} nets; logic + wrapper {len(r1)} pin bits "
              f"(tie cells {len(ties)} as constants, port buffers {len(bufs)} as wires); no new pins and only dead "
              f"logic removed: {'yes' if ok_pins else 'NO'}; every common pin on the same net: "
              f"{'yes' if not diff else 'NO'}")
        if not ok_pins:
            only0 = sorted(set(r0c) - set(r1))[:5]
            only1 = sorted(set(r1) - set(r0c))[:5]
            print(f"      only in the hierarchical netlist: {only0}")
            print(f"      only in logic + wrapper        : {only1}")
        for p in diff[:5]:
            print(f"      {p}: net of {r0c[p]} before, {r1.get(p)} now")
        print(f"   {'PASS' if ok else 'FAIL'}  E1 logic + wrapper = synthesised netlist (every cell pin and port bit)")
    json.dump({"cells": len(cells), "nets": len(nets), "ports": len(ports), "black_boxes": len(bbs),
               "open_ports": sorted(f"{b['flat']}.{p}" for b in bbs for p in open_ports[b["k"]]),
               "core_md5": md5(a.core_out), "wrapper_md5": md5(a.wrapper_out), "E1": ok if a.check else None},
              open(a.core_out + ".json", "w"), indent=1)
    return 0 if ok else 1


# ------------------------------------------------------------------ ctsfree (C1)
BUF_RE = re.compile(r"^sky130_fd_sc_hd__(clkbuf|buf|clkdlybuf4s\d+|dlygate4sd\d|dlymetal6s\ds)_\d+$")
INV_RE = re.compile(r"^sky130_fd_sc_hd__(clkinv|inv|clkinvlp|bufinv)_\d+$")
ICG_RE = re.compile(r"^sky130_fd_sc_hd__dlclkp_\d+$")
SEQ_RE = re.compile(r"^sky130_fd_sc_hd__(s?e?df\w+|dl\w+)_\d+$")
INST_LINE = re.compile(r"^\s*(sky130_fd_sc_hd__\w+)\s+(\S+)\s*\((.*?)\);", re.M | re.S)
PIN_RE = re.compile(r"\.(\w+)\s*\(\s*([^()]*?)\s*\)")


def cmd_ctsfree(a):
    t = open(a.net).read()
    print(f"P2R-E8.7 netlist for simulation: {a.net} (md5 {md5(a.net)})")
    insts = []
    for mo in INST_LINE.finditer(t):
        pins = dict(PIN_RE.findall(mo.group(3)))
        insts.append((mo.group(1), mo.group(2), pins, mo.start(), mo.end()))
    loads = collections.defaultdict(list)          # net -> [(inst index, pin)]
    drv = {}
    out_pins = {"X", "Y", "Q", "Q_N", "GCLK", "HI", "LO", "COUT", "SUM"}
    for i, (typ, nm, pins, _, _) in enumerate(insts):
        for p, net in pins.items():
            if not net:
                continue
            if p in out_pins:
                drv[net] = (i, p)
            else:
                loads[net].append((i, p))
    # output ports (bit names), e.g. the clock pins of the memories driven from the clock net
    outputs = set()
    for mo in re.finditer(r"^\s*output\s+(\[\s*(\d+)\s*:\s*(\d+)\s*\]\s*)?(\S+?)\s*;", t, re.M):
        if mo.group(1):
            lo, hi = sorted((int(mo.group(2)), int(mo.group(3))))
            outputs.update(f"{mo.group(4)}[{k}]" for k in range(lo, hi + 1))
        else:
            outputs.add(mo.group(4))
    # the clock network: from the port, through buffers, inverters and clock gates
    root_port = a.clock
    alias, removed, kept_inv, dummy, roots, port_alias = {}, [], [], [], [root_port], []
    seen, todo, reached = {root_port}, [root_port], collections.Counter()
    data_use = 0
    while todo:
        net = todo.pop()
        for i, p in loads.get(net, []):
            typ = insts[i][0]
            pins = insts[i][2]
            if BUF_RE.match(typ) and p == "A":
                o = pins.get("X", "")
                if not o or (not loads.get(o) and o not in outputs):
                    dummy.append(i)
                    continue
                removed.append(i)
                alias[o] = net
                if o in outputs:
                    # a clock output of the logic (a memory clock pin): driven from the root net
                    # directly, so that the memory sees the clock in the same delta cycle as the
                    # flip-flops, as in the RTL run
                    port_alias.append(o)
                if o not in seen:
                    seen.add(o)
                    todo.append(o)
            elif INV_RE.match(typ) and p == "A":
                o = pins.get("Y", "")
                if not o or not loads.get(o):
                    dummy.append(i)
                    continue
                kept_inv.append(i)
                if o not in seen:
                    seen.add(o)
                    todo.append(o)
            elif ICG_RE.match(typ) and p == "CLK":
                reached["clock gate"] += 1
                o = pins.get("GCLK", "")
                if o and o not in seen:
                    seen.add(o)
                    roots.append(o)
                    todo.append(o)
            elif SEQ_RE.match(typ) and p in ("CLK", "CLK_N", "GATE", "GATE_N"):
                reached["sequential clock pin"] += 1
            else:
                data_use += 1
                reached[f"other pin ({typ.replace('sky130_fd_sc_hd__', '')}/{p})"] += 1

    def root(n):
        while n in alias:
            n = alias[n]
        return n

    drop = set(removed) | set(dummy)
    pieces, last = [], 0
    n_rew = 0
    for i, (typ, nm, pins, s0, s1) in enumerate(insts):
        pieces.append(t[last:s0])
        last = s1
        if i in drop:
            pieces.append(f"// E8.7 clock-network cell removed for simulation: {typ} {nm}")
            continue
        seg = t[s0:s1]

        def rp(mo):
            nonlocal n_rew
            r = root(mo.group(2))
            if r != mo.group(2):
                n_rew += 1
            return f".{mo.group(1)}({r})"
        pieces.append(PIN_RE.sub(rp, seg))
    pieces.append(t[last:])
    out = "".join(pieces)
    if port_alias:
        k = out.rindex("endmodule")
        out = (out[:k] + "".join(f"  // E8.7: clock output driven from the clock net (its buffer removed)\n"
                                 f"  assign {o} = {root(o)};\n" for o in port_alias) + out[k:])
    # declarations of the joined nets are left as unconnected wires (harmless)
    open(a.out, "w").write(out)
    by_type = collections.Counter(insts[i][0].replace("sky130_fd_sc_hd__", "") for i in removed)
    ok = not kept_inv
    rep = {"removed_buffers": len(removed), "removed_by_type": dict(by_type), "dummy_loads": len(dummy),
           "inverters_kept": len(kept_inv), "roots": len(roots), "clock_gates": reached["clock gate"],
           "sequential_clock_pins": reached["sequential clock pin"],
           "other_pins": {k: v for k, v in reached.items() if k.startswith("other")},
           "pins_reconnected": n_rew, "clock_outputs": port_alias, "net_md5": md5(a.net),
           "out_md5": md5(a.out), "C1": ok}
    json.dump(rep, open(a.out + ".json", "w"), indent=1)
    print(f"   clock network from {root_port}: {len(roots) - 1} clock gates as roots, "
          f"{reached['sequential clock pin']} sequential clock pins, other loads {data_use}")
    print(f"   removed: {len(removed)} buffers ({', '.join(f'{k} {v}' for k, v in sorted(by_type.items()))}), "
          f"{len(dummy)} dummy loads; pins reconnected {n_rew}; inverters kept {len(kept_inv)} (0 expected); "
          f"clock outputs driven from the clock net directly {len(port_alias)}"
          + (f" ({', '.join(port_alias[:6])})" if port_alias else ""))
    for k, v in sorted(rep["other_pins"].items()):
        print(f"      {k}: {v}")
    print(f"   written {a.out}  md5 {md5(a.out)}")
    print(f"   {'PASS' if ok else 'FAIL'}  C1 only non-inverting buffers and dummy loads removed")
    return 0 if ok else 1


# ------------------------------------------------------------------ streams (F2)
def cmd_streams(a):
    print(f"P2R-E8.7 streams: RTL run {a.rtl} against gate-level run {a.gate}")
    ok = True
    res = {}
    for f in ("fbuf.txt", "spool.txt", "pcb.txt", "bias.txt"):
        p0, p1 = os.path.join(a.rtl, f), os.path.join(a.gate, f)
        if not (os.path.exists(p0) and os.path.exists(p1)):
            print(f"   FAIL {f}: missing")
            ok = False
            continue
        n0 = sum(1 for _ in open(p0))
        n1 = sum(1 for _ in open(p1))
        same = md5(p0) == md5(p1)
        res[f] = {"lines_rtl": n0, "lines_gate": n1, "same": same}
        print(f"   {f:<10}: {n0} lines (RTL), {n1} (gate-level); identical: {'yes' if same else 'NO'}")
        if not same:
            ok = False
            for k, (x, y) in enumerate(zip(open(p0), open(p1))):
                if x != y:
                    print(f"      first difference at line {k + 1}: RTL {x.strip()[:100]} | gate {y.strip()[:100]}")
                    break
    rr = {}
    for side, p in (("rtl", a.rtl), ("gate", a.gate)):
        reads, errs, nod = collections.Counter(), 0, 0
        for ln in open(os.path.join(p, "rom.txt")):
            x = ln.split()
            if x[0] == "R":
                reads[(x[1], int(x[3]), int(x[4]), int(x[5]), int(x[6]), x[7])] += 1
            elif x[0] == "E":
                errs += 1
            elif x[0] == "N":
                nod += 1
        rr[side] = (reads, errs, nod)
    same_r = rr["rtl"][0] == rr["gate"][0]
    nr = sum(rr["rtl"][0].values())
    print(f"   rom.txt   : {nr} reads (RTL), {sum(rr['gate'][0].values())} (gate-level); the same reads (phase, time, "
          f"side, lane, macro, address): {'yes' if same_r else 'NO'}; protocol errors {rr['rtl'][1]} / {rr['gate'][1]}; "
          f"macros without data {rr['rtl'][2]} / {rr['gate'][2]}")
    if not same_r:
        d = (rr["rtl"][0] - rr["gate"][0]) + (rr["gate"][0] - rr["rtl"][0])
        for k in sorted(d)[:5]:
            print(f"      differs: {k}")
    ok = ok and same_r and rr["rtl"][1] == 0 and rr["gate"][1] == 0 and rr["gate"][2] == 0
    res["rom"] = {"reads_rtl": nr, "same": same_r, "errors": [rr["rtl"][1], rr["gate"][1]]}
    res["F2"] = ok
    json.dump(res, open(a.out, "w"), indent=1)
    print(f"   {'PASS' if ok else 'FAIL'}  F2 the gate-level run drives every memory as the RTL run")
    return 0 if ok else 1


# ------------------------------------------------------------------ power
GROUP_RE = re.compile(r"^(Sequential|Combinational|Clock|Macro|Pad|Total)\s+([-\d.eE+]+)\s+([-\d.eE+]+)\s+"
                      r"([-\d.eE+]+)\s+([-\d.eE+]+)", re.M)


def parse_report_power(path):
    t = open(path, errors="replace").read()
    g = {}
    for m in GROUP_RE.finditer(t):
        g[m.group(1)] = {"internal": float(m.group(2)), "switching": float(m.group(3)),
                         "leakage": float(m.group(4)), "total": float(m.group(5))}
    return g


def vcd_window(path):
    """first and last time stamp of a VCD file (ns) and its time unit"""
    unit = None
    first = None
    head = []
    with open(path, "rb") as fh:          # the header can be large (one $var per net and cell pin)
        in_head = True
        for raw in fh:
            if in_head:
                if len(head) < 200:
                    head.append(raw.decode(errors="replace"))
                if raw.startswith(b"$enddefinitions"):
                    in_head = False
                continue
            if raw.startswith(b"#"):
                first = int(raw[1:])
                break
    m = re.search(r"\$timescale\s+(\d+)\s*(\w+)\s+\$end", "".join(head))
    if m:
        unit = int(m.group(1)) * {"s": 1e9, "ms": 1e6, "us": 1e3, "ns": 1.0, "ps": 1e-3, "fs": 1e-6}[m.group(2)]
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        fh.seek(max(0, size - (1 << 20)))
        tail = fh.read().decode(errors="replace")
    last = None
    for m3 in re.finditer(r"^#(\d+)", tail, re.M):
        last = int(m3.group(1))
    return first * unit, last * unit, unit


def classify(name, names):
    """part of the design of a cell of the logic netlist (the parts of the energy table: the address-map
    unit, the conv1 cache, the rest of the digital logic)"""
    orig = names.get(name)
    if orig is None:
        return "other"
    if "U_AMU" in orig:
        return "address-map unit"
    if "U_C1CACHE" in orig:
        return "conv1 cache"
    return "rest of the logic"


INST_POW_RE = re.compile(r"^\s*([-\d.eE+]+)\s+([-\d.eE+]+)\s+([-\d.eE+]+)\s+([-\d.eE+]+)\s+(\S+)\s*$", re.M)


def cmd_power(a):
    names = {}
    for ln in open(a.names):
        x = ln.split()
        if len(x) >= 3 and x[1] == "cell":
            names[x[0]] = x[2]
    t0, t1, unit = vcd_window(a.vcd)
    dur_ns = t1 - t0
    print(f"P2R-E8.7 energy, model {a.model}: waveform {t0:.0f} ns to {t1:.0f} ns ({dur_ns / 1e6:.6f} ms)")
    g = parse_report_power(a.rep)
    if "Total" not in g:
        print(f"   FAIL: no Total line in {a.rep}")
        return 1
    e = {k: v["total"] * dur_ns * 1e-9 * 1e6 for k, v in g.items()}      # uJ
    parts = collections.defaultdict(float)
    n_inst = 0
    for mo in INST_POW_RE.finditer(open(a.inst, errors="replace").read()):
        parts[classify(mo.group(5), names)] += float(mo.group(4))
        n_inst += 1
    s = sum(parts.values())
    res = {"window_ns": [t0, t1], "duration_ms": dur_ns / 1e6, "groups_W": g, "energy_uJ": e,
           "parts_W": dict(parts), "instances": n_inst,
           "parts_uJ": {k: v * dur_ns * 1e-9 * 1e6 for k, v in parts.items()},
           "annotation": open(a.ann, errors="replace").read()[-4000:]}
    print(f"   total {g['Total']['total'] * 1e3:.4f} mW -> {e['Total']:.3f} uJ per inference; "
          f"sequential {g.get('Sequential', {}).get('total', 0) * 1e3:.4f} mW, combinational "
          f"{g.get('Combinational', {}).get('total', 0) * 1e3:.4f}, clock {g.get('Clock', {}).get('total', 0) * 1e3:.4f}")
    print(f"   by part ({n_inst} instances, sum {s * 1e3:.4f} mW = report total x {s / g['Total']['total']:.4f}): "
          + ", ".join(f"{k} {v * dur_ns * 1e-9 * 1e6:.3f} uJ" for k, v in sorted(parts.items())))
    json.dump(res, open(a.out, "w"), indent=1)
    return 0


# ------------------------------------------------------------------ judge
def _read(p):
    try:
        return open(p, errors="replace").read()
    except OSError:
        return ""


def _jload(p):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return None


def judge_model(W, M):
    """all checks of one model from the files of its work folder"""
    g, info = {}, {}
    s0 = _jload(os.path.join(W, "syn", "layer_desc_rom.v.json"))
    g["S0"] = bool(s0 and s0.get("ok"))
    if s0:
        info["rshift"] = s0.get("rshift")
    bb = _jload(os.path.join(W, "syn", "bb.json"))
    st = _read(os.path.join(W, "syn", "stat_final.txt"))
    m = re.findall(r"Chip area for (?:top )?module '\\?\S+?': ([\d.]+)", st)
    info["area_synth_um2"] = float(m[-1]) if m else None
    n0 = os.path.join(W, "syn", "n0.v")
    bad_cells = len(re.findall(r"sky130_fd_sc_hd__(?:lpflow|probe)", _read(n0))) if os.path.exists(n0) else None
    if bb:
        byt = bb.get("std_cells_by_type", {})
        info["cells_synth"] = bb.get("std_cells")
        info["flip_flops_synth"] = sum(v for k, v in byt.items() if re.search(r"__(s?e?df|dl[xr])", k))
        info["clock_gates_synth"] = sum(v for k, v in byt.items() if "dlclkp" in k)
        info["black_boxes"] = len(bb.get("black_boxes", []))
    g["S1"] = bool(bb) and bad_cells == 0 and info.get("black_boxes") == 204
    c = _jload(os.path.join(W, "core.v.json"))
    g["E1"] = bool(c and c.get("E1"))
    cs = _jload(os.path.join(W, "sim", "core_sim.v.json"))
    g["C1"] = bool(cs and cs.get("C1"))
    if cs:
        info["clock_buffers_removed_for_simulation"] = cs.get("removed_buffers")
        info["clock_outputs_direct"] = len(cs.get("clock_outputs", []))
    r0, r1 = _read(os.path.join(W, "rtl_sim.log")), _read(os.path.join(W, "gate_sim.log"))
    d0 = re.findall(r"done seen at cycle (\d+) after the start, predicted_class (\d+)", r0)
    d1 = re.findall(r"done seen at cycle (\d+) after the start, predicted_class (\d+)", r1)
    info["done_rtl"], info["done_gate"] = (d0[-1] if d0 else None), (d1[-1] if d1 else None)
    g["F1"] = "RESULT PASS (golden used)" in r0 and "RESULT PASS (golden used)" in r1 and bool(d0) and d0 == d1
    s = _jload(os.path.join(W, "streams.json"))
    g["F2"] = bool(s and s.get("F2"))
    # A1: every pin of the logic netlist annotated by the waveform, except the pins of the cells removed
    # for simulation (ctsfree); every port annotated
    removed = set()
    sim = _read(os.path.join(W, "sim", "core_sim.v"))
    for mo in re.finditer(r"// E8.7 clock-network cell removed for simulation: \S+ (\S+)", sim):
        removed.add(mo.group(1))
    t = _read(os.path.join(W, "power", "gate_annotation.rpt"))
    nv = re.findall(r"^vcd\s+(\d+)", t, re.M)
    nu = re.findall(r"^unannotated\s+(\d+)", t, re.M)
    pins = re.findall(r"^ (\S+)$", t.split("Unannotated pins:")[-1], re.M) if "Unannotated pins:" in t else []
    cells = collections.Counter(p.rsplit("/", 1)[0] for p in pins if "/" in p)
    ports = [p for p in pins if "/" not in p]
    a1 = {"vcd": int(nv[-1]) if nv else None, "unannotated": int(nu[-1]) if nu else None,
          "unannotated_cells": len(cells), "unannotated_ports": len(ports),
          "unannotated_not_removed": sorted(c for c in cells if c not in removed)[:20]}
    info["annotation"] = a1
    g["A1"] = a1["vcd"] is not None and not a1["unannotated_not_removed"] and a1["unannotated_ports"] == 0
    pw = _jload(os.path.join(W, "power.json"))
    if pw:
        info["energy_uJ"] = pw.get("energy_uJ", {}).get("Total")
        info["energy_parts_uJ"] = pw.get("parts_uJ")
        info["duration_ms"] = pw.get("duration_ms")
    return g, info


def cmd_judge(a):
    out = {"models": {}}
    allok = True
    names = {"S0": "synthesis copy of layer_desc_rom with the shift values",
             "S1": "synthesis: no lpflow or probe cells, all 204 black boxes present",
             "E1": "logic + wrapper = synthesised netlist",
             "C1": "only non-inverting buffers on the clock net removed for simulation",
             "F1": "RTL and gate-level runs PASS (golden layers, class), same done cycle",
             "F2": "every memory driven as in the RTL run",
             "A1": "every pin annotated by the waveform except those of the cells removed for simulation"}
    for M in a.models:
        W = os.path.join(a.work, M)
        g, info = judge_model(W, M)
        out["models"][M] = {"gates": g, "info": info}
        print(f"==== model {M}")
        for k in ("S0", "S1", "E1", "C1", "F1", "F2", "A1"):
            print(f"   {'PASS' if g[k] else 'FAIL'}  {k} {names[k]}")
            if not g[k]:
                allok = False
        for k, v in info.items():
            print(f"   {k}: {v}")
    out["all_pass"] = allok
    json.dump(out, open(a.out, "w"), indent=1)
    print(f"   {'ALL PASS' if allok else 'NOT ALL PASS'}; written {a.out}")
    return 0 if allok else 1


# ------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("synfiles")
    s.add_argument("--paper2", required=True)
    s.add_argument("--model", required=True, choices=["A", "B"])
    s.add_argument("--out", required=True)
    s = sp.add_parser("stage3")
    s.add_argument("--n0", required=True)
    s.add_argument("--stubs", nargs="+", required=True)
    s.add_argument("--top", required=True)
    s.add_argument("--lib", required=True)
    s.add_argument("--out-dir", required=True)
    s = sp.add_parser("core")
    s.add_argument("--bb", required=True)
    s.add_argument("--raw", required=True)
    s.add_argument("--stubs", nargs="+", required=True)
    s.add_argument("--core-out", required=True)
    s.add_argument("--wrapper-out", required=True)
    s.add_argument("--names-out", required=True)
    s.add_argument("--check", action="store_true")
    s.add_argument("--extra-params", nargs="*", default=[],
                   help="parameters set on the module by the RTL around it, declared in the wrapper (unused)")
    s = sp.add_parser("ctsfree")
    s.add_argument("--net", required=True, help="the logic netlist (core.v)")
    s.add_argument("--out", required=True)
    s.add_argument("--clock", default="clk")
    s = sp.add_parser("streams")
    s.add_argument("--rtl", required=True)
    s.add_argument("--gate", required=True)
    s.add_argument("--out", required=True)
    s = sp.add_parser("power")
    s.add_argument("--model", required=True)
    s.add_argument("--names", required=True)
    s.add_argument("--vcd", required=True)
    s.add_argument("--rep", required=True, help="report_power of the logic netlist")
    s.add_argument("--inst", required=True, help="report_power -instances")
    s.add_argument("--ann", required=True, help="report_activity_annotation -report_unannotated")
    s.add_argument("--out", required=True)
    s = sp.add_parser("judge")
    s.add_argument("--work", required=True)
    s.add_argument("--models", nargs="+", required=True)
    s.add_argument("--out", required=True)
    a = ap.parse_args()
    return {"synfiles": cmd_synfiles, "stage3": cmd_stage3, "core": cmd_core, "ctsfree": cmd_ctsfree,
            "streams": cmd_streams, "power": cmd_power, "judge": cmd_judge}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
