#!/usr/bin/env bash
# =============================================================================
# run_e3b.sh
#
# Purpose : Run P2R-E3 for variants U2 and B, four Yosys stages in all, then
#           print the raw figures needed to judge them. No parsing of tool
#           output beyond selecting whole lines; the numbers are read by eye.
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\   (WSL: /mnt/d/Project/hybrid_memory/paper2/scripts/)
# Status  : NEW FILE. Run after gen_e3b_scripts.sh.
# Runtime : about 10 minutes per stage 1 and under a minute per stage 2, so
#           roughly 20 minutes in total. Stage 1 peaked at 12.96 GiB for the
#           earlier variants; close other applications.
# =============================================================================
set -uo pipefail

PAPER2=/mnt/d/Project/hybrid_memory/paper2
YS=/home/kid/oss-cad-suite/bin/yosys
cd "$PAPER2"

run_stage () {   # $1 = script basename, $2 = log basename, $3 = label
    echo
    echo "=============================================================="
    echo "$3"
    echo "start: $(date '+%F %T')"
    /usr/bin/time -v "$YS" -q -l "reports/$2.log" "scripts/$1" \
        2> "reports/$2_resource.txt"
    echo "yosys exit status: $?"
    echo "end:   $(date '+%F %T')"
    grep -E "Elapsed \(wall|Maximum resident" "reports/$2_resource.txt"
}

run_stage yosys_e3s1_u2.ys e3_u2_s1 "stage 1, U2 (transform only, no gating)"
run_stage yosys_e3s1_b.ys  e3_b_s1  "stage 1, B  (transform plus gating)"
run_stage yosys_e3s2_u2.ys e3_u2_s2 "stage 2, U2"
run_stage yosys_e3s2_b.ys  e3_b_s2  "stage 2, B"

echo
echo "=============================================================="
echo "RAW: gating cells reported during stage 1 of B"
grep -i "clockgate\|ICG\|Selected" reports/e3_b_s1.log | head
echo
echo "RAW: design-wide block after the transform and after gating, variant B"
tail -40 reports/e3_b_stat_after_transform.txt
echo "---- after clockgate ----"
tail -40 reports/e3_b_stat_after_clockgate.txt

echo
echo "=============================================================="
echo "RAW: final area line, all four variants"
for V in ungated gated u2 b; do
  printf '%-8s ' "$V"
  grep "Chip area for top module" "reports/e3_${V}_stat_final.txt" 2>&1 | tail -1
done
echo "submitted version, Yosys 0.33: 1263370.42 um^2"

echo
echo "=============================================================="
echo "RAW: sequential cells and gating cells in each final netlist"
for V in ungated gated u2 b; do
  echo "---- $V"
  grep -oE "sky130_fd_sc_hd__(s?e?df[a-z0-9_]+|dlclkp_[0-9]+)" "reports/lenet5_top_${V}_sta.v" 2>&1 \
    | sort | uniq -c | sort -rn
done

echo
echo "=============================================================="
echo "RAW: the two netlists of each variant must be one design"
for V in u2 b; do
  echo "---- $V"
  A=$(grep -c "sky130_fd_sc_hd__" "reports/lenet5_top_${V}_netlist.v")
  B=$(grep -c "sky130_fd_sc_hd__" "reports/lenet5_top_${V}_sta.v")
  echo "   cell lines: netlist=$A  sta=$B"
  echo "   lpflow or probe cells remaining: $(grep -c "sky130_fd_sc_hd__\(lpflow\|probe\)" "reports/lenet5_top_${V}_sta.v")"
done

echo
echo "=============================================================="
echo "Reference: 14,488 flip-flops, of which 14,224 carry an enable."
echo "Probing predicted 241 gating cells and a projected B area near"
echo "1.038 mm2 against 1.176 mm2 for U1."
