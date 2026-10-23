#!/usr/bin/env python3
"""
imc_torch.py -- torch (GPU-capable) port of imc_vec.py's INT8 hybrid SRAM/PCM-IMC
forward for LeNet. Same math as the numpy reference (imc_vec.py); runs on cuda for
speed on Colab. Validated to reproduce imc_vec predictions image-for-image, and to
match the RTL golden bit-exactly at the no-drift/no-ADC/no-noise point.

dtype: float64 reproduces numpy exactly; float32 is fast on GPU and is exact for
LeNet layer sizes (all integer accumulations stay below 2^24). For deeper nets
(ImageNet) use float64 or int accumulation.
"""

import math
import torch
import numpy as np
try:
    from imc_vec import load_model, read_hex_bytes, LAYERS, WCOUNT  # LeNet-only; not used by ResNet
except Exception:
    load_model = read_hex_bytes = LAYERS = WCOUNT = None  # ResNet path uses imc_matmul_t directly

DEFAULT_CFG = {
    "cellBit": 2, "n_mag_cells": 4, "subArray": 64, "in_bits": 8,
    "adc_bits": None, "drift_t": 1.0, "comp": 0.0,
}


# ---------- move model to torch + precompute cells ----------
def to_torch_model(model, device="cpu", dtype=torch.float32, cellBit=2, ncell=4):
    cmax = (1 << cellBit) - 1
    tm = {"rshift": model["rshift"], "W": {}, "mask": {}, "nu": {}, "bias": {}, "cells": {}}
    for L in LAYERS:
        W = model["W"][L]                                  # numpy int (out,K)
        absW = np.abs(W)
        cells = np.stack([((absW >> (cellBit * j)) & cmax) for j in range(ncell)], axis=-1)
        tm["W"][L] = torch.tensor(W, device=device, dtype=dtype)
        tm["mask"][L] = torch.tensor(model["mask"][L], device=device)        # bool
        tm["nu"][L] = torch.tensor(model["nu"][L], device=device, dtype=dtype)
        tm["bias"][L] = torch.tensor(model["bias"][L], device=device, dtype=dtype)
        tm["cells"][L] = torch.tensor(cells, device=device, dtype=dtype)     # (out,K,ncell)
    return tm


def writenoise_torch(model, seed, device="cpu", dtype=torch.float32, cellBit=2, ncell=4):
    sigma_value = 0.03 * 127.0
    S = sum((2 ** (cellBit * j)) ** 2 for j in range(ncell))
    sc = sigma_value / math.sqrt(S)
    rng = np.random.RandomState(seed)
    return {L: torch.tensor(rng.normal(0.0, sc, model["W"][L].shape + (ncell,)),
                            device=device, dtype=dtype) for L in LAYERS}


def nu_torch(model, seed, device="cpu", dtype=torch.float32):
    rng = np.random.RandomState(seed)
    return {L: torch.tensor(rng.normal(0.10, 0.03, model["W"][L].shape),
                            device=device, dtype=dtype) for L in LAYERS}


# ---------- helpers ----------
def adc_quant_t(x, fs, bits):
    levels = (1 << bits) - 1
    safe = torch.where(fs > 0, fs, torch.ones_like(fs))
    q = torch.where(fs > 0, torch.round(x / safe * levels), torch.zeros_like(x))
    q = torch.clamp(q, 0, levels)
    return q / levels * fs


def requant_relu_t(acc, rshift):
    shifted = torch.floor(acc / (1 << rshift))
    return torch.where(acc <= 0, torch.zeros_like(acc), torch.clamp(shifted, max=127))


def requant_fc3_t(acc, rshift):
    shifted = torch.floor(acc / (1 << rshift))
    POS, NEG = 32767, -131071
    tr = shifted.to(torch.int64) & 0xFFFF
    tr = torch.where((tr & 0x8000) != 0, tr - 0x10000, tr).to(acc.dtype)
    res = torch.where(shifted > POS, torch.full_like(shifted, 32767.0),
                      torch.where(shifted < NEG, torch.full_like(shifted, -32768.0), tr))
    return res


def im2col_t(x, kh, kw, pad):
    B, C, H, W = x.shape
    OH, OW = H + 2 * pad - kh + 1, W + 2 * pad - kw + 1
    if pad:
        xp = torch.zeros((B, C, H + 2 * pad, W + 2 * pad), device=x.device, dtype=x.dtype)
        xp[:, :, pad:pad + H, pad:pad + W] = x
    else:
        xp = x
    cols = torch.empty((B, C, kh, kw, OH, OW), device=x.device, dtype=x.dtype)
    for ky in range(kh):
        for kx in range(kw):
            cols[:, :, ky, kx, :, :] = xp[:, :, ky:ky + OH, kx:kx + OW]
    return cols.reshape(B, C * kh * kw, OH * OW), OH, OW


# ---------- IMC matmul (torch) ----------
def imc_matmul_t(tm, L, V, cfg, kind, wn_L=None):
    cells_L, W_L, mask_L, nu_L, bias_L = tm["cells"][L], tm["W"][L], tm["mask"][L], tm["nu"][L], tm["bias"][L]
    rshift = tm["rshift"][L]
    device, dtype = W_L.device, W_L.dtype
    out_dim, K = W_L.shape
    cellBit, ncell, sub, in_bits = cfg["cellBit"], cfg["n_mag_cells"], cfg["subArray"], cfg["in_bits"]
    adc_bits, t, comp = cfg["adc_bits"], cfg["drift_t"], cfg["comp"]
    cmax = (1 << cellBit) - 1
    M = V.shape[1]
    zeroW = torch.zeros_like(W_L)

    Wp = torch.where(mask_L, W_L, zeroW)
    acc = bias_L[:, None] + Wp @ V

    Wu = torch.where(mask_L, zeroW, W_L)
    if not bool((Wu != 0).any()):
        # fully protected layer (e.g. conv1): no PCM contribution, skip the analog path
        if kind == "raw":
            return acc
        if kind == "fc3":
            return requant_fc3_t(acc, rshift)
        return requant_relu_t(acc, rshift)
    signpos = (Wu > 0).to(dtype)
    signneg = (Wu < 0).to(dtype)
    if t != 1.0:
        Dpcm = torch.pow(torch.as_tensor(float(t), device=device, dtype=dtype), -nu_L)
        D = torch.where(mask_L, torch.ones_like(nu_L), Dpcm)
    else:
        D = torch.ones_like(W_L)

    T = (K + sub - 1) // sub
    Kpad = T * sub
    actual_rows = torch.full((T,), float(sub), device=device, dtype=dtype)
    if Kpad != K:
        actual_rows[-1] = float(K - (T - 1) * sub)

    def padK(a):
        if Kpad == K:
            return a
        o = torch.zeros(a.shape[:-1] + (Kpad,), device=device, dtype=dtype)
        o[..., :K] = a
        return o

    Vpad = torch.zeros((Kpad, M), device=device, dtype=dtype)
    Vpad[:K, :] = V
    Vint = Vpad.to(torch.int64)
    Vbits = torch.stack([((Vint >> i) & 1).to(dtype) for i in range(in_bits)], dim=0)
    Vbits_t = Vbits.reshape(in_bits, T, sub, M)

    notmask = (~mask_L).to(dtype)
    pcm = torch.zeros((out_dim, M), device=device, dtype=dtype)
    for j in range(ncell):
        Cj = cells_L[:, :, j]
        if wn_L is not None:
            Cj = Cj + wn_L[:, :, j] * notmask
        CjD_pos = padK(Cj * D * signpos).reshape(out_dim, T, sub)
        CjD_neg = padK(Cj * D * signneg).reshape(out_dim, T, sub)
        wj = float(1 << (cellBit * j))
        for i in range(in_bits):
            Bi = Vbits_t[i]
            ppos = torch.einsum('trm,otr->otm', Bi, CjD_pos)
            pneg = torch.einsum('trm,otr->otm', Bi, CjD_neg)
            if adc_bits is not None:
                fs = (actual_rows * cmax)
                if cfg.get("comp_pre", False) and comp != 0.0 and t > 0.0:
                    # comp-aware ADC range: shrink full-scale to the drifted signal so the
                    # coarse ADC keeps resolution; the global post-comp (below) restores the
                    # scale without amplifying the quantization noise.
                    fs = fs * math.exp(-comp * math.log(t))
                ppos = adc_quant_t(ppos, fs[None, :, None], adc_bits)
                pneg = adc_quant_t(pneg, fs[None, :, None], adc_bits)
            contrib = (ppos - pneg).sum(dim=1)
            bw = -(1 << i) if i == in_bits - 1 else (1 << i)
            pcm = pcm + (float(bw) * wj) * contrib
    if comp != 0.0:
        pcm = pcm * (math.exp(comp * math.log(t)) if t > 0 else 1.0)
    acc = acc + pcm

    if kind == "raw":
        return acc
    if kind == "fc3":
        return requant_fc3_t(acc, rshift)
    return requant_relu_t(acc, rshift)


# ---------- full LeNet forward (torch, batched) ----------
def forward_batch_t(images_int, tm, cfg, wn=None):
    device, dtype = tm["W"]["conv1"].device, tm["W"]["conv1"].dtype
    B = images_int.shape[0]
    gw = lambda L: (wn[L] if wn is not None else None)
    x = torch.tensor(images_int.reshape(B, 1, 28, 28), device=device, dtype=dtype)

    col, OH, OW = im2col_t(x, 5, 5, 2)
    V = col.permute(1, 0, 2).reshape(25, B * OH * OW)
    c1 = imc_matmul_t(tm, "conv1", V, cfg, "relu", gw("conv1"))
    c1 = c1.reshape(6, B, OH * OW).permute(1, 0, 2).reshape(B, 6, 28, 28)
    p1 = c1.reshape(B, 6, 14, 2, 14, 2).amax(dim=(3, 5))

    col, OH, OW = im2col_t(p1, 5, 5, 0)
    V = col.permute(1, 0, 2).reshape(150, B * OH * OW)
    c2 = imc_matmul_t(tm, "conv2", V, cfg, "relu", gw("conv2"))
    c2 = c2.reshape(16, B, OH * OW).permute(1, 0, 2).reshape(B, 16, 10, 10)
    p2 = c2.reshape(B, 16, 5, 2, 5, 2).amax(dim=(3, 5))
    flat = p2.reshape(B, 400)

    f1 = imc_matmul_t(tm, "fc1", flat.t().contiguous(), cfg, "relu", gw("fc1")).t()
    f2 = imc_matmul_t(tm, "fc2", f1.t().contiguous(), cfg, "relu", gw("fc2")).t()
    f3 = imc_matmul_t(tm, "fc3", f2.t().contiguous(), cfg, "fc3", gw("fc3")).t()
    preds = torch.argmax(f3, dim=1)
    return f3, preds
