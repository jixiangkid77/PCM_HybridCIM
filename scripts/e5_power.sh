#!/usr/bin/env bash
# =============================================================================
# e5_power.sh <variant> <vcd_file>
#
# Purpose : P2R-E5. Annotate a gate-level waveform onto the matching netlist and
#           report power, using the same flow as the submitted version so that
#           the new figures and the old one are comparable.
#
# Variant is one of: ungated, gated, u2, b. The waveform must have been produced
# from the same variant; a mismatch would annotate one design with another
# design's activity, which is the fault the submitted version came close to.
#
# Gate G11 : the annotated pin count and the sequential-group internal power
#            must both be recorded. Clock gating only shows up in the power
#            figure if the waveform actually carries the reduced toggling on the
#            gated clock nets and the tool actually annotates it. If the
#            sequential internal power does not fall for the gated variant while
#            the simulator itself ran 36 percent faster, the annotation is not
#            reaching the gated clock pins and the result is not usable.
#
# The whole report is printed, every group, not only the total. The submitted
# version kept only the total line, which is why it took a separate run months
# later to establish that 99.6 percent of the power sits in the sequential
# cells.
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\   (WSL: /mnt/d/Project/hybrid_memory/paper2/scripts/)
# Status  : NEW FILE.
# Runtime : unknown for a large waveform. This is also the memory measurement
#           that decides whether a fully recorded inference can be analysed at
#           all: the window used here is 155 MB and a full inference would be
#           about 3.9 GB, against a 24 GiB limit on this machine.
# =============================================================================
set -uo pipefail

PAPER2=/mnt/d/Project/hybrid_memory/paper2
LIB=/home/kid/sky130/orfs/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
STA=/usr/local/bin/sta

VARIANT="${1:-}"
VCD="${2:-}"
case "$VARIANT" in
    ungated|gated|u2|b) ;;
    *) echo "usage: bash scripts/e5_power.sh <ungated|gated|u2|b> <vcd_file>" >&2; exit 1 ;;
esac
[ -n "$VCD" ] || { echo "usage: bash scripts/e5_power.sh <variant> <vcd_file>" >&2; exit 1; }

NETLIST="$PAPER2/reports/lenet5_top_${VARIANT}_sta_ok.v"
for F in "$NETLIST" "$VCD" "$LIB" "$STA"; do
    [ -e "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done

cd "$PAPER2" || exit 1
mkdir -p reports

TAG="${VARIANT}_$(basename "$VCD" .vcd)"
TCL="scripts/e5_power_${TAG}.tcl"

# Placeholders are substituted below, so the file is written literally first.
cat > "$TCL" <<'TCLEOF'
# P2R-E5 power analysis. Same command sequence as the submitted version's
# vcd_power.tcl, with the netlist and the waveform pointed at one variant.
read_liberty @LIB@
read_verilog @NETLIST@
link_design lenet5_top
create_clock -name clk -period 10 [get_ports clk]
puts "FLIPFLOP_COUNT [llength [all_registers -cells]]"
read_vcd -scope tb_lenet5_gate/DUT @VCD@
report_power -digits 4
TCLEOF
sed -i -e "s|@LIB@|$LIB|" -e "s|@NETLIST@|$NETLIST|" -e "s|@VCD@|$VCD|" "$TCL"

echo "=============================================================="
echo "P2R-E5, variant $VARIANT"
echo "  netlist  : $NETLIST"
echo "  md5      : $(md5sum "$NETLIST" | cut -d' ' -f1)"
echo "  waveform : $VCD"
echo "  size     : $(ls -la "$VCD" | awk '{print $5}') bytes"
echo "  script   : $TCL"
echo "=============================================================="
echo
echo "---- the analysis script, in full ----"
cat "$TCL"

echo
echo "---- run, started $(date '+%F %T') ----"
/usr/bin/time -v "$STA" -no_splash -exit "$TCL" \
    > "reports/e5_${TAG}.log" 2> "reports/e5_${TAG}_resource.txt"
RC=$?
echo "sta exit status: $RC"
echo "     finished $(date '+%F %T')"
grep -E "Elapsed \(wall|Maximum resident" "reports/e5_${TAG}_resource.txt"

echo
echo "---- RAW: the whole report ----"
cat "reports/e5_${TAG}.log"

echo
echo "---- RAW: anything the tool complained about ----"
grep -v "Elapsed\|Maximum resident\|Command being\|User time\|System time\|Percent of\|Average\|Major\|Minor\|Voluntary\|Involuntary\|Swaps\|File system\|Socket\|Signals\|Page size\|Exit status" \
    "reports/e5_${TAG}_resource.txt"

echo
echo "=============================================================="
echo "Reference, submitted version, Yosys 0.33 netlist, 1,000-cycle window:"
echo "  Sequential    5.9047e-02 W internal, 99.6 percent of the total"
echo "  Combinational 2.4132e-04 W"
echo "  Total         5.9329e-02 W, 14,491 flip-flops, 636,052 pins annotated"
