"""
04_generate_pcm_nu.py
============================================================
Paper 2 v2 - PCM cell-level drift exponent (nu) generator.

Per Paper 1 III-A and config.py:
    G(t) = G_0 * (t / t_0)^(-nu)
    nu ~ N(DRIFT_NU_MEAN, DRIFT_NU_STD^2)
    DRIFT_NU_MEAN = 0.10
    DRIFT_NU_STD  = 0.03

Each PCM cell has its own nu, sampled once and fixed.

Output (per layer L in {conv1,conv2,fc1,fc2,fc3}):
    data/rtl_inputs_<A|B>/nu_<L>_pcm.hex
        - One INT8 per line (2 hex chars).
        - Quantization: nu_int8 = round(nu_float * NU_SCALE)
        - NU_SCALE = 256 (Q0.8 format, range [0, 255/256] ~= [0, 0.996])
        - Negative or zero nu values are clipped to 0
        - Values > 0.996 are clipped to 255
    data/rtl_inputs_<A|B>/nu_summary.json
        - Per-layer mean / std / min / max / clipped count

Number of lines per file matches weights_<L>_pcm.hex (i.e., number of
unprotected PCM cells in that layer).

Reproducibility: deterministic seed per (model, layer).
    seed = NU_SEED_BASE + layer_idx * 1000 + (0 if model=='A' else 500)

Usage:
    python 04_generate_pcm_nu.py --model A
    python 04_generate_pcm_nu.py --model B
"""

import argparse
import json
import numpy as np
from pathlib import Path

LAYERS = ['conv1', 'conv2', 'fc1', 'fc2', 'fc3']

# Paper 1 physical constants (config.py)
DRIFT_NU_MEAN = 0.10
DRIFT_NU_STD = 0.03

# Quantization parameters
NU_SCALE = 256          # Q0.8: stored value = round(nu * 256), range [0, 255]
NU_SCALE_BITS = 8

# Reproducibility
NU_SEED_BASE = 42000


def parse_args():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', choices=['A', 'B'], required=True)
    ap.add_argument('--data-dir', default=None,
                    help='Working dir; default = ./data/rtl_inputs_<model>')
    ap.add_argument('--seed-base', type=int, default=NU_SEED_BASE,
                    help=f'Base seed for reproducibility (default {NU_SEED_BASE})')
    return ap.parse_args()


def count_pcm_weights(data_dir, layer):
    """Count number of lines in weights_<layer>_pcm.hex to know how many cells need nu."""
    path = data_dir / f'weights_{layer}_pcm.hex'
    if not path.exists():
        raise FileNotFoundError(f'Missing input: {path}')
    n = 0
    with open(path) as f:
        for line in f:
            s = line.strip()
            if s and not s.startswith('//'):
                n += 1
    return n


def sample_nu(n_cells, seed):
    """Sample n_cells values of nu from N(DRIFT_NU_MEAN, DRIFT_NU_STD^2)."""
    rng = np.random.default_rng(seed)
    nu = rng.normal(DRIFT_NU_MEAN, DRIFT_NU_STD, size=n_cells)
    return nu


def quantize_nu(nu_float):
    """Quantize nu to INT8 (Q0.8 unsigned, range [0, 255])."""
    nu_q = np.round(nu_float * NU_SCALE).astype(np.int32)
    n_clip_low = int((nu_q < 0).sum())
    n_clip_high = int((nu_q > 255).sum())
    nu_q = nu_q.clip(0, 255)
    return nu_q.astype(np.uint8), n_clip_low, n_clip_high


def write_nu_hex(nu_int8, path):
    """Write unsigned INT8 array as 2-hex-char per line."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w') as f:
        for v in nu_int8:
            f.write(f'{int(v):02x}\n')


def main():
    args = parse_args()
    model = args.model
    data_dir = Path(args.data_dir) if args.data_dir else Path(f'./data/rtl_inputs_{model}')

    print('=' * 60)
    print(f'04_generate_pcm_nu.py  Model {model}')
    print(f'  data_dir:    {data_dir}')
    print(f'  nu mean/std: {DRIFT_NU_MEAN} / {DRIFT_NU_STD}')
    print(f'  quant scale: {NU_SCALE} (Q0.8, INT8)')
    print(f'  seed base:   {args.seed_base}')
    print('=' * 60)

    if not data_dir.exists():
        print(f'[ERROR] Directory does not exist: {data_dir}')
        print(f'        Run 03_split_protected.py --model {model} first.')
        return

    summary = {
        'model': model,
        'nu_mean_target': DRIFT_NU_MEAN,
        'nu_std_target': DRIFT_NU_STD,
        'nu_scale': NU_SCALE,
        'seed_base': args.seed_base,
        'layers': {},
    }

    total_cells = 0
    total_clip_low = 0
    total_clip_high = 0

    for layer_idx, layer in enumerate(LAYERS):
        n_pcm = count_pcm_weights(data_dir, layer)

        if n_pcm == 0:
            print(f'  {layer:6s}: 0 PCM cells (all SRAM), writing empty file')
            write_nu_hex(np.array([], dtype=np.uint8),
                         data_dir / f'nu_{layer}_pcm.hex')
            summary['layers'][layer] = {
                'n_pcm_cells': 0,
                'nu_mean_actual': None,
                'nu_std_actual': None,
                'nu_min': None, 'nu_max': None,
                'clipped_low': 0, 'clipped_high': 0,
            }
            continue

        seed = args.seed_base + layer_idx * 1000 + (0 if model == 'A' else 500)
        nu_float = sample_nu(n_pcm, seed)
        nu_int8, n_lo, n_hi = quantize_nu(nu_float)

        write_nu_hex(nu_int8, data_dir / f'nu_{layer}_pcm.hex')

        # Stats on quantized values (back to float for sanity)
        nu_dequant = nu_int8.astype(np.float64) / NU_SCALE
        actual_mean = float(nu_dequant.mean())
        actual_std = float(nu_dequant.std())

        print(f'  {layer:6s}: {n_pcm:6d} cells, '
              f'mean={actual_mean:.4f}, std={actual_std:.4f}, '
              f'range=[{nu_dequant.min():.4f}, {nu_dequant.max():.4f}], '
              f'clipped_low={n_lo}, clipped_high={n_hi}, seed={seed}')

        summary['layers'][layer] = {
            'n_pcm_cells': n_pcm,
            'seed': seed,
            'nu_mean_actual': actual_mean,
            'nu_std_actual': actual_std,
            'nu_min': float(nu_dequant.min()),
            'nu_max': float(nu_dequant.max()),
            'clipped_low': n_lo,
            'clipped_high': n_hi,
        }

        total_cells += n_pcm
        total_clip_low += n_lo
        total_clip_high += n_hi

    summary['total_pcm_cells'] = total_cells
    summary['total_clipped_low'] = total_clip_low
    summary['total_clipped_high'] = total_clip_high

    with open(data_dir / 'nu_summary.json', 'w') as f:
        json.dump(summary, f, indent=2)

    print('=' * 60)
    print(f'Total PCM cells:       {total_cells}')
    print(f'Total clipped (low):   {total_clip_low}')
    print(f'Total clipped (high):  {total_clip_high}')
    print(f'Summary written:       {data_dir / "nu_summary.json"}')
    print('=' * 60)
    print('Done.')


if __name__ == '__main__':
    main()
