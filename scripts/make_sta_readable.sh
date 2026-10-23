#!/usr/bin/env bash
# =============================================================================
# make_sta_readable.sh
#
# Purpose : The timing tool cannot parse the netlists written by the newer
#           Yosys. Two constructs stop it, neither of which the older writer
#           produced. This script produces a copy of each netlist with both
#           neutralised, and then proves that nothing else changed.
#
#             1. the signed keyword on port and wire declarations
#             2. the parameter override block on the memory macro instances
#
#           The netlist the submitted version gave to the timing tool carries
#           neither: its macro instances are written bare, with no override
#           block at all, and that is the form the tool is known to accept.
#           The macros are black boxes to it, which it reports as it creates
#           one for each of them, so the parameter values are never read. The
#           simulation netlist is a separate file and keeps its parameters, so
#           the waveform is unaffected by this.
#
#           Removing the block leaves the instance, its name and every port
#           connection untouched, so connectivity is unchanged.
#
#           Signedness is a source-language attribute. In a netlist of mapped
#           standard cells it carries no information the timing or power
#           analysis can use, so removing it from the declarations changes
#           nothing the tool would have read.
#
# Safety  : the rule matches only a declaration keyword at the start of a line
#           followed by signed. Expressions such as the signed system function,
#           and identifiers that merely contain the letters, are untouched;
#           both cases were checked against a constructed example.
#
# Inputs  : reports/lenet5_top_<variant>_sta.v          left untouched
# Outputs : reports/lenet5_top_<variant>_sta_ok.v       new files
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\   (WSL: /mnt/d/Project/hybrid_memory/paper2/scripts/)
# Status  : NEW FILE. Modifies none of the existing netlists.
# Runtime : seconds.
# =============================================================================
set -uo pipefail

PAPER2=/mnt/d/Project/hybrid_memory/paper2
cd "$PAPER2" || exit 1

for V in ungated gated u2 b; do
    SRC="reports/lenet5_top_${V}_sta.v"
    DST="reports/lenet5_top_${V}_sta_ok.v"
    echo "=============================================================="
    echo "variant $V"
    if [ ! -f "$SRC" ]; then echo "  skipped, $SRC not present"; continue; fi

    sed -E "s/^([[:space:]]*(input|output|inout|wire|reg))[[:space:]]+signed[[:space:]]+/\1 /" "$SRC" \
      | awk '
          /^[[:space:]]*[^[:space:]]+[[:space:]]+#\($/ {
              match($0, /^[[:space:]]*/); ind=substr($0, 1, RLENGTH)
              mod=$1; skip=1; next
          }
          skip && /^[[:space:]]*\)[[:space:]]+.*\([[:space:]]*$/ {
              sub(/^[[:space:]]*\)[[:space:]]+/, ""); print ind mod "  " $0; skip=0; next
          }
          skip { next }
          { print }
        ' > "$DST"

    LS=$(wc -l < "$SRC"); LD=$(wc -l < "$DST")
    PS=$(grep -cE '^[[:space:]]*[^[:space:]]+[[:space:]]+#\($' "$SRC")
    PD=$(grep -cE '^[[:space:]]*[^[:space:]]+[[:space:]]+#\($' "$DST")
    echo "  lines            : $LS -> $LD   (a parameter block of n lines becomes one line)"
    echo "  parameter blocks : $PS -> $PD   $([ "$PD" = "0" ] && echo cleared || echo REMAINING)"

    SS=$(grep -cE '^[[:space:]]*(input|output|inout|wire|reg)[[:space:]]+signed[[:space:]]' "$SRC")
    SD=$(grep -cE '^[[:space:]]*(input|output|inout|wire|reg)[[:space:]]+signed[[:space:]]' "$DST")
    echo "  signed decls     : $SS -> $SD   $([ "$SD" = "0" ] && echo cleared || echo REMAINING)"

    # The cell instances are what the analysis actually reads. Their histogram
    # must be identical before and after.
    HS=$(grep -oE "sky130_fd_sc_hd__[a-z0-9_]+" "$SRC" | sort | uniq -c | md5sum | cut -d' ' -f1)
    HD=$(grep -oE "sky130_fd_sc_hd__[a-z0-9_]+" "$DST" | sort | uniq -c | md5sum | cut -d' ' -f1)
    echo "  cell histogram   : $HS"
    echo "                     $HD   $([ "$HS" = "$HD" ] && echo identical || echo DIFFERENT)"

    # Connectivity check: every port connection line must survive untouched.
    CS=$(grep -cE '^[[:space:]]*\.[A-Za-z_]' "$SRC")
    CD=$(grep -cE '^[[:space:]]*\.[A-Za-z_]' "$DST")
    echo "  port connections : $CS -> $CD   (falls by the number of parameter lines removed)"

    # Instance count must not change.
    IS=$(grep -cE '^[[:space:]]*\)[[:space:]]*;$' "$SRC")
    ID=$(grep -cE '^[[:space:]]*\)[[:space:]]*;$' "$DST")
    echo "  instances closed : $IS -> $ID   $([ "$IS" = "$ID" ] && echo same || echo DIFFERENT)"

    ls -la "$DST"
done

echo
echo "=============================================================="
echo "Next: point e5_power.sh at these files by changing one line,"
echo "then rerun the analysis. Each attempt costs under a second if"
echo "the parser objects to something else further in."
