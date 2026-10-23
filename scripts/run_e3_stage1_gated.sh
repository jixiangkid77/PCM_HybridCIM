#!/usr/bin/env bash
# =============================================================================
# run_e3_stage1_gated.sh
#
# Purpose : Run P2R-E3 stage 1 (gated) and evaluate the G6 gate, which decides
#           whether the rest of E3 is worth running.
#
# G6      : clockgate must group flip-flops that share an enable under a shared
#           ICG. If instead it emits roughly one ICG per flop, the transform has
#           degenerated: each ICG burns its own clock power, and gating can cost
#           more than it saves. The design has 14,237 enable-bearing flops, so
#           an ICG count anywhere near that number is the degenerate case.
#           Threshold: fewer than 2,000 ICGs.
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\   (WSL: /mnt/d/Project/hybrid_memory/paper2/scripts/)
# Status  : NEW FILE. Run after gen_e3_scripts.sh, from the paper2 directory.
#
# Runtime : about 20 minutes, peak memory about 23.5 GiB. Close other
#           applications first: the WSL cap is 24 GiB and the host has 31.5 GB.
# =============================================================================
set -euo pipefail

PAPER2=/mnt/d/Project/hybrid_memory/paper2
YS=/home/kid/oss-cad-suite/bin/yosys
G6_THRESHOLD=2000

cd "$PAPER2"

echo "=== P2R-E3 stage 1 (gated) ==="
echo "start: $(date '+%F %T')"
"$YS" -V

# -q keeps the terminal quiet; everything lands in the log file.
/usr/bin/time -v "$YS" -q -l reports/e3_gated_s1.log scripts/yosys_e3s1_gated.ys \
    2> reports/e3_gated_s1_resource.txt || {
        echo "Yosys failed. Last lines of the log:"
        tail -30 reports/e3_gated_s1.log
        exit 1
    }

echo "end:   $(date '+%F %T')"
echo
echo "=== resource usage ==="
grep -E "Elapsed|Maximum resident" reports/e3_gated_s1_resource.txt

echo
echo "=== ICG selection reported by clockgate ==="
grep -iE "clockgate|ICG|dlclkp" reports/e3_gated_s1.log | head -20

echo
echo "=== G6 gate ==="
ICG=$(grep -oE "sky130_fd_sc_hd__dlclkp_[0-9]+[[:space:]]+[0-9]+" \
      reports/e3_gated_stat_after_clockgate.txt \
      | awk '{s+=$2} END {print s+0}')
echo "ICG cells inserted : $ICG"
echo "enable-bearing FFs : 14237   (measured in P2R-E1-e)"
echo "G6 threshold       : $G6_THRESHOLD"
if [ "$ICG" -eq 0 ]; then
    echo "RESULT: NO ICG INSERTED. Stop and report; clockgate found nothing to group."
elif [ "$ICG" -lt "$G6_THRESHOLD" ]; then
    echo "RESULT: PASS. Grouping worked. Proceed to the ungated stage 1."
    echo "        ICG area cost: $(awk -v n="$ICG" 'BEGIN{printf "%.4f mm2 (%.2f%% of the 1.263 mm2 digital)", n*17.5168/1e6, 100*n*17.5168/1263370.42}')"
else
    echo "RESULT: FAIL. Grouping degenerated. Stop and report; -min_net_size needs tuning."
fi

echo
echo "=== cell count, before and after clockgate ==="
grep -E "Number of cells" reports/e3_gated_stat_after_synth.txt     | tail -1
grep -E "Number of cells" reports/e3_gated_stat_after_clockgate.txt | tail -1

echo
echo "=== enable flops remaining (should fall sharply) ==="
echo "-- after synth --"
grep -oE '\$_[A-Z]*DFFE?[A-Z_0-9]*_[[:space:]]+[0-9]+' reports/e3_gated_stat_after_synth.txt | head -12
echo "-- after clockgate --"
grep -oE '\$_[A-Z]*DFFE?[A-Z_0-9]*_[[:space:]]+[0-9]+' reports/e3_gated_stat_after_clockgate.txt | head -12
