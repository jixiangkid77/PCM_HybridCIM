#!/usr/bin/env bash
# =============================================================================
# run_e3_rest.sh
#
# Purpose : Finish P2R-E3 after the G6 gate has passed. Runs, in order:
#             1. stage 1 ungated   (the new-Yosys baseline)
#             2. stage 2 gated     (dfflibmap + abc)
#             3. stage 2 ungated   (dfflibmap + abc)
#           then checks the G4, G7, G8 and G9 gates and prints the area
#           comparison that Reviewer 1 Comment 3 asks for.
#
# Do not run this until run_e3_stage1_gated.sh has reported G6 PASS.
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\   (WSL: /mnt/d/Project/hybrid_memory/paper2/scripts/)
# Status  : NEW FILE.
#
# Runtime : roughly 20 min + 40 min + 40 min. abc -liberty is the slow phase.
#           Each stage is a separate Yosys process, so memory restarts from
#           zero; the submitted-version single-process flow peaked at
#           23,533.51 MiB against a 24 GiB cap.
# =============================================================================
set -euo pipefail

PAPER2=/mnt/d/Project/hybrid_memory/paper2
YS=/home/kid/oss-cad-suite/bin/yosys
cd "$PAPER2"

if [ ! -f /home/kid/p2r_build/e3_gated_s1.rtlil ]; then
    echo "ERROR: stage 1 gated output missing. Run run_e3_stage1_gated.sh first." >&2
    exit 1
fi

run_stage () {   # $1 = script basename, $2 = log basename, $3 = human label
    echo
    echo "=============================================================="
    echo "$3"
    echo "start: $(date '+%F %T')"
    /usr/bin/time -v "$YS" -q -l "reports/$2.log" "scripts/$1" \
        2> "reports/$2_resource.txt" || {
            echo "FAILED. Last lines of the log:"; tail -30 "reports/$2.log"; exit 1; }
    echo "end:   $(date '+%F %T')"
    grep -E "Elapsed \(wall|Maximum resident" "reports/$2_resource.txt"
}

run_stage yosys_e3s1_ungated.ys e3_ungated_s1 "stage 1, ungated baseline"
run_stage yosys_e3s2_gated.ys   e3_gated_s2   "stage 2, gated"
run_stage yosys_e3s2_ungated.ys e3_ungated_s2 "stage 2, ungated"

echo
echo "=============================================================="
echo "G9: the simulation netlist and the STA netlist must be one design"
for V in gated ungated; do
    echo "-- $V"
    md5sum "reports/lenet5_top_${V}_netlist.v" "reports/lenet5_top_${V}_sta.v"
    A=$(grep -coE "sky130_fd_sc_hd__[a-z0-9_]+" "reports/lenet5_top_${V}_netlist.v" || true)
    B=$(grep -coE "sky130_fd_sc_hd__[a-z0-9_]+" "reports/lenet5_top_${V}_sta.v" || true)
    echo "   cell-line count: netlist=$A  sta=$B"
    [ "$A" = "$B" ] && echo "   G9 PASS" || echo "   G9 FAIL: the two netlists differ structurally"
done

echo
echo "=============================================================="
echo "G8: lpflow and probe cells must be gone (12,630 were present before)"
for V in gated ungated; do
    N=$(grep -coE "sky130_fd_sc_hd__(lpflow|probe)[a-z0-9_]*" "reports/lenet5_top_${V}_sta.v" || true)
    echo "   $V: $N   $([ "$N" -eq 0 ] && echo 'G8 PASS' || echo 'G8 FAIL')"
done

echo
echo "=============================================================="
echo "Area and cell count, for Reviewer 1 Comment 3"
for V in gated ungated; do
    echo "-- $V"
    grep -E "Number of cells|Chip area" "reports/e3_${V}_stat_final.txt" | tail -3
done
echo
echo "submitted version, Yosys 0.33: 1,263,370.42 um^2, 166,778 cells, 14,491 flops"

echo
echo "=============================================================="
echo "ICG cells in the final gated netlist"
grep -oE "sky130_fd_sc_hd__dlclkp_[0-9]+" "reports/lenet5_top_gated_sta.v" | sort | uniq -c || true

echo
echo "=============================================================="
echo "Flip-flop counts, gated vs ungated"
for V in gated ungated; do
    echo "-- $V"
    grep -oE "sky130_fd_sc_hd__[sd]df[a-z0-9_]+" "reports/lenet5_top_${V}_sta.v" | sort | uniq -c | sort -rn | head -6
done

echo
echo "E3 complete. Next: P2R-E4, the full-inference gate-level simulation of"
echo "both netlists, with predicted_class and cycle count required to match."
