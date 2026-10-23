#!/usr/bin/env bash
# =============================================================================
# e7_neurosim_130nm_v2.sh
#
# Purpose : Run the crossbar model at 130 nm so Reviewer 2 Comment 2 can be
#           answered with a measurement, and leave the tool exactly as found.
#
# Why the first version of this script was wrong
#   It assumed the configuration file still held the settings this paper used.
#   It does not. On 7 August the file was changed for the other paper in this
#   series, in seven places, and rebuilt. Running the old script would have
#   saved that changed file under a name claiming it was this paper's, then
#   restored from it, and this paper's settings would have been lost.
#
# What the file comparison established
#   The backup taken before that change is byte-identical to the archived
#   configuration of the cellBit 1 run, and the archived configurations of the
#   other runs differ from it in one line only, the cell precision. So every
#   run in this series used one configuration with one parameter varied, and
#   taking area from one run and energy from another, as the paper does, is
#   sound. Only the configuration file was modified after June; no other source
#   was touched.
#
# State handling
#   The other paper's settings are saved before anything is changed and put
#   back at the end, with a comparison to prove the restore. This paper's
#   baseline is taken from the archived configuration rather than reconstructed.
#
# The gate
#   Before the node is changed, the 22 nm run must reproduce what the 5 June run
#   reported: a chip area of 2.52208 mm² and a total read dynamic energy of
#   131429 pJ. If it does not, the configuration is not the one the paper used
#   and no 130 nm number taken afterwards would mean anything. The script stops
#   there and still restores the other paper's state.
#
# The change
#   Only the node and the wire width move. Sub-array size, converter levels,
#   sense amplifier type and cell precision stay at this paper's values, so the
#   comparison has one variable.
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\   (WSL: /mnt/d/Project/hybrid_memory/paper2/scripts/)
# Status  : NEW FILE, replaces e7_neurosim_130nm.sh, which must not be run.
# Runtime : two runs of about twenty minutes each, plus three short rebuilds.
# =============================================================================
set -uo pipefail

NS=/home/kid/NeuroSim/Inference_pytorch
PDIR=$NS/NeuroSIM
P=$PDIR/Param.cpp
ARCH=/mnt/d/Project/hybrid_memory/paper2/reports/12e_neurosim/configs/Param_neurosim_cellBit_2.cpp
P3=$PDIR/Param.cpp.paper3backup
OUT=/home/kid/p2r_e7
TRACE=$NS/layer_record_LeNet5/trace_command.sh
mkdir -p "$OUT"

show () { grep -nE "^[[:space:]]*(SARADC|technode|wireWidth|numRowSubArray|numColSubArray|levelOutput|cellBit|numColMuxed|memcelltype) = " "$P"; }
restore3 () {
    echo; echo "---- putting the other paper's configuration back ----"
    cp "$P3" "$P" && cd "$PDIR" && make -j4 > "$OUT/make_restore.log" 2>&1
    echo "rebuild exit status: $?"
    echo "difference against the saved copy, which should be empty:"
    diff "$P3" "$P" && echo "  identical"
    show
}

echo "=============================================================="
echo "P2R-E7 v2, started $(date '+%F %T')"
echo "=============================================================="

for F in "$P" "$ARCH" "$TRACE" "$PDIR/makefile"; do
    [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done

echo
echo "---- 1. the configuration as found, which belongs to the other paper ----"
show

echo
echo "---- 2. saving it ----"
if [ -f "$P3" ]; then
    echo "a saved copy already exists; comparing it with what is on disk now"
    diff "$P3" "$P" || { echo "ERROR: the saved copy and the current file differ. Resolve this by hand." >&2; exit 1; }
    echo "  identical, keeping the existing copy"
else
    cp "$P" "$P3" && echo "saved to $P3"
fi

echo
echo "---- 3. installing this paper's baseline from the archived configuration ----"
cp "$ARCH" "$P"
show
echo "expected: SARADC false, technode 22, wireWidth 40, 64 by 64, levelOutput 32, cellBit 2"

echo
echo "---- 4. rebuild ----"
cd "$PDIR" || { restore3; exit 1; }
make -j4 > "$OUT/make_22nm.log" 2>&1
echo "make exit status: $?"
tail -5 "$OUT/make_22nm.log"
ls -la "$PDIR/main"

echo
echo "---- 5. run at 22 nm, started $(date '+%F %T') ----"
cd "$NS" || { restore3; exit 1; }
bash "$TRACE" > "$OUT/result_22nm_repro.log" 2>&1
echo "exit status: $?   finished $(date '+%F %T')"
echo "---- RAW ----"
grep -iE "Total Chip Area|Chip total|Energy Efficiency|Throughput|Compute efficiency|readLatency \(per image\)|clock period" "$OUT/result_22nm_repro.log"

echo
echo "=============================================================="
echo "GATE: does this reproduce the 5 June run"
A=$(grep -c "Total Chip Area: 2.52208 mm\^2" "$OUT/result_22nm_repro.log")
E=$(grep -c "Chip total readDynamicEnergy is: 131429pJ" "$OUT/result_22nm_repro.log")
echo "  area line matching 2.52208 mm^2      : $A"
echo "  energy line matching 131429 pJ       : $E"
if [ "$A" -lt 1 ] || [ "$E" -lt 1 ]; then
    echo "  RESULT: FAIL. The configuration is not the one behind the published"
    echo "  figures, so nothing measured after a node change would be comparable."
    restore3
    exit 1
fi
echo "  RESULT: PASS"
echo "=============================================================="

echo
echo "---- 6. moving the node, and nothing else ----"
sed -i -e 's/^\([[:space:]]*\)technode = 22;/\1technode = 130;/' \
       -e 's/^\([[:space:]]*\)wireWidth = 40;/\1wireWidth = 175;/' "$P"
show
echo "expected: only the node and the wire width have moved"

echo
echo "---- 7. rebuild ----"
cd "$PDIR" && make -j4 > "$OUT/make_130nm.log" 2>&1
echo "make exit status: $?"
ls -la "$PDIR/main"

echo
echo "---- 8. run at 130 nm, started $(date '+%F %T') ----"
cd "$NS" || { restore3; exit 1; }
bash "$TRACE" > "$OUT/result_130nm.log" 2>&1
echo "exit status: $?   finished $(date '+%F %T')"
echo "---- RAW ----"
grep -iE "Total Chip Area|Chip total|Energy Efficiency|Throughput|Compute efficiency|readLatency \(per image\)|clock period" "$OUT/result_130nm.log"

echo
echo "---- 9. the area and energy split, both nodes ----"
for L in "$OUT/result_22nm_repro.log" "$OUT/result_130nm.log"; do
    echo "== $(basename "$L")"
    grep -iE "ADC|Accumulation|Other Peripheries|CIM array|Chip area" "$L" | head -14
done

restore3

echo
echo "=============================================================="
echo "Reference, 5 June, 22 nm, cellBit 2:"
echo "  Total Chip Area 2.52208 mm2, CIM array 60901.3 um2"
echo "  Chip total readDynamicEnergy 131429 pJ"
echo "  readLatency per image 52522.3 ns, Energy Efficiency 5.14439 TOPS/W"
echo "The paper reports the array and its converters after the scheme"
echo "conversion, 2.1542 mm2 for the two-bit differential scheme."
echo "Finished $(date '+%F %T')"
