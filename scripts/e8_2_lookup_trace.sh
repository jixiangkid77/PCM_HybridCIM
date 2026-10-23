#!/usr/bin/env bash
# =============================================================================
# e8_2_lookup_trace.sh
#
# Experiment : P2R-E8.2. Record every address-map lookup of a full inference,
#              for Model A and Model B, and turn the record into counts.
#
# Why
#   The manuscript charges the address map 833,040 accesses per inference.
#   That number is not in any file of the project: it was derived during the
#   revision as 2 x 416,520 MACs. This run measures it, and it records which
#   ROM entry each lookup reads, which the ROM read energy has to be weighted
#   by, and the input sequence the decoder arithmetic sees, which its gate-
#   level power analysis (E8.5) needs.
#
# How
#   The unchanged testbench rtl/tb/tb_lenet5_full_inference_v3.v is compiled
#   together with a passive monitor, rtl/tb/e8_lookup_monitor.v, as a second
#   top-level module. The monitor only reads signals; it drives nothing.
#   Modules are taken from rtl/src by name (iverilog -y), and the exact list
#   of files used is written to deps_<M>.txt with their checksums.
#
# Gate G1 (reproduction, per model) - the run must reproduce the locked
#   figures before anything is computed from it:
#     RESULT: ALL TESTS PASSED
#     inference complete at cycle 617573
#     SRAM protected-weight reads (per MAC op): 267143 (A) / 205664 (B)
# Gates G2-G5 are checked by scripts/e8_2_trace_summary.py:
#     G2 its replica of the decoder arithmetic agrees with the RTL hit bits on
#        every lookup; G3 the recorded SRAM hits equal the testbench count;
#     G4 exactly one side hits on every lookup; G5 nothing after done.
#
# Files (all NEW, nothing existing is modified):
#   scripts/e8_2_lookup_trace.sh        this script
#   scripts/e8_2_trace_summary.py       post-processing
#   rtl/tb/e8_lookup_monitor.v          the monitor
# Writes : /home/kid/p2r_e8/trace/      (work directory, Linux file system)
#          reports/e8_rom/trace/        (traces, logs, summaries, counts)
# Run    : cd /mnt/d/Project/hybrid_memory/paper2
#          bash scripts/e8_2_lookup_trace.sh 2>&1 | tee reports/e8_2_lookup_trace.log
# Runtime: two RTL simulations in parallel; not measured before on this
#          design. The log records the wall time of each.
# =============================================================================
set -uo pipefail

PAPER2=/mnt/d/Project/hybrid_memory/paper2
SRC="$PAPER2/rtl/src"
TB="$PAPER2/rtl/tb/tb_lenet5_full_inference_v3.v"
MON="$PAPER2/rtl/tb/e8_lookup_monitor.v"
SUM="$PAPER2/scripts/e8_2_trace_summary.py"
WORK=/home/kid/p2r_e8/trace
OUT="$PAPER2/reports/e8_rom/trace"

declare -A SRAM_READS=( [A]=267143 [B]=205664 )

echo "=============================================================="
echo "P2R-E8.2 lookup trace, started $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
for F in "$TB" "$MON" "$SUM" "$SRC/lenet5_top.v" "$SRC/pcm_imc_unit.v" \
         "$SRC/sram_addr_decoder.v" "$SRC/pcm_addr_decoder.v"; do
  [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
for D in "$PAPER2/data/rtl_inputs_A_v3" "$PAPER2/data/rtl_inputs_B_v3"; do
  [ -d "$D" ] || { echo "ERROR: missing $D" >&2; exit 1; }
done
echo "iverilog : $(command -v iverilog)   $(iverilog -V 2>&1 | head -1)"
echo "python3  : $(command -v python3)   $(python3 --version 2>&1)"
echo "md5 testbench : $(md5sum "$TB" | cut -d' ' -f1)"
echo "md5 monitor   : $(md5sum "$MON" | cut -d' ' -f1)"

echo
echo "---- how this testbench was compiled before, for the record ----"
grep -rn "tb_lenet5_full_inference_v3" "$PAPER2/scripts" "$PAPER2/rtl/sim" 2>/dev/null \
  | grep -v "e8_" | head -10
grep -n "tb_lenet5_full_inference_v3" ~/.bash_history 2>/dev/null | tail -5
echo "   (end)"

mkdir -p "$WORK" "$OUT" || exit 1
[ -e "$WORK/data" ] || ln -s "$PAPER2/data" "$WORK/data"
cd "$WORK" || exit 1

compile_model() {
  local M=$1 DEF=""
  [ "$M" = B ] && DEF="-DMODEL_B"
  iverilog -g2012 -DLOAD_REAL_DATA $DEF -I "$SRC" -y "$SRC" -Y .v \
      -s tb_lenet5_full_inference_v3 -s e8_lookup_monitor \
      -M "deps_$M.txt" -o "sim_$M.vvp" "$TB" "$MON" > "compile_$M.log" 2>&1
}

echo
echo "---- compile ----"
for M in A B; do
  compile_model "$M"; RC=$?
  echo "Model $M: iverilog exit $RC"
  cat "compile_$M.log"
  if [ "$RC" -ne 0 ]; then echo "COMPILE FAILED. Nothing further was run." >&2; exit 1; fi
done
echo "---- source files actually compiled (Model A), with checksums ----"
sort -u deps_A.txt | while read -r f; do printf "   %s  %s\n" "$(md5sum "$f" | cut -c1-12)" "$f"; done

echo
echo "---- simulate, both models in parallel, started $(date '+%F %T') ----"
for M in A B; do
  ( /usr/bin/time -f "%e s wall, %M kB peak" vvp "sim_$M.vvp" "+e8_trace=$WORK/trace_$M.txt" \
      > "sim_$M.log" 2> "sim_${M}_time.txt"; echo $? > "sim_$M.rc" ) &
done
wait
for M in A B; do
  echo "Model $M: vvp exit $(cat "sim_$M.rc"), $(tail -1 "sim_${M}_time.txt")"
done

echo
echo "---- gate G1: reproduction of the locked figures ----"
G1=1
for M in A B; do
  L="sim_$M.log"
  for pat in "RESULT: ALL TESTS PASSED" "inference complete at cycle 617573" \
             "SRAM protected-weight reads (per MAC op): ${SRAM_READS[$M]}"; do
    if grep -qF "$pat" "$L"; then echo "  PASS  Model $M: $pat"
    else echo "  FAIL  Model $M: $pat"; G1=0; fi
  done
  grep -E "inference complete|SRAM protected-weight|RESULT|E8 MONITOR" "$L" | sed 's/^/        /'
done

cp -f trace_A.txt trace_B.txt sim_A.log sim_B.log compile_A.log compile_B.log \
      deps_A.txt deps_B.txt "$OUT/" 2>/dev/null

if [ "$G1" -ne 1 ]; then
  echo
  echo "GATE G1 FAILED: the run does not reproduce the locked figures."
  echo "Nothing is computed from it. Send this log and reports/e8_rom/trace/sim_*.log."
  exit 1
fi

echo
echo "---- gates G2-G5 and the counts ----"
RCS=0
for M in A B; do
  echo
  python3 "$SUM" --trace "$WORK/trace_$M.txt" --data "$PAPER2/data/rtl_inputs_${M}_v3" \
      --model "$M" --tb-sram-reads "${SRAM_READS[$M]}" --out "$OUT"
  RCS=$((RCS + $?))
done

echo
echo "---- files written to $OUT ----"
ls -la "$OUT"
echo
echo "=============================================================="
echo "Finished $(date '+%Y-%m-%d %H:%M:%S'). $([ $RCS -eq 0 ] && echo 'All gates pass.' || echo 'A GATE FAILED, see above.')"
echo "=============================================================="
