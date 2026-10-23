#!/usr/bin/env bash
# =============================================================================
# e8_5c_sram2c.sh
#
# Experiment : P2R-E8.5c. Two-cycle read of the protected-weight SRAM in the
#              RTL. E8.4c resume3 (2026-10-18): the 4 KB OpenRAM macro does
#              not read within one 100 MHz cycle (F2 no) but does when its
#              clock stays low for the next cycle (F2b yes). The pool model
#              (the macro) gets one more output stage. SRAM_LATENCY, the
#              combiner and lenet5_top are NOT changed: the combiner
#              already takes the SRAM sum in cycle s+3 (pcm_crossbar's
#              result comes in cycle s+9, alignment 6), the first cycle a
#              two-cycle read can give it; start -> result is 10 cycles.
# Decision   : KID 2026-10-18 11:47 (corrected option; the 11:20 one with
#              SRAM_LATENCY 2 -> 3 rested on a wrong timing estimate).
#              Only new files (rtl/e8); rtl/src and the E8.5 files are not
#              changed.
#
# Steps
#   1  unit test U1: rtl/e8/sram_pool_25lane_2c.v against the unchanged
#      rtl/src/sram_pool_25lane.v one cycle earlier (random contents and
#      stimulus, a sweep of every address on every lane, a reset)
#   2  full inference, models A and B, three designs each:
#        base  the E8.5 design (rtl/e8/pcm_imc_unit_e8.v with rtl/src
#              sram_pool_25lane.v), as in E8.5
#        new   rtl/e8/pcm_imc_unit_e8s.v + sram_pool_25lane_2c.v
#        once  new with -DE85C_READ_ONCE: the pool reads only in the
#              cycle of the datapath start (one read per operation, as
#              the clock-gated macro) and holds each read for one cycle
#              only, so the results stay right only if the combiner
#              takes the SRAM sum in exactly the right cycle
#      all three with the unchanged rtl/src/lenet5_top.v
#      with the unchanged testbench, the E8.2 and E8.5 monitors and the
#      E8.5c monitor (rtl/e8/tb/e8_5c_monitor.v); E8_JOBS runs at a time
#   3  checks (scripts/e8_5c_check.py), A and B
#
# Gates (written before the run; claude/p2r-e8-5c-sandbox.md)
#   U1  0 mismatches, >= 200000 cycles, every address on every lane, reset
#   F0  compile file lists: only the intended files swapped
#   F1  every run: ALL TESTS PASSED, inference complete at cycle 617573,
#       SRAM reads 267143 (A) / 205664 (B)
#   F2  E8.2 monitor traces: base = E8.2 trace; new, once = base
#   F3  E8.5 traces and ROM events: new, once = base; base = E8.5 files
#   F4  results of the unit (cycle, value of every result): new, once = base;
#       every result 10 cycles after its datapath start
#   F5  SRAM_LATENCY / ALIGN_DELAY 2 / 6 in all runs; 16684 datapath starts; SRAM reads = testbench count; no two reads
#       of one lane less than 2 cycles apart; once: no pool hit outside
#       the datapath start
#   F6  E8.5 monitor summaries identical in the three runs
#
# Files (all NEW; nothing existing is changed)
#   rtl/e8/      sram_pool_25lane_2c.v pcm_imc_unit_e8s.v
#                e8_5c_manifest.md5 e8_5c_inputs.md5
#   rtl/e8/tb/   e8_5c_monitor.v tb_sram_pool_2c.v
#   scripts/     e8_5c_sram2c.sh e8_5c_check.py
# Used, unchanged (checked against e8_5c_inputs.md5 and the E8.5 manifest):
#   rtl/src/*.v, rtl/tb/tb_lenet5_full_inference_v3.v,
#   rtl/tb/e8_lookup_monitor.v, the E8.5 files in rtl/e8 and rtl/e8/tb,
#   rtl/e8/amu_park_{A,B}.vh, data/, reports/e8_rom/trace/trace_{A,B}.txt
#   (E8.2), reports/e8_rom/e8_5/e85_{trace,events}_{A,B}.txt (E8.5)
# Writes : /home/kid/p2r_e8/e8_5c/ (work), reports/e8_rom/e8_5c/ (results).
#          Nothing that E8.4b reads or writes; it can run while E8.4b runs.
# Run    : cd /mnt/d/Project/hybrid_memory/paper2
#          tar xzf e8_5c_package.tgz
#          bash scripts/e8_5c_sram2c.sh 2>&1 | tee reports/e8_5c_sram2c.log
# Options: E8_JOBS (simulations at a time, default 2)
# Runtime: sandbox (2 cores): unit test 1 min, each inference run 4-6 min.
#          Estimate here: 10-25 min. Memory < 1 GB.
# =============================================================================
set -uo pipefail

PAPER2=/mnt/d/Project/hybrid_memory/paper2
SRC="$PAPER2/rtl/src"
TBD="$PAPER2/rtl/tb"
E8="$PAPER2/rtl/e8"
E8TB="$E8/tb"
SCR="$PAPER2/scripts"
E82="$PAPER2/reports/e8_rom/trace"
E85="$PAPER2/reports/e8_rom/e8_5"
WORK=/home/kid/p2r_e8/e8_5c
OUT="$PAPER2/reports/e8_rom/e8_5c"
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
echo "P2R-E8.5c two-cycle SRAM read (RTL), started $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
cd "$PAPER2" || exit 1
echo "---- delivered files against the manifest ----"
md5sum -c "$E8/e8_5c_manifest.md5" || { echo "ERROR: a delivered file differs from the manifest (see above)."; exit 1; }
echo "---- unchanged inputs (E8.5 and before) against their checksums ----"
md5sum -c "$E8/e8_5c_inputs.md5" || { echo "ERROR: an input differs from the E8.5 run (see above). Nothing is run."; exit 1; }
md5sum -c "$E8/e8_5_manifest.md5" | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "ERROR: an E8.5 file differs from its manifest. Nothing is run."; exit 1; }
for F in "$E85/e85_trace_A.txt" "$E85/e85_trace_B.txt" "$E85/e85_events_A.txt" "$E85/e85_events_B.txt"; do
  [ -e "$F" ] || { echo "ERROR: missing $F (E8.5 result)" >&2; exit 1; }
done
md5sum "$E85/e85_trace_A.txt" "$E85/e85_trace_B.txt" "$E85/e85_events_A.txt" "$E85/e85_events_B.txt" | sed 's/^/   /'
for D in "$PAPER2/data/rtl_inputs_A_v3" "$PAPER2/data/rtl_inputs_B_v3"; do
  [ -d "$D" ] || { echo "ERROR: missing $D" >&2; exit 1; }
done
command -v iverilog > /dev/null || { echo "ERROR: iverilog not found" >&2; exit 1; }
echo "iverilog : $(command -v iverilog)  $(iverilog -V 2>&1 | head -1)"
echo "python3  : $(command -v python3)  $(python3 --version 2>&1)"
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
echo "==== 1. unit test U1: two-cycle pool against the one-cycle pool ===="
iverilog -g2012 -o u2c.vvp "$SRC/sram_pool_25lane.v" "$E8/sram_pool_25lane_2c.v" "$E8TB/tb_sram_pool_2c.v" > u2c_compile.log 2>&1 \
  && vvp u2c.vvp > u2c.log 2>&1
cat u2c_compile.log u2c.log | grep -v "finish called" | sed 's/^/   /'
python3 "$SCR/e8_5c_check.py" unit --log u2c.log; gate $? "U1 unit test"
cp -f u2c.log u2c_compile.log "$OUT/"
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 2. full inference: base (E8.5 design), new, once; models A and B ===="
TOPS=(-s tb_lenet5_full_inference_v3 -s e8_lookup_monitor -s e8_5_amu_monitor -s e8_5c_monitor)
MONS=("$TBD/tb_lenet5_full_inference_v3.v" "$TBD/e8_lookup_monitor.v" "$E8TB/e8_5_amu_monitor.v" "$E8TB/e8_5c_monitor.v")
NEWF=("$E8/pcm_imc_unit_e8s.v" "$E8/sram_pool_25lane_2c.v")
for M in A B; do
  DEFS=(-DLOAD_REAL_DATA)
  [ "$M" = B ] && DEFS+=(-DMODEL_B)
  for R in base new once; do
    case $R in
      base) X=(-DE8_AS_PCM_IMC_UNIT); FILES=("$E8/pcm_imc_unit_e8.v") ;;
      new)  X=(-DE8_AS_PCM_IMC_UNIT); FILES=("${NEWF[@]}") ;;
      once) X=(-DE8_AS_PCM_IMC_UNIT -DE85C_READ_ONCE); FILES=("${NEWF[@]}") ;;
    esac
    iverilog -g2012 "${DEFS[@]}" "${X[@]}" -I "$E8" -I "$SRC" -y "$SRC" -y "$E8" -Y .v "${TOPS[@]}" \
        -M "deps_${R}_$M.txt" -o "${R}_$M.vvp" "${MONS[@]}" "${FILES[@]}" > "comp_${R}_$M.log" 2>&1
    RC=$?
    echo "model $M, $R: iverilog exit $RC"; sed 's/^/   /' "comp_${R}_$M.log"
    [ $RC -eq 0 ] || { echo "COMPILE FAILED. Nothing further is run."; exit 1; }
  done
done
echo "---- source files of the new compile (model A), with checksums ----"
sort -u deps_new_A.txt | while read -r f; do printf "   %s  %s\n" "$(md5sum "$f" | cut -c1-12)" "$f"; done
echo "---- simulate, started $(date '+%F %T') ----"
run_one() {   # $1 = run, $2 = model
  local R=$1 M=$2 t0
  t0=$(date +%s)
  ${TIMECMD[@]+"${TIMECMD[@]}"} vvp "${R}_$M.vvp" "+e8_trace=$WORK/e8t_${R}_$M.txt" "+e85_trace=$WORK/e85t_${R}_$M.txt" \
      "+e85_events=$WORK/e85e_${R}_$M.txt" "+e85c_results=$WORK/res_${R}_$M.txt" > "sim_${R}_$M.log" 2> "time_${R}_$M.txt"
  echo $? > "sim_${R}_$M.rc"
  echo "$(( $(date +%s) - t0 )) s" >> "time_${R}_$M.txt"
}
LIST=(base:A new:A once:A base:B new:B once:B)
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
  grep -E "inference complete|SRAM protected-weight|raw lane-cycles|RESULT|E8 MONITOR|E8.5 MONITOR|E8.5c MONITOR|E8.5c\]|FAIL" \
      "sim_${R}_$M.log" | sed "s/^/   $R  /"
done
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 3. checks ===="
for M in A B; do
  echo "---- model $M ----"
  python3 "$SCR/e8_5c_check.py" full --model "$M" --work "$WORK" --e82-trace "$E82/trace_$M.txt" --e85-dir "$E85"
  gate $? "F0-F6 model $M"
done
for M in A B; do
  for R in base new once; do
    cp -f "sim_${R}_$M.log" "comp_${R}_$M.log" "deps_${R}_$M.txt" "e8t_${R}_$M.txt" "e85t_${R}_$M.txt" \
          "e85e_${R}_$M.txt" "res_${R}_$M.txt" "$OUT/"
  done
done
step_time

echo
echo "---- files written to $OUT ----"
ls -la "$OUT"
echo
echo "=============================================================="
echo "Finished $(date '+%Y-%m-%d %H:%M:%S'), $(( ($(date +%s) - T0) / 60 )) min."
if [ "$NFAIL" -eq 0 ]; then echo "All gates pass."; else echo "$NFAIL GATE(S) FAILED, see above."; fi
echo "=============================================================="
