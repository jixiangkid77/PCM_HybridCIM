"""
05_verify_baseline.py
=====================
Diagnostic script to measure the FP32 PyTorch baseline accuracy
of Model A and Model B on MNIST test set.

Purpose: determine whether Model B's low RTL accuracy (20%) is caused
by a quantization/RTL bug, or whether Model B itself is a weak model
at FP32 baseline.

Runs both models on the full MNIST test set (10,000 images) in pure
PyTorch, no quantization. If Model B shows ~99% like Model A, then
the RTL pipeline has a Model-B-specific bug. If Model B is already
weak at FP32, then the issue is in Paper 1's training.

Usage:
  python 05_verify_baseline.py

Output: FP32 accuracy for both models, plus confusion matrix for
class distribution to compare with RTL prediction distribution.
"""

import os
import sys
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader
from torchvision import datasets, transforms


# ============================================================
# LeNet-5 definition (MUST match 02_quantize_and_export.py exactly)
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
# Test one model
# ============================================================
def test_model(pth_path, variant_name, test_loader, device):
    print("=" * 60)
    print(f" Testing Model {variant_name}")
    print(f" Checkpoint : {pth_path}")
    print("=" * 60)

    if not os.path.exists(pth_path):
        print(f"ERROR: file not found: {pth_path}")
        return

    state_dict = torch.load(pth_path, map_location=device, weights_only=False)
    model = LeNet5().to(device)
    model.load_state_dict(state_dict)
    model.eval()

    correct = 0
    total = 0
    pred_counts = [0] * 10   # how many times each class was predicted

    with torch.no_grad():
        for x, y in test_loader:
            x = x.to(device)
            y = y.to(device)
            out = model(x)
            pred = out.argmax(dim=1)
            correct += (pred == y).sum().item()
            total += y.size(0)
            for p in pred.cpu().numpy():
                pred_counts[p] += 1

    acc = 100.0 * correct / total
    print(f"\n  FP32 Accuracy : {correct}/{total} = {acc:.2f}%")
    print(f"  Prediction distribution:")
    for c in range(10):
        print(f"    class {c}: {pred_counts[c]:5d}  ({100.0*pred_counts[c]/total:5.2f}%)")

    return acc, pred_counts


# ============================================================
# Main
# ============================================================
def main():
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    print(f"Using device: {device}\n")

    # Standard MNIST normalization (matches 02_quantize_and_export.py)
    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((0.1307,), (0.3081,))
    ])

    test_ds = datasets.MNIST(
        root='D:/Project/PCM_Research5/data',  # Paper 1 dataset location
        train=False,
        download=True,
        transform=transform
    )
    test_loader = DataLoader(test_ds, batch_size=1000, shuffle=False)
    print(f"MNIST test set: {len(test_ds)} images\n")

    # Paper 1 model paths
    paper1_dir = "D:/Project/PCM_Research5/outputs"
    model_a_path = os.path.join(paper1_dir, "Model_Baseline.pth")
    model_b_path = os.path.join(paper1_dir, "Model_Baseline_B.pth")

    results = {}
    results['A'] = test_model(model_a_path, "A", test_loader, device)
    print()
    results['B'] = test_model(model_b_path, "B", test_loader, device)

    # ================================================
    # Summary + diagnosis
    # ================================================
    print("\n" + "=" * 60)
    print(" SUMMARY")
    print("=" * 60)
    if results['A'] is not None and results['B'] is not None:
        acc_a, _ = results['A']
        acc_b, _ = results['B']
        print(f"  Model A FP32 baseline : {acc_a:.2f}%")
        print(f"  Model B FP32 baseline : {acc_b:.2f}%")
        print()
        if acc_b > 95:
            print("  DIAGNOSIS:")
            print("    Model B is healthy at FP32 (>95%).")
            print("    RTL's 20% accuracy for Model B therefore indicates")
            print("    a bug in the quantization pipeline or RTL handling")
            print("    of Model B's specific weight distribution.")
        elif acc_b < 50:
            print("  DIAGNOSIS:")
            print("    Model B is broken at FP32 baseline already.")
            print("    The .pth file likely contains an undertrained or")
            print("    corrupted model. Paper 1 training needs review.")
        else:
            print("  DIAGNOSIS:")
            print("    Model B is partially trained (50-95%).")
            print("    Quantization may be amplifying the issue.")

    print()


if __name__ == "__main__":
    main()
