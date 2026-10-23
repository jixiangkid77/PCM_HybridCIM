#!/usr/bin/env bash
# =============================================================================
# gen_e3b_scripts.sh
#
# Purpose : Generate the P2R-E3 scripts for the two remaining variants,
#           U2 and B. Nothing is run; the four .ys files are written and
#           printed. gen_e3_scripts.sh and the U1 and A results it produced
#           are untouched.
#
#   U2 : the flip-flop transform without clock gating. This is the control
#        that separates the effect of the transform from the effect of the
#        gating, so that the difference between B and U1 is not credited to
#        gating when part of it belongs to the transform.
#   B  : the same transform followed by the standard clock-gating pass.
#
# The transform asks the legalization pass to target the synchronous-reset
# cell in which the clock enable takes priority over the reset. The pass
# rewrites the enable as the original enable or the active reset, which makes
# the reset unconditional and the cell eligible for clock gating. Probing
# showed the enable is preserved and no multiplexers are added; the plain
# route, which removes the sync-reset cell from the target list, unmaps the
# enable as well and adds 26,905 multiplexers for no gain.
#
# opt_expr, opt_merge and opt_clean run between the transform and the gating.
# The transform emits one enable gate per flip-flop, so flops that share an
# enable land on separate nets and the gating pass, which groups by net,
# produces one clock-gating cell each. Merging and cleaning collapses those
# nets: probing gave 13,415 gating cells without the cleanup and 241 with it,
# from two independent transforms. opt_dff is deliberately excluded, since it
# would re-examine the flip-flops and could undo the transform.
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\   (WSL: /mnt/d/Project/hybrid_memory/paper2/scripts/)
# Status  : NEW FILE. Overwrites nothing. Run from anywhere.
# =============================================================================
set -euo pipefail

PAPER2=/mnt/d/Project/hybrid_memory/paper2
LIB=/home/kid/sky130/orfs/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
BUILD=/home/kid/p2r_build
SRC=scripts/yosys_12c_sky130.ys

cd "$PAPER2"
[ -f "$SRC" ] || { echo "ERROR: $SRC not found." >&2; exit 1; }
mkdir -p "$BUILD" scripts reports

for V in u2 b; do
    # Preamble cut from the submitted-version script, never retyped.
    sed -n '1,55p' "$SRC" > "scripts/yosys_e3s1_${V}.ys"

    # Quoted heredoc so the Yosys cell patterns keep their dollar signs.
    # @LIB@ and @BUILD@ are substituted afterwards.
    cat >> "scripts/yosys_e3s1_${V}.ys" <<'YSEOF'

# =============================================================
# P2R-E3 stage 1, variant @VAR@. Yosys 0.68+36 (OSS CAD Suite 20260807).
# =============================================================
synth -top lenet5_top
tee -o reports/e3_@VAR@_stat_after_synth.txt stat

dfflegalize -cell $_DFF_?_ 01 -cell $_DFFE_??_ 01 -cell $_DFF_???_ 01 -cell $_DFFE_????_ 01 -cell $_SDFFCE_????_ 01
opt_expr
opt_merge
opt_clean
tee -o reports/e3_@VAR@_stat_after_transform.txt stat
YSEOF

    if [ "$V" = "b" ]; then
        cat >> "scripts/yosys_e3s1_${V}.ys" <<'YSEOF'

clockgate -liberty @LIB@ -dont_use sky130_fd_sc_hd__sdlclkp*
tee -o reports/e3_@VAR@_stat_after_clockgate.txt stat
YSEOF
    fi

    cat >> "scripts/yosys_e3s1_${V}.ys" <<'YSEOF'

write_rtlil @BUILD@/e3_@VAR@_s1.rtlil
YSEOF

    # Stage 2 is the same shape as the U1 and A variants: a fresh process, so
    # memory starts from zero, and two netlists from one run so that the
    # simulation and the timing analysis read the same design.
    cat > "scripts/yosys_e3s2_${V}.ys" <<'YSEOF'
# =============================================================
# P2R-E3 stage 2, variant @VAR@. Yosys 0.68+36.
# =============================================================
read_liberty -lib @LIB@
read_rtlil @BUILD@/e3_@VAR@_s1.rtlil

dfflibmap -liberty @LIB@ -dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe*
abc -liberty @LIB@ -dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe*
clean

tee -o reports/e3_@VAR@_stat_final.txt stat -liberty @LIB@

write_verilog reports/lenet5_top_@VAR@_netlist.v
write_verilog -noattr reports/lenet5_top_@VAR@_sta.v
YSEOF

    for F in "scripts/yosys_e3s1_${V}.ys" "scripts/yosys_e3s2_${V}.ys"; do
        sed -i -e "s|@LIB@|$LIB|g" -e "s|@BUILD@|$BUILD|g" -e "s|@VAR@|$V|g" "$F"
    done
done

echo "Generated:"
ls -la scripts/yosys_e3s1_u2.ys scripts/yosys_e3s1_b.ys \
       scripts/yosys_e3s2_u2.ys scripts/yosys_e3s2_b.ys
echo
echo "=========== tail of yosys_e3s1_b.ys ==========="
tail -22 scripts/yosys_e3s1_b.ys
echo
echo "=========== tail of yosys_e3s1_u2.ys ==========="
tail -16 scripts/yosys_e3s1_u2.ys
echo
echo "=========== yosys_e3s2_b.ys ==========="
cat scripts/yosys_e3s2_b.ys
