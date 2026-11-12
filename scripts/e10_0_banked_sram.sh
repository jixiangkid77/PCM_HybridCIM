#!/usr/bin/env bash
# =============================================================================
# e10_0_banked_sram.sh
#
# Experiment : P2R-E10.0. The SRAM pool as 25 single-port banks. The RTL reads
#              all 25 lanes of a step in one cycle, which one single-port macro
#              cannot do; E8 reported one macro (0.28 mm2) and 25 copies
#              (7.02 mm2) as bounds. A protected weight sits at pool address
#              a = layer base + slot; the protected weights of a step have
#              consecutive addresses (each pool is in weight-index order and an
#              entry is 25 consecutive weights), so with bank = a mod 25 and
#              row = a div 25 the reads of a step always fall into different
#              banks: 25 banks of 128 words hold the 3,074 weights, each read at
#              most once per cycle, with no replication and no change to the
#              address map (ROM contents, address-map unit).
# Design     : rtl/e10/sram_pool_25bank_2c.v (same ports, parameters and
#              two-cycle timing as rtl/e8/sram_pool_25lane_2c.v; the bank and row
#              of each lane from the lowest hit address: one multiply by 1311 and
#              shift by 15 for div 25, a 5-bit difference per lane);
#              rtl/e10/sram_bank_128x8.v (one bank, behavioural; black box for
#              synthesis: rtl/e10/sram_bank_128x8_stub.v); rtl/e10/pcm_imc_unit_e10.v
#              = the E8.5e unit (rtl/e8/pcm_imc_unit_e8c.v) with U_SPOOL replaced.
#
# Steps
#   0  the tables: consecutive slots per entry, no two reads of a step in one
#      bank, deepest row (scripts/e10_0_tables_check.py)
#   1  unit test U1 (rtl/e10/tb/tb_sram_pool_bank.v): the banked pool against
#      sram_pool_25lane_2c, random pool and random steps with consecutive
#      addresses, 200,000 cycles
#   2  full inference, models A and B, cache (normal) and conce (the strict mode
#      of E8.5c, -DE85C_READ_ONCE), with the monitors of E8.2, E8.5, E8.5c and
#      E8.5e; every output compared with E8.5e (reports/e8_rom/e8_5e/)
#   3  Yosys, flow B as E8.5e: the banked pool with the banks as black boxes
#      (the logic E10 adds: bank selection, rows, the output selection)
#
# Gates (written before the run)
#   T0  tables: 0 entries with non-consecutive slots, 0 steps with two reads in
#       one bank (25 banks), deepest row < 128, both models
#   U1  0 output mismatches, >= 100,000 lane reads; the pool's own line: 0
#       conflict cycles, 0 address errors
#   G1  every run: ALL TESTS PASSED, inference complete at cycle 617573
#   G2  results, E8.2 and E8.5 traces, E8.5e events: byte for byte the files of
#       E8.5e (cache against cache, conce against conce)
#   G3  E10 POOL line of every run: conflict cycles 0, address errors 0, deepest
#       row < 128; conce runs (the pool sees its hits only in the cycle of the
#       datapath start, one clock pulse per operation as the clock-gated macro):
#       lane reads 149543 (A) / 88064 (B), the SRAM macro reads of E8.5e G4. In
#       the cache runs the behavioural pool reads in every cycle its hits are
#       held, so their count is reported, not gated.
#   S1  synthesis exit 0; netlist and sta netlist cell lines equal; no lpflow /
#       probe cells
#
# Files (all NEW; nothing existing is changed)
#   rtl/e10/      sram_pool_25bank_2c.v sram_bank_128x8.v sram_bank_128x8_stub.v
#                 pcm_imc_unit_e10.v e10_0_manifest.md5
#   rtl/e10/tb/   tb_sram_pool_bank.v
#   scripts/      e10_0_banked_sram.sh e10_0_tables_check.py
# Used, unchanged: rtl/src, rtl/tb, rtl/e8 (and rtl/e8/tb), data/, the E8.5e
#   results reports/e8_rom/e8_5e/ (the reference)
# Writes : /home/kid/p2r_e10/e10_0/ (work), reports/e10/e10_0/ (results)
# Run    : cd /mnt/d/Project/hybrid_memory/paper2
#          bash scripts/e10_0_banked_sram.sh 2>&1 | tee reports/e10_0_banked_sram.log
# Options: E8_JOBS (simulations at a time, default 2), E8_WORK, E8_YOSYS, E8_LIB
# Runtime: a 2-core test machine (2026-11-10): unit test about 10 min, each inference
#          run 15-30 min. Estimate here: 30-60 min.
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
WORK="${E8_WORK:-/home/kid/p2r_e10/e10_0}"
OUT="$PAPER2/reports/e10/e10_0"
YS="${E8_YOSYS:-/home/kid/oss-cad-suite/bin/yosys}"
LIB="${E8_LIB:-/home/kid/sky130/orfs/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib}"   # as E8.5e
JOBS="${E8_JOBS:-2}"
case "$JOBS" in ''|*[!0-9]*) echo "ERROR: E8_JOBS must be a whole number (got '$JOBS')" >&2; exit 1 ;; esac
[ "$JOBS" -ge 1 ] || JOBS=1

T0=$(date +%s)
NFAIL=0
step_time() { echo "   [$(date '+%H:%M:%S'), $(( $(date +%s) - T0 )) s since the start]"; }
gate() {   # $1 = exit status of a check (0 = pass), $2 = label
  if [ "$1" -eq 0 ]; then echo "  PASS  $2"; else echo "  FAIL  $2"; NFAIL=$((NFAIL + 1)); fi
}

echo "=============================================================="
echo "P2R-E10.0 banked SRAM pool (RTL), started $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
cd "$PAPER2" || exit 1
echo "---- delivered files against the manifest ----"
md5sum -c "$E10/e10_0_manifest.md5" || { echo "ERROR: a delivered file differs from the manifest (see above)."; exit 1; }
for M in A B; do
  for R in cache conce; do
    for K in res e8t e85t e85e; do
      [ -e "$REF/${K}_${R}_$M.txt" ] || { echo "ERROR: missing $REF/${K}_${R}_$M.txt (E8.5e result)" >&2; exit 1; }
    done
  done
  [ -e "$REF/conv1_cache_$M.hex" ] || { echo "ERROR: missing $REF/conv1_cache_$M.hex (E8.5e)" >&2; exit 1; }
  [ -d "$PAPER2/data/rtl_inputs_${M}_v3" ] || { echo "ERROR: missing $PAPER2/data/rtl_inputs_${M}_v3" >&2; exit 1; }
done
echo "---- E8.5e results used as the reference ----"
md5sum "$REF"/res_{cache,conce}_{A,B}.txt | sed 's/^/   /'
command -v iverilog > /dev/null || { echo "ERROR: iverilog not found" >&2; exit 1; }
echo "iverilog : $(command -v iverilog)  $(iverilog -V 2>&1 | head -1)"
echo "python3  : $(command -v python3)  $(python3 --version 2>&1)"
echo "yosys    : $YS  $("$YS" -V 2>&1 | head -1)"
echo "liberty  : $(md5sum "$LIB" | cut -c1-32)  $LIB"
echo "jobs     : at most $JOBS simulations at a time (E8_JOBS)"
mkdir -p "$WORK" "$OUT" || exit 1
FREE_KB=$(df -Pk "$WORK" | awk 'NR == 2 {print $4}')
echo "disk     : $((FREE_KB / 1024 / 1024)) GB free for $WORK"
[ "$FREE_KB" -ge 1048576 ] || { echo "ERROR: less than 1 GB free for $WORK" >&2; exit 1; }
[ -e "$WORK/data" ] || ln -s "$PAPER2/data" "$WORK/data"
if command -v /usr/bin/time > /dev/null 2>&1; then TIMECMD=(/usr/bin/time -f "%e s wall, %M kB peak"); else TIMECMD=(); fi

# ---------------------------------------------------------------------------
cd "$WORK" || exit 1
echo
echo "==== 0. tables ===="
python3 "$SCR/e10_0_tables_check.py" --paper2 "$PAPER2" > tables_check.log 2>&1
RC=$?
sed 's/^/   /' tables_check.log
gate $RC "T0 consecutive slots, no two reads of a step in one bank, rows < 128"
cp -f tables_check.log "$OUT/"
[ $RC -eq 0 ] || { echo "Nothing further is run."; exit 1; }
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 1. unit test U1 ===="
iverilog -g2012 -o u1.vvp "$E8/sram_pool_25lane_2c.v" "$E10/sram_bank_128x8.v" "$E10/sram_pool_25bank_2c.v" \
    "$E10TB/tb_sram_pool_bank.v" > u1_compile.log 2>&1 && vvp u1.vvp > u1.log 2>&1
cat u1_compile.log u1.log | grep -v "finish called" | sed 's/^/   /'
grep -q "^U1 PASS" u1.log && grep -q "E10 POOL: .*conflict cycles 0, address errors 0" u1.log
gate $? "U1 unit test"
cp -f u1.log u1_compile.log "$OUT/"
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 2. full inference: cache, conce (strict mode); models A and B ===="
TOPS=(-s tb_lenet5_full_inference_v3 -s e8_lookup_monitor -s e8_5_amu_monitor -s e8_5c_monitor -s e8_5e_monitor)
MONS=("$TBD/tb_lenet5_full_inference_v3.v" "$TBD/e8_lookup_monitor.v" "$E8TB/e8_5_amu_monitor.v" "$E8TB/e8_5c_monitor.v"
      "$E8TB/e8_5e_monitor.v")
NEWF=("$E10/pcm_imc_unit_e10.v" "$E8/conv1_cache.v" "$E10/sram_pool_25bank_2c.v" "$E10/sram_bank_128x8.v")
for M in A B; do
  DEFS=(-DLOAD_REAL_DATA)
  [ "$M" = B ] && DEFS+=(-DMODEL_B)
  for R in cache conce; do
    case $R in
      cache) X=(-DE8_AS_PCM_IMC_UNIT) ;;
      conce) X=(-DE8_AS_PCM_IMC_UNIT -DE85C_READ_ONCE) ;;
    esac
    iverilog -g2012 "${DEFS[@]}" "${X[@]}" -I "$E10" -I "$E8" -I "$SRC" -y "$SRC" -y "$E8" -Y .v "${TOPS[@]}" \
        -M "deps_${R}_$M.txt" -o "${R}_$M.vvp" "${MONS[@]}" "${NEWF[@]}" > "comp_${R}_$M.log" 2>&1
    RC=$?
    echo "model $M, $R: iverilog exit $RC"; sed 's/^/   /' "comp_${R}_$M.log"
    [ $RC -eq 0 ] || { echo "COMPILE FAILED. Nothing further is run."; exit 1; }
  done
done
echo "---- G0: the unit and the pool of the compile (model A, cache) ----"
sort -u deps_cache_A.txt | grep -E "pcm_imc_unit|sram_pool|sram_bank|conv1_cache" | while read -r f; do
  printf "   %s  %s\n" "$(md5sum "$f" | cut -c1-12)" "$f"; done
! grep -qE "rtl/src/pcm_imc_unit.v|pcm_imc_unit_e8c.v|sram_pool_25lane" deps_cache_A.txt
gate $? "G0 compile list: rtl/e10 unit and banked pool, none of the E8.5e unit, rtl/src unit or the 25-port pool"
echo "---- simulate, started $(date '+%F %T') ----"
run_one() {   # $1 = run, $2 = model
  local R=$1 M=$2 t0
  t0=$(date +%s)
  ${TIMECMD[@]+"${TIMECMD[@]}"} vvp "${R}_$M.vvp" "+e8_trace=$WORK/e8t_${R}_$M.txt" "+e85_trace=$WORK/e85t_${R}_$M.txt" \
      "+e85_events=$WORK/e85e_${R}_$M.txt" "+e85c_results=$WORK/res_${R}_$M.txt" \
      "+e85e_cache=$REF/conv1_cache_$M.hex" > "sim_${R}_$M.log" 2> "time_${R}_$M.txt"
  echo $? > "sim_${R}_$M.rc"
  echo "$(( $(date +%s) - t0 )) s" >> "time_${R}_$M.txt"
}
LIST=(cache:A conce:A cache:B conce:B)
i=0
while [ $i -lt ${#LIST[@]} ]; do
  n=0
  while [ $n -lt "$JOBS" ] && [ $i -lt ${#LIST[@]} ]; do
    E=${LIST[$i]}; run_one "${E%%:*}" "${E##*:}" &
    i=$((i + 1)); n=$((n + 1))
  done
  wait
done
for E in "${LIST[@]}"; do
  R=${E%%:*}; M=${E##*:}
  echo "---- model $M, $R: vvp exit $(cat "sim_${R}_$M.rc"), $(tr '\n' ' ' < "time_${R}_$M.txt")"
  grep -E "inference complete|ALL TESTS|E10 POOL|E8.5e MONITOR|E8.5c MONITOR|FAIL" "sim_${R}_$M.log" | sed "s/^/   $R  /"
done
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 3. checks ===="
for M in A B; do
  case $M in A) NREAD=149543 ;; B) NREAD=88064 ;; esac
  for R in cache conce; do
    L="sim_${R}_$M.log"
    grep -q "ALL TESTS PASSED" "$L" && grep -q "inference complete at cycle 617573" "$L"
    gate $? "G1 model $M $R: all tests passed, inference complete at cycle 617573"
    bad=0
    for K in res e8t e85t e85e; do
      if cmp -s "${K}_${R}_$M.txt" "$REF/${K}_${R}_$M.txt"; then echo "   $K: identical to E8.5e"
      else echo "   $K: DIFFERS from E8.5e"; bad=1; fi
    done
    [ $bad -eq 0 ]; gate $? "G2 model $M $R: results, traces and events identical to E8.5e"
    PL=$(grep -m1 "^E10 POOL:" "$L")
    echo "   $PL"
    python3 - "$PL" "$R" "$NREAD" <<'PY'
import re, sys
line, run, nread = sys.argv[1], sys.argv[2], int(sys.argv[3])
m = re.search(r"lane reads (\d+), bank reads (\d+).*conflict cycles (\d+), address errors (\d+), deepest row (-?\d+)", line)
if not m:
    print("   no E10 POOL line"); sys.exit(1)
lane, bank, conf, aerr, deep = map(int, m.groups())
ok = conf == 0 and aerr == 0 and 0 <= deep < 128 and bank == lane and (run != "conce" or lane == nread)
print(f"   lane reads {lane}{' (expected ' + str(nread) + ')' if run == 'conce' else ''}, bank reads {bank}, "
      f"conflict cycles {conf}, address errors {aerr}, deepest row {deep}")
sys.exit(0 if ok else 1)
PY
    gate $? "G3 model $M $R: no conflict, no address error, rows < 128$( [ "$R" = conce ] && echo ", $NREAD lane reads")"
  done
done
for M in A B; do
  for R in cache conce; do
    cp -f "sim_${R}_$M.log" "comp_${R}_$M.log" "deps_${R}_$M.txt" "res_${R}_$M.txt" "$OUT/"
  done
done
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 4. Yosys, flow B as E8.5e: the banked pool, banks as black boxes ===="
YSF="$WORK/bankpool_syn.ys"
cat > "$YSF" <<'YSEOF'
# P2R-E10.0: sram_pool_25bank_2c with the 25 banks as black boxes, flow B of P2R-E3 as in E8.5e
read_liberty -lib @LIB@
read_verilog -sv @E10@/sram_bank_128x8_stub.v
read_verilog -sv -DSYNTHESIS @E10@/sram_pool_25bank_2c.v
hierarchy -top sram_pool_25bank_2c
synth -top sram_pool_25bank_2c
tee -o @OUT@/bankpool_stat_after_synth.txt stat

dfflegalize -cell $_DFF_?_ 01 -cell $_DFFE_??_ 01 -cell $_DFF_???_ 01 -cell $_DFFE_????_ 01 -cell $_SDFFCE_????_ 01
opt_expr
opt_merge
opt_clean
tee -o @OUT@/bankpool_stat_after_transform.txt stat

clockgate -liberty @LIB@ -dont_use sky130_fd_sc_hd__sdlclkp*
tee -o @OUT@/bankpool_stat_after_clockgate.txt stat

dfflibmap -liberty @LIB@ -dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe*
abc -liberty @LIB@ -dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe*
clean

tee -o @OUT@/bankpool_stat_final.txt stat -liberty @LIB@
write_verilog @OUT@/bankpool_netlist.v
write_verilog -noattr @OUT@/bankpool_sta.v
YSEOF
sed -i -e "s|@LIB@|$LIB|g" -e "s|@E10@|$E10|g" -e "s|@OUT@|$OUT|g" "$YSF"
cp -f "$YSF" "$OUT/"
"$YS" -q -l "$WORK/bankpool_syn.log" -s "$YSF" > /dev/null 2>&1
RC=$?
echo "---- yosys exit $RC"
cp -f "$WORK/bankpool_syn.log" "$OUT/"
grep -iE "warning" "$WORK/bankpool_syn.log" | sort | uniq -c | sort -rn | head -12 | sed 's/^/   /'
echo "   RAW: final area (logic only; the 25 banks are black boxes)"
grep -E "Chip area for (top )?module|used for sequential" "$OUT/bankpool_stat_final.txt" | tail -2 | sed 's/^/   /'
echo "   RAW: black-box banks and sequential cells in the netlist"
grep -c "sram_bank_128x8 " "$OUT/bankpool_sta.v" | sed 's/^/   banks instantiated: /'
grep -oE "sky130_fd_sc_hd__(s?e?df[a-z0-9_]+|dlclkp_[0-9]+|dlxtp_[0-9]+)" "$OUT/bankpool_sta.v" | sort | uniq -c | sort -rn | sed 's/^/   /'
N1=$(grep -c "sky130_fd_sc_hd__" "$OUT/bankpool_netlist.v"); N2=$(grep -c "sky130_fd_sc_hd__" "$OUT/bankpool_sta.v")
NLP=$(grep -c "sky130_fd_sc_hd__\(lpflow\|probe\)" "$OUT/bankpool_sta.v")
echo "   cell lines: netlist $N1, sta $N2; lpflow / probe cells $NLP"
[ "$RC" -eq 0 ] && [ "$N1" -eq "$N2" ] && [ "$NLP" -eq 0 ]; gate $? "S1 synthesis of the banked pool"
step_time

echo
echo "---- files written to $OUT ----"
ls -la "$OUT"
echo
echo "=============================================================="
echo "Finished $(date '+%Y-%m-%d %H:%M:%S'), $(( ($(date +%s) - T0) / 60 )) min."
if [ "$NFAIL" -eq 0 ]; then echo "All gates pass."; else echo "$NFAIL GATE(S) FAILED, see above."; fi
echo "=============================================================="
