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
_ADC_NO_CLAMP = False  # diagnostic: when True, drop ADC top saturation (keep unipolar floor)

def adc_quant_t(x, fs, bits):
    levels = (1 << bits) - 1
    safe = torch.where(fs > 0, fs, torch.ones_like(fs))
    q = torch.where(fs > 0, torch.round(x / safe * levels), torch.zeros_like(x))
    if _ADC_NO_CLAMP:
        q = torch.clamp(q, min=0)
    else:
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

# ============== imc_resnet (inlined) ==============
#!/usr/bin/env python3
"""
imc_resnet.py -- ResNet-50 hybrid SRAM/PCM-IMC forward (analog crossbar + ADC).

Each PCM-mapped conv/linear (per config_imagenet.is_pcm_weight: weight, not BN,
not downsample.1) is replaced by an IMC module that:
  - quantizes its input activations to INT8 (per-layer calibrated scale),
  - runs the same validated IMC MAC as LeNet (imc_torch.imc_matmul_t, "raw"):
    cellBit=2 sign-magnitude cells, two's-complement bit-serial input, 64-row
    subarray tiling, 5-bit ADC per tile, per-weight drift t^(-nu), per-cell write
    noise; protected (top-k) weights computed exactly (SRAM),
  - dequantizes the integer MAC by (act_scale * weight_scale) to float; BN/ReLU/
    residual/pool stay in float (weight-only-quant baseline keeps activations fp,
    so between IMC convs we return to float exactly as that pipeline does).

mode='ref' replaces the IMC MAC with an exact INT8 conv (F.conv2d on the integer
tensors) so the IMC path can be validated bit-exactly at no-drift/no-ADC/no-noise.

Weights are quantized exactly as config_imagenet.build_quant_cache:
scale = w.abs().max()/127, w_q = round(w/scale). Protection top-k is by |w_orig|,
k = round(ratio*numel), matching config_imagenet.apply_drift_inplace.
"""

import math
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F


CELLBIT, NCELL = 2, 4
DRIFT_MEAN, DRIFT_STD, WRITE_NOISE = 0.10, 0.03, 0.03
BASE_CFG = {"cellBit": CELLBIT, "n_mag_cells": NCELL, "subArray": 64, "in_bits": 8,
            "adc_bits": None, "drift_t": 1.0, "comp": 0.0}


def writenoise_sigma_cell(cellBit=CELLBIT, ncell=NCELL):
    return WRITE_NOISE * 127.0 / math.sqrt(sum((2 ** (cellBit * j)) ** 2 for j in range(ncell)))


def is_pcm_weight(name):
    if "weight" not in name:
        return False
    if "bn" in name or "downsample.1" in name:
        return False
    return True


def _cells_from_wq(Wq2d, device, dtype):
    absW = Wq2d.abs().to(torch.int64)
    cmax = (1 << CELLBIT) - 1
    return torch.stack([((absW >> (CELLBIT * j)) & cmax).to(dtype)
                        for j in range(NCELL)], dim=-1)


class _IMCBase(nn.Module):
    """Holds INT8 weight + cells + per-run state shared by conv and linear."""
    def __init__(self, weight, device, dtype):
        super().__init__()
        self.device_, self.dtype_ = device, dtype
        w = weight.detach().to(torch.float32)
        self.w_orig = w.clone()
        wmax = w.abs().max()
        self.w_scale = float(wmax / 127.0) if wmax > 0 else 1.0
        wq4d = torch.round(w / (self.w_scale + 1e-9))                 # (out, ...)
        self.out_ch = wq4d.shape[0]
        self.Wq4d = wq4d.to(device=device, dtype=dtype)              # for ref conv
        self.Wq2d = wq4d.reshape(self.out_ch, -1).to(device=device, dtype=dtype)
        self.cells = _cells_from_wq(self.Wq2d, device, dtype)        # (out,K,ncell)
        self.numel = int(self.w_orig.numel())
        # per-run state
        self.act_scale = 1.0
        self.mask = None
        self.nu = None
        self.wn = None
        self.cfg = dict(BASE_CFG)
        self.mode = "imc"
        self.bias0 = torch.zeros(self.out_ch, device=device, dtype=dtype)

    def _mini_tm(self):
        return {"cells": {"x": self.cells}, "W": {"x": self.Wq2d}, "mask": {"x": self.mask},
                "nu": {"x": self.nu}, "bias": {"x": self.bias0}, "rshift": {"x": 0}}

    def set_state(self, act_scale, mask, nu, wn, cfg, mode="imc"):
        self.act_scale = float(act_scale)
        self.mask = mask
        self.nu = nu
        self.wn = wn
        self.cfg = cfg
        self.mode = mode

    def _effective_weight_noadc(self):
        """Effective INT-domain weight for the NO-ADC case, computed in one shot.
        Without an ADC the bit-serial/cell reconstruction is loss-free, so the
        crossbar output equals an exact MAC against this effective weight:
          unprotected: sign(Wq) * [sum_j (cell_j + wn_j) 4^j] * t^(comp - nu)
          protected:   Wq  (drift-free, no write noise)
        This is algebraically identical to imc_matmul_t with adc_bits=None
        (verified numerically), but costs one matmul instead of 32 einsums."""
        cw = torch.tensor([float(1 << (CELLBIT * j)) for j in range(NCELL)],
                          device=self.device_, dtype=self.dtype_)        # 4^j
        cellsn = self.cells + self.wn if self.wn is not None else self.cells
        mag = (cellsn * cw).sum(dim=-1)                                   # (out,K)
        sign = torch.sign(self.Wq2d)                                     # 0 for exact-zero weights
        t = self.cfg["drift_t"]; comp = self.cfg["comp"]
        if t != 1.0:
            Dpcm = torch.pow(torch.as_tensor(float(t), device=self.device_, dtype=self.dtype_),
                             comp - self.nu)                              # t^(comp - nu)
            D = torch.where(self.mask, torch.ones_like(self.nu), Dpcm)
        else:
            D = torch.ones_like(self.Wq2d)
        Weff_unprot = sign * mag * D
        return torch.where(self.mask, self.Wq2d, Weff_unprot)            # (out,K)


class IMCConv2d(_IMCBase):
    def __init__(self, conv, device, dtype):
        super().__init__(conv.weight, device, dtype)
        self.stride = conv.stride
        self.padding = conv.padding
        self.dilation = conv.dilation
        self.kh, self.kw = conv.kernel_size

    def forward(self, x):
        B, Cin, H, W = x.shape
        sH, sW = self.stride; pH, pW = self.padding; dH, dW = self.dilation
        OH = (H + 2 * pH - dH * (self.kh - 1) - 1) // sH + 1
        OW = (W + 2 * pW - dW * (self.kw - 1) - 1) // sW + 1
        xq = torch.round(x / (self.act_scale + 1e-9)).clamp(-128, 127).to(self.dtype_)
        deq = self.act_scale * self.w_scale
        if self.mode == "ref":
            out = F.conv2d(xq, self.Wq4d, None, self.stride, self.padding, self.dilation)
            return out * deq
        if self.mode == "imc_noadc":
            Weff = self._effective_weight_noadc().reshape(self.Wq4d.shape)
            out = F.conv2d(xq, Weff, None, self.stride, self.padding, self.dilation)
            return out * deq
        V = F.unfold(xq, (self.kh, self.kw), self.dilation, self.padding, self.stride)  # (B,K,L)
        K = V.shape[1]
        Vk = V.permute(1, 0, 2).reshape(K, B * OH * OW)
        acc = imc_matmul_t(self._mini_tm(), "x", Vk, self.cfg, "raw", self.wn)          # (out, B*L)
        out = acc.reshape(self.out_ch, B, OH * OW).permute(1, 0, 2).reshape(B, self.out_ch, OH, OW)
        return out * deq


class IMCLinear(_IMCBase):
    def __init__(self, lin, device, dtype):
        super().__init__(lin.weight, device, dtype)
        self.lin_bias = None if lin.bias is None else lin.bias.detach().to(device=device, dtype=dtype)

    def forward(self, x):
        xq = torch.round(x / (self.act_scale + 1e-9)).clamp(-128, 127).to(self.dtype_)
        deq = self.act_scale * self.w_scale
        if self.mode == "ref":
            out = xq @ self.Wq2d.t()
        elif self.mode == "imc_noadc":
            out = xq @ self._effective_weight_noadc().t()
        else:
            acc = imc_matmul_t(self._mini_tm(), "x", xq.t().contiguous(), self.cfg, "raw", self.wn)
            out = acc.t()
        out = out * deq
        if self.lin_bias is not None:
            out = out + self.lin_bias
        return out


# ---------- module tree surgery ----------
def _get_parent(model, path):
    parts = path.split(".")
    obj = model
    for p in parts[:-1]:
        obj = obj[int(p)] if p.isdigit() else getattr(obj, p)
    return obj, parts[-1]


def _set_module(model, path, new):
    parent, last = _get_parent(model, path)
    if last.isdigit():
        parent[int(last)] = new
    else:
        setattr(parent, last, new)


def build_imc_resnet(model, device="cuda", dtype=torch.float32):
    """Swap every PCM-mapped conv/linear with an IMC module. Returns {path: imc_module}."""
    imc = {}
    pcm_names = [n for n, _ in model.named_parameters() if is_pcm_weight(n)]
    mods = dict(model.named_modules())
    for n in pcm_names:
        path = n[:-len(".weight")]
        m = mods[path]
        new = IMCLinear(m, device, dtype) if isinstance(m, nn.Linear) else IMCConv2d(m, device, dtype)
        _set_module(model, path, new)
        imc[path] = new
    model.to(device).eval()
    return imc


# ---------- activation-scale calibration ----------
def calibrate_act_scales(imc_modules, model, calib_batches, device):
    """Run a few fp batches in 'ref' mode and record per-layer input max-abs.
    (ref mode quantizes with the CURRENT scale but we only need the input range;
    we set scale=1 first so xq=round(x) does not clip the range estimate.)"""
    maxabs = {p: 0.0 for p in imc_modules}
    handles = []
    for p, m in imc_modules.items():
        def hook(mod, inp, _p=p):
            v = inp[0].detach().abs().max().item()
            if v > maxabs[_p]:
                maxabs[_p] = v
        handles.append(m.register_forward_pre_hook(hook))
    # temporary identity-ish state so the model runs (ref mode, scale 1, no clip issue
    # because ref path computes F.conv2d on round(x); fine for range collection)
    for m in imc_modules.values():
        m.set_state(1.0, torch.zeros(m.Wq2d.shape, dtype=torch.bool, device=device),
                    None, None, dict(BASE_CFG), mode="ref")
    with torch.no_grad():
        for xb in calib_batches:
            model(xb.to(device))
    for h in handles:
        h.remove()
    return {p: (maxabs[p] / 127.0 if maxabs[p] > 0 else 1.0) for p in imc_modules}


# ---------- protection masks (top-k by |w_orig|, matching config_imagenet) ----------
def make_masks(imc_modules, ratios, device):
    masks = {}
    for p, m in imc_modules.items():
        r = float(ratios.get(p + ".weight", ratios.get(p, 0.0)))
        k = max(0, min(int(round(r * m.numel)), m.numel))
        flat = m.w_orig.abs().flatten()
        mk = torch.zeros(m.numel, dtype=torch.bool)
        if k > 0:
            idx = torch.topk(flat, k, largest=True, sorted=False).indices
            mk[idx] = True
        masks[p] = mk.view(m.Wq2d.shape).to(device)
    return masks


def uniform_ratios(imc_modules, budget=0.05):
    return {p: budget for p in imc_modules}


def none_ratios(imc_modules):
    return {p: 0.0 for p in imc_modules}


# ---------- per-seed drift / write-noise ----------
def gen_nu(imc_modules, seed, device, dtype):
    rng = np.random.RandomState(seed)
    return {p: torch.tensor(rng.normal(DRIFT_MEAN, DRIFT_STD, m.Wq2d.shape),
                            device=device, dtype=dtype) for p, m in imc_modules.items()}


def gen_wn(imc_modules, seed, device, dtype):
    sc = writenoise_sigma_cell()
    rng = np.random.RandomState(seed)
    return {p: torch.tensor(rng.normal(0.0, sc, m.Wq2d.shape + (NCELL,)),
                            device=device, dtype=dtype) for p, m in imc_modules.items()}


def set_run_state(imc_modules, act_scales, masks, nu, wn, drift_t, adc_bits, comp, mode="imc"):
    cfg = dict(BASE_CFG)
    cfg["drift_t"] = drift_t; cfg["adc_bits"] = adc_bits; cfg["comp"] = comp
    for p, m in imc_modules.items():
        m.set_state(act_scales[p], masks[p], nu[p] if nu else None,
                    wn[p] if wn else None, cfg, mode=mode)

# ============== embedded beta=50% layer-aware ratios ==============
LAYER_AWARE_RATIOS = {'conv1.weight': 1.0, 'layer1.0.conv1.weight': 1.0, 'layer1.0.conv2.weight': 1.0, 'layer1.0.conv3.weight': 1.0, 'layer1.0.downsample.0.weight': 1.0, 'layer1.1.conv1.weight': 1.0, 'layer1.1.conv2.weight': 1.0, 'layer1.1.conv3.weight': 1.0, 'layer1.2.conv1.weight': 1.0, 'layer1.2.conv2.weight': 1.0, 'layer1.2.conv3.weight': 1.0, 'layer2.0.conv1.weight': 1.0, 'layer2.0.conv2.weight': 1.0, 'layer2.0.conv3.weight': 1.0, 'layer2.0.downsample.0.weight': 1.0, 'layer2.1.conv1.weight': 0.3139224542532097, 'layer2.1.conv2.weight': 1.0, 'layer2.1.conv3.weight': 1.0, 'layer2.2.conv1.weight': 0.7481958762228557, 'layer2.2.conv2.weight': 0.7851334304171103, 'layer2.2.conv3.weight': 1.0, 'layer2.3.conv1.weight': 0.8811710713220798, 'layer2.3.conv2.weight': 0.947845694462583, 'layer2.3.conv3.weight': 1.0, 'layer3.0.conv1.weight': 1.0, 'layer3.0.conv2.weight': 0.3040100979378327, 'layer3.0.conv3.weight': 1.0, 'layer3.0.downsample.0.weight': 0.6034380688996772, 'layer3.1.conv1.weight': 0.3366460635423506, 'layer3.1.conv2.weight': 0.25182995808876624, 'layer3.1.conv3.weight': 1.0, 'layer3.2.conv1.weight': 0.350532713663473, 'layer3.2.conv2.weight': 0.14803075516320582, 'layer3.2.conv3.weight': 0.9150460814660699, 'layer3.3.conv1.weight': 0.40671052551710457, 'layer3.3.conv2.weight': 0.26997144040188326, 'layer3.3.conv3.weight': 0.7974303630159543, 'layer3.4.conv1.weight': 0.5731399231808593, 'layer3.4.conv2.weight': 0.18412669419858074, 'layer3.4.conv3.weight': 0.8117378207165067, 'layer3.5.conv1.weight': 1.0, 'layer3.5.conv2.weight': 0.26389310869903465, 'layer3.5.conv3.weight': 1.0, 'layer4.0.conv1.weight': 1.0, 'layer4.0.conv2.weight': 0.21587428824653768, 'layer4.0.conv3.weight': 0.5700890682300144, 'layer4.0.downsample.0.weight': 1.0, 'layer4.1.conv1.weight': 1.0, 'layer4.1.conv2.weight': 0.14541239689121316, 'layer4.1.conv3.weight': 0.4098665823628218, 'layer4.2.conv1.weight': 1.0, 'layer4.2.conv2.weight': 0.03427243952451976, 'layer4.2.conv3.weight': 0.14549422058721106, 'fc.weight': 0.566373337303667}

# ============== diagnostic driver (self-contained) ==============
import argparse, json as _json
IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD  = [0.229, 0.224, 0.225]

def imagenet_subset_loader(val_root, n_images, subset_seed, batch_size, num_workers):
    from torchvision import datasets, transforms
    tx = transforms.Compose([transforms.Resize(256), transforms.CenterCrop(224),
                             transforms.ToTensor(), transforms.Normalize(IMAGENET_MEAN, IMAGENET_STD)])
    ds = datasets.ImageFolder(val_root, transform=tx)
    rng = np.random.RandomState(subset_seed)
    idx = np.sort(rng.choice(len(ds), size=min(n_images, len(ds)), replace=False))
    sub = torch.utils.data.Subset(ds, idx.tolist())
    return torch.utils.data.DataLoader(sub, batch_size=batch_size, shuffle=False,
                                       num_workers=num_workers, pin_memory=True), len(sub)

def float_calibrate(model, pcm_paths, loader, device, n_batches):
    mods = dict(model.named_modules()); maxabs = {p: 0.0 for p in pcm_paths}; handles = []
    for p in pcm_paths:
        def hook(mod, inp, _p=p):
            v = inp[0].detach().abs().max().item()
            if v > maxabs[_p]: maxabs[_p] = v
        handles.append(mods[p].register_forward_pre_hook(hook))
    model.eval()
    with torch.no_grad():
        for b, (x, _) in enumerate(loader):
            model(x.to(device))
            if b + 1 >= n_batches: break
    for h in handles: h.remove()
    return {p: (maxabs[p] / 127.0 if maxabs[p] > 0 else 1.0) for p in pcm_paths}

@torch.no_grad()
def eval_loader(model, loader, device):
    c1 = c5 = tot = 0
    for x, y in loader:
        x = x.to(device); y = y.to(device); out = model(x)
        _, p5 = out.topk(5, 1, True, True); corr = p5.eq(y.view(-1, 1))
        c1 += corr[:, 0].sum().item(); c5 += corr.any(1).sum().item(); tot += y.size(0)
    return c1 / tot, c5 / tot

def build_arms_local(imc, ratios, device, budget):
    return {"uniform":     make_masks(imc, uniform_ratios(imc, budget), device),
            "layer_aware": make_masks(imc, ratios, device)}

import os, time

# Reference numbers from the main run (2000 imgs, 3 seeds, RTX PRO 6000), embedded at build time
REFERENCE = {'clean': 0.7645, 'noadc': {'none': {1.0: 0.061, 100.0: 0.030333333333333337, 10000.0: 0.0026666666666666666, 1000000.0: 0.0011666666666666668}, 'uniform': {1.0: 0.5456666666666666, 100.0: 0.5271666666666667, 10000.0: 0.4718333333333333, 1000000.0: 0.33466666666666667}, 'layer_aware': {1.0: 0.7203333333333334, 100.0: 0.7205, 10000.0: 0.7098333333333334, 1000000.0: 0.694}}, 'adc_post': {'none': {1.0: 0.0008333333333333334, 100.0: 0.0008333333333333334, 10000.0: 0.0008333333333333334, 1000000.0: 0.001}, 'uniform': {1.0: 0.7181666666666667, 100.0: 0.6971666666666666, 10000.0: 0.6491666666666667, 1000000.0: 0.644}, 'layer_aware': {1.0: 0.7278333333333333, 100.0: 0.7105, 10000.0: 0.6489999999999999, 1000000.0: 0.5245000000000001}}}

def build_arms3(imc, ratios, device, budget):
    return {"none":        make_masks(imc, none_ratios(imc), device),
            "uniform":     make_masks(imc, uniform_ratios(imc, budget), device),
            "layer_aware": make_masks(imc, ratios, device)}

def run_one(model, imc, loader, device, dt, act_scales, mask, t, seed, readout, adc_bits):
    nu = gen_nu(imc, 1000 + seed, device, dt) if t != 1.0 else None
    wn = gen_wn(imc, 5000 + seed, device, dt)
    comp = DRIFT_MEAN if t != 1.0 else 0.0
    mode = "imc_noadc" if readout == "noadc" else "imc"
    set_run_state(imc, act_scales, mask, nu, wn, t, adc_bits, comp, mode=mode)
    for m in imc.values():
        m.cfg["comp_pre"] = (readout == "adc_pre")
    return eval_loader(model, loader, device)

def clean_eval(model, imc, loader, device, dt, act_scales):
    full = {p: torch.ones(m.Wq2d.shape, dtype=torch.bool, device=device) for p, m in imc.items()}
    set_run_state(imc, act_scales, full, None, None, 1.0, None, 0.0, mode="imc_noadc")
    return eval_loader(model, loader, device)

def _load_or_init(outpath, meta):
    if os.path.exists(outpath):
        data = _json.load(open(outpath))
        for k in ["n_images", "subset_seed", "budget", "adc_bits"]:
            if data["meta"].get(k) != meta[k]:
                raise SystemExit(f"[resume guard] {outpath} was created with {k}="
                                 f"{data['meta'].get(k)} but this run uses {meta[k]}. "
                                 f"Use a different --out or delete the old file.")
        print(f"[resume] {outpath}: {len(data['rows'])} completed cells found, will skip them",
              flush=True)
        return data
    return {"meta": meta, "clean": None, "rows": []}

def _save(outpath, data):
    tmp = outpath + ".tmp"
    with open(tmp, "w") as f:
        _json.dump(data, f, indent=2)
    os.replace(tmp, outpath)

def main():
    from torchvision import models
    ap = argparse.ArgumentParser()
    ap.add_argument("--val_root", required=True)
    ap.add_argument("--out", default="final_imc_results.json")
    ap.add_argument("--n_images", type=int, default=2000)
    ap.add_argument("--subset_seed", type=int, default=42)
    ap.add_argument("--batch_size", type=int, default=64)
    ap.add_argument("--num_workers", type=int, default=4)
    ap.add_argument("--calib_batches", type=int, default=4)
    ap.add_argument("--seeds", type=int, default=3)
    ap.add_argument("--drift_grid", default="1,1e2,1e4,1e6")
    ap.add_argument("--budget", type=float, default=0.5)
    ap.add_argument("--adc_bits", type=int, default=5)
    ap.add_argument("--readouts", default="noadc,adc_pre",
                    help="comma list from: noadc, adc_pre")
    args = ap.parse_args()

    readouts = [r.strip() for r in args.readouts.split(",") if r.strip()]
    for r in readouts:
        if r not in ("noadc", "adc_pre"):
            raise SystemExit(f"unknown readout '{r}' (use noadc, adc_pre)")
    drift_grid = [float(s) for s in args.drift_grid.split(",")]
    arms_order = ["none", "uniform", "layer_aware"]

    device = "cuda" if torch.cuda.is_available() else "cpu"
    dt = torch.float32
    loader, nsub = imagenet_subset_loader(args.val_root, args.n_images, args.subset_seed,
                                          args.batch_size, args.num_workers)
    meta = {"n_images": nsub, "subset_seed": args.subset_seed, "budget": args.budget,
            "adc_bits": args.adc_bits, "seeds": args.seeds, "drift_grid": drift_grid,
            "readouts": readouts, "comp": "adc_pre = comp-aware ADC range (fs * t^-comp)",
            "write_noise": True}
    data = _load_or_init(args.out, meta)
    print(f"subset {nsub}  device {device}  budget {args.budget}  seeds {args.seeds}  "
          f"adc {args.adc_bits}-bit  drift {drift_grid}  readouts {readouts}", flush=True)

    model = models.resnet50(weights=models.ResNet50_Weights.IMAGENET1K_V1).eval().to(dt).to(device)
    pcm_paths = [n[:-len(".weight")] for n, _ in model.named_parameters() if is_pcm_weight(n)]
    print("calibrating activation scales ...", flush=True)
    act_scales = float_calibrate(model, pcm_paths, loader, device, args.calib_batches)
    imc = build_imc_resnet(model, device=device, dtype=dt)
    arms = build_arms3(imc, LAYER_AWARE_RATIOS, device, args.budget)

    if data["clean"] is None:
        a1, a5 = clean_eval(model, imc, loader, device, dt, act_scales)
        data["clean"] = {"top1": a1, "top5": a5}
        _save(args.out, data)
        rc = REFERENCE["clean"]
        print(f"[anchor] clean INT8 top1={a1*100:.1f}  (main-run reference {rc*100:.1f}; "
              f"should match closely)", flush=True)
    else:
        print(f"[anchor] clean INT8 top1={data['clean']['top1']*100:.1f} (from previous session)",
              flush=True)

    plan = [(ro, t, arm, s) for ro in readouts for t in drift_grid
            for arm in arms_order for s in range(args.seeds)]
    done = {(r["readout"], float(r["drift_t"]), r["arm"], int(r["seed"])) for r in data["rows"]}
    todo = [c for c in plan if c not in done]
    print(f"plan {len(plan)} cells | {len(plan)-len(todo)} done | {len(todo)} to run", flush=True)

    durs = {ro: [] for ro in readouts}
    for i, (ro, t, arm, s) in enumerate(todo):
        t0 = time.time()
        a1, a5 = run_one(model, imc, loader, device, dt, act_scales, arms[arm], t, s, ro,
                         args.adc_bits)
        el = time.time() - t0
        durs[ro].append(el)
        data["rows"].append({"readout": ro, "arm": arm, "drift_t": t, "seed": s,
                             "top1": a1, "top5": a5, "elapsed_sec": el})
        _save(args.out, data)
        rem = todo[i + 1:]
        eta = 0.0
        known = True
        for ro2 in durs:
            n_rem = sum(1 for c in rem if c[0] == ro2)
            if n_rem == 0:
                continue
            if durs[ro2]:
                eta += n_rem * (sum(durs[ro2]) / len(durs[ro2]))
            else:
                known = False
        eta_txt = f"ETA ~{eta/60:.0f} min" + ("" if known else " + next readout group")
        print(f"[{len(plan)-len(todo)+i+1}/{len(plan)}] {ro:8s} t={t:>9.0f} {arm:12s} seed={s} "
              f"top1={a1*100:5.1f} ({el:.0f}s)  {eta_txt}", flush=True)

    def cell(ro, arm, t):
        v = [r["top1"] for r in data["rows"]
             if r["readout"] == ro and r["arm"] == arm and float(r["drift_t"]) == t]
        if not v:
            return float("nan")
        return sum(v) / len(v) * 100

    for ro in readouts:
        refkey = "noadc" if ro == "noadc" else "adc_post"
        reflab = ("main-run no-ADC ref" if ro == "noadc"
                  else "main-run post-comp OLD readout (for contrast)")
        print(f"\n=== {ro}  top1 %, mean over {args.seeds} seeds, {nsub} imgs ===", flush=True)
        print(f"{'t':>9} {'none':>7} {'uniform':>8} {'layer_aware':>11} {'LA-uni':>7} "
              f"|  {reflab}: none/uni/LA")
        for t in drift_grid:
            n1 = cell(ro, "none", t); u1 = cell(ro, "uniform", t); l1 = cell(ro, "layer_aware", t)
            rf = REFERENCE.get(refkey, {})
            rtxt = "/".join((f"{rf.get(a, {}).get(t, float('nan'))*100:5.1f}").strip()
                            for a in arms_order)
            print(f"{t:>9.0f} {n1:7.1f} {u1:8.1f} {l1:11.1f} {l1-u1:+7.1f} |  {rtxt}")
    print(f"\nwrote {args.out}", flush=True)

if __name__ == "__main__":
    main()
