#!/usr/bin/env bash
# =============================================================================
# e4e5_fulldump_all.sh
#
# Purpose : Record the whole inference for the three variants that the power
#           comparison needs, and analyse each one as soon as it is ready.
#           Runs unattended; every figure is printed raw.
#
# Why a full recording is now the right choice
#   Two timing-tool runs settled the question. A 40 MB waveform on the old
#   netlist peaked at 608 MB, and a 155 MB waveform on the new one peaked at
#   588 MB: the waveform grew almost fourfold and the memory did not rise, so
#   the reader streams and the memory is set by the netlist. Reading cost one
#   extra second for 115 extra megabytes. A fully recorded inference is about
#   3.9 GB, which extrapolates to the same memory and roughly a minute of
#   reading. Nothing about it is out of reach.
#
#   That removes the reason for sampling windows, and with it the need to
#   defend a weighting scheme. Section V-E can then describe the measurement
#   it actually reports, which is what the submitted version does not do: its
#   activity came from 1,000 cycles near the start of the first convolutional
#   layer, out of 617,573.
#
# Window : recording starts at 8,160 ns, the first cycle after the start pulse,
#          derived from two calibration runs that ended at 18,160 ns after
#          1,000 post-start cycles and at 48,160 ns after 4,000. The 816 cycles
#          of configuration and image loading before that are not part of the
#          inference the paper reports. The end is left beyond any reachable
#          time so the recording never stops early.
#
# Cost   : the ungated run took 1 h 43 min without recording, and recording
#          adds about 37 ms per cycle, so expect eight to nine hours for it.
#          Variant b ran 36 percent faster unrecorded and should be quicker.
#          About 4 GB per waveform, twice that with the cleaned copy.
#
# Place  : D:\Project\hybrid_memory\paper2\scripts\   (WSL: /mnt/d/Project/hybrid_memory/paper2/scripts/)
# Status : NEW FILE. Calls e4_run.sh and e5_power.sh, neither of which changes.
# =============================================================================
set -uo pipefail

PAPER2=/mnt/d/Project/hybrid_memory/paper2
WORKROOT=/home/kid/p2r_e4
DUMP_FROM=8160
DUMP_TO=1000000000

cd "$PAPER2" || exit 1

echo "=============================================================="
echo "P2R-E4 and E5, full-inference recording, started $(date '+%F %T')"
echo "  window    : $DUMP_FROM ns to $DUMP_TO ns"
echo "  free space: $(df -h "$WORKROOT" 2>/dev/null | tail -1)"
echo "  a rough need is 25 GB for three waveforms and their cleaned copies"
echo "=============================================================="

for V in ungated u2 b; do
    echo
    echo "##############################################################"
    echo "# VARIANT $V, recording   $(date '+%F %T')"
    echo "##############################################################"
    bash scripts/e4_run.sh "$V" "$DUMP_FROM" "$DUMP_TO"
    RC=$?
    if [ "$RC" -ne 0 ]; then
        echo "VARIANT $V FAILED during simulation, moving to the next one." >&2
        continue
    fi

    CLEAN="$WORKROOT/$V/gate_${V}_${DUMP_FROM}_${DUMP_TO}_clean.vcd"
    if [ ! -f "$CLEAN" ]; then
        echo "VARIANT $V: no cleaned waveform at $CLEAN, skipping the analysis." >&2
        continue
    fi

    echo
    echo "##############################################################"
    echo "# VARIANT $V, analysis   $(date '+%F %T')"
    echo "##############################################################"
    bash scripts/e5_power.sh "$V" "$CLEAN"
done

echo
echo "=============================================================="
echo "Finished $(date '+%F %T')"
echo
echo "What to read off each analysis, and what it has to satisfy:"
echo "  G1  the run reports 617,575 cycles and class 7, as both"
echo "      verification runs already did"
echo "  G5  the cleaner reports one removed dump-on marker, one removed"
echo "      closing marker, and no truncation. Recording runs past the end"
echo "      of the simulation, so nothing should be cut"
echo "  G11 the sequential internal power must fall for variant b. The"
echo "      simulator itself ran 36 percent faster on that netlist, so if"
echo "      the power does not move, the reduced clock toggling is not"
echo "      reaching the tool and the figure is not usable"
echo "  O21 the annotated pin count, recorded for every variant"
echo
echo "Reference points already measured:"
echo "  submitted version, old netlist, 1,000-cycle window : 59.329 mW"
echo "  new ungated, 20,000-cycle window                   : 59.606 mW"
echo "  the two agree to 0.5 percent across different netlists and windows"
