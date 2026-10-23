#!/usr/bin/env bash
# =============================================================================
# e8_5_amu.sh
#
# Experiment : P2R-E8.5. The address-map unit (AMU) that replaces the 50
#              combinational address decoders of pcm_imc_unit with the r48 ROM
#              macros of E8.4a-7, read with the T1 timing and parked as in
#              E8.6a: equivalence with the unchanged design, the ROM clock
#              pulses of a full inference, and the logic area.
# Decisions  : KID 2026-10-15: read ahead, engines unchanged; an 8-entry
#              buffer per table; one shared entry computation, each lane
#              compares its own address and an error is raised when they
#              disagree.
#
# Steps
#   1  parking word of each of the 400 macros, per model (the choice E8.6a-2
#      used for D) -> rtl/e8/amu_park_A.vh, amu_park_B.vh
#   2  unit tests: entry arithmetic over all 8 x 65,536 (layer, address)
#      pairs; lane check on every engine address pattern and on random
#      addresses
#   3  engine level, A and B: the unchanged conv / fc engines run the whole
#      operation sequence against the original unit (REF, rtl/src) and the
#      E8.5 unit (NEW) on one bus; every operation's 25 + 25 hit,
#      out-of-range and pool-address outputs compared; ROM protocol and the
#      parking rule at every macro
#   4  full inference, A and B: the unchanged testbench and E8.2 monitor with
#      the E8.5 unit, and the unchanged design again (baseline, the E8.2
#      compile); every ROM clock pulse of the E8.5 runs recorded
#   5  Yosys 0.68+36, flow B of E3 (flip-flop transform + clock gating, same
#      commands; one process instead of two, the design is small), amu_top
#      with the 200 ROM macros as black boxes, A and B -> area, cells,
#      netlists
#   6  information for the gate-level power step (prints only, runs nothing)
#
# Gates (a failed gate stops nothing that is already running, but nothing is
# computed from a failed run)
#   U1  entry: 0 mismatches; lanes: 0 pattern mismatches, 0 silent mismatches
#   U2  engine level, A and B (scripts/e8_5_check.py engine): 16684 = 16684
#       operations, 0 mismatches, errors 000, 0 parking-rule violations,
#       0 macros left unparked, ROM protocol 0 / 0 / 0, clock low >= 90 ns
#       before lookups and >= 50 ns before parks, watchdogs 00000
#   F0  the E8.5 compile uses rtl/e8/pcm_imc_unit_e8.v and none of
#       rtl/src/pcm_imc_unit.v, sram_addr_decoder.v, pcm_addr_decoder.v
#   F1-F6 (scripts/e8_5_check.py full), A and B: G1 of E8.2 in both runs;
#       baseline and E8.5 traces equal to the E8.2 trace line by line; lookup
#       pulses read their entry's word; unit errors 000, parking rule, macro
#       reads of the models = reads implied by the pulses, ROM protocol
#   S1  Yosys exit 0 for A and B, no lpflow / probe cells, the two netlists of
#       each model have the same cells
#
# Files (all NEW; nothing existing is changed)
#   rtl/e8/      amu_top.v amu_core.v amu_entry.v amu_lanes.v amu_table.v
#                amu_buf.v amu_pflags.v pcm_imc_unit_e8.v e8_rom_r48.v
#                e8_rom_r48_stub.v e8_5_manifest.md5
#   rtl/e8/tb/   tb_amu_entry_exh.v tb_amu_lanes.v tb_amu_engines.v
#                e8_5_amu_monitor.v
#   scripts/     e8_5_amu.sh e8_5_park_words.py e8_5_check.py
#   generated    rtl/e8/amu_park_A.vh, rtl/e8/amu_park_B.vh
# Used, unchanged: rtl/src/*.v, rtl/tb/tb_lenet5_full_inference_v3.v,
#   rtl/tb/e8_lookup_monitor.v, scripts/e8_6a2_rom_energy.py, data/,
#   reports/e8_rom/trace/trace_{A,B}.txt (E8.2),
#   reports/e8_rom/e8_4b/model.json (E8.4b parking-word choices)
# Writes : /home/kid/p2r_e8/e8_5/ (work), reports/e8_rom/e8_5/ (results)
# Run    : cd /mnt/d/Project/hybrid_memory/paper2
#          tar xzf <download folder>/e8_5_package.tgz      (once)
#          bash scripts/e8_5_amu.sh 2>&1 | tee reports/e8_5_amu.log
# Runtime: the whole script in the sandbox (2 cores, same folder layout, made-up
#          table contents): 11 min (engine level 4 min, full inference 6 min,
#          Yosys 40 s). Estimate here: 10-20 min. Light on memory (< 1 GB).
# =============================================================================
set -uo pipefail

PAPER2=/mnt/d/Project/hybrid_memory/paper2
SRC="$PAPER2/rtl/src"
TBD="$PAPER2/rtl/tb"
E8="$PAPER2/rtl/e8"
E8TB="$E8/tb"
SCR="$PAPER2/scripts"
E82="$PAPER2/reports/e8_rom/trace"
WORK=/home/kid/p2r_e8/e8_5
OUT="$PAPER2/reports/e8_rom/e8_5"
YS=/home/kid/oss-cad-suite/bin/yosys
LIB=/home/kid/sky130/orfs/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib

T0=$(date +%s)
NFAIL=0
step_time() { echo "   [$(date '+%H:%M:%S'), $(( $(date +%s) - T0 )) s since the start]"; }
gate() {   # $1 = exit status of a check (0 = pass), $2 = label
  if [ "$1" -eq 0 ]; then echo "  PASS  $2"; else echo "  FAIL  $2"; NFAIL=$((NFAIL + 1)); fi
}

echo "=============================================================="
echo "P2R-E8.5 address-map unit, started $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
cd "$PAPER2" || exit 1
echo "---- delivered files against the manifest ----"
md5sum -c "$E8/e8_5_manifest.md5" || { echo "ERROR: a delivered file differs from the manifest (see above)."; exit 1; }
for F in "$SRC/pcm_imc_unit.v" "$SRC/sram_addr_decoder.v" "$SRC/pcm_addr_decoder.v" "$SRC/conv_engine.v" \
         "$SRC/fc_engine.v" "$SRC/lenet5_top.v" "$TBD/tb_lenet5_full_inference_v3.v" "$TBD/e8_lookup_monitor.v" \
         "$SCR/e8_6a2_rom_energy.py" "$E82/trace_A.txt" "$E82/trace_B.txt" "$LIB" "$YS"; do
  [ -e "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
for D in "$PAPER2/data/rtl_inputs_A_v3" "$PAPER2/data/rtl_inputs_B_v3"; do
  [ -d "$D" ] || { echo "ERROR: missing $D" >&2; exit 1; }
done
echo "---- unchanged files used (md5) ----"
md5sum "$SRC/pcm_imc_unit.v" "$SRC/sram_addr_decoder.v" "$SRC/pcm_addr_decoder.v" "$SRC/conv_engine.v" \
       "$SRC/fc_engine.v" "$SRC/lenet5_top.v" "$TBD/tb_lenet5_full_inference_v3.v" "$TBD/e8_lookup_monitor.v" \
       "$SCR/e8_6a2_rom_energy.py" "$E82/trace_A.txt" "$E82/trace_B.txt" "$LIB" | sed 's/^/   /'
echo "   (E8.2: tb_lenet5_full_inference_v3.v 23ff16d1cb27dcad218dd56097866545)"
echo "iverilog : $(command -v iverilog)  $(iverilog -V 2>&1 | head -1)"
echo "python3  : $(command -v python3)  $(python3 --version 2>&1)"
echo "yosys    : $YS  $("$YS" -V 2>&1 | head -1)"
mkdir -p "$WORK" "$OUT" || exit 1
[ -e "$WORK/data" ] || ln -s "$PAPER2/data" "$WORK/data"

# ---------------------------------------------------------------------------
echo
echo "==== 1. parking words (E8.6a-2 choice) ===="
python3 "$SCR/e8_5_park_words.py" --paper2 "$PAPER2"; RC=$?
gate $RC "parking words written (exit $RC)"
[ $RC -eq 0 ] || { echo "Nothing further is run."; exit 1; }
md5sum "$E8/amu_park_A.vh" "$E8/amu_park_B.vh" | sed 's/^/   /'
cp -f "$E8/amu_park_A.vh" "$E8/amu_park_B.vh" "$OUT/"
step_time

# ---------------------------------------------------------------------------
cd "$WORK" || exit 1
echo
echo "==== 2. unit tests ===="
iverilog -g2012 -o u_entry.vvp "$E8/amu_entry.v" "$E8TB/tb_amu_entry_exh.v" > u_entry_compile.log 2>&1 \
  && vvp u_entry.vvp > u_entry.log 2>&1
cat u_entry_compile.log u_entry.log | grep -v "finish called" | sed 's/^/   /'
grep -qE "exhaustive check: 524288 vectors, [0-9]+ valid lookups, 0 mismatches" u_entry.log; gate $? "U1 entry arithmetic, all (layer, address) pairs"
iverilog -g2012 -o u_lanes.vvp "$E8/amu_entry.v" "$E8/amu_lanes.v" "$E8TB/tb_amu_lanes.v" > u_lanes_compile.log 2>&1 \
  && vvp u_lanes.vvp > u_lanes.log 2>&1
cat u_lanes_compile.log u_lanes.log | grep -v "finish called" | sed 's/^/   /'
grep -qE "engine pattern: [0-9]+ lane lookups \([0-9]+ FC dummy lanes\), 0 mismatches" u_lanes.log; gate $? "U1 lane check, engine patterns"
grep -qE "random addresses: [0-9]+ lane lookups, [0-9]+ flagged, 0 silent mismatches" u_lanes.log; gate $? "U1 lane check, random addresses"
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 3. engine level (REF = rtl/src unit, NEW = E8.5 unit), A and B in parallel ===="
for M in A B; do
  DEFS=()
  [ "$M" = B ] && DEFS=(-DMODEL_B '-DDATA_DIR_STR="data/rtl_inputs_B_v3"')
  iverilog -g2012 "${DEFS[@]}" -I "$E8" -I "$E8TB" -y "$SRC" -y "$E8" -Y .v -s tb_amu_engines \
      -M "eng_deps_$M.txt" -o "eng_$M.vvp" "$E8TB/tb_amu_engines.v" "$E8/pcm_imc_unit_e8.v" > "eng_compile_$M.log" 2>&1
  RC=$?
  echo "Model $M: iverilog exit $RC"; sed 's/^/   /' "eng_compile_$M.log"
  [ $RC -eq 0 ] || { echo "COMPILE FAILED. Nothing further is run."; exit 1; }
done
for M in A B; do
  ( /usr/bin/time -f "%e s wall, %M kB peak" vvp "eng_$M.vvp" > "eng_$M.log" 2> "eng_${M}_time.txt"; echo $? > "eng_$M.rc" ) &
done
wait
for M in A B; do
  echo "---- model $M: vvp exit $(cat "eng_$M.rc"), $(tail -1 "eng_${M}_time.txt")"
  grep -v "Unable to open" "eng_$M.log" | grep -v "finish called" | sed 's/^/   /'
  python3 "$SCR/e8_5_check.py" engine --log "eng_$M.log"; gate $? "U2 engine level, model $M"
  cp -f "eng_$M.log" "eng_compile_$M.log" "eng_deps_$M.txt" "$OUT/"
done
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 4. full inference: E8.5 unit and baseline, A and B (four runs in parallel) ===="
for M in A B; do
  DEFS=(-DLOAD_REAL_DATA)
  [ "$M" = B ] && DEFS+=(-DMODEL_B)
  iverilog -g2012 "${DEFS[@]}" -DE8_AS_PCM_IMC_UNIT -I "$E8" -I "$SRC" -y "$SRC" -y "$E8" -Y .v \
      -s tb_lenet5_full_inference_v3 -s e8_lookup_monitor -s e8_5_amu_monitor -M "full_e8_deps_$M.txt" \
      -o "full_e8_$M.vvp" "$TBD/tb_lenet5_full_inference_v3.v" "$TBD/e8_lookup_monitor.v" \
      "$E8TB/e8_5_amu_monitor.v" "$E8/pcm_imc_unit_e8.v" > "full_e8_compile_$M.log" 2>&1
  RC1=$?
  iverilog -g2012 "${DEFS[@]}" -I "$SRC" -y "$SRC" -Y .v \
      -s tb_lenet5_full_inference_v3 -s e8_lookup_monitor -M "base_deps_$M.txt" \
      -o "base_$M.vvp" "$TBD/tb_lenet5_full_inference_v3.v" "$TBD/e8_lookup_monitor.v" > "base_compile_$M.log" 2>&1
  RC2=$?
  echo "Model $M: iverilog exit E8.5 $RC1, baseline $RC2"
  sed 's/^/   /' "full_e8_compile_$M.log" "base_compile_$M.log"
  [ $RC1 -eq 0 ] && [ $RC2 -eq 0 ] || { echo "COMPILE FAILED. Nothing further is run."; exit 1; }
  ! grep -qE "rtl/src/(pcm_imc_unit|sram_addr_decoder|pcm_addr_decoder)\.v" "full_e8_deps_$M.txt" \
    && grep -q "rtl/e8/pcm_imc_unit_e8.v" "full_e8_deps_$M.txt"
  gate $? "F0 model $M: the E8.5 compile uses rtl/e8/pcm_imc_unit_e8.v and not the original unit or decoders"
done
echo "---- source files of the E8.5 compile (model A), with checksums ----"
sort -u full_e8_deps_A.txt | while read -r f; do printf "   %s  %s\n" "$(md5sum "$f" | cut -c1-12)" "$f"; done
echo "---- simulate, started $(date '+%F %T') ----"
for M in A B; do
  ( /usr/bin/time -f "%e s wall, %M kB peak" vvp "full_e8_$M.vvp" "+e8_trace=$WORK/e8_trace_$M.txt" \
      "+e85_trace=$WORK/e85_trace_$M.txt" "+e85_events=$WORK/e85_events_$M.txt" \
      > "full_e8_$M.log" 2> "full_e8_${M}_time.txt"; echo $? > "full_e8_$M.rc" ) &
  ( /usr/bin/time -f "%e s wall, %M kB peak" vvp "base_$M.vvp" "+e8_trace=$WORK/base_trace_$M.txt" \
      > "base_$M.log" 2> "base_${M}_time.txt"; echo $? > "base_$M.rc" ) &
done
wait
for M in A B; do
  echo "---- model $M: E8.5 vvp exit $(cat "full_e8_$M.rc"), $(tail -1 "full_e8_${M}_time.txt");" \
       "baseline vvp exit $(cat "base_$M.rc"), $(tail -1 "base_${M}_time.txt")"
  grep -E "inference complete|SRAM protected-weight|raw lane-cycles|RESULT|E8 MONITOR|E8.5 MONITOR|FAIL" "full_e8_$M.log" | sed 's/^/   E8.5  /'
  grep -E "inference complete|SRAM protected-weight|raw lane-cycles|RESULT|E8 MONITOR|FAIL" "base_$M.log" | sed 's/^/   base  /'
  python3 "$SCR/e8_5_check.py" full --model "$M" --e82-trace "$E82/trace_$M.txt" \
      --base-log "base_$M.log" --base-trace "base_trace_$M.txt" --e85-log "full_e8_$M.log" \
      --ext-trace "e8_trace_$M.txt" --go-trace "e85_trace_$M.txt" --events "e85_events_$M.txt" --out "$OUT"
  gate $? "F1-F6 full inference, model $M"
  cp -f "full_e8_$M.log" "base_$M.log" "full_e8_compile_$M.log" "base_compile_$M.log" "full_e8_deps_$M.txt" \
        "e8_trace_$M.txt" "e85_trace_$M.txt" "e85_events_$M.txt" "base_trace_$M.txt" "$OUT/"
done
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 5. Yosys, flow B of E3, amu_top (ROM macros as black boxes) ===="
for M in A B; do
  YSF="$WORK/amu_syn_$M.ys"
  # Quoted heredoc so the Yosys cell patterns keep their dollar signs; @..@ substituted below.
  cat > "$YSF" <<'YSEOF'
# P2R-E8.5: amu_top, flow B of P2R-E3 (Yosys 0.68+36). Same commands as
# scripts/yosys_e3s1_b.ys + yosys_e3s2_b.ys, in one process.
read_liberty -lib @LIB@
read_verilog -sv @DEF@ -I @E8@ @E8@/amu_entry.v @E8@/amu_lanes.v @E8@/amu_core.v @E8@/amu_buf.v @E8@/amu_pflags.v @E8@/amu_table.v @E8@/amu_top.v
read_verilog -sv @E8@/e8_rom_r48_stub.v
synth -top amu_top
tee -o @OUT@/amu_@M@_stat_after_synth.txt stat

dfflegalize -cell $_DFF_?_ 01 -cell $_DFFE_??_ 01 -cell $_DFF_???_ 01 -cell $_DFFE_????_ 01 -cell $_SDFFCE_????_ 01
opt_expr
opt_merge
opt_clean
tee -o @OUT@/amu_@M@_stat_after_transform.txt stat

clockgate -liberty @LIB@ -dont_use sky130_fd_sc_hd__sdlclkp*
tee -o @OUT@/amu_@M@_stat_after_clockgate.txt stat

dfflibmap -liberty @LIB@ -dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe*
abc -liberty @LIB@ -dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe*
clean

tee -o @OUT@/amu_@M@_stat_final.txt stat -liberty @LIB@
write_verilog @OUT@/amu_top_@M@_netlist.v
write_verilog -noattr @OUT@/amu_top_@M@_sta.v
YSEOF
  DEF=""; [ "$M" = B ] && DEF="-DMODEL_B"
  sed -i -e "s|@LIB@|$LIB|g" -e "s|@E8@|$E8|g" -e "s|@OUT@|$OUT|g" -e "s|@M@|$M|g" -e "s|@DEF@|$DEF|g" "$YSF"
  cp -f "$YSF" "$OUT/"
done
for M in A B; do
  ( /usr/bin/time -v "$YS" -q -l "$WORK/amu_syn_$M.log" "$WORK/amu_syn_$M.ys" 2> "$WORK/amu_syn_${M}_resource.txt"
    echo $? > "$WORK/amu_syn_$M.rc" ) &
done
wait
for M in A B; do
  RC=$(cat "$WORK/amu_syn_$M.rc")
  echo "---- model $M: yosys exit $RC; $(grep -E "Elapsed \(wall" "$WORK/amu_syn_${M}_resource.txt" | sed 's/^\s*//'); $(grep -E "Maximum resident" "$WORK/amu_syn_${M}_resource.txt" | sed 's/^\s*//')"
  cp -f "$WORK/amu_syn_$M.log" "$OUT/"
  grep -iE "warning" "$WORK/amu_syn_$M.log" | sort | uniq -c | sort -rn | head -12 | sed 's/^/   /'
  echo "   RAW: final area"
  grep -E "Chip area for top module|used for sequential" "$OUT/amu_${M}_stat_final.txt" | tail -2 | sed 's/^/   /'
  python3 "$SCR/e8_5_check.py" syn --stat "$OUT/amu_${M}_stat_final.txt" | sed 's/^/   /'
  echo "   RAW: sequential and clock-gating cells in the netlist"
  grep -oE "sky130_fd_sc_hd__(s?e?df[a-z0-9_]+|dlclkp_[0-9]+|dlxtp_[0-9]+)" "$OUT/amu_top_${M}_sta.v" | sort | uniq -c | sort -rn | sed 's/^/   /'
  N1=$(grep -c "sky130_fd_sc_hd__" "$OUT/amu_top_${M}_netlist.v"); N2=$(grep -c "sky130_fd_sc_hd__" "$OUT/amu_top_${M}_sta.v")
  NLP=$(grep -c "sky130_fd_sc_hd__\(lpflow\|probe\)" "$OUT/amu_top_${M}_sta.v")
  NROM=$(grep -cE "^\s*e8_rom_r48 " "$OUT/amu_top_${M}_sta.v")
  echo "   cell lines: netlist $N1, sta $N2; lpflow / probe cells $NLP; ROM black-box instances $NROM (200 expected)"
  [ "$RC" -eq 0 ] && [ "$N1" -eq "$N2" ] && [ "$NLP" -eq 0 ]; gate $? "S1 synthesis, model $M"
done
step_time

# ---------------------------------------------------------------------------
echo
echo "==== 6. information for the gate-level power step (nothing is run) ===="
echo "---- build/ (gate-level runs of E5) ----"
ls -la "$PAPER2/build" 2>/dev/null | head -25
echo "---- build/compile_gate.log, first 25 lines ----"
head -25 "$PAPER2/build/compile_gate.log" 2>/dev/null
echo "---- files that mention tb_lenet5_gate ----"
grep -rlI "tb_lenet5_gate" "$PAPER2/scripts" "$PAPER2/rtl/sim" "$PAPER2/build" 2>/dev/null | grep -v "e8_5_amu.sh" | head -10
grep -n "tb_lenet5_gate\|sky130_fd_sc_hd\.v\|primitives\.v" ~/.bash_history 2>/dev/null | tail -10
echo "---- standard-cell Verilog models on this machine ----"
timeout 120 find /home/kid -maxdepth 8 \( -name "sky130_fd_sc_hd.v" -o -name "primitives.v" \
     -o -name "sky130_fd_sc_hd__dfxtp_1.v" -o -name "sky130_fd_sc_hd__dlclkp_1.v" \) 2>/dev/null | head -20
echo "   (end)"

# ---------------------------------------------------------------------------
echo
echo "---- files written to $OUT ----"
ls -la "$OUT"
echo
echo "=============================================================="
echo "Finished $(date '+%Y-%m-%d %H:%M:%S'), $(( ($(date +%s) - T0) / 60 )) min."
if [ "$NFAIL" -eq 0 ]; then echo "All gates pass."; else echo "$NFAIL GATE(S) FAILED, see above."; fi
echo "=============================================================="
