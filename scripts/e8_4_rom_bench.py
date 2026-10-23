#!/usr/bin/env python3
"""
e8_4_rom_bench.py  probe | bench | analyze | pick | shorts | compare | bitcheck | orgsum |
                   chains | rowmap | split | margins | macrosum | invsize | seqof | ab |
                   condsum

P2R-E8.4. Transistor-level read energy, idle energy, leakage, read access
time and functional readback of the address-map ROM macros generated in
E8.3, simulated with ngspice and the sky130 device models.

Version of 2026-10-09 (E8.4a-2). Changes from the E8.4a version:
  - bench --fix-asad: OpenRAM writes the source/drain areas as "as=0.14u"
    while widths are plain numbers in um; under the PDK's ".option
    scale=1.0u" that area is 1e-6 of the intended 0.14 um2, so the junction
    area capacitance of every transistor is missing. The option rewrites
    as/ad values that end in "u" to plain um2.
  - bench --sanitize: node names of an extracted netlist contain "/" and "#"
    (hierarchical names); they are rewritten ("/" -> "__", "#" -> "h") so
    that internal nodes can be saved by name.
  - bench --plain-nfet: a flat extraction names the 0.36 um cell transistors
    sky130_fd_pr__special_nfet_01v8, which the PDK model file defines as a
    subcircuit around the regular sky130_fd_pr__nfet_01v8 ("defined as a
    regular nFET because its model bins exist there"). The wrapper made
    ngspice exceed 7.5 GB while reading the full-size macro (sandbox); with
    the regular name the same netlist needs about 1.8 GB.
  - bench --probes: saves all wordlines (tb_wl.txt) and the row decoder
    outputs, column selects and clocks (tb_int.txt), for the generator's
    netlist and for a flat extracted netlist; analyze then reports which
    rows and words were selected in each read.
  - the deck checks after the first run and after every resume that the
    transient reached the next checkpoint; if not (e.g. the operating point
    failed), it writes tb_failed and quits instead of retrying.
  - probe reports negative capacitors; shorts lists signal nodes that a
    layout's top-level extraction (.ext) merges into a supply net.

Version of 2026-10-11 (E8.4a-3; second delivery (2) adds the extraction-error
column of orgsum). Additions, all backward compatible:
  - sequence token wN: N ns with the clock held low and CS low (a precharge
    of arbitrary length); cycles may now have different lengths, and each
    cycle's energy window runs from its (virtual) rising edge to the next one
  - pick --mode sweep (precharge sweep before a bottom-row read, --waits) and
    --mode idle (static current with the clock running, parking read)
  - bitcheck: the generated netlist stores the data file bit by bit
  - orgsum: comparison table of ROM organisations (area, LVS, magic
    extraction errors, energy, recovery, static current). An extraction
    error (e.g. "Illegal overlap between ndiff and poly") is a layout fault
    even when LVS matches: the hierarchical extraction leaves the overlap out,
    but on the mask poly over diffusion is a transistor (sandbox, 2026-10-11:
    26 words per row, LVS match, 600 errors; flattened, 15 extra transistors)
  - analyze records the number of wrong bits of each read

Version of 2026-10-11 (3) (E8.4a-4). Additions, all backward compatible:
  - bench --chain-cols COLS|auto [--chain-step N] (generator netlist only):
    saves the bitline and the nodes of the series chain of these columns
    (auto: bits 0, 1, w/2 and w-1 of the last word read), with the rows of
    their transistors (tb_meta.json "chains")
  - pick --mode rowmap --row R: the precharge a read of row R needs after a
    read of row 0 (see pick)
  - chains --dir RUN: chain-node voltages at each read of a probed column
  - rowmap --dirs RUN...: table of the precharge each target row needs, and
    whether the row is safe at the system's lookup interval (--interval)

Version of 2026-10-11 (4) (E8.4a-5, shallow macros). Additions, all backward
compatible (old sequences give the same deck and the same analysis output):
  - bench --bitlines all (with --probes full): saves every bitline, not only
    those of bits 0, w/2 and w-1 of the words read. The wordline of the read
    row goes low in every column, so one read of a row tests every cell of
    the row: each bitline has its own inverter before the column multiplexer,
    and a bitline does not depend on which word is selected
  - analyze, with all bitlines: for every read, the lowest bitline voltage
    during the evaluation among the read row's one cells (a one bit is read
    correctly only if its bitline stays above the bitline inverter's switching
    level, about 0.87-0.90 V at tt, 25 C in E8.4a-4), the highest bitline
    voltage at the sampling time among its zero cells (it must be below that
    level), and the lowest among the one bits of the word read
  - pick --mode deep (one read of each of the deepest rows after a read of
    row 0, at each wait) and --mode words (given addresses after a read of
    row 0, at each wait)
  - rowmap: every address read other than the first one is a target (a run
    may hold several target words); with all bitlines, a cell also shows the
    lowest bitline of the word's one bits
  - split: cut a data file into macros of a given number of rows
  - margins --dirs RUN...: per read, the lowest one-cell and the highest
    zero-cell bitline; the run (macro) with the lowest one-cell bitline and
    its N words with the lowest bitline among their one bits (--per-row: at
    most one word per row)
  - macrosum: area, LVS and extraction errors of a set of macros, with totals
    per option, against a reference macro
  - invsize: the transistor sizes of the bitline inverter (the script then
    measures its switching level at each corner)

Version of 2026-10-12 (5) (E8.4a-6, chip select after the clock edge).
Additions, all backward compatible (without --cs-delay a bench writes the
same deck as version 4; analyze prints the same lines plus one timing line per
read when the precharge net and the internal clock are probed):
  - bench --cs-delay NS: CS of a read rises NS ns after the clock edge and
    falls with the clock (version 4 and before: CS changes with the address,
    a quarter period before the edge). prechrg = CS AND clk, so the row
    decoder selects the row first and the array evaluates only when CS rises
  - analyze: for every read, the times after the clock edge at which the
    internal clock rises, the array precharge net rises (precharge PMOS off,
    column footers on) and the selected wordline falls (all through VDD/2),
    and footer-to-wordline = wordline low minus footers on. A positive value
    means every row of every column was on while the footers were already
    on, so the columns conducted to ground (the cause of the one-bit read
    errors of E8.4a-5, sandbox 2026-10-12). analyze --json-out FILE writes
    the result there instead of DIR/result.json (to analyse a run of another
    experiment without changing it)
  - seqof --dir RUN: the read sequence of an existing run, to repeat it
  - ab --a RESULT --b RESULT: read-by-read comparison of two runs of the same
    sequence (lowest one-cell bitline, result, energy, access time, footer
    to wordline)
  - condsum --dirs RUN|RESULT... [--vm V...]: one line per run (condition,
    wrong reads and selections, lowest one-cell bitline, margin above the
    bitline inverter's switching level, highest zero-cell bitline, footer to
    wordline, energy, access time)

Version of 2026-10-18 (6) (P2R-E8 time-step check). One addition, backward
compatible (without --reltol a bench writes the same deck as version 5):
  - bench --reltol X: the deck's ".options klu" line becomes
    ".options klu reltol=X" (ngspice's relative error tolerance, default 1e-3);
    the maximum time step stays period/50 (or --tmax). Sandbox, 2026-10-18
    (claude/p2r-e8-tstep-sandbox.md): with the default tolerance and a 2 ns
    maximum step the static current a read leaves behind differed from a
    20 ps run by up to about 10 % (per word, either sign) and a read energy by
    up to 4.7 %; with reltol 1e-4 by at most 0.07 % and 0.22 %, at 1.1-1.8
    times the run time. Reads, selections and bitline margins were the same
    with every setting (bitlines within 13 mV). tb_meta.json records reltol.

How the ROM works (OpenRAM e16d9eb, compiler/modules/rom_*.py; checked on a
generated netlist): there are no address or output registers. The control
logic makes prechrg = CS AND clk. While prechrg is low (clock low, or CS
low) every bitline is precharged; while it is high the selected wordline goes
low and each bitline, the top of a chain of (rows + 1) series NMOS, discharges
through the chain if the selected cell is a zero cell (shorted transistor).
The bitline inverters, the column multiplexer and the output inverters then
drive dout. So the address must be stable before the clock rises, and dout is
valid only late in the clock-high phase. The row decoder is clocked by the
buffered clock, not by CS, so it switches every cycle while the clock runs.

probe   --sp NETLIST [--top NAME]
        Top-level ports, subcircuit hierarchy, flattened device counts by model
        and size, capacitor count and total capacitance.

bench   --sp NETLIST --top NAME --bin DATA.bin --word-bytes 2 --out DIR
        --models FILE [--corner tt|none] --period NS --seq SEQ
        [--vdd 1.8] [--cload FF] [--edge NS] [--tmax NS (default period/50)]
        [--reltol X (version 6; default not written, ngspice's 1e-3)]
        [--internal | --probes basic|full] [--fix-asad] [--sanitize]
        (see the version notes above)
        Writes DIR/tb.sp (ngspice deck), DIR/netlist.sp (copy of the netlist
        without a trailing .end, with the corrections asked for) and
        DIR/tb_meta.json. The deck writes tb_out.txt (supply, inputs,
        outputs), tb_int.txt and tb_wl.txt (internal nodes), tb_done at the
        end, tb_failed if the transient did not reach a checkpoint.
        SEQ is a comma-separated list of cycles:
          rA    read address A (decimal): CS = 1 for this cycle
          i     idle cycle: CS = 0, clock running, address held
          sN    clock stopped (held low) for N periods, CS = 0: leakage
          wN    clock held low for N ns, CS = 0 (one segment of any length)
        Cycle k: clock low (precharge) for the first half, high (evaluate)
        for the second half; address and CS change in the middle of the low
        half. The energy of cycle k is integrated from its rising edge to the
        next rising edge, so it includes the precharge that restores what the
        read discharged.

analyze --dir DIR
        Reads DIR/tb_out.txt and DIR/tb_meta.json. For every cycle: energy
        drawn from the supply and from the input sources, dout sampled just
        before the falling edge against the stored word, access time (from
        the 50 % point of the clock rise until every dout bit has reached the
        value it holds at the sampling time). With full probes, also the rows
        whose wordline is low and the words whose column select is high at
        the sampling time, and the lowest voltage of an unselected row-decoder
        output during the read. Writes DIR/result.json.

shorts  --ext TOP.ext
        Signal nodes that the top cell's extraction merges into vdd or gnd.

compare --dirs D1 D2 ... --labels L1 L2 ...
        Per-cycle table (read value, energy, static power, access time) of
        several analysed runs of the same sequence.

Only the Python standard library is used.
"""
import argparse
import json
import math
import os
import re
import sys

# --------------------------------------------------------------------------
# netlist parsing
# --------------------------------------------------------------------------
UNIT = {"t": 1e12, "g": 1e9, "meg": 1e6, "k": 1e3, "m": 1e-3, "u": 1e-6,
        "n": 1e-9, "p": 1e-12, "f": 1e-15, "a": 1e-18}


def spice_num(s):
    s = s.strip().lower()
    m = re.match(r"^([+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)(meg|[tgkmunpfa])?", s)
    if not m:
        raise ValueError(s)
    return float(m.group(1)) * (UNIT[m.group(2)] if m.group(2) else 1.0)


def logical_lines(path):
    """SPICE lines with '+' continuations joined; comments dropped."""
    out, cur = [], None
    with open(path, errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            s = line.strip()
            if not s or s.startswith("*"):
                continue
            if s.startswith("+"):
                if cur is not None:
                    cur += " " + s[1:]
                continue
            if cur is not None:
                out.append(cur)
            cur = s
    if cur is not None:
        out.append(cur)
    return out


def parse_netlist(path):
    """Returns {subckt: {"ports": [...], "inst": [(name, nodes, cell, params)],
    "caps": [(name, a, b, value)]}} and the list of top-level (outside any
    subckt) lines."""
    subs, cur, outside = {}, None, []
    for line in logical_lines(path):
        tok = line.split()
        key = tok[0].lower()
        if key == ".subckt":
            ports = [t for t in tok[2:] if "=" not in t]
            cur = {"ports": ports, "inst": [], "caps": [], "name": tok[1]}
            subs[tok[1]] = cur
            continue
        if key == ".ends":
            cur = None
            continue
        if cur is None:
            outside.append(line)
            continue
        c0 = tok[0][0].upper()
        if c0 == "X":
            words = [t for t in tok[1:] if "=" not in t]
            params = dict(t.split("=", 1) for t in tok[1:] if "=" in t)
            cur["inst"].append((tok[0], words[:-1], words[-1], params))
        elif c0 == "M":
            params = dict(t.split("=", 1) for t in tok[1:] if "=" in t)
            words = [t for t in tok[1:] if "=" not in t]
            cur["inst"].append((tok[0], words[:4], words[4] if len(words) > 4 else "?", params))
        elif c0 == "C":
            try:
                cur["caps"].append((tok[0], tok[1], tok[2], spice_num(tok[3])))
            except (ValueError, IndexError):
                pass
    return subs, outside


def flatten_counts(subs, top, with_neg=False):
    """Flattened counts of primitive devices and capacitors under top
    (with_neg: also the number of negative capacitors, their sum, and the
    most negative value)."""
    memo = {}

    def walk(name):
        if name in memo:
            return memo[name]
        dev, ncap, ccap, nneg, cneg, cmin = {}, 0, 0.0, 0, 0.0, 0.0
        s = subs[name]
        for (_, _, cell, params) in s["inst"]:
            if cell in subs:
                d2, n2, c2, nn2, cn2, cm2 = walk(cell)
                mult = int(float(params.get("m", params.get("M", "1"))))
                for k, v in d2.items():
                    dev[k] = dev.get(k, 0) + v * mult
                ncap += n2 * mult
                ccap += c2 * mult
                nneg += nn2 * mult
                cneg += cn2 * mult
                cmin = min(cmin, cm2)
            else:
                w = params.get("w", params.get("W", "?"))
                l = params.get("l", params.get("L", "?"))
                mult = params.get("m", params.get("M", "1"))
                try:
                    mult = int(float(mult))
                except ValueError:
                    mult = 1
                key = (cell, w, l)
                dev[key] = dev.get(key, 0) + mult
        ncap += len(s["caps"])
        ccap += sum(c[3] for c in s["caps"])
        negs = [c[3] for c in s["caps"] if c[3] < 0]
        nneg += len(negs)
        cneg += sum(negs)
        if negs:
            cmin = min(cmin, min(negs))
        memo[name] = (dev, ncap, ccap, nneg, cneg, cmin)
        return memo[name]

    r = walk(top)
    return r if with_neg else r[:3]


def port_map(ports):
    """Map the macro's ports to bench nodes."""
    nodes, roles = [], {"addr": {}, "dout": {}}
    for p in ports:
        pl = p.lower()
        m_a = re.match(r"^addr0[\[_<]?(\d+)[\]>]?$", pl)
        m_d = re.match(r"^dout0[\[_<]?(\d+)[\]>]?$", pl)
        if pl in ("clk0", "clk"):
            nodes.append("clk")
        elif pl in ("cs0", "cs", "csb0"):
            nodes.append("cs")
        elif m_a:
            i = int(m_a.group(1)); roles["addr"][i] = p; nodes.append(f"a{i}")
        elif m_d:
            i = int(m_d.group(1)); roles["dout"][i] = p; nodes.append(f"d{i}")
        elif pl in ("vccd1", "vdd", "vpwr"):
            nodes.append("vdd")
        elif pl in ("vssd1", "gnd", "vgnd", "vss", "0", "vsubs", "vsub", "sub"):
            nodes.append("0")
        else:
            nodes.append(f"nc_{re.sub(r'[^A-Za-z0-9_]', '_', p)}")
            roles.setdefault("unmapped", []).append(p)
    return nodes, roles


# --------------------------------------------------------------------------
# ROM organisation (same rules as e8_3_rom_tools.py / OpenRAM rom_config.py)
# --------------------------------------------------------------------------
def organisation(n_bytes, word_bytes, words_per_row=None):
    data_size = (n_bytes * 8) / 8
    num_words = int(data_size / word_bytes)
    wpr = words_per_row or int(math.ceil(math.sqrt(num_words) / (2 * word_bytes)))
    cols = wpr * word_bytes * 8
    rows = int(num_words / wpr)
    return num_words, wpr, cols, rows


def bitmap(data, word_bytes, wpr, cols):
    bits = [int(b) for byte in data for b in f"{byte:08b}"]
    rows = []
    for i in range(0, len(bits), cols):
        r = bits[i:i + cols]
        if len(r) < cols:
            r = [0] * (cols - len(r)) + r
        rows.append(r)
    wb = word_bytes * 8
    return [[r[bit + word * wb] for bit in range(wb) for word in range(wpr)] for r in rows]


# --------------------------------------------------------------------------
# probe
# --------------------------------------------------------------------------
def cmd_probe(a):
    subs, outside = parse_netlist(a.sp)
    top = a.top or os.path.splitext(os.path.basename(a.sp))[0]
    if top not in subs:
        cands = [n for n in subs if n.lower() == top.lower()]
        if not cands:
            print(f"top subcircuit {top} not found; subcircuits: {', '.join(list(subs)[:20])}")
            sys.exit(2)
        top = cands[0]
    ports = subs[top]["ports"]
    nodes, roles = port_map(ports)
    print(f"netlist   : {a.sp}")
    print(f"top       : {top}, {len(ports)} ports, {len(subs)} subcircuits")
    print(f"ports     : {' '.join(ports)}")
    print(f"mapped to : {' '.join(nodes)}")
    print(f"address bits {len(roles['addr'])}, data bits {len(roles['dout'])}")
    if roles.get("unmapped"):
        print(f"UNMAPPED PORTS (would be left floating): {' '.join(roles['unmapped'])}")
    other = [l for l in outside if not l.lower().startswith((".end",))]
    if other:
        print("lines outside subcircuits (first 5):")
        for l in other[:5]:
            print("   " + l[:150])
    dev, ncap, ccap, nneg, cneg, cmin = flatten_counts(subs, top, with_neg=True)
    tot = sum(dev.values())
    print(f"devices (flattened): {tot}")
    for (cell, w, l), n in sorted(dev.items(), key=lambda kv: -kv[1])[:25]:
        print(f"   {n:7d}  {cell}  w={w}  l={l}")
    print(f"capacitors (flattened): {ncap}, total {ccap*1e12:.3f} pF")
    if ncap:
        print(f"negative capacitors (flattened): {nneg}, sum {cneg*1e12:.3f} pF, "
              f"most negative {cmin*1e15:.3f} fF"
              + ("   <-- NOT SIMULABLE AS IS" if nneg else ""))
    insts = {}
    for (_, _, cell, _) in subs[top]["inst"]:
        insts[cell] = insts.get(cell, 0) + 1
    print("instances in the top cell:")
    for k, v in list(insts.items())[:12]:
        print(f"   {v:5d}  {k}")
    if len(insts) > 12:
        print(f"   ... {len(insts)} kinds of instances")
    print(json.dumps({"top": top, "ports": ports, "devices": tot, "caps": ncap,
                      "cap_total_pF": ccap * 1e12, "caps_negative": nneg,
                      "cap_negative_sum_pF": cneg * 1e12}))


# --------------------------------------------------------------------------
# bench
# --------------------------------------------------------------------------
def parse_seq(seq):
    cycles = []
    for tok in seq.split(","):
        tok = tok.strip()
        if not tok:
            continue
        if tok[0] == "r":
            cycles.append(("read", int(tok[1:])))
        elif tok == "i":
            cycles.append(("idle", None))
        elif tok[0] == "s":
            for _ in range(int(tok[1:])):
                cycles.append(("stop", None))
        elif tok[0] == "w":
            ns = float(tok[1:])
            if ns > 0:
                cycles.append(("wait", ns))
        else:
            raise ValueError(f"bad cycle token {tok}")
    return cycles


def cmd_bench(a):
    if a.bitlines == "all" and a.probes != "full":
        sys.exit("--bitlines all needs --probes full")
    subs, _ = parse_netlist(a.sp)
    top = a.top
    if top not in subs:
        sys.exit(f"top subcircuit {top} not in {a.sp}")
    ports = subs[top]["ports"]
    nodes, roles = port_map(ports)
    nab, ndb = len(roles["addr"]), len(roles["dout"])
    data = open(a.bin, "rb").read()
    nw, wpr, cols, rows = organisation(len(data), a.word_bytes, a.words_per_row)
    bm = bitmap(data, a.word_bytes, wpr, cols)
    col_bits = max(1, math.ceil(math.log2(wpr))) if wpr > 1 else 0
    wbits = a.word_bytes * 8
    if ndb != wbits:
        sys.exit(f"the netlist has {ndb} data bits, the data file implies {wbits}")
    cycles = parse_seq(a.seq)
    os.makedirs(a.out, exist_ok=True)

    if roles.get("unmapped") and not a.allow_unmapped:
        sys.exit(f"ports with no bench connection: {' '.join(roles['unmapped'])} "
                 "(use --allow-unmapped to leave them floating)")
    # copy the netlist without .end lines (some extractors append one); tie the
    # extractor's substrate node to ground outside subcircuit headers;
    # optionally correct OpenRAM's junction areas and rewrite hierarchical
    # node names
    notes = []
    sub_re = re.compile(r"(?<![A-Za-z0-9_#$.])" + re.escape(a.substrate) + r"(?![A-Za-z0-9_#$.])",
                        re.IGNORECASE) if a.substrate else None
    asad_re = re.compile(r"(?<![A-Za-z0-9_])(as|ad)=([0-9]*\.?[0-9]+(?:[eE][+-]?[0-9]+)?)u(?![A-Za-z0-9_])",
                         re.IGNORECASE)
    n_sub = n_asad = n_san = n_plain = 0
    in_header = False
    node_names = set()

    def sanitize_line(line):
        """rewrite node names of a device line (X, M, C, R, D) inside a subcircuit"""
        tok = line.split()
        if not tok or tok[0][0].upper() not in "XMCRD":
            return line, 0
        c0 = tok[0][0].upper()
        words = [i for i, t in enumerate(tok) if "=" not in t]
        if c0 == "X":
            nidx = words[1:-1]                 # name, nodes..., cell
        elif c0 == "M":
            nidx = words[1:5]
        else:                                  # C, R, D: two nodes, then the value or model
            nidx = words[1:3]
        changed = 0
        for i in nidx:
            new = tok[i].replace("/", "__").replace("#", "h")
            if new != tok[i]:
                tok[i] = new
                changed += 1
            node_names.add(tok[i])
        return " ".join(tok) + "\n", changed

    with open(a.sp, errors="replace") as fi, open(os.path.join(a.out, "netlist.sp"), "w") as fo:
        for line in fi:
            s = line.strip().lower()
            if re.match(r"^\.end\s*$", s):
                notes.append("removed a .end line from the netlist copy")
                continue
            if s.startswith(".subckt"):
                in_header = True
            elif not s.startswith("+"):
                in_header = False
            if s.startswith((".option", ".options", ".lib", ".include", ".param", ".global")):
                notes.append("netlist line kept: " + line.strip()[:120])
            if sub_re and not in_header and not s.startswith("*"):
                line, n = sub_re.subn("0", line)
                n_sub += n
            if a.fix_asad and not s.startswith("*"):
                line, n = asad_re.subn(r"\1=\2", line)
                n_asad += n
            if a.plain_nfet and not s.startswith("*"):
                n = line.count("sky130_fd_pr__special_nfet_01v8")
                if n:
                    line = line.replace("sky130_fd_pr__special_nfet_01v8", "sky130_fd_pr__nfet_01v8")
                    n_plain += n
            if a.sanitize and not in_header and not s.startswith(("*", ".", "+")):
                line, n = sanitize_line(line)
                n_san += n
            fo.write(line)
    if n_sub:
        notes.append(f"substrate node {a.substrate} tied to ground in {n_sub} places")
    if a.fix_asad:
        notes.append(f"junction areas corrected (as/ad '<x>u' -> '<x>' um2) in {n_asad} places")
    if a.sanitize:
        notes.append(f"hierarchical node names rewritten ('/' -> '__', '#' -> 'h') in {n_san} places")
    if a.plain_nfet:
        notes.append(f"sky130_fd_pr__special_nfet_01v8 written as sky130_fd_pr__nfet_01v8 in {n_plain} places")

    T = a.period * 1e-9
    tr = a.edge * 1e-9
    vdd = a.vdd
    # expected words and stimulus
    meta_cycles = []
    clk_pts = [(0.0, 0.0)]
    cs_pts = [(0.0, 0.0)]
    addr_hist = [0] * nab
    a_pts = [[(0.0, 0.0)] for _ in range(nab)]
    cur_addr = 0
    t_next = 0.0
    for k, (kind, addr) in enumerate(cycles):
        # every cycle lasts one period, except a wait segment (token wN), which
        # holds the clock low for N ns
        seg = addr * 1e-9 if kind == "wait" else T
        t0 = t_next
        t_next = t0 + seg
        tin = t0 + T / 4           # inputs change in the middle of the low half
        trise = t0 + T / 2         # 50 % of the rising edge (virtual for stop and wait)
        tfall = t0 + T             # 50 % of the falling edge
        cs_val = vdd if kind == "read" else 0.0
        if kind == "read":
            cur_addr = addr
        # cs
        last = cs_pts[-1][1]
        if a.cs_delay is None:
            if last != cs_val:
                cs_pts += [(tin - tr / 2, last), (tin + tr / 2, cs_val)]
        elif kind == "read":
            # sandbox option: CS rises cs_delay ns after the clock edge (the row is
            # selected first, then the array evaluates) and falls with the clock
            tcs = trise + a.cs_delay * 1e-9
            if last != 0.0:
                cs_pts += [(tin - tr / 2, last), (tin + tr / 2, 0.0)]
            cs_pts += [(tcs - tr / 2, 0.0), (tcs + tr / 2, vdd), (tfall - tr / 2, vdd), (tfall + tr / 2, 0.0)]
        elif last != 0.0:
            cs_pts += [(tin - tr / 2, last), (tin + tr / 2, 0.0)]
        # address
        for i in range(nab):
            v = vdd if (cur_addr >> i) & 1 else 0.0
            lastv = a_pts[i][-1][1]
            if lastv != v:
                a_pts[i] += [(tin - tr / 2, lastv), (tin + tr / 2, v)]
        # clock (held low in stop cycles and wait segments)
        if kind not in ("stop", "wait"):
            clk_pts += [(trise - tr / 2, 0.0), (trise + tr / 2, vdd),
                        (tfall - tr / 2, vdd), (tfall + tr / 2, 0.0)]
        exp = None
        row = word = None
        if kind == "read":
            row, word = cur_addr >> col_bits, cur_addr & ((1 << col_bits) - 1)
            if row >= rows or word >= wpr:
                sys.exit(f"address {cur_addr} is outside the stored array (row {row}, word {word})")
            exp = [bm[row][b * wpr + word] for b in range(wbits)]
        meta_cycles.append({"k": k, "kind": kind, "addr": cur_addr if kind == "read" else None,
                            "row": row, "word": word, "expected": exp,
                            "zeros_in_row": (bm[row].count(0) if row is not None else None),
                            "t0": t0, "trise": trise, "tfall": tfall if kind != "wait" else None,
                            "len": seg})
    # energy window of each cycle: from its (virtual) rising edge to the next
    # cycle's; the windows tile the time axis
    for k, cy in enumerate(meta_cycles):
        cy["tend"] = meta_cycles[k + 1]["trise"] if k + 1 < len(meta_cycles) else cy["t0"] + cy["len"] + T / 2
    tstop = t_next + T / 2 + 2 * tr

    def pwl(pts):
        out, lastt = [], -1.0
        for t, v in pts:
            if t <= lastt:
                t = lastt + 1e-13
            out.append(f"{t:.6e} {v:g}")
            lastt = t
        out.append(f"{tstop:.6e} {pts[-1][1]:g}")
        return "PWL(" + " ".join(out) + ")"

    lines = []
    lines.append(f"* P2R-E8.4 ROM bench: {top}  period {a.period} ns  vdd {vdd} V")
    if a.corner and a.corner != "none":
        lines.append(f'.lib "{a.models}" {a.corner}')
    else:
        lines.append(f'.include "{a.models}"')
    lines.append(f'.include "{os.path.join(os.path.abspath(a.out), "netlist.sp")}"')
    lines.append(f".temp {a.temp}")
    lines.append(f"Vvdd vdd 0 {vdd}")
    lines.append(f"Vclk clk 0 {pwl(clk_pts)}")
    lines.append(f"Vcs cs 0 {pwl(cs_pts)}")
    for i in range(nab):
        lines.append(f"Va{i} a{i} 0 {pwl(a_pts[i])}")
    # instance, ports in the subcircuit's order
    inst = "Xrom " + " ".join(nodes) + " " + top
    lines.append(inst)
    for i in range(ndb):
        lines.append(f"Cd{i} d{i} 0 {a.cload}f")
    tmax = a.tmax * 1e-9 if a.tmax else T / 50
    reltol = getattr(a, "reltol", None)
    lines.append(".options klu" + (f" reltol={reltol:g}" if reltol else ""))
    lines.append(f".tran {min(T/1000, 10e-12):.3e} {tstop:.6e} 0 {tmax:.3e}")
    vec = ["v(clk)", "v(cs)", "i(vvdd)", "i(vclk)", "i(vcs)"]
    vec += [f"i(va{i})" for i in range(nab)] + [f"v(a{i})" for i in range(nab)]
    vec += [f"v(d{i})" for i in range(ndb)]
    internal = []
    wordlines = []
    probe_map = {}
    # internal nets go to separate files, so that a missing name cannot stop
    # the main waveform file from being written
    if a.internal and not a.probes:
        a.probes = "basic"
    if a.probes == "basic":
        # nets of the generator's netlist (rom_bank.py); not present in an extracted netlist
        first = next((cy for cy in meta_cycles if cy["kind"] == "read" and 0 in cy["expected"]), None)
        internal = ["v(xrom.precharge)", "v(xrom.clk_int)"]
        if first:
            b0 = first["expected"].index(0)
            col = b0 * wpr + first["word"]
            internal += [f"v(xrom.bl_{col})", f"v(xrom.bl_b_{col})", f"v(xrom.rom_out_prebuf_{b0})",
                         f"v(xrom.wl_{first['row']})"]
            notes.append(f"internal probes: bitline {col} and multiplexer output {b0} of the first read "
                         f"(address {first['addr']}), wordline {first['row']}")
    elif a.probes == "full":
        # rows read, and the rows whose decoder chain differs from a read row in
        # one address bit (the decoder outputs most exposed to charge sharing)
        read_rows = sorted({cy["row"] for cy in meta_cycles if cy["kind"] == "read"})
        row_bits = max(1, math.ceil(math.log2(rows)))
        near = set(read_rows)
        for r in read_rows:
            for j in range(row_bits):
                q = r ^ (1 << j)
                if q < rows:
                    near.add(q)
        near = sorted(near)
        if a.bitlines == "all":
            read_cols = list(range(cols))
        else:
            read_cols = sorted({b * wpr + cy["word"] for cy in meta_cycles if cy["kind"] == "read"
                                for b in (0, wbits // 2, wbits - 1)})
        flat = len(subs) <= 3 or not any(c.lower().endswith("_rom_row_decode")
                                         for (_, _, c, _) in subs[top]["inst"])
        if not flat:
            # generator netlist: names from rom_bank.py / rom_decoder.py
            top_nets = {n for (_, nn, _, _) in subs[top]["inst"] for n in nn}
            dec = next((c for (_, _, c, _) in subs[top]["inst"] if c.lower().endswith("_rom_row_decode")), None)
            dec_inst = next((i for (i, _, c, _) in subs[top]["inst"] if c == dec), None)
            dec_nets = {n for (_, nn, _, _) in subs[dec]["inst"] for n in nn} if dec else set()
            for r in range(rows):
                if f"wl_{r}" in top_nets:
                    probe_map[f"wl{r}"] = f"v(xrom.wl_{r})"
            for r in near:
                if f"wl_int{r}" in dec_nets and dec_inst:
                    probe_map[f"dec{r}"] = f"v(xrom.{dec_inst.lower()}.wl_int{r})"
            for w in range(wpr):
                if f"word_sel_{w}" in top_nets:
                    probe_map[f"sel{w}"] = f"v(xrom.word_sel_{w})"
            for c in read_cols:
                if f"bl_{c}" in top_nets:
                    probe_map[f"bl{c}"] = f"v(xrom.bl_{c})"
            for n in ("precharge", "clk_int"):
                if n in top_nets:
                    probe_map[n] = f"v(xrom.{n})"
        else:
            # flat extracted netlist: the layout's hierarchical label names
            if not a.sanitize:
                sys.exit("--probes full on an extracted netlist needs --sanitize")
            # a merged net carries one of its hierarchical names; the first
            # pattern is the name seen in the sandbox, the others are fallbacks
            pats = [("wl", 0, r"rom_row_decode_0__wl_(\d+)$"),
                    ("wl", 1, r"rom_base_array_0__wl_0_(\d+)$"),
                    ("dec", 0, r"rom_row_decode_array_0__bl_0_(\d+)$"),
                    ("dec", 1, r"rom_row_decode_wordline_buffer_0__in_(\d+)$"),
                    ("sel", 0, r"rom_column_decode_0__wl_(\d+)$"),
                    ("sel", 1, r"rom_column_mux_array_0__sel_(\d+)$"),
                    ("bl", 0, r"rom_base_array_0__bl_0_(\d+)$")]
            found = {}
            for n in node_names:
                for tag, prio, pat in pats:
                    m = re.search(pat, n)
                    if m:
                        found.setdefault((tag, int(m.group(1))), []).append((prio, len(n), n))
                if re.search(r"rom_row_decode_0__clk$", n):
                    found.setdefault(("clk_int", 0), []).append((0, len(n), n))
                if re.search(r"rom_column_decode_0__clk$", n):
                    found.setdefault(("precharge", 0), []).append((0, len(n), n))
            pick_name = lambda lst: sorted(lst)[0][2]
            for r in range(rows):
                if ("wl", r) in found:
                    probe_map[f"wl{r}"] = f"v(xrom.{pick_name(found[('wl', r)])})"
            for r in near:
                if ("dec", r) in found:
                    probe_map[f"dec{r}"] = f"v(xrom.{pick_name(found[('dec', r)])})"
            for w in range(wpr):
                if ("sel", w) in found:
                    probe_map[f"sel{w}"] = f"v(xrom.{pick_name(found[('sel', w)])})"
            for c in read_cols:
                if ("bl", c) in found:
                    probe_map[f"bl{c}"] = f"v(xrom.{pick_name(found[('bl', c)])})"
            for n in ("precharge", "clk_int"):
                if (n, 0) in found:
                    probe_map[n] = f"v(xrom.{pick_name(found[(n, 0)])})"
        wordlines = [probe_map[f"wl{r}"] for r in range(rows) if f"wl{r}" in probe_map]
        internal = [v for k, v in probe_map.items() if not k.startswith("wl")]
        nwl = len(wordlines)
        ndec = sum(1 for k in probe_map if k.startswith("dec"))
        nsel = sum(1 for k in probe_map if k.startswith("sel"))
        notes.append(f"probes ({'extracted' if flat else 'generator'} names): {nwl} of {rows} wordlines, "
                     f"{ndec} row-decoder outputs (rows {near[0]}..{near[-1]}, {len(near)} wanted), "
                     f"{nsel} of {wpr} column selects, "
                     f"{sum(1 for k in probe_map if k.startswith('bl'))} bitlines, "
                     f"clk_int {'yes' if 'clk_int' in probe_map else 'no'}, "
                     f"precharge {'yes' if 'precharge' in probe_map else 'no'}")
        if nwl < rows:
            notes.append(f"WARNING: only {nwl} of {rows} wordlines found by name")
        nbl = sum(1 for k in probe_map if k.startswith("bl"))
        if a.bitlines == "all" and nbl < cols:
            notes.append(f"WARNING: only {nbl} of {cols} bitlines found by name")
    if a.bitlines == "all":
        # the stored bits of the read row, for the row margins of analyze
        for cy in meta_cycles:
            if cy["kind"] == "read":
                cy["row_bits"] = bm[cy["row"]]
    # chain probes (generator netlist only): every node of the series chain of
    # the given columns, from the bitline down to the footer
    chains = {}
    if a.chain_cols:
        base = next((cn for cn in subs if cn.lower().endswith("_rom_base_array")), None)
        binst = next(((i, nn) for (i, nn, cn, _) in subs[top]["inst"] if cn == base), None) if base else None
        if not base or not binst:
            sys.exit("--chain-cols needs the generator's netlist (no *_rom_base_array instance in the top cell)")
        port_net = dict(zip(subs[base]["ports"], binst[1]))
        cells = {}
        for (iname, nn, cn, _) in subs[base]["inst"]:
            m = re.match(r"^xbit_r(\d+)_c(\d+)$", iname.lower())
            if m:
                cells[(int(m.group(1)), int(m.group(2)))] = (nn, cn.lower())
        if a.chain_cols == "auto":
            last = next((cy for cy in reversed(meta_cycles) if cy["kind"] == "read"), None)
            cols_req = sorted({b * wpr + last["word"] for b in (0, 1, wbits // 2, wbits - 1)}) if last else []
        else:
            cols_req = sorted({int(x) for x in a.chain_cols.split(",") if x.strip()})
        step = max(1, a.chain_step)
        for col in cols_req:
            top_port = f"bl_0_{col}"
            if top_port not in port_net or not (0, col) in cells:
                sys.exit(f"--chain-cols: column {col} not found in {base}")
            cur, ones, nodes, r, n_zero = top_port, 0, [], 0, 0
            while (r, col) in cells:
                nn, cn = cells[(r, col)]
                if cn.endswith("_rom_base_zero_cell"):
                    if nn[0] != cur:
                        sys.exit(f"--chain-cols: column {col}, row {r}: zero cell not on the chain node {cur}")
                    n_zero += 1
                    r += 1
                    continue
                n1, n2 = nn[0], nn[1]
                nxt = n1 if n2 == cur else (n2 if n1 == cur else None)
                if nxt is None:
                    sys.exit(f"--chain-cols: column {col}, row {r}: chain broken at {cur}")
                if nxt.lower() == "gnd":          # the footer (gate = precharge)
                    break
                ones += 1
                nodes.append({"node": nxt, "below_row": r, "ones_above": ones})
                cur = nxt
                r += 1
            one_rows = [nd["below_row"] for nd in nodes]
            keep = [i for i in range(len(nodes)) if i % step == 0 or i == len(nodes) - 1]
            for i in keep:
                nodes[i]["probe"] = f"v(xrom.{binst[0].lower()}.{nodes[i]['node'].lower()})"
            chains[str(col)] = {"bitline_probe": f"v(xrom.{port_net[top_port].lower()})",
                                "one_cells": ones, "zero_cells": n_zero, "one_rows": one_rows,
                                "nodes": [nodes[i] for i in keep], "nodes_total": len(nodes)}
            internal += [chains[str(col)]["bitline_probe"]] + [nodes[i]["probe"] for i in keep]
        internal = list(dict.fromkeys(internal))
        notes.append("chain probes: " + ", ".join(
            f"column {c} ({v['one_cells']} transistors, {v['zero_cells']} zero cells, "
            f"{len(v['nodes'])} of {v['nodes_total']} nodes saved)" for c, v in chains.items()))
    # Checkpoints: the transient pauses every --checkpoint ns of simulated time,
    # writes everything computed so far (to a temporary file, then renamed, so
    # a reader never sees a half-written file) and resumes. A run that is
    # stopped or still going therefore always leaves its data up to the last
    # checkpoint. Pausing does not change the result beyond the extra time
    # points it adds (checked in the sandbox: an RC circuit differed from an
    # uninterrupted run by at most 4 nV; the ROM bench's cycle energies by
    # under 1 %). Paths are relative: ngspice is started in the run directory.
    def dump():
        out = [f"wrdata tb_out.part " + " ".join(vec), "shell mv -f tb_out.part tb_out.txt"]
        if internal:
            out += [f"wrdata tb_int.part " + " ".join(internal), "shell mv -f tb_int.part tb_int.txt"]
        if wordlines:
            out += [f"wrdata tb_wl.part " + " ".join(wordlines), "shell mv -f tb_wl.part tb_wl.txt"]
        return out

    def check(target, what):
        """quit (after saving what exists) if the transient did not reach
        target. ngspice treats a condition it cannot evaluate (no vector
        'time' after a failed operating point) as false, so the failure
        branch is the 'else' of a test for success (sandbox-checked)."""
        out = ["if ( length(time) > 1 )",
               "  let e8_tlast = time[length(time)-1]",
               "else",
               "  let e8_tlast = 0",
               "end",
               f"if ( e8_tlast > {target:.6e} )",
               f"  echo E8_OK {what}",
               "else",
               f"  echo E8_FAILED the transient did not reach {target:.6e} s ({what})",
               "  shell touch tb_failed"]
        out += ["  " + d for d in dump()]
        out += ["  quit", "end"]
        return out
    cp = (a.checkpoint or a.period) * 1e-9
    stops_at = []
    x = cp
    while x < tstop - 0.5 * cp:
        stops_at.append(x)
        x += cp
    lines.append(".control")
    lines.append("set wr_singlescale")
    lines.append("set wr_vecnames")
    lines.append("option numdgt=8")
    lines.append("save " + " ".join(vec + internal + wordlines))
    if stops_at:
        lines.append(f"stop when time > {stops_at[0]:.6e}")
        lines.append("run")
        lines += check(stops_at[0] * 0.999, "first segment (operating point and start)")
        lines += dump()
        for x in stops_at[1:]:
            lines.append("delete all")
            lines.append(f"stop when time > {x:.6e}")
            lines.append("resume")
            lines += check(x * 0.999, f"segment ending at {x*1e9:.1f} ns")
            lines += dump()
        lines.append("delete all")
        lines.append("resume")
    else:
        lines.append("run")
    lines += check(tstop * 0.999, "last segment")
    lines += dump()
    lines.append("shell touch tb_done")
    lines.append("rusage time")
    lines.append("quit")
    lines.append(".endc")
    lines.append(".end")
    with open(os.path.join(a.out, "tb.sp"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    meta = {"top": top, "netlist": os.path.abspath(a.sp), "bin": os.path.abspath(a.bin),
            "word_bytes": a.word_bytes, "num_words": nw, "words_per_row": wpr, "cols": cols,
            "rows": rows, "col_bits": col_bits, "addr_bits": nab, "data_bits": ndb,
            "period_ns": a.period, "edge_ns": a.edge, "vdd": vdd, "cload_fF": a.cload,
            "tstop": tstop, "cycles": meta_cycles, "notes": notes, "models": a.models,
            "corner": a.corner, "temp": a.temp, "internal": internal,
            "probe_map": probe_map, "cs_delay_ns": a.cs_delay, "fix_asad": bool(a.fix_asad), "sanitize": bool(a.sanitize),
            "chains": chains}
    if a.bitlines == "all":
        meta["bitlines"] = "all"
    if reltol:
        meta["reltol"] = reltol
    with open(os.path.join(a.out, "tb_meta.json"), "w") as fh:
        json.dump(meta, fh, indent=1)
    print(f"bench written: {a.out}/tb.sp  ({len(cycles)} cycles, period {a.period} ns, "
          f"stop {tstop*1e9:.1f} ns, {nab} address bits, {ndb} data bits"
          + (f", reltol {reltol:g}" if reltol else "") + ")")
    for n in notes:
        print("   note: " + n)


# --------------------------------------------------------------------------
# analyze
# --------------------------------------------------------------------------
def read_wrdata(path):
    with open(path) as fh:
        header = fh.readline().split()
        cols = {h: [] for h in header}
        for line in fh:
            t = line.split()
            if len(t) != len(header):
                continue
            for h, v in zip(header, t):
                cols[h].append(float(v))
    return header, cols


def integ(t, y, t1, t2):
    """trapezoid integral of y over [t1, t2] with linear interpolation at ends"""
    s = 0.0
    n = len(t)
    for i in range(n - 1):
        a0, a1 = t[i], t[i + 1]
        if a1 <= t1 or a0 >= t2:
            continue
        lo, hi = max(a0, t1), min(a1, t2)
        if hi <= lo:
            continue
        f = lambda x: y[i] + (y[i + 1] - y[i]) * (x - a0) / (a1 - a0) if a1 > a0 else y[i]
        s += 0.5 * (f(lo) + f(hi)) * (hi - lo)
    return s


def value_at(t, y, x):
    lo, hi = 0, len(t) - 1
    if x <= t[0]:
        return y[0]
    if x >= t[-1]:
        return y[-1]
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if t[mid] <= x:
            lo = mid
        else:
            hi = mid
    a0, a1 = t[lo], t[hi]
    return y[lo] + (y[hi] - y[lo]) * (x - a0) / (a1 - a0) if a1 > a0 else y[lo]


def crossing(t, y, t0, t1, level, rising):
    """time of the first crossing of level between t0 and t1 (linear interpolation), or None"""
    for j in range(1, len(t)):
        if t[j] < t0:
            continue
        if t[j - 1] > t1:
            break
        y0, y1 = y[j - 1], y[j]
        if (rising and y0 < level <= y1) or (not rising and y0 > level >= y1):
            return t[j - 1] + (t[j] - t[j - 1]) * (level - y0) / (y1 - y0) if y1 != y0 else t[j]
    return None


def cmd_analyze(a):
    """Works on a finished run and on a run in progress: the deck rewrites
    tb_out.txt after every checkpoint, and cycles beyond the last written
    time are reported as not simulated yet."""
    meta = json.load(open(os.path.join(a.dir, "tb_meta.json")))
    failed = os.path.isfile(os.path.join(a.dir, "tb_failed"))
    if failed:
        why = ""
        plog = os.path.join(a.dir, "ngspice.log")
        if os.path.isfile(plog):
            with open(plog, errors="replace") as fh:
                for line in fh:
                    for part in line.split("\r"):
                        if "E8_FAILED" in part and "echo" not in part:
                            why = part.strip()
        print(f"P2R-E8.4 analysis: {meta['top']}: SIMULATION FAILED  {why}")
    pout = os.path.join(a.dir, "tb_out.txt")
    if not os.path.isfile(pout):
        print(f"P2R-E8.4 analysis: {meta['top']}: no waveform data written"
              + ("" if failed else " yet"))
        return
    header, c = read_wrdata(pout)
    t = c[header[0]]
    if len(t) < 2:
        print(f"P2R-E8.4 analysis: {meta['top']}: waveform file is empty")
        return
    for extra in ("tb_int.txt", "tb_wl.txt"):
        pint = os.path.join(a.dir, extra)
        if os.path.isfile(pint):
            h2, c2 = read_wrdata(pint)
            if len(c2.get(h2[0], [])) == len(t):
                for h in h2[1:]:
                    header.append(h)
                    c[h] = c2[h]
            else:
                print(f"   note: {extra} has a different number of time points; not used")
    pm = meta.get("probe_map", {})
    hkey = {h.lower(): h for h in header}
    pcol = {k: hkey.get(v.lower()) for k, v in pm.items() if hkey.get(v.lower())}
    wl_rows = sorted(int(k[2:]) for k in pcol if k.startswith("wl"))
    dec_rows = sorted(int(k[3:]) for k in pcol if k.startswith("dec"))
    sel_words = sorted(int(k[3:]) for k in pcol if k.startswith("sel"))
    vdd = meta["vdd"]
    key = lambda name: next((h for h in header if h.lower() == name.lower()), None)
    ivdd = c[key("i(vvdd)")]
    pvdd = [-vdd * x for x in ivdd]
    ins = [h for h in header if re.match(r"^i\(v(clk|cs|a\d+)\)$", h.lower())]
    pin = [0.0] * len(t)
    for h in ins:
        vk = key("v(" + re.match(r"^i\(v(.+)\)$", h.lower()).group(1) + ")")
        if vk is None:
            continue
        for j in range(len(t)):
            pin[j] += -c[vk][j] * c[h][j]
    nd = meta["data_bits"]
    dkeys = [key(f"v(d{i})") for i in range(nd)]
    T = meta["period_ns"] * 1e-9
    edge = meta["edge_ns"] * 1e-9
    cyc = meta["cycles"]
    t_end = t[-1]
    res = []
    hx = lambda bb: f"{int(''.join(map(str, bb)), 2):0{(len(bb)+3)//4}x}"
    wend = lambda cy: cy.get("tend") or (cy["trise"] + T)   # end of a cycle's energy window
    n_done = sum(1 for cy in cyc if wend(cy) <= t_end + 1e-12)
    state = "complete" if n_done == len(cyc) else "IN PROGRESS OR STOPPED"
    print(f"P2R-E8.4 analysis: {meta['top']}  period {meta['period_ns']} ns  vdd {vdd} V  "
          f"load {meta['cload_fF']} fF per output  points {len(t)}")
    print(f"data: simulated to {t_end*1e9:.1f} of {meta['tstop']*1e9:.1f} ns, "
          f"{n_done} of {len(cyc)} cycles complete ({state})")
    print("E_vdd: energy from the supply from this cycle's rising edge to the next one; "
          "P_after: supply power just before the next rising edge (static state after the cycle)")
    print(f"{'k':>3s} {'kind':5s} {'addr':>5s} {'row':>4s} {'w':>3s} {'precharge ns':>11s} {'z_row':>5s} {'z_word':>6s} "
          f"{'expected':>8s} {'read':>8s} {'ok':>3s} {'E_vdd pJ':>9s} {'E_in pJ':>8s} "
          f"{'P_after uW':>10s} {'t_acc ns':>8s}  dout min/max V")
    for k, cy in enumerate(cyc):
        t1 = cy["trise"]
        if wend(cy) > t_end + 1e-12:
            print(f"{k:3d} {cy['kind']:5s} not simulated yet")
            res.append({"k": k, "kind": cy["kind"], "complete": False})
            continue
        t2 = wend(cy)
        e_vdd = integ(t, pvdd, t1, t2)
        e_in = integ(t, pin, t1, t2)
        q1, q2 = t1 + 0.90 * (t2 - t1), t1 + 0.98 * (t2 - t1)
        p_after = integ(t, pvdd, q1, q2) / (q2 - q1)
        prev_reads = [cc for cc in cyc[:k] if cc["kind"] == "read"]
        t_pre = cy["trise"] - (prev_reads[-1]["tfall"] if prev_reads else 0.0)
        rec = {"k": k, "kind": cy["kind"], "complete": True, "addr": cy["addr"], "row": cy["row"],
               "word": cy["word"],
               "precharge_before_ns": t_pre * 1e9 if cy["kind"] == "read" else None,
               "zeros_in_row": cy["zeros_in_row"], "E_vdd_pJ": e_vdd * 1e12, "E_in_pJ": e_in * 1e12,
               "P_after_uW": p_after * 1e6}
        if cy["kind"] == "read":
            ts = cy["tfall"] - edge
            vals = [value_at(t, c[dk], ts) for dk in dkeys]
            bits = [1 if v > vdd / 2 else 0 for v in vals]
            exp = cy["expected"]
            ok = bits == exp
            tacc = 0.0
            for i, dk in enumerate(dkeys):
                yy = c[dk]
                last_bad = None
                for j in range(len(t)):
                    if t[j] < t1:
                        continue
                    if t[j] > ts:
                        break
                    if (yy[j] > vdd / 2) != (bits[i] == 1):
                        last_bad = j
                if last_bad is not None and last_bad + 1 < len(t):
                    tacc = max(tacc, t[last_bad + 1] - t1)
            win = [j for j in range(len(t)) if t1 <= t[j] <= ts]
            vmin = min(c[dk][j] for dk in dkeys for j in win) if win else float("nan")
            vmax = max(c[dk][j] for dk in dkeys for j in win) if win else float("nan")
            if pm:
                wb_ = meta["data_bits"]
                cands = [b * meta["words_per_row"] + cy["word"] for b in (0, wb_ // 2, wb_ - 1)
                         if exp[b] == 0]
                blk = next((pcol[f"bl{cc}"] for cc in cands if f"bl{cc}" in pcol), None)
            else:
                blk = next((h for h in header if re.match(r"^v\(xrom\.bl_\d+\)$", h.lower())), None)
            if blk:
                tb = None
                for j in range(len(t)):
                    if t[j] < t1 or t[j] > ts:
                        continue
                    if c[blk][j] < vdd / 2:
                        tb = t[j] - t1
                        break
                rec["t_bitline_half_ns"] = tb * 1e9 if tb is not None else None
            rec.update({"read_bits": bits, "expected_bits": exp, "ok": ok,
                        "wrong_bits": sum(1 for x, y in zip(bits, exp) if x != y),
                        "ok_if_bit_order_reversed": list(reversed(bits)) == exp,
                        "zeros_in_word": exp.count(0), "t_access_ns": tacc * 1e9,
                        "dout_min_V": vmin, "dout_max_V": vmax})
            print(f"{k:3d} {cy['kind']:5s} {cy['addr']:5d} {cy['row']:4d} {cy['word']:3d} "
                  f"{t_pre*1e9:11.1f} "
                  f"{cy['zeros_in_row']:5d} {exp.count(0):6d} {hx(exp):>8s} {hx(bits):>8s} "
                  f"{'yes' if ok else 'NO':>3s} {e_vdd*1e12:9.3f} {e_in*1e12:8.3f} "
                  f"{p_after*1e6:10.2f} {tacc*1e9:8.2f}  {vmin:.2f}/{vmax:.2f}"
                  + (f"  bitline below VDD/2 after {rec['t_bitline_half_ns']:.2f} ns"
                     if rec.get("t_bitline_half_ns") is not None else ""))
            # which rows and words the decoders selected (full probes)
            if wl_rows or sel_words or dec_rows:
                j0 = next((j for j in range(len(t)) if t[j] >= t1), len(t) - 1)
                j1 = next((j for j in range(len(t)) if t[j] > ts), len(t))
                sel_rows = [r for r in wl_rows if value_at(t, c[pcol[f"wl{r}"]], ts) < vdd / 2]
                low_any = [r for r in wl_rows
                           if min(c[pcol[f"wl{r}"]][j0:j1] or [vdd]) < vdd / 2]
                words_on = [w for w in sel_words if value_at(t, c[pcol[f"sel{w}"]], ts) > vdd / 2]
                worst = None
                for r in dec_rows:
                    if r == cy["row"]:
                        continue
                    m = min(c[pcol[f"dec{r}"]][j0:j1] or [vdd])
                    if worst is None or m < worst[0]:
                        worst = (m, r)
                rec.update({"rows_selected": sel_rows, "rows_low_during_read": low_any,
                            "words_selected": words_on,
                            "worst_unselected_decoder_V": worst[0] if worst else None,
                            "worst_unselected_decoder_row": worst[1] if worst else None,
                            "selection_ok": (sel_rows == [cy["row"]] if wl_rows else True)
                                            and (words_on == [cy["word"]] if sel_words else True)})
                fmt = lambda xs: "[" + ",".join(map(str, xs[:8])) + (",..." if len(xs) > 8 else "") + "]"
                print(f"      selection: rows {fmt(sel_rows)} (expected [{cy['row']}])"
                      + (f", low at some time {fmt(low_any)}" if low_any != sel_rows else "")
                      + (f"; words {fmt(words_on)} (expected [{cy['word']}])" if sel_words else "")
                      + (f"; lowest unselected row-decoder output {worst[0]:.2f} V (row {worst[1]})"
                         if worst else "")
                      + ("" if rec["selection_ok"] else "   <-- WRONG SELECTION"))
            # order of the array evaluation and the row selection: the array
            # precharge net rising (precharge PMOS off, column footers on) and
            # the selected wordline falling, both through VDD/2, after the clock
            # edge; footer-to-wordline > 0 means the columns conduct to ground
            # with every row still on for that long
            if "precharge" in pcol and f"wl{cy['row']}" in pcol:
                tw0, tw1 = t1 - edge, ts
                tclk = crossing(t, c[pcol["clk_int"]], tw0, tw1, vdd / 2, True) if "clk_int" in pcol else None
                tft = crossing(t, c[pcol["precharge"]], tw0, tw1, vdd / 2, True)
                twl = crossing(t, c[pcol[f"wl{cy['row']}"]], tw0, tw1, vdd / 2, False)
                rel = lambda x: (x - t1) * 1e9 if x is not None else None
                rec.update({"t_clk_int_ns": rel(tclk), "t_footer_on_ns": rel(tft), "t_wl_low_ns": rel(twl),
                            "footer_to_wl_ns": (twl - tft) * 1e9 if (tft is not None and twl is not None) else None})
                f2 = lambda x: f"{x:.3f}" if x is not None else "-"
                print(f"      timing after the clock edge: internal clock {f2(rel(tclk))} ns, array footers on "
                      f"{f2(rel(tft))} ns, wordline {cy['row']} low {f2(rel(twl))} ns; footers on before the row "
                      f"is selected by {f2(rec['footer_to_wl_ns'])} ns"
                      + ("   <-- columns conduct with every row on" if (rec["footer_to_wl_ns"] or -1) > 0 else ""))
            # row margins (all bitlines saved): every cell of the read row is
            # evaluated, whichever word the column multiplexer selects
            rb = cy.get("row_bits")
            if meta.get("bitlines") == "all" and rb:
                wpr_ = meta["words_per_row"]
                jw = [j for j in range(len(t)) if t1 <= t[j] <= ts]
                one_by_col, zero_max, n0 = {}, None, 0
                for col in range(len(rb)):
                    h = pcol.get(f"bl{col}")
                    if not h or not jw:
                        continue
                    if rb[col] == 1:
                        one_by_col[col] = min(c[h][j] for j in jw)
                    else:
                        n0 += 1
                        v = value_at(t, c[h], ts)
                        if zero_max is None or v > zero_max[0]:
                            zero_max = (v, col)
                one_min = min(((v, col) for col, v in one_by_col.items()), default=None)
                own = [(one_by_col[b * wpr_ + cy["word"]], b) for b in range(len(exp))
                       if exp[b] == 1 and (b * wpr_ + cy["word"]) in one_by_col]
                own_min = min(own, default=None)
                rec.update({"bl1_by_col": {str(k2): v for k2, v in sorted(one_by_col.items())},
                            "bl1_min_V": one_min[0] if one_min else None,
                            "bl1_min_col": one_min[1] if one_min else None,
                            "bl0_max_V": zero_max[0] if zero_max else None,
                            "bl0_max_col": zero_max[1] if zero_max else None,
                            "word_bl1_min_V": own_min[0] if own_min else None,
                            "word_bl1_min_bit": own_min[1] if own_min else None})
                cw = lambda col: f"column {col} = bit {col // wpr_} of word {col % wpr_}"
                print(f"      bitlines of row {cy['row']}: {len(one_by_col)} one cells, lowest while evaluating "
                      + (f"{one_min[0]:.3f} V ({cw(one_min[1])})" if one_min else "-")
                      + f"; {n0} zero cells, highest at sampling "
                      + (f"{zero_max[0]:.3f} V ({cw(zero_max[1])})" if zero_max else "-")
                      + "; word read: lowest one bit "
                      + (f"{own_min[0]:.3f} V (bit {own_min[1]})" if own_min else "- (no one bit)"))
        else:
            span = f"{(t2 - t1)*1e9:.0f} ns" if cy["kind"] == "wait" else ""
            print(f"{k:3d} {cy['kind']:5s} {'':>5s} {'':>4s} {'':>3s} {span:>11s} {'':>5s} {'':>6s} {'':>8s} "
                  f"{'':>8s} {'':>3s} {e_vdd*1e12:9.3f} {e_in*1e12:8.3f} {p_after*1e6:10.2f}")
            if cy["kind"] == "wait":
                rec["len_ns"] = (t2 - t1) * 1e9
        res.append(rec)
    done = [r for r in res if r.get("complete")]
    reads = [r for r in done[1:] if r["kind"] == "read"]
    idles = [r for r in done[1:] if r["kind"] == "idle"]
    stops = []                       # the stopped cycles at the end of the sequence
    for r, cy in zip(res, cyc):
        if r["kind"] == "stop" and r.get("complete"):
            stops.append(cy)
        else:
            stops = []
    summ = {"cycles_complete": len(done), "cycles_total": len(cyc),
            "simulated_ns": t_end * 1e9, "tstop_ns": meta["tstop"] * 1e9, "failed": failed}
    if reads:
        summ["reads"] = len(reads)
        summ["reads_ok"] = sum(1 for r in reads if r["ok"])
        if any("selection_ok" in r for r in reads):
            summ["reads_selection_ok"] = sum(1 for r in reads if r.get("selection_ok"))
        summ["E_read_pJ_mean"] = sum(r["E_vdd_pJ"] for r in reads) / len(reads)
        summ["E_read_pJ_min"] = min(r["E_vdd_pJ"] for r in reads)
        summ["E_read_pJ_max"] = max(r["E_vdd_pJ"] for r in reads)
        summ["t_access_ns_max"] = max(r["t_access_ns"] for r in reads)
        b1 = [r["bl1_min_V"] for r in reads if r.get("bl1_min_V") is not None]
        b0 = [r["bl0_max_V"] for r in reads if r.get("bl0_max_V") is not None]
        if b1:
            summ["bl1_min_V"] = min(b1)
        if b0:
            summ["bl0_max_V"] = max(b0)
    if idles:
        summ["E_idle_clocked_pJ_mean"] = sum(r["E_vdd_pJ"] for r in idles) / len(idles)
    if len(stops) >= 2:
        tA = stops[len(stops) // 2]["trise"]
        tB = stops[-1]["trise"] + (wend(stops[-1]) - stops[-1]["trise"]) / 2
        summ["P_stopped_uW"] = integ(t, pvdd, tA, tB) / (tB - tA) * 1e6
    print("summary: " + json.dumps(summ))
    json.dump({"meta": meta, "cycles": res, "summary": summ},
              open(a.json_out or os.path.join(a.dir, "result.json"), "w"), indent=1)


def cmd_pick(a):
    """Propose a smoke-test sequence.
    main:
      i   idle cycle (start from the precharged state)
      rL  bottom row, the word with the most one bits, read from the fully
          precharged state: the selected cells sit at the far end of the
          chains, so each bitline must hold its charge against the chain
          nodes above the selected row (charge sharing)
      rA  top row, the word with the most zero bits: many bitlines discharge
          through their whole chain
      rM  the row with the most zero bits, its word with the most zeros
      rA  the first word again (repeatability)
      rO  a word with no zero bit if there is one (it leaves every output at
          1, so the static current after it is leakage only); read right
          after many chains were discharged, it also tests the precharge
      i   idle cycle with the clock running
      s3  three cycles with the clock stopped
    recovery: for k = 2, 5, 15: rM, k cycles with the clock stopped (the
      ROM precharges), rL. The first rL that reads correctly bounds the
      precharge time a bottom-row read needs after a read that discharged
      many chains.
    sweep: the same question on a finer scale: for each N in --waits (ns),
      rM, a wait of N ns with the clock held low, rL. The precharge before
      rL is N + period/2.
    idle: the static current after a read with zero bits while the clock
      keeps running (CS low), and the effect of reading a word with no zero
      bit ("parking read", rP; the one in the lowest-numbered row):
      i, rM, rP, i x 10, rM, i x 20, rP, i x 5.
    rowmap (--row R): the precharge a read of row R needs after the worst
      preceding read: for each N in --waits, rA (row 0, the word with the
      most zero bits: a read of row 0 discharges every node below row 0 in
      every column), a wait of N ns with the clock held low, rR (row R, the
      word with the most one bits: a one bit is read correctly only if its
      bitline keeps its charge against the chain nodes above row R).
    deep (--deep-rows K): i, then for each N in --waits and each of the K
      deepest rows R (deepest first; row 0 excluded): rA, a wait of N ns, rR
      (the word of row R with the most one bits). With bench --bitlines all,
      each read of R tests every cell of row R.
    words (--addrs A1,A2,...): i, then for each N in --waits and each address
      Ai: rA, a wait of N ns, rAi."""
    data = open(a.bin, "rb").read()
    nw, wpr, cols, rows = organisation(len(data), a.word_bytes, a.words_per_row)
    bm = bitmap(data, a.word_bytes, wpr, cols)
    wb = a.word_bytes * 8
    col_bits = max(1, math.ceil(math.log2(wpr))) if wpr > 1 else 0
    zr = [bm[r].count(0) for r in range(rows)]
    wbits = lambda r, w: [bm[r][b * wpr + w] for b in range(wb)]
    addr = lambda r, w: (r << col_bits) | w
    most0 = lambda r: max(range(wpr), key=lambda w: wbits(r, w).count(0))
    most1 = lambda r: max(range(wpr), key=lambda w: wbits(r, w).count(1))
    r_max = max(range(rows), key=lambda r: zr[r])
    A = addr(0, most0(0))
    L = addr(rows - 1, most1(rows - 1))
    M = addr(r_max, most0(r_max))
    ones = [(r, w) for r in range(rows) for w in range(wpr) if wbits(r, w).count(0) == 0]
    if ones:
        P = addr(*min(ones))                     # lowest row first, then lowest word
    else:
        P = addr(0, most1(0))
    if a.mode == "recovery":
        # precharge needed after the row with the most zeros before a bottom-row read
        seq = ["i"]
        for k in (2, 5, 15):
            seq += [f"r{M}", f"s{k}", f"r{L}"]
    elif a.mode == "sweep":
        seq = ["i"]
        for n in [float(x) for x in a.waits.split(",") if x.strip()]:
            seq += [f"r{M}"] + ([f"w{n:g}"] if n > 0 else []) + [f"r{L}"]
    elif a.mode == "idle":
        seq = ["i", f"r{M}", f"r{P}"] + ["i"] * 10 + [f"r{M}"] + ["i"] * 20 + [f"r{P}"] + ["i"] * 5
    elif a.mode == "rowmap":
        if a.row is None or not (0 < a.row < rows):
            sys.exit(f"rowmap needs --row between 1 and {rows - 1}")
        R = addr(a.row, most1(a.row))
        seq = ["i"]
        for n in [float(x) for x in a.waits.split(",") if x.strip()]:
            seq += [f"r{A}"] + ([f"w{n:g}"] if n > 0 else []) + [f"r{R}"]
    elif a.mode == "deep":
        k_rows = min(a.deep_rows, rows - 1)
        if k_rows < 1:
            sys.exit("deep needs --deep-rows of at least 1 and a macro of at least 2 rows")
        targets = [addr(r, most1(r)) for r in range(rows - 1, rows - 1 - k_rows, -1)]
        seq = ["i"]
        for n in [float(x) for x in a.waits.split(",") if x.strip()]:
            for T_ in targets:
                seq += [f"r{A}"] + ([f"w{n:g}"] if n > 0 else []) + [f"r{T_}"]
    elif a.mode == "words":
        targets = [int(x) for x in (a.addrs or "").split(",") if x.strip()]
        if not targets:
            sys.exit("words needs --addrs")
        for T_ in targets:
            r_, w_ = T_ >> col_bits, T_ & ((1 << col_bits) - 1)
            if not (0 < r_ < rows and w_ < wpr):
                sys.exit(f"address {T_} (row {r_}, word {w_}) is not a word of rows 1..{rows - 1}")
        seq = ["i"]
        for n in [float(x) for x in a.waits.split(",") if x.strip()]:
            for T_ in targets:
                seq += [f"r{A}"] + ([f"w{n:g}"] if n > 0 else []) + [f"r{T_}"]
    else:
        seq = ["i", f"r{L}", f"r{A}", f"r{M}", f"r{A}"]
        if ones:
            seq.append(f"r{addr(*ones[-1])}")
        seq += ["i", "s3"]
    sys.stderr.write(f"rows {rows}, words per row {wpr}, zero bits per row: min {min(zr)}, "
                     f"max {max(zr)} (row {r_max}), mean {sum(zr)/rows:.1f} of {cols}; "
                     f"words with no zero bit: {len(ones)}\n")
    if a.mode == "rowmap":
        rc = lambda x: f"{x} (row {x >> col_bits}, word {x & ((1 << col_bits) - 1)})"
        wa, wr = A & ((1 << col_bits) - 1), R & ((1 << col_bits) - 1)
        sys.stderr.write(f"A = {rc(A)}, {wbits(0, wa).count(0)} zero bits in the word, {zr[0]} in row 0; "
                         f"R = {rc(R)}, {wbits(a.row, wr).count(1)} one bits in the word, "
                         f"{zr[a.row]} zero bits in row {a.row}\n")
    if a.mode in ("deep", "words"):
        msk = (1 << col_bits) - 1
        sys.stderr.write(f"A = {A} (row 0, word {A & msk}), {zr[0]} zero bits in row 0; targets: "
                         + ", ".join(f"{T_} (row {T_ >> col_bits}, word {T_ & msk}, "
                                     f"{wbits(T_ >> col_bits, T_ & msk).count(1)} one bits)" for T_ in targets)
                         + "\n")
    if a.mode in ("sweep", "idle"):
        rc = lambda x: f"{x} (row {x >> col_bits}, word {x & ((1 << col_bits) - 1)})"
        sys.stderr.write(f"M = {rc(M)}, {zr[M >> col_bits]} zero bits in its row; L = {rc(L)}, "
                         f"{zr[L >> col_bits]} zero bits in its row"
                         + (f"; P = {rc(P)}, no zero bit" if a.mode == "idle" else "") + "\n")
    print(",".join(seq))


def cmd_compare(a):
    """Side-by-side per-cycle table of several analysed runs of the same
    sequence (result.json of each run directory)."""
    runs = []
    for d, lab in zip(a.dirs, a.labels):
        p = os.path.join(d, "result.json")
        if not os.path.isfile(p):
            print(f"   {lab}: no result.json in {d}")
            continue
        r = json.load(open(p))
        runs.append((lab, {c["k"]: c for c in r["cycles"]}, r["meta"]["cycles"]))
    if not runs:
        return
    cyc = runs[0][2]
    hx = lambda bb: f"{int(''.join(map(str, bb)), 2):04x}" if bb else "-"
    head = f"{'k':>3s} {'kind':5s} {'addr':>5s} {'row':>4s} {'w':>3s} {'expect':>6s}"
    for lab, _, _ in runs:
        head += f" | {lab[:14]:>14s}: {'read':>4s} {'E pJ':>7s} {'P_after':>8s} {'t_acc':>6s}"
    print(head)
    for cy in cyc:
        k = cy["k"]
        line = (f"{k:3d} {cy['kind']:5s} {cy['addr'] if cy['addr'] is not None else '':>5} "
                f"{cy['row'] if cy['row'] is not None else '':>4} {cy['word'] if cy['word'] is not None else '':>3} "
                f"{hx(cy['expected']) if cy['expected'] else '':>6s}")
        for lab, res, _ in runs:
            c = res.get(k)
            if not c or not c.get("complete"):
                line += f" | {'':>14s}  {'not simulated':>28s}"
                continue
            rd = hx(c["read_bits"]) + ("" if c.get("ok") else "!") if c["kind"] == "read" else ""
            ta = f"{c['t_access_ns']:6.2f}" if c["kind"] == "read" else ""
            line += f" | {'':>14s}  {rd:>5s} {c['E_vdd_pJ']:7.2f} {c['P_after_uW']:8.2f} {ta:>6s}"
        print(line)
    print("('!' after a read value: differs from the stored word; P_after in uW; t_acc in ns)")


def parse_base_array_cells(sp_path, top):
    """{(row, col): 1 or 0} from the generator netlist's data array
    (<top>_rom_base_array: Xbit_r<row>_c<col> ... <top>_rom_base_one_cell or
    _zero_cell; continuation lines start with '+'). Same parser as E8.3's
    e8_3_rom_tools.py check."""
    target = f"{top}_rom_base_array"
    cells, inside, rec = {}, False, None

    def flush(r):
        if r is None:
            return
        m = re.match(r"Xbit_r(\d+)_c(\d+)$", r[0])
        if m and len(r) > 1:
            if r[-1].endswith("rom_base_one_cell"):
                cells[(int(m.group(1)), int(m.group(2)))] = 1
            elif r[-1].endswith("rom_base_zero_cell"):
                cells[(int(m.group(1)), int(m.group(2)))] = 0

    with open(sp_path, errors="replace") as fh:
        for line in fh:
            tk = line.split()
            if not tk:
                continue
            if tk[0].upper() == ".SUBCKT":
                inside = (tk[1] == target)
                rec = None
                continue
            if not inside:
                continue
            if tk[0].upper() == ".ENDS":
                flush(rec)
                break
            if tk[0].startswith("X"):
                flush(rec)
                rec = tk[:]
            elif tk[0] == "+" and rec is not None:
                rec += tk[1:]
            else:
                flush(rec)
                rec = None
    return cells


def cmd_bitcheck(a):
    """The generated netlist stores exactly the data file, bit by bit, in the
    organisation given (E8.3 gate G7 for one macro)."""
    data = open(a.bin, "rb").read()
    nw, wpr, cols, rows = organisation(len(data), a.word_bytes, a.words_per_row)
    bm = bitmap(data, a.word_bytes, wpr, cols)
    cells = parse_base_array_cells(a.sp, a.top)
    errors = sum(1 for r in range(rows) for c in range(cols) if cells.get((r, c)) != bm[r][c])
    dummy_ok = all(cells.get((rows, c)) == 1 for c in range(cols))
    extra = [rc for rc in cells if rc[0] > rows or rc[1] >= cols]
    ok = errors == 0 and dummy_ok and not extra and len(cells) == (rows + 1) * cols
    print(f"{a.top}: {nw} words, {wpr} words per row, {rows} rows x {cols} columns; "
          f"cells {len(cells)} (expected {(rows + 1) * cols}), bit errors {errors}, "
          f"dummy row {'ok' if dummy_ok else 'BAD'}{', EXTRA CELLS' if extra else ''} -> "
          f"{'STORES THE DATA EXACTLY' if ok else 'CHECK FAILED'}")
    sys.exit(0 if ok else 2)


def cmd_orgsum(a):
    """Comparison of ROM organisations from a JSON list (written by
    e8_4a3_rom_org.sh): label, bin, word_bytes, wpr, lef, box_log, lvs_log and
    the run directories main, sweep, idle (any may be missing)."""
    spec = json.load(open(a.spec))

    def lef_size(p):
        try:
            for line in open(p):
                m = re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", line)
                if m:
                    return float(m.group(1)), float(m.group(2))
        except (OSError, TypeError):
            pass
        return None

    def box_size(p):
        try:
            for line in open(p, errors="replace"):
                if line.startswith("microns:"):
                    f = line.split()
                    return float(f[1]), float(f[3])
        except (OSError, TypeError):
            pass
        return None

    def lvs_state(p):
        try:
            s = open(p, errors="replace").read()
        except (OSError, TypeError):
            return "not run"
        if "Circuits match uniquely" in s:
            return "match"
        if "do not match" in s or "MISMATCH" in s:
            return "MISMATCH"
        return "unclear"

    def result(d):
        try:
            return json.load(open(os.path.join(d, "result.json")))
        except (OSError, TypeError, ValueError):
            return None

    def ext_errors(p):
        # magic prints "Total of N errors (check feedback entries)." when the
        # extraction found errors, and nothing when there were none
        try:
            s = open(p, errors="replace").read()
        except (OSError, TypeError):
            return "-"
        m = re.search(r"Total of (\d+) errors", s)
        return m.group(1) if m else "0"

    print("A. area (um; mm2 = layout extent; x50 = 50 macros)")
    print(f"   {'organisation':34s} {'rows x cols':>11s} {'LEF W x H':>19s} {'layout W x H':>19s} "
          f"{'layout mm2':>10s} {'x50 mm2':>8s} {'vs first':>8s}")
    base = None
    for o in spec:
        data = open(o["bin"], "rb").read()
        nw, wpr, cols, rows = organisation(len(data), o["word_bytes"], o.get("wpr"))
        lw = lef_size(o.get("lef"))
        bw = box_size(o.get("box_log"))
        area = bw[0] * bw[1] / 1e6 if bw else None
        if base is None and area:
            base = area
        print(f"   {o['label']:34s} {f'{rows} x {cols}':>11s} "
              f"{(f'{lw[0]:.2f} x {lw[1]:.2f}' if lw else '-'):>19s} "
              f"{(f'{bw[0]:.3f} x {bw[1]:.3f}' if bw else '-'):>19s} "
              f"{(f'{area:.5f}' if area else '-'):>10s} {(f'{50*area:.3f}' if area else '-'):>8s} "
              f"{(f'{area/base:.3f}' if area and base else '-'):>8s}")

    print("\nB. post-layout function and energy (main sequence; energy per 100 ns cycle)")
    print(f"   {'organisation':34s} {'LVS':>8s} {'ext err':>7s} {'reads ok':>8s} {'sel ok':>7s} {'E row w/ 0s pJ':>18s} "
          f"{'E row no 0 pJ':>15s} {'E idle pJ':>9s} {'t_acc max ns':>12s} {'decoder min V':>13s}")
    for o in spec:
        r = result(o.get("main"))
        lvs = lvs_state(o.get("lvs_log"))
        xe = ext_errors(o.get("extract_log"))
        if not r:
            print(f"   {o['label']:34s} {lvs:>8s} {xe:>7s}  no main result")
            continue
        cyc = [c for c in r["cycles"] if c.get("complete")]
        reads = [c for c in cyc if c["kind"] == "read"]
        okr = [c for c in reads if c.get("ok")]
        z = [c["E_vdd_pJ"] for c in okr if c.get("zeros_in_row")]
        nz = [c["E_vdd_pJ"] for c in okr if c.get("zeros_in_row") == 0]
        idle0 = cyc[0]["E_vdd_pJ"] if cyc and cyc[0]["kind"] == "idle" else None
        tac = [c["t_access_ns"] for c in okr if c.get("zeros_in_word")]
        dec = [c["worst_unselected_decoder_V"] for c in reads if c.get("worst_unselected_decoder_V") is not None]
        sel = [c for c in reads if "selection_ok" in c]
        n_sel_ok = sum(1 for c in sel if c["selection_ok"])
        s_reads = f"{len(okr)}/{len(reads)}"
        s_sel = f"{n_sel_ok}/{len(sel)}" if sel else "-"
        print(f"   {o['label']:34s} {lvs:>8s} {xe:>7s} {s_reads:>8s} {s_sel:>7s} "
              f"{(f'{min(z):.1f}-{max(z):.1f}' if z else '-'):>18s} "
              f"{(f'{min(nz):.1f}-{max(nz):.1f}' if nz else '-'):>15s} "
              f"{(f'{idle0:.2f}' if idle0 is not None else '-'):>9s} "
              f"{(f'{max(tac):.2f}' if tac else '-'):>12s} {(f'{min(dec):.2f}' if dec else '-'):>13s}")

    print("   ext err: magic extraction errors of the layout (must be 0; LVS can match while poly over diffusion")
    print("   forms extra transistors on the mask); reads ok: read value = stored word; sel ok: only the right")
    print("   row and word selected; E row w/ 0s:")
    print("   correct reads of rows with zero bits (min-max); E row no 0: rows without zero bits; E idle: first")
    print("   cycle, clock running, no read; t_acc: correct reads of words with zero bits; decoder min: lowest")
    print("   unselected row-decoder output during the reads")
    print("\nC. recovery: bottom-row read after the row with the most zero bits "
          "(precharge ns: ok, or number of wrong bits)")
    for o in spec:
        r = result(o.get("sweep"))
        if not r:
            print(f"   {o['label']:34s} no sweep result")
            continue
        reads = [c for c in r["cycles"] if c.get("complete") and c["kind"] == "read"]
        if not reads:
            print(f"   {o['label']:34s} no reads")
            continue
        last_addr = reads[-1]["addr"]
        pts = [(c["precharge_before_ns"], c.get("ok"), c.get("wrong_bits")) for c in reads if c["addr"] == last_addr]
        txt = "  ".join(f"{p:.0f}: {'ok' if ok else str(w) + ' wrong'}" for p, ok, w in pts)
        okp = [p for p, ok, _ in pts if ok]
        need = None
        for i in range(len(pts)):
            if all(ok for _, ok, _ in pts[i:]):
                need = pts[i][0]
                break
        print(f"   {o['label']:34s} {txt}")
        print(f"   {'':34s} -> correct from {need:.0f} ns on" if need is not None
              else f"   {'':34s} -> never correct in the sweep")

    print("\nD. static current with the clock running (idle sequence: i, rM, rP, i x10, rM, i x20, rP, i x5)")
    print(f"   {'organisation':34s} {'P after rM uW':>13s} {'after rM,i20 uW':>15s} {'E idle, no park pJ':>18s} "
          f"{'E park read pJ':>14s} {'P after park uW':>15s} {'E idle, parked pJ':>17s} {'park reads ok':>13s}")
    for o in spec:
        r = result(o.get("idle"))
        if not r:
            print(f"   {o['label']:34s} no idle result")
            continue
        cyc = r["cycles"]
        if not all(c.get("complete") for c in cyc):
            print(f"   {o['label']:34s} incomplete")
            continue
        rd = [i for i, c in enumerate(cyc) if c["kind"] == "read"]
        if len(rd) < 4:
            print(f"   {o['label']:34s} unexpected sequence")
            continue
        m1, p1, m2, p2 = rd[:4]
        idle_after_park = [cyc[i]["E_vdd_pJ"] for i in range(p1 + 1, m2)]
        idle_no_park = [cyc[i]["E_vdd_pJ"] for i in range(m2 + 1, p2)]
        mean = lambda xs: sum(xs) / len(xs) if xs else float("nan")
        s_park = f"{int(bool(cyc[p1].get('ok'))) + int(bool(cyc[p2].get('ok')))}/2"
        print(f"   {o['label']:34s} {cyc[m2]['P_after_uW']:13.2f} {cyc[p2 - 1]['P_after_uW']:15.2f} "
              f"{mean(idle_no_park):18.3f} {cyc[p2]['E_vdd_pJ']:14.3f} {cyc[p2]['P_after_uW']:15.2f} "
              f"{mean(idle_after_park):17.3f} {s_park:>13s}")
    print("\n   P after rM: supply power at the end of the cycle that read rM (before the 20 idle cycles);")
    print("   after rM,i20: at the end of the 20th idle cycle; E idle, no park: mean energy of those 20 idle cycles;")
    print("   E park read / P after park: the parking read after them; E idle, parked: mean energy of the 10 idle")
    print("   cycles that follow a parking read made right after rM.")


def cmd_chains(a):
    """Chain-node voltages of the columns saved with bench --chain-cols, for
    every read of a word that has a bit in one of them: the bitline at the
    rising edge and its lowest value during the evaluation, and the chain
    nodes above the read row at the rising edge (first, quarter, middle,
    three quarters, last, lowest). A one bit is read correctly only if its
    bitline stays above the bitline inverter's switching level while it
    shares its charge with these nodes."""
    meta = json.load(open(os.path.join(a.dir, "tb_meta.json")))
    chains = meta.get("chains") or {}
    if not chains:
        print(f"{a.dir}: no chain probes in this run")
        return
    pres = os.path.join(a.dir, "result.json")
    pint = os.path.join(a.dir, "tb_int.txt")
    if not (os.path.isfile(pres) and os.path.isfile(pint)):
        print(f"{a.dir}: run analyze first (result.json and tb_int.txt needed)")
        return
    res = json.load(open(pres))["cycles"]
    hdr, c = read_wrdata(pint)
    t = c[hdr[0]]
    hkey = {h.lower(): h for h in hdr}
    wpr = meta["words_per_row"]
    last = next((cy for cy in reversed(meta["cycles"]) if cy["kind"] == "read"), None)
    target = last["addr"] if (last and not a.all_reads) else None
    print(f"chain nodes of {meta['top']} ({meta['rows']} rows, {wpr} words per row); "
          + (f"reads of address {target} (row {last['row']}, word {last['word']}); " if target is not None else "")
          + "voltages in V at the rising edge of the read; BLmin = lowest bitline voltage while evaluating")
    for col, ch in sorted(chains.items(), key=lambda kv: int(kv[0])):
        print(f"   column {col} (bit {int(col) // wpr} of word {int(col) % wpr}): {ch['one_cells']} transistors "
              f"and {ch['zero_cells']} zero cells in the chain; {len(ch['nodes'])} of {ch['nodes_total']} nodes saved")
    print(f"   {'k':>3} {'row':>4} {'pre ns':>7} {'col':>4} {'bit':>3} {'exp':>3} {'got':>3} {'1-cells':>7} |"
          f" {'BL':>5} {'BLmin':>5} | {'first':>5} {'1/4':>5} {'1/2':>5} {'3/4':>5} {'last':>5} {'lowest':>6}")
    for cy, r in zip(meta["cycles"], res):
        if cy["kind"] != "read" or not r.get("complete"):
            continue
        if target is not None and cy["addr"] != target:
            continue
        for col, ch in sorted(chains.items(), key=lambda kv: int(kv[0])):
            col = int(col)
            if col % wpr != cy["word"]:
                continue
            b = col // wpr
            exp, got = cy["expected"][b], r["read_bits"][b]
            row = cy["row"]
            above = [n for n in ch["nodes"] if n["below_row"] < row and hkey.get(n["probe"].lower())]
            if not above:
                continue            # nothing above the read cell (row 0, or zero cells only)
            n_one = sum(1 for x in ch.get("one_rows", []) if x < row)
            tr, tf = cy["trise"], cy["tfall"]
            blh = hkey.get(ch["bitline_probe"].lower())
            v_at = lambda h, x: value_at(t, c[h], x)
            bl0 = v_at(blh, tr) if blh else float("nan")
            win = [j for j in range(len(t)) if tr <= t[j] <= tf]
            blmin = min(c[blh][j] for j in win) if (blh and win) else float("nan")
            if above:
                vals = [v_at(hkey[n["probe"].lower()], tr) for n in above]
                pick = [vals[0], vals[len(vals) // 4], vals[len(vals) // 2], vals[(3 * len(vals)) // 4], vals[-1]]
                nodes_s = " ".join(f"{v:5.3f}" for v in pick) + f" {min(vals):6.3f}"
            else:
                nodes_s = "(no saved node above the read row)"
            flag = "" if exp == got else "  <-- WRONG"
            print(f"   {cy['k']:>3} {row:>4} {r['precharge_before_ns']:7.0f} {col:>4} {b:>3} {exp:>3} {got:>3} "
                  f"{n_one:>7} | {bl0:5.3f} {blmin:5.3f} | {nodes_s}{flag}")


def cmd_rowmap(a):
    """Precharge needed by a read of each target word: the target reads at
    each precharge, 'ok' or the number of wrong bits ('x' marks a read that
    selected a wrong row or word; with all bitlines saved, the lowest bitline
    of the word's one bits follows), the precharge from which every read of
    the word is correct, and whether it is safe at the system's lookup
    interval (precharge available = interval - half a period, the
    evaluation). The targets of a run are the addresses read other than the
    first one (rowmap, deep and words sequences start each pair with a read
    of row 0); a run that reads one address only has that one as target."""
    entries, pre_all, multi = [], set(), False
    for d in a.dirs:
        try:
            meta = json.load(open(os.path.join(d, "tb_meta.json")))
            res = json.load(open(os.path.join(d, "result.json")))["cycles"]
        except (OSError, ValueError):
            entries.append((d, None, None, None))
            continue
        cyc = meta["cycles"]
        reads = [cy for cy in cyc if cy["kind"] == "read"]
        if not reads:
            entries.append((d, meta, None, None))
            continue
        targets = []
        for cy in reads:
            if cy["addr"] != reads[0]["addr"] and cy["addr"] not in targets:
                targets.append(cy["addr"])
        if not targets:
            targets = [reads[-1]["addr"]]
        multi = multi or len(targets) > 1
        for tgt in targets:
            last = next(cy for cy in reversed(reads) if cy["addr"] == tgt)
            pts = []
            for cy, r in zip(cyc, res):
                if cy["kind"] == "read" and cy["addr"] == tgt and r.get("complete"):
                    p = round(r["precharge_before_ns"])
                    pts.append((p, r))
                    pre_all.add(p)
            entries.append((d, meta, last, pts))
    cols = sorted(pre_all)
    if not cols:
        print("rowmap: no completed target-row reads")
        return
    period = next((m["period_ns"] for (_, m, _, _) in entries if m), 100.0)
    avail = a.interval - period / 2
    lines, width, has_bl = [], 10, False
    for (d, meta, last, pts) in sorted(entries, key=lambda x: ((x[2]["row"], x[2]["word"], x[0]) if x[2]
                                                              else (1e9, 0, x[0]))):
        run = os.path.basename(d.rstrip('/'))
        if not meta or not last:
            lines.append((None, f"   {run}: no result"))
            continue
        by = {p: r for p, r in pts}
        cells = []
        for p in cols:
            r = by.get(p)
            if r is None:
                cells.append("-")
            elif r.get("word_bl1_min_V") is not None:
                has_bl = True
                s = "ok" if r.get("ok") else f"{r.get('wrong_bits', '?')}w"
                if r.get("selection_ok") is False:
                    s += " x"
                cells.append(f"{s} {r['word_bl1_min_V']:.3f}")
            else:
                s = "ok" if r.get("ok") else f"{r.get('wrong_bits', '?')} wrong"
                if r.get("selection_ok") is False:
                    s += " x"
                cells.append(s)
        width = max([width] + [len(x) for x in cells])
        good = [(p, bool(r.get("ok")) and r.get("selection_ok", True) is not False) for p, r in sorted(by.items())]
        need = None
        for i in range(len(good)):
            if all(g for _, g in good[i:]):
                need = good[i][0]
                break
        below = [g for p, g in good if p <= avail + 1e-6]
        above_ok = all(g for p, g in good if p > avail + 1e-6)
        safe = ("yes" if below and below[-1] and above_ok else "NO") if below else "not tested"
        ones = last["expected"].count(1)
        lines.append(((run, last, ones, cells, need, safe), None))
    print(f"{a.title + ': ' if a.title else ''}precharge before the target-row read (ns) after a read of row 0; "
          f"ok, or wrong bits (x: wrong row or word selected)"
          + ("; then the lowest bitline (V) of the word's one bits while evaluating" if has_bl else ""))
    rw = max([len(L[0][0]) for L in lines if isinstance(L[0], tuple)] + [3]) if multi else 0
    print("   " + (f"{'run':<{rw}} " if multi else "") + f"{'row':>4} {'addr':>5} {'1s':>3} | "
          + " ".join(f"{p:>{width}d}" for p in cols)
          + f" | {'correct from':>12} | safe at {a.interval:g} ns ({avail:g} ns precharge)")
    for L in lines:
        if L[0] is None:
            print(L[1])
            continue
        run, last, ones, cells, need, safe = L[0]
        print("   " + (f"{run:<{rw}} " if multi else "") + f"{last['row']:>4} {last['addr']:>5} {ones:>3} | "
              + " ".join(f"{s:>{width}}" for s in cells)
              + f" | {(f'{need} ns' if need is not None else 'never'):>12} | {safe}")


def cmd_split(a):
    """Cut a data file into macros of --rows rows of --words-per-row words
    each (consecutive entries: macro k holds entries k*rows*wpr ...; with the
    same words per row, its row r is row k*rows + r of the whole table)."""
    data = open(a.bin, "rb").read()
    wb = a.word_bytes
    if len(data) % wb:
        sys.exit(f"{a.bin}: {len(data)} bytes is not a whole number of {wb}-byte words")
    nw = len(data) // wb
    per = a.rows * a.words_per_row
    if nw % per:
        sys.exit(f"{nw} words cannot be cut into macros of {a.rows} rows x {a.words_per_row} words "
                 f"({per} words): remainder {nw % per}")
    n = nw // per
    full = bitmap(data, wb, a.words_per_row, a.words_per_row * wb * 8)
    out = []
    for k in range(n):
        part = data[k * per * wb:(k + 1) * per * wb]
        path = f"{a.out_prefix}{k}.bin"
        with open(path, "wb") as fh:
            fh.write(part)
        bm = bitmap(part, wb, a.words_per_row, a.words_per_row * wb * 8)
        same = bm == full[k * a.rows:(k + 1) * a.rows]
        zeros = sum(r.count(0) for r in bm)
        print(f"   macro {k}: {path}  entries {k * per}..{(k + 1) * per - 1}, rows {k * a.rows}..{(k + 1) * a.rows - 1} "
              f"of the whole table ({'same bits' if same else 'BITS DIFFER'}), {zeros} zero cells of {per * wb * 8}")
        out.append({"k": k, "bin": os.path.abspath(path), "first_entry": k * per, "words": per, "same_bits": same})
        if not same:
            sys.exit("the cut does not reproduce the rows of the whole table")
    print(json.dumps({"macros": n, "words_per_macro": per, "rows": a.rows, "words_per_row": a.words_per_row,
                      "parts": out}))


def cmd_seqof(a):
    """The read sequence of an existing bench run (tb_meta.json), in the
    --seq syntax, so that another bench can repeat it exactly."""
    meta = json.load(open(os.path.join(a.dir, "tb_meta.json")))
    out = []
    for cy in meta["cycles"]:
        if cy["kind"] == "idle":
            out.append("i")
        elif cy["kind"] == "read":
            out.append(f"r{cy['addr']}")
        elif cy["kind"] == "wait":
            out.append(f"w{int(round(cy['len'] * 1e9))}")
        elif cy["kind"] == "stop":
            out.append("s")
        else:
            sys.exit(f"seqof: unknown cycle kind {cy['kind']}")
    print(",".join(out))


def cmd_ab(a):
    """Read-by-read comparison of two analysed runs of the same sequence
    (result files of analyze): lowest one-cell bitline of the read row, read
    result, energy, access time, and the order of footers and wordline."""
    ra, rb = json.load(open(a.a)), json.load(open(a.b))
    ca, cb = ra["meta"]["cycles"], rb["meta"]["cycles"]
    seq = lambda cc: [(c["kind"], c.get("addr")) for c in cc]
    if seq(ca) != seq(cb):
        sys.exit("ab: the two runs do not have the same sequence")
    A, Bn = a.labels
    f3 = lambda x: f"{x:.3f}" if isinstance(x, (int, float)) else "-"
    rd = lambda c: ("ok" if c.get("ok") else f"{c.get('wrong_bits')} wrong") if c.get("complete") else "n/a"
    print(f"   {'k':>3} {'row':>4} {'word':>4} | {A[:22]:>22}: {'lowest V':>8} {'col':>4} {'read':>8} {'E pJ':>7} "
          f"{'t_acc':>6} {'foot-wl':>7} | {Bn[:22]:>22}: {'lowest V':>8} {'col':>4} {'read':>8} {'E pJ':>7} "
          f"{'t_acc':>6} {'foot-wl':>7} | {'dV mV':>6}")
    rows = []
    for k, (x, y) in enumerate(zip(ra["cycles"], rb["cycles"])):
        if ca[k]["kind"] != "read":
            continue
        vx, vy = x.get("bl1_min_V"), y.get("bl1_min_V")
        dv = (vy - vx) * 1000 if (vx is not None and vy is not None) else None
        rows.append((ca[k]["row"], x, y, dv))
        print(f"   {k:3d} {ca[k]['row']:4d} {ca[k]['word']:4d} | {'':>22}  {f3(vx):>8} {str(x.get('bl1_min_col', '-')):>4} "
              f"{rd(x):>8} {x.get('E_vdd_pJ', float('nan')):7.2f} {x.get('t_access_ns', float('nan')):6.2f} "
              f"{f3(x.get('footer_to_wl_ns')):>7} | {'':>22}  {f3(vy):>8} {str(y.get('bl1_min_col', '-')):>4} "
              f"{rd(y):>8} {y.get('E_vdd_pJ', float('nan')):7.2f} {y.get('t_access_ns', float('nan')):6.2f} "
              f"{f3(y.get('footer_to_wl_ns')):>7} | {(f'{dv:6.1f}' if dv is not None else '     -')}")
    def summ(lab, idx):
        sel = [r[idx] for r in rows if r[idx].get("complete")]
        tgt = [r[idx] for r in rows if r[idx].get("complete") and r[0] != 0]
        if not sel:
            return f"{lab}: no complete reads"
        wrong = sum(1 for c in sel if not c.get("ok"))
        lo = min((c["bl1_min_V"] for c in tgt if c.get("bl1_min_V") is not None), default=None)
        lo0 = min((c["bl1_min_V"] for c in sel if c.get("bl1_min_V") is not None and c not in tgt), default=None)
        e = [c["E_vdd_pJ"] for c in tgt]
        ta = [c["t_access_ns"] for c in sel if c.get("ok")]
        return (f"{lab}: {len(sel)} reads, {wrong} wrong; lowest one-cell bitline: target reads {f3(lo)} V, "
                f"other reads {f3(lo0)} V; target-read energy {min(e):.2f}..{max(e):.2f} pJ (mean {sum(e)/len(e):.2f}); "
                f"longest access of correct reads {max(ta) if ta else float('nan'):.2f} ns")
    print("   " + summ(A, 1))
    print("   " + summ(Bn, 2))
    d = [r[3] for r in rows if r[3] is not None]
    if d:
        print(f"   bitline change ({Bn} - {A}): min {min(d):.1f} mV, max {max(d):.1f} mV, mean {sum(d)/len(d):.1f} mV")


def cmd_condsum(a):
    """One line per analysed run (for example the same reads at several
    corners): reads, wrong reads, wrong row or word selections, the lowest
    one-cell bitline (target reads = reads of an address other than the first
    one; and all reads), the bitline inverter's switching level at that
    condition (--vm, in the order of --dirs) and the margin above it, the
    highest zero-cell bitline at the sampling time, the largest
    footer-to-wordline time (> 0: the columns conducted with every row on),
    target-read energy and the longest access time of the correct reads."""
    labels = a.labels or [os.path.basename(d.rstrip("/")) for d in a.dirs]
    vms = a.vm or []
    print(f"   {'run':<34} {'condition':<16} {'reads':>5} {'wrong':>5} {'sel':>3} | {'low 1 tgt':>9} {'low 1 all':>9} "
          f"{'Vm':>6} {'margin':>7} | {'high 0':>6} | {'foot-wl':>7} | {'E target pJ (min/mean/max)':>26} | "
          f"{'t_acc':>6}")
    worst = None
    for i, (d, lab) in enumerate(zip(a.dirs, labels)):
        try:
            r = json.load(open(d if (d.endswith(".json") and os.path.isfile(d)) else os.path.join(d, "result.json")))
        except (OSError, ValueError):
            print(f"   {lab:<34} no result")
            continue
        meta, res = r["meta"], r["cycles"]
        cond = f"{meta.get('corner')} {meta.get('temp'):g}C {meta.get('vdd'):g}V"
        cyc = meta["cycles"]
        reads = [(cy, x) for cy, x in zip(cyc, res) if cy["kind"] == "read" and x.get("complete")]
        n_all = sum(1 for cy in cyc if cy["kind"] == "read")
        if not reads:
            print(f"   {lab:<34} {cond:<16} no complete read (of {n_all})")
            continue
        first = reads[0][0]["addr"]
        tg = [x for cy, x in reads if cy["addr"] != first]
        wrong = sum(1 for _, x in reads if not x.get("ok"))
        sel = sum(1 for _, x in reads if x.get("selection_ok") is False)
        b1t = [x["bl1_min_V"] for x in tg if x.get("bl1_min_V") is not None]
        b1a = [x["bl1_min_V"] for _, x in reads if x.get("bl1_min_V") is not None]
        b0 = [x["bl0_max_V"] for _, x in reads if x.get("bl0_max_V") is not None]
        fw = [x["footer_to_wl_ns"] for _, x in reads if x.get("footer_to_wl_ns") is not None]
        e = [x["E_vdd_pJ"] for x in tg]
        ta = [x["t_access_ns"] for _, x in reads if x.get("ok")]
        vm = vms[i] if i < len(vms) else None
        lo = min(b1t) if b1t else None
        mg = (lo - vm) if (lo is not None and vm is not None) else None
        f3 = lambda x: f"{x:.3f}" if x is not None else "-"
        part = "" if len(reads) == n_all else f" (complete {len(reads)} of {n_all})"
        print(f"   {lab[:34]:<34} {cond:<16} {len(reads):5d} {wrong:5d} {sel:3d} | {f3(lo):>9} "
              f"{f3(min(b1a) if b1a else None):>9} {f3(vm):>6} {(f'{mg:+.3f}' if mg is not None else '-'):>7} | "
              f"{f3(max(b0) if b0 else None):>6} | {f3(max(fw) if fw else None):>7} | "
              f"{(f'{min(e):.1f} / {sum(e)/len(e):.1f} / {max(e):.1f}' if e else '-'):>26} | "
              f"{(f'{max(ta):.2f}' if ta else '-'):>6}{part}")
        if mg is not None and (worst is None or mg < worst[0]):
            worst = (mg, lab)
    if worst:
        print(f"   smallest margin above the switching level: {worst[0]:+.3f} V ({worst[1]})")


def cmd_margins(a):
    """Row margins of runs written with bench --bitlines all: for each read,
    the lowest bitline voltage of the read row's one cells while evaluating
    (it must stay above the bitline inverter's switching level), the highest
    bitline voltage of its zero cells at the sampling time (it must be below
    that level), and the lowest bitline of the read word's one bits. Then the
    run with the lowest one-cell bitline among its target reads (reads of an
    address other than the first one), and its --n words with the lowest
    bitline among their one bits (ranked at the precharge --at, if given;
    with --per-row, at most one word per row)."""
    labels = a.labels or [os.path.basename(d.rstrip("/")) for d in a.dirs]
    if len(labels) != len(a.dirs):
        sys.exit("margins: give as many --labels as --dirs")
    runs = []
    for d, lab in zip(a.dirs, labels):
        try:
            meta = json.load(open(os.path.join(d, "tb_meta.json")))
            res = json.load(open(os.path.join(d, "result.json")))["cycles"]
        except (OSError, ValueError):
            print(f"{lab}: no result")
            continue
        if meta.get("bitlines") != "all":
            print(f"{lab}: no row margins (bench without --bitlines all)")
            continue
        runs.append((d, lab, meta, res))
    if not runs:
        return
    hdr = (f"   {'k':>3} {'addr':>5} {'row':>4} {'w':>3} {'pre ns':>6} {'read':>8} | {'1-cells':>7} {'lowest V':>8} "
           f"{'col':>4} {'bit':>3} {'word':>4} | {'0-cells':>7} {'highest V':>9} {'col':>4} | {'word 1-bit V':>12} | "
           f"{'E pJ':>7}")
    best = None          # (lowest target one-cell bitline, run index, row, col)
    n_wrong = n_target = 0
    for i, (d, lab, meta, res) in enumerate(runs):
        wpr = meta["words_per_row"]
        cyc = meta["cycles"]
        reads = [(cy, r) for cy, r in zip(cyc, res) if cy["kind"] == "read" and r.get("complete")]
        first = reads[0][0]["addr"] if reads else None
        print(f"\n{lab}: {meta['top']}, {meta['rows']} rows x {meta['cols']} columns, corner "
              f"{meta.get('corner')}, {meta.get('temp')} C; lowest bitline of the read row's one cells while "
              f"evaluating, highest of its zero cells at the sampling time")
        print(hdr)
        t_low = None
        z_high = None
        for cy, r in reads:
            if r.get("bl1_min_V") is None and r.get("bl0_max_V") is None:
                continue
            rb = cy.get("row_bits") or []
            n1, n0 = rb.count(1), rb.count(0)
            rd = "ok" if r.get("ok") else f"{r.get('wrong_bits', '?')} wrong"
            if r.get("selection_ok") is False:
                rd += " x"
            c1 = r.get("bl1_min_col")
            c0 = r.get("bl0_max_col")
            v1 = f"{r['bl1_min_V']:8.3f}" if r.get("bl1_min_V") is not None else f"{'-':>8}"
            v0 = f"{r['bl0_max_V']:9.3f}" if r.get("bl0_max_V") is not None else f"{'-':>9}"
            vw = (f"{r['word_bl1_min_V']:.3f} (b{r['word_bl1_min_bit']})" if r.get("word_bl1_min_V") is not None
                  else "-")
            print(f"   {cy['k']:>3} {cy['addr']:>5} {cy['row']:>4} {cy['word']:>3} {r['precharge_before_ns']:6.0f} "
                  f"{rd:>8} | {n1:>7} {v1} {(c1 if c1 is not None else '-'):>4} "
                  f"{(c1 // wpr if c1 is not None else '-'):>3} {(c1 % wpr if c1 is not None else '-'):>4} | "
                  f"{n0:>7} {v0} {(c0 if c0 is not None else '-'):>4} | {vw:>12} | {r['E_vdd_pJ']:7.2f}")
            if cy["addr"] != first and r.get("bl1_min_V") is not None:
                if t_low is None or r["bl1_min_V"] < t_low[0]:
                    t_low = (r["bl1_min_V"], cy["row"], c1, r["precharge_before_ns"])
            if r.get("bl0_max_V") is not None and (z_high is None or r["bl0_max_V"] > z_high[0]):
                z_high = (r["bl0_max_V"], cy["row"], c0, r["precharge_before_ns"])
        tr = [r for cy, r in reads if cy["addr"] != first]
        n_ok = sum(1 for r in tr if r.get("ok") and r.get("selection_ok", True) is not False)
        n_target += len(tr)
        n_wrong += len(tr) - n_ok
        print(f"   target reads correct: {n_ok} of {len(tr)}"
              + (f"; lowest one-cell bitline {t_low[0]:.3f} V (row {t_low[1]}, column {t_low[2]}, precharge "
                 f"{t_low[3]:.0f} ns)" if t_low else "")
              + (f"; highest zero-cell bitline at sampling {z_high[0]:.3f} V (row {z_high[1]}, column {z_high[2]})"
                 if z_high else ""))
        if t_low and (best is None or t_low[0] < best[0]):
            best = (t_low[0], i, t_low[1], t_low[2])
    print(f"\nall runs: target reads correct {n_target - n_wrong} of {n_target}"
          + (f"; lowest one-cell bitline {best[0]:.3f} V ({runs[best[1]][1]}, row {best[2]}, column {best[3]})"
             if best else ""))
    print(f"TARGET_READS {n_target} WRONG {n_wrong}")
    if best is None:
        print("\nno target read with row margins")
        return
    print(f"LOWEST_ONE_CELL_V {best[0]:.4f}")
    d, lab, meta, res = runs[best[1]]
    wpr, col_bits = meta["words_per_row"], meta["col_bits"]
    cyc = meta["cycles"]
    reads = [(cy, r) for cy, r in zip(cyc, res) if cy["kind"] == "read" and r.get("complete")]
    first = reads[0][0]["addr"]
    wb = meta["data_bits"]
    cand = {}
    for cy, r in reads:
        if cy["addr"] == first or not r.get("bl1_by_col"):
            continue
        if a.at is not None and abs(r["precharge_before_ns"] - a.at) > 1.0:
            continue
        rb = cy["row_bits"]
        by = r["bl1_by_col"]
        for w in range(wpr):
            ones = [(by[str(b * wpr + w)], b) for b in range(wb)
                    if rb[b * wpr + w] == 1 and str(b * wpr + w) in by]
            if not ones:
                continue
            v, b = min(ones)
            key = (cy["row"], w)
            if key not in cand or v < cand[key][0]:
                cand[key] = (v, b, len(ones), r["precharge_before_ns"])
    ranked = sorted(cand.items(), key=lambda kv: kv[1][0])
    if a.per_row:
        # the worst word of each row, rows ranked by it: the words chosen lie in
        # different rows (each read also measures every other cell of its row)
        seen, worst = set(), []
        for (row, w), v in ranked:
            if row in seen:
                continue
            seen.add(row)
            worst.append(((row, w), v))
        worst = worst[:a.n]
    else:
        worst = ranked[:a.n]
    print(f"\nworst run: {lab} (lowest one-cell bitline {best[0]:.3f} V, row {best[2]}, column {best[3]})")
    if not worst:
        print("   no word with one bits among its target reads" + (f" at {a.at:g} ns" if a.at is not None else ""))
        return
    print(f"   its {len(worst)} words with the lowest bitline among their one bits"
          + (", at most one per row" if a.per_row else "")
          + (f" (precharge {a.at:g} ns)" if a.at is not None else "") + ":")
    print(f"   {'addr':>5} {'row':>4} {'word':>4} {'1s':>3} {'lowest V':>8} {'bit':>3} {'col':>4} {'pre ns':>6}")
    addrs = []
    for (row, w), (v, b, n1, pre) in worst:
        ad = (row << col_bits) | w
        addrs.append(ad)
        print(f"   {ad:>5} {row:>4} {w:>4} {n1:>3} {v:8.3f} {b:>3} {b * wpr + w:>4} {pre:6.0f}")
    print(f"WORST_RUN {d}")
    print(f"WORST_WORDS {','.join(str(x) for x in addrs)}")


def cmd_macrosum(a):
    """Area, stored bits, LVS and extraction errors of a set of macros (JSON
    spec: {"reference": {...}, "macros": [{...}, ...]}, each with label, bin,
    word_bytes, wpr, lef, box_log, and for the macros also option,
    bitcheck_log, lvs_log, extract_log), with the totals per option against
    the reference macro (layout extent from magic's box)."""
    spec = json.load(open(a.spec))

    def lef_size(p):
        try:
            for line in open(p):
                m = re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", line)
                if m:
                    return float(m.group(1)), float(m.group(2))
        except (OSError, TypeError):
            pass
        return None

    def box_size(p):
        try:
            for line in open(p, errors="replace"):
                if line.startswith("microns:"):
                    f = line.split()
                    return float(f[1]), float(f[3])
        except (OSError, TypeError):
            pass
        return None

    def lvs_state(p):
        try:
            s = open(p, errors="replace").read()
        except (OSError, TypeError):
            return "not run", ""
        dev = re.findall(r"Circuit \d+ contains (\d+) devices", s)
        dv = "/".join(dev[-2:]) if dev else ""
        if "Circuits match uniquely" in s:
            return "match", dv
        if "do not match" in s or "MISMATCH" in s:
            return "MISMATCH", dv
        return "unclear", dv

    def ext_errors(p):
        try:
            s = open(p, errors="replace").read()
        except (OSError, TypeError):
            return "-"
        m = re.search(r"Total of (\d+) errors", s)
        return m.group(1) if m else "0"

    def bits_state(p):
        try:
            s = open(p, errors="replace").read()
        except (OSError, TypeError):
            return "-"
        return "exact" if "STORES THE DATA EXACTLY" in s else ("FAILED" if "CHECK FAILED" in s else "?")

    def org(o):
        data = open(o["bin"], "rb").read()
        return organisation(len(data), o["word_bytes"], o.get("wpr"))

    ref = spec["reference"]
    rbw = box_size(ref.get("box_log"))
    rarea = rbw[0] * rbw[1] / 1e6 if rbw else None
    nw, wpr, cols, rows = org(ref)
    rl = lef_size(ref.get("lef"))
    print("A. macros (um; area = drawn layout extent from magic, mm2)")
    print(f"   {'option':8s} {'macro':44s} {'rows x cols':>11s} {'LEF W x H':>17s} {'layout W x H':>19s} "
          f"{'area mm2':>9s} {'bits':>6s} {'LVS':>8s} {'devices':>13s} {'ext err':>7s}")
    print(f"   {'ref':8s} {ref['label'][:44]:44s} {f'{rows} x {cols}':>11s} "
          f"{(f'{rl[0]:.2f} x {rl[1]:.2f}' if rl else '-'):>17s} "
          f"{(f'{rbw[0]:.3f} x {rbw[1]:.3f}' if rbw else '-'):>19s} {(f'{rarea:.5f}' if rarea else '-'):>9s}")
    opts = {}
    for o in spec["macros"]:
        nw, wpr, cols, rows = org(o)
        lw = lef_size(o.get("lef"))
        bw = box_size(o.get("box_log"))
        area = bw[0] * bw[1] / 1e6 if bw else None
        lvs, dv = lvs_state(o.get("lvs_log"))
        xe = ext_errors(o.get("extract_log"))
        bits = bits_state(o.get("bitcheck_log"))
        print(f"   {o['option']:8s} {o['label'][:44]:44s} {f'{rows} x {cols}':>11s} "
              f"{(f'{lw[0]:.2f} x {lw[1]:.2f}' if lw else '-'):>17s} "
              f"{(f'{bw[0]:.3f} x {bw[1]:.3f}' if bw else '-'):>19s} {(f'{area:.5f}' if area else '-'):>9s} "
              f"{bits:>6s} {lvs:>8s} {dv:>13s} {xe:>7s}")
        g = opts.setdefault(o["option"], {"n": 0, "area": 0.0, "missing": 0, "lvs_ok": 0, "xe_ok": 0,
                                          "bits_ok": 0, "w": [], "h": []})
        g["n"] += 1
        if area:
            g["area"] += area
            g["w"].append(bw[0])
            g["h"].append(bw[1])
        else:
            g["missing"] += 1
        g["lvs_ok"] += lvs == "match"
        g["xe_ok"] += xe == "0"
        g["bits_ok"] += bits == "exact"
    print("\nB. per option: the macros that hold one table, against the reference macro")
    print(f"   {'option':8s} {'macros':>6s} {'total mm2':>9s} {'vs ref':>6s} {'width um':>9s} {'heights um':>16s} "
          f"{'bits exact':>10s} {'LVS match':>9s} {'ext err 0':>9s}")
    if rarea:
        print(f"   {'ref':8s} {1:>6d} {rarea:9.5f} {1.0:6.3f} {rbw[0]:9.3f} {rbw[1]:16.3f}")
    for name, g in opts.items():
        tot = f"{g['area']:.5f}" if not g["missing"] else f"{g['area']:.5f}*"
        ratio = f"{g['area'] / rarea:.3f}" if rarea and not g["missing"] else "-"
        wid = f"{max(g['w']):.3f}" if g["w"] else "-"
        hs = (f"{min(g['h']):.3f}-{max(g['h']):.3f}" if g["h"] else "-")
        print(f"   {name:8s} {g['n']:>6d} {tot:>9s} {ratio:>6s} {wid:>9s} {hs:>16s} "
              f"{g['bits_ok']:>4d} of {g['n']:<2d} {g['lvs_ok']:>3d} of {g['n']:<2d} {g['xe_ok']:>3d} of {g['n']:<2d}")
    print("   (*: area of some macros missing; a valid layout needs bits exact, LVS match and 0 extraction errors)")


def cmd_invsize(a):
    """Transistor sizes of the bitline inverter of a generated ROM netlist
    (<top>_rom_bitline_inverter: one inverter per bitline): prints the cell
    and "pfet W L nfet W L" (um)."""
    subs, _ = parse_netlist(a.sp)
    arr = next((n for n in subs if n.lower() == (a.top + "_rom_bitline_inverter").lower()), None)
    if not arr:
        sys.exit(f"{a.sp}: no subcircuit {a.top}_rom_bitline_inverter")
    cells = sorted({c for (_, _, c, _) in subs[arr]["inst"]})
    if len(cells) != 1 or cells[0] not in subs:
        sys.exit(f"{arr}: expected one inverter cell, found {cells}")
    cell = cells[0]
    size = {}
    for (_, _, model, params) in subs[cell]["inst"]:
        kind = "pfet" if "pfet" in model else ("nfet" if "nfet" in model else None)
        if kind and kind not in size:
            size[kind] = (params.get("w", params.get("W")), params.get("l", params.get("L")))
    if set(size) != {"pfet", "nfet"}:
        sys.exit(f"{cell}: transistors not found ({size})")
    print(f"cell {cell} ({len(subs[arr]['inst'])} in {arr})")
    print(f"pfet {size['pfet'][0]} {size['pfet'][1]} nfet {size['nfet'][0]} {size['nfet'][1]}")


def cmd_shorts(a):
    """Signal nodes merged into a supply net by the top cell of a magic
    extraction (the .ext file of the top cell). Each 'merge' line joins two
    nodes of subcells (or a subcell node and a top-level node) because
    geometry drawn in the top cell, or overlapping subcells, connects them.
    A subcell node whose own name is not a supply name but that ends up in
    the same net as vdd/gnd is a candidate short; LVS decides."""
    supply = re.compile(r"^(vdd|gnd|vccd1|vssd1|vpwr|vgnd|vpb|vnb|sub|vsubs|vss|vcc)$", re.I)
    parent = {}

    def find(x):
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    names = set()
    with open(a.ext, errors="replace") as fh:
        for line in fh:
            m = re.match(r'(merge|node|port)\s+"([^"]+)"(?:\s+"([^"]+)")?', line)
            if not m:
                continue
            if m.group(1) == "merge" and m.group(3):
                ra, rb = find(m.group(2)), find(m.group(3))
                if ra != rb:
                    parent[ra] = rb
                names.update((m.group(2), m.group(3)))
            else:
                find(m.group(2))
                names.add(m.group(2))
    comp = {}
    for n in names:
        comp.setdefault(find(n), []).append(n)
    leaf = lambda n: n.split("/")[-1]
    hits = []
    for mem in comp.values():
        sup = sorted({leaf(n) for n in mem if supply.match(leaf(n))})
        if not sup:
            continue
        # skip magic's generated names (end in '#'), labels with spaces, and
        # transistor terminals (a precharge PMOS source on vdd is expected)
        sig = sorted(n for n in mem if not supply.match(leaf(n)) and not leaf(n).endswith("#")
                     and " " not in leaf(n) and leaf(n) not in ("D", "S", "G", "B", "d", "s", "g", "b"))
        if sig:
            hits.append((sup, sig))
    print(f"top-level merges in {a.ext}: {len(names)} named nodes, {len(comp)} nets")
    if not hits:
        print("no signal node is merged into a supply net at the top level")
    for sup, sig in hits:
        print(f"supply net ({', '.join(sup)}) also contains {len(sig)} signal node(s):")
        for s in sig[:30]:
            print(f"   {s}")
    print(json.dumps({"supply_shorts": [{"supply": s, "nodes": g} for s, g in hits]}))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("probe")
    p.add_argument("--sp", required=True)
    p.add_argument("--top")
    b = sub.add_parser("bench")
    b.add_argument("--sp", required=True)
    b.add_argument("--top", required=True)
    b.add_argument("--bin", required=True)
    b.add_argument("--word-bytes", type=int, required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--models", required=True)
    b.add_argument("--corner", default="tt")
    b.add_argument("--period", type=float, required=True)
    b.add_argument("--seq", required=True)
    b.add_argument("--vdd", type=float, default=1.8)
    b.add_argument("--temp", type=float, default=25.0)
    b.add_argument("--cload", type=float, default=10.0)
    b.add_argument("--edge", type=float, default=0.1)
    b.add_argument("--tmax", type=float, default=None)
    b.add_argument("--reltol", type=float, default=None,
                   help="ngspice relative error tolerance written on the .options line (default: not written, i.e. "
                        "ngspice's 1e-3; version 6, 2026-10-18)")
    b.add_argument("--checkpoint", type=float, default=None,
                   help="write the waveform data every this many ns of simulated time "
                        "(default: one clock period)")
    b.add_argument("--words-per-row", type=int, default=None,
                   help="if the macro was generated with words_per_row set")
    b.add_argument("--substrate", default="VSUBS")
    b.add_argument("--internal", action="store_true",
                   help="same as --probes basic (generator netlist only)")
    b.add_argument("--probes", choices=["basic", "full"], default=None,
                   help="basic: precharge, clock, one bitline, one multiplexer output, one wordline "
                        "(generator netlist); full: all wordlines, the row-decoder outputs near the "
                        "rows read, the column selects, a few bitlines (generator netlist, or a flat "
                        "extracted netlist with --sanitize)")
    b.add_argument("--fix-asad", action="store_true",
                   help="rewrite as/ad values ending in 'u' to um2 (OpenRAM's junction areas)")
    b.add_argument("--sanitize", action="store_true",
                   help="rewrite '/' and '#' in node names (extracted netlists)")
    b.add_argument("--plain-nfet", action="store_true",
                   help="write sky130_fd_pr__special_nfet_01v8 as sky130_fd_pr__nfet_01v8 (the PDK "
                        "defines the former as a wrapper of the latter; the wrapper costs ngspice "
                        "several GB for 43,530 cell transistors)")
    b.add_argument("--allow-unmapped", action="store_true")
    b.add_argument("--chain-cols", default=None,
                   help="generator netlist only: save every node of the series chain of these columns "
                        "(comma list), or 'auto' = the columns of bits 0, 1, w/2 and w-1 of the last word read")
    b.add_argument("--chain-step", type=int, default=1,
                   help="save every Nth chain node (the last one always)")
    b.add_argument("--cs-delay", type=float, default=None,
                   help="sandbox: CS of a read rises this many ns after the clock edge and falls with the clock "
                        "(default: CS changes with the address, a quarter period before the edge)")
    b.add_argument("--bitlines", choices=["read", "all"], default="read",
                   help="with --probes full: read = bits 0, w/2 and w-1 of the words read (as before); "
                        "all = every bitline (analyze then reports the margins of every cell of the read row)")
    k = sub.add_parser("pick")
    k.add_argument("--bin", required=True)
    k.add_argument("--word-bytes", type=int, required=True)
    k.add_argument("--mode", choices=["main", "recovery", "sweep", "idle", "rowmap", "deep", "words"],
                   default="main")
    k.add_argument("--row", type=int, default=None, help="rowmap mode: the target row")
    k.add_argument("--deep-rows", type=int, default=2, help="deep mode: the number of deepest rows read")
    k.add_argument("--addrs", default=None, help="words mode: comma-separated target addresses")
    k.add_argument("--words-per-row", type=int, default=None)
    k.add_argument("--waits", default="0,25,50,100,200,300,400,500",
                   help="sweep, rowmap, deep and words modes: waits in ns before the target read")
    z = sub.add_parser("analyze")
    z.add_argument("--dir", required=True)
    z.add_argument("--json-out", default=None,
                   help="write the result here instead of DIR/result.json (re-analysis of a run that must not change)")
    h = sub.add_parser("shorts")
    h.add_argument("--ext", required=True, help="the top cell's .ext file from magic")
    q = sub.add_parser("compare")
    q.add_argument("--dirs", nargs="+", required=True)
    q.add_argument("--labels", nargs="+", required=True)
    c = sub.add_parser("bitcheck")
    c.add_argument("--sp", required=True)
    c.add_argument("--top", required=True)
    c.add_argument("--bin", required=True)
    c.add_argument("--word-bytes", type=int, required=True)
    c.add_argument("--words-per-row", type=int, default=None)
    o = sub.add_parser("orgsum")
    o.add_argument("--spec", required=True)
    g = sub.add_parser("chains")
    g.add_argument("--dir", required=True)
    g.add_argument("--all-reads", action="store_true",
                   help="every read of a probed column (default: only reads of the last address read)")
    m = sub.add_parser("rowmap")
    m.add_argument("--dirs", nargs="+", required=True)
    m.add_argument("--title", default="")
    m.add_argument("--interval", type=float, default=140.0,
                   help="lookup interval of the system in ns (precharge available = interval - period/2)")
    sp_ = sub.add_parser("split")
    sp_.add_argument("--bin", required=True)
    sp_.add_argument("--word-bytes", type=int, required=True)
    sp_.add_argument("--words-per-row", type=int, required=True)
    sp_.add_argument("--rows", type=int, required=True, help="rows per macro")
    sp_.add_argument("--out-prefix", required=True, help="writes <prefix><k>.bin for k = 0, 1, ...")
    mg = sub.add_parser("margins")
    mg.add_argument("--dirs", nargs="+", required=True)
    mg.add_argument("--labels", nargs="+", default=None)
    mg.add_argument("--n", type=int, default=3, help="number of worst words to list")
    mg.add_argument("--at", type=float, default=None,
                    help="rank the words at this precharge (ns; default: all target reads)")
    mg.add_argument("--per-row", action="store_true",
                    help="at most one word per row (the worst word of each of the worst rows)")
    cs_ = sub.add_parser("condsum")
    cs_.add_argument("--dirs", nargs="+", required=True, help="run directories (DIR/result.json) or result files")
    cs_.add_argument("--labels", nargs="+", default=None)
    cs_.add_argument("--vm", nargs="+", type=float, default=None,
                     help="switching level of the bitline inverter for each run (V), in the order of --dirs")
    so = sub.add_parser("seqof")
    so.add_argument("--dir", required=True)
    ab = sub.add_parser("ab")
    ab.add_argument("--a", required=True, help="result file (result.json or analyze --json-out) of run A")
    ab.add_argument("--b", required=True, help="result file of run B (same sequence)")
    ab.add_argument("--labels", nargs=2, default=["A", "B"])
    ms = sub.add_parser("macrosum")
    ms.add_argument("--spec", required=True)
    iv = sub.add_parser("invsize")
    iv.add_argument("--sp", required=True)
    iv.add_argument("--top", required=True)
    a = ap.parse_args()
    {"probe": cmd_probe, "bench": cmd_bench, "analyze": cmd_analyze, "pick": cmd_pick,
     "shorts": cmd_shorts, "compare": cmd_compare, "bitcheck": cmd_bitcheck,
     "orgsum": cmd_orgsum, "chains": cmd_chains, "rowmap": cmd_rowmap,
     "split": cmd_split, "margins": cmd_margins, "macrosum": cmd_macrosum, "invsize": cmd_invsize,
     "seqof": cmd_seqof, "ab": cmd_ab, "condsum": cmd_condsum}[a.cmd](a)


if __name__ == "__main__":
    main()
