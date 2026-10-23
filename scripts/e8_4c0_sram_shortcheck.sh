#!/usr/bin/env bash
# =============================================================================
# e8_4c0_sram_shortcheck.sh
#
# Experiment : P2R-E8.4c-0. Do the submitted OpenRAM SRAM macros have the short found in the sandbox
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
# Reads      : the submitted layouts (not changed). Writes: /home/kid/p2r_e8/e8_4c0 (magic's .ext files) and
#              reports/e8_rom/e8_4c0/ (summary and logs).
# Run        : cd /mnt/d/Project/hybrid_memory/paper2
#              bash scripts/e8_4c0_sram_shortcheck.sh 2>&1 | tee reports/e8_4c0_sram_shortcheck.log
# Needs      : scripts/e8_4c_sram_tools.py (with the topshort command, 2026-10-16).
# =============================================================================
set -uo pipefail

PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
MACROS="${E8_MACROS:-$PAPER2/reports/12e_openram/macros}"
WORK="${E8_WORK:-/home/kid/p2r_e8/e8_4c0}"
OUT="$PAPER2/reports/e8_rom/e8_4c0"
STOOLS="$PAPER2/scripts/e8_4c_sram_tools.py"
MAGICRC="$PDK_ROOT_DIR/sky130A/libs.tech/magic/sky130A.magicrc"
pick_path() { ls -d $1 2>/dev/null | sort -V | tail -1; }
MAGIC="${E8_MAGIC:-$(pick_path "/nix/store/*magic-vlsi*/bin/magic")}"
stamp() { date '+%Y-%m-%d %H:%M:%S'; }

echo "=============================================================="
echo "P2R-E8.4c-0 top-level short check of the SRAM macros, started $(stamp)"
echo "=============================================================="
echo "macros : $MACROS"
echo "magic  : ${MAGIC:-<missing>}"
echo "rcfile : $MAGICRC"
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
  echo "   layout: $g ($(stat -L -c %s "$g") bytes, md5 $(md5sum "$g" | cut -c1-32))"
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
  cat > "$d/top.tcl" <<EOF
drc off
gds flatten true
gds ordering true
gds read $g
load $name
select top cell
extract no all
extract cell $name
quit -noprompt
EOF
  t0=$(date +%s)
  ( cd "$d" && PDK_ROOT="$PDK_ROOT_DIR" timeout 3600 "$MAGIC" -dnull -noconsole -rcfile "$MAGICRC" < top.tcl > magic_top.log 2>&1 )
  echo "   magic exit $?, $(( $(date +%s) - t0 )) s"
  if [ ! -s "$d/$name.ext" ]; then
    echo "   no $name.ext written; magic log:"; tail -5 "$d/magic_top.log" | sed 's/^/      /'
    VERDICT[$name]="NOT JUDGED (no extraction)"
    continue
  fi
  python3 "$STOOLS" topshort --ext "$d/$name.ext" --json "$d/topshort.json" | sed 's/^/   /'
  VERDICT[$name]=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['verdict'])" "$d/topshort.json" 2>/dev/null || echo "NOT JUDGED")
  cp -f "$d/topshort.json" "$OUT/${name}_topshort.json"
  cp -f "$d/magic_top.log" "$OUT/${name}_magic_top.log"
done

echo
echo "P2R-E8.4c-0 summary"
for k in "${!VERDICT[@]}"; do echo "   $k: ${VERDICT[$k]}"; done | sort
echo "finished $(stamp); send reports/e8_4c0_sram_shortcheck.log"
