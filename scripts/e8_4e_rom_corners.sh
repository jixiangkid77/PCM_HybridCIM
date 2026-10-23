#!/usr/bin/env bash
# =============================================================================
# e8_4e_rom_corners.sh
#
# Experiment : P2R-E8.4e (ROM part). Energy of the address-map ROM at other
#              operating conditions: the runs of E8.4b-rel5 (part A of every
#              macro, the conv2 and fc1 trains) for two tables, at five
#              conditions, one after another, with the parking words of rel5.
# Why        : the paper's D_ROM is at tt, 25 C, 1.80 V; this gives its
#              sensitivity to process corner and temperature, and whether the
#              reads stay correct there (claude/p2r-e8-plan.md, E8.4e).
# Conditions : tt -40 C, tt 85 C, ff 25 C, ss 25 C, ff 85 C (all 1.80 V)
# Tables     : e8rom_A_pcm_l00_16x2496 (PCM side), e8rom_A_sram_l00_16x2496
#              (SRAM side), 4 macros each (E8.4a-7)
# Settings   : reltol 1e-5 (as rel5), maximum step 2 ns, CS 10 ns after the
#              clock edge, trains of 13 lookups, no drift runs, parking words
#              from reports/e8_rom/e8_4b_rel5/model.json
# First      : scripts/e8_4e_split.py (a few seconds): the split of rel5's
#              D_ROM per side into reads, parking reads, static above the
#              parked level and the parked level (leakage / words with zero
#              bits), from E8.6a-3's computation, checked against
#              reports/e8_rom/e8_6a3_rel5/d_rom.json; the comparison after the
#              runs scales each part by its own measured ratio
# Needs      : scripts/e8_4b_rom_energy.sh of 2026-10-19 (version 3) with
#              e8_4b_energy_tools.py and e8_4_rom_bench.py (unchanged);
#              scripts/e8_4e_split.py (new) with e8_6a3_rom_energy.py and
#              e8_6a2_rom_energy.py (unchanged); reports/e8_rom/e8_4b_rel5/
#              model.json, reports/e8_rom/e8_6a3_rel5/d_rom.json,
#              reports/e8_rom/e8_5/; E8.4a-7's macros
# Writes     : reports/e8_rom/e8_4e_split.json, reports/e8_4e_split.log,
#              reports/e8_rom/e8_4b_c_<condition>/ (one folder per condition)
#              and reports/e8_4e_rom_<condition>.log; nothing else
# Run        : cd /mnt/d/Project/hybrid_memory/paper2
#              bash scripts/e8_4e_rom_corners.sh 2>&1 | tee reports/e8_4e_rom_corners.log
# Status     : E8_OUT_NAME=e8_4b_c_<condition> bash scripts/e8_4b_rom_energy.sh status
#              (the condition folders are listed in the log)
# Interrupted: run this script again; conditions whose folder already holds
#              a finished run (model.json written after the last simulation)
#              are skipped
# Runtime    : about 2.5-3.5 h per condition (12 runs: part A of 4 macros
#              and 2 trains, for 2 tables; 7 at a time), about 13-17 h in
#              all; about 1.5 GB of disk per condition (estimates)
# =============================================================================
set -uo pipefail

PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
SCRIPT="$PAPER2/scripts/e8_4b_rom_energy.sh"
REF="reports/e8_rom/e8_4b_rel5/model.json"
TABLES_C="e8rom_A_pcm_l00_16x2496 e8rom_A_sram_l00_16x2496"
CONDS="tt:-40:1.80:ttm40 tt:85:1.80:tt85 ff:25:1.80:ff25 ss:25:1.80:ss25 ff:85:1.80:ff85"
stamp() { date "+%Y-%m-%d %H:%M:%S"; }

echo "=============================================================="
echo "P2R-E8.4e ROM energy at five operating conditions, started $(stamp)"
echo "=============================================================="
cd "$PAPER2" || { echo "ERROR: no folder $PAPER2" >&2; exit 1; }
[ -f "$SCRIPT" ] || { echo "ERROR: missing $SCRIPT" >&2; exit 1; }
grep -q 'E8_PARK_FROM' "$SCRIPT" && grep -q 'park_ref' "$SCRIPT" \
  || { echo "ERROR: $SCRIPT is an older version; copy the one of 2026-10-19 (version 3)" >&2; exit 1; }
[ -f "$REF" ] || { echo "ERROR: missing $PAPER2/$REF (E8.4b-rel5)" >&2; exit 1; }
[ -f scripts/e8_4e_split.py ] || { echo "ERROR: missing $PAPER2/scripts/e8_4e_split.py" >&2; exit 1; }
echo "script   : $(md5sum "$SCRIPT" | cut -c1-32)  $SCRIPT"
echo "tools    : $(md5sum scripts/e8_4b_energy_tools.py | cut -c1-32)  scripts/e8_4b_energy_tools.py"
echo "bench    : $(md5sum scripts/e8_4_rom_bench.py | cut -c1-32)  scripts/e8_4_rom_bench.py"
echo "parking  : $(md5sum "$REF" | cut -c1-32)  $REF"
echo "tables   : $TABLES_C"
echo "trains   : conv2 (macro 0), fc1 (macro 1); part A of all 4 macros; no drift runs"
echo "solver   : reltol 1e-5, maximum time step 2 ns"
echo

echo "---- split of rel5's D_ROM ($(stamp)) ----"
python3 scripts/e8_4e_split.py --paper2 "$PAPER2" > reports/e8_4e_split.log 2>&1
rc=$?
grep -E "^  (PASS|FAIL)|ALL CHECKS PASS|CHECK\(S\) FAILED|^written" reports/e8_4e_split.log | sed 's/^/   /'
[ $rc -eq 0 ] || echo "   WARNING: the split failed (exit $rc, see reports/e8_4e_split.log); the runs go on, the split can be redone later"
echo

done_ok() {   # done_ok FOLDER: a finished run (model.json newer than every simulation's exit code)
  local W=$1 f
  [ -f "$W/model.json" ] || return 1
  for f in $(ls "$W"/*/*/exit_code 2>/dev/null); do [ "$f" -nt "$W/model.json" ] && return 1; done
  [ -n "$(ls "$W"/*/*/exit_code 2>/dev/null)" ]
}

for c in $CONDS; do
  IFS=: read -r corner temp vdd tag <<< "$c"
  name="e8_4b_c_$tag"
  W="reports/e8_rom/$name"
  echo "---- $corner, $temp C, $vdd V -> $W ($(stamp)) ----"
  if done_ok "$W"; then
    echo "   already finished (model.json present): skipped"
    continue
  fi
  E8_CORNER="$corner" E8_TEMP="$temp" E8_VDD="$vdd" E8_TABLES="$TABLES_C" E8_DRIFT=none E8_RELTOL=1e-5 \
  E8_PARK_FROM="$REF" E8_TRAINS="conv2 fc1" E8_OUT_NAME="$name" \
    bash "$SCRIPT" > "reports/e8_4e_rom_$tag.log" 2>&1
  rc=$?
  echo "   exit $rc at $(stamp); log reports/e8_4e_rom_$tag.log ($(wc -l < "reports/e8_4e_rom_$tag.log") lines)"
  grep -E "^ERROR" "reports/e8_4e_rom_$tag.log" | head -3 | sed 's/^/   /'
  grep -E "lookups of the trains|parking reads \(50 ns|part-A and drift reads" "reports/e8_4e_rom_$tag.log" | tail -3 | sed 's/^/   /'
  [ -f "$W/model.json" ] && echo "   model.json: $(md5sum "$W/model.json" | cut -c1-32)"
done

echo
echo "=============================================================="
echo "Finished $(stamp). Pack for Claude:"
echo "  tar czf reports/e8_4e_rom_compare.tar.gz reports/e8_rom/e8_4e_split.json reports/e8_4e_split.log reports/e8_rom/e8_4b_c_*/model.json reports/e8_rom/e8_4b_c_*/condition.txt reports/e8_rom/e8_4b_c_*/vm/vm.txt"
echo "=============================================================="
