#!/usr/bin/env bash
# =============================================================================
# e8_5e_conv1cache.sh
#
# Experiment : P2R-E8.5e. A register cache for the 150 conv1 weights. All
#              150 conv1 weights are protected weights in the SRAM pool
#              (every conv1 entry of the 25 SRAM-side tables is a hit, in
#              both models); conv1 reads them 117,600 times per inference,
#              44.0 % (A) / 57.2 % (B) of the SRAM reads, at 86.35 pJ each
#              (E8.4c resume3). With the cache the SRAM macros are not
#              clocked during conv1.
# Decision   : KID 2026-10-19 21:34 ("all changes, including the optional
#              improvements, adopted"); RTL changes agreed.
# Design     : rtl/e8/conv1_cache.v (all added logic) between the address-map
#              unit, the pool and sram_mac; rtl/e8/pcm_imc_unit_e8c.v = the
#              E8.5c unit (pcm_imc_unit_e8s.v) with the cache. The cache
#              returns the weight in cycle s+2 like the two-cycle macro read;
#              SRAM_LATENCY, the combiner, the address-map unit, the pool
#              model, lenet5_top and the testbench are not changed.
#
# Steps
#   0  the cache contents of models A and B (scripts/e8_5e_cache_hex.py,
#      from data/rtl_inputs_<M>_v3: layer_config, conv1 SRAM tables, pool)
#   1  unit test U1 (rtl/e8/tb/tb_conv1_cache.v): random stimulus against
#      an independent reference, 200,000 cycles
#   2  full inference, models A and B: cache (normal) and conce (the strict
#      mode of E8.5c, -DE85C_READ_ONCE), with the E8.2, E8.5, E8.5c and
#      E8.5e monitors; compared with E8.5c's runs new and once
#      (reports/e8_rom/e8_5c/)
#   3  checks (scripts/e8_5e_check.py)
#   4  Yosys, flow B of E3 as E8.5, conv1_cache alone: area and cells
#
# Gates (written before the run; claude/p2r-e8-5e-sandbox.md)
#   U1  0 errors, >= 100,000 cached lane outputs, >= 1,000 cache writes
#   G0  compile file lists: e8c + conv1_cache + the two-cycle pool, none of
#       pcm_imc_unit_e8s.v, pcm_imc_unit_e8.v, rtl/src pcm_imc_unit.v and
#       sram_pool_25lane.v; all other files = E8.5c new
#   G1  every run: ALL TESTS PASSED, inference complete at cycle 617573;
#       testbench SRAM lookups 267143 (A) / 205664 (B) (unchanged)
#   G2  E8.2 monitor trace, E8.5 trace and ROM events = E8.5c new
#   G3  results (cycle, value): cache = E8.5c new, conce = E8.5c once;
#       16684 results, each 10 cycles after its datapath start
#   G4  E8.5e monitor: SRAM macro reads 149543 (A) / 88064 (B), conv1
#       macro reads 0; cache reads 117600 (4704 per lane); cache entries
#       different from the pool word 0; cache reads outside conv1 0;
#       cycles with a pool hit in conv1 0
#   G5  E8.5c and E8.5 monitor summaries = E8.5c new (once: E8.5c once)
#   S1  synthesis exit 0; netlist and sta netlist cell lines equal; no
#       lpflow / probe cells
#
# Files (all NEW; nothing existing is changed)
#   rtl/e8/      conv1_cache.v pcm_imc_unit_e8c.v e8_5e_manifest.md5
#   rtl/e8/tb/   e8_5e_monitor.v tb_conv1_cache.v
#   scripts/     e8_5e_conv1cache.sh e8_5e_check.py e8_5e_cache_hex.py
# Used, unchanged: rtl/src, rtl/tb, the E8.5 and E8.5c files (checked
#   against e8_5c_manifest.md5, e8_5c_inputs.md5, e8_5_manifest.md5),
#   data/, reports/e8_rom/e8_5c/ (E8.5c results), E8.2 and E8.5 traces
# Writes : /home/kid/p2r_e8/e8_5e/ (work), reports/e8_rom/e8_5e/ (results)
# Run    : cd /mnt/d/Project/hybrid_memory/paper2
#          bash scripts/e8_5e_conv1cache.sh 2>&1 | tee reports/e8_5e_conv1cache.log
# Options: E8_JOBS (simulations at a time, default 2)
# Runtime: sandbox (2 cores): unit test about 1 min, each inference run
#          4-6 min, synthesis about 1 min. Estimate here: 10-25 min.
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
E85C="$PAPER2/reports/e8_rom/e8_5c"
WORK="${E8_WORK:-/home/kid/p2r_e8/e8_5e}"
OUT="$PAPER2/reports/e8_rom/e8_5e"
YS="${E8_YOSYS:-/home/kid/oss-cad-suite/bin/yosys}"
LIB="${E8_LIB:-/home/kid/sky130/orfs/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib}"   # as E8.5 and E8.5b
FAKE="${E8_FAKE_DATA:-}"      # sandbox only: random data, real-data gates reported, not gated
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
echo "P2R-E8.5e conv1 register cache (RTL), started $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
cd "$PAPER2" || exit 1
echo "---- delivered files against the manifest ----"
md5sum -c "$E8/e8_5e_manifest.md5" || { echo "ERROR: a delivered file differs from the manifest (see above)."; exit 1; }
echo "---- unchanged inputs (E8.5, E8.5c) against their checksums ----"
md5sum -c "$E8/e8_5c_manifest.md5" | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "ERROR: an E8.5c file differs from its manifest. Nothing is run."; exit 1; }
md5sum -c "$E8/e8_5c_inputs.md5" | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "ERROR: an input differs from the E8.5c run. Nothing is run."; exit 1; }
md5sum -c "$E8/e8_5_manifest.md5" | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "ERROR: an E8.5 file differs from its manifest. Nothing is run."; exit 1; }
for M in A B; do
  for R in new once; do
    for K in res e8t e85t e85e sim deps; do
      case $K in sim) F="$E85C/sim_${R}_$M.log" ;; deps) F="$E85C/deps_${R}_$M.txt" ;; *) F="$E85C/${K}_${R}_$M.txt" ;; esac
      [ -e "$F" ] || { echo "ERROR: missing $F (E8.5c result)" >&2; exit 1; }
    done
  done
done
echo "---- E8.5c results used as the reference ----"
md5sum "$E85C"/res_{new,once}_{A,B}.txt | sed 's/^/   /'
for D in "$PAPER2/data/rtl_inputs_A_v3" "$PAPER2/data/rtl_inputs_B_v3"; do
  [ -d "$D" ] || { echo "ERROR: missing $D" >&2; exit 1; }
done
command -v iverilog > /dev/null || { echo "ERROR: iverilog not found" >&2; exit 1; }
echo "iverilog : $(command -v iverilog)  $(iverilog -V 2>&1 | head -1)"
echo "python3  : $(command -v python3)  $(python3 --version 2>&1)"
echo "yosys    : $YS  $("$YS" -V 2>&1 | head -1)"
echo "liberty  : $(md5sum "$LIB" | cut -c1-32)  $LIB"
echo "jobs     : at most $JOBS simulations at a time (E8_JOBS)"
[ -n "$FAKE" ] && echo "data     : FAKE (sandbox); real-data gates are reported, not gated"
mkdir -p "$WORK" "$OUT" || exit 1
FREE_KB=$(df -Pk "$WORK" | awk 'NR == 2 {print $4}')
echo "disk     : $((FREE_KB / 1024 / 1024)) GB free for $WORK"
[ "$FREE_KB" -ge 1048576 ] || { echo "ERROR: less than 1 GB free for $WORK" >&2; exit 1; }
[ -e "$WORK/data" ] || ln -s "$PAPER2/data" "$WORK/data"
if command -v /usr/bin/time > /dev/null 2>&1; then TIMECMD=(/usr/bin/time -f "%e s wall, %M kB peak"); else TIMECMD=(); fi

# ---------------------------------------------------------------------------
cd "$WORK" || exit 1
echo
echo "==== 0. cache contents ===="
for M in A B; do
  python3 "$SCR/e8_5e_cache_hex.py" --data "$PAPER2/data/rtl_inputs_${M}_v3" --out "$WORK/conv1_cache_$M.hex" \
    > "cache_hex_$M.log" 2>&1
  RC=$?
  sed 's/^/   /' "cache_hex_$M.log"
  gate $RC "C0 cache contents, model $M"
  [ $RC -eq 0 ] || { echo "Nothing further is run."; exit 1; }
  cp -f "conv1_cache_$M.hex" "cache_hex_$M.log" "$OUT/"
done
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 1. unit test U1 ===="
iverilog -g2012 -o u1.vvp "$E8/conv1_cache.v" "$E8TB/tb_conv1_cache.v" > u1_compile.log 2>&1 && vvp u1.vvp > u1.log 2>&1
cat u1_compile.log u1.log | grep -v "finish called" | sed 's/^/   /'
python3 "$SCR/e8_5e_check.py" unit --log u1.log; gate $? "U1 unit test"
cp -f u1.log u1_compile.log "$OUT/"
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 2. full inference: cache, conce (strict mode); models A and B ===="
TOPS=(-s tb_lenet5_full_inference_v3 -s e8_lookup_monitor -s e8_5_amu_monitor -s e8_5c_monitor -s e8_5e_monitor)
MONS=("$TBD/tb_lenet5_full_inference_v3.v" "$TBD/e8_lookup_monitor.v" "$E8TB/e8_5_amu_monitor.v" "$E8TB/e8_5c_monitor.v"
      "$E8TB/e8_5e_monitor.v")
NEWF=("$E8/pcm_imc_unit_e8c.v" "$E8/conv1_cache.v" "$E8/sram_pool_25lane_2c.v")
for M in A B; do
  DEFS=(-DLOAD_REAL_DATA)
  [ "$M" = B ] && DEFS+=(-DMODEL_B)
  for R in cache conce; do
    case $R in
      cache) X=(-DE8_AS_PCM_IMC_UNIT) ;;
      conce) X=(-DE8_AS_PCM_IMC_UNIT -DE85C_READ_ONCE) ;;
    esac
    iverilog -g2012 "${DEFS[@]}" "${X[@]}" -I "$E8" -I "$SRC" -y "$SRC" -y "$E8" -Y .v "${TOPS[@]}" \
        -M "deps_${R}_$M.txt" -o "${R}_$M.vvp" "${MONS[@]}" "${NEWF[@]}" > "comp_${R}_$M.log" 2>&1
    RC=$?
    echo "model $M, $R: iverilog exit $RC"; sed 's/^/   /' "comp_${R}_$M.log"
    [ $RC -eq 0 ] || { echo "COMPILE FAILED. Nothing further is run."; exit 1; }
  done
done
echo "---- source files of the cache compile (model A), with checksums ----"
sort -u deps_cache_A.txt | while read -r f; do printf "   %s  %s\n" "$(md5sum "$f" | cut -c1-12)" "$f"; done
echo "---- simulate, started $(date '+%F %T') ----"
run_one() {   # $1 = run, $2 = model
  local R=$1 M=$2 t0
  t0=$(date +%s)
  ${TIMECMD[@]+"${TIMECMD[@]}"} vvp "${R}_$M.vvp" "+e8_trace=$WORK/e8t_${R}_$M.txt" "+e85_trace=$WORK/e85t_${R}_$M.txt" \
      "+e85_events=$WORK/e85e_${R}_$M.txt" "+e85c_results=$WORK/res_${R}_$M.txt" \
      "+e85e_cache=$WORK/conv1_cache_$M.hex" > "sim_${R}_$M.log" 2> "time_${R}_$M.txt"
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
  grep -E "inference complete|SRAM protected-weight|RESULT|E8.5c MONITOR|E8.5e MONITOR|E8.5e\]|FAIL" \
      "sim_${R}_$M.log" | sed "s/^/   $R  /"
done
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 3. checks ===="
for M in A B; do
  echo "---- model $M ----"
  python3 "$SCR/e8_5e_check.py" full --model "$M" --work "$WORK" --e85c-dir "$E85C" --e82-trace "$E82/trace_$M.txt" \
      ${FAKE:+--fake-data}
  gate $? "G0-G5 model $M"
done
for M in A B; do
  for R in cache conce; do
    cp -f "sim_${R}_$M.log" "comp_${R}_$M.log" "deps_${R}_$M.txt" "e8t_${R}_$M.txt" "e85t_${R}_$M.txt" \
          "e85e_${R}_$M.txt" "res_${R}_$M.txt" "$OUT/"
  done
done
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 4. Yosys, flow B of E3 as E8.5: conv1_cache alone ===="
YSF="$WORK/c1cache_syn.ys"
cat > "$YSF" <<'YSEOF'
# P2R-E8.5e: conv1_cache, flow B of P2R-E3 as in E8.5 (scripts/e8_5_amu.sh step 5)
read_liberty -lib @LIB@
read_verilog -sv @E8@/conv1_cache.v
synth -top conv1_cache
tee -o @OUT@/c1cache_stat_after_synth.txt stat

dfflegalize -cell $_DFF_?_ 01 -cell $_DFFE_??_ 01 -cell $_DFF_???_ 01 -cell $_DFFE_????_ 01 -cell $_SDFFCE_????_ 01
opt_expr
opt_merge
opt_clean
tee -o @OUT@/c1cache_stat_after_transform.txt stat

clockgate -liberty @LIB@ -dont_use sky130_fd_sc_hd__sdlclkp*
tee -o @OUT@/c1cache_stat_after_clockgate.txt stat

dfflibmap -liberty @LIB@ -dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe*
abc -liberty @LIB@ -dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe*
clean

tee -o @OUT@/c1cache_stat_final.txt stat -liberty @LIB@
write_verilog @OUT@/conv1_cache_netlist.v
write_verilog -noattr @OUT@/conv1_cache_sta.v
YSEOF
sed -i -e "s|@LIB@|$LIB|g" -e "s|@E8@|$E8|g" -e "s|@OUT@|$OUT|g" "$YSF"
cp -f "$YSF" "$OUT/"
"$YS" -q -l "$WORK/c1cache_syn.log" -s "$YSF" > /dev/null 2>&1
RC=$?
echo "---- yosys exit $RC"
cp -f "$WORK/c1cache_syn.log" "$OUT/"
grep -iE "warning" "$WORK/c1cache_syn.log" | sort | uniq -c | sort -rn | head -12 | sed 's/^/   /'
echo "   RAW: final area"
grep -E "Chip area for (top )?module|used for sequential" "$OUT/c1cache_stat_final.txt" | tail -2 | sed 's/^/   /'
echo "   RAW: sequential and clock-gating cells in the netlist"
grep -oE "sky130_fd_sc_hd__(s?e?df[a-z0-9_]+|dlclkp_[0-9]+|dlxtp_[0-9]+)" "$OUT/conv1_cache_sta.v" | sort | uniq -c | sort -rn | sed 's/^/   /'
N1=$(grep -c "sky130_fd_sc_hd__" "$OUT/conv1_cache_netlist.v"); N2=$(grep -c "sky130_fd_sc_hd__" "$OUT/conv1_cache_sta.v")
NLP=$(grep -c "sky130_fd_sc_hd__\(lpflow\|probe\)" "$OUT/conv1_cache_sta.v")
echo "   cell lines: netlist $N1, sta $N2; lpflow / probe cells $NLP"
[ "$RC" -eq 0 ] && [ "$N1" -eq "$N2" ] && [ "$NLP" -eq 0 ]; gate $? "S1 synthesis of conv1_cache"
step_time

echo
echo "---- files written to $OUT ----"
ls -la "$OUT"
echo
echo "=============================================================="
echo "Finished $(date '+%Y-%m-%d %H:%M:%S'), $(( ($(date +%s) - T0) / 60 )) min."
if [ "$NFAIL" -eq 0 ]; then echo "All gates pass."; else echo "$NFAIL GATE(S) FAILED, see above."; fi
echo "=============================================================="
