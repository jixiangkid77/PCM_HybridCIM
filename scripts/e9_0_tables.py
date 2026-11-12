#!/usr/bin/env python3
"""
e9_0_tables.py   P2R-E9.0: the address map as assignment bits and a count.

One word per entry (the 25 weights that a datapath step reads; 2,482 entries
per model in the order conv1, conv2, fc1, fc2, fc3, as the slot tables of
data/rtl_inputs_<M>_v3). OpenRAM sizes ROM words in bytes, so a word is 40 bit
(5 bytes), stored high byte first as in E8.3:
  bits 24..0   lane k: 0 = protected (SRAM), 1 = not protected (PCM or no
               weight); lanes past the fan-in of the last entry of an output
               (fc2, fc3) are 1
  bits 36..25  NOT of the count of protected weights before the entry in its
               layer (12 bit)
  bits 39..37  1
Ones are the common value, so that a read leaves few zero bits (a zero bit
draws about 60-80 uW after a read until the macro is parked, E8.4b/E8.5d).
Decoding (what the address-map unit would do):
  protected(k) = !w[k];  count = ~w[36:25]
  SRAM slot(k) = count + (protected lanes 0..k-1)
  PCM  slot(k) = weight index - count - (protected lanes 0..k-1)
The script checks this decoding against every entry of the 25 SRAM-side and
25 PCM-side slot tables (0 differences required), then lays the words out in
macros of R rows x W words with the last word of every macro all ones (the
parking word) and writes:
  <out>/e9rom_<M>_40x<n>_w<W>.bin   the table as the macros hold it (n words)
  <out>/e9_0_layout_w<W>.json       per model: entries, macros, zero bits per
                                    macro and row, the word of every entry
Usage:
  python3 scripts/e9_0_tables.py --paper2 . --rows 48 --wpr 8 --out reports/e9_rom/tables
"""
import argparse, json, os, sys

LAYERS = ["conv1", "conv2", "fc1", "fc2", "fc3"]
FAN_IN = {"conv1": 25, "conv2": 150, "fc1": 400, "fc2": 120, "fc3": 84}
CONV = {"conv1", "conv2"}
WBITS = 40


def rd(path):
    return [x.strip().lower() for x in open(path) if x.strip() and not x.startswith("//") and not x.startswith("@")]


def build(data_dir):
    words, info = [], {"layers": {}}
    errors = {"sram": 0, "pcm": 0, "neither_or_both": 0}
    max_count = 0
    for L in LAYERS:
        S = [rd(os.path.join(data_dir, f"addr_to_slot_{L}_sram_lane{k:02d}.hex")) for k in range(25)]
        P = [rd(os.path.join(data_dir, f"addr_to_slot_{L}_pcm_lane{k:02d}.hex")) for k in range(25)]
        n = len(S[0])
        if any(len(t) != n for t in S + P):
            sys.exit(f"ERROR: the lane tables of {L} have different lengths")
        per_out = 1 if L in CONV else -(-FAN_IN[L] // 25)
        count = 0
        n_prot = 0
        for e in range(n):
            if L in CONV:
                a0, nvalid = 25 * e, 25
            else:
                o, j = divmod(e, per_out)
                a0, nvalid = o * FAN_IN[L] + 25 * j, min(25, FAN_IN[L] - 25 * j)
            if count > 4095:
                sys.exit("ERROR: count does not fit 12 bits")
            max_count = max(max_count, count)
            bits = (1 << 25) - 1
            pre = 0
            for k in range(25):
                s, p = S[k][e], P[k][e]
                if k >= nvalid:
                    if s != "ffff" or p != "ffff":
                        errors["neither_or_both"] += 1
                    continue
                prot = s != "ffff"
                if prot == (p != "ffff"):
                    errors["neither_or_both"] += 1
                if prot:
                    bits &= ~(1 << k)
                    if int(s, 16) != count + pre:
                        errors["sram"] += 1
                    pre += 1
                elif int(p, 16) != (a0 + k) - (count + pre):
                    errors["pcm"] += 1
            w = (0b111 << 37) | ((~count & 0xFFF) << 25) | bits
            words.append(w)
            count += pre
            n_prot += pre
        info["layers"][L] = {"entries": n, "protected": n_prot}
    info["entries"] = len(words)
    info["max_count_before_entry"] = max_count
    info["decode_errors"] = errors
    return words, info


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".")
    ap.add_argument("--rows", type=int, default=48)
    ap.add_argument("--wpr", type=int, default=8)
    ap.add_argument("--models", default="A,B")
    ap.add_argument("--out", default="reports/e9_rom/tables")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    per = a.rows * a.wpr
    data_per = per - 1
    layout = {"word_bits": WBITS, "word_bytes": WBITS // 8, "rows": a.rows, "words_per_row": a.wpr,
              "cols": a.wpr * WBITS, "words_per_macro": per, "entries_per_macro": data_per, "models": {}}
    ok = True
    for M in a.models.split(","):
        words, info = build(os.path.join(a.paper2, "data", f"rtl_inputs_{M}_v3"))
        nmac = -(-len(words) // data_per)
        table, where = [], []
        for m in range(nmac):
            part = words[m * data_per:(m + 1) * data_per]
            for i, _ in enumerate(part):
                where.append([m, i])
            part = part + [(1 << WBITS) - 1] * (data_per - len(part))   # unused words: all ones
            table += part + [(1 << WBITS) - 1]                          # last word: parking
        name = f"e9rom_{M}_40x{len(table)}_w{a.wpr}"
        path = os.path.join(a.out, name + ".bin")
        with open(path, "wb") as fh:
            for w in table:
                fh.write(w.to_bytes(WBITS // 8, "big"))
        zeros = []
        for m in range(nmac):
            mw = table[m * per:(m + 1) * per]
            rowz = [sum(WBITS - bin(w).count("1") for w in mw[r * a.wpr:(r + 1) * a.wpr]) for r in range(a.rows)]
            zeros.append({"macro": m, "zero_bits": sum(rowz), "zero_fraction": round(sum(rowz) / (per * WBITS), 4),
                          "zeros_per_row_max": max(rowz), "zeros_per_row_mean": round(sum(rowz) / a.rows, 2)})
        bad = sum(info["decode_errors"].values())
        ok = ok and bad == 0
        layout["models"][M] = {"bin": path, "name": name, "table_words": len(table), "macros": nmac,
                               "map_bits": len(words) * WBITS, "info": info, "macro_zeros": zeros,
                               "entry_word": where}
        print(f"model {M}: {info['entries']} entries, protected per layer "
              f"{[info['layers'][L]['protected'] for L in LAYERS]}, largest count {info['max_count_before_entry']}, "
              f"decode differences {info['decode_errors']}")
        print(f"   {nmac} macros of {a.rows} rows x {a.wpr} words ({a.wpr * WBITS} columns), {len(table)} words, "
              f"{len(words) * WBITS} map bits; {path}")
        for z in zeros:
            print(f"   macro {z['macro']}: zero bits {z['zero_bits']} ({z['zero_fraction']:.4f}), "
                  f"largest per row {z['zeros_per_row_max']}")
    with open(os.path.join(a.out, f"e9_0_layout_w{a.wpr}.json"), "w") as fh:
        json.dump(layout, fh, indent=1)
    print("TABLES OK" if ok else "TABLES FAILED: the decoding differs from the slot tables")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
