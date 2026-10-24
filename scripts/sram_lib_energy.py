#!/usr/bin/env python3
"""Analytical figures of the 4-KB SRAM macro in its OpenRAM timing libraries, and what they give per read
and per inference.

reports/12e_openram/lib_20260608/ holds the timing library generated on 2026-06-08 by a run of the compiler
that writes only the netlist (netlist_only = True) with the configuration of the simulated macro, which sets a
single output load of 6.89 fF (use_specified_load_slew = [(6.89, 0.005)]); netlist_only_regeneration/ next to
it holds a rerun of that generation that gives the same library byte for byte, with the compiler's log.
reports/e8_rom/e8_4c/ and reports/e8_rom/e8_4f/ hold the libraries written with the layout of the simulated
macro (same configuration, netlist_only = False), and reports/12e_openram/macros/paper2_sram_pool_8x4096/ the
one written with the layout on 2026-05-13 with the compiler's default loads: same leakage, about 1.6e11 in
the same entries. reports/12e_openram/lib_default_loads/ holds the library generated like that of 2026-06-08
but with the compiler's default loads (1.7225, 6.89 and 27.56 fF instead of the single 6.89 fF).

How to read the clk0 entries. In the units of a library an internal_power entry is an energy,
capacitive_load_unit x voltage_unit^2 = pF x V^2 = pJ, per transition of the pin. OpenRAM (version 1.2.49,
commit e16d9eb, compiler/characterizer/lib.py, add_clk_control_power) writes one entry per access
condition: when "!csb0 & web0" (read) holds read1_power as rise_power and read0_power as fall_power,
"!csb0 & !web0" (write) holds write1_power and write0_power, and the entries with csb0 high hold the same
for a deselected port. With the analytical model, which the compiler uses unless characterization by
simulation is requested (analytical_delay = True, compiler/characterizer/elmore.py), every one of these is
the same number: the dynamic power of the whole macro in mW, a sum over its gates and the columns of its
bit-cell array of a switched capacitance at the default event frequency of the technology (100 MHz for
sky130), each gate with a fixed transition probability and the last output load of the library, each column
with the drain capacitance of its access transistors and half the supply as swing (netlist_only_regeneration/
power_breakdown.txt, which also gives the figure with the compiler's default loads). A gate-level power
analysis takes the entries as energies: one rising and one falling clock transition per read, so twice the
entry per read (scripts/sram_lib_opensta.tcl runs OpenSTA on the library). Read as the model computes it,
the number is a power at 100 MHz, that is the entry / 100 MHz per cycle.

The last part prices the SRAM reads and the ROM reads of one inference with the library, against the
post-layout figures used for the energy (reports/e8_6/e8_6_summary.json, reports/e8_rom/e8_6a3_rel5/d_rom.json).

Usage: python3 scripts/sram_lib_energy.py [--paper2 REPO_ROOT]
"""
import argparse
import json
import os
import re

LIB = "sky130_sram_4kbytes_1rw_8x4096_8_TT_1p8V_25C.lib"
LIB0608 = os.path.join("reports", "12e_openram", "lib_20260608", LIB)
LIBS = [
    ("generated 2026-06-08, netlist only, output load 6.89 fF", LIB0608),
    ("written with the layout of the simulated macro, output load 6.89 fF (E8.4c)",
     os.path.join("reports", "e8_rom", "e8_4c", LIB)),
    ("written with the layout of the simulated macro, output load 6.89 fF (E8.4f)",
     os.path.join("reports", "e8_rom", "e8_4f", LIB)),
    ("written with the macro and its layout, 2026-05-13, the compiler's default loads",
     os.path.join("reports", "12e_openram", "macros", "paper2_sram_pool_8x4096", LIB)),
    ("generated 2026-10-24, netlist only, the compiler's default loads",
     os.path.join("reports", "12e_openram", "lib_default_loads", LIB)),
]
LIBDEF = LIBS[-1][1]
REGEN = os.path.join("reports", "12e_openram", "lib_20260608", "netlist_only_regeneration")
REGEN_LOG = os.path.join(REGEN, "sky130_sram_4kbytes_1rw_8x4096_8.log")
BREAKDOWN = os.path.join(REGEN, "power_breakdown.txt")
LAYOUT_LOG = os.path.join("reports", "e8_rom", "e8_4c", "gen_sky130_sram_4kbytes_1rw_8x4096_8.log")
KIND = {"!csb0 & web0": "read", "!csb0 & !web0": "write", "csb0 & web0": "read, port deselected",
        "csb0 & !web0": "write, port deselected"}
EVENT_MHZ = 100.0          # spice["default_event_frequency"] of technology/sky130/tech/tech.py


def parse(path):
    txt = open(path).read()
    cap = re.search(r"capacitive_load_unit\s*\(\s*([\d.]+)\s*,\s*(\w+)\s*\)", txt)
    volt = re.search(r'voltage_unit\s*:\s*"([\d.]+)V"', txt)
    leak_unit = re.search(r'leakage_power_unit\s*:\s*"([\d.]+)(\w+)"', txt)
    leak = re.search(r"^\s*cell_leakage_power\s*:\s*([\d.eE+-]+)", txt, re.M).group(1)
    clk = txt[txt.index("pin(clk0)"):]
    entries = re.findall(r'internal_power\(\)\s*\{\s*when\s*:\s*"([^"]+)";\s*rise_power\(\w+\)\s*\{\s*values\("([^"]+)"\);'
                         r'\s*\}\s*fall_power\(\w+\)\s*\{\s*values\("([^"]+)"\);', clk)
    period = re.search(r'timing_type\s*:\s*"minimum_period";.*?rise_constraint\(scalar\)\s*\{\s*values\("([^"]+)"\)', txt,
                       re.S).group(1)
    dout = txt[txt.index("pin(dout0"):]
    dout_type = re.search(r"timing_type\s*:\s*(\w+)", dout).group(1)
    vals = [float(x) for x in re.findall(r"[\d.]+(?:[eE][+-]?\d+)?",
                                         re.search(r"cell_rise\(CELL_TABLE\)\s*\{\s*values\(([^;]*)\);", dout).group(1))]
    dout_delay = f"{min(vals):g}" if min(vals) == max(vals) else f"{min(vals):g} to {max(vals):g}"
    return cap.groups(), volt.group(1), leak_unit.groups(), leak, entries, period, dout_type, dout_delay


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".", help="repository root")
    a = ap.parse_args()
    root = a.paper2
    lib0608 = None
    for name, rel in LIBS:
        (cv, cu), vu, (lv, lu), leak, entries, period, dout_type, dout_delay = parse(os.path.join(root, rel))
        assert cu == "pF" and float(cv) == 1.0 and float(vu) == 1.0, (cv, cu, vu)
        to_uw = {"mW": 1e3, "uW": 1.0, "nW": 1e-3}[lu] * float(lv)
        print(f"{name}: {rel}")
        print(f"   clk0 internal_power, {len(entries)} access conditions (energy unit of the library: pF x V^2 = pJ"
              f" per transition; OpenRAM's analytical model writes its dynamic power in mW here):")
        for when, rise, fall in entries:
            print(f"      when {when:14s} ({KIND.get(when, '?')}): rise_power {rise}, fall_power {fall}")
        print(f"   cell_leakage_power {leak} {lu} = {float(leak) * to_uw:.3f} uW")
        print(f"   minimum_period of clk0 {period} ns; dout0 from clk0 ({dout_type}): cell_rise {dout_delay} ns")
        if rel == LIB0608:
            read = [(float(r), float(f)) for w_, r, f in entries if w_ == "!csb0 & web0"][0]
            lib0608 = (read, float(leak) * to_uw)
        if rel == LIBDEF:
            libdef = [(float(r), float(f)) for w_, r, f in entries if w_ == "!csb0 & web0"][0]

    (rise, fall), leak_uw = lib0608
    lib_read = rise + fall
    log = open(os.path.join(root, REGEN_LOG)).read()
    model_mw = float(re.search(r"Dynamic Power: ([\d.eE+-]+) mW", log).group(1))
    model_pj = model_mw / EVENT_MHZ * 1e3
    brk = open(os.path.join(root, BREAKDOWN)).read()
    dflt = re.search(r"default loads \[([^\]]*)\] fF.*?takes ([\d.]+) fF: dynamic [\d.]+ nW = ([\d.]+) mW", brk)
    dflt_mw = float(dflt.group(3))
    s = json.load(open(os.path.join(root, "reports", "e8_6", "e8_6_summary.json")))
    f = s["e84f"]
    print(f"\nper read, library of 2026-06-08 (read condition, output load 6.89 fF):")
    print(f"   as a gate-level power analysis takes it: rise {rise:g} + fall {fall:g} = {lib_read:.4f} pJ;"
          f" post-layout read in the system {f['e_read_pJ']:.2f} pJ = {f['e_read_pJ'] / lib_read:.2f} x")
    print(f"   as the analytical model computes it ({REGEN_LOG}: {model_mw} mW) at {EVENT_MHZ:.0f} MHz:"
          f" {model_pj:.2f} pJ per cycle; post-layout read = {f['e_read_pJ'] / model_pj:.2f} x")
    print(f"   static power after a read {f['p_static_uW']} uW = 1/{leak_uw / f['p_static_uW']:.1f} of the library's"
          f" {leak_uw:.3f} uW")
    dr, df = libdef
    print(f"per read, library with the compiler's default loads ({LIBDEF}; {BREAKDOWN}: loads [{dflt.group(1)}] fF,"
          f" the model takes {dflt.group(2)} fF and gives {dflt_mw} mW):")
    print(f"   as a gate-level power analysis takes it: rise {dr:g} + fall {df:g} = {dr + df:.4f} pJ;"
          f" post-layout read = {f['e_read_pJ'] / (dr + df):.2f} x")
    print(f"   as the analytical model computes it at {EVENT_MHZ:.0f} MHz: {dflt_mw / EVENT_MHZ * 1e3:.2f} pJ per cycle;"
          f" model / post-layout read = {dflt_mw / EVENT_MHZ * 1e3 / f['e_read_pJ']:.2f} x")
    lay = float(re.search(r"Dynamic Power: ([\d.eE+-]+) mW", open(os.path.join(root, LAYOUT_LOG)).read()).group(1))
    print(f"with the layout ({LAYOUT_LOG}): {lay} mW; the wire term scaled by 1e12 is (that - {model_mw:.6f}) / 1e12 ="
          f" {(lay - model_mw) / 1e12:.6f} mW = {(lay - model_mw) / 1e12 / model_mw:.2%} of the netlist-only figure")

    c = s["constants"]
    win_ms = c["cycles"][0] * c["t_clk_ns"][0] * 1e-6
    d = json.load(open(os.path.join(root, "reports", "e8_rom", "e8_6a3_rel5", "d_rom.json")))["models"]
    print(f"\nper inference ({c['cycles'][0]} cycles of {c['t_clk_ns'][0]} ns = {win_ms:.5f} ms), priced with the library"
          f" of 2026-06-08:")
    for m in ("A", "B"):
        n = c["sram_reads"][0][m]
        lib_uj = n * lib_read * 1e-6 + leak_uw * win_ms * 1e-3
        bp = s["energy"][m]["B_parts_uJ"]
        pl_uj = bp["SRAM reads"] + bp["SRAM static (1 macro)"]
        roms = d[m]["bits"]["rom_reads"] + d[m]["bits"]["parks"]
        rom_lib = roms * lib_read * 1e-6
        dp = s["energy"][m]["D_parts_uJ"]
        rom_reads_pl = dp["lookup reads"] + dp["parking reads"]
        print(f"   model {m}: SRAM {n} reads x {lib_read:.4f} pJ + {leak_uw:.3f} uW x {win_ms:.5f} ms = {lib_uj:.3f} uJ;"
              f" post-layout {pl_uj:.3f} uJ ({pl_uj / lib_uj:.2f} x)")
        print(f"            ROM {roms} reads ({d[m]['bits']['rom_reads']} lookups + {d[m]['bits']['parks']} parking reads)"
              f" as SRAM reads of the library = {rom_lib:.3f} uJ; post-layout reads alone {rom_reads_pl:.3f} uJ;"
              f" D_ROM {s['energy'][m]['D_rom_uJ']:.3f} uJ ({s['energy'][m]['D_rom_uJ'] / rom_lib:.2f} x)")


if __name__ == "__main__":
    main()
