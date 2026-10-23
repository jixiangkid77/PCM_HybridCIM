#!/usr/bin/env bash
# =============================================================================
# e8_4a_rom_smoke.sh   [run | status]
#
# Experiment : P2R-E8.4a. First transistor-level simulation of one
#              address-map ROM macro generated in E8.3, before the full
#              characterisation (E8.4b) is planned.
#
# Questions
#   1. Does the macro read back the stored words in SPICE (function)?
#   2. How long does a read take (access time), without and with the
#      parasitic capacitance of the layout?
#   3. Energy of a read cycle and of an idle cycle (clock running, CS low),
#      and the static power left after a read.
#   4. How long magic and ngspice take, so that E8.4b can be sized.
#
# Steps
#   a. probe the generator's netlist (ports, device counts)
#   b. pick two read sequences from the stored data (e8_4_rom_bench.py pick):
#      main     : reads chosen by the zero bits of their rows and words
#                 (function, access time, read and idle energy, static power)
#      recovery : the row with the most zeros, then 2, 5 and 15 periods of
#                 precharge, then a bottom-row read: how long the chains need
#                 to recharge before a bottom-row read is correct
#   c. start the two simulations of the generator's netlist (transistors
#      only, no wire capacitance), clock period E8_PERIOD (default 100 ns)
#   d. meanwhile, extract the layout with magic (transistors and parasitic
#      capacitance, including coupling capacitance), probe the extracted
#      netlist, and start its two simulations
#   e. wait for all four, printing progress every E8_HEARTBEAT seconds
#      (default 1800), then analyse each one
#
# Run to completion (version of 2026-10-08 23:40)
#   - No simulation is stopped by a time limit (E8_TIMEOUT, default 0 = no
#     limit; a positive value would stop each simulation after that many
#     seconds).
#   - The four simulations run at the same time, two threads each, so the
#     whole run takes about as long as the slowest one.
#   - Each simulation writes everything it has computed after every clock
#     period of simulated time. Whatever happens (a very slow run, Ctrl+C,
#     a crash), the data up to the last period is on disk, and
#       bash scripts/e8_4a_rom_smoke.sh status
#     analyses every simulation as far as it has got, while they keep
#     running.
#
# What the sandbox showed before this run (same generator and commit,
# synthetic data with half the bits zero, generator netlist without wire
# capacitance, ngspice-42, sky130 TT models of fossi-foundation commit
# 403964d; not paper data):
#   - reads from the fully precharged state are correct; access time
#     12-22 ns after the clock rises
#   - a read of a row with 125 zero bits draws about 100 pJ per 100 ns cycle;
#     a row with no zero bit about 11.5 pJ
#   - after a row with many zeros, a read of the bottom row fails if the
#     precharge before it is 50 or 200 ns, and is correct after 250 ns or
#     more: each bitline is a chain of 192 cells plus a footer, and the
#     chain recharges slowly from its top
#   - the column multiplexer is one NMOS per column; after a 0 bit is read,
#     its output stays near VDD - Vt and floats, so the output inverter
#     conducts a static current (about 200-280 uW per macro) until the next
#     read. The analysis reports it as P_after, the supply power just before
#     the next rising edge.
# This run measures the same quantities on a real macro, and with the
# capacitance of its layout.
#
# Macro   : e8rom_A_pcm_l00_16x2496 (PCM side: about half the stored bits are
#           zero, so most bitlines discharge). Override with E8_MACRO=...
# Models  : sky130 TT corner, 25 C, 1.8 V (the corner of the E5 power flow)
# Place   : D:\Project\hybrid_memory\paper2\scripts\  (with e8_4_rom_bench.py)
# Writes  : only the folder reports\e8_rom\e8_4a\<macro>\ (sch_main,
#           sch_recovery, extract, ext_main, ext_recovery). Nothing else is
#           touched, nothing is installed. A rerun overwrites that folder.
# Run     : cd /mnt/d/Project/hybrid_memory/paper2
#           bash scripts/e8_4a_rom_smoke.sh 2>&1 | tee reports/e8_4a_rom_smoke.log
#           Keep the terminal window open and the computer awake (plugged in,
#           sleep set to "never" in the Windows power settings).
# Status  : bash scripts/e8_4a_rom_smoke.sh status 2>&1 | tee reports/e8_4a_status.log
# Runtime : sandbox estimate 1 to 3 hours. Memory: about 3 GB per
#           simulation of the generator's netlist in the sandbox, probably
#           more for the extracted netlist; four run at once.
# =============================================================================
set -uo pipefail

MODE="${1:-run}"
PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
MACRO="${E8_MACRO:-e8rom_A_pcm_l00_16x2496}"
PERIOD="${E8_PERIOD:-100}"
TIMEOUT="${E8_TIMEOUT:-0}"
HEARTBEAT="${E8_HEARTBEAT:-1800}"
ROOT="$PAPER2/reports/e8_rom"
SP="$ROOT/macros/$MACRO/$MACRO.sp"
GDS="$ROOT/macros/$MACRO/$MACRO.gds"
BIN="$ROOT/bins/$MACRO.bin"
BENCH="$PAPER2/scripts/e8_4_rom_bench.py"
MODELS="$PDK_ROOT_DIR/sky130A/libs.tech/ngspice/sky130.lib.spice"
MAGICRC="$PDK_ROOT_DIR/sky130A/libs.tech/magic/sky130A.magicrc"
WORK="$ROOT/e8_4a/$MACRO"
PEX="$WORK/extract/$MACRO.pex.spice"
RUNS="sch_main sch_recovery ext_main ext_recovery"
WB=2
case "$MACRO" in *_8x*) WB=1 ;; esac

pick() { ls -d $1 2>/dev/null | sort -V | tail -1; }
NGSPICE="${E8_NGSPICE:-$(pick "/nix/store/*-ngspice-*/bin/ngspice")}"
MAGIC="${E8_MAGIC:-$(pick "/nix/store/*magic-vlsi*/bin/magic")}"
NCORES=$(nproc 2>/dev/null || echo 4)
NTHREADS=$(( NCORES / 4 )); [ "$NTHREADS" -lt 1 ] && NTHREADS=1

hr() { echo; echo "########## $* ##########"; }
stamp() { date '+%Y-%m-%d %H:%M:%S'; }

# simulated time reached by a run, from its waveform file
reached() {
  local d=$1
  if [ -s "$d/tb_out.txt" ]; then
    python3 - "$d" <<'PY'
import json, sys, os
d = sys.argv[1]
tstop = json.load(open(os.path.join(d, "tb_meta.json")))["tstop"]
last = None
with open(os.path.join(d, "tb_out.txt")) as fh:
    for line in fh:
        last = line
try:
    t = float(last.split()[0])
except (ValueError, AttributeError, IndexError):
    t = 0.0
print(f"{t*1e9:8.1f} of {tstop*1e9:8.1f} ns ({100*t/tstop:5.1f} %)")
PY
  else
    echo "no data yet"
  fi
}

state() {
  local d=$1
  if [ ! -f "$d/tb_meta.json" ]; then echo "not started"
  elif [ -f "$d/tb_done" ]; then echo "finished"
  elif [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null; then echo "running"
  else echo "not running, stopped before the end"; fi
}

elapsed() {
  local d=$1 s e
  s=$(cat "$d/started" 2>/dev/null) || { echo "-"; return; }
  e=$(cat "$d/finished" 2>/dev/null || date +%s)
  printf "%dh%02dm" $(( (e - s) / 3600 )) $(( (e - s) % 3600 / 60 ))
}

progress() {
  echo "   progress at $(stamp):"
  for R in $RUNS; do
    printf "      %-13s %-36s %-8s %s\n" "$R" "$(state "$WORK/$R")" "$(elapsed "$WORK/$R")" \
      "$( [ -f "$WORK/$R/tb_meta.json" ] && reached "$WORK/$R")"
  done
}

report() {   # report RUN
  local d="$WORK/$1"
  echo; echo "---- $1: $(state "$d"), wall time $(elapsed "$d"), ngspice exit $(cat "$d/exit_code" 2>/dev/null || echo '-') ----"
  [ -f "$d/ngspice.log" ] || { echo "   no log"; return; }
  tr '\r' '\n' < "$d/ngspice.log" | grep -v "Reference value" \
    | grep -iE "error|could not|unknown|singular|timestep too small|abort" | head -8 | sed 's/^/   log: /'
  tr '\r' '\n' < "$d/ngspice.log" | grep -iE "total analysis time|total elapsed time" | head -2 | sed 's/^/   /'
  if [ ! -f "$d/tb_done" ]; then
    echo "   the log ends with:"
    tr '\r' '\n' < "$d/ngspice.log" | grep -v "Reference value" | grep -v '^\s*$' | tail -6 | sed 's/^/      /'
  fi
  python3 "$BENCH" analyze --dir "$d"
}

if [ "$MODE" = "status" ]; then
  echo "=============================================================="
  echo "P2R-E8.4a status, $(stamp)   ($MACRO)"
  echo "=============================================================="
  if [ -f "$WORK/extract/finished" ]; then echo "extraction: finished"
  elif [ -f "$WORK/extract/started" ]; then echo "extraction: running or stopped (started $(date -d @"$(cat "$WORK/extract/started")" '+%F %T'))"
  else echo "extraction: not started"; fi
  progress
  for R in $RUNS; do report "$R"; done
  exit 0
fi

echo "=============================================================="
echo "P2R-E8.4a ROM smoke simulation, started $(stamp)"
echo "=============================================================="
echo "macro    : $MACRO  (word bytes $WB)"
echo "ngspice  : ${NGSPICE:-<missing>}"
echo "magic    : ${MAGIC:-<missing>}"
echo "models   : $MODELS (tt)"
echo "period   : $PERIOD ns   time limit per simulation: $([ "$TIMEOUT" -gt 0 ] && echo "$TIMEOUT s" || echo none)   threads per simulation: $NTHREADS"
echo "machine  : $NCORES cores, $(free -g | awk '/Mem:/{print $2" GiB memory, "$7" GiB available"}')"
for F in "$SP" "$GDS" "$BIN" "$BENCH" "$MODELS" "$MAGICRC"; do
  [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
[ -n "$NGSPICE" ] && [ -n "$MAGIC" ] || { echo "ERROR: ngspice or magic not found" >&2; exit 1; }
"$NGSPICE" -v < /dev/null 2>&1 | grep -m1 -i "ngspice-" | sed 's/^/   /'
# a rerun replaces this script's own previous output for this macro, nothing else
for R in $RUNS extract; do rm -rf "${WORK:?}/${R:?}"; done
mkdir -p "$WORK"/extract || exit 1

spiceinit() {
  cat > "$1/.spiceinit" <<EOF
* ngspice settings recommended for the sky130 models
set ngbehavior=hsa
set ng_nomodcheck
set skywaterpdk
set num_threads=$NTHREADS
EOF
}

launch() {   # launch RUN: start ngspice in the background
  local d="$WORK/$1"
  spiceinit "$d"
  date +%s > "$d/started"
  (
    cd "$d" || exit 99
    if [ "$TIMEOUT" -gt 0 ]; then
      timeout "$TIMEOUT" "$NGSPICE" -b tb.sp > ngspice.log 2>&1
    else
      "$NGSPICE" -b tb.sp > ngspice.log 2>&1
    fi
    echo $? > exit_code
    date +%s > finished
  ) &
  echo $! > "$d/pid"
  echo "   started $1 at $(stamp)"
}

hr "a. the generator's netlist"
python3 "$BENCH" probe --sp "$SP" --top "$MACRO" 2>&1 | grep -v '^{' | head -40

hr "b. read sequences"
SEQ_main=$(python3 "$BENCH" pick --bin "$BIN" --word-bytes "$WB" --mode main)
SEQ_recovery=$(python3 "$BENCH" pick --bin "$BIN" --word-bytes "$WB" --mode recovery 2>/dev/null)
echo "   main     : $SEQ_main"
echo "   recovery : $SEQ_recovery"

hr "c. start the simulations of the generator's netlist (no wire capacitance)"
for Q in main recovery; do
  eval "SEQ=\$SEQ_$Q"
  python3 "$BENCH" bench --sp "$SP" --top "$MACRO" --bin "$BIN" --word-bytes "$WB" \
      --out "$WORK/sch_$Q" --models "$MODELS" --corner tt --period "$PERIOD" --seq "$SEQ" --internal \
    || { echo "ERROR: bench for sch_$Q not written" >&2; exit 1; }
  launch "sch_$Q"
done

hr "d. extraction with magic (devices and parasitic capacitance), meanwhile"
cat > "$WORK/extract/extract.tcl" <<EOF
drc off
gds flatten true
gds ordering true
gds read $GDS
load $MACRO
select top cell
expand
readspice $SP
extract do local
extract all
ext2spice lvs
ext2spice cthresh 0
ext2spice -o $PEX
quit -noprompt
EOF
date +%s > "$WORK/extract/started"
( cd "$WORK/extract" && PDK_ROOT="$PDK_ROOT_DIR" "$MAGIC" -dnull -noconsole \
      -rcfile "$MAGICRC" < extract.tcl > magic_extract.log 2>&1 )
echo "   magic exit $?, wall time $(( $(date +%s) - $(cat "$WORK/extract/started") )) s"
date +%s > "$WORK/extract/finished"
grep -iE "error|fatal|could not|not found" "$WORK/extract/magic_extract.log" | grep -v "placed on top of itself" \
    | head -10 | sed 's/^/   log: /'
if [ -s "$PEX" ]; then
  ls -la "$PEX" | sed 's/^/   /'
  echo "   first lines and first devices of the extracted netlist:"
  grep -v '^\*' "$PEX" | head -4 | cut -c1-200 | sed 's/^/      /'
  grep -m3 -E "sky130_fd_pr__nfet_01v8" "$PEX" | cut -c1-200 | sed 's/^/      /'
  grep -m2 -E "^C" "$PEX" | cut -c1-200 | sed 's/^/      /'
  python3 "$BENCH" probe --sp "$PEX" --top "$MACRO" 2>&1 | grep -v '^{' | head -40
  echo
  echo "   start the simulations of the extracted netlist (with parasitic capacitance)"
  for Q in main recovery; do
    eval "SEQ=\$SEQ_$Q"
    if python3 "$BENCH" bench --sp "$PEX" --top "$MACRO" --bin "$BIN" --word-bytes "$WB" \
        --out "$WORK/ext_$Q" --models "$MODELS" --corner tt --period "$PERIOD" --seq "$SEQ"; then
      launch "ext_$Q"
    else
      echo "   ERROR: bench for ext_$Q not written; that simulation is skipped"
    fi
  done
else
  echo "   no extracted netlist; the extracted simulations are skipped. The magic log ends with:"
  tail -20 "$WORK/extract/magic_extract.log" | sed 's/^/   /'
fi

hr "e. waiting for the simulations (progress every $HEARTBEAT s)"
progress
last=$(date +%s)
while :; do
  alive=0
  for R in $RUNS; do
    [ -f "$WORK/$R/pid" ] && kill -0 "$(cat "$WORK/$R/pid")" 2>/dev/null && alive=1
  done
  [ "$alive" -eq 0 ] && break
  sleep 30
  if [ $(( $(date +%s) - last )) -ge "$HEARTBEAT" ]; then
    progress
    last=$(date +%s)
  fi
done
wait 2>/dev/null
progress

hr "f. results"
for R in $RUNS; do report "$R"; done

echo
echo "---- files, all in the folder $WORK ----"
ls -la "$WORK"/sch_* "$WORK"/ext_* "$WORK"/extract 2>/dev/null | grep -vE "\.ext$" | sed 's/^/   /'
echo
echo "=============================================================="
echo "Finished $(stamp)."
echo "=============================================================="
