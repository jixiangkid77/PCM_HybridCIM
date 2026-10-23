#!/usr/bin/env bash
# =============================================================================
# watch_e4.sh <variant>
#
# Purpose : Follow a recording run that prints nothing while it works, and say
#           when it is done. The testbench reports only at the end, and its
#           output sits in a block buffer until the simulator exits, so the log
#           file stays empty for the whole run. The waveform file, on the other
#           hand, grows continuously, and that is what this watches.
#
# Reads only. Polls once a minute, prints one line, and when the simulator
# exits it prints the lines the functional gate is judged on.
#
# The percentage is an estimate. It divides the waveform by the bytes per cycle
# measured on the completed ungated run, 15,821, and the three completed runs
# ranged from 15,821 to 18,408, so read it as plus or minus about fifteen
# percent. The completion message is not an estimate.
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\   (WSL: /mnt/d/Project/hybrid_memory/paper2/scripts/)
# Status  : NEW FILE.
# =============================================================================
set -uo pipefail

VARIANT="${1:-}"
case "$VARIANT" in
    ungated|gated|u2|b) ;;
    *) echo "usage: bash scripts/watch_e4.sh <ungated|gated|u2|b>" >&2; exit 1 ;;
esac

RUNDIR="/home/kid/p2r_e4/$VARIANT"
VCD="$RUNDIR/gate.vcd"
BYTES_PER_CYCLE=15821
HEADER=32900000
TOTAL_CYCLES=617575

echo "watching variant $VARIANT in $RUNDIR"
echo "the run is finished when this says so; Ctrl-C only stops the watching"
echo

PREV=0
while true; do
    PID=$(pgrep -f "vvp sim_${VARIANT}.vvp" | head -1)
    NOW=$(stat -c %s "$VCD" 2>/dev/null || echo 0)

    if [ -z "$PID" ]; then
        if [ "$NOW" -gt 0 ] || [ -f "$RUNDIR/gate_${VARIANT}_8160_1000000000.vcd" ]; then
            echo
            echo "=============================================================="
            echo "simulator has exited at $(date '+%F %T')"
            echo "=============================================================="
            echo "---- waveform files ----"
            ls -la "$RUNDIR"/gate_*.vcd 2>/dev/null
            echo
            echo "---- the lines gate G1 is judged on ----"
            grep -n "DONE at post-start cycle\|PASS\|FAIL\|STOP" \
                 "$RUNDIR/sim_${VARIANT}_8160_1000000000.log" 2>/dev/null \
                 || echo "(log not written yet; the cleaning step may still be running)"
            echo
            echo "---- wall time and memory ----"
            grep -E "Elapsed \(wall|Maximum resident" \
                 "$RUNDIR/sim_${VARIANT}_8160_1000000000_resource.txt" 2>/dev/null
            echo
            echo "Next, the power analysis:"
            echo "  bash scripts/e5_power.sh $VARIANT $RUNDIR/gate_${VARIANT}_8160_1000000000_clean.vcd"
            exit 0
        fi
        echo "$(date '+%H:%M:%S')  no simulator running and no waveform; check the job with jobs"
        exit 1
    fi

    if [ "$NOW" -le "$HEADER" ]; then
        echo "$(date '+%H:%M:%S')  loading the simulation image, no waveform data yet   (RSS $(ps -o rss= -p "$PID" | tr -d ' ') kB)"
    else
        CYC=$(( (NOW - HEADER) / BYTES_PER_CYCLE ))
        PCT=$(( CYC * 100 / TOTAL_CYCLES ))
        RATE=$(( (NOW - PREV) / 60 ))
        if [ "$PREV" -gt 0 ] && [ "$RATE" -gt 0 ]; then
            REMAIN=$(( (TOTAL_CYCLES - CYC) * BYTES_PER_CYCLE / RATE / 60 ))
            printf '%s  %6.2f GB  about cycle %7d of %d  %3d%%  roughly %d min left\n' \
                   "$(date '+%H:%M:%S')" "$(echo "$NOW" | awk '{printf "%.2f", $1/1e9}')" \
                   "$CYC" "$TOTAL_CYCLES" "$PCT" "$REMAIN"
        else
            printf '%s  %6.2f GB  about cycle %7d of %d  %3d%%\n' \
                   "$(date '+%H:%M:%S')" "$(echo "$NOW" | awk '{printf "%.2f", $1/1e9}')" \
                   "$CYC" "$TOTAL_CYCLES" "$PCT"
        fi
    fi
    PREV=$NOW
    sleep 60
done
