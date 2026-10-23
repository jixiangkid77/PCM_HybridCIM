#!/usr/bin/env python3
"""
e8_2_trace_summary.py

P2R-E8.2 post-processing. Reads the lookup trace written by
rtl/tb/e8_lookup_monitor.v during a full RTL inference and turns it into
the counts the address-map energy needs.

For every MAC operation and every one of the 25 lanes it replays the
address arithmetic of rtl/src/sram_addr_decoder.v and pcm_addr_decoder.v
(the two are identical in this part), decides whether the lane performs a
ROM lookup and which entry of its 2,482-entry table it reads, and then
checks the result against the hit bits the RTL itself produced:

    predicted SRAM hit = entry != 0xFFFF, entry < SRAM size, base + entry < 3074
    predicted PCM  hit = entry != 0xFFFF, entry < PCM size,  base + entry < 58396

(the partition base and size of each operation are recorded in the trace,
exactly as the decoders' hit and range logic uses them).

Every lookup must agree. Agreement on all of them is the evidence that the
entry counts written below are the entries the hardware reads.

Outputs (in --out):
    e8_2_summary_<M>.txt     human-readable summary
    e8_2_summary_<M>.json    the same numbers for later scripts
    e8_2_entry_counts_<M>.csv
        lane, entry, layer, count : reads of each ROM entry per inference.
        The SRAM-side and PCM-side decoders of a lane read the same entry,
        so one table serves both.
    e8_2_ops_<M>.csv          cycle, layer, valid lane count per operation

Usage:
    python3 e8_2_trace_summary.py --trace trace_A.txt \
        --data <paper2>/data/rtl_inputs_A_v3 --model A \
        --tb-sram-reads 267143 --out <paper2>/reports/e8_rom/trace
"""
import argparse
import json
import os
import statistics
import sys

K = 25
LAYERS = ["conv1", "conv2", "fc1", "fc2", "fc3"]
DEPTH = [6, 96, 1920, 420, 40]                 # per-lane table depth per layer
OFFSET = [0, 6, 102, 2022, 2442]               # entry offset in the 2,482-entry ROM
TOTAL_ENTRIES = sum(DEPTH)                     # 2482
IN_RANGE = [150, 2400, 48000, 10080, 840]      # global address range per layer
EXPECTED_OPS = [4704, 9600, 1920, 420, 40]     # 25-lane operations per layer
MISS = 0xFFFF
SRAM_TOTAL, PCM_TOTAL = 3074, 58396            # pcm_imc_unit parameters in lenet5_top


def read_memh(path, depth):
    """Minimal $readmemh reader: hex words, // comments, @address lines.
    Unloaded words keep the RTL default fill 0xFFFF."""
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


def load_tables(data_dir):
    """tables[side][lane][layer] -> list of 16-bit entries"""
    tables = {}
    for side in ("sram", "pcm"):
        tables[side] = []
        for lane in range(K):
            per_layer = []
            for li, name in enumerate(LAYERS):
                f = os.path.join(data_dir, f"addr_to_slot_{name}_{side}_lane{lane:02d}.hex")
                if not os.path.isfile(f):
                    sys.exit(f"missing table file {f}")
                per_layer.append(read_memh(f, DEPTH[li]))
            tables[side].append(per_layer)
    return tables


def decode(layer, o16, lane):
    """Replica of the index arithmetic in the RTL decoders.
    Returns the per-layer table index, or None when the lane does not look
    anything up (out of range, wrong lane, or beyond the table depth)."""
    if layer > 4:
        return None              # the RTL layer mux returns a miss
    if layer == 0 or layer == 1:
        compact = o16 // 25
        lane_ok = (o16 % 25) == lane
    else:
        in_dim, groups = {2: (400, 16), 3: (120, 5), 4: (84, 4)}[layer]
        oc = o16 // in_dim
        flat = o16 - oc * in_dim
        sb = (flat - lane) // 25 if flat >= lane else 0
        compact = oc * groups + sb
        lane_ok = (flat % 25) == lane
    if not (o16 < IN_RANGE[layer] and lane_ok and compact < DEPTH[layer]):
        return None
    return compact


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--tb-sram-reads", type=int, required=True,
                    help="sram_reads_mac printed by the testbench, for the cross-check")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    M = a.model

    tables = load_tables(a.data)

    ops = []                  # (cycle, layer, [(addr, s, p)]*25)
    done_line = None
    after_done = 0
    with open(a.trace) as fh:
        for line in fh:
            if line.startswith("# done_cycle"):
                done_line = line.split()
                continue
            if line.startswith("#") or not line.strip():
                continue
            if done_line is not None:
                after_done += 1
                continue
            f = line.split()
            cyc, layer = int(f[0]), int(f[1])
            part = tuple(int(x, 16) for x in f[2:6])     # sram base, size, pcm base, size
            lanes = []
            for tok in f[6:]:
                ah, hits = tok.split(":")
                lanes.append((int(ah, 16), int(hits[0]), int(hits[1])))
            if len(lanes) != K:
                sys.exit(f"malformed trace line: {line.strip()[:80]}")
            ops.append((cyc, layer, part, lanes))

    counts = [[0] * TOTAL_ENTRIES for _ in range(K)]
    ops_per_layer = [0] * 5
    valid_per_layer = [0] * 5
    invalid_per_layer = [0] * 5
    rec_sram = rec_pcm = 0
    mism_sram = mism_pcm = 0
    both_or_none_on_valid = 0
    hit_on_invalid = 0
    first_mismatches = []
    op_rows = []
    oor = 0
    partitions = {}

    for cyc, layer, part, lanes in ops:
        if layer > 4:
            sys.exit(f"unexpected layer_id {layer} at cycle {cyc}")
        ops_per_layer[layer] += 1
        partitions.setdefault(layer, set()).add(part)
        sbase, ssize, pbase, psize = part
        nvalid = 0
        for lane, (addr, s, p) in enumerate(lanes):
            rec_sram += s
            rec_pcm += p
            idx = decode(layer, addr, lane)
            if idx is None:
                invalid_per_layer[layer] += 1
                ps = pp = 0
                if s or p:
                    hit_on_invalid += 1
            else:
                nvalid += 1
                valid_per_layer[layer] += 1
                counts[lane][OFFSET[layer] + idx] += 1
                vs = tables["sram"][lane][layer][idx]
                vp = tables["pcm"][lane][layer][idx]
                # the decoders' hit: entry present, inside the partition, inside the pool
                ps = int(vs != MISS and vs < ssize and sbase + vs < SRAM_TOTAL)
                pp = int(vp != MISS and vp < psize and pbase + vp < PCM_TOTAL)
                oor += int(vs != MISS and not ps) + int(vp != MISS and not pp)
                if ps + pp != 1:
                    both_or_none_on_valid += 1
            if ps != s:
                mism_sram += 1
            if pp != p:
                mism_pcm += 1
            if (ps != s or pp != p) and len(first_mismatches) < 10:
                first_mismatches.append((cyc, layer, lane, f"{addr:04x}", s, p, ps, pp))
        op_rows.append((cyc, layer, nvalid))

    # gaps between consecutive operations, per layer
    gaps = {li: [] for li in range(5)}
    for (c0, l0, _x), (c1, l1, _y) in zip(op_rows, op_rows[1:]):
        if l0 == l1:
            gaps[l0].append(c1 - c0)

    valid_total = sum(valid_per_layer)
    n_ops = len(ops)
    reads_16 = 2 * valid_total            # both decoders, one 16-bit read each
    reads_8 = 2 * reads_16                # 8-bit macro: two byte reads per lookup
    entries_read = [sum(1 for c in counts[l] if c) for l in range(K)]

    gates = {
        "G2 every lookup agrees with the RTL hit bits": (mism_sram == 0 and mism_pcm == 0),
        "G3 recorded SRAM hits equal the testbench sram_reads_mac": (rec_sram == a.tb_sram_reads),
        "G4 exactly one side hits on every lookup, none on non-lookups":
            (both_or_none_on_valid == 0 and hit_on_invalid == 0),
        "G5 no operation recorded after done": (after_done == 0),
    }

    L = []
    L.append(f"P2R-E8.2 lookup-trace summary, Model {M}")
    L.append(f"trace : {a.trace}")
    L.append(f"tables: {a.data}")
    L.append("")
    L.append(f"done line in trace       : {' '.join(done_line) if done_line else 'MISSING'}")
    L.append(f"MAC operations recorded  : {n_ops}")
    L.append("")
    L.append("layer   ops   expected   lookups(valid lanes)   lanes without lookup   gap min/median/max (cycles)")
    for li, name in enumerate(LAYERS):
        g = gaps[li]
        gtxt = f"{min(g)}/{statistics.median(g):g}/{max(g)}" if g else "-"
        L.append(f"{name:6s} {ops_per_layer[li]:6d} {EXPECTED_OPS[li]:9d}   {valid_per_layer[li]:20d}   "
                 f"{invalid_per_layer[li]:20d}   {gtxt}")
    L.append(f"total  {n_ops:6d} {sum(EXPECTED_OPS):9d}   {valid_total:20d}   {sum(invalid_per_layer):20d}")
    L.append("")
    L.append(f"lookups per decoder side           : {valid_total}  (the SRAM-side and PCM-side decoder of a lane both look up)")
    L.append(f"ROM reads, 16-bit organisation     : {reads_16}  (2 sides x 1 read per lookup)")
    L.append(f"ROM reads, 8-bit 2-byte burst      : {reads_8}  (2 sides x 2 reads per lookup)")
    L.append(f"analytical figure in the manuscript: 833040")
    L.append("")
    L.append(f"recorded SRAM hits : {rec_sram}   testbench sram_reads_mac: {a.tb_sram_reads}")
    L.append(f"recorded PCM hits  : {rec_pcm}")
    L.append(f"replica mismatches : SRAM {mism_sram}, PCM {mism_pcm}")
    for m in first_mismatches:
        L.append(f"   mismatch cycle={m[0]} layer={m[1]} lane={m[2]} addr={m[3]} rec(s,p)=({m[4]},{m[5]}) pred=({m[6]},{m[7]})")
    L.append(f"lookups with both or no side hitting : {both_or_none_on_valid}")
    L.append(f"hits on lanes without a lookup       : {hit_on_invalid}")
    L.append(f"entries rejected by size or pool range: {oor}")
    L.append(f"operations after done                : {after_done}")
    L.append("")
    L.append("partition base/size per layer seen in the trace (sram base, size, pcm base, size):")
    for li in sorted(partitions):
        vals = "; ".join(" ".join(str(v) for v in p) for p in sorted(partitions[li]))
        L.append(f"   {LAYERS[li]:5s}: {vals}")
    L.append("")
    L.append(f"distinct ROM entries read per lane (of {TOTAL_ENTRIES}): min {min(entries_read)}, max {max(entries_read)}")
    L.append("")
    L.append("GATES")
    for k, v in gates.items():
        L.append(f"  {'PASS' if v else 'FAIL'}  {k}")
    L.append(f"RESULT: {'ALL GATES PASS' if all(gates.values()) else 'GATE FAILURE'}")
    text = "\n".join(L)
    print(text)

    with open(os.path.join(a.out, f"e8_2_summary_{M}.txt"), "w") as fh:
        fh.write(text + "\n")
    with open(os.path.join(a.out, f"e8_2_summary_{M}.json"), "w") as fh:
        json.dump({
            "model": M, "mac_operations": n_ops, "ops_per_layer": ops_per_layer,
            "lookups_per_side": valid_total, "lookups_per_layer": valid_per_layer,
            "lanes_without_lookup_per_layer": invalid_per_layer,
            "rom_reads_16bit": reads_16, "rom_reads_8bit_burst": reads_8,
            "recorded_sram_hits": rec_sram, "recorded_pcm_hits": rec_pcm,
            "tb_sram_reads": a.tb_sram_reads,
            "replica_mismatch_sram": mism_sram, "replica_mismatch_pcm": mism_pcm,
            "gaps_min": {LAYERS[l]: (min(gaps[l]) if gaps[l] else None) for l in range(5)},
            "done_line": " ".join(done_line) if done_line else None,
            "gates": {k: bool(v) for k, v in gates.items()},
        }, fh, indent=2)
    with open(os.path.join(a.out, f"e8_2_entry_counts_{M}.csv"), "w") as fh:
        fh.write("lane,entry,layer,count\n")
        for lane in range(K):
            for li in range(5):
                for i in range(DEPTH[li]):
                    e = OFFSET[li] + i
                    fh.write(f"{lane},{e},{LAYERS[li]},{counts[lane][e]}\n")
    with open(os.path.join(a.out, f"e8_2_ops_{M}.csv"), "w") as fh:
        fh.write("cycle,layer,valid_lanes\n")
        for r in op_rows:
            fh.write(f"{r[0]},{r[1]},{r[2]}\n")

    sys.exit(0 if all(gates.values()) else 2)


if __name__ == "__main__":
    main()
