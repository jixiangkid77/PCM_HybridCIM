#!/usr/bin/env bash
# =============================================================================
# e9_4_amu_energy.sh
#
# Experiment : P2R-E9.4. The energy of the logic of the address-map unit of E9 (one 40-bit word
#              per table entry, rtl/e9/amu9_top.v) over one whole inference, at gate level, by the
#              method of E8.7, E10.2a and E10.2c: the synthesised netlist of E9.1 (reports/e9/e9_1/
#              syn/amu9_sta.v, Yosys flow B with clock gating, byte for byte) runs inside the RTL full
#              inference of E9.1 (the E9 unit rtl/e9/pcm_imc_unit_e9.v with the clock-gated banked
#              pool, no conv1 cache); its waveform gives OpenSTA (OpenROAD) the activity of every pin;
#              tt library, 10 ns clock, no clock tree. The 7 ROM macros are black boxes: their energy
#              is D_ROM (E9.3), not part of this.
# Why        : E8.7 measured the E8.5 unit (50 tables, a buffer of 8 x 800 bits) at 9.871 / 9.717 uJ
#              per inference, more than its ROM. The E9 unit has one word per entry (a buffer of 8 x 37
#              bits, a prefix count instead of 50 tables): its logic energy is the second part of the
#              address-map energy D of E9 (D = D_ROM + this).
# Steps      : 0  files (rtl/e9/e9_4_manifest.md5), the E9.1 results (all gates passed; netlist, event
#                 lists, images), tools
#              B1 the logic netlist with the E8.7 tools (stage 3, plain names and wrapper, check E1; the
#                 simulation netlist, check C1) and the wrapper completed for simulation
#                 (scripts/e9_4_tools.py wrapper: the 7 ROM models and a recorder of their read pulses)
#              B2 compiles: the E9.1 compiles with the synthesised unit instead of the RTL unit (PDK cell
#                 models with -DFUNCTIONAL) and the monitor rtl/e9/tb/e9_4_monitor.v (the E8.5 trace from
#                 ports of the unit, and the waveform); models A and B, normal and read-once
#              B3 the runs (E8_JOBS at a time); each writes the waveform of the unit's logic
#              B4 power of the logic netlist with each waveform (scripts/e8_7_power.tcl), energy per
#                 inference (scripts/e8_7_tools.py power)
#              B5 gates and summary (scripts/e9_4_tools.py judge)
# Gates (written before the run in protocol P2R-E9.4 of 2026-11-11)
#              S1 the netlist is that of E9.1 byte for byte, 7 ROM black boxes with MACRO 0..6, no lpflow
#                 or probe cells; E1; C1; per run G0 (the synthesised unit, the cell models, the ROM, pool
#                 and bank models; no RTL of the address map, no E8.5 address map, no conv1 cache), G1 ALL
#                 TESTS PASSED at cycle 617573, G2 results and E8.2 / E8.5 traces byte for byte those of
#                 E8.5c (normal: new, read-once: once), G3 every ROM read pulse (kind, phase, cycle, macro,
#                 address, clock-low cycles) the same as in the E9.1 RTL event list, reads counted by the
#                 models = pulses, ROM protocol errors 0, G4 the banked pool's line (lane and bank reads,
#                 per bank, conflicts, address errors, deepest row) = that of the E9.1 RTL run, W waveform
#                 window, A1 annotation.
# For E9.5   : the logic energy of the read-once runs (the configuration of the SRAM reads of E10.2b);
#              the normal runs next to them.
# Files      : NEW scripts/e9_4_amu_energy.sh, scripts/e9_4_tools.py, rtl/e9/tb/e9_4_monitor.v,
#              rtl/e9/e9_4_manifest.md5
# Used, unchanged (md5 in rtl/e9/e9_4_manifest.md5): rtl/e9/pcm_imc_unit_e9.v, e9_rom.v, e9_rom_stub.v
#              (E9.1), rtl/e10/sram_pool_25bank_2c_cg.v, sram_bank_128x8.v, rtl/tb/
#              tb_lenet5_full_inference_v3.v, e8_lookup_monitor.v, rtl/e8/tb/e8_5c_monitor.v,
#              scripts/e8_7_tools.py, e8_7_power.tcl, e10_2a_tools.py, reports/e8_rom/e8_5c/ (new, once);
#              the E9.1 results reports/e9/e9_1/ (netlist and statistics, event lists, images, summary);
#              also rtl/src, data/
# Writes     : /home/kid/p2r_e9/e9_4/ (work, waveforms), reports/e9/e9_4/
# Run        : cd /mnt/d/Project/hybrid_memory/paper2
#              E8_JOBS=4 bash scripts/e9_4_amu_energy.sh 2>&1 | tee reports/e9_4_amu_energy.log
# Options    : E8_JOBS (simulations at a time, default 2; four runs, so more than 4 does not help),
#              E8_WORK, E8_YOSYS, E8_OPENROAD, E8_PLAT, E8_SKY_DIR, E8_PAPER2
# Runtime    : my computer (8 cores) with E8_JOBS=4: gate-level runs about 15-30 min (four at once),
#              power about 1-2 min: about 20-40 min. Disk: four waveforms of about 0.7 GB (test run: 0.69 GB).
# =============================================================================
set -uo pipefail

PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
SRC="$PAPER2/rtl/src"
TBD="$PAPER2/rtl/tb"
E8="$PAPER2/rtl/e8"
E8TB="$E8/tb"
E10="$PAPER2/rtl/e10"
E9="$PAPER2/rtl/e9"
E9TB="$E9/tb"
SCR="$PAPER2/scripts"
REF="$PAPER2/reports/e8_rom/e8_5c"
E91="$PAPER2/reports/e9/e9_1"
NET="$E91/syn/amu9_sta.v"
STAT="$E91/syn/amu9_stat_final.txt"
WORK="${E8_WORK:-/home/kid/p2r_e9/e9_4}"
OUT="$PAPER2/reports/e9/e9_4"
W="$WORK"
YS="${E8_YOSYS:-/home/kid/oss-cad-suite/bin/yosys}"
OR="${E8_OPENROAD:-/home/kid/p2r_e8/openroad/bin/openroad}"
PLAT="${E8_PLAT:-/home/kid/sky130/orfs/flow/platforms/sky130hd}"
SKY_DIR="${E8_SKY_DIR:-/home/kid/gf/pdk/ciel/sky130/versions/1e931c9417df0478df9ee6b7289202f3e87440ab/sky130A/libs.ref/sky130_fd_sc_hd/verilog}"
CELLS=("$SKY_DIR/primitives.v" "$SKY_DIR/sky130_fd_sc_hd.v")
LIB="$PLAT/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
TOP=amu9_top
SCOPE=tb_lenet5_full_inference_v3/DUT/u_imc/U_AMU/core
STUB="$E9/e9_rom_stub.v"
UNIT="$E9/pcm_imc_unit_e9.v"
ROMV="$E9/e9_rom.v"
CGV="$E10/sram_pool_25bank_2c_cg.v"
BANKV="$E10/sram_bank_128x8.v"
MONV="$E9TB/e9_4_monitor.v"
JOBS="${E8_JOBS:-2}"
case "$JOBS" in ''|*[!0-9]*) echo "ERROR: E8_JOBS must be a whole number (got '$JOBS')" >&2; exit 1 ;; esac
[ "$JOBS" -ge 1 ] || JOBS=1
LIST=(normal:A once:A normal:B once:B)
declare -A REFN=([normal]=new [once]=once)      # the E8.5c run with the same pool behaviour

T0=$(date +%s)
step_time() { echo "   [$(date '+%H:%M:%S'), $(( $(date +%s) - T0 )) s since the start]"; }
stop() { echo "STOPPED: $*"; echo "Finished $(date '+%Y-%m-%d %H:%M:%S') without a result."; exit 1; }
md5key() { md5sum "$@" 2>/dev/null | awk '{print $1}' | md5sum | cut -c1-16; }
in_parallel() {   # $1 = function, then the runs "<run>:<model>", JOBS at a time
  local fn=$1; shift
  local items=("$@") i=0 n
  while [ $i -lt ${#items[@]} ]; do
    n=0
    while [ $n -lt "$JOBS" ] && [ $i -lt ${#items[@]} ]; do
      "$fn" "${items[$i]}" &
      i=$((i + 1)); n=$((n + 1))
    done
    wait
  done
}

echo "=============================================================="
echo "P2R-E9.4 the address-map unit of E9 at gate level (logic energy), started $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
cd "$PAPER2" || exit 1

# ---------------------------------------------------------------------------
echo
echo "==== 0. files, the E9.1 results, tools ===="
md5sum -c "$E9/e9_4_manifest.md5" || stop "a delivered or used file differs from rtl/e9/e9_4_manifest.md5 (above)"
[ -f "$E91/e9_1_summary.json" ] || stop "missing $E91/e9_1_summary.json (run E9.1 first)"
python3 -c "import json, sys; sys.exit(0 if json.load(open(sys.argv[1])).get('all_pass') is True else 1)" "$E91/e9_1_summary.json" \
  || stop "E9.1 did not pass all its gates ($E91/e9_1_summary.json): the unit is not measured"
echo "   E9.1: all gates passed ($E91/e9_1_summary.json)"
for f in "$NET" "$STAT" "$E91/syn/yosys_rc.txt" "$E91/tables/e9rom_A.hex" "$E91/tables/e9rom_B.hex" \
         "$LIB" "$PLAT/lef/sky130_fd_sc_hd.tlef" "$PLAT/lef/sky130_fd_sc_hd_merged.lef" "${CELLS[@]}"; do
  [ -f "$f" ] || stop "missing $f"
done
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}
  [ -f "$E91/rtl/e9ev_${R}_$M.txt" ] || stop "missing $E91/rtl/e9ev_${R}_$M.txt (E9.1 event list)"
  for K in res e8t e85t; do
    [ -e "$REF/${K}_${REFN[$R]}_$M.txt" ] || stop "missing $REF/${K}_${REFN[$R]}_$M.txt (E8.5c result)"
  done
  [ -d "$PAPER2/data/rtl_inputs_${M}_v3" ] || stop "missing $PAPER2/data/rtl_inputs_${M}_v3"
done
[ "$(cat "$E91/syn/yosys_rc.txt")" = 0 ] || stop "the E9.1 synthesis did not end with exit 0"
echo "   E9.1 netlist : $(md5sum "$NET")"
echo "   E9.1 images  : $(md5sum "$E91/tables/e9rom_A.hex" | cut -c1-32) A, $(md5sum "$E91/tables/e9rom_B.hex" | cut -c1-32) B"
for E in "${LIST[@]}"; do echo "   E9.1 events  : $(md5sum "$E91/rtl/e9ev_${E%%:*}_${E##*:}.txt")"; done
for f in "$LIB" "${CELLS[@]}"; do echo "   $(md5sum "$f")"; done
command -v iverilog > /dev/null || stop "iverilog not found"
command -v python3 > /dev/null || stop "python3 not found"
[ -x "$YS" ] || stop "yosys not found: $YS"
[ -x "$OR" ] || stop "openroad not found: $OR"
echo "iverilog : $(command -v iverilog)  $(iverilog -V 2>&1 | head -1)"
echo "python3  : $(command -v python3)  $(python3 --version 2>&1)"
echo "yosys    : $YS  $("$YS" -V 2>&1 | head -1)"
echo "openroad : $OR  $("$OR" -version 2>&1 | head -1)"
echo "jobs     : at most $JOBS simulations at a time (E8_JOBS)"
mkdir -p "$W/syn" "$W/sim" "$W/runs" "$W/power" "$OUT" || exit 1
FREE_KB=$(df -Pk "$WORK" | awk 'NR == 2 {print $4}')
echo "disk     : $((FREE_KB / 1024 / 1024)) GB free for $WORK (needs 6 GB: four waveforms of about 0.7 GB)"
[ "$FREE_KB" -ge 6291456 ] || stop "less than 6 GB free for $WORK"
[ -e "$WORK/data" ] || ln -s "$PAPER2/data" "$WORK/data"
if command -v /usr/bin/time > /dev/null 2>&1; then TIMECMD=(/usr/bin/time -f "%e s wall, %M kB peak"); else TIMECMD=(); fi
step_time

# ===========================================================================
echo
echo "==== B1. the logic netlist (the E8.7 tools) ===="
echo "---- $NET"
cp -f "$NET" "$W/syn/n0.v" || exit 1
python3 "$SCR/e8_7_tools.py" stage3 --n0 "$W/syn/n0.v" --stubs "$STUB" --top "$TOP" --lib "$LIB" \
    --out-dir "$W/syn" 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || stop "e8_7_tools.py stage3"
"$YS" -q -l "$W/syn/stage3.log" -s "$W/syn/stage3.ys" > /dev/null 2>&1 || stop "yosys stage 3 (see $W/syn/stage3.log)"
echo "   yosys stage 3: exit 0"
python3 "$SCR/e8_7_tools.py" core --bb "$W/syn/bb.json" --raw "$W/syn/core_raw.v" --stubs "$STUB" \
    --core-out "$W/core.v" --wrapper-out "$W/wrapper.v" --names-out "$W/names.tsv" --check \
    --extra-params K ADDR_WIDTH SRAM_TOTAL PCM_TOTAL 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || stop "e8_7_tools.py core (check E1)"
python3 "$SCR/e8_7_tools.py" ctsfree --net "$W/core.v" --out "$W/sim/core_sim.v" 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || stop "e8_7_tools.py ctsfree (check C1)"
python3 "$SCR/e9_4_tools.py" wrapper --bb "$W/syn/bb.json" --in "$W/wrapper.v" --out "$W/wrapper_sim.v"
[ $? -eq 0 ] || stop "e9_4_tools.py wrapper"
for f in core.v sim/core_sim.v wrapper_sim.v names.tsv; do echo "   $(md5sum "$W/$f" | cut -c1-12)  $f"; done
step_time

echo
echo "==== B2. compiles: the synthesised unit at gate level, models A and B, normal and read-once ===="
TOPS=(-s tb_lenet5_full_inference_v3 -s e8_lookup_monitor -s e8_5c_monitor -s e9_4_monitor)
MONS=("$TBD/tb_lenet5_full_inference_v3.v" "$TBD/e8_lookup_monitor.v" "$E8TB/e8_5c_monitor.v")
cd "$WORK" || exit 1
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}; D="$W/runs/${R}_$M"
  mkdir -p "$D"
  DEFS=(-DLOAD_REAL_DATA -DFUNCTIONAL -DE8_AS_PCM_IMC_UNIT)
  [ "$M" = B ] && DEFS+=(-DMODEL_B)
  [ "$R" = once ] && DEFS+=(-DE85C_READ_ONCE)
  iverilog -g2012 "${DEFS[@]}" -I "$E9" -I "$E10" -I "$E8" -I "$SRC" -y "$SRC" -y "$E8" -Y .v "${TOPS[@]}" \
      -M "$D/deps.txt" -o "$D/sim.vvp" "${MONS[@]}" "$UNIT" "$W/wrapper_sim.v" "$W/sim/core_sim.v" \
      "$ROMV" "$CGV" "$BANKV" "$MONV" "${CELLS[@]}" > "$D/comp.log" 2>&1
  RC=$?
  echo "model $M, $R: iverilog exit $RC; warnings $(grep -ci warning "$D/comp.log") ($(grep -i warning "$D/comp.log" | sed 's/^.*warning: //' | sort | uniq -c | sort -rn | head -2 | tr -s ' ' | tr '\n' ';'))"
  grep -vi "warning" "$D/comp.log" | head -5 | sed 's/^/   /'
  [ $RC -eq 0 ] || stop "compile, model $M, $R"
done
echo "---- the unit, the address map, the pool and the cell models of the compile (model A, normal), with checksums ----"
sort -u "$W/runs/normal_A/deps.txt" | grep -E "pcm_imc_unit|amu|e9_rom|sram_pool|sram_bank|conv1|wrapper_sim|core_sim|e9_4_monitor|sky130_fd_sc_hd|primitives" | \
  while read -r f; do printf "   %s  %s\n" "$(md5sum "$f" | cut -c1-12)" "$f"; done
step_time

echo
echo "==== B3. runs, started $(date '+%F %T') ===="
gate_one() {   # $1 = "<run>:<model>"
  local R=${1%%:*} M=${1##*:}
  local D="$W/runs/${R}_$M" t0 key
  key="$(md5key "$D/sim.vvp" "$E91/tables/e9rom_$M.hex")"
  if [ -f "$D/sim.done" ] && [ "$(cat "$D/sim.done")" = "$key" ] && [ -f "$D/amu.vcd" ]; then
    echo "   model $M, $R: done before with the same compile, kept"
    return 0
  fi
  rm -f "$D/sim.done" "$D/amu.vcd"
  t0=$(date +%s)
  ${TIMECMD[@]+"${TIMECMD[@]}"} vvp -n "$D/sim.vvp" "+e9_rom=$E91/tables/e9rom_$M.hex" \
      "+e8_trace=$D/e8t.txt" "+e85_trace=$D/e85t.txt" "+e85c_results=$D/res.txt" \
      "+e9_events=$D/e9ev.txt" "+e9_vcd=$D/amu.vcd" > "$D/sim.log" 2> "$D/time.txt"
  local rc=$?
  echo "$(( $(date +%s) - t0 )) s" >> "$D/time.txt"
  [ $rc -eq 0 ] && grep -q "RESULT: ALL TESTS PASSED" "$D/sim.log" && echo "$key" > "$D/sim.done"
  return 0
}
in_parallel gate_one "${LIST[@]}"
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}; D="$W/runs/${R}_$M"
  echo "---- model $M, $R: $(tr '\n' ' ' < "$D/time.txt"); waveform $(du -h "$D/amu.vcd" 2>/dev/null | cut -f1)"
  grep -E "inference complete|ALL TESTS|E9\.4 (ROM|VCD|MONITOR)|E10 POOL|E8.5c MONITOR\] datapath|FAIL" "$D/sim.log" | sed "s/^/   /"
  [ -f "$D/sim.done" ] || stop "model $M, $R: the run did not pass (see $D/sim.log)"
done
step_time

echo
echo "==== B4. power of the logic netlist with each waveform (OpenROAD, scripts/e8_7_power.tcl) ===="
power_one() {   # $1 = "<run>:<model>"
  local R=${1%%:*} M=${1##*:}
  local P="$W/power/${R}_$M"
  E87_PLAT="$PLAT" E87_NET="$W/core.v" E87_TOP="${TOP}_core" E87_VCD="$W/runs/${R}_$M/amu.vcd" E87_SCOPE="$SCOPE" \
      E87_REP="$P" ${TIMECMD[@]+"${TIMECMD[@]}"} "$OR" -exit -no_init "$W/power/e8_7_power.tcl" \
      > "$P.log" 2> "${P}_time.txt"
  return 0
}
cp -f "$SCR/e8_7_power.tcl" "$W/power/" || exit 1
in_parallel power_one "${LIST[@]}"
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}; P="$W/power/${R}_$M"
  echo "---- model $M, $R: $(grep -E "E87P: (cells|done)" "$P.log" | tr '\n' ' ') $(tail -1 "${P}_time.txt")"
  grep -q "E87P: done" "$P.log" || { tail -20 "$P.log"; stop "power, model $M, $R (see $P.log)"; }
  python3 "$SCR/e8_7_tools.py" power --model "amu9_${R}_$M" --names "$W/names.tsv" \
      --vcd "$W/runs/${R}_$M/amu.vcd" --rep "${P}_power.rpt" --inst "${P}_instances.rpt" \
      --ann "${P}_annotation.rpt" --out "$P.json" 2>&1 | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || stop "e8_7_tools.py power, model $M, $R"
done
step_time

echo
echo "==== B5. gates and summary ===="
python3 "$SCR/e9_4_tools.py" judge --work "$W" --net "$NET" --stat "$STAT" --ref "$REF" --e91 "$E91/rtl" \
    --lib "$LIB" --runs "${LIST[@]}" --out "$OUT/e9_4_summary.json" | tee "$OUT/e9_4_summary.txt"
RC=${PIPESTATUS[0]}
# small files to the results folder (the netlists for simulation and the waveforms stay in the work folder)
mkdir -p "$OUT/power" "$OUT/runs"
cp -f "$W/syn/stage3.ys" "$W/syn/stage3.log" "$W/syn/bb.json" "$W/syn/stat_core.txt" "$W/core.v.json" \
      "$W/sim/core_sim.v.json" "$OUT/" 2>/dev/null
gzip -c "$W/names.tsv" > "$OUT/names.tsv.gz"
gzip -c "$W/wrapper_sim.v" > "$OUT/wrapper_sim.v.gz"
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}; D="$W/runs/${R}_$M"; P="$W/power/${R}_$M"
  for f in sim.log comp.log deps.txt time.txt e9ev.txt; do cp -f "$D/$f" "$OUT/runs/${f%.*}_${R}_$M.${f##*.}" 2>/dev/null; done
  cp -f "$P.log" "$P.json" "${P}_power.rpt" "${P}_annotation.rpt" "${P}_time.txt" "$OUT/power/" 2>/dev/null
  gzip -c "${P}_instances.rpt" > "$OUT/power/${R}_${M}_instances.rpt.gz" 2>/dev/null
done
step_time
echo
echo "---- files written to $OUT ----"
ls -la "$OUT" "$OUT"/*/ | sed 's/^/   /'
echo
echo "=============================================================="
echo "Finished $(date '+%Y-%m-%d %H:%M:%S'), $(( ($(date +%s) - T0) / 60 )) min."
if [ "$RC" -eq 0 ]; then echo "E9.4: all gates pass"; else echo "E9.4: NOT ALL GATES PASS, see above"; fi
echo "Pack the results for checking:"
echo "   cd $PAPER2 && tar czf reports/e9_4_results.tar.gz -C reports/e9 e9_4"
echo "Keep the waveforms $W/runs/*/amu.vcd until E9.5 is final; then they can be deleted."
echo "=============================================================="
[ "$RC" -eq 0 ]
