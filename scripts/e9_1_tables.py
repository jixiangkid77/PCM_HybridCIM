#!/usr/bin/env python3
"""
e9_1_tables.py   P2R-E9.1: contents of the address-map ROM with one 40-bit word per entry.

One word per entry (the 25 weights that a datapath step reads; 2,482 entries per model in the
order conv1, conv2, fc1, fc2, fc3, as the slot tables of data/rtl_inputs_<M>_v3), the format of
E9.0 (scripts/e9_0_tables.py), stored high byte first:
  bits 24..0   lane k: 0 = protected (SRAM), 1 = not protected (PCM or no weight); lanes past
               the fan-in of the last entry of an output (fc2, fc3) are 1
  bits 36..25  NOT of the number of protected weights before the entry in its layer (12 bit)
  bits 39..37  1
The address-map unit of E9.1 (rtl/e9/amu9_decode.v) decodes, for a lane k that holds weight
index a (within its layer):
  protected = !w[k];  count = ~w[36:25];  pre = protected lanes 0..k-1
  SRAM slot = count + pre                  (protected)
  PCM  slot = a - count - pre              (not protected)
Organisation (E9.0 probe, both tables PASS): macros of 48 rows x 8 words (320 columns); the
last word of every macro (address 383) is all ones, the parking word; entry e is in macro
e div 383 at address e mod 383; unused words are all ones.

The script builds the words from the 25 SRAM-side and 25 PCM-side slot tables, writes them, reads
the written image back and decodes every weight from the image alone (the arithmetic of the
unit), and compares medium and slot with the slot tables: 0 differences are required.

Writes, per model M:
  <out>/e9rom_<M>.bin    the image as the macros hold it (7 x 384 words of 5 bytes, high byte
                         first), the input of the macro generation (E9.2)
  <out>/e9rom_<M>.hex    the same image, one word of 10 hex digits per line ($readmemh of
                         rtl/e9/e9_rom.v)
and <out>/e9_1_tables.json (entries, macros, map bits, zero bits per macro and row, decode check).
Usage:
  python3 scripts/e9_1_tables.py --paper2 . --out reports/e9/e9_1/tables
"""
import argparse
import hashlib
import json
import os
import sys

LAYERS = ["conv1", "conv2", "fc1", "fc2", "fc3"]
FAN_IN = {"conv1": 25, "conv2": 150, "fc1": 400, "fc2": 120, "fc3": 84}
CONV = {"conv1", "conv2"}
K = 25
WBITS = 40
ONES = (1 << WBITS) - 1
ROWS, WPR = 48, 8
PER = ROWS * WPR            # 384 words per macro
EPM = PER - 1               # 383 entries per macro; address 383 = parking word


def rd(path):
    return [x.strip().lower() for x in open(path) if x.strip() and not x.startswith("//") and not x.startswith("@")]


def tables(data_dir):
    """the 50 slot tables per layer and the weight index of lane 0 of every entry"""
    out = []
    for L in LAYERS:
        S = [rd(os.path.join(data_dir, f"addr_to_slot_{L}_sram_lane{k:02d}.hex")) for k in range(K)]
        P = [rd(os.path.join(data_dir, f"addr_to_slot_{L}_pcm_lane{k:02d}.hex")) for k in range(K)]
        n = len(S[0])
        if any(len(t) != n for t in S + P):
            sys.exit(f"ERROR: the lane tables of {L} have different lengths")
        per_out = 1 if L in CONV else -(-FAN_IN[L] // K)
        for e in range(n):
            if L in CONV:
                a0, nvalid = K * e, K
            else:
                o, j = divmod(e, per_out)
                a0, nvalid = o * FAN_IN[L] + K * j, min(K, FAN_IN[L] - K * j)
            out.append({"layer": L, "e": e, "a0": a0, "nvalid": nvalid,
                        "sram": [S[k][e] for k in range(K)], "pcm": [P[k][e] for k in range(K)]})
    return out


def build(entries):
    words, layers = [], {}
    count, last = 0, None
    for x in entries:
        if x["layer"] != last:
            count, last = 0, x["layer"]
            layers[last] = {"entries": 0, "protected": 0}
        if count > 4095:
            sys.exit("ERROR: the count does not fit 12 bits")
        bits = (1 << K) - 1
        for k in range(x["nvalid"]):
            if x["sram"][k] != "ffff":
                bits &= ~(1 << k)
        words.append((0b111 << 37) | ((~count & 0xFFF) << 25) | bits)
        n_prot = K - bin(bits).count("1")
        layers[last]["entries"] += 1
        layers[last]["protected"] += n_prot
        count += n_prot
    return words, layers


def decode_check(image, entries):
    """decode every weight from the image alone, as amu9_decode.v does, against the slot tables"""
    diff = {"sram_slot": 0, "pcm_slot": 0, "medium": 0, "invalid_lane_not_ffff": 0, "constant_bits": 0}
    n_weights = 0
    for e, x in enumerate(entries):
        w = image[(e // EPM) * PER + e % EPM]
        if (w >> 37) != 0b111:
            diff["constant_bits"] += 1
        count = (~(w >> 25)) & 0xFFF
        pre = 0
        for k in range(K):
            prot = not ((w >> k) & 1)
            if k >= x["nvalid"]:
                if prot or x["sram"][k] != "ffff" or x["pcm"][k] != "ffff":
                    diff["invalid_lane_not_ffff"] += 1
                continue
            n_weights += 1
            s_tab, p_tab = x["sram"][k], x["pcm"][k]
            if prot != (s_tab != "ffff") or prot == (p_tab != "ffff"):
                diff["medium"] += 1
            if prot:
                if s_tab == "ffff" or int(s_tab, 16) != count + pre:
                    diff["sram_slot"] += 1
                pre += 1
            else:
                if p_tab == "ffff" or int(p_tab, 16) != x["a0"] + k - count - pre:
                    diff["pcm_slot"] += 1
    return n_weights, diff


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".")
    ap.add_argument("--models", default="A,B")
    ap.add_argument("--out", default="reports/e9/e9_1/tables")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    summary = {"word_bits": WBITS, "rows": ROWS, "words_per_row": WPR, "columns": WPR * WBITS,
               "words_per_macro": PER, "entries_per_macro": EPM, "parking_address": PER - 1, "models": {}}
    ok = True
    for M in a.models.split(","):
        data_dir = os.path.join(a.paper2, "data", f"rtl_inputs_{M}_v3")
        entries = tables(data_dir)
        words, layers = build(entries)
        nmac = -(-len(words) // EPM)
        image = []
        for m in range(nmac):
            part = words[m * EPM:(m + 1) * EPM]
            image += part + [ONES] * (EPM - len(part)) + [ONES]
        f_bin = os.path.join(a.out, f"e9rom_{M}.bin")
        f_hex = os.path.join(a.out, f"e9rom_{M}.hex")
        with open(f_bin, "wb") as fh:
            for w in image:
                fh.write(w.to_bytes(WBITS // 8, "big"))
        with open(f_hex, "w") as fh:
            for w in image:
                fh.write(f"{w:010x}\n")
        # read the written image back and decode from it alone
        back = [int(x, 16) for x in open(f_hex) if x.strip()]
        bb = open(f_bin, "rb").read()
        back_bin = [int.from_bytes(bb[i:i + 5], "big") for i in range(0, len(bb), 5)]
        n_w, diff = decode_check(back, entries)
        same = back == image and back_bin == image
        bad = sum(diff.values()) + (0 if same else 1)
        ok = ok and bad == 0
        zeros = []
        for m in range(nmac):
            mw = image[m * PER:(m + 1) * PER]
            rowz = [sum(WBITS - bin(w).count("1") for w in mw[r * WPR:(r + 1) * WPR]) for r in range(ROWS)]
            zeros.append({"macro": m, "entries": min(EPM, len(words) - m * EPM), "zero_bits": sum(rowz),
                          "zero_fraction": round(sum(rowz) / (PER * WBITS), 4), "zeros_per_row_max": max(rowz)})
        n_prot = sum(v["protected"] for v in layers.values())
        summary["models"][M] = {
            "entries": len(words), "macros": nmac, "image_words": len(image), "map_bits": len(words) * WBITS,
            "protected": n_prot, "layers": layers, "weights_decoded": n_w, "decode_differences": diff,
            "image_reads_back": same, "bin": f_bin, "hex": f_hex,
            "bin_md5": hashlib.md5(open(f_bin, "rb").read()).hexdigest(),
            "hex_md5": hashlib.md5(open(f_hex, "rb").read()).hexdigest(), "macro_zeros": zeros}
        print(f"model {M}: {len(words)} entries, {n_prot} protected weights "
              f"{[layers[L]['protected'] for L in LAYERS]}, {nmac} macros of {ROWS} rows x {WPR} words, "
              f"{len(image)} words, {len(words) * WBITS} map bits")
        print(f"   decoded {n_w} weights from the image: differences {diff}; image reads back {same}")
        for z in zeros:
            print(f"   macro {z['macro']}: {z['entries']} entries, zero bits {z['zero_bits']} ({z['zero_fraction']:.4f}), "
                  f"largest per row {z['zeros_per_row_max']}")
        print(f"   {f_bin}  {summary['models'][M]['bin_md5']}")
        print(f"   {f_hex}  {summary['models'][M]['hex_md5']}")
    with open(os.path.join(a.out, "e9_1_tables.json"), "w") as fh:
        json.dump(summary, fh, indent=1)
    print("TABLES OK" if ok else "TABLES FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
