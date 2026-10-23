#!/usr/bin/env python3
"""Analytical figures of the 4-KB SRAM macro in its two OpenRAM timing libraries.

reports/12e_openram/lib_20260608/ holds the timing library generated on 2026-06-08,
whose figures (11.81819 in the clk0 internal_power entries, 0.034375 mW of leakage)
are the analytical figures the post-layout simulation of the SRAM is compared with.
reports/12e_openram/macros/paper2_sram_pool_8x4096/ holds the library written with
the macro on 2026-05-13: same leakage, about 1.6e11 in the same entries.

How to read the clk0 entries. In the units of the library an internal_power entry
is an energy, capacitive_load_unit x voltage_unit^2 = pF x V^2 = pJ, per transition
of the pin. OpenRAM (commit e16d9eb, compiler/characterizer/lib.py,
add_clk_control_power) writes one entry per access condition: when "!csb0 & web0"
(read) holds read1_power as rise_power and read0_power as fall_power, "!csb0 & !web0"
(write) holds write1_power and write0_power, and the entries with csb0 high hold the
same for a disabled port. With the analytical model (analytical_delay = True,
compiler/characterizer/elmore.py), every one of these is the dynamic power of the
whole macro in mW, computed with every gate switching at the default event
frequency of the technology (100 MHz for sky130), and the macro datasheets list it
in mW.

Usage: python3 scripts/sram_lib_energy.py [--paper2 REPO_ROOT]
"""
import argparse
import os
import re

LIB = "sky130_sram_4kbytes_1rw_8x4096_8_TT_1p8V_25C.lib"
LIBS = [
    ("generated 2026-06-08", os.path.join("reports", "12e_openram", "lib_20260608", LIB)),
    ("written with the macro, 2026-05-13",
     os.path.join("reports", "12e_openram", "macros", "paper2_sram_pool_8x4096", LIB)),
]
KIND = {"!csb0 & web0": "read", "!csb0 & !web0": "write", "csb0 & web0": "read, port disabled",
        "csb0 & !web0": "write, port disabled"}


def parse(path):
    txt = open(path).read()
    cap = re.search(r"capacitive_load_unit\s*\(\s*([\d.]+)\s*,\s*(\w+)\s*\)", txt)
    volt = re.search(r'voltage_unit\s*:\s*"([\d.]+)V"', txt)
    leak_unit = re.search(r'leakage_power_unit\s*:\s*"([\d.]+)(\w+)"', txt)
    leak = re.search(r"^\s*cell_leakage_power\s*:\s*([\d.eE+-]+)", txt, re.M).group(1)
    clk = txt[txt.index("pin(clk0)"):]
    entries = re.findall(r'internal_power\(\)\s*\{\s*when\s*:\s*"([^"]+)";\s*rise_power\(\w+\)\s*\{\s*values\("([^"]+)"\);'
                         r'\s*\}\s*fall_power\(\w+\)\s*\{\s*values\("([^"]+)"\);', clk)
    return cap.groups(), volt.group(1), leak_unit.groups(), leak, entries


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".", help="repository root")
    a = ap.parse_args()
    for name, rel in LIBS:
        (cv, cu), vu, (lv, lu), leak, entries = parse(os.path.join(a.paper2, rel))
        assert cu == "pF" and float(cv) == 1.0 and float(vu) == 1.0, (cv, cu, vu)
        to_uw = {"mW": 1e3, "uW": 1.0, "nW": 1e-3}[lu] * float(lv)
        print(f"{name}: {rel}")
        print(f"   clk0 internal_power, {len(entries)} access conditions (energy unit of the library: pF x V^2 = pJ;"
              f" OpenRAM's analytical model writes its dynamic power in mW here):")
        for when, rise, fall in entries:
            print(f"      when {when:14s} ({KIND.get(when, '?')}): rise_power {rise}, fall_power {fall}")
        print(f"   cell_leakage_power {leak} {lu} = {float(leak) * to_uw:.3f} uW")


if __name__ == "__main__":
    main()
