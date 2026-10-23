#!/usr/bin/env bash
# =============================================================================
# e8_1b_macro_footprints.sh [macro_dir ...]
#
# Experiment : P2R-E8.1b. Compare the footprint each macro declares in its LEF
#              with the extent of the layout actually drawn in its GDS.
#
# Why
#   E8.1 (e8_1_tools_smoke.log, 2026-10-07 22:41) read the submitted address-
#   map ROM into magic. Its layout spans 362.690 x 244.085 um, from (-7.480,
#   -7.480) to (355.210, 236.605), while its LEF declares 347.73 x 229.125 um
#   from (0, 0). The drawn layout reaches 7.48 um beyond the declared
#   footprint on every side.
#
#   The memory compiler's source explains it. In compiler/modules/rom_bank.py
#   (OpenRAM e16d9eb) the ROM sets its boundary, and with it the width and
#   height written to the LEF, before route_layout() adds the supply ring
#   (route_supplies = "ring") and routes the pins out past it. The SRAM code
#   (sram_1bank.py) does the opposite: it routes the ring first and sets the
#   boundary afterwards, so its LEF should enclose the ring.
#
#   The area model of the manuscript takes every macro footprint from its LEF.
#   This script measures every macro, ROM and SRAM, so that the area figures
#   can be put on the layout extent where the two differ.
#
# For each macro directory (default: the submitted macros in
# reports/12e_openram/macros and, if present, the regenerated ones in
# reports/e8_rom/macros) it reads the LEF SIZE and asks magic for the bounding
# box of the GDS top cell.
#
# Read-only for the project: magic's command files and logs are written to
# /home/kid/p2r_e8/footprints/ (Linux file system), nothing in the project
# is modified.
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\
#           (WSL: /mnt/d/Project/hybrid_memory/paper2/scripts/)
# Status  : NEW FILE.
# Run     : cd /mnt/d/Project/hybrid_memory/paper2
#           bash scripts/e8_1b_macro_footprints.sh 2>&1 | tee reports/e8_1b_macro_footprints.log
# Runtime : about a minute; the largest SRAM layout is 32 MB.
# =============================================================================
set -uo pipefail

PAPER2=/mnt/d/Project/hybrid_memory/paper2
PDK_ROOT_DIR=/home/kid/gf/pdk
MAGICRC="$PDK_ROOT_DIR/sky130A/libs.tech/magic/sky130A.magicrc"
MAGIC=$(ls -d /nix/store/*magic-vlsi*/bin/magic 2>/dev/null | sort -V | tail -1)
WORK=/home/kid/p2r_e8/footprints

if [ "$#" -gt 0 ]; then
  DIRS=("$@")
else
  DIRS=("$PAPER2/reports/12e_openram/macros")
  [ -d "$PAPER2/reports/e8_rom/macros" ] && DIRS+=("$PAPER2/reports/e8_rom/macros")
fi

echo "=============================================================="
echo "P2R-E8.1b macro footprints, started $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
echo "magic   : ${MAGIC:-<missing>}"
echo "magicrc : $MAGICRC"
[ -n "$MAGIC" ] && [ -f "$MAGICRC" ] || { echo "ERROR: magic or its sky130A rc file is missing" >&2; exit 1; }
mkdir -p "$WORK" || exit 1

printf "\n%-40s %-20s %-20s %-40s %10s %10s %7s\n" "macro" "LEF W x H (um)" "layout W x H (um)" \
       "layout extent (llx,lly)-(urx,ury)" "LEF um2" "layout um2" "ratio"
for D in "${DIRS[@]}"; do
  echo "-- $D"
  for sub in "$D"/*/; do
    gds=$(ls "$sub"*.gds 2>/dev/null | head -1)
    [ -n "$gds" ] || continue
    top=$(basename "$gds" .gds)
    lef="$sub$top.lef"
    [ -f "$lef" ] || lef=$(ls "$sub"*.lef 2>/dev/null | head -1)
    read -r LW LH < <(grep -m1 -E "^\s*SIZE" "$lef" 2>/dev/null | awk '{print $2, $4}')
    tcl="$WORK/$top.tcl"; log="$WORK/$top.log"
    printf 'gds read %s\nload %s\nselect top cell\nbox\nquit -noprompt\n' "$gds" "$top" > "$tcl"
    PDK_ROOT="$PDK_ROOT_DIR" timeout 900 "$MAGIC" -dnull -noconsole -rcfile "$MAGICRC" \
        < "$tcl" > "$log" 2>&1
    line=$(grep -m1 "^microns:" "$log")
    if [ -z "$line" ]; then
      printf "%-40s %-20s %s\n" "$top" "${LW:-?} x ${LH:-?}" "NO BOX FROM MAGIC, see $log"
      continue
    fi
    GW=$(echo "$line" | awk '{print $2}')
    GH=$(echo "$line" | awk '{print $4}')
    EXT=$(echo "$line" | sed -E 's/.*\(\s*([-0-9.]+),\s*([-0-9.]+)\),\s*\(\s*([-0-9.]+),\s*([-0-9.]+)\).*/(\1,\2)-(\3,\4)/')
    awk -v n="$top" -v lw="${LW:-0}" -v lh="${LH:-0}" -v gw="$GW" -v gh="$GH" -v ext="$EXT" 'BEGIN{
          la = lw*lh; ga = gw*gh;
          printf "%-40s %-20s %-20s %-40s %10.1f %10.1f %7.4f\n", n, lw " x " lh, gw " x " gh, ext, la, ga, (la>0? ga/la : 0) }'
  done
done

echo
echo "ratio = layout area / LEF area. A ratio of 1.0000 means the LEF encloses the"
echo "whole drawn layout; above 1 means the layout extends past the declared footprint."
echo "magic logs: $WORK"
echo
echo "=============================================================="
echo "Finished $(date '+%Y-%m-%d %H:%M:%S'). Nothing in the project was changed."
echo "=============================================================="
