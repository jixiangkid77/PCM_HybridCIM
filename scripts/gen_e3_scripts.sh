#!/usr/bin/env bash
# =============================================================================
# gen_e3_scripts.sh
#
# Purpose : Generate the four P2R-E3 Yosys scripts for the clock-gating study
#           (Reviewer 1, Comment 3). Nothing is run by this script; it only
#           writes the .ys files and prints them for review.
#
# Method  : The RTL-reading preamble is CUT FROM scripts/yosys_12c_sky130.ys
#           with sed, never retyped, so the gated and ungated runs read exactly
#           the same source files as the submitted-version synthesis.
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\   (WSL: /mnt/d/Project/hybrid_memory/paper2/scripts/)
# Status  : NEW FILE. Overwrites nothing. Run from the paper2 directory.
#
# Outputs : scripts/yosys_e3s1_gated.ys      stage 1, with clockgate
#           scripts/yosys_e3s1_ungated.ys    stage 1, baseline
#           scripts/yosys_e3s2_gated.ys      stage 2, with clockgate
#           scripts/yosys_e3s2_ungated.ys    stage 2, baseline
# =============================================================================
set -euo pipefail

PAPER2=/mnt/d/Project/hybrid_memory/paper2
LIB=/home/kid/sky130/orfs/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
BUILD=/home/kid/p2r_build
SRC=scripts/yosys_12c_sky130.ys

cd "$PAPER2"

if [ ! -f "$SRC" ]; then
    echo "ERROR: $SRC not found. Run this from $PAPER2." >&2
    exit 1
fi
if [ ! -f "$LIB" ]; then
    echo "ERROR: liberty file not found: $LIB" >&2
    exit 1
fi

mkdir -p "$BUILD" scripts reports

# Cells excluded from technology mapping.
#   lpflow_* : multi-power-domain cells needing a separate always-on rail.
#              The submitted-version netlist contains 12,630 lpflow_isobufsrc_1
#              because the ORFS DONT_USE_CELLS list was never applied.
#   probe*   : DFT probe points carrying metal on every layer.
DU="-dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe*"

# -----------------------------------------------------------------------------
# Stage 1, gated
# -----------------------------------------------------------------------------
sed -n '1,55p' "$SRC" > scripts/yosys_e3s1_gated.ys
cat >> scripts/yosys_e3s1_gated.ys <<EOF

# =============================================================
# P2R-E3 stage 1, GATED. Yosys 0.68+36 (OSS CAD Suite 20260807).
#
# clockgate runs BEFORE dfflibmap because it operates on the
# word-level \$_SDFFE_/\$_DFFE_ cells that carry the enable. After
# dfflibmap the enable is gone: sky130_fd_sc_hd has no reset-plus-
# enable flop, so dfflegalize rewrites all 14,237 enable flops as
# plain flops plus a feedback mux, and the clock can no longer stop.
#
# sdlclkp is excluded: it is the scan variant, and there is no
# scan chain in this design.
#
# Stops before dfflibmap so that the ICG count can be checked
# against the G6 gate before paying for abc.
# =============================================================
synth -top lenet5_top
tee -o reports/e3_gated_stat_after_synth.txt stat
clockgate -liberty $LIB -dont_use sky130_fd_sc_hd__sdlclkp*
tee -o reports/e3_gated_stat_after_clockgate.txt stat
write_rtlil $BUILD/e3_gated_s1.rtlil
EOF

# -----------------------------------------------------------------------------
# Stage 1, ungated. Identical to the gated script except for the clockgate line.
# -----------------------------------------------------------------------------
sed -n '1,55p' "$SRC" > scripts/yosys_e3s1_ungated.ys
cat >> scripts/yosys_e3s1_ungated.ys <<EOF

# =============================================================
# P2R-E3 stage 1, UNGATED baseline. Yosys 0.68+36.
#
# Line-for-line identical to yosys_e3s1_gated.ys except that the
# clockgate call is absent. Both baselines must come from the same
# Yosys version, or the measured difference would mix two changes:
# the tool upgrade and the clock gating.
# =============================================================
synth -top lenet5_top
tee -o reports/e3_ungated_stat_after_synth.txt stat
write_rtlil $BUILD/e3_ungated_s1.rtlil
EOF

# -----------------------------------------------------------------------------
# Stage 2, both variants. A separate process, so memory starts from zero.
# The submitted-version flow peaked at 23,533.51 MiB against a 24 GiB WSL cap,
# and stage 2 adds abc -liberty on top of that.
# -----------------------------------------------------------------------------
for V in gated ungated; do
cat > "scripts/yosys_e3s2_${V}.ys" <<EOF
# =============================================================
# P2R-E3 stage 2, variant: $V. Yosys 0.68+36.
#
# Reads back the stage 1 design and finishes technology mapping.
# Two netlists are written from this one run so that the gate-level
# simulation and the static timing analysis are guaranteed to read
# the same design:
#   lenet5_top_${V}_netlist.v   with attributes, for iverilog
#   lenet5_top_${V}_sta.v       -noattr, for OpenSTA
# =============================================================
read_liberty -lib $LIB
read_rtlil $BUILD/e3_${V}_s1.rtlil

dfflibmap -liberty $LIB $DU
abc -liberty $LIB $DU
clean

tee -o reports/e3_${V}_stat_final.txt stat -liberty $LIB

write_verilog reports/lenet5_top_${V}_netlist.v
write_verilog -noattr reports/lenet5_top_${V}_sta.v
EOF
done

echo "Generated:"
ls -la scripts/yosys_e3s1_gated.ys scripts/yosys_e3s1_ungated.ys \
       scripts/yosys_e3s2_gated.ys scripts/yosys_e3s2_ungated.ys

echo
echo "=========== tail of yosys_e3s1_gated.ys ==========="
tail -25 scripts/yosys_e3s1_gated.ys
echo
echo "=========== yosys_e3s2_gated.ys ==========="
cat scripts/yosys_e3s2_gated.ys
