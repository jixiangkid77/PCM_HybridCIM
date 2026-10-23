#!/usr/bin/env python3
"""
gen_pred_batch_v3.py

Run the RTL-equivalent full LeNet-5 pipeline on N images and
produce:

  1. golden_preds_<M>_imgs1-N.hex
       N lines, one byte each (00..09), = the model's predicted
       class for each image. Used by tb_lenet5_batch_inference_v3.v
       as the hard-match reference (golden compare).

  2. console report per image:
       img_NNN: pred=X  true=Y  match (or *MISS*)

  3. summary:
       Total / golden vs true accuracy

Pipeline is imported from gen_full_golden_v3.py to keep the
RTL-equivalence rules in one place.
"""

import argparse
import os
import sys
import importlib.util


# Dynamically import gen_full_golden_v3.py to reuse its pipeline
def _import_gen_full(script_dir):
    spec_path = os.path.join(script_dir, "gen_full_golden_v3.py")
    spec = importlib.util.spec_from_file_location("gen_full", spec_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def parse_label_file(path):
    """Returns {image_id_int: true_label_int}."""
    labels = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            # Format: "img_NNN  true_class"
            parts = line.split()
            if len(parts) < 2:
                continue
            try:
                img_id = int(parts[0].replace("img_", "").lstrip("0") or "0")
                true_lbl = int(parts[1])
                labels[img_id] = true_lbl
            except ValueError:
                continue
    return labels


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--src-dir", required=True,
                        help="Directory with weights_*.hex, biases_all.hex, rshift_per_layer.hex")
    parser.add_argument("--image-dir", required=True,
                        help="Directory containing img_NNN.hex files")
    parser.add_argument("--label-file", required=True,
                        help="image_labels.txt (img_NNN  class)")
    parser.add_argument("--n", type=int, required=True,
                        help="Number of images (run img_001 .. img_N)")
    parser.add_argument("--out", required=True,
                        help="Output hex path (one byte per image)")
    parser.add_argument("--model-tag", required=True, help="A or B")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    gen_full = _import_gen_full(script_dir)

    print(f"gen_pred_batch_v3   (model {args.model_tag}, N={args.n})")
    print(f"  src dir   : {args.src_dir}")
    print(f"  image dir : {args.image_dir}")
    print(f"  labels    : {args.label_file}")
    print(f"  out       : {args.out}")
    print()

    # ---- Load RTL data ONCE ----
    weights_c1 = gen_full.read_hex_bytes(os.path.join(args.src_dir, "weights_conv1.hex"))
    weights_c2 = gen_full.read_hex_bytes(os.path.join(args.src_dir, "weights_conv2.hex"))
    weights_f1 = gen_full.read_hex_bytes(os.path.join(args.src_dir, "weights_fc1.hex"))
    weights_f2 = gen_full.read_hex_bytes(os.path.join(args.src_dir, "weights_fc2.hex"))
    weights_f3 = gen_full.read_hex_bytes(os.path.join(args.src_dir, "weights_fc3.hex"))
    biases_all = gen_full.read_hex_words(os.path.join(args.src_dir, "biases_all.hex"))
    rshift_all = gen_full.read_hex_words(
        os.path.join(args.src_dir, "rshift_per_layer.hex"), width_bits=8)

    b_c1 = biases_all[0:6]
    b_c2 = biases_all[6:22]
    b_f1 = biases_all[22:142]
    b_f2 = biases_all[142:226]
    b_f3 = biases_all[226:236]
    rs_c1, rs_c2, rs_f1, rs_f2, rs_f3 = rshift_all[0:5]

    labels = parse_label_file(args.label_file)
    if len(labels) < args.n:
        print(f"WARNING: label file has {len(labels)} entries, need {args.n}")

    # ---- Loop over N images ----
    predictions = []
    correct_count = 0
    miss_count = 0
    pos_sat_total = 0
    neg_sat_total = 0
    trunc_wrap_total = 0
    shifted_min_all = float('inf')
    shifted_max_all = float('-inf')

    for img_id in range(1, args.n + 1):
        img_path = os.path.join(args.image_dir, f"img_{img_id:03d}.hex")
        if not os.path.exists(img_path):
            print(f"img_{img_id:03d}: MISSING ({img_path})")
            sys.exit(2)
        image = gen_full.read_hex_bytes(img_path, signed=True)
        if len(image) != 784:
            print(f"img_{img_id:03d}: wrong size {len(image)}")
            sys.exit(2)

        # Full pipeline
        c1 = gen_full.conv_layer(image, 28, 28, 1, weights_c1, b_c1, rs_c1,
                                  28, 28, 6, 5, 2)
        p1 = gen_full.pool_layer(c1, 28, 28, 6)
        c2 = gen_full.conv_layer(p1, 14, 14, 6, weights_c2, b_c2, rs_c2,
                                  10, 10, 16, 5, 0)
        p2 = gen_full.pool_layer(c2, 10, 10, 16)
        f1 = gen_full.fc_layer_relu(p2, weights_f1, b_f1, rs_f1)
        f2 = gen_full.fc_layer_relu(f1, weights_f2, b_f2, rs_f2)
        f3, diag = gen_full.fc_layer_fc3(f2, weights_f3, b_f3, rs_f3)
        pred = gen_full.argmax10_strict(f3)

        true_lbl = labels.get(img_id, -1)
        match_str = ""
        if true_lbl < 0:
            match_str = " (no label)"
        elif pred == true_lbl:
            correct_count += 1
            match_str = " match"
        else:
            miss_count += 1
            match_str = " *MISS*"

        # Aggregate saturation diagnostics
        pos_sat_total    += diag['pos_sat']
        neg_sat_total    += diag['neg_sat']
        trunc_wrap_total += diag['truncation_wrap']
        if diag['shifted_min'] < shifted_min_all: shifted_min_all = diag['shifted_min']
        if diag['shifted_max'] > shifted_max_all: shifted_max_all = diag['shifted_max']

        print(f"  img_{img_id:03d}: pred={pred}  true={true_lbl}{match_str}")
        predictions.append(pred)

    # ---- Write golden hex ----
    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w") as f:
        for p in predictions:
            f.write(f"{p:02x}\n")

    print()
    print(f"  wrote {len(predictions)} entries to {args.out}")
    print()
    print(f"  Summary (model {args.model_tag}, N={args.n}):")
    print(f"    Accuracy (vs true labels) : {correct_count}/{args.n} "
          f"({100.0 * correct_count / args.n:.1f}%)")
    print(f"    Misclassifications        : {miss_count}/{args.n}")
    print()
    print(f"  fc3 saturation diagnostics across {args.n} images:")
    print(f"    shifted range          : [{shifted_min_all}, {shifted_max_all}]")
    print(f"    positive sat triggered : {pos_sat_total} times")
    print(f"    negative sat triggered : {neg_sat_total} times")
    print(f"    truncation-wrap region : {trunc_wrap_total} times")
    if trunc_wrap_total > 0:
        print("    *** WARNING: at least one image triggered fc3 truncation-wraparound. ***")


if __name__ == "__main__":
    main()
