#!/usr/bin/env python3
"""
e8_4a8_export.py   (P2R-E8.4a-8, data export for the analysis of all tables)

Writes one compressed file with what the next analysis needs, so that it can be
done outside this computer and every number still traces to the files here:
  - the 100 address-map tables (2,496 words each, rebuilt from
    data/rtl_inputs_{A,B}_v3 exactly as E8.6a and part 1 of E8.4a-8 do);
  - for every macro screened at tt in E8.4a-7 and E8.4a-8 (every row): its
    data file and, for every target read, the row, the lowest one-cell bitline
    of every column (bl1_by_col) and the highest zero-cell bitline;
  - the md5 of every input file.
Only reads. A few seconds.

Usage:
  python3 scripts/e8_4a8_export.py --paper2 /mnt/d/Project/hybrid_memory/paper2
Writes reports/e8_rom/e8_4a8/export_cells_tables.json.gz and prints its md5.
"""
import argparse
import gzip
import hashlib
import importlib.util
import json
import os
import time


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--paper2", required=True)
    ap.add_argument("--table-words", type=int, default=2496)
    ap.add_argument("--lanes", type=int, default=25)
    a = ap.parse_args()
    t0 = time.time()
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("e8screen", os.path.join(here, "e8_4a8_margin_screen.py"))
    S = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(S)
    root = os.path.join(a.paper2, "reports", "e8_rom")
    print(f"P2R-E8.4a-8 export  {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"   script : {md5(os.path.abspath(__file__))}  {os.path.abspath(__file__)}")
    out = {"created": time.strftime("%Y-%m-%d %H:%M:%S"), "table_words": a.table_words, "tables": {},
           "inputs": {}, "macros": {}}
    suf = f"_16x{a.table_words}"
    for M in ("A", "B"):
        d = os.path.join(a.paper2, "data", f"rtl_inputs_{M}_v3")
        for f in sorted(os.listdir(d)):
            if f.startswith("addr_to_slot_") and f.endswith(".hex"):
                out["inputs"][f"rtl_inputs_{M}_v3/{f}"] = md5(os.path.join(d, f))
        for side in ("pcm", "sram"):
            for lane in range(a.lanes):
                w = S.table_words(a.paper2, M, side, lane, a.table_words)
                out["tables"][f"e8rom_{M}_{side}_l{lane:02d}{suf}"] = "".join(f"{x:04x}" for x in w)
    print(f"   tables: {len(out['tables'])} rebuilt from {len(out['inputs'])} hex files")
    n_cells = 0
    for exp in ("e8_4a7", "e8_4a8"):
        bdir = os.path.join(root, exp, "bins")
        if not os.path.isdir(bdir):
            print(f"   {exp}: no bins folder, skipped")
            continue
        for t in sorted(f[:-6] for f in os.listdir(bdir) if f.endswith(".names")):
            for n in [x.strip() for x in open(os.path.join(bdir, t + ".names")) if x.strip()]:
                binf = os.path.join(bdir, n + ".bin")
                rj = os.path.join(root, exp, n, "tt_cs", "result.json")
                if not (os.path.isfile(binf) and os.path.isfile(rj)):
                    print(f"   {exp} {n}: no screening result, skipped")
                    continue
                r_ = json.load(open(rj))
                reads = []
                for cy, x in zip(r_["meta"]["cycles"], r_["cycles"]):
                    if cy["kind"] != "read" or not x.get("complete"):
                        continue
                    bl = x.get("bl1_by_col") or {}
                    n_cells += len(bl)
                    reads.append({"k": cy.get("k"), "row": cy["row"], "addr": cy.get("addr"), "ok": x.get("ok"),
                                  "bl1_by_col": {c: round(v, 5) for c, v in bl.items()},
                                  "bl0_max_V": x.get("bl0_max_V")})
                out["macros"][n] = {"experiment": exp, "table": t, "bin_md5": md5(binf),
                                    "bin_hex": open(binf, "rb").read().hex(), "result_md5": md5(rj),
                                    "bitlines": r_["meta"].get("bitlines"), "reads": reads}
        print(f"   {exp}: {sum(1 for m in out['macros'].values() if m['experiment'] == exp)} macros")
    f = os.path.join(root, "e8_4a8", "export_cells_tables.json.gz")
    with gzip.open(f, "wt") as fh:
        json.dump(out, fh)
    print(f"   one-cell bitlines exported: {n_cells}")
    print(f"written: {f}  md5 {md5(f)}  {os.path.getsize(f)} bytes  ({time.time() - t0:.0f} s)")


if __name__ == "__main__":
    main()
