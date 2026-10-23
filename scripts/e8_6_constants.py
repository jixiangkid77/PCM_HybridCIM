#!/usr/bin/env python3
"""Where four constants of scripts/e8_6_summary.py come from, recomputed from files of this repository.

  e_array_uJ 0.263      PCM crossbar, energy per inference: NeuroSim at 22 nm, "Chip total
                        readDynamicEnergy" of reports/e7_neurosim/result_22nm_repro.log, doubled for
                        the two arrays of the differential pair
  crossbar_mm2 2.27     crossbar with its converters, baseline converter scheme: "Array Area" +
                        "ADC Area" of the same log, doubled
  crossbar_mm2 0.68     the same for the most compact converter scheme (cellBit 4): PCM_array_um2 +
                        ADC_um2 of reports/12e_neurosim/outputs/neurosim_cellBit_4_verify/key_numbers.json,
                        doubled
  act_buffer_mm2 0.669  activation buffer: two arrays (ping-pong, rtl/src/feature_buffer.v), each a 5-KB
                        OpenRAM macro whose LEF SIZE is in
                        reports/12e_openram/macros/paper2_feature_buffer_8x5120/sky130_sram_5kbytes_1rw_8x5120_8.lef

Usage: python3 scripts/e8_6_constants.py [--paper2 REPO_ROOT]
"""
import argparse
import importlib.util
import json
import os
import re
import sys

LOG22 = os.path.join("reports", "e7_neurosim", "result_22nm_repro.log")
KEY4 = os.path.join("reports", "12e_neurosim", "outputs", "neurosim_cellBit_4_verify", "key_numbers.json")
LEF5K = os.path.join("reports", "12e_openram", "macros", "paper2_feature_buffer_8x5120",
                     "sky130_sram_5kbytes_1rw_8x5120_8.lef")


def num(text, pattern):
    return float(re.search(pattern, text, re.M).group(1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".", help="repository root")
    a = ap.parse_args()
    root = a.paper2
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("e8_6", os.path.join(root, "scripts", "e8_6_summary.py"))
    summ = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(summ)
    const = summ.CONST

    log = open(os.path.join(root, LOG22)).read()
    e_dyn = num(log, r"^Chip total readDynamicEnergy is: ([\d.eE+-]+)pJ")
    arr = num(log, r"^Array Area: ([\d.eE+-]+) mm\^2")
    adc = num(log, r"^ADC Area: ([\d.eE+-]+) mm\^2")
    k4 = json.load(open(os.path.join(root, KEY4)))
    w, h = map(float, re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", open(os.path.join(root, LEF5K)).read()).groups())

    rows = [
        ("e_array_uJ", const["e_array_uJ"][0], 2 * e_dyn * 1e-6,
         f"2 x {e_dyn:g} pJ (Chip total readDynamicEnergy, {LOG22})"),
        ("crossbar_mm2, baseline", const["crossbar_mm2"][0][1], 2 * (arr + adc),
         f"2 x ({arr:g} + {adc:g}) mm2 (Array Area + ADC Area, {LOG22})"),
        ("crossbar_mm2, compact", const["crossbar_mm2"][0][0],
         2 * (float(k4["PCM_array_um2"]) + float(k4["ADC_um2"])) * 1e-6,
         f"2 x ({k4['PCM_array_um2']} + {k4['ADC_um2']}) um2 (PCM_array_um2 + ADC_um2, cellBit {k4['cellBit']}, {KEY4})"),
        ("act_buffer_mm2", const["act_buffer_mm2"][0], 2 * w * h * 1e-6,
         f"2 x {w:g} x {h:g} um (SIZE, {LEF5K})"),
    ]
    for name, used, derived, how in rows:
        print(f"{name:24s} used {used:<6g} derived {derived:.4f} = {how}")


if __name__ == "__main__":
    main()
