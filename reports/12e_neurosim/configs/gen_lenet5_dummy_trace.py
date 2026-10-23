#!/usr/bin/env python3
"""
Generate dummy LeNet-5 trace for NeuroSim smoke test.

Layer specs match NetWork_LeNet5.csv (5 weight layers).
Outputs:
  ~/NeuroSim/Inference_pytorch/layer_record_LeNet5/
    weightConv0_.csv, inputConv0_.csv  (conv1)
    weightConv1_.csv, inputConv1_.csv  (conv2)
    weightFC0_.csv,   inputFC0_.csv    (fc1)
    weightFC1_.csv,   inputFC1_.csv    (fc2)
    weightFC2_.csv,   inputFC2_.csv    (fc3)
    trace_command.sh
"""
import numpy as np
import os
import sys

# (name, Hin, Win, Cin, kH, kW, Cout, pool, is_fc)
LAYERS = [
    ('Conv0', 32, 32, 1,   5, 5, 6,   pool:=1, False),
    ('Conv1', 16, 16, 6,   5, 5, 16,  1, False),
    ('FC0',   1,  1,  400, 1, 1, 120, 0, True),
    ('FC1',   1,  1,  120, 1, 1, 84,  0, True),
    ('FC2',   1,  1,  84,  1, 1, 10,  0, True),
]
WEIGHT_BIT = 8
ACT_BIT = 8

OUT_DIR = os.path.expanduser('~/NeuroSim/Inference_pytorch/layer_record_LeNet5')
os.makedirs(OUT_DIR, exist_ok=True)

rng = np.random.RandomState(42)
trace_files = []
print(f'Writing to {OUT_DIR}')
print()

for layer in LAYERS:
    name, Hin, Win, Cin, kH, kW, Cout, pool, is_fc = layer
    wrows = kH * kW * Cin  # fan-in
    wcols = Cout            # fan-out
    
    # === Weight CSV: float [-1, +1], INT8 quantized ===
    w = rng.uniform(-1.0, 1.0 - 1/128, size=(wrows, wcols))
    w = np.round(w * 128) / 128   # quantize to 1/128 step
    wpath = os.path.join(OUT_DIR, f'weight{name}_.csv')
    with open(wpath, 'w') as f:
        for row in w:
            f.write(','.join(f'{v:10.5f}' for v in row) + '\n')
    
    # === Input CSV: bit-serial binary ===
    n_spatial = Hin * Win
    icols = n_spatial * ACT_BIT
    bits = rng.randint(0, 2, size=(wrows, icols)).astype(np.uint8)
    ipath = os.path.join(OUT_DIR, f'input{name}_.csv')
    with open(ipath, 'w') as f:
        for row in bits:
            f.write(','.join(str(v) for v in row) + '\n')
    
    fc_size_mb = (os.path.getsize(wpath) + os.path.getsize(ipath)) / (1024*1024)
    print(f'  {name:6s} ({"FC" if is_fc else "Conv"}): weight {wrows}×{wcols}, input {wrows}×{icols}  ({fc_size_mb:.2f} MB)')
    trace_files.append((f'weight{name}_.csv', f'input{name}_.csv'))

# === trace_command.sh ===
cmd_path = os.path.join(OUT_DIR, 'trace_command.sh')
cmd = f'./NeuroSIM/main ./NeuroSIM/NetWork_LeNet5.csv {WEIGHT_BIT} {ACT_BIT}'
for w, i in trace_files:
    cmd += f' ./layer_record_LeNet5/{w} ./layer_record_LeNet5/{i}'
with open(cmd_path, 'w') as f:
    f.write(cmd + '\n')
os.chmod(cmd_path, 0o755)

print()
print(f'  trace_command.sh: {cmd_path}')
print()
print('Done. Run smoke from ~/NeuroSim/Inference_pytorch:')
print(f'  bash ./layer_record_LeNet5/trace_command.sh')
