#!/usr/bin/env bash
# =============================================================================
# e10_2a_pool_energy.sh
#
# Experiment : P2R-E10.2a. Energy of the logic of the banked SRAM pool over one
#              whole inference, by the method of E8.7: gate-level simulation of
#              the synthesised netlist with the real data, OpenSTA (OpenROAD) with
#              the tt library and a 10 ns clock, the activity of every pin from
#              the waveform. In E8.7 the 25-port pool was a black box, so none of
#              this logic is in its 21.096 / 20.561 uJ.
# Two pools  : ng = the E10.0 pool (rtl/e10/sram_pool_25bank_2c.v): its 375
#              flip-flops have no enable, so no clock gate, and the 25 banks get
#              the clock in every cycle;
#              cg = the same pool with clock gating (rtl/e10/sram_pool_25bank_2c_cg.v):
#              one clock gate per bank, enabled by its request (the bank is
#              clocked only when it reads, as the gated-read energy of E10.1
#              assumes), and one shared enable per group of stage registers;
#              outputs bit for bit those of ng.
#              Each pool netlist runs at gate level inside the RTL full inference
#              of E10.0: the rest of the chip stays RTL, so the pool gets the
#              addresses and hits of the address-map unit cycle for cycle.
#
# Part A (cg, RTL, as E10.0)
#   A1  unit test U1 (rtl/e10/tb/tb_sram_pool_bank.v against the 25-port pool)
#   A2  full inference, models A and B, cache and conce, compared with E8.5e
#   A3  Yosys flow B as E10.0 (25 banks as black boxes)
# Part B (ng and cg, gate level)
#   B1  the logic netlist with the E8.7 tools (stage 3, plain names and wrapper,
#       check E1; the simulation netlist without the buffers between the clock
#       and the bank clock pins, check C1); the wrapper completed for the run
#       (pool image, bank contents, bank-read count: e10_2a_tools.py wrapper)
#   B2  compiles: the E10.0 compile with the synthesised pool instead of the RTL
#       pool (PDK cell models with -DFUNCTIONAL, as E8.7) and the waveform module
#       rtl/e10/tb/e10_2a_vcd.v; models A and B, cache and conce
#   B3  the runs (E8_JOBS at a time); each writes the waveform of the pool logic
#   B4  power of the logic netlist with each waveform (scripts/e8_7_power.tcl),
#       energy per inference (scripts/e8_7_tools.py power)
#   B5  gates and summary (scripts/e10_2a_tools.py judge)
#
# Gates (written before the run in protocol P2R-E10.2a of 2026-11-10)
#   Part A: U1 0 mismatches, >= 100,000 lane reads, 0 conflicts, 0 address errors;
#     G0 the cg pool in the compile, not the ng pool; G1 ALL TESTS PASSED, cycle
#     617573; G2 byte for byte E8.5e; G3 the E10 POOL line of every run = that of
#     E10.0 (conce: 149543 / 88064 lane reads); S1 synthesis exit 0, netlist and
#     sta netlist cell lines equal, no lpflow / probe cells, at least 25 clock
#     gates, 375 flip-flops. Part B is run only if all pass.
#   Part B, per pool: S1 the netlist is that of E10.0 (ng) or of A3 (cg) byte for
#     byte, 25 bank black boxes, 375 flip-flops, no lpflow / probe cells, no clock
#     gate (ng) / at least the 25 bank clock gates (cg); E1; C1; per run G0 (the
#     synthesised pool and cell models in the compile, no RTL pool), G1, G2, G3
#     (bank reads = its RTL run), W (waveform window), A1 (annotation).
# Paper : the pool logic of cg in the conce runs (the configuration whose bank
#         reads are the 149,543 / 88,064 reads of the SRAM energy); ng and cache
#         next to it.
#
# Files      : NEW scripts/e10_2a_pool_energy.sh, scripts/e10_2a_tools.py,
#              rtl/e10/sram_pool_25bank_2c_cg.v, rtl/e10/tb/e10_2a_vcd.v,
#              rtl/e10/e10_2a_manifest.md5
# Used, unchanged: rtl/e10 (E10.0, rtl/e10/e10_0_manifest.md5), rtl/src, rtl/tb,
#              rtl/e8, scripts/e8_7_tools.py, scripts/e8_7_power.tcl, data/,
#              reports/e10/e10_0/ (netlist, run logs), reports/e8_rom/e8_5e/
# Writes     : /home/kid/p2r_e10/e10_2a/ (work, waveforms), reports/e10/e10_2a/
# Run        : cd /mnt/d/Project/hybrid_memory/paper2
#              E8_JOBS=4 bash scripts/e10_2a_pool_energy.sh 2>&1 | tee reports/e10_2a_pool_energy.log
# Options    : E8_JOBS (simulations at a time, default 2), E8_WORK, E8_YOSYS,
#              E8_OPENROAD, E8_PLAT, E8_SKY_DIR
# Runtime    : a 2-core test machine: unit test about 10 min, each RTL run 5-8 min,
#              each gate-level run about 10-15 min (waveform up to about 1 GB).
#              Estimate here: 40-70 min.
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
REF="$PAPER2/reports/e8_rom/e8_5e"
E10OUT="$PAPER2/reports/e10/e10_0"
WORK="${E8_WORK:-/home/kid/p2r_e10/e10_2a}"
OUT="$PAPER2/reports/e10/e10_2a"
OUTA="$OUT/rtl_cg"
WA="$WORK/rtl_cg"
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
JOBS="${E8_JOBS:-2}"
case "$JOBS" in ''|*[!0-9]*) echo "ERROR: E8_JOBS must be a whole number (got '$JOBS')" >&2; exit 1 ;; esac
[ "$JOBS" -ge 1 ] || JOBS=1
LIST=(cache:A conce:A cache:B conce:B)
VARIANTS=(ng cg)

T0=$(date +%s)
NFAIL=0
step_time() { echo "   [$(date '+%H:%M:%S'), $(( $(date +%s) - T0 )) s since the start]"; }
stop() { echo "STOPPED: $*"; echo "Finished $(date '+%Y-%m-%d %H:%M:%S') without a result."; exit 1; }
gate() {   # $1 = exit status of a check (0 = pass), $2 = label
  if [ "$1" -eq 0 ]; then echo "  PASS  $2"; else echo "  FAIL  $2"; NFAIL=$((NFAIL + 1)); fi
}
md5key() { md5sum "$@" 2>/dev/null | awk '{print $1}' | md5sum | cut -c1-16; }
in_parallel() {   # $1 = function, then the runs "<run>:<model>" (or "<pool>:<run>:<model>"), JOBS at a time
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
echo "P2R-E10.2a energy of the banked pool logic (gate level), started $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
cd "$PAPER2" || exit 1

# ---------------------------------------------------------------------------
echo
echo "==== 0. files, tools ===="
md5sum -c "$E10/e10_2a_manifest.md5" || stop "a delivered or used file differs from rtl/e10/e10_2a_manifest.md5 (above)"
md5sum -c "$E10/e10_0_manifest.md5" > /dev/null || stop "rtl/e10 differs from rtl/e10/e10_0_manifest.md5 (E10.0)"
echo "   rtl/e10 (E10.0): all files as rtl/e10/e10_0_manifest.md5"
for M in A B; do
  for R in cache conce; do
    for K in res e8t e85t e85e; do
      [ -e "$REF/${K}_${R}_$M.txt" ] || stop "missing $REF/${K}_${R}_$M.txt (E8.5e result)"
    done
    [ -e "$E10OUT/sim_${R}_$M.log" ] || stop "missing $E10OUT/sim_${R}_$M.log (E10.0 run)"
    grep -q "^E10 POOL: " "$E10OUT/sim_${R}_$M.log" || stop "no E10 POOL line in $E10OUT/sim_${R}_$M.log"
  done
  [ -e "$REF/conv1_cache_$M.hex" ] || stop "missing $REF/conv1_cache_$M.hex (E8.5e)"
  [ -d "$PAPER2/data/rtl_inputs_${M}_v3" ] || stop "missing $PAPER2/data/rtl_inputs_${M}_v3"
done
for f in "$E10OUT/bankpool_sta.v" "$E10OUT/bankpool_stat_final.txt" "$LIB" "$PLAT/lef/sky130_fd_sc_hd.tlef" \
         "$PLAT/lef/sky130_fd_sc_hd_merged.lef" "${CELLS[@]}"; do
  [ -f "$f" ] || stop "missing $f"
done
echo "   E10.0 netlist : $(md5sum "$E10OUT/bankpool_sta.v")"
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
mkdir -p "$WORK" "$WA" "$OUT" "$OUTA" || exit 1
for v in "${VARIANTS[@]}"; do mkdir -p "$WORK/$v/syn" "$WORK/$v/sim" "$WORK/$v/runs" "$WORK/$v/power" || exit 1; done
FREE_KB=$(df -Pk "$WORK" | awk 'NR == 2 {print $4}')
echo "disk     : $((FREE_KB / 1024 / 1024)) GB free for $WORK (needs 12 GB: eight waveforms of up to about 1 GB)"
[ "$FREE_KB" -ge 12582912 ] || stop "less than 12 GB free for $WORK"
[ -e "$WORK/data" ] || ln -s "$PAPER2/data" "$WORK/data"
[ -e "$WA/data" ] || ln -s "$PAPER2/data" "$WA/data"
if command -v /usr/bin/time > /dev/null 2>&1; then TIMECMD=(/usr/bin/time -f "%e s wall, %M kB peak"); else TIMECMD=(); fi
step_time

# ===========================================================================
echo
echo "#### Part A: the pool with clock gating ($CGV), RTL, as E10.0"
cd "$WA" || exit 1
echo
echo "==== A1. unit test U1 (cg) ===="
iverilog -g2012 -o u1.vvp "$E8/sram_pool_25lane_2c.v" "$E10/sram_bank_128x8.v" "$CGV" \
    "$E10TB/tb_sram_pool_bank.v" > u1_compile.log 2>&1 && vvp -n u1.vvp > u1.log 2>&1
cat u1_compile.log u1.log | grep -v "finish called" | sed 's/^/   /'
grep -q "^U1 PASS" u1.log && grep -q "E10 POOL: .*conflict cycles 0, address errors 0" u1.log
gate $? "U1 unit test of the cg pool"
cp -f u1.log u1_compile.log "$OUTA/"
step_time

echo
echo "==== A2. full inference with the cg pool: cache, conce; models A and B ===="
TOPS=(-s tb_lenet5_full_inference_v3 -s e8_lookup_monitor -s e8_5_amu_monitor -s e8_5c_monitor -s e8_5e_monitor)
MONS=("$TBD/tb_lenet5_full_inference_v3.v" "$TBD/e8_lookup_monitor.v" "$E8TB/e8_5_amu_monitor.v" "$E8TB/e8_5c_monitor.v"
      "$E8TB/e8_5e_monitor.v")
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}
  DEFS=(-DLOAD_REAL_DATA -DE8_AS_PCM_IMC_UNIT)
  [ "$M" = B ] && DEFS+=(-DMODEL_B)
  [ "$R" = conce ] && DEFS+=(-DE85C_READ_ONCE)
  iverilog -g2012 "${DEFS[@]}" -I "$E10" -I "$E8" -I "$SRC" -y "$SRC" -y "$E8" -Y .v "${TOPS[@]}" \
      -M "deps_${R}_$M.txt" -o "${R}_$M.vvp" "${MONS[@]}" "$E10/pcm_imc_unit_e10.v" "$E8/conv1_cache.v" "$CGV" \
      "$E10/sram_bank_128x8.v" > "comp_${R}_$M.log" 2>&1
  RC=$?
  echo "model $M, $R: iverilog exit $RC"; sed 's/^/   /' "comp_${R}_$M.log"
  [ $RC -eq 0 ] || stop "compile of the cg pool, model $M, $R"
done
grep -q "sram_pool_25bank_2c_cg.v" deps_cache_A.txt && ! grep -qE "sram_pool_25bank_2c\.v|rtl/src/pcm_imc_unit.v|pcm_imc_unit_e8c.v|sram_pool_25lane" deps_cache_A.txt
gate $? "G0 compile list: the cg pool and the rtl/e10 unit; not the ng pool, the E8.5e unit, rtl/src unit or 25-port pool"
rtl_one() {   # $1 = "<run>:<model>"
  local R=${1%%:*} M=${1##*:} t0
  t0=$(date +%s)
  ${TIMECMD[@]+"${TIMECMD[@]}"} vvp -n "${R}_$M.vvp" "+e8_trace=$WA/e8t_${R}_$M.txt" "+e85_trace=$WA/e85t_${R}_$M.txt" \
      "+e85_events=$WA/e85e_${R}_$M.txt" "+e85c_results=$WA/res_${R}_$M.txt" \
      "+e85e_cache=$REF/conv1_cache_$M.hex" > "sim_${R}_$M.log" 2> "time_${R}_$M.txt"
  echo $? > "sim_${R}_$M.rc"
  echo "$(( $(date +%s) - t0 )) s" >> "time_${R}_$M.txt"
}
echo "---- simulate, started $(date '+%F %T') ----"
in_parallel rtl_one "${LIST[@]}"
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}
  echo "---- model $M, $R: vvp exit $(cat "sim_${R}_$M.rc"), $(tr '\n' ' ' < "time_${R}_$M.txt")"
  grep -E "inference complete|ALL TESTS|E10 POOL|E8.5e MONITOR\] datapath|FAIL" "sim_${R}_$M.log" | sed "s/^/   $R  /"
done
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}
  L="sim_${R}_$M.log"
  grep -q "ALL TESTS PASSED" "$L" && grep -q "inference complete at cycle 617573" "$L"
  gate $? "G1 cg, model $M $R: all tests passed, inference complete at cycle 617573"
  bad=0
  for K in res e8t e85t e85e; do
    cmp -s "${K}_${R}_$M.txt" "$REF/${K}_${R}_$M.txt" || { echo "   $K: DIFFERS from E8.5e"; bad=1; }
  done
  [ $bad -eq 0 ]; gate $? "G2 cg, model $M $R: results, traces and events identical to E8.5e"
  P1=$(grep -m1 "^E10 POOL:" "$L"); P0=$(grep -m1 "^E10 POOL:" "$E10OUT/sim_${R}_$M.log")
  echo "   cg    $P1"; echo "   E10.0 $P0"
  [ -n "$P1" ] && [ "$P1" = "$P0" ] && echo "$P1" | grep -q "conflict cycles 0, address errors 0"
  gate $? "G3 cg, model $M $R: the E10 POOL line = that of E10.0 (no conflict, no address error)"
  cp -f "$L" "comp_${R}_$M.log" "deps_${R}_$M.txt" "time_${R}_$M.txt" "$OUTA/"
done
step_time

echo
echo "==== A3. Yosys, flow B as E10.0: the cg pool, banks as black boxes ===="
YSF="$WA/bankpool_cg_syn.ys"
cat > "$YSF" <<'YSEOF'
# P2R-E10.2a: sram_pool_25bank_2c (rtl/e10/sram_pool_25bank_2c_cg.v, clock gating) with the 25 banks as black
# boxes, flow B of P2R-E3 as in E8.5e and E10.0
read_liberty -lib @LIB@
read_verilog -sv @E10@/sram_bank_128x8_stub.v
read_verilog -sv -DSYNTHESIS @E10@/sram_pool_25bank_2c_cg.v
hierarchy -top sram_pool_25bank_2c
synth -top sram_pool_25bank_2c
tee -o @OUT@/bankpool_cg_stat_after_synth.txt stat

dfflegalize -cell $_DFF_?_ 01 -cell $_DFFE_??_ 01 -cell $_DFF_???_ 01 -cell $_DFFE_????_ 01 -cell $_SDFFCE_????_ 01
opt_expr
opt_merge
opt_clean
tee -o @OUT@/bankpool_cg_stat_after_transform.txt stat

clockgate -liberty @LIB@ -dont_use sky130_fd_sc_hd__sdlclkp*
tee -o @OUT@/bankpool_cg_stat_after_clockgate.txt stat

dfflibmap -liberty @LIB@ -dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe*
abc -liberty @LIB@ -dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe*
clean

tee -o @OUT@/bankpool_cg_stat_final.txt stat -liberty @LIB@
write_verilog @OUT@/bankpool_cg_netlist.v
write_verilog -noattr @OUT@/bankpool_cg_sta.v
YSEOF
sed -i -e "s|@LIB@|$LIB|g" -e "s|@E10@|$E10|g" -e "s|@OUT@|$OUTA|g" "$YSF"
cp -f "$YSF" "$OUTA/"
"$YS" -q -l "$WA/bankpool_cg_syn.log" -s "$YSF" > /dev/null 2>&1
RC=$?
echo "---- yosys exit $RC"
cp -f "$WA/bankpool_cg_syn.log" "$OUTA/"
grep -iE "warning" "$WA/bankpool_cg_syn.log" | sort | uniq -c | sort -rn | head -12 | sed 's/^/   /'
echo "   RAW: final area (logic only; the 25 banks are black boxes)"
grep -E "Chip area for (top )?module|used for sequential" "$OUTA/bankpool_cg_stat_final.txt" | tail -2 | sed 's/^/   /'
echo "   RAW: black-box banks, sequential cells and clock gates in the netlist"
NBB=$(grep -c "sram_bank_128x8 " "$OUTA/bankpool_cg_sta.v"); echo "   banks instantiated: $NBB"
grep -oE "sky130_fd_sc_hd__(s?e?df[a-z0-9_]+|dlclkp_[0-9]+|dlxtp_[0-9]+)" "$OUTA/bankpool_cg_sta.v" | sort | uniq -c | sort -rn | sed 's/^/   /'
N1=$(grep -c "sky130_fd_sc_hd__" "$OUTA/bankpool_cg_netlist.v"); N2=$(grep -c "sky130_fd_sc_hd__" "$OUTA/bankpool_cg_sta.v")
NLP=$(grep -c "sky130_fd_sc_hd__\(lpflow\|probe\)" "$OUTA/bankpool_cg_sta.v")
NCG=$(grep -cE "sky130_fd_sc_hd__dlclkp_[0-9]+ " "$OUTA/bankpool_cg_sta.v")
NFF=$(grep -cE "sky130_fd_sc_hd__(s?e?df[a-z0-9_]+) " "$OUTA/bankpool_cg_sta.v")
echo "   cell lines: netlist $N1, sta $N2; lpflow / probe cells $NLP; clock gates $NCG (25 for the banks); flip-flops $NFF"
[ "$RC" -eq 0 ] && [ "$N1" -eq "$N2" ] && [ "$NLP" -eq 0 ] && [ "$NBB" -eq 25 ] && [ "$NCG" -ge 25 ] && [ "$NFF" -eq 375 ]
gate $? "S1 synthesis of the cg pool"
step_time
[ "$NFAIL" -eq 0 ] || stop "$NFAIL gate(s) of part A failed: the cg pool is not measured (part B not run)"

# ===========================================================================
echo
echo "#### Part B: gate-level energy of both pools (ng: E10.0, cg: part A)"
echo
echo "==== B1. the logic netlists (the E8.7 tools) ===="
for v in "${VARIANTS[@]}"; do
  W="$WORK/$v"
  case $v in ng) N0="$E10OUT/bankpool_sta.v" ;; cg) N0="$OUTA/bankpool_cg_sta.v" ;; esac
  echo "---- $v: $N0"
  cp -f "$N0" "$W/syn/n0.v" || exit 1
  python3 "$SCR/e8_7_tools.py" stage3 --n0 "$W/syn/n0.v" --stubs "$STUB" --top "$TOP" --lib "$LIB" \
      --out-dir "$W/syn" 2>&1 | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || stop "$v: e8_7_tools.py stage3"
  "$YS" -q -l "$W/syn/stage3.log" -s "$W/syn/stage3.ys" > /dev/null 2>&1 || stop "$v: yosys stage 3 (see $W/syn/stage3.log)"
  echo "   yosys stage 3: exit 0"
  python3 "$SCR/e8_7_tools.py" core --bb "$W/syn/bb.json" --raw "$W/syn/core_raw.v" --stubs "$STUB" \
      --core-out "$W/core.v" --wrapper-out "$W/wrapper.v" --names-out "$W/names.tsv" --check \
      --extra-params K DATA_WIDTH ADDR_WIDTH SRAM_TOTAL 2>&1 | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || stop "$v: e8_7_tools.py core (check E1)"
  python3 "$SCR/e8_7_tools.py" ctsfree --net "$W/core.v" --out "$W/sim/core_sim.v" 2>&1 | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || stop "$v: e8_7_tools.py ctsfree (check C1)"
  python3 "$SCR/e10_2a_tools.py" wrapper --bb "$W/syn/bb.json" --in "$W/wrapper.v" --out "$W/wrapper_sim.v"
  [ $? -eq 0 ] || stop "$v: e10_2a_tools.py wrapper"
done
step_time

echo
echo "==== B2. compiles: the synthesised pools at gate level, models A and B, cache and conce ===="
TOPS=(-s tb_lenet5_full_inference_v3 -s e8_lookup_monitor -s e8_5_amu_monitor -s e8_5c_monitor -s e8_5e_monitor
      -s e10_2a_vcd)
cd "$WORK" || exit 1
ITEMS=()
for v in "${VARIANTS[@]}"; do
  W="$WORK/$v"
  for E in "${LIST[@]}"; do
    R=${E%%:*}; M=${E##*:}; D="$W/runs/${R}_$M"
    mkdir -p "$D"
    DEFS=(-DLOAD_REAL_DATA -DFUNCTIONAL -DE8_AS_PCM_IMC_UNIT)
    [ "$M" = B ] && DEFS+=(-DMODEL_B)
    [ "$R" = conce ] && DEFS+=(-DE85C_READ_ONCE)
    iverilog -g2012 "${DEFS[@]}" -I "$E10" -I "$E8" -I "$SRC" -y "$SRC" -y "$E8" -Y .v "${TOPS[@]}" \
        -M "$D/deps.txt" -o "$D/sim.vvp" "${MONS[@]}" "$E10/pcm_imc_unit_e10.v" "$E8/conv1_cache.v" "$W/wrapper_sim.v" \
        "$W/sim/core_sim.v" "$E10/sram_bank_128x8.v" "$E10TB/e10_2a_vcd.v" "${CELLS[@]}" > "$D/comp.log" 2>&1
    RC=$?
    echo "$v, model $M, $R: iverilog exit $RC; warnings $(grep -ci warning "$D/comp.log") ($(grep -i warning "$D/comp.log" | sed 's/^.*warning: //' | sort | uniq -c | sort -rn | head -2 | tr -s ' ' | tr '\n' ';'))"
    grep -vi "warning" "$D/comp.log" | head -5 | sed 's/^/   /'
    [ $RC -eq 0 ] || stop "compile of $v, model $M, $R"
    ITEMS+=("$v:$R:$M")
  done
done
echo "---- the pool, the unit and the cell models of the compiles (model A, cache) ----"
for v in "${VARIANTS[@]}"; do
  sort -u "$WORK/$v/runs/cache_A/deps.txt" | grep -E "pcm_imc_unit|sram_pool|sram_bank|wrapper_sim|core_sim|e10_2a_vcd|sky130_fd_sc_hd|primitives" | \
    while read -r f; do printf "   %s  %s  %s\n" "$v" "$(md5sum "$f" | cut -c1-12)" "$f"; done
done
step_time

echo
echo "==== B3. runs, started $(date '+%F %T') ===="
gate_one() {   # $1 = "<pool>:<run>:<model>"
  local v=${1%%:*} rest=${1#*:}
  local R=${rest%%:*} M=${rest##*:}
  local D="$WORK/$v/runs/${R}_$M" t0 key
  key="$(md5key "$D/sim.vvp" "$REF/conv1_cache_$M.hex")"
  if [ -f "$D/sim.done" ] && [ "$(cat "$D/sim.done")" = "$key" ] && [ -f "$D/pool.vcd" ]; then
    echo "   $v, model $M, $R: done before with the same compile, kept"
    return 0
  fi
  rm -f "$D/sim.done" "$D/pool.vcd"
  t0=$(date +%s)
  ${TIMECMD[@]+"${TIMECMD[@]}"} vvp -n "$D/sim.vvp" "+e8_trace=$D/e8t.txt" "+e85_trace=$D/e85t.txt" \
      "+e85_events=$D/e85e.txt" "+e85c_results=$D/res.txt" "+e85e_cache=$REF/conv1_cache_$M.hex" \
      "+e10_vcd=$D/pool.vcd" > "$D/sim.log" 2> "$D/time.txt"
  local rc=$?
  echo "$(( $(date +%s) - t0 )) s" >> "$D/time.txt"
  [ $rc -eq 0 ] && grep -q "RESULT: ALL TESTS PASSED" "$D/sim.log" && echo "$key" > "$D/sim.done"
  return 0
}
in_parallel gate_one "${ITEMS[@]}"
for I in "${ITEMS[@]}"; do
  v=${I%%:*}; rest=${I#*:}; R=${rest%%:*}; M=${rest##*:}; D="$WORK/$v/runs/${R}_$M"
  echo "---- $v, model $M, $R: $(tr '\n' ' ' < "$D/time.txt"); waveform $(du -h "$D/pool.vcd" 2>/dev/null | cut -f1)"
  grep -E "inference complete|ALL TESTS|E10\.2a|E8.5e MONITOR\] datapath|FAIL" "$D/sim.log" | sed "s/^/   /"
  [ -f "$D/sim.done" ] || stop "$v, model $M, $R: the run did not pass (see $D/sim.log)"
done
step_time

echo
echo "==== B4. power of the logic netlists with each waveform (OpenROAD, scripts/e8_7_power.tcl) ===="
power_one() {   # $1 = "<pool>:<run>:<model>"
  local v=${1%%:*} rest=${1#*:}
  local R=${rest%%:*} M=${rest##*:}
  local W="$WORK/$v" P="$WORK/$v/power/${R}_$M"
  E87_PLAT="$PLAT" E87_NET="$W/core.v" E87_TOP="${TOP}_core" E87_VCD="$W/runs/${R}_$M/pool.vcd" E87_SCOPE="$SCOPE" \
      E87_REP="$P" ${TIMECMD[@]+"${TIMECMD[@]}"} "$OR" -exit -no_init "$W/power/e8_7_power.tcl" \
      > "$P.log" 2> "${P}_time.txt"
  return 0
}
for v in "${VARIANTS[@]}"; do cp -f "$SCR/e8_7_power.tcl" "$WORK/$v/power/" || exit 1; done
in_parallel power_one "${ITEMS[@]}"
for I in "${ITEMS[@]}"; do
  v=${I%%:*}; rest=${I#*:}; R=${rest%%:*}; M=${rest##*:}; P="$WORK/$v/power/${R}_$M"
  echo "---- $v, model $M, $R: $(grep -E "E87P: (cells|done)" "$P.log" | tr '\n' ' ') $(tail -1 "${P}_time.txt")"
  grep -q "E87P: done" "$P.log" || { tail -20 "$P.log"; stop "power of $v, model $M, $R (see $P.log)"; }
  python3 "$SCR/e8_7_tools.py" power --model "${v}_${R}_$M" --names "$WORK/$v/names.tsv" \
      --vcd "$WORK/$v/runs/${R}_$M/pool.vcd" --rep "${P}_power.rpt" --inst "${P}_instances.rpt" \
      --ann "${P}_annotation.rpt" --out "$P.json" 2>&1 | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || stop "e8_7_tools.py power for $v, model $M, $R"
done
step_time

echo
echo "==== B5. gates and summary ===="
python3 "$SCR/e10_2a_tools.py" judge --work "$WORK" --variants "${VARIANTS[@]}" --ref "$REF" --e10 "$E10OUT" \
    --rtl-cg "$OUTA" --net-ng "$E10OUT/bankpool_sta.v" --net-cg "$OUTA/bankpool_cg_sta.v" \
    --stat-ng "$E10OUT/bankpool_stat_final.txt" --stat-cg "$OUTA/bankpool_cg_stat_final.txt" --lib "$LIB" \
    --runs "${LIST[@]}" --out "$OUT/e10_2a_summary.json" | tee "$OUT/e10_2a_summary.txt"
RC=${PIPESTATUS[0]}
# small files to the results folder (the netlists for simulation and the waveforms stay in the work folder)
for v in "${VARIANTS[@]}"; do
  W="$WORK/$v"; O="$OUT/$v"
  mkdir -p "$O/power"
  cp -f "$W/syn/stage3.ys" "$W/syn/stage3.log" "$W/syn/bb.json" "$W/core.v.json" "$W/sim/core_sim.v.json" "$O/" 2>/dev/null
  gzip -c "$W/names.tsv" > "$O/names.tsv.gz"
  for E in "${LIST[@]}"; do
    R=${E%%:*}; M=${E##*:}; D="$W/runs/${R}_$M"; P="$W/power/${R}_$M"
    for f in sim.log comp.log deps.txt time.txt; do cp -f "$D/$f" "$O/${f%.*}_${R}_$M.${f##*.}" 2>/dev/null; done
    cp -f "$P.log" "$P.json" "${P}_power.rpt" "${P}_annotation.rpt" "${P}_time.txt" "$O/power/" 2>/dev/null
    gzip -c "${P}_instances.rpt" > "$O/power/${R}_${M}_instances.rpt.gz" 2>/dev/null
  done
done
step_time
echo
echo "---- files written to $OUT ----"
ls -la "$OUT" "$OUT"/*/
echo
echo "=============================================================="
echo "Finished $(date '+%Y-%m-%d %H:%M:%S'), $(( ($(date +%s) - T0) / 60 )) min."
if [ "$RC" -eq 0 ] && [ "$NFAIL" -eq 0 ]; then echo "All gates pass."; else echo "NOT ALL GATES PASS, see above."; fi
echo "Pack the results: cd $PAPER2 && tar czf reports/e10_2a_results.tar.gz -C reports/e10 e10_2a && md5sum reports/e10_2a_results.tar.gz"
echo "The waveforms $WORK/*/runs/*/pool.vcd can be deleted after the results are confirmed."
echo "=============================================================="
[ "$RC" -eq 0 ]
