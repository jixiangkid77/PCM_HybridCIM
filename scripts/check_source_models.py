#!/usr/bin/env python3
"""Check that the trained models and protection ratios in data/source_models/ give the RTL inputs.

Model A is Model_Baseline.pth with LayerAware_Ratios.json, model B is
Model_Baseline_B.pth with LayerAware_Ratios_B.json. For each model, against
data/rtl_inputs_<A|B>/:
  1. the INT8 weights, quantized per tensor as scripts/02_quantize_and_export.py
     does (scale max|w|/127, round, clip to [-128, 127]), against weights_<layer>.hex;
  2. the weight scales and right shifts against rshift_per_layer.txt;
  3. the INT32 biases, quantized with the activation scales recorded in scales.txt,
     against biases_all.hex (the activation scales themselves come from the calibration
     on MNIST images in scripts/02_quantize_and_export.py and are taken as recorded;
     so are they for the right shifts of step 2);
  4. the protection split of scripts/03_split_protected.py (split_layer) with the
     ratios, against idx_<layer>_sram.hex, idx_<layer>_pcm.hex and split_summary.json.
The .pth files are read without PyTorch: a .pth is a zip archive, and the
unpickler here accepts only tensors and an OrderedDict.

Usage: python3 scripts/check_source_models.py [--paper2 REPO_ROOT]
"""
import argparse
import collections
import contextlib
import importlib.util
import io
import json
import math
import os
import pickle
import sys
import zipfile

import numpy as np

LAYERS = ("conv1", "conv2", "fc1", "fc2", "fc3")
PREV = {"conv1": "input", "conv2": "conv1", "fc1": "conv2", "fc2": "fc1", "fc3": "fc2"}
MODELS = (("A", "Model_Baseline.pth", "LayerAware_Ratios.json"),
          ("B", "Model_Baseline_B.pth", "LayerAware_Ratios_B.json"))


def load_pth(path):
    z = zipfile.ZipFile(path)
    root = z.namelist()[0].split("/")[0]
    dtypes = {"FloatStorage": np.float32, "LongStorage": np.int64}

    def rebuild_tensor_v2(storage, offset, size, stride, requires_grad, hooks, *rest):
        n = int(np.prod(size)) if size else 1
        a = storage[offset:offset + n]
        return a.reshape(size) if size else a.reshape(())

    class Unpickler(pickle.Unpickler):
        def find_class(self, mod, name):
            if (mod, name) == ("torch._utils", "_rebuild_tensor_v2"):
                return rebuild_tensor_v2
            if mod == "torch" and name in dtypes:
                return name
            if (mod, name) == ("collections", "OrderedDict"):
                return collections.OrderedDict
            raise pickle.UnpicklingError(f"refused {mod}.{name}")

        def persistent_load(self, pid):
            typ, storage_type, key, location, numel = pid
            assert typ == "storage"
            raw = z.read(f"{root}/data/{key}")
            return np.frombuffer(raw, dtype=np.dtype(dtypes[storage_type]).newbyteorder("<")).copy()

    with z.open(f"{root}/data.pkl") as fh:
        return Unpickler(fh).load()


def read_hex(path, bits=None):
    """One hex value per line; two's complement of the given width, or unsigned if bits is None."""
    vals = [int(x, 16) for x in open(path).read().split()]
    if bits is not None:
        vals = [v - (1 << bits) if v >= (1 << (bits - 1)) else v for v in vals]
    return np.array(vals, dtype=np.int64)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paper2", default=".", help="repository root")
    a = ap.parse_args()
    root = a.paper2
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("split03", os.path.join(root, "scripts", "03_split_protected.py"))
    split03 = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(split03)

    ok = True
    for tag, pth, ratios_name in MODELS:
        src = os.path.join("data", "source_models")
        rtl = os.path.join(root, "data", f"rtl_inputs_{tag}")
        sd = load_pth(os.path.join(root, src, pth))
        ratios = {k.replace(".weight", ""): v for k, v in json.load(open(os.path.join(root, src, ratios_name))).items()}
        print(f"Model {tag}: {src}/{pth}, {src}/{ratios_name} -> data/rtl_inputs_{tag}/")
        print("   tensors: " + ", ".join(f"{k} {tuple(v.shape)}" for k, v in sd.items()))
        act = {}
        for line in open(os.path.join(rtl, "scales.txt")):
            if not line.startswith("#"):
                k, v = line.split()
                act[k] = float(v)
        shifts = {}
        for line in open(os.path.join(rtl, "rshift_per_layer.txt")):
            if not line.startswith("#"):
                f = line.split()
                shifts[f[0]] = (int(f[1].split("=")[1]), f[2].split("=")[1])
        summary = json.load(open(os.path.join(rtl, "split_summary.json")))
        biases = []
        n_prot = 0
        for L in LAYERS:
            w = sd[f"{L}.weight"].astype(np.float32)
            s_w = float(np.abs(w).max()) / 127.0
            q = np.round(w / s_w).clip(-128, 127).astype(np.int8).flatten()
            same_w = bool((q.astype(np.int64) == read_hex(os.path.join(rtl, f"weights_{L}.hex"), 8)).all())
            rs = max(0, min(31, round(-math.log2((act[PREV[L]] * s_w) / act[L]))))
            same_s = shifts[L] == (rs, f"{s_w:.6f}")
            b = sd[f"{L}.bias"].astype(np.float32)
            biases += np.round(b / (act[PREV[L]] * s_w)).astype(np.int32).tolist()
            with contextlib.redirect_stdout(io.StringIO()):
                r = split03.split_layer(q, ratios[L], L)
            idx_s = read_hex(os.path.join(rtl, f"idx_{L}_sram.hex")).tolist()
            idx_p = read_hex(os.path.join(rtl, f"idx_{L}_pcm.hex")).tolist()
            same_x = list(map(int, r["sram_idx"])) == idx_s and list(map(int, r["pcm_idx"])) == idx_p
            same_x &= summary["layers"][L]["ratio"] == ratios[L] and summary["layers"][L]["n_sram"] == r["n_sram"]
            n_prot += r["n_sram"]
            ok &= same_w and same_s and same_x
            print(f"   {L:5s}: {q.size:>5} weights {'identical' if same_w else 'DIFFERENT'}; scale_w {s_w:.6f}, "
                  f"RSHIFT {rs} {'identical' if same_s else 'DIFFERENT'}; ratio {ratios[L]:.6f}, "
                  f"{r['n_sram']:>5} protected, index lists and summary {'identical' if same_x else 'DIFFERENT'}")
        same_b = biases == read_hex(os.path.join(rtl, "biases_all.hex"), 32).tolist()
        ok &= same_b
        print(f"   biases: {len(biases)} {'identical' if same_b else 'DIFFERENT'}; protected weights in total: {n_prot}")
    print("ALL IDENTICAL" if ok else "MISMATCH")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
