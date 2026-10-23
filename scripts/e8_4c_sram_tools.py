#!/usr/bin/env python3
"""
e8_4c_sram_tools.py   (P2R-E8.4c: checks for the extracted protected-weight SRAM macro)

lvsprep   copies of the two netlists for netgen:
          layout    : the flat extraction without parasitics; the substrate node of every foundry
                      cell written as vssd1: by name ('<path>/SUB' in the sandbox PDK, '<path>/VSUBS' in
                      KID's) and, whatever its name, every net that reaches transistors only through the
                      body terminal of nFETs (2026-10-16 v3);
                      sky130_fd_pr__special_nfet_01v8 written as sky130_fd_pr__nfet_01v8 (as the
                      ROM flow).
          reference : OpenRAM's LVS netlist (<name>.lvs.sp: the foundry cells with all their
                      devices, the dummy pull-ups included); w and l in um as in the layout ('0.15u'
                      -> 0.15, '1.5e-07' -> 0.15). The bitcell pull-ups take the name the layout uses:
                      OpenRAM writes sky130_fd_pr__special_pfet_pass; magic extracts them under the
                      name in the PDK's tech file (the sandbox PDK: sky130_fd_pr__special_pfet_latch,
                      KID's PDK: sky130_fd_pr__special_pfet_pass; 2026-10-16: the first version always
                      renamed the reference to ..._latch, which broke the LVS on KID's machine).
lvscheck  reads the netgen report and gives the verdict: PASS when the device counts of every
          class and the net counts are equal, every property difference is on a dummy device of
          a foundry cell (pull-up of length 0.025 um in the layout, pass device of a column end
          cell), and the only pin difference is spare_wen0 (OpenRAM writes the spare-column
          write-enable flip-flop input as spare_wen0[0], not connected to the pin spare_wen0).
libvals   OpenRAM's analytical values in a liberty file (internal power of each state, leakage).
modelcheck which names of the special SRAM devices (sky130_fd_pr__special_*) used in a netlist the
          model library takes: a one-device ngspice deck per name (an instance line of the netlist with
          its own parameters); for a pull-up name that fails, the other pull-up name is tried, and the
          verdict says whether the bench must write ..._pfet_pass as ..._pfet_latch (--pfet-pass-alias).
fbclass   reads a magic feedback listing ('Feedback #<n>: <reason>' lines, see the run script) and
          says whether all extraction errors are of the known foundry-cell type ("Illegal overlap
          between pwell and nwell") and whether the listing found as many errors as the extraction.

Place  : scripts/
Status : 2026-10-16 v3 (lvsprep also ties the nFET-body-only nets to vssd1). v2 (lvsprep takes the layout's
         pull-up name; lvscheck accepts both pull-up names for the dummy pull-ups; modelcheck): md5
         1e351d3bf6d74224b40ea8150fd4f8d8. The first version: md5 89538ea739cddf7b1a1f08aabbe1a7a8.
"""
import argparse
import json
import os
import re
import subprocess
import sys

PF_PASS, PF_LATCH = "sky130_fd_pr__special_pfet_pass", "sky130_fd_pr__special_pfet_latch"
CELL_SUB_SUFFIXES = ("/SUB", "/VSUBS")     # the substrate node of a foundry cell: sandbox PDK, KID's PDK
NAME_RE = {n: re.compile(r"(?<![A-Za-z0-9_])" + n + r"(?![A-Za-z0-9_])") for n in (PF_PASS, PF_LATCH)}


def join_lines(path):
    out = []
    with open(path, errors="replace") as fh:
        for raw in fh:
            if raw.startswith("+") and out:
                out[-1] = out[-1].rstrip("\n") + " " + raw[1:].strip() + "\n"
            else:
                out.append(raw)
    return out


def nfet_body_only_nets(lines):
    """nets that reach transistors only through the body terminal (4th node) of nFETs, ports excluded: the
    body of a foundry cell that the extraction leaves on its own (the reference ties it to ground)"""
    use, ports = {}, set()
    for l in lines:
        low = l.lower()
        if low.startswith(".subckt"):
            ports |= set(t for t in l.split()[2:] if "=" not in t)
            continue
        if not l or l[0] not in "Xx":
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
    return {n for n, u in use.items() if u == {"nbody"} and n not in ports}


def cmd_lvsprep(a):
    lay = join_lines(a.layout)
    n_sub = n_nf = n_body = 0
    body = nfet_body_only_nets(lay)
    body_by_name = sum(1 for n in body if n.endswith(CELL_SUB_SUFFIXES))
    lay_count = {PF_PASS: 0, PF_LATCH: 0}
    with open(f"{a.out}/layout.spice", "w") as fo:
        for line in lay:
            if line[:1] in "Xx":
                tok = line.split()
                for i in range(1, len(tok)):
                    if "=" not in tok[i] and tok[i].endswith(CELL_SUB_SUFFIXES):
                        tok[i] = "vssd1"
                        n_sub += 1
                    elif "=" not in tok[i] and tok[i] in body:
                        tok[i] = "vssd1"
                        n_body += 1
                    elif tok[i] == "sky130_fd_pr__special_nfet_01v8":
                        tok[i] = "sky130_fd_pr__nfet_01v8"
                        n_nf += 1
                    elif tok[i] in lay_count:
                        lay_count[tok[i]] += 1
                line = " ".join(tok) + "\n"
            fo.write(line)
    # the reference's bitcell pull-ups take the layout's name (one name only in the layout; otherwise no change)
    if lay_count[PF_LATCH] and not lay_count[PF_PASS]:
        src, dst = PF_PASS, PF_LATCH
    elif lay_count[PF_PASS] and not lay_count[PF_LATCH]:
        src, dst = PF_LATCH, PF_PASS
    else:
        src = dst = None
    pat = re.compile(r"(?<![A-Za-z0-9_])([wl])=([0-9.]+(?:[eE][+-]?[0-9]+)?)(u?)(?![A-Za-z0-9_])", re.IGNORECASE)
    n_unit = n_alias = 0

    def fix(m):
        nonlocal n_unit
        v = float(m.group(2))
        if m.group(3):
            n_unit += 1
            return f"{m.group(1)}={m.group(2)}"
        if v < 1e-3:
            n_unit += 1
            return f"{m.group(1)}={v * 1e6:.6g}"
        return m.group(0)

    with open(a.ref, errors="replace") as fi, open(f"{a.out}/reference.spice", "w") as fo:
        for line in fi:
            if not line.startswith("*"):
                if src:
                    line, k = NAME_RE[src].subn(dst, line)
                    n_alias += k
                line = pat.sub(fix, line)
            fo.write(line)
    info = {"layout_cell_substrates_to_vssd1": n_sub,
            "layout_nfet_body_only_nets": len(body), "of_them_named_SUB_or_VSUBS": body_by_name,
            "layout_nfet_body_only_terminals_to_vssd1": n_body,
            "layout_special_nfet_01v8_renamed": n_nf,
            "layout_pullup_names": {PF_PASS: lay_count[PF_PASS], PF_LATCH: lay_count[PF_LATCH]},
            "reference_pullups_renamed": (f"{src} -> {dst}" if src else "none"),
            "reference_pullups_renamed_count": n_alias, "reference_wl_values_in_um": n_unit}
    json.dump(info, open(f"{a.out}/lvsprep.json", "w"), indent=1)
    print("lvsprep: " + json.dumps(info))
    return 0


def cmd_lvscheck(a):
    txt = open(a.report, errors="replace").read().split("\n")
    res = {"summary_classes": [], "devices": None, "nets": None, "property_errors": 0,
           "property_errors_unexpected": [], "pin_differences": [], "final": None}
    # subcircuit summary of the top cell (the last one in the report)
    idx = [i for i, l in enumerate(txt) if l.startswith("Subcircuit summary:")]
    if idx:
        i = idx[-1] + 3
        while i < len(txt) and "|" in txt[i] and not txt[i].startswith("Number of devices"):
            left, right = txt[i].split("|", 1)
            res["summary_classes"].append([left.strip(), right.strip()])
            i += 1
        for l in txt[i:i + 3]:
            if l.startswith("Number of devices"):
                res["devices"] = [x.strip() for x in l.split("|")]
            if l.startswith("Number of nets"):
                res["nets"] = [x.strip() for x in l.split("|")]
    mism = any("Mismatch" in "".join(x) for x in res["summary_classes"]) or \
        any("Mismatch" in x for x in (res["devices"] or ["Mismatch"])) or \
        any("Mismatch" in x for x in (res["nets"] or ["Mismatch"]))
    # property errors: "<class>:<n> vs. <path>:" followed by " w circuit1: a   circuit2: b ..." lines
    cur = None
    for l in txt:
        if " vs. " in l and l.startswith("sky130_fd_pr__"):
            cur = {"class": l.split(":")[0], "where": l.split(" vs. ", 1)[1], "diff": {}}
            res["property_errors"] += 1
            cur_ok = None
            continue
        m = re.match(r"^\s+([wl]) circuit1: ([0-9.eE+-]+)\s+circuit2: ([0-9.eE+-]+)", l)
        if m and cur is not None:
            cur["diff"][m.group(1)] = (float(m.group(2)), float(m.group(3)))
            cls, where, d = cur["class"], cur["where"], cur["diff"]
            ok = ("sky130_fd_bd_sram__" in where and (
                (cls in (PF_LATCH, PF_PASS) and d.get("l", (0.025,))[0] == 0.025 and
                 d.get("w", (0.14,))[0] == 0.14) or
                (cls == "sky130_fd_pr__special_nfet_pass" and re.search(r"sram_sp_colend", where))))
            cur["ok"] = ok
            continue
        if cur is not None and not l.startswith(" "):
            if not cur.get("ok", False):
                res["property_errors_unexpected"].append({"class": cur["class"], "where": cur["where"][-160:],
                                                         "diff": cur["diff"]})
            cur = None
    # pins
    if "Subcircuit pins:" in "\n".join(txt):
        i = max(i for i, l in enumerate(txt) if l.startswith("Subcircuit pins:")) + 3
        while i < len(txt) and "|" in txt[i]:
            left, right = [x.strip() for x in txt[i].split("|", 1)]
            if left != right:
                res["pin_differences"].append([left, right])
            i += 1
    fin = [l for l in txt if l.startswith("Final result")]
    res["final"] = fin[-1] if fin else None
    if a.log:
        lg = open(a.log, errors="replace").read()
        m = re.findall(r"Final result:\s*\n?\s*(.*)", lg)
        res["netgen_log_final"] = m[-1].strip() if m else None
    pins_ok = all(("spare_wen0" in p[0] or "spare_wen0" in p[1]) for p in res["pin_differences"])
    res["verdict"] = "PASS" if (not mism and res["devices"] and res["nets"] and pins_ok and
                                not res["property_errors_unexpected"]) else "FAIL"
    res["counts_match"] = not mism
    res["pins_only_spare_wen0"] = pins_ok
    print(f"LVS: {res['verdict']}  (device and net counts {'equal' if not mism else 'DIFFERENT'}; "
          f"property differences {res['property_errors']}, of which unexpected {len(res['property_errors_unexpected'])}; "
          f"pin differences {len(res['pin_differences'])}: {res['pin_differences']})")
    print("   devices: " + " | ".join(res["devices"] or ["?"]) + "   nets: " + " | ".join(res["nets"] or ["?"]))
    for c in res["summary_classes"]:
        print(f"   {c[0]:45s} | {c[1]}")
    for u in res["property_errors_unexpected"][:10]:
        print(f"   UNEXPECTED property difference: {u}")
    if a.json:
        json.dump(res, open(a.json, "w"), indent=1)
    return 0 if res["verdict"] == "PASS" else 1


def cmd_modelcheck(a):
    """one ngspice deck per special SRAM device name of the netlist (its first instance line, own parameters)"""
    found = {}
    for line in join_lines(a.sp):
        if line[:1] not in "Xx":
            continue
        tok = line.split()
        for i, t in enumerate(tok[1:], 1):
            if re.match(r"^sky130_fd_pr__special_\w+$", t):
                if t not in found:
                    found[t] = (i, tok)
                break
    os.makedirs(a.dir, exist_ok=True)

    def try_name(name, i, tok, tag):
        nodes = [f"n{k}" for k in range(1, i)]
        params = [t for t in tok[i + 1:] if "=" in t]
        deck = os.path.join(a.dir, f"{tag}.sp")
        with open(deck, "w") as fo:
            fo.write(f"* model check of {name}\n.lib \"{a.models}\" {a.corner}\n")
            for k, n in enumerate(nodes):
                fo.write(f"V{k} {n} 0 {0.9 * (k % 2)}\n")
            fo.write("X1 " + " ".join(nodes) + f" {name} " + " ".join(params) + "\n.op\n.end\n")
        log = ""
        try:
            r = subprocess.run([a.ngspice, "-b", deck], capture_output=True, text=True, timeout=600)
            log = (r.stdout or "") + (r.stderr or "")
            bad = [m.group(0).strip()[:160] for m in re.finditer(
                r"(?im)^.*(unknown subckt|could not find|unable to find|error:|error on line|interrupted).*$", log)]
            ok = r.returncode == 0 and not bad
        except subprocess.TimeoutExpired:
            ok, bad = False, ["timeout"]
        open(os.path.join(a.dir, f"{tag}.log"), "w").write(log)
        return ok, bad[:3]

    res, alias_needed, unusable = {}, False, []
    for name, (i, tok) in sorted(found.items()):
        if a.plain_nfet and name == "sky130_fd_pr__special_nfet_01v8":
            ok, bad = try_name("sky130_fd_pr__nfet_01v8", i, tok, "special_nfet_01v8_as_nfet_01v8")
            res[name] = {"usable": ok, "errors": bad, "tested_as": "sky130_fd_pr__nfet_01v8 (the bench's --plain-nfet)"}
            if not ok:
                unusable.append(name)
            continue
        ok, bad = try_name(name, i, tok, name.replace("sky130_fd_pr__", ""))
        res[name] = {"usable": ok, "errors": bad}
        if not ok:
            alt = {PF_PASS: PF_LATCH, PF_LATCH: PF_PASS}.get(name)
            if alt:
                ok2, bad2 = try_name(alt, i, tok, alt.replace("sky130_fd_pr__", "") + "_for_" + name.replace("sky130_fd_pr__", ""))
                res[name]["other_name"] = {"name": alt, "usable": ok2, "errors": bad2}
                if ok2 and name == PF_PASS:
                    alias_needed = True
                    continue
            unusable.append(name)
    out = {"netlist": a.sp, "models": a.models, "corner": a.corner, "names": res,
           "pfet_pass_alias": alias_needed, "unusable": unusable,
           "verdict": "OK" if not unusable else "MODELS MISSING"}
    print("model check: " + json.dumps(out))
    if a.json:
        json.dump(out, open(a.json, "w"), indent=1)
    return 0 if not unusable else 1


def cmd_fbclass(a):
    """magic prints every feedback entry as 'Feedback #<n>: <reason>' when the run script's listing visits it;
    'Label ... attached to more than one unconnected node' entries are warnings, the others errors"""
    known = "Illegal overlap between pwell and nwell"
    reasons = {}
    for l in open(a.log, errors="replace"):
        m = re.match(r"^Feedback #(\d+): (.*)$", l.strip())
        if m:
            why = re.sub(r":\s*\S+#?$", ": <node>", m.group(2).strip()) if m.group(2).startswith("Label ") else m.group(2).strip()
            reasons[why] = reasons.get(why, 0) + 1
    nknown = sum(v for k, v in reasons.items() if k.startswith(known))
    other = {k: v for k, v in reasons.items() if not k.startswith(known)}
    # magic counts the errors of a cell ("<cell>: N errors M warnings"); the run passes their total: every counted
    # error must be one of the known type, the other entries are then its warnings
    ok = a.expect is not None and nknown == a.expect
    out = {"known_type_entries": nknown, "errors_expected": a.expect, "other_entries": other,
           "verdict": "ALL ERRORS OF THE KNOWN TYPE" if ok else "NOT ALL ERRORS ARE OF THE KNOWN TYPE"}
    print("extraction feedback: " + json.dumps(out))
    return 0 if ok else 1


def cmd_topshort(a):
    """magic's extraction of the top cell only ('extract cell <top>'): its 'merge' lines are the connections that
    the top cell's own wires make between nodes of the cells inside it. A column-select line of the column
    multiplexer (sel_<k>, a node inside the bank) appears there only if a top-level wire touches it; OpenRAM
    e16d9eb's control route of p_en_bar does so with 16 words per row. Verdict SHORT when a net contains a
    column-select line together with a control signal or another column-select line."""
    par = {}

    def find(x):
        par.setdefault(x, x)
        while par[x] != x:
            par[x] = par[par[x]]
            x = par[x]
        return x

    n_merge = 0
    for l in open(a.ext, errors="replace"):
        if not l.startswith("merge "):
            continue
        q = l.split('"')
        if len(q) < 4:
            continue
        n_merge += 1
        ra, rb = find(q[1]), find(q[3])
        if ra != rb:
            par[ra] = rb
    nets = {}
    for x in list(par):
        nets.setdefault(find(x), set()).add(x)
    leaf = lambda n: n.rsplit("/", 1)[-1]
    sel_re = re.compile(r"^sel_\d+$")
    ctl_re = re.compile(r"^(p_en_bar|s_en|w_en|wl_en)\d*$|^en_bar$")
    flagged, seen_ctl = [], set()
    for members in nets.values():
        sels = sorted({leaf(m) for m in members if sel_re.match(leaf(m))})
        ctls = sorted({leaf(m) for m in members if ctl_re.match(leaf(m))})
        for c in ctls:
            seen_ctl.add(re.sub(r"\d+$", "", c))
        if sels and (ctls or len(sels) > 1):
            flagged.append({"select_lines": sels, "control_signals": ctls,
                            "nodes": sorted(m for m in members if sel_re.match(leaf(m)) or ctl_re.match(leaf(m)))[:12]})
    expected = {"p_en_bar", "s_en", "w_en", "wl_en"}
    out = {"ext": a.ext, "merge_lines": n_merge, "control_signals_seen_at_top": sorted(seen_ctl),
           "control_routes_found": sorted(expected & seen_ctl), "shorts": flagged,
           "verdict": ("SHORT" if flagged else
                       ("NO SHORT OF THIS KIND" if expected <= seen_ctl else "NOT JUDGED (control routes not found)"))}
    print("top-level check: " + json.dumps(out))
    if a.json:
        json.dump(out, open(a.json, "w"), indent=1)
    return {"SHORT": 1, "NO SHORT OF THIS KIND": 0}.get(out["verdict"], 2)


def cmd_libvals(a):
    """OpenRAM's analytical values in a liberty file: internal power of clk0 per state, cell leakage"""
    txt = open(a.lib, errors="replace").read()
    unit = re.search(r'leakage_power_unit\s*:\s*"([^"]+)"', txt)
    leak = re.search(r"(?<!default_)cell_leakage_power\s*:\s*([0-9.eE+-]+)", txt)
    ip = re.findall(r'internal_power\s*\(\s*\)\s*\{.*?when\s*:\s*"([^"]*)".*?values\("([^"]*)"\)', txt, re.S)
    out = {"leakage": float(leak.group(1)) if leak else None, "leakage_unit": unit.group(1) if unit else None,
           "internal_power": [[w.strip(), v] for w, v in ip]}
    print("liberty " + a.lib.split("/")[-1] + ": " + json.dumps(out))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("lvsprep")
    p.add_argument("--layout", required=True)
    p.add_argument("--ref", required=True)
    p.add_argument("--out", required=True)
    p = sp.add_parser("lvscheck")
    p.add_argument("--report", required=True)
    p.add_argument("--log", default="")
    p.add_argument("--json", default="")
    p = sp.add_parser("fbclass")
    p.add_argument("--log", required=True)
    p.add_argument("--expect", type=int, default=None, help="the extraction's total of errors")
    p = sp.add_parser("libvals")
    p.add_argument("--lib", required=True)
    p = sp.add_parser("modelcheck")
    p.add_argument("--sp", required=True, help="the netlist the bench will simulate")
    p.add_argument("--models", required=True)
    p.add_argument("--corner", default="tt")
    p.add_argument("--ngspice", required=True)
    p.add_argument("--dir", required=True, help="folder for the test decks and their logs")
    p.add_argument("--plain-nfet", action="store_true",
                   help="the bench writes sky130_fd_pr__special_nfet_01v8 as sky130_fd_pr__nfet_01v8: test that name")
    p.add_argument("--json", default="")
    p = sp.add_parser("topshort")
    p.add_argument("--ext", required=True, help="the .ext of the top cell from 'extract cell <top>'")
    p.add_argument("--json", default="")
    a = ap.parse_args()
    return {"lvsprep": cmd_lvsprep, "lvscheck": cmd_lvscheck, "fbclass": cmd_fbclass, "libvals": cmd_libvals,
            "topshort": cmd_topshort, "modelcheck": cmd_modelcheck}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
