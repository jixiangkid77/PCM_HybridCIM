"""
02_quantize_and_export.py
=========================

Step 2 of the LeNet-5 RTL pipeline.

This script is a ONE-WAY DATA CONVERTER: it takes Paper 1's trained
PyTorch model and converts it into hex files that the RTL simulation
will consume. PyTorch is used only for:
  (a) loading the already-trained .pth file
  (b) deterministic FP32->INT8 quantization (pure math, not inference)
  (c) writing hex files

PyTorch IS NOT used for running inference. All inference -- meaning the
computation of 10 classification scores from a 28x28 image -- happens
EXCLUSIVELY inside the RTL simulator (conv1 -> conv2 -> fc1 -> fc2
-> fc3 -> argmax, all in Verilog).

This matches Professor Namba's requirement exactly:
  "推論を、PyTorch を使わず、すべて RTLシミュレーションだけでやってください"

Evaluation protocol:
  - RTL reads weight hex files and image hex files
  - RTL computes predictions entirely in Verilog
  - Testbench compares RTL predictions against MNIST's ground-truth
    labels (NOT against PyTorch predictions).
  - Accuracy = correct_rtl_predictions / total_images.

Two models required (per professor's second instruction):
  "学習済みNNを2種類作って、それぞれについて検証用モジュールだけを
   変えて行ってください。回路本体の方は同じRTLを使うこと。"
  - Model A: D:\\Project\\PCM_Research5\\outputs\\Model_Baseline.pth
  - Model B: D:\\Project\\PCM_Research5\\outputs\\Model_Baseline_B.pth

Run this script TWICE with MODEL_VARIANT = "A" and then "B" to
produce two sets of hex files.

Outputs (written to paper2/data/rtl_inputs_{A|B}/):
  weights_conv1.hex, weights_conv2.hex, weights_fc1.hex,
  weights_fc2.hex, weights_fc3.hex    -- INT8 weights
  biases_all.hex                       -- INT32 biases, 236 concatenated
  rshift_per_layer.txt                 -- RSHIFT values for layer_desc_rom.v
  scales.txt                           -- calibration scales (debug info)
  images/img_001.hex .. img_100.hex    -- INT8 quantized MNIST images
  image_labels.txt                     -- MNIST ground-truth labels (0..9)

NOTE: image_labels.txt contains ONLY true MNIST labels.
      There is NO "PyTorch predicted class" file.
      The RTL testbench compares its own predictions to these
      ground-truth labels directly.

Usage:
  python 02_quantize_and_export.py A    # export Model A hex files
  python 02_quantize_and_export.py B    # export Model B hex files

Requires:
  pip install torch torchvision numpy
"""

import os
import sys
import math
import numpy as np

try:
    import torch
    import torch.nn as nn
    import torch.nn.functional as F
    from torch.utils.data import DataLoader
    from torchvision import datasets, transforms
except ImportError:
    sys.stderr.write("ERROR: PyTorch required.  pip install torch torchvision\n")
    sys.exit(1)


# ============================================================
# Configuration
# ============================================================

# Paths to Paper 1 models
MODEL_A_PATH = r"D:\Project\PCM_Research5\outputs\Model_Baseline.pth"
MODEL_B_PATH = r"D:\Project\PCM_Research5\outputs\Model_Baseline_B.pth"

# Output directory per variant
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

NUM_CALIB_IMAGES = 1000
NUM_TEST_IMAGES  = 100


# ============================================================
# LeNet-5 architecture (matches Paper 1 exactly)
# ============================================================
class LeNet5(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1,  6,  kernel_size=5, padding=2)
        self.conv2 = nn.Conv2d(6,  16, kernel_size=5, padding=0)
        self.fc1   = nn.Linear(400, 120)
        self.fc2   = nn.Linear(120, 84)
        self.fc3   = nn.Linear(84,  10)

    def forward(self, x):
        x = F.relu(self.conv1(x))
        x = F.max_pool2d(x, 2)
        x = F.relu(self.conv2(x))
        x = F.max_pool2d(x, 2)
        x = x.view(x.size(0), -1)
        x = F.relu(self.fc1(x))
        x = F.relu(self.fc2(x))
        x = self.fc3(x)
        return x


# ============================================================
# Load Paper 1 model (REFUSE to train)
# ============================================================
def load_paper1_model(model_path, device):
    if not os.path.exists(model_path):
        print("=" * 68)
        print("ERROR: Paper 1 model not found.")
        print(f"  Expected: {model_path}")
        print("  This script will NEVER train a new model.")
        print("  Paper 2 must use the same trained weights as Paper 1.")
        print("=" * 68)
        sys.exit(2)

    print(f"[INFO] Loading Paper 1 model: {model_path}")
    model = LeNet5().to(device)

    try:
        state = torch.load(model_path, map_location=device, weights_only=True)
    except TypeError:
        state = torch.load(model_path, map_location=device)

    model.load_state_dict(state)
    model.eval()

    expected = {
        "conv1.weight": (6, 1, 5, 5),
        "conv2.weight": (16, 6, 5, 5),
        "fc1.weight":   (120, 400),
        "fc2.weight":   (84, 120),
        "fc3.weight":   (10, 84),
    }
    for key, shape in expected.items():
        actual = tuple(state[key].shape)
        if actual != shape:
            print(f"ERROR: {key} shape {actual} != {shape}")
            sys.exit(3)
    print("[INFO] Model loaded, architecture verified.")
    return model


# ============================================================
# Activation scale calibration
# Used only to DERIVE the scale factors for quantization.
# It is NOT an inference run whose outputs are used elsewhere.
# ============================================================
class ActivationCollector:
    def __init__(self):
        self.maxabs = {}

    def hook(self, name):
        def fn(module, inp, out):
            v = out.detach().abs().max().item()
            if name not in self.maxabs or v > self.maxabs[name]:
                self.maxabs[name] = v
        return fn


def calibrate(model, device):
    print(f"[INFO] Calibrating on {NUM_CALIB_IMAGES} training images...")
    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((0.1307,), (0.3081,))
    ])
    calib_ds = datasets.MNIST("./_mnist", train=True, download=True, transform=transform)

    collector = ActivationCollector()
    handles = [
        model.conv1.register_forward_hook(collector.hook("conv1_out")),
        model.conv2.register_forward_hook(collector.hook("conv2_out")),
        model.fc1.register_forward_hook(collector.hook("fc1_out")),
        model.fc2.register_forward_hook(collector.hook("fc2_out")),
        model.fc3.register_forward_hook(collector.hook("fc3_out")),
    ]

    input_maxabs = 0.0
    with torch.no_grad():
        for i in range(NUM_CALIB_IMAGES):
            x, _ = calib_ds[i]
            x = x.unsqueeze(0).to(device)
            input_maxabs = max(input_maxabs, x.abs().max().item())
            _ = model(x)  # forward pass for activation range stats only

    for h in handles:
        h.remove()

    scales = {
        "input":  input_maxabs / 127.0,
        "conv1":  collector.maxabs["conv1_out"] / 127.0,
        "conv2":  collector.maxabs["conv2_out"] / 127.0,
        "fc1":    collector.maxabs["fc1_out"]   / 127.0,
        "fc2":    collector.maxabs["fc2_out"]   / 127.0,
        "fc3":    collector.maxabs["fc3_out"]   / 127.0,
    }
    print("[INFO] Activation scales derived:")
    for k, v in scales.items():
        print(f"         {k:8s} : {v:.6f}")
    return scales


# ============================================================
# Quantization helpers
# ============================================================
def quantize_weight(tensor):
    w = tensor.detach().cpu().numpy().astype(np.float32)
    maxabs = float(np.abs(w).max())
    if maxabs == 0:
        return np.zeros_like(w, dtype=np.int8), 1.0
    scale = maxabs / 127.0
    q = np.round(w / scale).clip(-128, 127).astype(np.int8)
    return q, scale


def compute_rshift(scale_act_in, scale_weight, scale_act_out):
    ratio = (scale_act_in * scale_weight) / scale_act_out
    if ratio <= 0:
        return 0
    rshift = round(-math.log2(ratio))
    return max(0, min(31, rshift))


# ============================================================
# Writers
# ============================================================
def write_hex_bytes(path, data, label=""):
    with open(path, "w") as f:
        for v in data:
            f.write(f"{int(v) & 0xFF:02x}\n")
    print(f"[OUT] {label:20s} -> {len(data)} bytes")


def write_hex_int32(path, data, label=""):
    with open(path, "w") as f:
        for v in data:
            f.write(f"{int(v) & 0xFFFFFFFF:08x}\n")
    print(f"[OUT] {label:20s} -> {len(data)} int32s")


# ============================================================
# MAIN
# ============================================================
def main():
    # Parse CLI
    if len(sys.argv) < 2 or sys.argv[1] not in ("A", "B"):
        print("Usage: python 02_quantize_and_export.py {A|B}")
        print("  A -> Model_Baseline.pth (Paper 1 main baseline)")
        print("  B -> Model_Baseline_B.pth (second model for prof's requirement)")
        sys.exit(1)

    variant = sys.argv[1]
    model_path = MODEL_A_PATH if variant == "A" else MODEL_B_PATH
    out_dir = os.path.abspath(os.path.join(
        SCRIPT_DIR, "..", "data", f"rtl_inputs_{variant}"))
    img_dir = os.path.join(out_dir, "images")

    os.makedirs(out_dir, exist_ok=True)
    os.makedirs(img_dir, exist_ok=True)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"[INFO] Variant: Model {variant}")
    print(f"[INFO] Using device: {device}")
    print(f"[INFO] Output dir: {out_dir}")
    print()

    model = load_paper1_model(model_path, device)
    scales = calibrate(model, device)

    # Quantize weights + biases
    layer_specs = [
        ("conv1", model.conv1.weight, model.conv1.bias, scales["input"], scales["conv1"]),
        ("conv2", model.conv2.weight, model.conv2.bias, scales["conv1"], scales["conv2"]),
        ("fc1",   model.fc1.weight,   model.fc1.bias,   scales["conv2"], scales["fc1"]),
        ("fc2",   model.fc2.weight,   model.fc2.bias,   scales["fc1"],   scales["fc2"]),
        ("fc3",   model.fc3.weight,   model.fc3.bias,   scales["fc2"],   scales["fc3"]),
    ]

    rshifts = []
    all_biases = []

    print()
    for name, w, b, s_in, s_out in layer_specs:
        qw, s_w = quantize_weight(w)
        write_hex_bytes(
            os.path.join(out_dir, f"weights_{name}.hex"),
            qw.flatten(),
            label=f"weights_{name}"
        )
        rshift = compute_rshift(s_in, s_w, s_out)
        rshifts.append((name, rshift, s_w))
        print(f"      scale_w={s_w:.6f}  RSHIFT={rshift}")

        b_np = b.detach().cpu().numpy().astype(np.float32)
        b_int32 = np.round(b_np / (s_in * s_w)).astype(np.int32)
        all_biases.extend(b_int32.tolist())

    with open(os.path.join(out_dir, "rshift_per_layer.txt"), "w") as f:
        f.write(f"# Model {variant} requantization shifts\n")
        f.write("# Copy into layer_desc_rom.v\n")
        for name, rs, sw in rshifts:
            f.write(f"{name}  RSHIFT={rs}   scale_w={sw:.6f}\n")
    print("[OUT] rshift_per_layer.txt")

    with open(os.path.join(out_dir, "scales.txt"), "w") as f:
        f.write(f"# Model {variant} activation scales (max_abs/127)\n")
        for k, v in scales.items():
            f.write(f"{k:8s}  {v:.6f}\n")
    print("[OUT] scales.txt")

    write_hex_int32(
        os.path.join(out_dir, "biases_all.hex"),
        all_biases,
        label="biases_all"
    )

    # ============================================================
    # Export test images + GROUND-TRUTH LABELS (NOT pytorch preds)
    # ============================================================
    print(f"\n[INFO] Exporting {NUM_TEST_IMAGES} MNIST images + true labels...")
    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((0.1307,), (0.3081,))
    ])
    test_ds = datasets.MNIST("./_mnist", train=False, download=True, transform=transform)

    labels = []
    for i in range(NUM_TEST_IMAGES):
        x, y = test_ds[i]
        x_np = x.numpy().astype(np.float32)
        x_int8 = np.round(x_np / scales["input"]).clip(-128, 127).astype(np.int8)

        img_path = os.path.join(img_dir, f"img_{i+1:03d}.hex")
        with open(img_path, "w") as f:
            for v in x_int8.flatten():
                f.write(f"{int(v) & 0xFF:02x}\n")
        labels.append((i+1, y))

    print(f"[OUT] {NUM_TEST_IMAGES} images -> {img_dir}")

    with open(os.path.join(out_dir, "image_labels.txt"), "w") as f:
        f.write("# MNIST ground-truth labels (0..9) for images 1..100\n")
        f.write("# Format: img_NNN  true_class\n")
        f.write("# These are the GROUND TRUTH labels from the MNIST dataset.\n")
        f.write("# NOT PyTorch predictions. The RTL testbench compares its\n")
        f.write("# own predictions against these labels to measure accuracy.\n")
        for idx, y in labels:
            f.write(f"img_{idx:03d}  {y}\n")
    print(f"[OUT] image_labels.txt ({NUM_TEST_IMAGES} ground-truth labels)")

    # Also a hex-only version of labels for easy $readmemh
    with open(os.path.join(out_dir, "image_labels.hex"), "w") as f:
        for idx, y in labels:
            f.write(f"{y:02x}\n")
    print(f"[OUT] image_labels.hex (hex format for $readmemh)")

    print()
    print("=" * 68)
    print(f"  Model {variant} export complete.")
    print("=" * 68)
    print(f"  Weights, biases, images, and GROUND-TRUTH labels are ready.")
    print(f"  Output: {out_dir}")
    print()
    print("  Next: run RTL simulation. RTL will read these hex files,")
    print("        perform ALL of conv1/conv2/fc1/fc2/fc3 computation in")
    print("        Verilog, and produce 10 classification scores per image.")
    print("        Testbench will compute RTL accuracy = correct/100.")
    print()
    print("  PyTorch is NOT involved in the RTL accuracy evaluation.")
    print()
    if variant == "A":
        print("  When done with Model A, run again with argument B:")
        print("    python 02_quantize_and_export.py B")


if __name__ == "__main__":
    main()
