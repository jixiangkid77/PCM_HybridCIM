#!/usr/bin/env bash
# =============================================================================
# e8_4c0b_sram_shortcheck.sh
#
# Experiment : P2R-E8.4c-0b (E8.4c-0 again, 2026-10-16). Do the submitted OpenRAM SRAM macros have the short found in the sandbox
#              between the top-level control route of p_en_bar (precharge enable) and the column-select
#              line sel_7 of the column multiplexer? (claude/p2r-e8-4c-sandbox.md)
# Why        : OpenRAM e16d9eb (the version used for the manuscript's macros) routes each control-logic
#              output to the bank on a horizontal metal-3 wire at the height of the control-logic pin. With
#              16 words per row this wire of p_en_bar lies on the metal-3 wire of sel_7 inside the bank. In
#              the sandbox the 256-byte and 1 KB macros of the manuscript's configuration have it; netgen
#              finds one net fewer, and the 256-byte macro reads wrong in simulation.
# How        : magic reads each SRAM layout (GDS) under reports/12e_openram/macros/ and extracts the top cell
#              only (its wires and their connections to the cells inside; no capacitance, a few minutes);
#              scripts/e8_4c_sram_tools.py topshort lists the nets that join a column-select line with a
#              control signal or with another column-select line.
# Verdict    : per macro SHORT / NO SHORT OF THIS KIND / NOT JUDGED (the control routes were not found, so the
#              extraction did not see the top-level wires). The full check is the LVS of E8.4c.
# Why again  : E8.4c-0 let magic read each layout from /mnt/d. With 'gds flatten' magic looks ahead in the file
#              for every cell used before it is defined, one small read and one seek per GDS record, and over
#              /mnt/d every such call goes to Windows: on KID's machine the 5 KB layout was not read in one hour.
#              Here each layout is first copied to the Linux work folder (md5 checked) and magic reads the copy.
#              A macro whose magic run is cut by the time limit gives only SHORT (each merge in a partial .ext is a
#              real connection); otherwise NOT JUDGED (rule of claude/p2r-e8-4c-sandbox.md 0-8, set before results).
# Reads      : the submitted layouts (not changed). Writes: /home/kid/p2r_e8/e8_4c0b (copies of the layouts,
#              magic's .ext files) and reports/e8_rom/e8_4c0b/ (summary and logs). Runs beside E8.4c-0 and E8.4c.
# Run        : cd /mnt/d/Project/hybrid_memory/paper2
#              bash scripts/e8_4c0b_sram_shortcheck.sh 2>&1 | tee reports/e8_4c0b_sram_shortcheck.log
# Options    : E8_TIMEOUT (magic time limit per macro, s; 7200)
# Needs      : scripts/e8_4c_sram_tools.py (with the topshort command, 2026-10-16).
# =============================================================================
set -uo pipefail

PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
MACROS="${E8_MACROS:-$PAPER2/reports/12e_openram/macros}"
WORK="${E8_WORK:-/home/kid/p2r_e8/e8_4c0b}"
OUT="$PAPER2/reports/e8_rom/e8_4c0b"
TLIM="${E8_TIMEOUT:-7200}"
case "$TLIM" in *[!0-9]*|"") echo "ERROR: E8_TIMEOUT must be an integer (s)" >&2; exit 1 ;; esac
STOOLS="$PAPER2/scripts/e8_4c_sram_tools.py"
MAGICRC="$PDK_ROOT_DIR/sky130A/libs.tech/magic/sky130A.magicrc"
pick_path() { ls -d $1 2>/dev/null | sort -V | tail -1; }
MAGIC="${E8_MAGIC:-$(pick_path "/nix/store/*magic-vlsi*/bin/magic")}"
stamp() { date '+%Y-%m-%d %H:%M:%S'; }

echo "=============================================================="
echo "P2R-E8.4c-0b top-level short check of the SRAM macros (layouts copied to the Linux work folder), started $(stamp)"
echo "=============================================================="
echo "macros : $MACROS"
echo "magic  : ${MAGIC:-<missing>}"
echo "rcfile : $MAGICRC"
echo "work   : $WORK   (magic time limit per macro: $TLIM s)"
for F in "$STOOLS" "$MAGICRC"; do [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }; done
[ -n "$MAGIC" ] || { echo "ERROR: magic not found" >&2; exit 1; }
grep -q "def cmd_topshort" "$STOOLS" || { echo "ERROR: $STOOLS is an older version (no topshort)" >&2; exit 1; }
echo "   $(md5sum "$STOOLS" | cut -c1-32)  $STOOLS"
echo "   $(md5sum "$0" 2>/dev/null | cut -c1-32)  $0"

mapfile -t GDS < <(find "$MACROS" \( -type f -o -type l \) -name "*.gds" 2>/dev/null | grep -i "sram" | sort)
[ "${#GDS[@]}" -gt 0 ] || { echo "ERROR: no SRAM layout (*sram*.gds) under $MACROS" >&2; exit 1; }
mkdir -p "$WORK" "$OUT" || exit 1

declare -A VERDICT
for g in "${GDS[@]}"; do
  name=$(basename "$g" .gds)
  case "$name" in *[!A-Za-z0-9_]*) echo "   skipped (unexpected name): $g"; continue ;; esac
  d="$WORK/$name"
  rm -rf "${d:?}"; mkdir -p "$d"
  echo
  echo "---- $name ----"
  gmd5=$(md5sum "$g" | cut -c1-32)
  echo "   layout: $g ($(stat -L -c %s "$g") bytes, md5 $gmd5)"
  lef="${g%.gds}.lef"
  [ -f "$lef" ] && echo "   LEF size: $(grep -m1 -E '^\s*SIZE' "$lef" | awk '{print $2" x "$4}') um"
  # OpenRAM's own log of this macro, when it is next to the layout: the configuration and the time of each
  # generation step (to estimate the time of a new generation)
  glog="${g%.gds}.log"
  if [ -f "$glog" ]; then
    echo "   OpenRAM log $(basename "$glog"):"
    grep -E "^\*\* |Words per row|^Word size|^Total size|Netlist only|Characterization is disabled" "$glog" | head -24 | sed 's/^/      /'
    t1=$(grep -m1 -oE "^\[[0-9-]+ [0-9:.]+\]" "$glog"); t2=$(grep -oE "^\[[0-9-]+ [0-9:.]+\]" "$glog" | tail -1)
    [ -n "$t1" ] && echo "      first and last time stamps of the log: $t1 $t2"
  fi
  for e in sp lvs.sp py; do [ -f "${g%.gds}.$e" ] && echo "   also present: $(basename "${g%.gds}.$e")"; done
  t0=$(date +%s)
  cp "$g" "$d/$name.gds" || { echo "   could not copy the layout"; VERDICT[$name]="NOT JUDGED (layout not copied)"; continue; }
  cmd5=$(md5sum "$d/$name.gds" | cut -c1-32)
  echo "   copied to $d/$name.gds in $(( $(date +%s) - t0 )) s, md5 $cmd5 ($( [ "$cmd5" = "$gmd5" ] && echo "the same" || echo "DIFFERENT"))"
  [ "$cmd5" = "$gmd5" ] || { VERDICT[$name]="NOT JUDGED (copy differs)"; continue; }
  cat > "$d/top.tcl" <<EOF
drc off
gds flatten true
gds ordering true
gds read $d/$name.gds
load $name
select top cell
extract no all
extract cell $name
quit -noprompt
EOF
  t0=$(date +%s)
  ( cd "$d" && PDK_ROOT="$PDK_ROOT_DIR" timeout "$TLIM" "$MAGIC" -dnull -noconsole -rcfile "$MAGICRC" < top.tcl > magic_top.log 2>&1 )
  mx=$?
  echo "   magic exit $mx, $(( $(date +%s) - t0 )) s$( [ "$mx" = "124" ] && echo " (cut by the time limit)")"
  if [ ! -s "$d/$name.ext" ]; then
    echo "   no $name.ext written; magic log:"; tail -5 "$d/magic_top.log" | sed 's/^/      /'
    VERDICT[$name]="NOT JUDGED (no extraction)"
    continue
  fi
  python3 "$STOOLS" topshort --ext "$d/$name.ext" --json "$d/topshort.json" | sed 's/^/   /'
  VERDICT[$name]=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['verdict'])" "$d/topshort.json" 2>/dev/null || echo "NOT JUDGED")
  if [ "$mx" != "0" ] && [ "${VERDICT[$name]}" != "SHORT" ]; then
    echo "   magic did not finish (exit $mx): the .ext is incomplete, so only SHORT would count"
    VERDICT[$name]="NOT JUDGED (magic exit $mx)"
  fi
  cp -f "$d/topshort.json" "$OUT/${name}_topshort.json"
  cp -f "$d/magic_top.log" "$OUT/${name}_magic_top.log"
done

echo
echo "P2R-E8.4c-0b summary"
for k in "${!VERDICT[@]}"; do echo "   $k: ${VERDICT[$k]}"; done | sort
echo "finished $(stamp); send reports/e8_4c0b_sram_shortcheck.log"
