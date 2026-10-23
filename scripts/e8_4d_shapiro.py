#!/usr/bin/env python3
"""Shapiro-Wilk p of the E8.4d read margins (local-mismatch Monte Carlo of the address-map ROM).

The analysis of E8.4d (scripts/e8_4d_rom_mc.py analyze) computes the Shapiro-Wilk p of each site's
30 margins only when scipy is installed. It ran without scipy, so reports/e8_rom/e8_4d/e8_4d_summary.json
has no p values. This script takes the per-sample margins stored in that file, recomputes each site's
statistics with the same function (stats() of scripts/e8_4d_rom_mc.py), checks that the mean, sd, min,
max, skew and excess kurtosis equal the stored ones, and prints the p values.

Usage: python3 scripts/e8_4d_shapiro.py [--paper2 REPO_ROOT]   (needs scipy)
"""
import argparse
import importlib.util
import json
import math
import os
import sys

import scipy


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".", help="repository root")
    a = ap.parse_args()
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("e8_4d", os.path.join(a.paper2, "scripts", "e8_4d_rom_mc.py"))
    mc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mc)
    rel = os.path.join("reports", "e8_rom", "e8_4d", "e8_4d_summary.json")
    summary = json.load(open(os.path.join(a.paper2, rel)))
    print(f"{rel}: margin of the read row (lowest one-cell bitline minus its own switching level), "
          f"mismatch samples s0001.. (finished); scipy {scipy.__version__}")
    print(f"{'site':22s} {'n':>3s} {'mean V':>8s} {'sd mV':>6s} {'min V':>7s} {'(mean-min)/sd':>13s} "
          f"{'skew':>6s} {'ex.kurt':>7s} {'SW p':>9s}  stored statistics")
    for name, site in summary["sites"].items():
        recs = site["samples"]
        xs = [recs[t]["m1_min_V"] for t in sorted(recs)
              if t.startswith("s") and t != "s0000" and recs[t]["state"] == "finished"]
        s = mc.stats(xs)
        stored = site["margin_row_min"]
        same = all(math.isclose(s[k], stored[k], rel_tol=0, abs_tol=1e-12)
                   for k in ("n", "mean", "sd", "min", "max", "skew", "ex_kurt"))
        print(f"{name:22s} {s['n']:3d} {s['mean']:8.4f} {1e3 * s['sd']:6.2f} {s['min']:7.4f} "
              f"{(s['mean'] - s['min']) / s['sd']:13.2f} {s['skew']:6.2f} {s['ex_kurt']:7.2f} "
              f"{s['shapiro_p']:9.3g}  {'identical' if same else 'DIFFERENT'}")


if __name__ == "__main__":
    main()
