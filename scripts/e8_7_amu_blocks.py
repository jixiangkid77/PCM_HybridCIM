#!/usr/bin/env python3
"""Energy of the parts of the address-map unit (AMU) in the gate-level power analysis of E8.7 (model A).

reports/e8_7/A/power.json gives the AMU logic as one part. This script splits it by the AMU's sub-blocks:
every instance of reports/e8_7/A/power/gate_instances.rpt.gz (OpenSTA, power per instance) is mapped to
its original hierarchical name through reports/e8_7/A/names.tsv.gz (the plain names written by
scripts/e8_7_tools.py core), assigned to a part with classify() of scripts/e8_7_tools.py, and the cells
of the AMU are grouped by the instance below U_AMU. Power times the inference window of power.json gives
the energy. It also counts the clock-gating cells (sky130_fd_sc_hd__dlclkp_*) and compares the parking
flags (U_PF) with the synthesis of the AMU alone in E8.5b (reports/e8_rom/e8_5b/).

Usage: python3 scripts/e8_7_amu_blocks.py [--paper2 REPO_ROOT]
"""
import argparse
import collections
import gzip
import importlib.util
import json
import os
import re
import sys

AMU = "address-map unit"


def block_of(orig):
    rest = orig.split("U_AMU.", 1)[1]
    first = rest.split(".", 1)[0]
    if first.startswith("tab["):
        return "tab[*]." + rest.split(".")[1]
    if first.startswith("_"):
        return "(top level of U_AMU)"
    return first


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".", help="repository root")
    a = ap.parse_args()
    root = a.paper2
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("e8_7_tools", os.path.join(root, "scripts", "e8_7_tools.py"))
    tools = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tools)

    d = os.path.join("reports", "e8_7", "A")
    power = json.load(open(os.path.join(root, d, "power.json")))
    window_s = power["duration_ms"] * 1e-3
    names, kinds = {}, {}
    with gzip.open(os.path.join(root, d, "names.tsv.gz"), "rt") as fh:
        for ln in fh:
            x = ln.split()
            if len(x) >= 4 and x[1] == "cell":
                names[x[0]] = x[2]
                kinds[x[0]] = x[3]
    with gzip.open(os.path.join(root, d, "power", "gate_instances.rpt.gz"), "rt", errors="replace") as fh:
        inst = fh.read()

    parts = collections.defaultdict(float)
    blocks = collections.defaultdict(lambda: [0.0, 0, 0])          # power W, cells, clock-gating cells
    icg_w, icg_n, n_inst = 0.0, 0, 0
    for mo in tools.INST_POW_RE.finditer(inst):
        cell, w = mo.group(5), float(mo.group(4))
        part = tools.classify(cell, names)
        parts[part] += w
        n_inst += 1
        is_icg = kinds.get(cell, "").startswith("sky130_fd_sc_hd__dlclkp")
        if is_icg:
            icg_w += w
            icg_n += 1
        if part == AMU:
            b = blocks[block_of(names[cell])]
            b[0] += w
            b[1] += 1
            b[2] += is_icg

    amu_w = parts[AMU]
    print(f"E8.7 model A: {d}/power/gate_instances.rpt.gz ({n_inst} instances) with {d}/names.tsv.gz; "
          f"window {power['duration_ms']} ms ({d}/power.json)")
    for k in sorted(parts):
        same = abs(parts[k] - power["parts_W"][k]) <= 1e-12 * max(1.0, power["parts_W"][k])
        print(f"   {k:18s} {parts[k] * 1e3:8.4f} mW  {parts[k] * window_s * 1e6:7.3f} uJ  "
              f"(power.json {power['parts_uJ'][k]:.3f} uJ: {'identical' if same else 'DIFFERENT'})")
    print(f"\nAMU by block (cells, clock-gating cells, power, energy per inference, share of the AMU):")
    for name, (w, n, g) in sorted(blocks.items(), key=lambda kv: -kv[1][0]):
        print(f"   {name:22s} {n:6d} {g:4d}  {w * 1e3:8.4f} mW  {w * window_s * 1e6:7.3f} uJ  {100 * w / amu_w:5.1f}%")
    print(f"   {'AMU':22s} {sum(b[1] for b in blocks.values()):6d} {sum(b[2] for b in blocks.values()):4d}  "
          f"{amu_w * 1e3:8.4f} mW  {amu_w * window_s * 1e6:7.3f} uJ")

    tot = power["groups_W"]["Total"]["total"]
    clk = power["groups_W"]["Clock"]["total"]
    print(f"\nclock-gating cells in the whole logic: {icg_n}, {icg_w * 1e3:.4f} mW = {100 * icg_w / tot:.1f}% of the "
          f"report total {tot * 1e3:.4f} mW (Clock group of the report: {clk * 1e3:.4f} mW = {100 * clk / tot:.1f}%)")

    e5b = os.path.join("reports", "e8_rom", "e8_5b")
    pj = json.load(open(os.path.join(root, e5b, "e8_5b_power_A.json")))
    pf = pj["by_top_level_instance_W"]["U_PF"]
    hier = open(os.path.join(root, e5b, "amu_A_stat_hier.txt")).read()
    sec = re.search(r"^=== [^\n]*amu_pflags[^\n]* ===\n(.*?)^=== ", hier, re.M | re.S).group(1)
    n_cells = int(re.search(r"^\s*(\d+) cells$", sec, re.M).group(1))
    n_icg = sum(int(m) for m in re.findall(r"^\s*(\d+)\s+sky130_fd_sc_hd__dlclkp_\w+$", sec, re.M))
    print(f"\nparking flags, E8.5b (AMU synthesized alone, {e5b}/): module amu_pflags {n_cells} cells, {n_icg} "
          f"clock-gating cells; U_PF {pf[3] * 1e3:.4f} mW over {pj['window_s'] * 1e3:.5f} ms = "
          f"{pf[3] * pj['window_s'] * 1e6:.3f} uJ")


if __name__ == "__main__":
    main()
