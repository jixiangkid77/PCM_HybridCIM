#!/usr/bin/env python3
"""
imc_vec.py  --  vectorized (numpy) INT8 hybrid SRAM/PCM-IMC forward for LeNet.

Same compute model as imc_forward_v3_imc.py (the per-element scaffold), but
batched over images so it can run a test set. Must reproduce the scaffold:
  - ADC off + drift off  => bit-exact vs the RTL golden
  - ADC 5-bit + drift off => identical fc3 logits to the scaffold

Layer math (after im2col, conv and fc are both matmuls out[o,m]=sum_k W[o,k]V[k,m]):
  protected (mask True)  -> exact integer partial (SRAM path)
  unprotected (mask False)-> PCM-IMC:
        |w| -> cellBit=2 cells C_j=(|w|>>2j)&3 ; sign via +/- polarity
        v (unsigned INT8) -> bit-serial b_i=(v>>i)&1
        rows tiled by subArray=64
        per (i,j,polarity,tile): analog partial = sum_row b_i*(C_j*drift)
            optional 5-bit ADC over [0, actual_rows_in_tile * cmax]
        shift-add: total += 2^i * 2^(2j) * (ADC(pos)-ADC(neg))
        drift: per-weight t^(-nu/256) on that weight's cells (off: t=1)
        compensation t^(+comp) applied to total AFTER ADC (off: comp=0)
  acc = bias + protected + pcm ; requant = arsh(acc,rshift) + relu/sat
"""

import json
import math
import os
import numpy as np

FFFF = 0xFFFF
LAYERS = ["conv1", "conv2", "fc1", "fc2", "fc3"]
WCOUNT = {"conv1": 150, "conv2": 2400, "fc1": 48000, "fc2": 10080, "fc3": 840}

DEFAULT_CFG = {
    "cellBit": 2, "n_mag_cells": 4, "subArray": 64, "in_bits": 8,
    "adc_bits": None, "drift_t": 1.0, "comp": 0.0,
}


# ---------- hex readers ----------
def read_hex_bytes(path, signed=True):
    out = []
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if not ln or ln.startswith("//"):
                continue
            v = int(ln, 16)
            if signed and v >= 128:
                v -= 256
            out.append(v)
    return out


def read_hex_words(path, width_bits=32):
    out = []
    sb = 1 << (width_bits - 1)
    full = 1 << width_bits
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if not ln or ln.startswith("//"):
                continue
            v = int(ln, 16)
            if v >= sb:
                v -= full
            out.append(v)
    return out


def read_hex_u(path):
    out = []
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if not ln or ln.startswith("//"):
                continue
            out.append(int(ln, 16))
    return out


# ---------- model loading ----------
def load_model(src_dir, v3_dir):
    """Returns dict with per-layer W (out,K) int, mask (out,K) bool protected,
    nu (out,K) int code, plus biases and rshift."""
    shapes = {
        "conv1": (6, 1 * 5 * 5), "conv2": (16, 6 * 5 * 5),
        "fc1": (120, 400), "fc2": (84, 120), "fc3": (10, 84),
    }
    raw = {L: np.array(read_hex_bytes(os.path.join(src_dir, f"weights_{L}.hex")),
                        dtype=np.int64) for L in LAYERS}
    for L in LAYERS:
        assert raw[L].size == WCOUNT[L]

    with open(os.path.join(v3_dir, "split_summary_v3.json")) as f:
        summ = json.load(f)
    sram_pool = np.array(read_hex_bytes(os.path.join(v3_dir, "sram_pool.hex")), dtype=np.int64)
    pcm_pool = np.array(read_hex_bytes(os.path.join(v3_dir, "pcm_pool.hex")), dtype=np.int64)
    nu_pool = np.array(read_hex_u(os.path.join(v3_dir, "nu_pcm_pool.hex")), dtype=np.int64)

    W, mask, nu = {}, {}, {}
    recon_bad = 0
    for L in LAYERS:
        n = WCOUNT[L]
        a_sram = np.array(read_hex_u(os.path.join(v3_dir, f"addr_to_slot_{L}_sram.hex")), dtype=np.int64)
        a_pcm = np.array(read_hex_u(os.path.join(v3_dir, f"addr_to_slot_{L}_pcm.hex")), dtype=np.int64)
        sbase = summ["layers"][L]["sram_base"]
        pbase = summ["layers"][L]["pcm_base"]
        m_flat = a_sram != FFFF
        nu_flat = np.zeros(n, dtype=np.float64)
        idx_pcm = np.where(~m_flat)[0]
        nu_flat[idx_pcm] = nu_pool[pbase + a_pcm[idx_pcm]] / 256.0   # code -> physical nu
        # reconstruction check
        rec = np.empty(n, dtype=np.int64)
        idx_sram = np.where(m_flat)[0]
        rec[idx_sram] = sram_pool[sbase + a_sram[idx_sram]]
        rec[idx_pcm] = pcm_pool[pbase + a_pcm[idx_pcm]]
        recon_bad += int(np.sum(rec != raw[L]))
        oc, K = shapes[L]
        W[L] = raw[L].reshape(oc, K)
        mask[L] = m_flat.reshape(oc, K)
        nu[L] = nu_flat.reshape(oc, K)
    assert recon_bad == 0, f"reconstruction mismatch ({recon_bad})"

    biases_all = read_hex_words(os.path.join(src_dir, "biases_all.hex"))
    rshift_all = read_hex_words(os.path.join(src_dir, "rshift_per_layer.hex"), width_bits=8)
    b = {"conv1": biases_all[0:6], "conv2": biases_all[6:22], "fc1": biases_all[22:142],
         "fc2": biases_all[142:226], "fc3": biases_all[226:236]}
    bias = {L: np.array(b[L], dtype=np.int64) for L in LAYERS}
    rshift = dict(zip(LAYERS, rshift_all[0:5]))
    return {"W": W, "mask": mask, "nu": nu, "bias": bias, "rshift": rshift}


# ---------- im2col ----------
def im2col(x, kh, kw, pad):
    """x: (B,C,H,W) -> (B, C*kh*kw, OH*OW), fan-in index = ic*kh*kw+ky*kw+kx."""
    B, C, H, W = x.shape
    OH, OW = H + 2 * pad - kh + 1, W + 2 * pad - kw + 1
    if pad:
        xp = np.zeros((B, C, H + 2 * pad, W + 2 * pad), dtype=x.dtype)
        xp[:, :, pad:pad + H, pad:pad + W] = x
    else:
        xp = x
    cols = np.empty((B, C, kh, kw, OH, OW), dtype=x.dtype)
    for ky in range(kh):
        for kx in range(kw):
            cols[:, :, ky, kx, :, :] = xp[:, :, ky:ky + OH, kx:kx + OW]
    return cols.reshape(B, C * kh * kw, OH * OW), OH, OW


# ---------- IMC matmul ----------
def imc_matmul(W, mask, nu, V, rshift, bias, cfg, kind, wn=None):
    """
    W,mask,nu: (out, K).  V: (K, M) int (M = positions*batch), unsigned for PCM.
    wn: (out, K, ncell) per-cell write-noise realization (float) or None.
    Returns requantized output (out, M) as int.
    """
    out_dim, K = W.shape
    cellBit, ncell = cfg["cellBit"], cfg["n_mag_cells"]
    sub, in_bits = cfg["subArray"], cfg["in_bits"]
    adc_bits, t, comp = cfg["adc_bits"], cfg["drift_t"], cfg["comp"]
    cmax = (1 << cellBit) - 1
    M = V.shape[1]

    # protected exact partial (integer)
    Wp = np.where(mask, W, 0)
    acc = bias[:, None] + Wp @ V                      # (out, M) int64

    # PCM path over unprotected weights
    Wu = np.where(mask, 0, W)
    if np.any(Wu != 0) or True:
        absU = np.abs(Wu)
        signpos = (Wu > 0).astype(np.float64)         # (out,K)
        signneg = (Wu < 0).astype(np.float64)
        if t != 1.0:
            D = np.where(mask, 1.0, t ** (-nu))        # nu is physical drift exponent
        else:
            D = np.ones_like(Wu, dtype=np.float64)

        # tiling: pad K to multiple of sub
        T = (K + sub - 1) // sub
        Kpad = T * sub
        actual_rows = np.full(T, sub, dtype=np.int64)
        if Kpad != K:
            actual_rows[-1] = K - (T - 1) * sub

        def padK(a, fill=0.0):
            if Kpad == K:
                return a
            out = np.full(a.shape[:-1] + (Kpad,), fill, dtype=a.dtype)
            out[..., :K] = a
            return out

        # per cell-plane: cell value scaled by drift, split by polarity, padded & tiled
        # CWpos[j] : (out, T, sub) ; same for neg
        Vf = V.astype(np.float64)                      # (K, M)
        # bit-planes of V: (in_bits, Kpad, M)
        Vp = padK(Vf.T).T if False else None           # placeholder
        # build padded V (Kpad, M)
        Vpad = np.zeros((Kpad, M), dtype=np.float64)
        Vpad[:K, :] = Vf
        Vbits = np.stack([((Vpad.astype(np.int64) >> i) & 1).astype(np.float64)
                          for i in range(in_bits)], axis=0)   # (in_bits, Kpad, M)
        Vbits_t = Vbits.reshape(in_bits, T, sub, M)            # (i, T, sub, M)

        pcm = np.zeros((out_dim, M), dtype=np.float64)
        for j in range(ncell):
            Cj = ((absU >> (cellBit * j)) & cmax).astype(np.float64)  # (out,K)
            if wn is not None:
                # per-cell write noise (programming error), unprotected cells only;
                # protected cells stay exact (SRAM). nonzero-weight polarity columns
                # carry the noise; exact-zero unprotected weights have no polarity so
                # their noise is not modeled here (secondary, see notes).
                Cj = Cj + wn[:, :, j] * (~mask)
            CjD_pos = padK(Cj * D * signpos).reshape(out_dim, T, sub)
            CjD_neg = padK(Cj * D * signneg).reshape(out_dim, T, sub)
            wj = float(1 << (cellBit * j))
            for i in range(in_bits):
                Bi = Vbits_t[i]                                   # (T, sub, M)
                # partial[out,T,M] = sum_sub Bi[T,sub,M] * CjD[out,T,sub]
                ppos = np.einsum('trm,otr->otm', Bi, CjD_pos, optimize=True)
                pneg = np.einsum('trm,otr->otm', Bi, CjD_neg, optimize=True)
                if adc_bits is not None:
                    fs = (actual_rows * cmax).astype(np.float64)  # (T,)
                    if cfg.get("comp_pre") and comp != 0.0:
                        fs = fs * (t ** (-comp))  # comp-aware ADC reference (corrected readout)
                    ppos = adc_quant(ppos, fs[None, :, None], adc_bits)
                    pneg = adc_quant(pneg, fs[None, :, None], adc_bits)
                contrib = (ppos - pneg).sum(axis=1)               # sum over T -> (out, M)
                bw = -(1 << i) if i == in_bits - 1 else (1 << i)   # two's-complement MSB
                pcm += (float(bw) * wj) * contrib
        if comp != 0.0:
            pcm *= (t ** comp)
        acc = acc.astype(np.float64) + pcm

    # requant
    if kind == "fc3":
        return requant_fc3(acc, rshift)
    return requant_relu(acc, rshift)


def adc_quant(x, full_scale, bits):
    levels = (1 << bits) - 1
    fs = np.asarray(full_scale, dtype=np.float64)
    q = np.where(fs > 0, np.round(x / np.where(fs > 0, fs, 1.0) * levels), 0.0)
    q = np.clip(q, 0, levels)
    return q / levels * fs


def _floor_div_shift(acc, rshift):
    # arithmetic shift / floor div toward -inf, works for int or float arrays
    return np.floor(acc / (1 << rshift))


def requant_relu(acc, rshift):
    shifted = _floor_div_shift(acc, rshift)
    out = np.where(acc <= 0, 0, np.minimum(127, shifted))
    return out.astype(np.int64)


def requant_fc3(acc, rshift):
    shifted = _floor_div_shift(acc, rshift).astype(np.int64)
    POS, NEG = 32767, -131071
    res = np.empty_like(shifted)
    pos_sat = shifted > POS
    neg_sat = shifted < NEG
    mid = ~(pos_sat | neg_sat)
    res[pos_sat] = 32767
    res[neg_sat] = -32768
    tr = (shifted[mid] & 0xFFFF)
    tr = np.where(tr & 0x8000, tr - 0x10000, tr)
    res[mid] = tr
    return res


# ---------- full LeNet forward (batched) ----------
def forward_batch(images_int, model, cfg):
    """images_int: (B, 784) signed INT8.  Returns (logits (B,10), preds (B,))."""
    B = images_int.shape[0]
    W, mask, nu, bias, rs = model["W"], model["mask"], model["nu"], model["bias"], model["rshift"]
    wn = model.get("wn")
    gw = lambda L: (wn[L] if wn is not None else None)

    x = images_int.reshape(B, 1, 28, 28)
    # conv1 (pad 2): all-protected -> exact regardless of cfg
    col, OH, OW = im2col(x, 5, 5, 2)                 # (B, 25, 784)
    V = np.transpose(col, (1, 0, 2)).reshape(25, B * OH * OW)
    c1 = imc_matmul(W["conv1"], mask["conv1"], nu["conv1"], V, rs["conv1"], bias["conv1"], cfg, "relu", gw("conv1"))
    c1 = c1.reshape(6, B, OH * OW).transpose(1, 0, 2).reshape(B, 6, 28, 28)

    p1 = c1.reshape(B, 6, 14, 2, 14, 2).max(axis=(3, 5))   # (B,6,14,14)

    col, OH, OW = im2col(p1, 5, 5, 0)               # (B,150,100)
    V = np.transpose(col, (1, 0, 2)).reshape(150, B * OH * OW)
    c2 = imc_matmul(W["conv2"], mask["conv2"], nu["conv2"], V, rs["conv2"], bias["conv2"], cfg, "relu", gw("conv2"))
    c2 = c2.reshape(16, B, OH * OW).transpose(1, 0, 2).reshape(B, 16, 10, 10)

    p2 = c2.reshape(B, 16, 5, 2, 5, 2).max(axis=(3, 5))    # (B,16,5,5)
    flat = p2.reshape(B, 400)

    f1 = imc_matmul(W["fc1"], mask["fc1"], nu["fc1"], flat.T, rs["fc1"], bias["fc1"], cfg, "relu", gw("fc1")).T
    f2 = imc_matmul(W["fc2"], mask["fc2"], nu["fc2"], f1.T, rs["fc2"], bias["fc2"], cfg, "relu", gw("fc2")).T
    f3 = imc_matmul(W["fc3"], mask["fc3"], nu["fc3"], f2.T, rs["fc3"], bias["fc3"], cfg, "fc3", gw("fc3")).T
    preds = np.argmax(f3, axis=1)
    return f3, preds
