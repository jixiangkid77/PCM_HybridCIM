#!/usr/bin/env python3
"""
e8_4a10_export.py   (P2R-E8.4a-10, data export of the screenings)

Writes one compressed file with the tt screenings of E8.4a-10, in the record that
scripts/e8_4a8_export.py writes for E8.4a-7 and E8.4a-8, so that the next analysis
(E8.4a-11: the model fitted again with these macros) can be done outside this
computer and every number still traces to the files here:
  - for every macro of reports/e8_rom/e8_4a10 (bins/<table>.names): its data file
    and, for every target read that the screening completed, the row, the lowest
    one-cell bitline of every column (bl1_by_col) and the highest zero-cell bitline;
    whether the screening is complete (every cycle) and how many rows it read;
  - the md5 of every file read, and of selected_macros.txt and predictions.json.
Only reads. A few seconds.

Usage:
  python3 scripts/e8_4a10_export.py --paper2 /mnt/d/Project/hybrid_memory/paper2
Writes reports/e8_rom/e8_4a10/export_cells_e8_4a10.json.gz and prints its md5.

Place  : scripts/
Status : NEW FILE.
"""
import argparse
import gzip
import hashlib
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
    a = ap.parse_args()
    t0 = time.time()
    work = os.path.join(a.paper2, "reports", "e8_rom", "e8_4a10")
    print(f"P2R-E8.4a-10 export  {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"   script : {md5(os.path.abspath(__file__))}  {os.path.abspath(__file__)}")
    out = {"created": time.strftime("%Y-%m-%d %H:%M:%S"), "experiment": "e8_4a10", "inputs": {}, "macros": {}}
    for f in ("selected_macros.txt", "selected.txt", "predictions.json"):
        p = os.path.join(work, "tables", f)
        if os.path.isfile(p):
            out["inputs"][f"tables/{f}"] = md5(p)
            print(f"   {f:<20}: {out['inputs'][f'tables/{f}']}")
    bdir = os.path.join(work, "bins")
    if not os.path.isdir(bdir):
        raise SystemExit(f"no {bdir}: E8.4a-10 has not run here")
    n_cells = 0
    print(f"   {'macro':<34} {'screening':<12} {'rows':>4} {'cells':>6}  result md5")
    for t in sorted(f[:-6] for f in os.listdir(bdir) if f.endswith(".names")):
        for n in [x.strip() for x in open(os.path.join(bdir, t + ".names")) if x.strip()]:
            binf = os.path.join(bdir, n + ".bin")
            rj = os.path.join(work, n, "tt_cs", "result.json")
            if not (os.path.isfile(binf) and os.path.isfile(rj)):
                print(f"   {n:<34} {'none':<12}")
                continue
            r_ = json.load(open(rj))
            s = r_.get("summary", {})
            complete = (not s.get("failed")) and s.get("cycles_complete") == s.get("cycles_total")
            reads, rows = [], set()
            for cy, x in zip(r_["meta"]["cycles"], r_["cycles"]):
                if cy["kind"] != "read" or not x.get("complete"):
                    continue
                bl = x.get("bl1_by_col") or {}
                if cy["row"] != 0:
                    rows.add(cy["row"])
                    n_cells += len(bl)
                reads.append({"k": cy.get("k"), "row": cy["row"], "addr": cy.get("addr"), "ok": x.get("ok"),
                              "bl1_by_col": {c: round(v, 5) for c, v in bl.items()},
                              "bl0_max_V": x.get("bl0_max_V")})
            out["macros"][n] = {"experiment": "e8_4a10", "table": t, "bin_md5": md5(binf),
                                "bin_hex": open(binf, "rb").read().hex(), "result_md5": md5(rj),
                                "bitlines": r_["meta"].get("bitlines"), "complete": complete,
                                "cycles_complete": s.get("cycles_complete"), "cycles_total": s.get("cycles_total"),
                                "rows_read": len(rows), "reads": reads}
            ncell = sum(len(r["bl1_by_col"]) for r in reads if r["row"] != 0)
            print(f"   {n:<34} {'complete' if complete else 'INCOMPLETE':<12} {len(rows):4d} {ncell:6d}  {md5(rj)}")
    f = os.path.join(work, "export_cells_e8_4a10.json.gz")
    with gzip.open(f, "wt") as fh:
        json.dump(out, fh)
    nc = sum(1 for m in out["macros"].values() if m["complete"])
    print(f"   macros exported: {len(out['macros'])} ({nc} complete); one-cell bitlines of rows 1-47: {n_cells}")
    print(f"written: {f}  md5 {md5(f)}  {os.path.getsize(f)} bytes  ({time.time() - t0:.0f} s)")


if __name__ == "__main__":
    main()
