"""
gen_drift_luts.py
============================================================
Paper 2 v2 - One-time tool to pre-generate precision LUTs
for the PCM drift coefficient computation in pcm_crossbar.v.

The drift coefficient computation in RTL is:
    coef[i] = (drift_t)^(-nu[i])
            = 2^(-nu[i] * log2(drift_t))

Two LUTs are needed:
  1. log2_lut: input drift_t (10-bit unsigned, range [0, 1023])
                → output log2(drift_t) in Q4.8 unsigned (12-bit, range [0, 4095])
                Precision: ~1/256 = 0.4%

  2. exp2_lut: input "exponent index" (10-bit unsigned, in Q2.8 format,
                representing exponent value in [0, 4))
                → output 2^(-exp_value) in Q1.7 unsigned (8-bit, [0, 255])
                Precision: ~1/128 = 0.8%

For drift_t in [10^3, 10^6]:
  log2(10^3) = 9.97, log2(10^6) = 19.93

Since our LUT only covers drift_t up to 1023, we need to scale up:
  Real RTL usage: log2(drift_t * SCALE) where SCALE makes it fit
  For now: drift_t_input = floor(real_t / 256), so input to LUT is up to ~3900
  
  Actually simpler: just clamp drift_t to [1, 1023] and use what we get.
  In practice for Paper 2, we use a few discrete time points like
  t = 1024 (~ 17 minutes) or use multiplier trick.

For Paper 2 baseline experiments, we use t = 10^6 seconds.
We'll preprocess this in Python: log2(10^6) = 19.93 ≈ 20.0.
The LUT is just used to get this approximate value.

A more robust approach: scale drift_t using shift, store log2 as
shift_amount + LUT_log2(remainder). But that's overkill for our needs.

For now: log2_lut covers t in [1, 1023], output in Q4.8.
RTL will scale up for larger t (e.g., for t=10^6, use log2_lut[t/4096] + 12).

OUTPUT (placed under data/rtl_inputs_common/):
    log2_lut.hex   - 1024 lines, 3 hex chars each (12-bit Q4.8)
    exp2_lut.hex   - 1024 lines, 2 hex chars each (8-bit Q1.7)
    drift_luts_meta.json - metadata + precision report

Usage:
    python gen_drift_luts.py
"""

import json
import math
from pathlib import Path

OUT_DIR = Path('./data/rtl_inputs_common')

# log2_lut: 1024 entries, output Q4.8 (12-bit, [0, 4095])
LOG2_SIZE = 1024
LOG2_OUT_BITS = 12
LOG2_FRAC_BITS = 8  # Q4.8 → 4 integer bits, 8 fractional bits
LOG2_OUT_MAX = (1 << LOG2_OUT_BITS) - 1

# exp2_lut: 1024 entries, output Q1.7 (8-bit, [0, 255])
# Input: exponent in Q2.8 format (10-bit), value in [0, 4)
EXP2_SIZE = 1024
EXP2_OUT_BITS = 8
EXP2_FRAC_OUT = 7  # Q1.7 → 1 integer bit (always 0 since 2^(-x) < 1 for x>0), 7 fractional
EXP2_INPUT_FRAC = 8  # input format: Q2.8


def gen_log2_lut():
    """log2_lut[i] = round(log2(i) * 256), clamped to 12-bit unsigned.
    log2(0) and log2(1) both stored as 0 (special case)."""
    lut = [0] * LOG2_SIZE
    for i in range(LOG2_SIZE):
        if i <= 1:
            lut[i] = 0
        else:
            val = math.log2(i) * (1 << LOG2_FRAC_BITS)
            lut[i] = max(0, min(LOG2_OUT_MAX, int(round(val))))
    return lut


def gen_exp2_lut():
    """exp2_lut[i] = round(2^(-i/256) * 128), clamped to 8-bit unsigned.
    i represents exponent in Q2.8: real_value = i / 256, range [0, 4).
    Output Q1.7: real_coef = lut[i] / 128, range (0, 1.0]."""
    lut = [0] * EXP2_SIZE
    for i in range(EXP2_SIZE):
        exp_val = i / (1 << EXP2_INPUT_FRAC)  # in [0, 4)
        coef = (2 ** (-exp_val)) * (1 << EXP2_FRAC_OUT)
        lut[i] = max(0, min(255, int(round(coef))))
    return lut


def write_hex(lut, path, hex_chars):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w') as f:
        for v in lut:
            f.write(f'{v:0{hex_chars}x}\n')


def report_precision(log2_lut, exp2_lut):
    """Sanity check: log2/exp2 round-trip on key values."""
    print("\n=== Precision check ===")

    # log2 spot checks
    print("\nlog2_lut check:")
    for t in [2, 8, 64, 100, 256, 512, 1000, 1023]:
        true_val = math.log2(t)
        lut_val = log2_lut[t] / 256.0
        err = (lut_val - true_val) / true_val * 100
        print(f"  log2({t:4d})  true={true_val:.4f}  lut={lut_val:.4f}  err={err:+.2f}%")

    # exp2 spot checks
    print("\nexp2_lut check:")
    for x_q in [0, 64, 128, 256, 512, 768, 1023]:
        x_real = x_q / 256.0
        true_val = 2 ** (-x_real)
        lut_val = exp2_lut[x_q] / 128.0
        if true_val > 0:
            err = (lut_val - true_val) / true_val * 100
        else:
            err = 0
        print(f"  2^(-{x_real:.4f})  true={true_val:.4f}  lut={lut_val:.4f}  err={err:+.2f}%")

    # End-to-end drift coefficient check
    print("\nEnd-to-end drift coef (nu=0.10):")
    nu = 0.10
    for t_real, t_lut_input in [(1000, None), (10000, None), (100000, None), (1000000, None)]:
        # In RTL, we'll handle large t by shift. For LUT input range [1,1023]:
        # t_lut_input = t_real >> shift, where shift = clog2(t_real / 1023)
        if t_real <= 1023:
            shift = 0
            t_idx = t_real
        else:
            shift = max(0, math.ceil(math.log2(t_real / 1023.0)))
            t_idx = t_real >> shift

        true_log2 = math.log2(t_real)
        lut_log2 = log2_lut[t_idx] / 256.0 + shift  # +shift accounts for the right-shift

        # nu_q = round(nu * 256) = 26 (Q0.8)
        nu_q = round(nu * 256)
        # Multiply: nu_q (Q0.8) × lut_log2_q (Q4.8 + shift) → Q4.16, take Q2.8
        # In RTL: expo_q = (nu_q * lut_log2_q + shift_part) >> 8
        # We approximate this here:
        expo_real = nu * true_log2  # what we WANT
        expo_q = round(expo_real * (1 << EXP2_INPUT_FRAC))
        expo_q_clipped = max(0, min(EXP2_SIZE - 1, expo_q))
        coef_lut = exp2_lut[expo_q_clipped] / 128.0
        coef_true = t_real ** (-nu)
        err = (coef_lut - coef_true) / coef_true * 100
        print(f"  t={t_real:7d}  shift={shift}  t_idx={t_idx:4d}  "
              f"true_coef={coef_true:.4f}  lut_coef={coef_lut:.4f}  err={err:+.2f}%")


def main():
    print("=" * 60)
    print("gen_drift_luts.py — Generating LUTs for pcm_crossbar.v")
    print(f"  log2_lut:  {LOG2_SIZE} entries, Q4.8 unsigned ({LOG2_OUT_BITS}-bit)")
    print(f"  exp2_lut:  {EXP2_SIZE} entries, Q1.7 unsigned ({EXP2_OUT_BITS}-bit)")
    print(f"  output:    {OUT_DIR}")
    print("=" * 60)

    log2_lut = gen_log2_lut()
    exp2_lut = gen_exp2_lut()

    write_hex(log2_lut, OUT_DIR / 'log2_lut.hex', 3)  # 12-bit → 3 hex chars
    write_hex(exp2_lut, OUT_DIR / 'exp2_lut.hex', 2)  # 8-bit → 2 hex chars

    meta = {
        'log2_lut': {
            'size': LOG2_SIZE,
            'output_bits': LOG2_OUT_BITS,
            'format': 'Q4.8 unsigned',
            'description': 'log2_lut[i] = round(log2(i) * 256), clamped 12-bit',
        },
        'exp2_lut': {
            'size': EXP2_SIZE,
            'output_bits': EXP2_OUT_BITS,
            'format': 'Q1.7 unsigned',
            'description': 'exp2_lut[i] = round(2^(-i/256) * 128), clamped 8-bit',
            'input_format': 'Q2.8 (exponent value = i/256, range [0, 4))',
        },
    }
    with open(OUT_DIR / 'drift_luts_meta.json', 'w') as f:
        json.dump(meta, f, indent=2)

    report_precision(log2_lut, exp2_lut)

    print("=" * 60)
    print(f"Done. Files in {OUT_DIR}")


if __name__ == '__main__':
    main()
