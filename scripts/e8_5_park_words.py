#!/usr/bin/env python3
"""
e8_5_park_words.py   (P2R-E8.5)

The parking word of every address-map ROM macro, as constants for the RTL
of the address-map unit (rtl/e8/amu_park_A.vh, amu_park_B.vh).

The choice is the one E8.6a-2 used for D (scripts/e8_6a2_rom_energy.py,
class Table), so that the RTL parks exactly the words the energy figures
assume:
  1. the word E8.4b chose after simulating the macro (the 48 macros of
     E8.4a-7), if it is a word of 0xFFFF;
  2. otherwise the Pd rule of E8.4b among the words of 0xFFFF of the macro:
     the smallest 0.3 x (rows - 1 - row) + 0.18 x (zero bits in the row),
     ties by (row, word);
  3. a macro without a word of 0xFFFF: the word with the fewest zero bits
     (E8.6a: 3 of the 400 macros).
The address in the macro is row x 16 + word.

Usage:
  python3 scripts/e8_5_park_words.py --paper2 /mnt/d/Project/hybrid_memory/paper2
Reads data/rtl_inputs_{A,B}_v3/, reports/e8_rom/e8_4b/model.json (if present),
scripts/e8_6a2_rom_energy.py; writes rtl/e8/amu_park_A.vh, rtl/e8/amu_park_B.vh.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import time


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        h.update(fh.read())
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--paper2", required=True)
    ap.add_argument("--model-json", default=None, help="default reports/e8_rom/e8_4b/model.json")
    ap.add_argument("--rows", type=int, default=48)
    ap.add_argument("--wpr", type=int, default=13)
    ap.add_argument("--table-words", type=int, default=2496)
    ap.add_argument("--out-dir", default=None, help="default rtl/e8")
    a = ap.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("e86a2", os.path.join(here, "e8_6a2_rom_energy.py"))
    E = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(E)
    out_dir = a.out_dir or os.path.join(a.paper2, "rtl", "e8")
    os.makedirs(out_dir, exist_ok=True)
    print(f"P2R-E8.5 parking words  {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"   script : {md5(os.path.abspath(__file__))}  {os.path.abspath(__file__)}")
    print(f"   E8.6a-2: {md5(os.path.join(here, 'e8_6a2_rom_energy.py'))}")
    mj = a.model_json or os.path.join(a.paper2, "reports", "e8_rom", "e8_4b", "model.json")
    choice = {}
    if os.path.isfile(mj):
        model = json.load(open(mj))
        print(f"   E8.4b model: {md5(mj)}  {mj} (rows {model.get('rows')})")
        if model.get("rows") != a.rows:      # as E8.6a-2: warn, use the choices (each is checked below)
            print(f"   WARNING: the E8.4b model was fitted on {model.get('rows')}-row macros; this run uses {a.rows} rows")
        for r in model["runs"]:
            if r["kind"] == "parta" and r.get("park_choice"):
                tok = r["park_choice"].split()[0]
                choice.setdefault(r["table"], {})[r["k"]] = int(tok) if tok.isdigit() else None
    else:
        print(f"   no E8.4b model at {mj}: Pd rule only")
    per = a.rows * a.wpr
    suf = f"_16x{a.table_words}"
    for M in ("A", "B"):
        lines, src_n = [], {}
        for side_i, side in enumerate(("sram", "pcm")):
            for lane in range(E.K):
                t = f"e8rom_{M}_{side}_l{lane:02d}{suf}"
                words = E.table_words(a.paper2, M, side, lane, a.table_words)
                for k in range(len(words) // per):
                    w_k = words[k * per:(k + 1) * per]
                    zr = [sum(E.zbits(x) for x in w_k[r * a.wpr:(r + 1) * a.wpr]) for r in range(a.rows)]
                    got, src = None, None
                    c = choice.get(t, {}).get(k)
                    if c is not None:
                        r, w = c >> 4, c & 15
                        if r < a.rows and w < a.wpr and w_k[r * a.wpr + w] == E.MISS:
                            got, src = (r, w), "E8.4b"
                    if got is None:
                        ones = [(r, w) for r in range(a.rows) for w in range(a.wpr) if w_k[r * a.wpr + w] == E.MISS]
                        if ones:
                            got = min(ones, key=lambda rw: (E.pd_key(a.rows, zr[rw[0]], rw[0]), rw))
                            src = "Pd rule"
                        else:
                            got = min(((r, w) for r in range(a.rows) for w in range(a.wpr)),
                                      key=lambda rw: (E.zbits(w_k[rw[0] * a.wpr + rw[1]]), rw))
                            src = "no word of 0xFFFF"
                    src_n[src] = src_n.get(src, 0) + 1
                    addr = got[0] * 16 + got[1]
                    lines.append(f"            {side_i * 100 + lane * 4 + k:4d}: amu_park = 10'd{addr};"
                                 f"  // {t} r48k{k}: row {got[0]} word {got[1]} = {w_k[got[0] * a.wpr + got[1]]:04x}, {src}")
        f = os.path.join(out_dir, f"amu_park_{M}.vh")
        with open(f, "w") as fh:
            fh.write(f"// amu_park_{M}.vh  (P2R-E8.5, generated by scripts/e8_5_park_words.py, "
                     f"{time.strftime('%Y-%m-%d %H:%M:%S')})\n")
            fh.write(f"// Parking word of every r48 macro of model {M}: address = row*16 + word.\n")
            fh.write("// index = side*100 + lane*4 + macro (side 0 = SRAM, 1 = PCM)\n")
            fh.write("function [9:0] amu_park;\n    input integer side, lane, m;\n    begin\n"
                     "        case (side * 100 + lane * 4 + m)\n")
            fh.write("\n".join(lines) + "\n")
            fh.write("            default: amu_park = 10'd0;\n        endcase\n    end\nendfunction\n")
        print(f"   model {M}: {len(lines)} macros; " + ", ".join(f"{k} {v}" for k, v in sorted(src_n.items())) +
              f"; written {f}  md5 {md5(f)}")


if __name__ == "__main__":
    main()
