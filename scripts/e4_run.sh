#!/usr/bin/env bash
# =============================================================================
# e4_run.sh <variant> [dump_from_ns dump_to_ns]
#
# Variant is one of: ungated, gated, u2, b.
#
# Two modes.
#   With no window arguments : verification run. No waveform is recorded, so
#                              the run is as fast as the simulator can go. This
#                              is gate G1 and it also measures how long a full
#                              inference takes, which nothing on record does.
#   With window arguments    : the same run with a waveform recorded between
#                              the two times, for the power analysis in E5.
#
# Gate G1 : the run must reach the done state, report a predicted class of 7,
#           and finish in 617,573 cycles. Clock gating must not change what the
#           accelerator computes. Variant b in particular folds the synchronous
#           reset into the enable, and this run is what decides whether that
#           rewrite was sound.
#
# Gate G5 : when a window is recorded, the cleaner must report one removed
#           dump-on marker, one removed closing marker, and no truncation.
#
# Why verification comes first
#   The recorded command from the submitted version was
#       vvp gate_sim.vvp +max_cycles=2000 +dump_from=10000 +dump_to=20000
#   so that run stopped after 2,000 of the 617,573 cycles, 0.32 percent of the
#   inference, and recorded 1,000 of them. It ended in the smoke-run branch and
#   never reached the done state, which means the gate netlist has never been
#   checked end to end and the reported power comes from a 1,000-cycle window
#   near the start of the first convolutional layer. Scaling that run suggests a
#   fully recorded inference would need on the order of a hundred hours and tens
#   of gigabytes, so the window has to be chosen from a measurement rather than
#   guessed. This mode provides that measurement and the missing functional
#   check at the same time.
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\   (WSL: /mnt/d/Project/hybrid_memory/paper2/scripts/)
# Status  : NEW FILE, replaces the earlier draft of the same name.
# =============================================================================
set -uo pipefail

# -- resolved by e4_preflight.sh, and cross-checked against the compile log of
#    the submitted version, which names this same directory ---------------------
SKY_DIR=/home/kid/gf/pdk/ciel/sky130/versions/1e931c9417df0478df9ee6b7289202f3e87440ab/sky130A/libs.ref/sky130_fd_sc_hd/verilog

PAPER2=/mnt/d/Project/hybrid_memory/paper2
WORKROOT=/home/kid/p2r_e4

# -- the six behavioural macro models, in the order the earlier command used ----
SIM_MODELS="$PAPER2/rtl/src/pcm_crossbar.v \
$PAPER2/rtl/src/sram_pool_25lane.v \
$PAPER2/rtl/src/feature_buffer.v \
$PAPER2/rtl/src/bias_storage.v \
$PAPER2/rtl/src/sram_addr_decoder.v \
$PAPER2/rtl/src/pcm_addr_decoder.v"

# -----------------------------------------------------------------------------
VARIANT="${1:-}"
case "$VARIANT" in
    ungated|gated|u2|b) ;;
    *) echo "usage: bash scripts/e4_run.sh <ungated|gated|u2|b> [dump_from_ns dump_to_ns]" >&2; exit 1 ;;
esac

DUMP_FROM="${2:-}"
DUMP_TO="${3:-}"
if [ -n "$DUMP_FROM" ] && [ -z "$DUMP_TO" ]; then
    echo "ERROR: give both window times, or neither." >&2; exit 1
fi
if [ -n "$DUMP_FROM" ]; then
    MODE="window"
    TAG="${VARIANT}_${DUMP_FROM}_${DUMP_TO}"
    # A window is requested, so the dump turns on at DUMP_FROM.
    PLUSARGS="+dump_from=${DUMP_FROM} +dump_to=${DUMP_TO}"
else
    MODE="verify"
    TAG="${VARIANT}_verify"
    # The dump never turns on: the start time is put beyond any reachable
    # simulation time, so no waveform is written and the run is at full speed.
    PLUSARGS="+dump_from=2000000000 +dump_to=2000000001"
fi

NETLIST="$PAPER2/reports/lenet5_top_${VARIANT}_netlist.v"
TB="$PAPER2/rtl/tb/tb_lenet5_gate.v"
CLEANER="$PAPER2/clean_vcd.py"

for F in "$NETLIST" "$TB" "$CLEANER" "$SKY_DIR/primitives.v" "$SKY_DIR/sky130_fd_sc_hd.v"; do
    [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
for F in $SIM_MODELS; do
    [ -f "$F" ] || { echo "ERROR: missing macro model $F" >&2; exit 1; }
done

# -- working directory. The testbench opens its inputs through paths that start
#    one level up, so a symlink puts the data directory where they expect it.
#    The waveforms live on the Linux filesystem, which is far faster to write
#    than the Windows mount.
mkdir -p "$WORKROOT/$VARIANT" || exit 1
[ -e "$WORKROOT/data" ] || ln -s "$PAPER2/data" "$WORKROOT/data"
RUNDIR="$WORKROOT/$VARIANT"
cd "$RUNDIR" || exit 1

echo "=============================================================="
echo "P2R-E4, variant $VARIANT, mode $MODE"
echo "  netlist     : $NETLIST"
echo "  netlist md5 : $(md5sum "$NETLIST" | cut -d' ' -f1)"
echo "  cell models : $SKY_DIR"
echo "  run dir     : $RUNDIR"
echo "  data link   : $(readlink -f "$WORKROOT/data")"
echo "  plusargs    : $PLUSARGS"
echo "  free space  : $(df -h "$RUNDIR" | tail -1)"
echo "=============================================================="

echo
echo "---- data paths baked into the netlist, which the symlink has to satisfy ----"
grep -oE '"[^"]*\.(hex|mem)"' "$NETLIST" | sort -u | head -20

# -- compile -------------------------------------------------------------------
echo
echo "---- compile, started $(date '+%F %T') ----"
# shellcheck disable=SC2086
/usr/bin/time -v iverilog -g2012 -DFUNCTIONAL -s tb_lenet5_gate \
    -o "sim_${VARIANT}.vvp" \
    "$SKY_DIR/primitives.v" "$SKY_DIR/sky130_fd_sc_hd.v" \
    $SIM_MODELS "$NETLIST" "$TB" \
    > "compile_${VARIANT}.log" 2> "compile_${VARIANT}_resource.txt"
RC=$?
echo "iverilog exit status: $RC"
grep -E "Elapsed \(wall|Maximum resident" "compile_${VARIANT}_resource.txt"
echo "---- compile messages other than the harmless delay-macro warnings ----"
grep -v "UNIT_DELAY\|Elapsed\|Maximum resident\|Command being\|User time\|System time\|Percent of\|Average\|Major\|Minor\|Voluntary\|Involuntary\|Swaps\|File system\|Socket\|Signals\|Page size\|Exit status" \
    "compile_${VARIANT}_resource.txt"
cat "compile_${VARIANT}.log"
if [ "$RC" -ne 0 ]; then
    echo "COMPILE FAILED. Nothing further was run." >&2
    exit 1
fi
ls -la "sim_${VARIANT}.vvp"

# -- simulate ------------------------------------------------------------------
echo
echo "---- simulate, started $(date '+%F %T') ----"
# shellcheck disable=SC2086
/usr/bin/time -v vvp "sim_${VARIANT}.vvp" $PLUSARGS \
    > "sim_${TAG}.log" 2> "sim_${TAG}_resource.txt"
RC=$?
echo "vvp exit status: $RC"
echo "     finished $(date '+%F %T')"
grep -E "Elapsed \(wall|Maximum resident" "sim_${TAG}_resource.txt"

echo
echo "---- RAW: the whole simulation log. It is short. ----"
cat "sim_${TAG}.log"

echo
echo "---- RAW: the lines gate G1 is judged on ----"
grep -n "DONE at post-start cycle\|PASS\|FAIL\|STOP\|max_cycles" "sim_${TAG}.log"
echo "     expected: DONE at post-start cycle 617573, predicted_class=7, PASS"

# -- waveform ------------------------------------------------------------------
echo
if [ "$MODE" = "window" ]; then
    echo "---- waveform ----"
    ls -la gate.vcd 2>&1
    if [ -f gate.vcd ]; then
        mv gate.vcd "gate_${TAG}.vcd"
        ls -la "gate_${TAG}.vcd"
        echo
        echo "---- clean the waveform for the timing tool, gate G5 ----"
        python3 "$CLEANER" "$RUNDIR/gate_${TAG}.vcd" "$RUNDIR/gate_${TAG}_clean.vcd"
        echo "     expected: removed dump-on 1, removed closing end 1, truncated at line None"
        ls -la "gate_${TAG}_clean.vcd"
    else
        echo "ERROR: a window was requested but no waveform was written." >&2
    fi
else
    echo "---- no waveform in verification mode; confirming none was written ----"
    ls -la gate.vcd 2>&1
fi

echo
echo "=============================================================="
echo "Reference: the submitted version reports 617,573 cycles and class 7."
echo "Its own gate-level run stopped at 2,000 cycles and never reached done,"
echo "so this is the first end-to-end check of the gate netlist."
