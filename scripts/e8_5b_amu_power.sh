#!/usr/bin/env bash
# =============================================================================
# e8_5b_amu_power.sh
#
# Experiment : P2R-E8.5b. Power of the logic of the address-map unit (AMU,
#              E8.5) over one inference, at gate level, by the method of E5:
#              the synthesised netlist of E8.5 (reports/e8_rom/e8_5/
#              amu_top_<M>_sta.v, Yosys 0.68+36, flow B, not changed) is
#              simulated in the full inference (the rest of the design RTL),
#              its waveform is written from the start pulse to the end, and
#              OpenSTA annotates it and reports the power (tt library,
#              10 ns clock, no clock tree, as E5). The ROM macros are black
#              boxes: their energy is D_ROM (E8.6a-3), not part of this.
# Why        : E8.6a-3 gave D_ROM of about 10 uJ per inference. The AMU (8-slot
#              buffer of 6,400 flip-flops behind clock gates, about 460 other
#              flip-flops clocked every cycle, entry arithmetic, 50 tables of
#              logic; 295,571 um2) is new hardware: its logic energy belongs to
#              the address map and may be of the same order as D_ROM.
#
# Steps
#   1  netlist copies per model. Yosys (the one of E8.5) reads the E8.5
#      netlist and writes it flattened into one module with every internal
#      net a single bit (flatten, splitnets, write_verilog -simple-lhs). In
#      the hierarchical netlist the buffer drives a 6,400-bit bus bit by bit,
#      and iverilog rebuilds and re-sends the whole bus at every bit change:
#      in the sandbox the gate-level run went from about 85 to about 0.7
#      cycles per second at fc1 (about 3 ROM reads per cycle) and could not
#      finish; flattened, the gate-level run of one model takes 6.6 min
#      there. Then scripts/e8_5b_check.py netlists gives plain names to the
#      escaped names (name list kept) and writes the copy for simulation
#      (top module amu_top_gl, the model's data folder given to the 200 ROM
#      black boxes) and the copy for OpenSTA (the ROM parameter lists and the
#      word "signed" removed: OpenSTA's Verilog reader stops at them).
#      Checked: the same cells (names, types) and every cell pin on the same
#      net as in the hierarchical netlist; the renaming undone exactly
#   2  compile, A and B: the RTL run (rtl/e8 as in E8.5) and the gate-level run
#      (rtl/e8/tb/amu_top_gl_wrap.v + the netlist copy + the cell models used
#      by E4 / E5); both with the ROM model rtl/e8/e8_rom_r48_rec.v and the
#      monitor rtl/e8/tb/e8_5b_monitor.v, next to the unchanged testbench and
#      E8.2 monitor
#   3  simulate the four runs in parallel; the gate-level runs write the
#      waveform of the unit (the nets of the flattened netlist and the port
#      nets of every cell, which OpenSTA reads as <instance>/<pin>) from the
#      first clock after the start pulse
#   4  equivalence (scripts/e8_5b_check.py sim)
#   5  waveform for OpenSTA (scripts/e8_5b_check.py vcd): wire and reg values
#      only, time shifted to start at 0
#   6  OpenSTA: read_liberty, read_verilog, link_design amu_top, create_clock
#      10 ns, read_vcd, report_power (all groups) and the power of every cell
#   7  energy per inference (scripts/e8_5b_check.py power), with the power of
#      the cells summed by top-level instance of the unit (from the name list)
#
# Gates (decided before the run; a failed gate stops nothing that runs, but
# no power is reported for a model whose gate fails)
#   N1  netlist copies: Yosys exit 0; the flattened netlist has the cells of
#       the hierarchy (names, types) and every cell pin and top-level port bit
#       on the same net; no multi-bit internal net; renaming undone exactly;
#       top renamed once, DATA_DIR set in 200 ROM black boxes, 200 ROM
#       parameter lists removed, the same cells in both copies
#   F0  the gate-level compile reads none of rtl/e8/amu_*.v, and reads the
#       netlist copy and the wrapper; the RTL compile reads rtl/e8/amu_top.v
#   F1  both runs ALL TESTS PASSED; cycles and SRAM reads equal to E8.5
#   F2  the E8.2 monitor trace of both runs = E8.2 trace (md5)
#   F3  the trace at the datapath start of both runs = E8.5 trace (md5)
#   F4  every ROM macro read (time, side, lane, macro, address, clock-low
#       time) the same in the RTL and the gate-level run; reads per side =
#       E8.5 summary; RTL run 0 stall cycles; error flags 000 in both runs
#       (the unit's four counters count only in simulation, `ifndef SYNTHESIS
#       in rtl/e8/amu_core.v: 0 in the gate-level run); ROM protocol errors 0
#       (the address-hold check on the settled address), clock low >= 50 ns
#   P1  OpenSTA: annotated pins = the pin bits of the netlist (every cell pin
#       and port bit; N1 counts them) and, where the version reports it, 0
#       unannotated; sequential internal power > 0 (E5's G11: both recorded)
#
# Files (all NEW; nothing existing is changed)
#   rtl/e8/      e8_rom_r48_rec.v  e8_5b_manifest.md5
#   rtl/e8/tb/   e8_5b_monitor.v  amu_top_gl_wrap.v
#   scripts/     e8_5b_amu_power.sh  e8_5b_check.py
# Used, unchanged: the E8.5 files (rtl/e8/, checked against
#   rtl/e8/e8_5_manifest.md5; rtl/e8/e8_rom_r48_stub.v is the ROM black box
#   for Yosys, as in E8.5), rtl/e8/amu_park_{A,B}.vh, rtl/src/*.v,
#   rtl/tb/tb_lenet5_full_inference_v3.v, rtl/tb/e8_lookup_monitor.v, data/,
#   reports/e8_rom/trace/trace_{A,B}.txt (E8.2), reports/e8_rom/e8_5/
#   (netlists, traces, summaries, logs of E8.5)
# Writes : /home/kid/p2r_e8/e8_5b/ (work: netlist copies, compiles, waveforms),
#          reports/e8_rom/e8_5b/ (results)
# Run    : cd /mnt/d/Project/hybrid_memory/paper2
#          bash scripts/e8_5b_amu_power.sh 2>&1 | tee reports/e8_5b_amu_power.log
#          Keep the terminal open and the computer awake.
# Runtime: sandbox (2 cores, A and B, four runs in parallel) 12 min; the
#          gate-level runs dominate. Disk: about 1.7 GB of waveforms per model
#          in the work folder (checked before the runs: 2.5 GB per model).
#          See claude/p2r-e8-5b-sandbox.md.
# Options (for testing only): E8_PAPER2, E8_WORK, E8_SKY_DIR, E8_CELL_ARGS,
#          E8_LIB, E8_STA, E8_YOSYS, E8_MODELS ("A B")
# =============================================================================
set -uo pipefail

PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
SRC="$PAPER2/rtl/src"
TBD="$PAPER2/rtl/tb"
E8="$PAPER2/rtl/e8"
E8TB="$E8/tb"
SCR="$PAPER2/scripts"
E82="$PAPER2/reports/e8_rom/trace"
E85="$PAPER2/reports/e8_rom/e8_5"
WORK="${E8_WORK:-/home/kid/p2r_e8/e8_5b}"
OUT="$PAPER2/reports/e8_rom/e8_5b"
SKY_DIR="${E8_SKY_DIR:-/home/kid/gf/pdk/ciel/sky130/versions/1e931c9417df0478df9ee6b7289202f3e87440ab/sky130A/libs.ref/sky130_fd_sc_hd/verilog}"
CELL_ARGS="${E8_CELL_ARGS:-$SKY_DIR/primitives.v $SKY_DIR/sky130_fd_sc_hd.v}"
LIB="${E8_LIB:-/home/kid/sky130/orfs/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib}"
STA="${E8_STA:-/usr/local/bin/sta}"
YS="${E8_YOSYS:-/home/kid/oss-cad-suite/bin/yosys}"
MODELS="${E8_MODELS:-A B}"
SCOPE="tb_lenet5_full_inference_v3/DUT/u_imc/U_AMU/U_GL"

T0=$(date +%s)
NFAIL=0
step_time() { echo "   [$(date '+%H:%M:%S'), $(( $(date +%s) - T0 )) s since the start]"; }
gate() {   # $1 = exit status of a check (0 = pass), $2 = label
  if [ "$1" -eq 0 ]; then echo "  PASS  $2"; else echo "  FAIL  $2"; NFAIL=$((NFAIL + 1)); fi
}
timed() {   # timed LABELFILE CMD...: runs CMD, writes wall time and peak memory to LABELFILE when /usr/bin/time exists
  local f=$1; shift
  if [ -x /usr/bin/time ]; then /usr/bin/time -f "%e s wall, %M kB peak" -o "$f" "$@"
  else local s; s=$(date +%s); "$@"; local rc=$?; echo "$(( $(date +%s) - s )) s wall" > "$f"; return $rc; fi
}

echo "=============================================================="
echo "P2R-E8.5b gate-level power of the address-map unit, started $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
cd "$PAPER2" || exit 1
echo "---- delivered files against the manifests ----"
md5sum -c "$E8/e8_5b_manifest.md5" || { echo "ERROR: a delivered file differs from the manifest (see above)."; exit 1; }
md5sum -c "$E8/e8_5_manifest.md5" > /dev/null || { echo "ERROR: an E8.5 file differs from rtl/e8/e8_5_manifest.md5."; exit 1; }
echo "   E8.5 files: all OK against rtl/e8/e8_5_manifest.md5"
for F in "$TBD/tb_lenet5_full_inference_v3.v" "$TBD/e8_lookup_monitor.v" "$E82/trace_A.txt" "$E82/trace_B.txt" \
         "$E8/amu_park_A.vh" "$E8/amu_park_B.vh" "$E8/e8_rom_r48_stub.v" "$LIB" "$STA" "$YS"; do
  [ -e "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
for M in $MODELS; do
  for F in "$E85/amu_top_${M}_sta.v" "$E85/e85_trace_$M.txt" "$E85/e8_5_summary_$M.json" "$E85/full_e8_$M.log"; do
    [ -e "$F" ] || { echo "ERROR: missing $F (written by scripts/e8_5_amu.sh)" >&2; exit 1; }
  done
done
for F in $CELL_ARGS; do
  case "$F" in -*) continue ;; esac
  [ -e "$F" ] || { echo "ERROR: missing cell model file $F" >&2; exit 1; }
done
echo "---- inputs (md5) ----"
md5sum "$TBD/tb_lenet5_full_inference_v3.v" "$TBD/e8_lookup_monitor.v" "$E8/amu_park_A.vh" "$E8/amu_park_B.vh" \
       "$E8/e8_rom_r48_stub.v" "$E82/trace_A.txt" "$E82/trace_B.txt" "$LIB" | sed 's/^/   /'
for M in $MODELS; do
  md5sum "$E85/amu_top_${M}_sta.v" "$E85/e85_trace_$M.txt" "$E85/e8_5_summary_$M.json" | sed 's/^/   /'
  cmp -s "$E8/amu_park_$M.vh" "$E85/amu_park_$M.vh" && echo "   rtl/e8/amu_park_$M.vh = the copy in reports/e8_rom/e8_5 (the one the netlist was synthesised with)" \
    || { echo "ERROR: rtl/e8/amu_park_$M.vh differs from reports/e8_rom/e8_5/amu_park_$M.vh" >&2; exit 1; }
done
echo "cell models: $CELL_ARGS"
for F in $CELL_ARGS; do case "$F" in -*) ;; *) [ -f "$F" ] && md5sum "$F" | sed 's/^/   /' ;; esac; done
echo "yosys    : $YS  $("$YS" -V 2>&1 | head -1)"
echo "iverilog : $(command -v iverilog)  $(iverilog -V 2>&1 | head -1)"
echo "python3  : $(command -v python3)  $(python3 --version 2>&1)"
echo "OpenSTA  : $STA  $("$STA" -version 2>&1 | head -1)"
echo "machine  : $(nproc) cores, $(free -g | awk '/Mem:/{print $2" GiB memory, "$7" GiB available"}'), $(df -h "$(dirname "$WORK")" 2>/dev/null | awk 'NR==2{print $4" free for the work folder"}')"
mkdir -p "$WORK" "$OUT" || exit 1
[ -e "$WORK/data" ] || ln -s "$PAPER2/data" "$WORK/data"
# the waveforms: about 0.85 GB per model in the sandbox, written twice (as simulated, and for OpenSTA)
FREE_KB=$(df -Pk "$WORK" | awk 'NR==2{print $4}')
NEED_KB=$(( 2500000 * $(echo $MODELS | wc -w) ))
[ "$FREE_KB" -ge "$NEED_KB" ] || { echo "ERROR: $((FREE_KB / 1000000)) GB free in the work folder; at least $((NEED_KB / 1000000)) GB needed for the waveforms." >&2; exit 1; }

# ---------------------------------------------------------------------------
echo
echo "==== 1. netlist copies (flattened by Yosys; simulation, OpenSTA) ===="
for M in $MODELS; do
  echo "---- model $M ----"
  YSF="$WORK/amu_flat_$M.ys"
  cat > "$YSF" <<YSEOF
# P2R-E8.5b: the E8.5 netlist of model $M flattened for the gate-level simulation and OpenSTA:
# one module, every internal net a single bit, assignments bit by bit; the cells and their
# connections are not changed (checked by scripts/e8_5b_check.py netlists)
read_liberty -lib $LIB
read_verilog -sv $E8/e8_rom_r48_stub.v
read_verilog $E85/amu_top_${M}_sta.v
hierarchy -top amu_top
tee -o $WORK/amu_${M}_stat_hier.txt stat
flatten -noscopeinfo
splitnets
tee -o $WORK/amu_${M}_stat_flat.txt stat
write_verilog -noattr -simple-lhs $WORK/amu_top_${M}_flat.v
YSEOF
  rm -f "$WORK/amu_top_${M}_flat.v"
  timed "$WORK/flat_${M}_time.txt" "$YS" -q -l "$WORK/amu_flat_$M.log" -s "$YSF"
  RC=$?
  echo "   yosys exit $RC ($(cat "$WORK/flat_${M}_time.txt"))"
  grep -iE "warning|error" "$WORK/amu_flat_$M.log" | sort | uniq -c | sort -rn | head -8 | sed 's/^/   /'
  cp -f "$YSF" "$WORK/amu_flat_$M.log" "$WORK/amu_${M}_stat_hier.txt" "$WORK/amu_${M}_stat_flat.txt" "$OUT/" 2>/dev/null
  if [ $RC -eq 0 ]; then
    python3 "$SCR/e8_5b_check.py" netlists --hier "$E85/amu_top_${M}_sta.v" --flat "$WORK/amu_top_${M}_flat.v" \
        --stat-hier "$WORK/amu_${M}_stat_hier.txt" --stat-flat "$WORK/amu_${M}_stat_flat.txt" --model "$M" \
        --sim-out "$WORK/amu_top_gl_$M.v" --sta-out "$WORK/amu_top_${M}_sta_ok.v" --map-out "$WORK/amu_names_$M.txt"
    RC=$?
    cp -f "$WORK/amu_names_$M.txt" "$WORK/amu_names_$M.txt.json" "$OUT/"
  fi
  gate $RC "N1 netlist copies, model $M"
  [ $RC -eq 0 ] || { echo "The netlist copies of model $M failed. Nothing further is run."; exit 1; }
done
step_time

# ---------------------------------------------------------------------------
cd "$WORK" || exit 1
echo
echo "==== 2. compile: RTL run and gate-level run, A and B ===="
for M in $MODELS; do
  DEFS=(-DLOAD_REAL_DATA -DE8_AS_PCM_IMC_UNIT)
  [ "$M" = B ] && DEFS+=(-DMODEL_B)
  iverilog -g2012 "${DEFS[@]}" -I "$E8" -I "$SRC" -y "$SRC" -y "$E8" -Y .v \
      -s tb_lenet5_full_inference_v3 -s e8_lookup_monitor -s e8_5b_monitor -M "rtl_deps_$M.txt" \
      -o "rtl_$M.vvp" "$TBD/tb_lenet5_full_inference_v3.v" "$TBD/e8_lookup_monitor.v" \
      "$E8TB/e8_5b_monitor.v" "$E8/pcm_imc_unit_e8.v" "$E8/e8_rom_r48_rec.v" > "rtl_compile_$M.log" 2>&1
  RC1=$?
  # shellcheck disable=SC2086
  timed "gate_compile_${M}_time.txt" iverilog -g2012 "${DEFS[@]}" -DFUNCTIONAL -DE85B_GATE -I "$SRC" -y "$SRC" -Y .v \
      -s tb_lenet5_full_inference_v3 -s e8_lookup_monitor -s e8_5b_monitor -M "gate_deps_$M.txt" \
      -o "gate_$M.vvp" "$TBD/tb_lenet5_full_inference_v3.v" "$TBD/e8_lookup_monitor.v" \
      "$E8TB/e8_5b_monitor.v" "$E8/pcm_imc_unit_e8.v" "$E8/e8_rom_r48_rec.v" "$E8TB/amu_top_gl_wrap.v" \
      "$WORK/amu_top_gl_$M.v" $CELL_ARGS > "gate_compile_$M.log" 2>&1
  RC2=$?
  echo "Model $M: iverilog exit RTL $RC1, gate $RC2 (gate compile $(cat "gate_compile_${M}_time.txt"))"
  sed 's/^/   /' "rtl_compile_$M.log"
  grep -v "UNIT_DELAY" "gate_compile_$M.log" | sed 's/^/   /'
  echo "   gate compile: $(grep -c "UNIT_DELAY" "gate_compile_$M.log") warnings about the delay macro of the cell models (as E4 / E5)"
  [ $RC1 -eq 0 ] && [ $RC2 -eq 0 ] || { echo "COMPILE FAILED. Nothing further is run."; exit 1; }
  ! grep -qE "rtl/e8/amu_[a-z]+\.v" "gate_deps_$M.txt" && grep -q "amu_top_gl_$M.v" "gate_deps_$M.txt" \
    && grep -q "amu_top_gl_wrap.v" "gate_deps_$M.txt" && grep -q "rtl/e8/amu_top.v" "rtl_deps_$M.txt"
  gate $? "F0 model $M: the gate-level compile reads the netlist and the wrapper and no rtl/e8/amu_*.v; the RTL compile reads rtl/e8/amu_top.v"
  cp -f "rtl_compile_$M.log" "rtl_deps_$M.txt" "gate_deps_$M.txt" "$OUT/"
done
echo "---- source files of the gate-level compile (model ${MODELS%% *}), with checksums ----"
sort -u "gate_deps_${MODELS%% *}.txt" 2>/dev/null | while read -r f; do printf "   %s  %s\n" "$(md5sum "$f" | cut -c1-12)" "$f"; done
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 3. simulate (RTL and gate-level runs in parallel), started $(date '+%F %T') ===="
for M in $MODELS; do
  ( timed "rtl_${M}_time.txt" vvp "rtl_$M.vvp" "+e8_trace=$WORK/rtl_e8trace_$M.txt" "+e85b_trace=$WORK/rtl_trace_$M.txt" \
      "+e85b_reads=$WORK/rtl_reads_$M.txt" > "rtl_$M.log" 2>&1; echo $? > "rtl_$M.rc" ) &
  ( timed "gate_${M}_time.txt" vvp "gate_$M.vvp" "+e8_trace=$WORK/gate_e8trace_$M.txt" "+e85b_trace=$WORK/gate_trace_$M.txt" \
      "+e85b_reads=$WORK/gate_reads_$M.txt" "+e85b_vcd=$WORK/amu_gate_$M.vcd" > "gate_$M.log" 2>&1; echo $? > "gate_$M.rc" ) &
done
wait
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 4. equivalence ===="
for M in $MODELS; do
  echo "---- model $M: RTL vvp exit $(cat "rtl_$M.rc"), $(cat "rtl_${M}_time.txt"); gate vvp exit $(cat "gate_$M.rc"), $(cat "gate_${M}_time.txt")"
  for L in rtl gate; do
    grep -E "inference complete|SRAM protected-weight|RESULT|E8 MONITOR|E8.5b MONITOR|FAIL" "${L}_$M.log" \
      | grep -vE "ROM protocol error [0-9]|has no DATA_DIR" | sed "s/^/   $L   /"
    N=$(grep -cE "ROM protocol error [0-9]|has no DATA_DIR" "${L}_$M.log")
    [ "$N" -gt 0 ] && { echo "   $L: $N lines of ROM protocol errors or ROM models without data, the first 5:"
                        grep -m5 -E "ROM protocol error [0-9]|has no DATA_DIR" "${L}_$M.log" | sed 's/^/      /'; }
  done
  python3 "$SCR/e8_5b_check.py" sim --model "$M" --rtl-log "rtl_$M.log" --gate-log "gate_$M.log" \
      --e82-trace "$E82/trace_$M.txt" --rtl-e8trace "rtl_e8trace_$M.txt" --gate-e8trace "gate_e8trace_$M.txt" \
      --e85-trace "$E85/e85_trace_$M.txt" --rtl-trace "rtl_trace_$M.txt" --gate-trace "gate_trace_$M.txt" \
      --rtl-reads "rtl_reads_$M.txt" --gate-reads "gate_reads_$M.txt" \
      --e85-log "$E85/full_e8_$M.log" --e85-summary "$E85/e8_5_summary_$M.json"
  RC=$?
  gate $RC "F1-F4 model $M"
  echo $RC > "equiv_$M.rc"
  cp -f "rtl_$M.log" "gate_$M.log" "rtl_trace_$M.txt" "gate_trace_$M.txt" "rtl_reads_$M.txt" "gate_reads_$M.txt" \
        "rtl_e8trace_$M.txt" "gate_e8trace_$M.txt" "$OUT/"
done
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 5. waveform for OpenSTA (wire and reg values, time from 0) ===="
for M in $MODELS; do
  echo "---- model $M ----"
  timed "vcd_${M}_time.txt" python3 "$SCR/e8_5b_check.py" vcd --in "$WORK/amu_gate_$M.vcd" --out "$WORK/amu_gate_${M}_sta.vcd"
  RC=$?
  echo "   ($(cat "vcd_${M}_time.txt"))"
  gate $RC "waveform written, model $M"
  cp -f "$WORK/amu_gate_${M}_sta.vcd.json" "$OUT/"
done
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 6. OpenSTA power (tt, 10 ns clock, no clock tree, as E5) ===="
for M in $MODELS; do
  TCL="$WORK/amu_power_$M.tcl"
  cat > "$TCL" <<TCLEOF
# P2R-E8.5b power of the address-map unit, model $M (the command sequence of E5's
# power script, with the unit's netlist, scope and waveform)
read_liberty $LIB
read_verilog $WORK/amu_top_${M}_sta_ok.v
link_design amu_top
create_clock -name clk -period 10 [get_ports clk]
puts "FLIPFLOP_COUNT [llength [all_registers -cells]]"
read_vcd -scope $SCOPE $WORK/amu_gate_${M}_sta.vcd
if {[catch {report_activity_annotation} msg]} { puts "report_activity_annotation: not available in this version" }
report_power -digits 6
if {[catch {report_power -instances [get_cells *] -digits 6} msg]} { puts "report_power -instances: \$msg" }
TCLEOF
  cp -f "$TCL" "$OUT/"
  echo "---- model $M: $TCL ----"
  timed "sta_${M}_time.txt" "$STA" -no_splash -exit "$TCL" > "$WORK/amu_power_$M.log" 2>&1
  RC=$?
  echo "   sta exit $RC, $(cat "sta_${M}_time.txt")"
  grep -v "Creating black box" "$WORK/amu_power_$M.log" | grep -vE "^\s*[0-9.eE+-]+\s+[0-9.eE+-]+\s+[0-9.eE+-]+\s+[0-9.eE+-]+\s+e85b_c" \
    | sed 's/^/   /' | head -80
  echo "   ($(grep -c "Creating black box" "$WORK/amu_power_$M.log") warning(s) 'module e8_rom_r48 not found. Creating black box'" \
       "(the ROM macros: no power model, as intended);" \
       "$(grep -cE "^\s*[0-9.eE+-]+\s+[0-9.eE+-]+\s+[0-9.eE+-]+\s+[0-9.eE+-]+\s+\S" "$WORK/amu_power_$M.log") lines of cell power, in the log)"
  cp -f "$WORK/amu_power_$M.log" "$OUT/"
done
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 7. energy per inference ===="
for M in $MODELS; do
  echo "---- model $M ----"
  python3 "$SCR/e8_5b_check.py" power --log "$WORK/amu_power_$M.log" --vcd "$WORK/amu_gate_${M}_sta.vcd" \
      --window-json "$WORK/amu_gate_${M}_sta.vcd.json" --names "$WORK/amu_names_$M.txt" --out "$OUT/e8_5b_power_$M.json"
  RC=$?
  gate $RC "P1 OpenSTA annotation and power, model $M"
  [ "$(cat "equiv_$M.rc")" -eq 0 ] || echo "   NOTE: the equivalence checks of model $M failed: its power is not a result"
done
step_time

echo
echo "---- files written to $OUT ----"
ls -la "$OUT"
echo "---- waveforms in $WORK ----"
ls -la "$WORK"/*.vcd 2>/dev/null
echo
echo "=============================================================="
echo "Finished $(date '+%Y-%m-%d %H:%M:%S'), $(( ($(date +%s) - T0) / 60 )) min."
if [ "$NFAIL" -eq 0 ]; then echo "All gates pass."; else echo "$NFAIL GATE(S) FAILED, see above."; fi
echo "=============================================================="
