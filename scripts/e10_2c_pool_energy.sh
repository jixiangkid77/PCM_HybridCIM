#!/usr/bin/env bash
# =============================================================================
# e10_2c_pool_energy.sh
#
# Experiment : P2R-E10.2c. The banked SRAM pool with clock gating of E10.2a (cg)
#              in the unit without the conv1 cache: RTL check of the whole
#              inference, and the energy of the pool logic over one whole inference
#              at gate level, by the method of E8.7 and E10.2a.
# Why        : E10.2b takes the conv1 cache out of the chip (E8.7: 4.628 / 4.578 uJ
#              per inference, 48,356 um2). Without it every SRAM read of the datapath
#              goes to the banks: 267,143 / 205,664 reads per inference (E8.5c)
#              instead of 149,543 / 88,064 (E10.2a). E10.2a measured the pool logic
#              in the unit with the cache, so it is measured again here.
# The unit   : rtl/e10/pcm_imc_unit_e10n.v = rtl/e8/pcm_imc_unit_e8s.v (the E8.5c
#              unit, no conv1 cache) with the banked pool sram_pool_25bank_2c in place
#              of the 25-port pool (same parameters, same ports); nothing else changed.
# The pool   : part A: rtl/e10/sram_pool_25bank_2c_cg.v (E10.2a), RTL;
#              part B: the E10.2a netlist reports/e10/e10_2a/rtl_cg/bankpool_cg_sta.v
#              byte for byte (its md5 is in rtl/e10/e10_2c_manifest.md5), at gate level
#              inside the RTL full inference, as in E10.2a.
#
# Part A (RTL)
#   A1  full inference with the cg pool in the unit without the cache: models A and B,
#       cache and conce, compared with E8.5c (new and once)
# Part B (gate level)
#   B1  the logic netlist with the E8.7 tools (stage 3, plain names and wrapper, check
#       E1; the simulation netlist, check C1) and the completed wrapper
#       (e10_2a_tools.py wrapper), as E10.2a
#   B2  compiles: the A1 compiles with the synthesised pool instead of the RTL pool
#       (PDK cell models with -DFUNCTIONAL) and the waveform module rtl/e10/tb/e10_2a_vcd.v
#   B3  the runs (E8_JOBS at a time); each writes the waveform of the pool logic
#   B4  power of the logic netlist with each waveform (scripts/e8_7_power.tcl), energy
#       per inference (scripts/e8_7_tools.py power)
#   B5  gates and summary (scripts/e10_2c_tools.py judge)
#
# Gates (written before the run in protocol P2R-E10.2c of 2026-11-11)
#   Part A, per run: G0 the compile has the unit without the cache and the cg pool, and
#     not the conv1 cache, the ng pool, the E10 / E8.5 / E8.5c / E8.5e units, the rtl/src
#     unit or the 25-port pool; G1 ALL TESTS PASSED, cycle 617573; G2 results, E8.2 and
#     E8.5 traces, E8.5 events byte for byte those of E8.5c (cache: new, conce: once);
#     G3 the E10 POOL line: bank reads = lane reads, 0 conflict cycles, 0 address errors,
#     deepest row below 128; conce: 267143 / 205664 lane reads (the SRAM reads of E8.5c).
#     Part B is run only if all pass.
#   Part B: S1 the netlist is that of E10.2a byte for byte, 25 bank black boxes, 375
#     flip-flops, at least 25 clock gates, no lpflow / probe cells; E1; C1; per run G0
#     (the synthesised pool and cell models, no RTL pool, no cache), G1, G2, G3 (bank
#     reads = those of its RTL run; conce: 267143 / 205664), W (waveform window),
#     A1 (annotation).
# For E10.2b : the pool logic of cg in the conce runs (the configuration whose bank reads
#              are the 267,143 / 205,664 reads of the SRAM energy); cache next to it.
#
# Files      : NEW scripts/e10_2c_pool_energy.sh, scripts/e10_2c_tools.py,
#              rtl/e10/pcm_imc_unit_e10n.v, rtl/e10/e10_2c_manifest.md5
# Used, unchanged (md5 in rtl/e10/e10_2c_manifest.md5 and rtl/e10/e10_0_manifest.md5):
#              rtl/e10/sram_pool_25bank_2c_cg.v, rtl/e10/tb/e10_2a_vcd.v, rtl/e10/sram_bank_128x8.v,
#              rtl/e10/sram_bank_128x8_stub.v, rtl/e8/pcm_imc_unit_e8s.v (the base of the new
#              unit), scripts/e10_2a_tools.py, scripts/e8_7_tools.py, scripts/e8_7_power.tcl,
#              reports/e8_rom/e8_5c/ (new, once), reports/e10/e10_2a/rtl_cg/bankpool_cg_sta.v;
#              also rtl/src, rtl/tb, rtl/e8, data/, reports/e10/e10_2a/e10_2a_summary.json
# Writes     : /home/kid/p2r_e10/e10_2c/ (work, waveforms), reports/e10/e10_2c/
# Run        : cd /mnt/d/Project/hybrid_memory/paper2
#              E8_JOBS=4 bash scripts/e10_2c_pool_energy.sh 2>&1 | tee reports/e10_2c_pool_energy.log
# Options    : E8_JOBS (simulations at a time, default 2; every step has four runs, so
#              more than 4 does not help), E8_WORK, E8_YOSYS, E8_OPENROAD, E8_PLAT,
#              E8_SKY_DIR, E8_WORK_2A (the E10.2a work folder: only to compare the B1 files)
# Runtime    : my computer (8 cores) with E8_JOBS=4: RTL runs about 5 min (four at once),
#              gate-level runs about 20-27 min (four at once), power about 2 min: about
#              30-40 min. Disk: four waveforms of 1-2 GB.
# =============================================================================
set -uo pipefail

PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
SRC="$PAPER2/rtl/src"
TBD="$PAPER2/rtl/tb"
E8="$PAPER2/rtl/e8"
E8TB="$E8/tb"
E10="$PAPER2/rtl/e10"
E10TB="$E10/tb"
SCR="$PAPER2/scripts"
REF="$PAPER2/reports/e8_rom/e8_5c"
E2A="$PAPER2/reports/e10/e10_2a"
NET="$E2A/rtl_cg/bankpool_cg_sta.v"
WORK="${E8_WORK:-/home/kid/p2r_e10/e10_2c}"
W2A="${E8_WORK_2A:-/home/kid/p2r_e10/e10_2a}/cg"
OUT="$PAPER2/reports/e10/e10_2c"
WR="$WORK/rtl"
OUTR="$OUT/rtl"
W="$WORK/cg"
O="$OUT/cg"
YS="${E8_YOSYS:-/home/kid/oss-cad-suite/bin/yosys}"
OR="${E8_OPENROAD:-/home/kid/p2r_e8/openroad/bin/openroad}"
PLAT="${E8_PLAT:-/home/kid/sky130/orfs/flow/platforms/sky130hd}"
SKY_DIR="${E8_SKY_DIR:-/home/kid/gf/pdk/ciel/sky130/versions/1e931c9417df0478df9ee6b7289202f3e87440ab/sky130A/libs.ref/sky130_fd_sc_hd/verilog}"
CELLS=("$SKY_DIR/primitives.v" "$SKY_DIR/sky130_fd_sc_hd.v")
LIB="$PLAT/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
TOP=sram_pool_25bank_2c
SCOPE=tb_lenet5_full_inference_v3/DUT/u_imc/U_SPOOL/core
STUB="$E10/sram_bank_128x8_stub.v"
CGV="$E10/sram_pool_25bank_2c_cg.v"
UNIT="$E10/pcm_imc_unit_e10n.v"
JOBS="${E8_JOBS:-2}"
case "$JOBS" in ''|*[!0-9]*) echo "ERROR: E8_JOBS must be a whole number (got '$JOBS')" >&2; exit 1 ;; esac
[ "$JOBS" -ge 1 ] || JOBS=1
LIST=(cache:A conce:A cache:B conce:B)
declare -A REFN=([cache]=new [conce]=once)      # the E8.5c run with the same pool behaviour
declare -A READS=([A]=267143 [B]=205664)        # SRAM reads per inference without the conv1 cache (E8.5c)

T0=$(date +%s)
NFAIL=0
step_time() { echo "   [$(date '+%H:%M:%S'), $(( $(date +%s) - T0 )) s since the start]"; }
stop() { echo "STOPPED: $*"; echo "Finished $(date '+%Y-%m-%d %H:%M:%S') without a result."; exit 1; }
gate() {   # $1 = exit status of a check (0 = pass), $2 = label
  if [ "$1" -eq 0 ]; then echo "  PASS  $2"; else echo "  FAIL  $2"; NFAIL=$((NFAIL + 1)); fi
}
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
echo "P2R-E10.2c the cg pool without the conv1 cache (RTL and gate level), started $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
cd "$PAPER2" || exit 1

# ---------------------------------------------------------------------------
echo
echo "==== 0. files, tools ===="
md5sum -c "$E10/e10_2c_manifest.md5" || stop "a delivered or used file differs from rtl/e10/e10_2c_manifest.md5 (above)"
md5sum -c "$E10/e10_0_manifest.md5" > /dev/null || stop "rtl/e10 differs from rtl/e10/e10_0_manifest.md5 (E10.0)"
echo "   rtl/e10 (E10.0): all files as rtl/e10/e10_0_manifest.md5"
for M in A B; do
  for R in cache conce; do
    for K in res e8t e85t e85e; do
      [ -e "$REF/${K}_${REFN[$R]}_$M.txt" ] || stop "missing $REF/${K}_${REFN[$R]}_$M.txt (E8.5c result)"
    done
  done
  [ -d "$PAPER2/data/rtl_inputs_${M}_v3" ] || stop "missing $PAPER2/data/rtl_inputs_${M}_v3"
done
for f in "$NET" "$E2A/rtl_cg/bankpool_cg_stat_final.txt" "$E2A/e10_2a_summary.json" "$LIB" \
         "$PLAT/lef/sky130_fd_sc_hd.tlef" "$PLAT/lef/sky130_fd_sc_hd_merged.lef" "${CELLS[@]}"; do
  [ -f "$f" ] || stop "missing $f"
done
echo "   E10.2a netlist (cg): $(md5sum "$NET")"
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
mkdir -p "$WORK" "$WR" "$W/syn" "$W/sim" "$W/runs" "$W/power" "$OUT" "$OUTR" || exit 1
FREE_KB=$(df -Pk "$WORK" | awk 'NR == 2 {print $4}')
echo "disk     : $((FREE_KB / 1024 / 1024)) GB free for $WORK (needs 10 GB: four waveforms of 1-2 GB)"
[ "$FREE_KB" -ge 10485760 ] || stop "less than 10 GB free for $WORK"
[ -e "$WORK/data" ] || ln -s "$PAPER2/data" "$WORK/data"
[ -e "$WR/data" ] || ln -s "$PAPER2/data" "$WR/data"
if command -v /usr/bin/time > /dev/null 2>&1; then TIMECMD=(/usr/bin/time -f "%e s wall, %M kB peak"); else TIMECMD=(); fi
step_time

# ===========================================================================
echo
echo "#### Part A: the cg pool ($CGV) in the unit without the conv1 cache ($UNIT), RTL"
cd "$WR" || exit 1
echo
echo "==== A1. full inference: cache, conce; models A and B ===="
TOPS=(-s tb_lenet5_full_inference_v3 -s e8_lookup_monitor -s e8_5_amu_monitor -s e8_5c_monitor)
MONS=("$TBD/tb_lenet5_full_inference_v3.v" "$TBD/e8_lookup_monitor.v" "$E8TB/e8_5_amu_monitor.v" "$E8TB/e8_5c_monitor.v")
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}
  DEFS=(-DLOAD_REAL_DATA -DE8_AS_PCM_IMC_UNIT)
  [ "$M" = B ] && DEFS+=(-DMODEL_B)
  [ "$R" = conce ] && DEFS+=(-DE85C_READ_ONCE)
  iverilog -g2012 "${DEFS[@]}" -I "$E10" -I "$E8" -I "$SRC" -y "$SRC" -y "$E8" -Y .v "${TOPS[@]}" \
      -M "deps_${R}_$M.txt" -o "${R}_$M.vvp" "${MONS[@]}" "$UNIT" "$CGV" "$E10/sram_bank_128x8.v" > "comp_${R}_$M.log" 2>&1
  RC=$?
  echo "model $M, $R: iverilog exit $RC"; sed 's/^/   /' "comp_${R}_$M.log"
  [ $RC -eq 0 ] || stop "compile of the cg pool without the cache, model $M, $R"
done
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}
  grep -q "pcm_imc_unit_e10n.v" "deps_${R}_$M.txt" && grep -q "sram_pool_25bank_2c_cg.v" "deps_${R}_$M.txt" && \
    ! grep -qE "conv1_cache\.v|sram_pool_25bank_2c\.v|pcm_imc_unit_e10\.v|pcm_imc_unit_e8[cs]?\.v|rtl/src/pcm_imc_unit\.v|sram_pool_25lane" "deps_${R}_$M.txt"
  gate $? "G0 model $M, $R: compile list has the unit without the cache and the cg pool; no conv1 cache, ng pool, E10 / E8.5 / E8.5c / E8.5e unit, rtl/src unit or 25-port pool"
done
echo "---- the unit, the pool and the bank model of the compile (model A, cache), with checksums ----"
sort -u deps_cache_A.txt | grep -E "pcm_imc_unit|sram_pool|sram_bank|conv1" | \
  while read -r f; do printf "   %s  %s\n" "$(md5sum "$f" | cut -c1-12)" "$f"; done
rtl_one() {   # $1 = "<run>:<model>"
  local R=${1%%:*} M=${1##*:} t0
  t0=$(date +%s)
  ${TIMECMD[@]+"${TIMECMD[@]}"} vvp -n "${R}_$M.vvp" "+e8_trace=$WR/e8t_${R}_$M.txt" "+e85_trace=$WR/e85t_${R}_$M.txt" \
      "+e85_events=$WR/e85e_${R}_$M.txt" "+e85c_results=$WR/res_${R}_$M.txt" > "sim_${R}_$M.log" 2> "time_${R}_$M.txt"
  echo $? > "sim_${R}_$M.rc"
  echo "$(( $(date +%s) - t0 )) s" >> "time_${R}_$M.txt"
}
echo "---- simulate, started $(date '+%F %T') ----"
in_parallel rtl_one "${LIST[@]}"
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}
  echo "---- model $M, $R: vvp exit $(cat "sim_${R}_$M.rc"), $(tr '\n' ' ' < "time_${R}_$M.txt")"
  grep -E "inference complete|ALL TESTS|E10 POOL|E8.5c MONITOR\] datapath|FAIL" "sim_${R}_$M.log" | sed "s/^/   $R  /"
done
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}
  L="sim_${R}_$M.log"
  grep -q "RESULT: ALL TESTS PASSED" "$L" && grep -q "inference complete at cycle 617573" "$L"
  gate $? "G1 model $M, $R: all tests passed, inference complete at cycle 617573"
  bad=0
  for K in res e8t e85t e85e; do
    cmp -s "${K}_${R}_$M.txt" "$REF/${K}_${REFN[$R]}_$M.txt" || { echo "   $K: DIFFERS from E8.5c ${REFN[$R]}"; bad=1; }
  done
  [ $bad -eq 0 ]; gate $? "G2 model $M, $R: results, traces and events identical to E8.5c (${REFN[$R]})"
  P1=$(grep -m1 "^E10 POOL:" "$L")
  echo "   $P1"
  V=$(echo "$P1" | sed -nE 's/^E10 POOL: lane reads ([0-9]+), bank reads ([0-9]+) .*conflict cycles ([0-9]+), address errors ([0-9]+), deepest row ([0-9]+).*$/\1 \2 \3 \4 \5/p')
  read -r NL NB NC NA DR <<< "$V"
  ok=1
  [ -n "$V" ] && [ "$NL" = "$NB" ] && [ "$NC" = 0 ] && [ "$NA" = 0 ] && [ "$DR" -lt 128 ] && ok=0
  if [ "$ok" -eq 0 ] && [ "$R" = conce ] && [ "$NL" != "${READS[$M]}" ]; then ok=1; fi
  if [ "$R" = conce ]; then
    gate $ok "G3 model $M, $R: bank reads = lane reads = ${READS[$M]} (E8.5c), no conflict, no address error, rows below 128"
  else
    gate $ok "G3 model $M, $R: bank reads = lane reads, no conflict, no address error, rows below 128"
  fi
  cp -f "$L" "comp_${R}_$M.log" "deps_${R}_$M.txt" "time_${R}_$M.txt" "$OUTR/"
done
step_time
[ "$NFAIL" -eq 0 ] || stop "$NFAIL gate(s) of part A failed: the pool is not measured (part B not run)"

# ===========================================================================
echo
echo "#### Part B: gate-level energy of the cg pool (the E10.2a netlist) in the unit without the conv1 cache"
echo
echo "==== B1. the logic netlist (the E8.7 tools) ===="
echo "---- cg: $NET"
cp -f "$NET" "$W/syn/n0.v" || exit 1
python3 "$SCR/e8_7_tools.py" stage3 --n0 "$W/syn/n0.v" --stubs "$STUB" --top "$TOP" --lib "$LIB" \
    --out-dir "$W/syn" 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || stop "e8_7_tools.py stage3"
"$YS" -q -l "$W/syn/stage3.log" -s "$W/syn/stage3.ys" > /dev/null 2>&1 || stop "yosys stage 3 (see $W/syn/stage3.log)"
echo "   yosys stage 3: exit 0"
python3 "$SCR/e8_7_tools.py" core --bb "$W/syn/bb.json" --raw "$W/syn/core_raw.v" --stubs "$STUB" \
    --core-out "$W/core.v" --wrapper-out "$W/wrapper.v" --names-out "$W/names.tsv" --check \
    --extra-params K DATA_WIDTH ADDR_WIDTH SRAM_TOTAL 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || stop "e8_7_tools.py core (check E1)"
python3 "$SCR/e8_7_tools.py" ctsfree --net "$W/core.v" --out "$W/sim/core_sim.v" 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || stop "e8_7_tools.py ctsfree (check C1)"
python3 "$SCR/e10_2a_tools.py" wrapper --bb "$W/syn/bb.json" --in "$W/wrapper.v" --out "$W/wrapper_sim.v"
[ $? -eq 0 ] || stop "e10_2a_tools.py wrapper"
echo "---- the same files of E10.2a (same netlist, same tools; for information, not a gate) ----"
for f in core.v sim/core_sim.v wrapper_sim.v names.tsv; do
  if [ ! -f "$W2A/$f" ]; then s="E10.2a file not found ($W2A/$f)"
  elif cmp -s "$W/$f" "$W2A/$f"; then s="same as E10.2a"
  else s="differs from E10.2a ($W2A/$f)"; fi
  echo "   $(md5sum "$W/$f" | cut -c1-12)  $f: $s"
done
step_time

echo
echo "==== B2. compiles: the synthesised pool at gate level, models A and B, cache and conce ===="
TOPS=(-s tb_lenet5_full_inference_v3 -s e8_lookup_monitor -s e8_5_amu_monitor -s e8_5c_monitor -s e10_2a_vcd)
cd "$WORK" || exit 1
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}; D="$W/runs/${R}_$M"
  mkdir -p "$D"
  DEFS=(-DLOAD_REAL_DATA -DFUNCTIONAL -DE8_AS_PCM_IMC_UNIT)
  [ "$M" = B ] && DEFS+=(-DMODEL_B)
  [ "$R" = conce ] && DEFS+=(-DE85C_READ_ONCE)
  iverilog -g2012 "${DEFS[@]}" -I "$E10" -I "$E8" -I "$SRC" -y "$SRC" -y "$E8" -Y .v "${TOPS[@]}" \
      -M "$D/deps.txt" -o "$D/sim.vvp" "${MONS[@]}" "$UNIT" "$W/wrapper_sim.v" "$W/sim/core_sim.v" \
      "$E10/sram_bank_128x8.v" "$E10TB/e10_2a_vcd.v" "${CELLS[@]}" > "$D/comp.log" 2>&1
  RC=$?
  echo "model $M, $R: iverilog exit $RC; warnings $(grep -ci warning "$D/comp.log") ($(grep -i warning "$D/comp.log" | sed 's/^.*warning: //' | sort | uniq -c | sort -rn | head -2 | tr -s ' ' | tr '\n' ';'))"
  grep -vi "warning" "$D/comp.log" | head -5 | sed 's/^/   /'
  [ $RC -eq 0 ] || stop "compile, model $M, $R"
done
echo "---- the unit, the pool and the cell models of the compile (model A, cache), with checksums ----"
sort -u "$W/runs/cache_A/deps.txt" | grep -E "pcm_imc_unit|sram_pool|sram_bank|conv1|wrapper_sim|core_sim|e10_2a_vcd|sky130_fd_sc_hd|primitives" | \
  while read -r f; do printf "   %s  %s\n" "$(md5sum "$f" | cut -c1-12)" "$f"; done
step_time

echo
echo "==== B3. runs, started $(date '+%F %T') ===="
gate_one() {   # $1 = "<run>:<model>"
  local R=${1%%:*} M=${1##*:}
  local D="$W/runs/${R}_$M" t0 key
  key="$(md5key "$D/sim.vvp")"
  if [ -f "$D/sim.done" ] && [ "$(cat "$D/sim.done")" = "$key" ] && [ -f "$D/pool.vcd" ]; then
    echo "   model $M, $R: done before with the same compile, kept"
    return 0
  fi
  rm -f "$D/sim.done" "$D/pool.vcd"
  t0=$(date +%s)
  ${TIMECMD[@]+"${TIMECMD[@]}"} vvp -n "$D/sim.vvp" "+e8_trace=$D/e8t.txt" "+e85_trace=$D/e85t.txt" \
      "+e85_events=$D/e85e.txt" "+e85c_results=$D/res.txt" "+e10_vcd=$D/pool.vcd" > "$D/sim.log" 2> "$D/time.txt"
  local rc=$?
  echo "$(( $(date +%s) - t0 )) s" >> "$D/time.txt"
  [ $rc -eq 0 ] && grep -q "RESULT: ALL TESTS PASSED" "$D/sim.log" && echo "$key" > "$D/sim.done"
  return 0
}
in_parallel gate_one "${LIST[@]}"
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}; D="$W/runs/${R}_$M"
  echo "---- model $M, $R: $(tr '\n' ' ' < "$D/time.txt"); waveform $(du -h "$D/pool.vcd" 2>/dev/null | cut -f1)"
  grep -E "inference complete|ALL TESTS|E10\.2a|E8.5c MONITOR\] datapath|FAIL" "$D/sim.log" | sed "s/^/   /"
  [ -f "$D/sim.done" ] || stop "model $M, $R: the run did not pass (see $D/sim.log)"
done
step_time

echo
echo "==== B4. power of the logic netlist with each waveform (OpenROAD, scripts/e8_7_power.tcl) ===="
power_one() {   # $1 = "<run>:<model>"
  local R=${1%%:*} M=${1##*:}
  local P="$W/power/${R}_$M"
  E87_PLAT="$PLAT" E87_NET="$W/core.v" E87_TOP="${TOP}_core" E87_VCD="$W/runs/${R}_$M/pool.vcd" E87_SCOPE="$SCOPE" \
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
  python3 "$SCR/e8_7_tools.py" power --model "cg_nc_${R}_$M" --names "$W/names.tsv" \
      --vcd "$W/runs/${R}_$M/pool.vcd" --rep "${P}_power.rpt" --inst "${P}_instances.rpt" \
      --ann "${P}_annotation.rpt" --out "$P.json" 2>&1 | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || stop "e8_7_tools.py power, model $M, $R"
done
step_time

echo
echo "==== B5. gates and summary ===="
python3 "$SCR/e10_2c_tools.py" judge --work "$W" --net "$NET" --ref "$REF" --rtl "$OUTR" \
    --e10-2a "$E2A/e10_2a_summary.json" --lib "$LIB" --runs "${LIST[@]}" \
    --out "$OUT/e10_2c_summary.json" | tee "$OUT/e10_2c_summary.txt"
RC=${PIPESTATUS[0]}
# small files to the results folder (the netlists for simulation and the waveforms stay in the work folder)
mkdir -p "$O/power"
cp -f "$W/syn/stage3.ys" "$W/syn/stage3.log" "$W/syn/bb.json" "$W/core.v.json" "$W/sim/core_sim.v.json" "$O/" 2>/dev/null
gzip -c "$W/names.tsv" > "$O/names.tsv.gz"
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}; D="$W/runs/${R}_$M"; P="$W/power/${R}_$M"
  for f in sim.log comp.log deps.txt time.txt; do cp -f "$D/$f" "$O/${f%.*}_${R}_$M.${f##*.}" 2>/dev/null; done
  cp -f "$P.log" "$P.json" "${P}_power.rpt" "${P}_annotation.rpt" "${P}_time.txt" "$O/power/" 2>/dev/null
  gzip -c "${P}_instances.rpt" > "$O/power/${R}_${M}_instances.rpt.gz" 2>/dev/null
done
step_time
echo
echo "---- files written to $OUT ----"
ls -la "$OUT" "$OUT"/*/
echo
echo "=============================================================="
echo "Finished $(date '+%Y-%m-%d %H:%M:%S'), $(( ($(date +%s) - T0) / 60 )) min."
if [ "$RC" -eq 0 ] && [ "$NFAIL" -eq 0 ]; then echo "All gates pass."; else echo "NOT ALL GATES PASS, see above."; fi
echo "Pack the results: cd $PAPER2 && tar czf reports/e10_2c_results.tar.gz -C reports/e10 e10_2c && md5sum reports/e10_2c_results.tar.gz"
echo "Keep the waveforms $W/runs/*/pool.vcd until E10.2b is final; then they can be deleted."
echo "=============================================================="
[ "$RC" -eq 0 ]
