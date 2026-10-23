#!/usr/bin/env python3
"""
e8_4c_sram_bench.py   (P2R-E8.4c: read energy of the protected-weight SRAM macro by the method of E8.4)

The address-map ROM energies of E8.4b come from ngspice transients of the extracted macros: the
energy from the supply in every clock cycle, from its rising edge to the next one. This script
does the same for an OpenRAM single-port (1rw) SRAM macro, so that the SRAM item (B) and the
address map (D) of the energy table come from the same method. Netlist parsing, waveform reading
and integration are those of scripts/e8_4_rom_bench.py (imported).

bench    writes an ngspice deck: the macro (generator or extracted netlist, copied with the same
         options as the ROM bench: substrate node tied to ground, OpenRAM junction areas
         corrected, hierarchical node names rewritten), a supply source on vccd1 (vssd1 at 0 V),
         PWL sources on clk0, csb0, web0, spare_wen0, addr0, din0 (inputs change a quarter period
         before the rising edge), a load on every dout0 bit, checkpoints that save the waveforms.
         Sequence tokens: w:<addr>:<hex> write, r:<addr> read, i idle (clock running, csb0 high),
         s:<ns> clock stopped low and csb0 high for <ns> (leakage).
analyze  per cycle: the energy from the supply (rising edge to the next rising edge), the energy
         from the input sources, the supply power just before the next rising edge; for reads
         the word on dout0 at the end of the clock-high half and just before the next rising
         edge against the word written before, and the access time (rising edge to the last
         data bit within 10 % of VDD of its final level). For a stopped segment: the supply
         power at its end.

Usage:
  python3 e8_4c_sram_bench.py bench --sp <netlist> --top <subckt> --models <sky130.lib.spice>
          --corner tt --out <dir> --seq "i i w:0:00 w:17:ff ... r:0 r:17 ... i i s:50"
          [--period 10] [--vdd 1.8] [--temp 25] [--cload 10] [--edge 0.1] [--fix-asad]
          [--sanitize] [--substrate NAME] [--pfet-pass-alias] [--spare-wen-fix] [--threads N] [--uic]
          [--tie-cell-sub] [--tie-float-gates] [--plain-nfet]
  (cd <dir> && ngspice -b tb.sp -o ngspice.log)
  python3 e8_4c_sram_bench.py analyze --dir <dir>

Place  : scripts/
Status : 2026-10-17 v3: --sense-precharge W adds, in the simulation netlist only, a copy of the column
         precharge cell (2 pull-ups, 1 equalizer, pfet W um, L 0.15 um, gate p_en_bar0) on the two inputs of
         every sense amplifier behind the column multiplexer (OpenRAM's sky130 read path leaves them at
         about VDD - Vth; claude/p2r-e8-4c-results.md). v2 md5 8db79a243f19b0e6842e487bd23f7e7d.
         2026-10-16 v2: --tie-cell-sub ties to ground the nodes named '<path>/SUB' (sandbox PDK) or
         '<path>/VSUBS' (KID's PDK) and every other net that reaches transistors only through the body
         terminal of nFETs; a port named as --substrate is connected to ground. v1: md5
         e946262d52409c0b1327ce4e68107127.
"""
import argparse
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("e8bench", os.path.join(HERE, "e8_4_rom_bench.py"))
RB = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(RB)


def bus(ports, base):
    """indices of base[i] ports, in the order of i"""
    found = {}
    for p in ports:
        m = re.match(r"^" + re.escape(base) + r"\[(\d+)\]$", p, re.IGNORECASE) or \
            re.match(r"^" + re.escape(base) + r"_(\d+)$", p, re.IGNORECASE)
        if m:
            found[int(m.group(1))] = p
    return [found[i] for i in sorted(found)]


def parse_seq(s):
    out = []
    for tok in s.split():
        f = tok.split(":")
        if f[0] == "w" and len(f) == 3:
            out.append(("write", int(f[1], 0), int(f[2], 16)))
        elif f[0] == "r" and len(f) == 2:
            out.append(("read", int(f[1], 0), None))
        elif f[0] == "i" and len(f) == 1:
            out.append(("idle", None, None))
        elif f[0] == "s" and len(f) == 2:
            out.append(("stop", None, float(f[1])))
        else:
            sys.exit(f"bad sequence token {tok}")
    return out


def gate_only_nets(path, top):
    """nets of the top subcircuit that reach transistors only through their gates (and capacitors):
    undriven, i.e. floating gates (the OpenRAM sky130 dummy cells have them by design)"""
    lines, ports, cur = [], set(), None
    with open(path, errors="replace") as fh:
        for raw in fh:
            if raw.startswith("+") and lines:
                lines[-1] += " " + raw[1:].strip()
            else:
                lines.append(raw.strip())
    use = {}
    in_top = False
    for l in lines:
        low = l.lower()
        if low.startswith(".subckt"):
            tok = l.split()
            in_top = (tok[1] == top)
            if in_top:
                ports = set(t for t in tok[2:] if "=" not in t)
            continue
        if low.startswith(".ends"):
            in_top = False
            continue
        if not in_top or not l or l[0] not in "Xx":
            continue
        tok = l.split()
        mi = next((i for i, t in enumerate(tok) if t.lower().startswith("sky130_fd_pr__") and "fet" in t.lower()), None)
        if mi is None:
            for t in tok[1:]:
                if "=" not in t:
                    use.setdefault(t, set()).add("other")
            continue
        for k, n in enumerate(tok[1:mi]):
            use.setdefault(n, set()).add("g" if k == 1 else "sdb")
    return sorted(n for n, u in use.items() if u == {"g"} and n not in ports)


def nfet_body_only_nets(path, top):
    """nets of the top subcircuit that reach transistors only through the body terminal (4th node) of nFETs
    (and capacitors): the body of a foundry cell left on its own by the extraction"""
    lines, ports = [], set()
    with open(path, errors="replace") as fh:
        for raw in fh:
            if raw.startswith("+") and lines:
                lines[-1] += " " + raw[1:].strip()
            else:
                lines.append(raw.strip())
    use = {}
    in_top = False
    for l in lines:
        low = l.lower()
        if low.startswith(".subckt"):
            tok = l.split()
            in_top = (tok[1] == top)
            if in_top:
                ports = set(t for t in tok[2:] if "=" not in t)
            continue
        if low.startswith(".ends"):
            in_top = False
            continue
        if not in_top or not l or l[0] not in "Xx":
            continue
        tok = l.split()
        mi = next((i for i, t in enumerate(tok) if t.lower().startswith("sky130_fd_pr__") and "fet" in t.lower()), None)
        if mi is None:
            for t in tok[1:]:
                if "=" not in t:
                    use.setdefault(t, set()).add("other")
            continue
        nfet = "nfet" in tok[mi].lower()
        for k, n in enumerate(tok[1:mi]):
            use.setdefault(n, set()).add("nbody" if (k == 3 and nfet) else "x")
    return sorted(n for n, u in use.items() if u == {"nbody"} and n not in ports)


SA_IN_RE = re.compile(r"sense_amp_array_\d+/(bl|br)_(\d+)$")


def sense_inputs(path, top):
    """the two inputs of every sense amplifier behind the column multiplexer ('<path>/sense_amp_array_<n>/bl_<k>',
    '.../br_<k>') and the bank's precharge enable ('<path>/p_en_bar0') in the top subcircuit of a flat netlist"""
    pins, pen = {}, set()
    in_top = False
    with open(path, errors="replace") as fh:
        for raw in fh:
            low = raw.lower()
            if low.startswith(".subckt"):
                in_top = (raw.split()[1] == top)
                continue
            if low.startswith(".ends"):
                in_top = False
                continue
            if not in_top or raw[:1] not in "XxCc":
                continue
            for t in raw.split()[1:]:
                if "=" in t:
                    continue
                m = SA_IN_RE.search(t)
                if m:
                    pins.setdefault(int(m.group(2)), {})[m.group(1)] = t
                elif t.endswith("/p_en_bar0") or t == "p_en_bar0":
                    pen.add(t)
    pairs = [(pins[k]["bl"], pins[k]["br"]) for k in sorted(pins) if "bl" in pins[k] and "br" in pins[k]]
    return pairs, sorted(pen)


def copy_netlist(a, path_out, notes):
    """the ROM bench's netlist copy: .end removed, substrate tied to ground outside subckt
    headers, OpenRAM junction areas corrected, node names rewritten; for the SRAM also: the substrate
    nodes of the foundry cells and (optionally) the floating gates tied to ground, device names"""
    asad_re = re.compile(r"(?<![A-Za-z0-9_])(as|ad)=([0-9]*\.?[0-9]+(?:[eE][+-]?[0-9]+)?)u(?![A-Za-z0-9_])",
                         re.IGNORECASE)
    alias_re = re.compile(r"(?<![A-Za-z0-9_])sky130_fd_pr__special_pfet_pass(?![A-Za-z0-9_])", re.IGNORECASE)
    swen_re = re.compile(r"(?<![A-Za-z0-9_])spare_wen0\[0\](?![A-Za-z0-9_\[])", re.IGNORECASE)
    snfet_re = re.compile(r"(?<![A-Za-z0-9_])sky130_fd_pr__special_nfet_01v8(?![A-Za-z0-9_])")
    n_sub = n_asad = n_san = n_alias = n_swen = n_cellsub = n_plain = n_float = n_body = 0
    cellsub_names = set()
    floating = set(gate_only_nets(a.sp, a.top)) if a.tie_float_gates else set()
    body = set(n for n in nfet_body_only_nets(a.sp, a.top) if not n.endswith(("/SUB", "/VSUBS"))) if a.tie_cell_sub else set()
    sub_low = a.substrate.lower() if a.substrate else None
    in_header = False

    def sanitize_line(line):
        tok = line.split()
        if not tok or tok[0][0].upper() not in "XMCRD":
            return line, 0
        c0 = tok[0][0].upper()
        words = [i for i, t in enumerate(tok) if "=" not in t]
        nidx = words[1:-1] if c0 == "X" else (words[1:5] if c0 == "M" else words[1:3])
        changed = 0
        for i in nidx:
            new = tok[i].replace("/", "__").replace("#", "h")
            if new != tok[i]:
                tok[i] = new
                changed += 1
        return " ".join(tok) + "\n", changed

    def tie_tokens(line):
        """whole-token replacements to ground: '<path>/SUB', the substrate node, floating gates"""
        nonlocal n_sub, n_cellsub, n_float, n_body
        tok = line.split()
        if not tok or tok[0][0].upper() not in "XMCRD":
            return line
        changed = False
        for i in range(1, len(tok)):
            t = tok[i]
            if "=" in t:
                continue
            if a.tie_cell_sub and t.endswith(("/SUB", "/VSUBS")):
                cellsub_names.add(t); tok[i] = "0"; n_cellsub += 1; changed = True
            elif t in body:
                tok[i] = "0"; n_body += 1; changed = True
            elif sub_low and t.lower() == sub_low:
                tok[i] = "0"; n_sub += 1; changed = True
            elif t in floating:
                tok[i] = "0"; n_float += 1; changed = True
        return (" ".join(tok) + "\n") if changed else line

    spc_lines = []
    if a.sense_precharge:
        pairs, pen = sense_inputs(a.sp, a.top)
        if not pairs or len(pen) != 1:
            raise SystemExit(f"--sense-precharge: sense-amplifier inputs {len(pairs)} pairs, precharge enables {pen}")
        w = a.sense_precharge
        geo = f"ad={w * 0.29:.4g} pd={2 * (w + 0.29):.4g} as={w * 0.29:.4g} ps={2 * (w + 0.29):.4g} w={w:g} l=0.15"
        vdd_node = a.sense_precharge_vdd
        for k, (bl, br) in enumerate(pairs):
            spc_lines += [f"XE8SPC{k}eq {bl} {pen[0]} {br} {vdd_node} sky130_fd_pr__pfet_01v8 {geo}\n",
                          f"XE8SPC{k}u1 {bl} {pen[0]} {vdd_node} {vdd_node} sky130_fd_pr__pfet_01v8 {geo}\n",
                          f"XE8SPC{k}u2 {br} {pen[0]} {vdd_node} {vdd_node} sky130_fd_pr__pfet_01v8 {geo}\n"]
        notes.append(f"sense-side precharge added (not in the layout): a copy of the column precharge cell (2 pull-ups and "
                     f"1 equalizer, pfet W = {w:g} um, L = 0.15 um) on the inputs of {len(pairs)} sense amplifiers, gate "
                     f"{pen[0]}, {len(spc_lines)} devices")
    top_seen = False
    with open(a.sp, errors="replace") as fi, open(path_out, "w") as fo:
        for line in fi:
            s = line.strip().lower()
            if re.match(r"^\.end\s*$", s):
                notes.append("removed a .end line from the netlist copy")
                continue
            if s.startswith(".subckt") and len(line.split()) > 1 and line.split()[1] == a.top:
                top_seen = True
            if spc_lines and top_seen and s.startswith(".ends"):
                for extra in spc_lines:
                    extra = tie_tokens(extra)
                    if a.sanitize:
                        extra, _ = sanitize_line(extra)
                    fo.write(extra)
                spc_lines = []
                top_seen = False
            if s.startswith(".subckt"):
                in_header = True
            elif not s.startswith("+"):
                in_header = False
            if not in_header and not s.startswith(("*", ".", "+")):
                line = tie_tokens(line)
            if a.fix_asad and not s.startswith("*"):
                line, n = asad_re.subn(r"\1=\2", line)
                n_asad += n
            if a.plain_nfet and not s.startswith("*"):
                line, n = snfet_re.subn("sky130_fd_pr__nfet_01v8", line)
                n_plain += n
            if a.sanitize and not in_header and not s.startswith(("*", ".", "+")):
                line, n = sanitize_line(line)
                n_san += n
            if a.pfet_pass_alias and not s.startswith("*"):
                line, n = alias_re.subn("sky130_fd_pr__special_pfet_latch", line)
                n_alias += n
            if a.spare_wen_fix and not s.startswith("*"):
                line, n = swen_re.subn("spare_wen0", line)
                n_swen += n
            fo.write(line)
    if a.substrate:
        notes.append(f"substrate node {a.substrate} tied to ground in {n_sub} places")
    if a.fix_asad:
        notes.append(f"junction areas corrected (as/ad '<x>u' -> '<x>' um2) in {n_asad} places")
    if a.sanitize:
        notes.append(f"hierarchical node names rewritten ('/' -> '__', '#' -> 'h') in {n_san} places")
    if a.pfet_pass_alias:
        notes.append(f"device name sky130_fd_pr__special_pfet_pass -> sky130_fd_pr__special_pfet_latch in {n_alias} "
                     f"places (the PDK keeps the old name only as a wrapper that ngspice cannot parse)")
    if a.spare_wen_fix:
        notes.append(f"net spare_wen0[0] written as the port spare_wen0 in {n_swen} places (generator netlist: the spare "
                     f"write-enable flip-flop input is otherwise a floating net)")
    if a.tie_cell_sub:
        notes.append(f"substrate nodes of the foundry cells ('<path>/SUB' or '<path>/VSUBS', {len(cellsub_names)} nodes) tied to ground in "
                     f"{n_cellsub} places (p-substrate; the flat extraction leaves one per cell)")
        leaf = {}
        for n in body:
            k = n.rsplit("/", 1)[-1]
            leaf[k] = leaf.get(k, 0) + 1
        notes.append(f"nets reaching transistors only through nFET bodies, other names ({len(body)} nodes; leaf names "
                     + ", ".join(f"{k} {v}" for k, v in sorted(leaf.items(), key=lambda x: -x[1])[:4])
                     + f") tied to ground in {n_body} places")
    if a.tie_float_gates:
        cells = {}
        for n in floating:
            parts = n.split("/")
            c = re.sub(r"_\d+$", "", parts[-2]) if len(parts) > 1 else "(top)"
            cells[c] = cells.get(c, 0) + 1
        notes.append(f"floating gates (nets that reach transistors only through gates: {len(floating)}, in "
                     + ", ".join(f"{c} {k}" for c, k in sorted(cells.items(), key=lambda x: -x[1])[:6])
                     + f") tied to ground in {n_float} places")
    if a.plain_nfet:
        notes.append(f"sky130_fd_pr__special_nfet_01v8 written as sky130_fd_pr__nfet_01v8 in {n_plain} places (as the ROM bench)")
    return floating


def cmd_bench(a):
    subs, _ = RB.parse_netlist(a.sp)
    if a.top not in subs:
        sys.exit(f"top subcircuit {a.top} not in {a.sp}")
    ports = subs[a.top]["ports"]
    din, addr, dout = bus(ports, "din0"), bus(ports, "addr0"), bus(ports, "dout0")
    single = {p.lower(): p for p in ports}
    need = ["clk0", "csb0", "web0", "vccd1", "vssd1"]
    miss = [n for n in need if n not in single]
    if miss or not din or not addr or not dout:
        sys.exit(f"ports not found: {miss or ''} {'din0 ' if not din else ''}{'addr0 ' if not addr else ''}"
                 f"{'dout0' if not dout else ''}")
    sublow = (a.substrate or "").lower()
    other = [p for p in ports if p not in din + addr + dout and p.lower() not in need + ["spare_wen0"]
             and not (sublow and p.lower() == sublow)]
    if other:
        sys.exit(f"ports with no bench connection: {' '.join(other)}")
    os.makedirs(a.out, exist_ok=True)
    notes = []
    copy_netlist(a, os.path.join(a.out, "netlist.sp"), notes)
    if a.uic:
        notes.append("transient started from 0 V on every node with the supply on (uic, no DC operating point)")
    T, tr, vdd = a.period * 1e-9, a.edge * 1e-9, a.vdd
    nd, na = len(dout), len(addr)
    wbits = a.word_bits or nd
    cycles = parse_seq(a.seq)
    sig = {n: [(0.0, 0.0)] for n in ["clk0", "csb0", "web0", "spare_wen0"] +
           [f"a{i}" for i in range(na)] + [f"din{i}" for i in range(len(din))]}

    def put(name, t, v):
        last = sig[name][-1][1]
        if abs(last - v) > 1e-12:
            sig[name].append((t - tr / 2, last))
            sig[name].append((t + tr / 2, v))

    sig["csb0"] = [(0.0, vdd)]
    sig["web0"] = [(0.0, vdd)]
    mem, meta_cycles = {}, []
    t_next = T          # one period of settling before the first cycle
    for k, (kind, ad, val) in enumerate(cycles):
        seg = val * 1e-9 if kind == "stop" else T
        t0 = t_next                      # start of the cycle = its rising edge (50 %)
        t_next = t0 + seg
        tin = t0 - T / 4                 # inputs change a quarter period before the edge
        if kind in ("read", "write"):
            if ad >= 2 ** na:
                sys.exit(f"address {ad} needs more than {na} bits")
            put("csb0", tin, 0.0)
            put("web0", tin, 0.0 if kind == "write" else vdd)
            for i in range(na):
                put(f"a{i}", tin, vdd if (ad >> i) & 1 else 0.0)
            if kind == "write":
                for i in range(len(din)):
                    bit = (val >> i) & 1 if i < wbits else 0
                    put(f"din{i}", tin, vdd if bit else 0.0)
                mem[ad] = val
        else:
            put("csb0", tin, vdd)
            put("web0", tin, vdd)
        if kind != "stop":
            sig["clk0"] += [(t0 - tr / 2, 0.0), (t0 + tr / 2, vdd), (t0 + T / 2 - tr / 2, vdd),
                            (t0 + T / 2 + tr / 2, 0.0)]
        exp = mem.get(ad) if kind == "read" else None
        meta_cycles.append({"k": k, "kind": kind, "addr": ad, "data": (val if kind == "write" else None),
                            "expected": exp, "trise": t0, "tend": t_next, "stop_ns": val if kind == "stop" else None})
    tstop = t_next + T / 4

    def pwl(pts):
        out, lastt = [], -1.0
        for t, v in pts:
            if t <= lastt:
                t = lastt + 1e-13
            out.append(f"{t:.6e} {v:g}")
            lastt = t
        out.append(f"{tstop:.6e} {pts[-1][1]:g}")
        return "PWL(" + " ".join(out) + ")"

    node = {}
    for i, p in enumerate(din):
        node[p] = f"din{i}"
    for i, p in enumerate(addr):
        node[p] = f"a{i}"
    for i, p in enumerate(dout):
        node[p] = f"d{i}"
    for p in ports:
        lp = p.lower()
        if lp in ("clk0", "csb0", "web0", "spare_wen0"):
            node[p] = lp
        elif lp == "vccd1":
            node[p] = "vdd"
        elif lp == "vssd1":
            node[p] = "0"
        elif a.substrate and lp == a.substrate.lower():
            node[p] = "0"        # the substrate node is a port of the extracted macro: ground
    lines = [f"* P2R-E8.4c SRAM bench: {a.top}  period {a.period} ns  vdd {vdd} V",
             f'.lib "{a.models}" {a.corner}', f'.include "{os.path.abspath(os.path.join(a.out, "netlist.sp"))}"',
             f".temp {a.temp}", f"Vvdd vdd 0 {vdd}"]
    srcs = ["clk0", "csb0", "web0"] + (["spare_wen0"] if "spare_wen0" in single else []) + \
           [f"a{i}" for i in range(na)] + [f"din{i}" for i in range(len(din))]
    for s_ in srcs:
        lines.append(f"V{s_} {s_} 0 {pwl(sig[s_])}")
    lines.append("Xsram " + " ".join(node[p] for p in ports) + " " + a.top)
    for i in range(nd):
        lines.append(f"Cd{i} d{i} 0 {a.cload}f")
    tmax = a.tmax * 1e-9 if a.tmax else T / 50
    if a.ic_cells:
        # start every cell resolved: in each pull-down of a latch (special_nfet_latch) one of drain/source is a storage
        # node and the gate is the other one; of the two, the node with the smaller name starts at 0 V, the other at VDD
        pairs = set()
        supplies = {"0", "vccd1", "vssd1", "gnd", "vdd"}
        with open(os.path.join(a.out, "netlist.sp")) as fh:
            for line in fh:
                if not line[:1] in "Xx" or "special_nfet_latch" not in line:
                    continue
                tk = line.split()
                d_, g_, s_ = tk[1], tk[2], tk[3]
                x = s_ if d_.lower() in supplies else (d_ if s_.lower() in supplies else None)
                if x is None or g_.lower() in supplies or x.lower() in supplies:
                    continue
                pairs.add(tuple(sorted((x, g_))))
        ics = []
        for lo, hi in sorted(pairs):
            ics.append(f"v(xsram.{lo})=0 v(xsram.{hi})={vdd}")
        for k in range(0, len(ics), 8):
            lines.append(".ic " + " ".join(ics[k:k + 8]))
        notes.append(f"initial condition on {len(pairs)} storage-node pairs (latch pull-downs): smaller name 0 V, other VDD")
    lines.append(".options klu")
    lines.append(f".tran {min(T / 1000, 10e-12):.3e} {tstop:.6e} 0 {tmax:.3e}" + (" uic" if a.uic else ""))
    probes = []
    if a.probe:
        pats = [re.compile(x + "$") for x in a.probe.split(",") if x]
        seen = set()
        with open(os.path.join(a.out, "netlist.sp")) as fh:
            for line in fh:
                if line[:1] not in "XxCc":
                    continue
                for tk in line.split()[1:]:
                    # skip parameters and device model names; node names of OpenRAM's sky130 macros also begin
                    # with "sky130_" (the macro name), so only the foundry model prefix is skipped
                    if "=" in tk or tk in seen or tk.lower().startswith("sky130_fd_pr__"):
                        continue
                    seen.add(tk)
                    if any(pp.search(tk) for pp in pats):
                        probes.append(tk)
        probes = sorted(probes)[:60]
        notes.append(f"internal nodes saved: {len(probes)}")
    vec = ["v(clk0)", "v(csb0)", "v(web0)", "i(vvdd)"] + [f"i(v{s_})" for s_ in srcs] + \
          [f"v({s_})" for s_ in srcs if s_ not in ("clk0", "csb0", "web0")] + [f"v(d{i})" for i in range(nd)]
    vec += [f"v(xsram.{n})" for n in probes]

    def dump():
        return ["wrdata tb_out.part " + " ".join(vec), "shell mv -f tb_out.part tb_out.txt"]

    def check(target, what):
        out = ["if ( length(time) > 1 )", "  let e8_tlast = time[length(time)-1]", "else", "  let e8_tlast = 0", "end",
               f"if ( e8_tlast > {target:.6e} )", f"  echo E8_OK {what}", "else",
               f"  echo E8_FAILED the transient did not reach {target:.6e} s ({what})", "  shell touch tb_failed"]
        out += ["  " + d for d in dump()] + ["  quit", "end"]
        return out

    cp = (a.checkpoint or 5 * a.period) * 1e-9
    stops_at, x = [], cp
    while x < tstop - 0.5 * cp:
        stops_at.append(x)
        x += cp
    lines += [".control", "set wr_singlescale", "set wr_vecnames", "option numdgt=8", "save " + " ".join(vec)]
    if stops_at:
        lines += [f"stop when time > {stops_at[0]:.6e}", "run"] + check(stops_at[0] * 0.999, "first segment") + dump()
        for x in stops_at[1:]:
            lines += ["delete all", f"stop when time > {x:.6e}", "resume"] + \
                     check(x * 0.999, f"segment ending at {x * 1e9:.1f} ns") + dump()
        lines += ["delete all", "resume"]
    else:
        lines.append("run")
    lines += check(tstop * 0.999, "last segment") + dump() + ["shell touch tb_done", "rusage time", "quit", ".endc", ".end"]
    with open(os.path.join(a.out, "tb.sp"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(os.path.join(a.out, ".spiceinit"), "w") as fh:     # the settings of the ROM runs (E8.4a-2 on)
        fh.write("* ngspice settings recommended for the sky130 models\nset ngbehavior=hsa\nset ng_nomodcheck\n"
                 f"set skywaterpdk\nset num_threads={a.threads}\n")
    meta = {"top": a.top, "netlist": os.path.abspath(a.sp), "period_ns": a.period, "edge_ns": a.edge, "vdd": vdd,
            "cload_fF": a.cload, "tstop": tstop, "cycles": meta_cycles, "notes": notes, "models": a.models,
            "corner": a.corner, "temp": a.temp, "data_bits": nd, "word_bits": wbits, "addr_bits": na,
            "sources": srcs, "probes": probes}
    with open(os.path.join(a.out, "tb_meta.json"), "w") as fh:
        json.dump(meta, fh, indent=1)
    print(f"bench written: {a.out}/tb.sp  ({len(cycles)} cycles, period {a.period} ns, stop {tstop * 1e9:.1f} ns, "
          f"{na} address bits, {nd} data bits of which {wbits} compared)")
    for n in notes:
        print("   note: " + n)


def cmd_analyze(a):
    meta = json.load(open(os.path.join(a.dir, "tb_meta.json")))
    pout = os.path.join(a.dir, "tb_out.txt")
    failed = os.path.isfile(os.path.join(a.dir, "tb_failed"))
    if not os.path.isfile(pout):
        print(f"P2R-E8.4c analysis: {meta['top']}: no waveform data" + (" (simulation failed)" if failed else ""))
        return 1
    header, c = RB.read_wrdata(pout)
    t = c[header[0]]
    key = lambda name: next((h for h in header if h.lower() == name.lower()), None)
    vdd, T = meta["vdd"], meta["period_ns"] * 1e-9
    ivdd = c[key("i(vvdd)")]
    pvdd = [-vdd * x for x in ivdd]
    pin = [0.0] * len(t)
    for s_ in meta["sources"]:
        ik, vk = key(f"i(v{s_})"), key(f"v({s_})")
        if ik and vk:
            for j in range(len(t)):
                pin[j] += -c[vk][j] * c[ik][j]
    nd, wbits = meta["data_bits"], meta["word_bits"]
    dk = [key(f"v(d{i})") for i in range(nd)]
    t_end = t[-1]
    cyc = meta["cycles"]
    done = sum(1 for cy in cyc if cy["tend"] <= t_end + 1e-12)
    print(f"P2R-E8.4c analysis: {meta['top']}  period {meta['period_ns']} ns  vdd {vdd} V  corner {meta['corner']} "
          f"{meta['temp']} C  load {meta['cload_fF']} fF per output  points {len(t)}")
    print(f"data: simulated to {t_end * 1e9:.1f} of {meta['tstop'] * 1e9:.1f} ns, {done} of {len(cyc)} cycles complete"
          + ("  (SIMULATION FAILED)" if failed else ""))
    print("E_vdd: energy from the supply from the cycle's rising edge to the next; E_in: from the input sources; "
          "P_end: supply power at the end of the cycle (stopped segment: average over its last fifth)")
    print(f"{'k':>3} {'kind':5} {'addr':>5} {'data':>5} {'read@half':>9} {'read@end':>8} {'ok':>3} {'E_vdd pJ':>9} "
          f"{'E_in pJ':>8} {'P_end uW':>9} {'t_acc ns':>8}")
    res = []
    for ci, cy in enumerate(cyc):
        t1, t2 = cy["trise"], cy["tend"]
        if t2 > t_end + 1e-12:
            break
        e = RB.integ(t, pvdd, t1, t2) * 1e12
        ein = RB.integ(t, pin, t1, t2) * 1e12
        if cy["kind"] == "stop":
            # static power: average over the last fifth of the stopped segment (instantaneous values ring)
            w = (t2 - t1) / 5
            pend = RB.integ(t, pvdd, t2 - w, t2) / w * 1e6
        else:
            pend = sum(RB.value_at(t, pvdd, t2 - x) for x in (0.02 * T, 0.03 * T, 0.04 * T)) / 3 * 1e6
        r_half = r_end = ok = tacc = tacc_fall = None
        if cy["kind"] == "read":
            word = lambda tt: sum((1 << i) for i in range(wbits) if RB.value_at(t, c[dk[i]], tt) > vdd / 2)
            r_half = word(t1 + T / 2 - 0.02 * T)
            r_end = word(t2 - 0.02 * T)
            ok = (cy["expected"] is not None and r_end == cy["expected"])
            last = t1
            for i in range(wbits):
                fin = RB.value_at(t, c[dk[i]], t2 - 0.02 * T)
                # last time the bit was farther than 10 % of VDD from its final level
                for j in range(len(t) - 1, -1, -1):
                    if t[j] < t1:
                        break
                    if t[j] <= t2 - 0.02 * T and abs(c[dk[i]][j] - fin) > 0.1 * vdd:
                        last = max(last, t[j])
                        break
            tacc = (last - t1) * 1e9
        # a read followed by a stopped clock (the lane's clock gated after the read): the word at the end of the stopped
        # segment, i.e. what logic sampling (period + stop) after the rising edge gets (two system cycles for r10),
        # and the access time against that final word
        r_stop = ok_stop = tacc_stop = None
        nx = cyc[ci + 1] if ci + 1 < len(cyc) else None
        if cy["kind"] == "read" and nx is not None and nx["kind"] == "stop" and nx["tend"] <= t_end + 1e-12:
            ts = nx["tend"] - 0.02 * T
            r_stop = word(ts)
            ok_stop = (cy["expected"] is not None and r_stop == cy["expected"])
            last = t1
            for i in range(wbits):
                fin = RB.value_at(t, c[dk[i]], ts)
                for j in range(len(t) - 1, -1, -1):
                    if t[j] < t1:
                        break
                    if t[j] <= ts and abs(c[dk[i]][j] - fin) > 0.1 * vdd:
                        last = max(last, t[j])
                        break
            tacc_stop = (last - t1) * 1e9
        tacc_fall = None if tacc is None else tacc - meta["period_ns"] / 2
        rec = {"k": cy["k"], "kind": cy["kind"], "addr": cy["addr"], "E_vdd_pJ": e, "E_in_pJ": ein, "P_end_uW": pend,
               "read_half": r_half, "read_end": r_end, "ok": ok, "t_acc_ns": tacc, "t_acc_from_fall_ns": tacc_fall,
               "read_after_stop": r_stop, "ok_after_stop": ok_stop, "t_acc_gated_ns": tacc_stop,
               "expected": cy["expected"],
               "data": cy["data"], "stop_ns": cy.get("stop_ns")}
        res.append(rec)
        hx = lambda v: "-" if v is None else f"{v:02x}"
        dat = cy["data"] if cy["kind"] == "write" else cy["expected"]
        print(f"{cy['k']:3d} {cy['kind']:5} {'' if cy['addr'] is None else cy['addr']:>5} {hx(dat):>5} {hx(r_half):>9} "
              f"{hx(r_end):>8} {'' if ok is None else ('yes' if ok else 'NO'):>3} {e:9.3f} {ein:8.3f} {pend:9.3f} "
              f"{'' if tacc is None else f'{tacc:8.3f}'}"
              + ("" if r_stop is None else f"   after the stop: {hx(r_stop)} {'yes' if ok_stop else 'NO'}, t_acc {tacc_stop:.3f} ns"))
    reads = [r for r in res if r["kind"] == "read"]
    # every wrong bit, with the word that the previous read put on the same output (history of the sense amplifier)
    wrong_bits, prev = [], None
    for r in reads:
        if r["expected"] is not None and r["read_end"] is not None:
            for i in range(wbits):
                e_, g_ = (r["expected"] >> i) & 1, (r["read_end"] >> i) & 1
                if e_ != g_:
                    wrong_bits.append({"k": r["k"], "addr": r["addr"], "bit": i, "expected": e_, "read": g_,
                                       "prev_addr": None if prev is None else prev["addr"],
                                       "prev_bit": None if prev is None or prev["read_end"] is None else (prev["read_end"] >> i) & 1})
        prev = r
    writes = [r for r in res if r["kind"] == "write"]
    idles = [r for r in res if r["kind"] == "idle"]
    stops = [r for r in res if r["kind"] == "stop"]
    mean = lambda xs: sum(xs) / len(xs) if xs else float("nan")
    summ = {"reads": len(reads), "reads_ok": sum(1 for r in reads if r["ok"]),
            "E_read_pJ_mean": mean([r["E_vdd_pJ"] for r in reads]), "E_read_pJ_min": min((r["E_vdd_pJ"] for r in reads), default=None),
            "E_read_pJ_max": max((r["E_vdd_pJ"] for r in reads), default=None),
            "E_write_pJ_mean": mean([r["E_vdd_pJ"] for r in writes]), "E_idle_pJ_mean": mean([r["E_vdd_pJ"] for r in idles]),
            "P_stop_uW": stops[-1]["P_end_uW"] if stops else None,
            "P_stop_after_read_uW": [round(r["P_end_uW"], 4) for i, r in enumerate(res)
                                     if r["kind"] == "stop" and i > 0 and res[i - 1]["kind"] == "read"],
            "P_stop_after_idle_uW": [round(r["P_end_uW"], 4) for i, r in enumerate(res)
                                     if r["kind"] == "stop" and i > 0 and res[i - 1]["kind"] == "idle"],
            "E_read_after_stop_pJ_mean": mean([r["E_vdd_pJ"] for i, r in enumerate(res)
                                               if r["kind"] == "read" and i > 0 and res[i - 1]["kind"] == "stop"]),
            "reads_ok_at_half": sum(1 for r in reads if r["expected"] is not None and r["read_half"] == r["expected"]),
            # a read followed by a stopped clock: its cycle plus what the stopped segment draws above its own end level
            "E_read_gated_pJ": [round(r["E_vdd_pJ"] + res[i + 1]["E_vdd_pJ"] - res[i + 1]["P_end_uW"] * 1e-6 *
                                      res[i + 1]["stop_ns"] * 1e-9 * 1e12, 4)
                                for i, r in enumerate(res[:-1]) if r["kind"] == "read" and res[i + 1]["kind"] == "stop"],
            "t_acc_ns_max": max((r["t_acc_ns"] for r in reads if r["t_acc_ns"] is not None), default=None),
            "reads_gated": sum(1 for r in reads if r["read_after_stop"] is not None),
            "reads_ok_after_stop": sum(1 for r in reads if r["ok_after_stop"]),
            "t_acc_gated_ns_max": max((r["t_acc_gated_ns"] for r in reads if r["t_acc_gated_ns"] is not None), default=None),
            "wrong_bits": wrong_bits,
            "complete": done == len(cyc) and not failed}
    print("summary: " + json.dumps({k: (round(v, 4) if isinstance(v, float) else v) for k, v in summ.items()}))
    json.dump({"meta": meta, "cycles": res, "summary": summ}, open(os.path.join(a.dir, "result.json"), "w"), indent=1)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    b = sp.add_parser("bench")
    b.add_argument("--sp", required=True)
    b.add_argument("--top", required=True)
    b.add_argument("--models", required=True)
    b.add_argument("--corner", default="tt")
    b.add_argument("--temp", type=float, default=25.0)
    b.add_argument("--out", required=True)
    b.add_argument("--seq", required=True)
    b.add_argument("--period", type=float, default=10.0)
    b.add_argument("--vdd", type=float, default=1.8)
    b.add_argument("--cload", type=float, default=10.0)
    b.add_argument("--edge", type=float, default=0.1)
    b.add_argument("--tmax", type=float, default=0.0)
    b.add_argument("--checkpoint", type=float, default=0.0)
    b.add_argument("--threads", type=int, default=1)
    b.add_argument("--probe", default="",
                   help="comma-separated regular expressions: save the internal nodes whose (rewritten) names end with one")
    b.add_argument("--ic-cells", action="store_true",
                   help="with --uic: start the storage nodes of every cell resolved (no metastable start)")
    b.add_argument("--uic", action="store_true",
                   help="start the transient from 0 V on every node with the supply on (no DC operating point; "
                        "OpenRAM's own stimulus does the same): the bitlines float in DC and the operating point "
                        "does not converge")
    b.add_argument("--word-bits", type=int, default=8, help="data bits written and compared (the spare column is not)")
    b.add_argument("--fix-asad", action="store_true")
    b.add_argument("--sanitize", action="store_true")
    b.add_argument("--substrate", default="")
    b.add_argument("--tie-float-gates", action="store_true",
                   help="tie to ground every net of the top subcircuit that reaches transistors only through their gates")
    b.add_argument("--tie-cell-sub", action="store_true",
                   help="extracted netlist: tie every '<path>/SUB' node (substrate of a foundry SRAM cell) to ground")
    b.add_argument("--plain-nfet", action="store_true",
                   help="write sky130_fd_pr__special_nfet_01v8 as sky130_fd_pr__nfet_01v8 (as the ROM bench)")
    b.add_argument("--spare-wen-fix", action="store_true",
                   help="generator netlist: connect the floating net spare_wen0[0] to the port spare_wen0")
    b.add_argument("--sense-precharge", type=float, default=0.0,
                   help="add a copy of the column precharge cell (pfet of this width in um) on the inputs of every "
                        "sense amplifier behind the column multiplexer, gate p_en_bar0 (simulation netlist only)")
    b.add_argument("--sense-precharge-vdd", default="vccd1", help="supply node for --sense-precharge")
    b.add_argument("--pfet-pass-alias", action="store_true",
                   help="use the PDK's real name sky130_fd_pr__special_pfet_latch for the bitcell pull-ups")
    z = sp.add_parser("analyze")
    z.add_argument("--dir", required=True)
    a = ap.parse_args()
    return cmd_bench(a) if a.cmd == "bench" else cmd_analyze(a)


if __name__ == "__main__":
    sys.exit(main() or 0)
