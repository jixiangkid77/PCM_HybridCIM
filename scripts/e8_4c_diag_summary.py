#!/usr/bin/env python3
"""Summary of the diagnosis of the 4-KB SRAM read failure before the fix (E8.4c resume2).

Reads reports/e8_rom/e8_4c_resume2_diag/diag_r20.json and diag_r10.json (written
by scripts/e8_4c_diag.py from the waveforms of the r20 and r10 runs) and prints,
for every data bit of every read of each run, the two sense-amplifier inputs when
the word-line enable rises (start of the read), grouped by the direction of their
difference against the data to be read (same, or opposite with a difference of at
least or below 0.6 V), with the number of bits read right in each group.

Usage: python3 scripts/e8_4c_diag_summary.py --paper2 .
"""
import argparse
import json
import os


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".")
    a = ap.parse_args()
    d = os.path.join(a.paper2, "reports", "e8_rom", "e8_4c_resume2_diag")
    for run in ("r20", "r10"):
        rows = json.load(open(os.path.join(d, f"diag_{run}.json")))
        groups = {}
        for r in rows:
            for b in r["bits"]:
                if b["bl_wl"] is None or b["br_wl"] is None:
                    continue
                start = b["bl_wl"] - b["br_wl"]                  # > 0: the inputs start toward a one
                toward_new = (start > 0) == (b["exp"] == 1)
                right = b["out_end"] == b["exp"]
                key = ("same direction as the new data" if toward_new else
                       f"opposite, |difference| {'>= 0.6' if abs(start) >= 0.6 else '< 0.6'} V")
                g = groups.setdefault(key, {"bits": 0, "right": 0, "lo": [], "hi": [], "diff": []})
                g["bits"] += 1
                g["right"] += right
                g["lo"].append(min(b["bl_wl"], b["br_wl"]))
                g["hi"].append(max(b["bl_wl"], b["br_wl"]))
                g["diff"].append(abs(start))
        print(f"{run}: {len(rows)} reads")
        for key, g in groups.items():
            print(f"   inputs at the start of the read {key}: {g['bits']} bits, read right {g['right']}; "
                  f"low input {min(g['lo']):.3f}-{max(g['lo']):.3f} V, high input {min(g['hi']):.3f}-{max(g['hi']):.3f} V, "
                  f"|difference| {min(g['diff']):.3f}-{max(g['diff']):.3f} V")


if __name__ == "__main__":
    main()
