#!/usr/bin/env python3
"""P2R-E8.6: final per-inference energy, area and figure data of the paper.

No new simulation. The script reads the result files of E8.4f, E8.4e-SRAM,
E8.5g and E8.7 listed in FILES, uses the constants in CONST (each with its
source), checks that it reproduces the published values of those steps, and
writes reports/e8_6/e8_6_summary.json and reports/e8_6/e8_6_summary.txt.

Energy parts (per inference, tt, 25 C, 1.80 V, 10 ns clock):
  A  digital periphery: E8.7 gate-level, all logic except the AMU and the
     conv1 cache
  B  protected-weight storage: SRAM macro reads and static power (E8.4f,
     read counts of E8.5e) plus the conv1 register cache (E8.7)
  C  PCM-CIM array (v6, NeuroSim 22 nm)
  D  address map: ROM macros (E8.5g, corrected for the model error) plus the
     AMU logic (E8.7)

Usage: python3 scripts/e8_6_summary.py [--root DIR] [--out DIR]
"""
import argparse
import json
import os
import re
import sys

FILES = {
    "power_A": "reports/e8_7/A/power.json",
    "power_B": "reports/e8_7/B/power.json",
    "stat_A": "reports/e8_7/A/stat_final.txt",
    "stat_B": "reports/e8_7/B/stat_final.txt",
    "e84f_log": "reports/e8_4f_sram_char.log",
    "e84e_sram": "reports/e8_rom/e8_4e_sram/e8_4e_sram_summary.json",
    "e85g": "reports/e8_rom/e8_5g/e8_5g_drom.json",
}

CONST = {
    "cycles": [617573, "E8.5c, E8.5e: inference cycles, both models"],
    "t_clk_ns": [10.0, "clock period of all simulations"],
    "macs": [416520, "v6 Section V-F; E8.2: weight lookups per lane side and inference"],
    "sram_reads": [{"A": 149543, "B": 88064}, "E8.5e G4: SRAM macro reads per inference"],
    "protected_reads": [{"A": 267143, "B": 205664}, "E8.5c F1: protected-weight lookups per inference"],
    "cache_reads": [117600, "E8.5e G4: conv1 cache reads per inference"],
    "e_array_uJ": [0.263, "v6 Table III: PCM-CIM array, NeuroSim 22 nm"],
    "crossbar_mm2": [[0.68, 2.27], "v6 Section V-D: crossbar with converters, most compact and baseline scheme"],
    "rom_macro_um": [[275.010, 118.340], "E8.4a-7: r48 macro, drawn layout extent"],
    "rom_macro_lef_um": [[260.05, 103.38], "E8.4a-7: r48 macro, LEF"],
    "rom_macros": [200, "50 tables x 4 macros of 48 rows"],
    "rom_bits": [50 * 2496 * 16, "50 tables x 2,496 words x 16 bit"],
    "sram_macro_um": [[477.365, 588.130], "E8.1b (LEF = layout); E8.4f: unchanged with the precharge drawn in"],
    "sram_macro_bits": [32768, "4-KB macro"],
    "act_buffer_mm2": [0.669, "v6 Section V-D (OpenRAM SRAM: LEF = layout, E8.1b)"],
    "bias_table_um": [[190.090, 137.510], "E8.1b: test_rom_1kbyte_abspath, drawn layout extent (v6 0.021 mm2 is its LEF)"],
    "weights": [61470, "v6 Table II"],
    "protected": [3074, "v6 Table II, 5% budget, both models"],
    "copies": [25, "SRAM replicated once per lane (upper bound)"],
    "resnet50_weights": [25502912, "v6 Section VI-C"],
    "bits_per_weight": [8, "v6"],
    "map_bits_per_weight": [32, "one 16-bit entry per weight in each partition (v6 Section VI-C scaling)"],
    "e_analytical_pJ": [11.81819, "clk0 internal_power entry of the OpenRAM timing library, per clock transition (23.64 pJ per read; scripts/sram_lib_energy.py)"],
    "node_scale": [[130.0, 22.0], "v6 Section VI-C: ideal area scaling 130 nm -> 22 nm"],
}

V6 = {
    "A": 22.5, "B": {"A": 3.37, "B": 2.64}, "C": 0.263, "D": 9.85,
    "share_B_AC": {"A": 0.129, "B": 0.104}, "share_BD_AD": {"A": 0.367, "B": 0.354},
    "area_fixed": 5.80, "area_range": [6.76, 15.09],
}

MODELS = ("A", "B")
CHECKS = []


def check(name, ok, detail):
    CHECKS.append({"check": name, "ok": bool(ok), "detail": detail})


def c(key):
    return CONST[key][0]


def read_e84f(path):
    """r10 summary of E8.4f: gated reads and the static power after a read."""
    sums = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("summary: {"):
                sums.append(json.loads(line[len("summary: "):]))
    r10 = sums[0]
    gated = r10["E_read_gated_pJ"]
    system = gated[1:8]          # previous access also a read (k13-k25, 7 reads)
    out = {
        "gated_all_pJ": gated,
        "system_pJ": system,
        "e_read_pJ": sum(system) / len(system),
        "e_read_min_pJ": min(system),
        "e_read_max_pJ": max(system),
        "e_read_all9_pJ": sum(gated) / len(gated),
        "p_static_uW": r10["P_stop_uW"],
        "t_acc_gated_ns_max": r10["t_acc_gated_ns_max"],
    }
    check("E8.4f system read 86.48 pJ (85.38-90.09), all nine 82.80 pJ, static 1.2548 uW",
          abs(out["e_read_pJ"] - 86.48) < 0.005 and abs(out["e_read_min_pJ"] - 85.384) < 1e-6
          and abs(out["e_read_max_pJ"] - 90.0876) < 1e-6 and abs(out["e_read_all9_pJ"] - 82.80) < 0.005
          and out["p_static_uW"] == 1.2548,
          "%.4f (%.4f-%.4f), all nine %.4f pJ, %.4f uW" % (out["e_read_pJ"], out["e_read_min_pJ"],
                                                           out["e_read_max_pJ"], out["e_read_all9_pJ"],
                                                           out["p_static_uW"]))
    return out


def base_name(name):
    if name.startswith("$paramod\\"):
        return name.split("\\")[1]
    if name.startswith("$paramod$"):
        return name.split("\\")[-1]
    return name.lstrip("\\")


def read_stat(path):
    """Areas of the synthesized netlist (E8.7 stage 2) by module."""
    t = open(path, encoding="utf-8").read()
    head, hier = t.split("=== design hierarchy ===")
    defs = {}
    for name, a in re.findall(r"^\s*Chip area for module '(.+)': ([0-9.]+)\s*$", head, re.M):
        defs[name] = float(a)
    top = float(re.search(r"Chip area for top module '\\lenet5_top': ([0-9.]+)", hier).group(1))
    # occurrences of each module in the hierarchy tree (a module used twice appears
    # twice); the tree is the block after the header, up to the first empty line
    occ = {}
    lines = hier.splitlines()
    start = next(i for i, l in enumerate(lines) if "Area including submodules" in l) + 2
    for line in lines[start:]:
        if not line.strip():
            break
        m = re.match(r"^\s+\d+\s+\S+\s+(\S+)\s*$", line)
        if m:
            name = m.group(1) if m.group(1) in defs else "\\" + m.group(1)
            occ[name] = occ.get(name, 0) + 1
    if set(occ) != set(defs):
        sys.exit("hierarchy tree and module list differ in %s" % path)
    total = 0.0
    by_base = {}
    for name, a in defs.items():
        n = occ[name]
        total += n * a
        b = base_name(name)
        by_base[b] = by_base.get(b, 0.0) + n * a
    amu = sum(v for k, v in by_base.items() if k.startswith("amu_"))
    cache = by_base.get("conv1_cache", 0.0)
    out = {
        "top_um2": top, "amu_um2": amu, "cache_um2": cache,
        "rest_um2": top - amu - cache, "by_module_um2": by_base,
        "amu_buf_share": by_base.get("amu_buf", 0.0) / amu,
        "fc_engines_um2": by_base.get("fc_engine", 0.0),
    }
    check("E8.7 %s: module areas x instances = top area" % os.path.basename(os.path.dirname(path)),
          abs(total - top) < 1e-3, "%.3f vs %.3f um2" % (total, top))
    return out


def read_power(path):
    p = json.load(open(path, encoding="utf-8"))
    parts = p["parts_uJ"]
    out = {
        "A_uJ": parts["rest of the logic"], "amu_uJ": parts["address-map unit"],
        "cache_uJ": parts["conv1 cache"], "report_total_uJ": p["energy_uJ"]["Total"],
        "groups_mW": {k: v["total"] * 1e3 for k, v in p["groups_W"].items() if k in ("Sequential", "Combinational", "Clock", "Total")},
        "window_ms": p["duration_ms"],
    }
    s = out["A_uJ"] + out["amu_uJ"] + out["cache_uJ"]
    out["parts_sum_uJ"] = s
    check("E8.7 %s: instance sum within 0.05%% of the report total" % os.path.basename(os.path.dirname(path)),
          abs(s / out["report_total_uJ"] - 1) < 5e-4, "%.4f vs %.4f uJ" % (s, out["report_total_uJ"]))
    return out


def rom_parts(model):
    """D_ROM of E8.5g (main variant) with the model parts corrected per side."""
    mean = model["mean_model_error"]
    se = model["se"]
    v = model["variants"]["main"]
    parts = v["parts_uJ"]
    model_keys = ("read", "park", "above")      # model parts: divided by 1 + mean error
    meas_keys = ("leak", "zero")                 # measured parts: unchanged

    def total(shift):
        s = 0.0
        for side in ("pcm", "sram"):
            k = 1 + mean[side] + shift * se[side]
            s += sum(parts[side][x] for x in model_keys) / k + sum(parts[side][x] for x in meas_keys)
        return s
    corr = {}
    for x in model_keys:
        corr[x] = sum(parts[side][x] / (1 + mean[side]) for side in ("pcm", "sram"))
    for x in meas_keys:
        corr[x] = sum(parts[side][x] for side in ("pcm", "sram"))
    out = {
        "main_uJ": v["D_uJ"], "corrected_uJ": total(0.0), "range_uJ": [total(2.0), total(-2.0)],
        "corrected_parts_uJ": {"lookup reads": corr["read"], "parking reads": corr["park"],
                               "static after lookup reads": corr["above"],
                               "macros at rest on an all-ones word": corr["leak"],
                               "macros parked on words with zero bits": corr["zero"]},
        "published": {"corrected_uJ": v["corrected_uJ"], "range_uJ": v["range_uJ"]},
    }
    ok = (abs(out["corrected_uJ"] - v["corrected_uJ"]) < 1e-9
          and abs(out["range_uJ"][0] - v["range_uJ"][0]) < 1e-9
          and abs(out["range_uJ"][1] - v["range_uJ"][1]) < 1e-9
          and abs(sum(corr.values()) - v["corrected_uJ"]) < 1e-9)
    return out, ok


def energy(models_in, e84f):
    t_ms = c("cycles") * c("t_clk_ns") * 1e-6
    res = {}
    for m in MODELS:
        d = models_in[m]
        n = c("sram_reads")[m]
        reads = n * e84f["e_read_pJ"] * 1e-6
        reads_lo = n * e84f["e_read_min_pJ"] * 1e-6
        reads_hi = n * e84f["e_read_max_pJ"] * 1e-6
        reads_all9 = n * e84f["e_read_all9_pJ"] * 1e-6
        static1 = e84f["p_static_uW"] * t_ms * 1e-3          # uW x ms = nJ -> uJ
        cache = d["power"]["cache_uJ"]
        A = d["power"]["A_uJ"]
        C = c("e_array_uJ")
        amu = d["power"]["amu_uJ"]
        rom = d["rom"]
        B = reads + static1 + cache
        D = rom["corrected_uJ"] + amu
        B_lo, B_hi = reads_lo + static1 + cache, reads_hi + static1 + cache
        D_lo, D_hi = rom["range_uJ"][0] + amu, rom["range_uJ"][1] + amu
        AC = A + B + C
        AD = AC + D

        def shares(b, dd):
            return b / (A + b + C), (b + dd) / (A + b + C + dd)
        s1, s2 = shares(B, D)
        s1_lo, s2_lo = shares(B_lo, D_lo)
        s1_hi, s2_hi = shares(B_hi, D_hi)
        B25 = B + (c("copies") - 1) * static1
        s1_25, s2_25 = shares(B25, D)
        B9 = reads_all9 + static1 + cache
        s1_9, s2_9 = shares(B9, D)
        Bnc = reads + static1            # cache counted in A instead (for reference only)
        s1_nc = Bnc / (A + cache + Bnc + C)
        s2_nc = (Bnc + D) / (A + cache + Bnc + C + D)
        res[m] = {
            "A_uJ": A,
            "B_uJ": B, "B_parts_uJ": {"SRAM reads": reads, "SRAM static (1 macro)": static1, "conv1 cache": cache},
            "B_range_uJ": [B_lo, B_hi], "B_25_macros_uJ": B25, "B_all_nine_reads_uJ": B9,
            "C_uJ": C,
            "D_uJ": D, "D_parts_uJ": dict(rom["corrected_parts_uJ"], **{"AMU logic": amu}),
            "D_range_uJ": [D_lo, D_hi], "D_rom_uJ": rom["corrected_uJ"], "D_rom_main_uJ": rom["main_uJ"],
            "D_rom_range_uJ": rom["range_uJ"], "amu_uJ": amu,
            "total_AC_uJ": AC, "total_AD_uJ": AD,
            "share_B_of_AC": s1, "share_BD_of_AD": s2,
            "share_B_of_AC_range": [s1_lo, s1_hi], "share_BD_of_AD_range": [s2_lo, s2_hi],
            "share_25_macros": [s1_25, s2_25], "share_all_nine_reads": [s1_9, s2_9],
            "share_cache_in_A_reference": [s1_nc, s2_nc],
            "per_mac_pJ": {"A-C": AC / c("macs") * 1e6, "A-D": AD / c("macs") * 1e6,
                           "C": C / c("macs") * 1e6},
            "digital_logic_uJ": d["power"]["report_total_uJ"],
            "digital_groups_mW": d["power"]["groups_mW"],
            "sram_static_window_ms": t_ms,
        }
    return res


def conditions(e84e, e85g, e84f):
    t_ms = c("cycles") * c("t_clk_ns") * 1e-6
    per = e84e["per"]
    ref = per["tt:25"]
    out = {}
    for cond, v in per.items():
        r_read = v["E_sys_pJ"] / ref["E_sys_pJ"]
        r_static = v["P_static_uW"] / ref["P_static_uW"]
        key = cond + ":1.80"
        row = {"r_read": r_read, "r_static": r_static, "read_time_ns": max(
            x["t_acc_gated_ns"] for x in v["reads"] if x["expected"] != 0)}
        for m in MODELS:
            n = c("sram_reads")[m]
            reads = n * e84f["e_read_pJ"] * 1e-6 * r_read
            st = e84f["p_static_uW"] * r_static * t_ms * 1e-3
            if cond == "tt:25":
                drom = e85g["models"][m]["variants"]["main"]["corrected_uJ"]
            else:
                drom = e85g["conditions"][key][m]["corrected_uJ"]
            row[m] = {"sram_1_uJ": reads + st, "sram_25_uJ": reads + c("copies") * st,
                      "sram_reads_uJ": reads, "sram_static_1_uJ": st, "d_rom_uJ": drom}
        out[cond] = row
    tt = out["tt:25"]
    for cond, row in out.items():
        for m in MODELS:
            row[m]["d_rom_x_tt"] = row[m]["d_rom_uJ"] / tt[m]["d_rom_uJ"]
            row[m]["sram_1_x_tt"] = row[m]["sram_1_uJ"] / tt[m]["sram_1_uJ"]
            row[m]["sram_25_x_tt"] = row[m]["sram_25_uJ"] / tt[m]["sram_25_uJ"]
    a = out["tt:25"]["A"]
    check("E8.4e-SRAM: model A at tt 25 C, reads 12.93 uJ, static 0.008 / 0.19 uJ",
          abs(a["sram_reads_uJ"] - 12.93) < 0.005 and abs(a["sram_static_1_uJ"] - 0.0077) < 0.0005
          and abs(25 * a["sram_static_1_uJ"] - 0.19) < 0.005,
          "%.4f, %.5f, %.4f uJ" % (a["sram_reads_uJ"], a["sram_static_1_uJ"], 25 * a["sram_static_1_uJ"]))
    return out


def area(stat):
    rw, rh = c("rom_macro_um")
    lw, lh = c("rom_macro_lef_um")
    sw, sh = c("sram_macro_um")
    bw, bh = c("bias_table_um")
    rom = c("rom_macros") * rw * rh * 1e-6
    rom_lef = c("rom_macros") * lw * lh * 1e-6
    sram1 = sw * sh * 1e-6
    sram_bit_um2 = sw * sh / c("sram_macro_bits")
    rom_bit_um2 = rom * 1e6 / c("rom_bits")
    bias = bw * bh * 1e-6
    xb_lo, xb_hi = c("crossbar_mm2")
    res = {"rom_mm2": rom, "rom_lef_mm2": rom_lef, "sram_macro_mm2": sram1,
           "sram_um2_per_bit": sram_bit_um2, "rom_um2_per_bit": rom_bit_um2,
           "rom_lef_um2_per_bit": rom_lef * 1e6 / c("rom_bits"), "bias_table_mm2": bias,
           "act_buffer_mm2": c("act_buffer_mm2"), "crossbar_mm2": [xb_lo, xb_hi]}
    for m in MODELS:
        s = stat[m]
        dig = s["rest_um2"] * 1e-6
        amu = s["amu_um2"] * 1e-6
        cache = s["cache_um2"] * 1e-6
        amap = rom + amu
        fixed = dig + c("act_buffer_mm2") + amap + bias + cache
        lo = fixed + xb_lo + sram1
        hi = fixed + xb_hi + c("copies") * sram1
        prot_lo = amap + cache + sram1
        prot_hi = amap + cache + c("copies") * sram1
        res[m] = {
            "digital_periphery_mm2": dig, "amu_mm2": amu, "conv1_cache_mm2": cache,
            "address_map_mm2": amap, "synthesis_total_mm2": s["top_um2"] * 1e-6,
            "amu_entry_buffer_share": s["amu_buf_share"], "fc_engines_mm2": s["fc_engines_um2"] * 1e-6,
            "fixed_mm2": fixed, "range_mm2": [lo, hi],
            "protection_mm2": [prot_lo, prot_hi], "protection_share": [prot_lo / lo, prot_hi / hi],
            "other_mm2": [lo - prot_lo, hi - prot_hi],
            "non_crossbar_share": [(lo - xb_lo) / lo, (hi - xb_hi) / hi],
        }
    return res


def fig7(ar):
    a = ar["A"]
    rows = []
    for pct in range(0, 51):
        b = pct / 100.0
        sram = b * c("weights") * c("bits_per_weight") * ar["sram_um2_per_bit"] * 1e-6
        below = a["digital_periphery_mm2"] + ar["act_buffer_mm2"] + ar["bias_table_mm2"] + ar["crossbar_mm2"][1]
        above = a["address_map_mm2"] + a["conv1_cache_mm2"]
        rows.append({"budget_pct": pct, "sram_single_mm2": sram, "sram_replicated_mm2": c("copies") * sram,
                     "total_single_mm2": below + above + sram,
                     "total_replicated_mm2": below + above + c("copies") * sram})
    built = {"budget_pct": 100.0 * c("protected") / c("weights"),
             "sram_single_mm2": ar["sram_macro_mm2"], "sram_replicated_mm2": c("copies") * ar["sram_macro_mm2"]}
    below = a["digital_periphery_mm2"] + ar["act_buffer_mm2"] + ar["bias_table_mm2"] + ar["crossbar_mm2"][1]
    above = a["address_map_mm2"] + a["conv1_cache_mm2"]
    built["total_single_mm2"] = below + above + built["sram_single_mm2"]
    built["total_replicated_mm2"] = below + above + built["sram_replicated_mm2"]
    blocks = {"above the line (exist because weights are protected)": {
                  "address map: ROM macros": ar["rom_mm2"], "address map: AMU logic": a["amu_mm2"],
                  "conv1 register cache": a["conv1_cache_mm2"],
                  "protected-weight SRAM": "per-bit curve; as built 1 macro"},
              "below the line (present anyway)": {
                  "PCM crossbar (baseline converter scheme)": ar["crossbar_mm2"][1],
                  "activation buffer": ar["act_buffer_mm2"], "bias table": ar["bias_table_mm2"],
                  "digital periphery": a["digital_periphery_mm2"]}}
    r50 = rows[50]
    return {"model": "A", "blocks_mm2": blocks, "curve": rows, "as_built": built,
            "map_over_sram_at_50pct": a["address_map_mm2"] / r50["sram_single_mm2"],
            "total_single_0_and_50pct": [rows[0]["total_single_mm2"], r50["total_single_mm2"]],
            "protection_at_5pct_single": [above + ar["sram_macro_mm2"], built["total_single_mm2"]]}


def vic(en, ar):
    w50 = c("resnet50_weights") // 2
    bits50 = w50 * c("bits_per_weight")
    sram50 = bits50 * ar["sram_um2_per_bit"] * 1e-6
    sram5 = c("resnet50_weights") * 0.05 * c("bits_per_weight") * ar["sram_um2_per_bit"] * 1e-6
    a, b = c("node_scale")
    map_bits = c("resnet50_weights") * c("map_bits_per_weight")
    e50 = w50 * en["A"]["B_parts_uJ"]["SRAM reads"] / c("sram_reads")["A"]   # per-read energy x count
    return {
        "protected_weights_50pct": w50, "sram_bits_50pct": bits50, "sram_mm2_50pct": sram50,
        "sram_mm2_50pct_22nm": sram50 * (b / a) ** 2, "sram_mm2_5pct": sram5,
        "sram_over_lenet_upper": sram50 / ar["A"]["range_mm2"][1],
        "map_bits": map_bits, "map_mm2": map_bits * ar["rom_um2_per_bit"] * 1e-6,
        "map_mm2_lef_basis": map_bits * ar["rom_lef_um2_per_bit"] * 1e-6,
        "sram_energy_floor_uJ": e50,
        "floor_over_lenet_AD": e50 / en["A"]["total_AD_uJ"], "floor_over_lenet_AC": e50 / en["A"]["total_AC_uJ"],
    }


def v6_check():
    for m in MODELS:
        A, B, C, D = V6["A"], V6["B"][m], V6["C"], V6["D"]
        s1 = B / (A + B + C)
        s2 = (B + D) / (A + B + C + D)
        check("formulas reproduce v6 model %s (%.1f %%, %.1f %%)" % (m, 100 * V6["share_B_AC"][m], 100 * V6["share_BD_AD"][m]),
              round(s1, 3) == V6["share_B_AC"][m] and round(s2, 3) == V6["share_BD_AD"][m],
              "%.4f, %.4f" % (s1, s2))


def fmt_report(out):
    L = []
    en, ar = out["energy"], out["area"]
    L.append("P2R-E8.6 summary (tt, 25 C, 1.80 V, 10 ns clock; uJ per inference)")
    L.append("")
    L.append("%-44s %12s %12s" % ("part", "model A", "model B"))
    rows = [("A digital periphery", "A_uJ"), ("B protected-weight storage", "B_uJ"),
            ("C PCM-CIM array", "C_uJ"), ("D address map", "D_uJ"),
            ("A-C", "total_AC_uJ"), ("A-D", "total_AD_uJ")]
    for lab, k in rows:
        L.append("%-44s %12.3f %12.3f" % (lab, en["A"][k], en["B"][k]))
    for lab in ("SRAM reads", "SRAM static (1 macro)", "conv1 cache"):
        L.append("%-44s %12.4f %12.4f" % ("  B: " + lab, en["A"]["B_parts_uJ"][lab], en["B"]["B_parts_uJ"][lab]))
    for lab in en["A"]["D_parts_uJ"]:
        L.append("%-44s %12.4f %12.4f" % ("  D: " + lab, en["A"]["D_parts_uJ"][lab], en["B"]["D_parts_uJ"][lab]))
    L.append("%-44s %12s %12s" % ("B range", "%.3f-%.3f" % tuple(en["A"]["B_range_uJ"]), "%.3f-%.3f" % tuple(en["B"]["B_range_uJ"])))
    L.append("%-44s %12s %12s" % ("D range", "%.3f-%.3f" % tuple(en["A"]["D_range_uJ"]), "%.3f-%.3f" % tuple(en["B"]["D_range_uJ"])))
    for lab, k in (("B / (A-C)", "share_B_of_AC"), ("(B+D) / (A-D)", "share_BD_of_AD")):
        L.append("%-44s %12.2f %12.2f" % (lab + " %", 100 * en["A"][k], 100 * en["B"][k]))
        L.append("%-44s %12s %12s" % ("  range %", "%.2f-%.2f" % tuple(100 * x for x in en["A"][k + "_range"]),
                                      "%.2f-%.2f" % tuple(100 * x for x in en["B"][k + "_range"])))
    L.append("%-44s %12s %12s" % ("shares with 25 SRAM macros %", "%.2f / %.2f" % tuple(100 * x for x in en["A"]["share_25_macros"]),
                                  "%.2f / %.2f" % tuple(100 * x for x in en["B"]["share_25_macros"])))
    L.append("%-44s %12s %12s" % ("per MAC A-C / A-D pJ", "%.1f / %.1f" % (en["A"]["per_mac_pJ"]["A-C"], en["A"]["per_mac_pJ"]["A-D"]),
                                  "%.1f / %.1f" % (en["B"]["per_mac_pJ"]["A-C"], en["B"]["per_mac_pJ"]["A-D"])))
    L.append("")
    L.append("Area (mm2, layout extent for memories, synthesis for logic)")
    for lab, k in (("digital periphery", "digital_periphery_mm2"), ("AMU", "amu_mm2"), ("conv1 cache", "conv1_cache_mm2"),
                   ("address map (ROM + AMU)", "address_map_mm2"), ("fixed blocks", "fixed_mm2")):
        L.append("%-44s %12.4f %12.4f" % (lab, ar["A"][k], ar["B"][k]))
    L.append("%-44s %12s %12s" % ("range (compact + 1 SRAM, baseline + 25)", "%.3f-%.3f" % tuple(ar["A"]["range_mm2"]), "%.3f-%.3f" % tuple(ar["B"]["range_mm2"])))
    L.append("%-44s %12s %12s" % ("protection share %", "%.1f / %.1f" % tuple(100 * x for x in ar["A"]["protection_share"]),
                                  "%.1f / %.1f" % tuple(100 * x for x in ar["B"]["protection_share"])))
    L.append("")
    L.append("Checks")
    for ch in out["checks"]:
        L.append("  %s  %s: %s" % ("PASS" if ch["ok"] else "FAIL", ch["check"], ch["detail"]))
    L.append("  " + ("ALL PASS" if all(ch["ok"] for ch in out["checks"]) else "NOT ALL PASS"))
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=".")
    ap.add_argument("--out", default="reports/e8_6")
    a = ap.parse_args()
    P = {k: os.path.join(a.root, v) for k, v in FILES.items()}
    for k, p in P.items():
        if not os.path.isfile(p):
            sys.exit("missing input %s: %s" % (k, p))
    e84f = read_e84f(P["e84f_log"])
    e84e = json.load(open(P["e84e_sram"], encoding="utf-8"))
    e85g = json.load(open(P["e85g"], encoding="utf-8"))
    stat = {m: read_stat(P["stat_" + m]) for m in MODELS}
    models_in = {}
    for m in MODELS:
        rom, ok = rom_parts(e85g["models"][m])
        check("E8.5g model %s: corrected D_ROM and range reproduced from the parts" % m, ok,
              "%.4f (%.4f-%.4f) uJ" % (rom["corrected_uJ"], rom["range_uJ"][0], rom["range_uJ"][1]))
        models_in[m] = {"power": read_power(P["power_" + m]), "rom": rom}
    v6_check()
    en = energy(models_in, e84f)
    ar = area(stat)
    out = {
        "inputs": {k: {"path": FILES[k]} for k in FILES},
        "constants": CONST,
        "e84f": e84f,
        "energy": en,
        "conditions": conditions(e84e, e85g, e84f),
        "area": ar,
        "fig7": fig7(ar),
        "fig8": {m: {"A digital periphery": en[m]["A_uJ"], "B": en[m]["B_parts_uJ"], "C PCM-CIM array": en[m]["C_uJ"],
                     "D": en[m]["D_parts_uJ"], "B range": en[m]["B_range_uJ"], "D range": en[m]["D_range_uJ"]}
                 for m in MODELS},
        "vi_c": vic(en, ar),
        "checks": CHECKS,
    }
    import hashlib
    for k in FILES:
        out["inputs"][k]["md5"] = hashlib.md5(open(P[k], "rb").read()).hexdigest()
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "e8_6_summary.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1)
    rep = fmt_report(out)
    with open(os.path.join(a.out, "e8_6_summary.txt"), "w", encoding="utf-8") as f:
        f.write(rep)
    sys.stdout.write(rep)
    return 0 if all(ch["ok"] for ch in CHECKS) else 1


if __name__ == "__main__":
    sys.exit(main())
