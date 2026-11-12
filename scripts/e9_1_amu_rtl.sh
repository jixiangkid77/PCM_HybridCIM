#!/bin/bash
#===========================================================================
# e9_1_amu_rtl.sh   P2R-E9.1: the address map of E9 in RTL (one 40-bit word per entry)
#===========================================================================
# What    : 1. the ROM contents (scripts/e9_1_tables.py): one word per table entry
#              (25 assignment bits and the NOT of the count of protected weights before
#              the entry in its layer), 7 macros of 48 rows x 8 words per model; every
#              weight of both models decoded from the image alone and compared with the
#              E8.5 slot tables; model A's image compared with the table of the E9.0 probe
#           2. full inference with rtl/e9/pcm_imc_unit_e9.v (the E10.2c unit with the
#              address map of E9: rtl/e9/amu9_top.v, amu9_core.v, amu9_decode.v, ROM model
#              e9_rom.v), models A and B, normal and read-once (the E8.5c verification
#              mode), RTL; the monitor rtl/e9/tb/e9_1_amu_monitor.v writes the E8.5 trace,
#              the ROM read sequence (event list, the input of E9.3) and checks the slots of
#              every lane at every operation against the E8.5 slot tables
#           3. synthesis of amu9_top with the 7 ROM macros as black boxes (flow B of E3, as
#              E8.5e and E10.0)
#           4. gates and summary (scripts/e9_1_tools.py judge)
# Gates   : T0 decoded weights = slot tables (both models); image A = E9.0 table
#           G0 compile lists: the E9 unit and address map, the cg pool, the bank model;
#              none of the E8.5 address map, the conv1 cache or another unit
#           G1 all tests passed, inference complete at cycle 617573 (every run)
#           G2 results, E8.2 trace and E8.5 trace identical to E8.5c (new / once)
#           G3 address map: no stall, error flags 000, 0 slots different from the E8.5
#              tables, ROM protocol errors 0, clock low >= 90 ns before a lookup and
#              >= 50 ns before a parking read, parking only after a word with a zero bit,
#              model reads = event list
#           G4 banked pool: lane reads = bank reads, no conflict or address error, deepest
#              row < 128; read-once runs: 267,143 / 205,664 reads (E8.5c)
#           S1 synthesis exit 0, 7 ROM macros as black boxes
# Inputs  : rtl/src, rtl/tb, rtl/e8 (amu_entry.v, amu_lanes.v, tb/e8_5c_monitor.v), rtl/e10
#           (sram_pool_25bank_2c_cg.v, sram_bank_128x8.v), data/rtl_inputs_{A,B}_v3,
#           reports/e8_rom/e8_5c (E8.5c results), reports/e9_rom/tables (E9.0 table of A);
#           the files used are checked against rtl/e9/e9_1_manifest.md5
# Outputs : reports/e9/e9_1/  tables/ (images e9rom_{A,B}.bin/.hex, e9_1_tables.json),
#           rtl/ (compile and simulation logs, compile lists, ROM event lists e9ev_*.txt),
#           syn/ (synthesis script, log, statistics, netlists), e9_1_summary.json/.txt;
#           the traces stay in the work folder (identical to E8.5c when G2 passes)
# Place   : D:\Project\hybrid_memory\paper2\scripts\  (with e9_1_tables.py, e9_1_tools.py)
# Command : cd /mnt/d/Project/hybrid_memory/paper2
#           E8_JOBS=4 bash scripts/e9_1_amu_rtl.sh 2>&1 | tee reports/e9_1_amu_rtl.log
# Options : E8_JOBS (simulations at a time, default 2); E8_PAPER2, E9_WORK, E8_YOSYS,
#           E8_PLAT (paths)
# Runtime : my computer (8 cores), E8_JOBS=4: about 10 min
# Status  : NEW FILE.
#===========================================================================

PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
SRC="$PAPER2/rtl/src"
TBD="$PAPER2/rtl/tb"
E8="$PAPER2/rtl/e8"
E8TB="$E8/tb"
E10="$PAPER2/rtl/e10"
E9="$PAPER2/rtl/e9"
SCR="$PAPER2/scripts"
REF="$PAPER2/reports/e8_rom/e8_5c"
E90="$PAPER2/reports/e9_rom/tables/e9rom_A_40x2688_w8.bin"
WORK="${E9_WORK:-/home/kid/p2r_e9/e9_1}"
OUT="$PAPER2/reports/e9/e9_1"
YS="${E8_YOSYS:-/home/kid/oss-cad-suite/bin/yosys}"
PLAT="${E8_PLAT:-/home/kid/sky130/orfs/flow/platforms/sky130hd}"
LIB="$PLAT/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
JOBS="${E8_JOBS:-2}"
case "$JOBS" in ''|*[!0-9]*) echo "ERROR: E8_JOBS must be a whole number (got '$JOBS')" >&2; exit 1 ;; esac
[ "$JOBS" -ge 1 ] || JOBS=1
LIST=(normal:A once:A normal:B once:B)
declare -A REFN=([normal]=new [once]=once)

T0=$(date +%s)
NFAIL=0
step_time() { echo "   [$(date '+%H:%M:%S'), $(( $(date +%s) - T0 )) s since the start]"; }
stop() { echo "STOPPED: $*"; echo "Finished $(date '+%Y-%m-%d %H:%M:%S') without a result."; exit 1; }
gate() {   # $1 = exit status of a check (0 = pass), $2 = label
  if [ "$1" -eq 0 ]; then echo "  PASS  $2"; else echo "  FAIL  $2"; NFAIL=$((NFAIL + 1)); fi
}
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
echo "P2R-E9.1 the address map of E9 in RTL, started $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
cd "$PAPER2" || exit 1

echo
echo "==== 0. files, tools ===="
md5sum -c "$E9/e9_1_manifest.md5" || stop "a delivered or used file differs from rtl/e9/e9_1_manifest.md5 (above)"
for M in A B; do
  for R in normal once; do
    for K in res e8t e85t; do
      [ -e "$REF/${K}_${REFN[$R]}_$M.txt" ] || stop "missing $REF/${K}_${REFN[$R]}_$M.txt (E8.5c result)"
    done
  done
  [ -d "$PAPER2/data/rtl_inputs_${M}_v3" ] || stop "missing $PAPER2/data/rtl_inputs_${M}_v3"
done
[ -f "$LIB" ] || stop "missing $LIB"
command -v iverilog > /dev/null || stop "iverilog not found"
command -v python3 > /dev/null || stop "python3 not found"
[ -x "$YS" ] || stop "yosys not found: $YS"
echo "iverilog : $(command -v iverilog)  $(iverilog -V 2>&1 | head -1)"
echo "python3  : $(command -v python3)  $(python3 -V 2>&1)"
echo "yosys    : $YS  $("$YS" -V 2>&1 | head -1)"
echo "liberty  : $(md5sum "$LIB")"
if [ -f "$E90" ]; then echo "E9.0     : $(md5sum "$E90")"; else echo "E9.0     : $E90 not found (the T0 comparison with the E9.0 table is left out)"; E90=""; fi
echo "jobs     : at most $JOBS simulations at a time (E8_JOBS)"
mkdir -p "$WORK" "$OUT/tables" "$OUT/rtl" "$OUT/syn" || exit 1
[ -e "$WORK/data" ] || ln -s "$PAPER2/data" "$WORK/data"
if command -v /usr/bin/time > /dev/null 2>&1; then TIMECMD=(/usr/bin/time -f "%e s wall, %M kB peak"); else TIMECMD=(); fi
step_time

echo
echo "==== 1. the ROM contents (scripts/e9_1_tables.py) ===="
python3 "$SCR/e9_1_tables.py" --paper2 "$PAPER2" --out "$OUT/tables"
RC=$?
gate $RC "T0 tables: every weight decoded from the image equals the slot tables (TABLES OK)"
[ $RC -eq 0 ] || stop "the ROM contents"
step_time

echo
echo "==== 2. full inference with the address map of E9 (RTL) ===="
cd "$WORK" || exit 1
TOPS=(-s tb_lenet5_full_inference_v3 -s e8_lookup_monitor -s e9_1_amu_monitor -s e8_5c_monitor)
MONS=("$TBD/tb_lenet5_full_inference_v3.v" "$TBD/e8_lookup_monitor.v" "$E9/tb/e9_1_amu_monitor.v" "$E8TB/e8_5c_monitor.v")
NEWF=("$E9/pcm_imc_unit_e9.v" "$E9/amu9_top.v" "$E9/amu9_core.v" "$E9/amu9_decode.v" "$E9/e9_rom.v"
      "$E10/sram_pool_25bank_2c_cg.v" "$E10/sram_bank_128x8.v")
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}
  DEFS=(-DLOAD_REAL_DATA -DE8_AS_PCM_IMC_UNIT)
  [ "$M" = B ] && DEFS+=(-DMODEL_B)
  [ "$R" = once ] && DEFS+=(-DE85C_READ_ONCE)
  iverilog -g2012 "${DEFS[@]}" -I "$E9" -I "$E10" -I "$E8" -I "$SRC" -y "$SRC" -y "$E8" -Y .v "${TOPS[@]}" \
      -M "deps_${R}_$M.txt" -o "${R}_$M.vvp" "${MONS[@]}" "${NEWF[@]}" > "comp_${R}_$M.log" 2>&1
  RC=$?
  echo "model $M, $R: iverilog exit $RC"; sed 's/^/   /' "comp_${R}_$M.log"
  [ $RC -eq 0 ] || stop "compile, model $M, $R"
done
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}
  D="deps_${R}_$M.txt"
  ok=0
  for f in pcm_imc_unit_e9.v amu9_top.v amu9_core.v amu9_decode.v e9_rom.v sram_pool_25bank_2c_cg.v sram_bank_128x8.v; do
    grep -q "/$f\$" "$D" || { echo "   missing in the compile list: $f"; ok=1; }
  done
  if grep -qE "/(amu_top|amu_core|amu_table|amu_buf|amu_pflags|e8_rom_r48[a-z_]*|conv1_cache|sram_pool_25bank_2c|sram_pool_25lane[a-z0-9_]*|pcm_imc_unit[a-z0-9_]*)\.v$" \
       <(grep -vE "/(pcm_imc_unit_e9|sram_pool_25bank_2c_cg)\.v$" "$D"); then
    echo "   the compile list has a file of the E8.5 address map, the conv1 cache, the ng pool or another unit:"
    grep -vE "/(pcm_imc_unit_e9|sram_pool_25bank_2c_cg)\.v$" "$D" | \
      grep -E "/(amu_top|amu_core|amu_table|amu_buf|amu_pflags|e8_rom_r48[a-z_]*|conv1_cache|sram_pool_25bank_2c|sram_pool_25lane[a-z0-9_]*|pcm_imc_unit[a-z0-9_]*)\.v$" | sed 's/^/   /'
    ok=1
  fi
  gate $ok "G0 model $M, $R: compile list = the E9 unit, the address map of E9, the cg pool and the bank model; no E8.5 address map, conv1 cache or other unit"
done
echo "---- the files of the unit and the address map in the compile (model A, normal), with checksums ----"
sort -u deps_normal_A.txt | grep -E "/rtl/e9/|amu_|sram_pool|sram_bank|pcm_imc_unit" | \
  while read -r f; do printf "   %s  %s\n" "$(md5sum "$f" | cut -c1-12)" "$f"; done
run_one() {   # $1 = "<run>:<model>"
  local R=${1%%:*} M=${1##*:} t0
  t0=$(date +%s)
  ${TIMECMD[@]+"${TIMECMD[@]}"} vvp -n "${R}_$M.vvp" "+e9_rom=$OUT/tables/e9rom_$M.hex" \
      "+e8_trace=$WORK/e8t_${R}_$M.txt" "+e85_trace=$WORK/e85t_${R}_$M.txt" \
      "+e9_events=$WORK/e9ev_${R}_$M.txt" "+e85c_results=$WORK/res_${R}_$M.txt" \
      > "sim_${R}_$M.log" 2> "time_${R}_$M.txt"
  echo $? > "sim_${R}_$M.rc"
  echo "$(( $(date +%s) - t0 )) s" >> "time_${R}_$M.txt"
}
echo "---- simulate, started $(date '+%F %T') ----"
in_parallel run_one "${LIST[@]}"
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}
  echo "---- model $M, $R: vvp exit $(cat "sim_${R}_$M.rc"), $(tr '\n' ' ' < "time_${R}_$M.txt")"
  grep -E "inference complete|ALL TESTS|E10 POOL|E8.5c MONITOR\] datapath|\[E9 MONITOR\]|FAIL" "sim_${R}_$M.log" | sed "s/^/   /"
  cp -f "sim_${R}_$M.log" "comp_${R}_$M.log" "deps_${R}_$M.txt" "time_${R}_$M.txt" "e9ev_${R}_$M.txt" "$OUT/rtl/" 2> /dev/null
done
step_time

echo
echo "==== 3. synthesis of amu9_top, ROM macros as black boxes (flow B of E3) ===="
YSF="$OUT/syn/amu9_syn.ys"
cat > "$YSF" <<'YSEOF'
# P2R-E9.1: amu9_top with the 7 ROM macros as black boxes, flow B of P2R-E3 as in E8.5e and E10.0
read_liberty -lib @LIB@
read_verilog -sv @E9@/e9_rom_stub.v
read_verilog -sv -DSYNTHESIS @E8@/amu_entry.v @E8@/amu_lanes.v @E9@/amu9_core.v @E9@/amu9_decode.v @E9@/amu9_top.v
hierarchy -top amu9_top
synth -top amu9_top
tee -o @OUT@/amu9_stat_after_synth.txt stat

dfflegalize -cell $_DFF_?_ 01 -cell $_DFFE_??_ 01 -cell $_DFF_???_ 01 -cell $_DFFE_????_ 01 -cell $_SDFFCE_????_ 01
opt_expr
opt_merge
opt_clean
tee -o @OUT@/amu9_stat_after_transform.txt stat

clockgate -liberty @LIB@ -dont_use sky130_fd_sc_hd__sdlclkp*
tee -o @OUT@/amu9_stat_after_clockgate.txt stat

dfflibmap -liberty @LIB@ -dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe*
abc -liberty @LIB@ -dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe*
clean

tee -o @OUT@/amu9_stat_final.txt stat -liberty @LIB@
write_verilog @OUT@/amu9_netlist.v
write_verilog -noattr @OUT@/amu9_sta.v
YSEOF
sed -i -e "s|@LIB@|$LIB|g" -e "s|@E9@|$E9|g" -e "s|@E8@|$E8|g" -e "s|@OUT@|$OUT/syn|g" "$YSF"
"$YS" -q -l "$OUT/syn/amu9_syn.log" -s "$YSF" > /dev/null 2>&1
RC=$?
echo $RC > "$OUT/syn/yosys_rc.txt"
echo "---- yosys exit $RC"
grep -iE "warning" "$OUT/syn/amu9_syn.log" | sort | uniq -c | sort -rn | head -8 | sed 's/^/   /'
echo "   RAW: final area (logic only; the 7 ROM macros are black boxes)"
grep -E "Chip area for (top )?module|used for sequential" "$OUT/syn/amu9_stat_final.txt" 2> /dev/null | tail -2 | sed 's/^/   /'
echo "   RAW: ROM macros and sequential cells in the netlist"
grep -cE "^\s*e9_rom\s" "$OUT/syn/amu9_sta.v" 2> /dev/null | sed 's/^/   ROM macros instantiated: /'
grep -oE "sky130_fd_sc_hd__(s?e?df[a-z0-9_]+|dlclkp_[0-9]+|dlxtp_[0-9]+)" "$OUT/syn/amu9_sta.v" 2> /dev/null | \
  sort | uniq -c | sort -rn | sed 's/^/   /'
step_time

echo
echo "==== 4. gates and summary (scripts/e9_1_tools.py judge) ===="
JARGS=(--work "$WORK" --ref "$REF" --tables "$OUT/tables/e9_1_tables.json" --syn "$OUT/syn" --out "$OUT")
[ -n "$E90" ] && JARGS+=(--e90 "$E90")
python3 "$SCR/e9_1_tools.py" judge "${JARGS[@]}"
RC=$?
[ $RC -eq 0 ] || NFAIL=$((NFAIL + 1))
step_time

echo
echo "---- files written to $OUT ----"
ls -la "$OUT" "$OUT/tables" "$OUT/rtl" "$OUT/syn" | sed 's/^/   /'
echo
if [ "$NFAIL" -eq 0 ]; then echo "E9.1: all gates pass"; else echo "E9.1: $NFAIL gate(s) failed (see FAIL above)"; fi
echo "Pack the results for checking:"
echo "   cd $PAPER2 && tar czf reports/e9_1_results.tar.gz -C reports/e9 e9_1"
echo "Finished $(date '+%Y-%m-%d %H:%M:%S'), $(( $(date +%s) - T0 )) s"
