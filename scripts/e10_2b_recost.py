#!/usr/bin/env python3
"""P2R-E10.2b: energy and area per inference with the protected-weight SRAM realised as 25 single-port
banks (E10) and without the conv1 register cache, for the TVLSI manuscript (Table II, Figs. 6 and 7,
Sections V-D to VI-C).

What changes against reports/e8_6/e8_6_summary.json (E8.6):
  B, the protected-weight storage, is now
    bank reads   = SRAM reads per inference x energy of a system read of the bank (E10.1, variant S)
    bank static  = 25 banks x static power after a read (E10.1, S) x inference time
    pool logic   = gate-level energy of the banked pool with clock gating (cg) in the unit without the cache
                   (E10.2c, conce: one read per operation, the reads counted above)
  The SRAM reads are the protected-weight lookups of E8.5c (no cache): 267,143 / 205,664 for Models A / B,
  equal to the bank reads of E10.2c. The conv1 cache (4.628 / 4.578 uJ in E8.6's B, 0.048 mm2) is removed;
  all of its logic is in the module U_C1CACHE, so A (digital periphery), C and D are those of E8.6.
  Area: the SRAM is 25 banks (drawn layout extent of the S bank) plus the pool logic (synthesis, E10.2a).
Everything else (A, C, D and their ranges, the other blocks' areas, D_ROM at the other conditions, the
ResNet-50 scaling) is taken from the E8.6 summary unchanged.

Inputs (paths relative to --paper2; md5 of each recorded in the output):
  reports/e8_6/e8_6_summary.json
  reports/e10/e10_1s/e10_1_summary.json           bank S at tt, 25 C, 1.80 V (read energy, static, extent)
  reports/e10/e10_1f/e10_1_summary.json           bank F (the bank as generated), for the library comparison
  reports/e10/e10_1f/libgen_l689/*.lib, libgen_ldef/*.lib   timing libraries of the bank (netlist only)
  reports/e10/e10_1c_s/e10_1c_summary.json        bank S at the six conditions
  reports/e10/e10_2a/e10_2a_summary.json          pool logic in the unit with the cache (ng and cg)
  reports/e10/e10_2a/rtl_cg/bankpool_cg_stat_final.txt     area of the pool logic (cg)
  reports/e10/e10_2c/e10_2c_summary.json          pool logic in the unit without the cache (cg)
  reports/e10_0_banked_sram.log                   E10.0: T0 (slot interleaving) and U1

Usage: python3 scripts/e10_2b_recost.py --paper2 . --out reports/e10/e10_2b
"""
import argparse
import glob
import hashlib
import json
import math
import os
import re

MODELS = ("A", "B")
BANKS = 25
BANK_WORDS = 128


def md5(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()


def lib_clock_read_pJ(path):
    """energy of one read in a timing library: rise + fall internal power of clk0 when the macro reads
    (csb0 low, web0 high), and the leakage (uW)"""
    t = open(path, errors="replace").read()
    k = t.index("pin(clk0)")
    blk = t[k:k + 4000]
    m = re.search(r'when\s*:\s*"!csb0 & web0";\s*rise_power\(scalar\)\{\s*values\("([^"]+)"\);\s*\}\s*'
                  r'fall_power\(scalar\)\{\s*values\("([^"]+)"\);', blk)
    leak = re.search(r"^\s*cell_leakage_power\s*:\s*([\d.eE+-]+)\s*;", t, re.M)   # not default_cell_leakage_power
    unit = re.search(r'leakage_power_unit\s*:\s*"1mW"', t)
    if not (m and leak and unit):
        raise SystemExit(f"cannot read the clock-pin internal power or the leakage of {path}")
    return float(m.group(1)) + float(m.group(2)), float(leak.group(1)) * 1e3


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--paper2", default=".")
    ap.add_argument("--out", default="reports/e10/e10_2b")
    a = ap.parse_args()
    P = lambda *x: os.path.join(a.paper2, *x)  # noqa: E731
    f_e86 = P("reports", "e8_6", "e8_6_summary.json")
    f_s = P("reports", "e10", "e10_1s", "e10_1_summary.json")
    f_f = P("reports", "e10", "e10_1f", "e10_1_summary.json")
    f_l689 = glob.glob(P("reports", "e10", "e10_1f", "libgen_l689", "*.lib"))
    f_ldef = glob.glob(P("reports", "e10", "e10_1f", "libgen_ldef", "*.lib"))
    f_cs = P("reports", "e10", "e10_1c_s", "e10_1c_summary.json")
    f_2a = P("reports", "e10", "e10_2a", "e10_2a_summary.json")
    f_stat = P("reports", "e10", "e10_2a", "rtl_cg", "bankpool_cg_stat_final.txt")
    f_2c = P("reports", "e10", "e10_2c", "e10_2c_summary.json")
    f_e100 = P("reports", "e10_0_banked_sram.log")
    if len(f_l689) != 1 or len(f_ldef) != 1:
        raise SystemExit("expected one .lib in each of reports/e10/e10_1f/libgen_l689 and libgen_ldef")
    inputs = [f_e86, f_s, f_f, f_l689[0], f_ldef[0], f_cs, f_2a, f_stat, f_2c, f_e100]
    out = {"inputs": {os.path.relpath(p, a.paper2): md5(p) for p in inputs}}
    e86 = json.load(open(f_e86))
    bs = json.load(open(f_s))
    bf = json.load(open(f_f))
    cs = json.load(open(f_cs))
    s2a = json.load(open(f_2a))
    s2c = json.load(open(f_2c))
    con = e86["constants"]
    cycles, tclk = con["cycles"][0], con["t_clk_ns"][0]
    t_inf_ms = cycles * tclk * 1e-6                       # 6.17573 ms, the window of the static energy in E8.6
    reads = {m: con["protected_reads"][0][m] for m in MODELS}
    macs = con["macs"][0]
    checks = []

    def check(name, ok, detail):
        checks.append({"check": name, "ok": bool(ok), "detail": detail})

    # ---- the bank (E10.1, S) ------------------------------------------------------------------------
    rd = bs["system_read_pJ"]["r10"]
    e_rd, e_rd_lo, e_rd_hi = rd["mean"], rd["min"], rd["max"]
    p_st = bs["summary"]["r10"]["P_stop_uW"]
    w_s, h_s = (float(x) for x in str(bs["lef_size_um"]).split())   # E10.1: the drawn extent equals the LEF
    w_f, h_f = (float(x) for x in str(bf["lef_size_um"]).split())
    bank_um2 = w_s * h_s
    lib689_pJ, lib_leak_uW = lib_clock_read_pJ(f_l689[0])
    libdef_pJ, _ = lib_clock_read_pJ(f_ldef[0])
    e_rd_f = bf["system_read_pJ"]["r10"]["mean"]
    bank = {"variant": bs["variant"], "words": BANK_WORDS, "bits": 8, "banks": BANKS,
            "extent_um": [w_s, h_s], "area_um2": bank_um2, "banks_mm2": BANKS * bank_um2 * 1e-6,
            "extent_F_um": [w_f, h_f], "height_increase_over_F": h_s / h_f - 1,
            "system_read_pJ": e_rd, "system_read_range_pJ": [e_rd_lo, e_rd_hi], "system_read_n": rd["n"],
            "static_after_read_uW": p_st, "t_acc_ns_tt": bs["summary"]["r10"]["t_acc_gated_ns_max"],
            "F_system_read_pJ": e_rd_f, "F_static_after_read_uW": bf["summary"]["r10"]["P_stop_uW"],
            "library_read_pJ_6p89fF": lib689_pJ, "library_read_pJ_default_loads": libdef_pJ,
            "library_leakage_uW": lib_leak_uW,
            "F_over_library_6p89fF": e_rd_f / lib689_pJ, "F_over_library_default": e_rd_f / libdef_pJ,
            "library_leakage_over_F_static": lib_leak_uW / bf["summary"]["r10"]["P_stop_uW"],
            "read_over_4KB_macro": e86["e84f"]["e_read_pJ"] / e_rd}
    for g in ("G0", "G1", "G1b", "G2", "G3"):
        check(f"E10.1 bank S gate {g}", bs.get(g) == "PASS", str(bs.get(g)))
    check("E10.1 bank S: all reads correct (F1 0 wrong bits, F2b gated reads within two cycles)",
          bs.get("F1_wrong_bits") == 0 and bs.get("F2b_gated_reads_ok_within_two_cycles") == "yes",
          f"F1 {bs.get('F1_wrong_bits')}, F2b {bs.get('F2b_gated_reads_ok_within_two_cycles')}")
    check("E10.1 bank S carries the sense-amplifier precharge in the layout", bs.get("layout_sense_precharge") is True,
          str(bs.get("layout_sense_precharge")))

    # ---- interleaving (E10.0 T0, U1) ----------------------------------------------------------------
    t = open(f_e100, errors="replace").read()
    t0 = re.findall(r"model ([AB]): (\d+) protected weights, (\d+) entries with protected weights; entries with "
                    r"non-consecutive slots (\d+)\s+25 banks: steps with two reads in one bank (\d+), deepest row (\d+)", t)
    u1 = re.search(r"U1: cycles (\d+), lane hits in range (\d+), output mismatches (\d+)", t)
    inter = {m: {"protected": int(p), "entries_with_protected": int(e), "non_consecutive": int(nc),
                 "steps_with_two_reads_in_a_bank": int(c2), "deepest_row": int(dr)} for m, p, e, nc, c2, dr in t0}
    inter["U1"] = {"cycles": int(u1.group(1)), "lane_reads": int(u1.group(2)), "mismatches": int(u1.group(3))} if u1 else None
    inter["bank_rule"] = "bank = slot mod 25, row = floor(slot / 25)"
    check("E10.0 T0: slots consecutive, no two reads of a step in one bank, rows < 128, both models",
          set(inter) >= {"A", "B"} and all(inter[m]["non_consecutive"] == 0 and inter[m]["steps_with_two_reads_in_a_bank"] == 0
                                           and inter[m]["deepest_row"] < BANK_WORDS for m in MODELS),
          json.dumps({m: inter.get(m) for m in MODELS}))
    check("E10.0 U1: banked pool = 25-port pool cycle for cycle", bool(u1) and inter["U1"]["mismatches"] == 0,
          json.dumps(inter["U1"]))

    # ---- pool logic (E10.2a area, E10.2c energy) -------------------------------------------------------
    area_m = re.findall(r"Chip area for module '\\?sram_pool_25bank_2c': ([\d.]+)", open(f_stat).read())
    pool_um2 = float(area_m[-1])
    check("E10.2c all gates pass", s2c.get("all_pass") is True, str(s2c.get("all_pass")))
    check("E10.2a all gates pass", s2a.get("all_pass") is True, str(s2a.get("all_pass")))
    check("E10.2c netlist = E10.2a cg netlist", s2c["design"]["netlist_md5"] == s2a["design"]["cg"]["netlist_md5"],
          f"{s2c['design']['netlist_md5']} / {s2a['design']['cg']['netlist_md5']}")
    pool = {m: s2c["paper"][m]["pool_logic_uJ"] for m in MODELS}
    for m in MODELS:
        check(f"E10.2c model {m}: bank reads = SRAM reads of E8.5c ({reads[m]})",
              s2c["paper"][m]["lane_reads"] == reads[m], f"{s2c['paper'][m]['lane_reads']}")

    # ---- energy, tt 25 C --------------------------------------------------------------------------------
    st_uJ = BANKS * p_st * t_inf_ms * 1e-3                 # uW x ms = nJ -> uJ
    energy = {}
    for m in MODELS:
        o = e86["energy"][m]
        b_rd = reads[m] * e_rd * 1e-6
        b = b_rd + st_uJ + pool[m]
        b_lo = reads[m] * e_rd_lo * 1e-6 + st_uJ + pool[m]
        b_hi = reads[m] * e_rd_hi * 1e-6 + st_uJ + pool[m]
        A, C, D = o["A_uJ"], o["C_uJ"], o["D_uJ"]
        d_lo, d_hi = o["D_range_uJ"]
        ac, ad = A + b + C, A + b + C + D
        e = {"A_uJ": A, "B_uJ": b,
             "B_parts_uJ": {"SRAM bank reads": b_rd, "SRAM bank static (25 banks)": st_uJ, "pool logic (gate level)": pool[m]},
             "B_range_uJ": [b_lo, b_hi], "C_uJ": C, "D_uJ": D, "D_parts_uJ": o["D_parts_uJ"], "D_range_uJ": [d_lo, d_hi],
             "D_rom_uJ": o["D_rom_uJ"], "D_rom_range_uJ": o["D_rom_range_uJ"], "amu_uJ": o["amu_uJ"],
             "total_AC_uJ": ac, "total_AD_uJ": ad, "share_B_of_AC": b / ac, "share_BD_of_AD": (b + D) / ad,
             "share_B_of_AC_range": [b_lo / (A + b_lo + C), b_hi / (A + b_hi + C)],
             "share_BD_of_AD_range": [(b_lo + d_lo) / (A + b_lo + C + d_lo), (b_hi + d_hi) / (A + b_hi + C + d_hi)],
             "per_mac_pJ": {"A-C": ac / macs * 1e6, "A-D": ad / macs * 1e6, "C": C / macs * 1e6},
             "reads": reads[m],
             "logic_uJ": {"digital periphery (E8.7)": A, "pool logic (E10.2c)": pool[m], "AMU (E8.7)": o["amu_uJ"]}}
        # the configurations this replaces: E8.6 (one 4-KB macro with the cache) and E10 with the cache (E10.2a)
        cache = o["B_parts_uJ"]["conv1 cache"]
        reads_c = con["sram_reads"][0][m]
        b_kept = reads_c * e_rd * 1e-6 + st_uJ + s2a["paper"][m]["cg_conce"] + cache
        e["compare"] = {"E8.6_B_uJ": o["B_uJ"], "E8.6_total_AD_uJ": o["total_AD_uJ"],
                        "E8.6_share_B_of_AC": o["share_B_of_AC"], "E8.6_share_BD_of_AD": o["share_BD_of_AD"],
                        "E8.6_per_mac_AD_pJ": o["per_mac_pJ"]["A-D"], "E8.6_per_mac_AC_pJ": o["per_mac_pJ"]["A-C"],
                        "banks_with_cache_B_uJ": b_kept, "banks_with_cache_total_AD_uJ": A + b_kept + C + D,
                        "saving_by_removing_the_cache_uJ": b_kept - b, "conv1_cache_uJ": cache,
                        "conv1_reads_in_banks_uJ": con["cache_reads"][0] * e_rd * 1e-6,
                        "conv1_reads_in_pool_logic_uJ": pool[m] - s2a["paper"][m]["cg_conce"],
                        "conv1_cache_saved_with_4KB_macro_uJ": con["cache_reads"][0] * e86["e84f"]["e_read_pJ"] * 1e-6,
                        "pool_logic_ungated_with_cache_uJ": s2a["paper"][m]["ng_conce"],
                        "pool_logic_gated_with_cache_uJ": s2a["paper"][m]["cg_conce"]}
        energy[m] = e
        check(f"model {m}: B parts sum to B", abs(sum(e["B_parts_uJ"].values()) - b) < 1e-9, f"{b:.6f}")
        check(f"model {m}: A-D = A + B + C + D", abs(ad - (A + b + C + D)) < 1e-9, f"{ad:.6f}")
    out["bank"] = bank
    out["interleaving"] = inter
    out["pool_logic"] = {"area_um2": pool_um2, "area_mm2": pool_um2 * 1e-6,
                         "energy_uJ": pool, "energy_by_class_uJ": {m: s2c["runs"][f"conce:{m}"]["info"]["energy_by_class_uJ"]
                                                                   for m in MODELS},
                         "clock_root_net_not_included_uJ": s2c["runs"]["conce:A"]["info"]["clock_root_net"]["E_uJ_not_included"],
                         "flip_flops": s2c["design"]["flip_flops"], "clock_gates": s2c["design"]["clock_gates"]}
    out["energy"] = energy
    out["constants"] = {"inference_ms": t_inf_ms, "macs": macs, "reads": reads, "banks": BANKS}

    # ---- other conditions (bank only; the logic is characterised at tt, 25 C) ---------------------------
    conds = {}
    for c, v in cs["per"].items():
        r = {"r_read": v["r_read"], "r_static": v["r_static"], "static_settled": v["static_settled"],
             "read_time_ns": v["t_acc_gated_ns_max"], "reads_ok": v["reads_ok_after_stop"], "valid": v["valid"]}
        for m in MODELS:
            rr = reads[m] * e_rd * v["r_read"] * 1e-6
            ss = st_uJ * v["r_static"]
            r[m] = {"bank_reads_uJ": rr, "bank_static_uJ": ss, "banks_uJ": rr + ss,
                    "banks_x_tt": (rr + ss) / (reads[m] * e_rd * 1e-6 + st_uJ),
                    "d_rom_uJ": e86["conditions"][c][m]["d_rom_uJ"] if c in e86["conditions"] else None}
        conds[c] = r
    out["conditions"] = conds
    check("E10.1c S: all six conditions read correctly (5/5)", all(v["valid"] and v["reads_ok"] == 5 for v in conds.values()),
          ", ".join(f"{c} {v['reads_ok']}/5" for c, v in conds.items()))

    # ---- area ---------------------------------------------------------------------------------------------
    ar = e86["area"]
    area = {"banks_mm2": bank["banks_mm2"], "pool_logic_mm2": pool_um2 * 1e-6,
            "sram_mm2": bank["banks_mm2"] + pool_um2 * 1e-6,
            "rom_mm2": ar["rom_mm2"], "bias_table_mm2": ar["bias_table_mm2"], "act_buffer_mm2": ar["act_buffer_mm2"],
            "crossbar_mm2": ar["crossbar_mm2"], "sram_4KB_macro_mm2": ar["sram_macro_mm2"],
            "sram_4KB_25_copies_mm2": BANKS * ar["sram_macro_mm2"], "removed_conv1_cache_mm2": ar["A"]["conv1_cache_mm2"]}
    for m in MODELS:
        x = ar[m]
        fixed = x["digital_periphery_mm2"] + ar["act_buffer_mm2"] + ar["bias_table_mm2"] + x["address_map_mm2"]
        rng = [fixed + area["sram_mm2"] + xb for xb in ar["crossbar_mm2"]]
        prot = x["address_map_mm2"] + area["sram_mm2"]
        area[m] = {"digital_periphery_mm2": x["digital_periphery_mm2"], "amu_mm2": x["amu_mm2"],
                   "address_map_mm2": x["address_map_mm2"], "fixed_mm2": fixed, "range_mm2": rng,
                   "protection_mm2": prot, "protection_share": [prot / v for v in rng],
                   "map_over_sram": x["address_map_mm2"] / area["sram_mm2"],
                   "E8.6_range_mm2": x["range_mm2"], "E8.6_protection_mm2": x["protection_mm2"]}
    out["area"] = area

    # ---- Fig. 7: area against the budget (Model A) -----------------------------------------------------------
    # banks: 25 banks of ceil(n / 25) words, each modelled linearly in its words between the two laid-out
    # SRAM macros of this compiler, the 128-word bank (S) and the 4,096-word macro (E8.6); plus the pool logic.
    # One copy and 25 copies: the per-bit model of E8.6 (the 4-KB macro's area per bit).
    w_big = con["sram_macro_bits"][0] // 8
    slope = (ar["sram_macro_mm2"] * 1e6 - bank_um2) / (w_big - BANK_WORDS)        # um2 per word
    a0 = bank_um2 - slope * BANK_WORDS                                               # um2 per bank at zero words
    per_bit = ar["sram_um2_per_bit"]
    xa = ar["A"]
    fixed_a = area["A"]["fixed_mm2"]
    curve = []
    for p in range(0, 51):
        n = con["weights"][0] * p / 100.0
        if n > 0:
            wds = math.ceil(n / BANKS)
            banks_mm2 = BANKS * (a0 + slope * wds) * 1e-6
            sram_b = banks_mm2 + pool_um2 * 1e-6
        else:
            wds, banks_mm2, sram_b = 0, 0.0, 0.0
        single = n * 8 * per_bit * 1e-6
        curve.append({"budget_pct": p, "words_per_bank": wds, "sram_banked_mm2": sram_b, "sram_single_mm2": single,
                      "sram_replicated_mm2": BANKS * single,
                      "total_banked_baseline_mm2": fixed_a + ar["crossbar_mm2"][1] + sram_b,
                      "total_banked_compact_mm2": fixed_a + ar["crossbar_mm2"][0] + sram_b})
    budget_built = 100.0 * con["protected"][0] / con["weights"][0]
    out["fig7"] = {"model": "A", "bank_model": {"um2_per_word": slope, "um2_per_bank_at_zero_words": a0,
                                                 "from": "128-word bank (S) and 4,096-word macro, drawn extents"},
                   "blocks_mm2": {"digital_periphery": xa["digital_periphery_mm2"],
                                  "act_buffer_and_bias": ar["act_buffer_mm2"] + ar["bias_table_mm2"],
                                  "crossbar_baseline": ar["crossbar_mm2"][1], "address_map": xa["address_map_mm2"]},
                   "curve": curve,
                   "as_built": {"budget_pct": budget_built, "sram_banked_mm2": area["sram_mm2"],
                                "sram_single_mm2": ar["sram_macro_mm2"], "sram_replicated_mm2": BANKS * ar["sram_macro_mm2"],
                                "total_baseline_mm2": area["A"]["range_mm2"][1], "total_compact_mm2": area["A"]["range_mm2"][0]}}
    check("bank model reproduces the 4,096-word macro", abs((a0 + slope * w_big) * 1e-6 - ar["sram_macro_mm2"]) < 1e-9,
          f"{(a0 + slope * w_big) * 1e-6:.6f} mm2")
    check("bank model at 128 words = the bank", abs(a0 + slope * BANK_WORDS - bank_um2) < 1e-6, f"{bank_um2:.3f} um2")

    # ---- Section VI-A: the memories charged by their timing libraries -----------------------------------------
    lib_leak_4kb = 34.375                                    # uW, the 4-KB macro's library (E8.6 fig6 script)
    out["vi_a"] = {m: {"banks_by_library_uJ": reads[m] * lib689_pJ * 1e-6 + BANKS * lib_leak_uW * t_inf_ms * 1e-3,
                       "banks_post_layout_uJ": reads[m] * e_rd * 1e-6 + st_uJ,
                       "macro_4KB_by_library_with_cache_uJ": con["sram_reads"][0][m] * 2 * con["e_analytical_pJ"][0] * 1e-6
                       + lib_leak_4kb * t_inf_ms * 1e-3}
                   for m in MODELS}

    # ---- Section VI-C: scaling (E8.6), against the new LeNet-5 total ---------------------------------------------
    vc = dict(e86["vi_c"])
    vc["floor_over_lenet_AD_E10"] = vc["sram_energy_floor_uJ"] / energy["A"]["total_AD_uJ"]
    out["vi_c"] = vc
    out["checks"] = checks
    out["all_checks_pass"] = all(c["ok"] for c in checks)

    os.makedirs(a.out, exist_ok=True)
    json.dump(out, open(os.path.join(a.out, "e10_2b_summary.json"), "w"), indent=1)
    L = ["P2R-E10.2b: energy and area with the banked SRAM, without the conv1 cache (scripts/e10_2b_recost.py)", ""]
    for k, v in out["inputs"].items():
        L.append(f"   input {v}  {k}")
    L += ["", f"bank S: {w_s} x {h_s} um = {bank_um2:.1f} um2 (+{100 * bank['height_increase_over_F']:.2f} % height over F), "
          f"25 banks {bank['banks_mm2']:.4f} mm2; read {e_rd:.3f} pJ ({e_rd_lo:.3f}-{e_rd_hi:.3f}, {rd['n']} reads), "
          f"{bank['read_over_4KB_macro']:.2f} x less than the 4-KB macro; static after a read {p_st:.4f} uW; data {bank['t_acc_ns_tt']:.2f} ns",
          f"library of the bank as generated (F): {lib689_pJ:.3f} pJ per read (6.89 fF), {libdef_pJ:.3f} pJ (default loads), "
          f"leakage {lib_leak_uW:.3f} uW; F reads {e_rd_f:.3f} pJ = {bank['F_over_library_6p89fF']:.2f} x and "
          f"{bank['F_over_library_default']:.2f} x the library; library leakage {bank['library_leakage_over_F_static']:.1f} x F's static",
          f"interleaving: {inter['bank_rule']}; A {json.dumps(inter.get('A'))}; B {json.dumps(inter.get('B'))}; U1 {json.dumps(inter['U1'])}",
          f"pool logic: {pool_um2:.2f} um2; {pool['A']:.4f} / {pool['B']:.4f} uJ (cg, conce, no cache); "
          f"root clock net not included {out['pool_logic']['clock_root_net_not_included_uJ']:.4f} uJ", ""]
    for m in MODELS:
        e = energy[m]
        cp = e["compare"]
        L.append(f"model {m}: A {e['A_uJ']:.3f}  B {e['B_uJ']:.3f} ({e['B_range_uJ'][0]:.3f}-{e['B_range_uJ'][1]:.3f}: "
                 + ", ".join(f"{k} {x:.4f}" for k, x in e["B_parts_uJ"].items()) + f")  C {e['C_uJ']:.3f}  D {e['D_uJ']:.3f}")
        L.append(f"   A-C {e['total_AC_uJ']:.3f}, A-D {e['total_AD_uJ']:.3f} uJ; B/(A-C) {100 * e['share_B_of_AC']:.2f} % "
                 f"({100 * e['share_B_of_AC_range'][0]:.2f}-{100 * e['share_B_of_AC_range'][1]:.2f}); (B+D)/(A-D) "
                 f"{100 * e['share_BD_of_AD']:.2f} % ({100 * e['share_BD_of_AD_range'][0]:.2f}-{100 * e['share_BD_of_AD_range'][1]:.2f}); "
                 f"per MAC A-D {e['per_mac_pJ']['A-D']:.2f} pJ, A-C {e['per_mac_pJ']['A-C']:.2f} pJ")
        L.append(f"   E8.6: B {cp['E8.6_B_uJ']:.3f}, A-D {cp['E8.6_total_AD_uJ']:.3f}; banks with the cache: B "
                 f"{cp['banks_with_cache_B_uJ']:.3f}, A-D {cp['banks_with_cache_total_AD_uJ']:.3f}; removing the cache saves "
                 f"{cp['saving_by_removing_the_cache_uJ']:.3f} uJ (cache {cp['conv1_cache_uJ']:.3f}; its reads cost "
                 f"{cp['conv1_reads_in_banks_uJ']:.3f} in the banks + {cp['conv1_reads_in_pool_logic_uJ']:.3f} pool logic; "
                 f"with the 4-KB macro they cost {cp['conv1_cache_saved_with_4KB_macro_uJ']:.2f})")
    L.append("")
    for c, v in conds.items():
        L.append(f"condition {c}: read x{v['r_read']:.4f}, static x{v['r_static']:.3f} (settled {v['static_settled']}), "
                 f"data {v['read_time_ns']:.2f} ns; banks A {v['A']['bank_reads_uJ']:.3f} + {v['A']['bank_static_uJ']:.3f} = "
                 f"{v['A']['banks_uJ']:.3f} uJ ({v['A']['banks_x_tt']:.2f} x tt), B {v['B']['banks_uJ']:.3f} uJ")
    L.append("")
    for m in MODELS:
        x = area[m]
        L.append(f"area {m}: fixed {x['fixed_mm2']:.4f}, SRAM {area['sram_mm2']:.4f} (banks {area['banks_mm2']:.4f} + logic "
                 f"{area['pool_logic_mm2']:.4f}), total {x['range_mm2'][0]:.3f}-{x['range_mm2'][1]:.3f} mm2 (E8.6 "
                 f"{x['E8.6_range_mm2'][0]:.3f}-{x['E8.6_range_mm2'][1]:.3f}); protection {x['protection_mm2']:.3f} mm2, "
                 f"{100 * x['protection_share'][0]:.1f} / {100 * x['protection_share'][1]:.1f} %; map / SRAM {x['map_over_sram']:.2f}")
    fc = out["fig7"]["curve"]
    L.append(f"fig7 model: {slope:.3f} um2 per word, {a0:.1f} um2 per bank at zero words; budget 50 %: banks "
             f"{fc[50]['sram_banked_mm2']:.3f}, one copy {fc[50]['sram_single_mm2']:.3f}, 25 copies {fc[50]['sram_replicated_mm2']:.3f} mm2; "
             f"total (baseline) {fc[1]['total_banked_baseline_mm2']:.3f} at 1 %, {fc[50]['total_banked_baseline_mm2']:.3f} at 50 %")
    for m in MODELS:
        v = out["vi_a"][m]
        L.append(f"VI-A {m}: banks by their library {v['banks_by_library_uJ']:.3f} uJ against {v['banks_post_layout_uJ']:.3f} post-layout")
    L.append(f"VI-C: SRAM energy floor {vc['sram_energy_floor_uJ']:.1f} uJ = {vc['floor_over_lenet_AD_E10']:.2f} x the LeNet-5 A-D")
    L.append("")
    for c in checks:
        L.append(f"   {'PASS' if c['ok'] else 'FAIL'}  {c['check']}: {c['detail']}")
    L.append(f"{'ALL CHECKS PASS' if out['all_checks_pass'] else 'NOT ALL CHECKS PASS'}")
    open(os.path.join(a.out, "e10_2b_summary.txt"), "w").write("\n".join(L) + "\n")
    print("\n".join(L))
    return 0 if out["all_checks_pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
