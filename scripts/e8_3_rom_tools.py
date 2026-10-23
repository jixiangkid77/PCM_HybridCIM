#!/usr/bin/env python3
"""
e8_3_rom_tools.py  build | check

P2R-E8.3. Regenerate the address-map ROM with the real map contents.

The macro used for the submitted area (paper2_addr_decoder_8x5120) was
generated from paper2_addr_decoder.bin, whose 40,960 bits are all zero: a
placeholder. A mask ROM places its transistors according to its data, so
that netlist cannot give the read energy of the real map. This tool writes
the real contents of selected decoders into the binary format the ROM
generator reads, writes a self-contained generator configuration for each,
and afterwards checks bit by bit that each generated netlist stores exactly
those contents.

build
    For each model, decoder side (sram, pcm) and lane:
      * concatenates the lane's five tables in the order the decoder indexes
        them (conv1 6, conv2 96, fc1 1920, fc2 420, fc3 40 = 2,482 entries,
        16 bits each), as rtl/src/*_addr_decoder.v loads them;
      * pads to 2,496 words with 0xFFFF, the decoders' own miss value. 2,496
        is the smallest size the generator lays out without a partial row:
        13 words per row x 192 rows (see organisation() below);
      * writes it big-endian, so each 16-bit entry is stored most significant
        bit first, and writes the generator configuration.
    It also builds one 8-bit x 5,120-word macro of the same contents (the
    organisation of the submitted area figure) to test whether the area
    depends on the data.

check
    For each generated macro: reads the LEF footprint, rebuilds the stored
    bit matrix from the transistor netlist (one cell = 1, shorted zero cell
    = 0, in the data array only) and compares it with the matrix the
    generator should have built from the binary file.

Usage (paths are WSL paths):
    python3 e8_3_rom_tools.py build --paper2 /mnt/d/Project/hybrid_memory/paper2
    python3 e8_3_rom_tools.py check --paper2 /mnt/d/Project/hybrid_memory/paper2
"""
import argparse
import json
import math
import os
import re
import sys

K = 25
LAYERS = ["conv1", "conv2", "fc1", "fc2", "fc3"]
DEPTH = [6, 96, 1920, 420, 40]
TOTAL_ENTRIES = sum(DEPTH)          # 2482
MISS = 0xFFFF
WORDS_16 = 2496                     # 13 words per row x 192 rows, no partial row
BYTES_8 = 5120                      # the submitted 8 x 5120 organisation


# --------------------------------------------------------------------------
# map contents
# --------------------------------------------------------------------------
def read_memh(path, depth):
    """Minimal $readmemh reader; unloaded words keep the RTL default 0xFFFF."""
    mem = [MISS] * depth
    addr = 0
    with open(path) as fh:
        for raw in fh:
            line = raw.split("//", 1)[0]
            for tok in line.split():
                if tok.startswith("@"):
                    addr = int(tok[1:], 16)
                    continue
                if addr < depth:
                    mem[addr] = int(tok, 16)
                addr += 1
    return mem


def lane_words(data_dir, side, lane):
    words = []
    for li, name in enumerate(LAYERS):
        f = os.path.join(data_dir, f"addr_to_slot_{name}_{side}_lane{lane:02d}.hex")
        if not os.path.isfile(f):
            sys.exit(f"missing table file {f}")
        words += read_memh(f, DEPTH[li])
    assert len(words) == TOTAL_ENTRIES
    return words


def bytes_16(words, n_words=WORDS_16):
    w = words + [MISS] * (n_words - len(words))
    out = bytearray()
    for v in w:
        out += bytes([(v >> 8) & 0xFF, v & 0xFF])
    return bytes(out)


def bytes_8(words, n_bytes=BYTES_8):
    out = bytearray()
    for v in words:
        out += bytes([(v >> 8) & 0xFF, v & 0xFF])
    out += bytes([0xFF]) * (n_bytes - len(out))
    return bytes(out)


# --------------------------------------------------------------------------
# replica of compiler/rom_config.py (OpenRAM commit e16d9eb, v1.2.49)
# --------------------------------------------------------------------------
def organisation(n_bytes, word_bytes, words_per_row=None):
    """compute_sizes(): returns num_words, words_per_row, cols, rows"""
    data_size = (n_bytes * 8) / 8
    num_words = int(data_size / word_bytes)
    wpr = words_per_row or int(math.ceil(math.sqrt(num_words) / (2 * word_bytes)))
    cols = wpr * word_bytes * 8
    rows = int(num_words / wpr)
    return num_words, wpr, cols, rows


def bitmap(data, word_bytes, wpr, cols, scramble=True):
    """read_data_bin() + chunk_data(): the per-row bit lists, column order as placed"""
    bits = [int(b) for byte in data for b in f"{byte:08b}"]
    rows = []
    for i in range(0, len(bits), cols):
        r = bits[i:i + cols]
        if len(r) < cols:
            r = [0] * (cols - len(r)) + r
        rows.append(r)
    if scramble:
        wb = word_bytes * 8
        rows = [[r[bit + word * wb] for bit in range(wb) for word in range(wpr)] for r in rows]
    return rows


# --------------------------------------------------------------------------
# build
# --------------------------------------------------------------------------
def write_config(path, name, bin_path, word_bytes, macro_dir):
    with open(path, "w") as fh:
        fh.write(f"# P2R-E8.3 ROM configuration for {name}.\n")
        fh.write("# Generated by scripts/e8_3_rom_tools.py build; do not edit by hand.\n")
        fh.write("# Same options as macros/rom_configs/sky130_rom_common.py of the\n")
        fh.write("# submitted macro, with checking off as in paper2_addr_decoder.py.\n")
        fh.write('tech_name = "sky130"\n')
        fh.write("nominal_corner_only = True\n")
        fh.write('route_supplies = "ring"\n')
        fh.write("check_lvsdrc = False\n")
        fh.write(f"word_size = {word_bytes}\n")
        fh.write(f'rom_data = "{bin_path}"\n')
        fh.write('data_type = "bin"\n')
        fh.write(f'output_name = "{name}"\n')
        fh.write(f'output_path = "{macro_dir}/"\n')


def zero_stats(rows_bits, n_rows):
    z = [r.count(0) for r in rows_bits[:n_rows]]
    return {"zero_fraction": sum(z) / (n_rows * len(rows_bits[0])),
            "zeros_per_row_mean": sum(z) / n_rows, "zeros_per_row_min": min(z),
            "zeros_per_row_max": max(z)}


def cmd_build(a):
    root = os.path.join(a.paper2, "reports", "e8_rom")
    dirs = {d: os.path.join(root, d) for d in ("bins", "configs", "macros", "logs")}
    for d in dirs.values():
        os.makedirs(d, exist_ok=True)
    entries = []

    def add(model, side, lane, org):
        data_dir = os.path.join(a.paper2, "data", f"rtl_inputs_{model}_v3")
        words = lane_words(data_dir, side, lane)
        if org == "16":
            data, wb, tag = bytes_16(words), 2, f"16x{WORDS_16}"
        else:
            data, wb, tag = bytes_8(words), 1, f"8x{BYTES_8}"
        name = f"e8rom_{model}_{side}_l{lane:02d}_{tag}"
        bin_path = os.path.join(dirs["bins"], name + ".bin")
        with open(bin_path, "wb") as fh:
            fh.write(data)
        macro_dir = os.path.join(dirs["macros"], name)
        cfg = os.path.join(dirs["configs"], name + ".py")
        write_config(cfg, name, bin_path, wb, macro_dir)
        nw, wpr, cols, rows = organisation(len(data), wb)
        bm = bitmap(data, wb, wpr, cols)
        lost_words = nw - rows * wpr
        e = {"name": name, "model": model, "side": side, "lane": lane, "org": org,
             "bin": bin_path, "config": cfg, "macro_dir": macro_dir,
             "bytes": len(data), "num_words": nw, "words_per_row": wpr,
             "cols": cols, "rows": rows, "words_not_stored": lost_words,
             "real_entries": TOTAL_ENTRIES}
        e.update(zero_stats(bm, rows))
        entries.append(e)
        return e

    for model in a.models:
        for side in ("sram", "pcm"):
            for lane in a.lanes:
                add(model, side, lane, "16")
    add("A", "sram", 0, "8")

    # how representative the sampled lanes are: zero fraction of every lane
    rep = []
    for model in a.models:
        data_dir = os.path.join(a.paper2, "data", f"rtl_inputs_{model}_v3")
        for side in ("sram", "pcm"):
            fr = []
            for lane in range(K):
                d = bytes_16(lane_words(data_dir, side, lane))
                nw, wpr, cols, rows = organisation(len(d), 2)
                fr.append(zero_stats(bitmap(d, 2, wpr, cols), rows)["zero_fraction"])
            rep.append({"model": model, "side": side, "all_lanes": fr})

    with open(os.path.join(root, "e8_3_manifest.json"), "w") as fh:
        json.dump({"entries": entries, "zero_fraction_all_lanes": rep}, fh, indent=2)

    print("P2R-E8.3 build")
    print(f"{'macro':34s} {'org':4s} {'words':>6s} {'w/row':>5s} {'cols':>5s} {'rows':>5s} "
          f"{'not stored':>10s} {'zero frac':>9s}")
    for e in entries:
        print(f"{e['name']:34s} {e['org']:4s} {e['num_words']:6d} {e['words_per_row']:5d} "
              f"{e['cols']:5d} {e['rows']:5d} {e['words_not_stored']:10d} {e['zero_fraction']:9.4f}")
    print()
    print("zero fraction of the 16-bit array, all 25 lanes (sampled lanes in brackets)")
    for r in rep:
        f = r["all_lanes"]
        smp = ", ".join(f"{f[l]:.4f}" for l in a.lanes)
        print(f"  Model {r['model']} {r['side']:4s}: mean {sum(f)/len(f):.4f}  min {min(f):.4f}  "
              f"max {max(f):.4f}   [{smp}]")
    bad = [e for e in entries if e["org"] == "16" and e["words_not_stored"] != 0]
    if bad:
        sys.exit("ERROR: a 16-bit macro would drop words; the organisation is wrong")
    print("\nBUILD OK: every 16-bit macro stores all 2,496 words "
          "(the 8-bit macro drops 8 padding words, as the submitted one does)")


# --------------------------------------------------------------------------
# check
# --------------------------------------------------------------------------
def parse_base_array(sp_path, name):
    """Return {(row, col): bit} from the data array subcircuit.
    OpenRAM writes subcircuit instances as 'X<inst>', '+ <nets>', '+ <cell>'."""
    target = f"{name}_rom_base_array"
    cells = {}
    inside = False
    rec = None

    def flush(r):
        if r is None:
            return
        m = re.match(r"Xbit_r(\d+)_c(\d+)$", r[0])
        if m and len(r) > 1:
            cell = r[-1]
            if cell.endswith("rom_base_one_cell"):
                cells[(int(m.group(1)), int(m.group(2)))] = 1
            elif cell.endswith("rom_base_zero_cell"):
                cells[(int(m.group(1)), int(m.group(2)))] = 0

    with open(sp_path) as fh:
        for line in fh:
            t = line.split()
            if not t:
                continue
            if t[0].upper() == ".SUBCKT":
                inside = (t[1] == target)
                rec = None
                continue
            if not inside:
                continue
            if t[0].upper() == ".ENDS":
                flush(rec)
                break
            if t[0].startswith("X"):
                flush(rec)
                rec = t[:]
            elif t[0] == "+" and rec is not None:
                rec += t[1:]
            else:
                flush(rec)
                rec = None
    return cells


def cmd_check(a):
    root = os.path.join(a.paper2, "reports", "e8_rom")
    with open(os.path.join(root, "e8_3_manifest.json")) as fh:
        man = json.load(fh)
    print("P2R-E8.3 check")
    print(f"{'macro':34s} {'LEF W x H (um)':>20s} {'area mm2':>9s} {'x50 mm2':>8s} "
          f"{'cells':>7s} {'bit errors':>10s} {'dummy row':>9s}")
    ok_all = True
    for e in man["entries"]:
        name, mdir = e["name"], e["macro_dir"]
        lef = os.path.join(mdir, name + ".lef")
        sp = os.path.join(mdir, name + ".sp")
        if not (os.path.isfile(lef) and os.path.isfile(sp)):
            print(f"{name:34s} MISSING OUTPUT")
            ok_all = False
            continue
        w = h = None
        with open(lef) as fh:
            for line in fh:
                m = re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", line)
                if m:
                    w, h = float(m.group(1)), float(m.group(2))
                    break
        with open(e["bin"], "rb") as fh:
            data = fh.read()
        wb = 2 if e["org"] == "16" else 1
        bm = bitmap(data, wb, e["words_per_row"], e["cols"])
        cells = parse_base_array(sp, name)
        rows, cols = e["rows"], e["cols"]
        errors = sum(1 for r in range(rows) for c in range(cols)
                     if cells.get((r, c)) != bm[r][c])
        dummy_ok = all(cells.get((rows, c)) == 1 for c in range(cols))
        extra = [rc for rc in cells if rc[0] > rows or rc[1] >= cols]
        ok = (errors == 0 and dummy_ok and not extra and w is not None)
        ok_all &= ok
        area = (w * h / 1e6) if w else float("nan")
        print(f"{name:34s} {f'{w} x {h}':>20s} {area:9.5f} {50*area:8.3f} {len(cells):7d} "
              f"{errors:10d} {'ok' if dummy_ok else 'BAD':>9s}{'' if not extra else '  EXTRA CELLS'}")
    print("\nreference, submitted macro paper2_addr_decoder_8x5120 (all-zero data): LEF "
          "347.73 x 229.125 um = 0.07967 mm2, x50 = 3.984 mm2")
    print("the ROM generator's LEF leaves out the supply ring it draws; the drawn extent of the "
          "submitted macro is 362.690 x 244.085 um (E8.1) and is measured for every macro by "
          "e8_1b_macro_footprints.sh")
    print("RESULT:", "ALL MACROS STORE THE MAP EXACTLY" if ok_all else "CHECK FAILED")
    sys.exit(0 if ok_all else 2)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--paper2", required=True)
    b.add_argument("--models", nargs="+", default=["A", "B"])
    b.add_argument("--lanes", nargs="+", type=int, default=[0, 12, 24])
    c = sub.add_parser("check")
    c.add_argument("--paper2", required=True)
    a = ap.parse_args()
    cmd_build(a) if a.cmd == "build" else cmd_check(a)


if __name__ == "__main__":
    main()
