#!/usr/bin/env bash
# =============================================================================
# e8_4a4_rom_rows.sh   [run | status | stop]
#
# Experiment : P2R-E8.4a-4. Which rows of the E8.3 ROM macro (13 words per
#              row, 192 rows) can be read correctly at the system's lookup
#              interval, and why the real data needs a longer precharge than
#              a column made of transistors only.
#
# Why
#   - E8.4a-2/E8.4a-3 (post-layout): after a read of a row with many zero
#     bits, a read of the bottom row needs 350-450 ns of precharge; the fully
#     connected layers look up every 140 ns (E8.2). Wider rows (shorter
#     chains) were slower, not faster.
#   - Sandbox, 2026-10-11 (claude/p2r-e8-4a4-sandbox.md): the series NMOS
#     chain can precharge its internal nodes only to about 1.0-1.25 V, and
#     the far nodes slowly; a read of a far row shares the bitline's charge
#     with the nodes above the read cell, and the bit reads 0 if the bitline
#     falls below the bitline inverter's switching level (about 0.82-0.88 V).
#     With a column made of transistors only, 192 rows need 100-150 ns; the
#     real data needed 250-550 ns on the same kind of netlist (E8.4a-2).
#
# Runs (macro e8rom_A_pcm_l00_16x2496; tt, 25 C, 1.8 V, period 100 ns)
#   ext_row<R>   post-layout netlist of E8.4a-2 (flat extraction with
#                parasitic capacitance), target row R (default 16 32 64 96
#                128 160 191): i, then for each wait N (0 40 100 200 400 600
#                ns): rA (row 0, the word with the most zero bits; a read of
#                row 0 discharges every chain node below row 0 in every
#                column, the worst case before any read), N ns with the clock
#                held low, rR (row R, the word with the most one bits).
#                Precharge before rR = N + 50 ns (50 90 150 250 450 650).
#   asad_row<R>  the same on the generator's netlist with the junction areas
#                corrected (as E8.4a-2 "asad"), saving the bitline and every
#                second chain node of the columns of bits 0, 1, 8 and 15 of
#                the target word
#   asad_sweep   the E8.4a-3 sweep (row 8 -> row 191, waits 0-500 ns) on the
#                generator's netlist, with the same chain probes for the word
#                read in row 191 (columns 0, 13, 104, 195)
#
# Results : each run (analyze); the chain voltages (asad runs); the row maps
#           (post-layout and generator netlist): for each target row the
#           precharge from which it reads correctly, and whether it is safe
#           at the lookup interval (E8_INTERVAL, default 140 ns, i.e. 90 ns of
#           precharge with a 50 ns evaluation).
# Place   : D:\Project\hybrid_memory\paper2\scripts\  (with e8_4_rom_bench.py
#           of 2026-10-11 (3), which replaces the earlier ones)
# Writes  : only reports\e8_rom\e8_4a4\<macro>\ (a rerun replaces it; it
#           refuses to start while an earlier run still works there). E8.3's
#           macro and the E8.4a-2 folder are only read.
# Run     : cd /mnt/d/Project/hybrid_memory/paper2
#           bash scripts/e8_4a4_rom_rows.sh 2>&1 | tee reports/e8_4a4_rom_rows.log
#           Keep the terminal open and the computer awake.
# Status  : bash scripts/e8_4a4_rom_rows.sh status 2>&1 | tee reports/e8_4a4_status.log
# Stop    : bash scripts/e8_4a4_rom_rows.sh stop
#           (Ctrl+C alone ends only the script: the simulations keep running)
# Options : E8_ROWS (default "16 32 64 96 128 160 191"), E8_WAITS (default
#           "0,40,100,200,400,600"), E8_INTERVAL (default 140), E8_MAXSIM
#           (default 4), E8_PERIOD (default 100), E8_CHAIN_STEP (default 2),
#           E8_MACRO, E8_TIMEOUT (default 0 = none).
# Runtime : 7 post-layout runs of about 45-60 min and 8 runs on the
#           generator's netlist of about 15-25 min, at most 4 at a time:
#           about 2-2.5 hours. Memory: about 3 GB per post-layout run.
#           Disk: about 1 GB.
# =============================================================================
set -uo pipefail

MODE="${1:-run}"
PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
MACRO="${E8_MACRO:-e8rom_A_pcm_l00_16x2496}"
ROWS="${E8_ROWS:-16 32 64 96 128 160 191}"
WAITS="${E8_WAITS:-0,40,100,200,400,600}"
INTERVAL="${E8_INTERVAL:-140}"
PERIOD="${E8_PERIOD:-100}"
MAXSIM="${E8_MAXSIM:-4}"
TIMEOUT="${E8_TIMEOUT:-0}"
HEARTBEAT="${E8_HEARTBEAT:-1800}"
CHAIN_STEP="${E8_CHAIN_STEP:-2}"
ROOT="$PAPER2/reports/e8_rom"
SP0="$ROOT/macros/$MACRO/$MACRO.sp"
BIN="$ROOT/bins/$MACRO.bin"
OLD="$ROOT/e8_4a2/$MACRO"
PEX0="$OLD/extract/$MACRO.flat_pex.spice"
BENCH="$PAPER2/scripts/e8_4_rom_bench.py"
MODELS="$PDK_ROOT_DIR/sky130A/libs.tech/ngspice/sky130.lib.spice"
WORK="$ROOT/e8_4a4/$MACRO"
WB=2
case "$MACRO" in *_8x*) WB=1 ;; esac
SELF="e8_4a4_rom_rows.sh"

pick_path() { ls -d $1 2>/dev/null | sort -V | tail -1; }
NGSPICE="${E8_NGSPICE:-$(pick_path "/nix/store/*-ngspice-*/bin/ngspice")}"
NCORES=$(nproc 2>/dev/null || echo 4)
NTHREADS=2

for r in $ROWS; do
  case "$r" in ''|*[!0-9]*) echo "ERROR: E8_ROWS must list row numbers (got '$r')" >&2; exit 1 ;; esac
done
RUNS=""
for r in $ROWS; do RUNS="$RUNS ext_row$r"; done
for r in $ROWS; do RUNS="$RUNS asad_row$r"; done
RUNS="$RUNS asad_sweep"

# ---- processes of a run of this script (for the guard and the stop mode) ----
args01() {   # the first two words of the command line of process $1 (base names), as "a0 a1"
  local a0="" a1=""
  { IFS= read -r -d '' a0; IFS= read -r -d '' a1; } 2>/dev/null < "/proc/$1/cmdline"
  echo "${a0##*/} ${a1##*/}"
}
is_tool() {   # process $1 is ngspice (or a shell running a wrapper of it), or this script
  local a0 a1
  read -r a0 a1 <<< "$(args01 "$1")"
  case "$a0" in
    ngspice) return 0 ;;
    bash|sh) case "$a1" in ngspice|"$SELF") return 0 ;; esac ;;
  esac
  return 1
}
is_mine() {   # process $1 is this invocation of the script or one of its subshells
  local q=$1 n=0 st
  while [ -n "$q" ] && [ "$q" -gt 1 ] && [ "$n" -lt 64 ]; do
    [ "$q" = "$$" ] && return 0
    { read -r st < "/proc/$q/stat"; } 2>/dev/null || return 1
    st=${st##*) }
    set -- $st
    q=${2:-}
    n=$((n + 1))
  done
  return 1
}
procs_in_work() {   # this script's simulations working in $WORK (a shell or viewer opened there is left alone)
  local p c
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    c=$(readlink "/proc/$p/cwd" 2>/dev/null) || continue
    case "$c" in "$WORK"|"$WORK"/*) is_tool "$p" && ! is_mine "$p" && echo "$p" ;; esac
  done
}
other_runs() {   # other running instances of this script in run mode
  local p a0 a1 a2
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    a0="" a1="" a2=""
    { IFS= read -r -d '' a0; IFS= read -r -d '' a1; IFS= read -r -d '' a2; } 2>/dev/null < "/proc/$p/cmdline"
    case "${a0##*/}" in bash|sh) ;; *) continue ;; esac
    [ "${a1##*/}" = "$SELF" ] || continue
    case "$a2" in ""|run) ;; *) continue ;; esac
    is_mine "$p" || echo "$p"
  done
}

hr() { echo; echo "########## $* ##########"; }
stamp() { date '+%Y-%m-%d %H:%M:%S'; }

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
  if [ ! -f "$d/tb_meta.json" ]; then echo "not written"
  elif [ -f "$d/tb_failed" ]; then echo "FAILED (see its log)"
  elif [ -f "$d/tb_done" ]; then echo "finished"
  elif [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null; then echo "running"
  elif [ -f "$d/finished" ]; then echo "ENDED WITHOUT COMPLETION (see its log)"
  elif [ -f "$d/pid" ]; then echo "not running, stopped before the end"
  else echo "queued"; fi
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
    printf "      %-12s %-40s %-8s %s\n" "$R" "$(state "$WORK/$R")" "$(elapsed "$WORK/$R")" \
      "$( [ -f "$WORK/$R/tb_meta.json" ] && reached "$WORK/$R")"
  done
}
report() {   # report DIR LABEL
  local d=$1
  echo; echo "---- $2: $(state "$d"), wall time $(elapsed "$d"), ngspice exit $(cat "$d/exit_code" 2>/dev/null || echo '-') ----"
  [ -f "$d/ngspice.log" ] || { echo "   no log"; return; }
  tr '\r' '\n' < "$d/ngspice.log" | grep -v "Reference value" \
    | grep -iE "error|could not|unknown|singular|timestep too small|abort|E8_FAILED" | sort | uniq -c \
    | sort -rn | head -8 | sed 's/^/   log: /'
  tr '\r' '\n' < "$d/ngspice.log" | grep -iE "total analysis time" | head -1 | sed 's/^/   /'
  python3 "$BENCH" analyze --dir "$d"
}
summaries() {
  local ext="" asad=""
  for r in $ROWS; do
    [ -f "$WORK/ext_row$r/result.json" ] && ext="$ext $WORK/ext_row$r"
    [ -f "$WORK/asad_row$r/result.json" ] && asad="$asad $WORK/asad_row$r"
  done
  echo
  if [ -n "$ext" ]; then
    python3 "$BENCH" rowmap --dirs $ext --interval "$INTERVAL" --title "post-layout (E8.4a-2 extraction)"
  else
    echo "post-layout row map: no results yet"
  fi
  echo
  if [ -n "$asad" ]; then
    python3 "$BENCH" rowmap --dirs $asad --interval "$INTERVAL" --title "generator netlist, junction areas corrected"
  else
    echo "generator-netlist row map: no results yet"
  fi
}

if [ "$MODE" = "status" ]; then
  echo "=============================================================="
  echo "P2R-E8.4a-4 status, $(stamp)   ($MACRO)"
  echo "=============================================================="
  progress
  for R in $RUNS; do
    [ -f "$WORK/$R/tb_meta.json" ] && report "$WORK/$R" "$R"
  done
  hr "row maps (as far as available)"
  summaries
  exit 0
fi

if [ "$MODE" = "stop" ]; then
  echo "P2R-E8.4a-4 stop, $(stamp)   ($WORK)"
  R=$(other_runs | tr '\n' ' ')
  if [ -n "${R// /}" ]; then
    echo "   ending the running script: $R"
    kill $R 2>/dev/null
    sleep 2
  fi
  P=$(procs_in_work | tr '\n' ' ')
  if [ -n "${P// /}" ]; then
    echo "   ending $(echo $P | wc -w) process(es) working in the folder:"
    ps -o pid=,args= -p "$(echo $P | tr ' ' ',')" 2>/dev/null | cut -c1-110 | sed 's/^/      /'
    kill $P 2>/dev/null
    sleep 5
    P=$(procs_in_work | tr '\n' ' ')
    if [ -n "${P// /}" ]; then echo "   still running, forcing: $P"; kill -9 $P 2>/dev/null; sleep 1; fi
  fi
  R=$(other_runs | tr '\n' ' '); P=$(procs_in_work | tr '\n' ' ')
  if [ -n "${R// /}${P// /}" ]; then
    echo "   NOT everything ended (script: ${R:-none}; processes: ${P:-none})"
    exit 1
  fi
  echo "   nothing of this script is running any more"
  exit 0
fi

R=$(other_runs | tr '\n' ' '); P=$(procs_in_work | tr '\n' ' ')
if [ -n "${R// /}${P// /}" ]; then
  echo "ERROR: an earlier run is still working (script: ${R:-none}; processes in $WORK: ${P:-none})." >&2
  echo "       Let it finish, or end it first with: bash scripts/$SELF stop" >&2
  exit 1
fi

echo "=============================================================="
echo "P2R-E8.4a-4 rows of the ROM, started $(stamp)"
echo "=============================================================="
echo "macro    : $MACRO  (word bytes $WB)"
echo "rows     : $ROWS   waits (ns): $WAITS   lookup interval: $INTERVAL ns"
echo "ngspice  : ${NGSPICE:-<missing>}"
echo "models   : $MODELS (tt)"
echo "period   : $PERIOD ns   at most $MAXSIM simulations at a time, $NTHREADS threads each   time limit: $([ "$TIMEOUT" -gt 0 ] && echo "$TIMEOUT s" || echo none)"
echo "machine  : $NCORES cores, $(free -g | awk '/Mem:/{print $2" GiB memory, "$7" GiB available"}')"
for F in "$SP0" "$BIN" "$PEX0" "$BENCH" "$MODELS"; do
  [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
[ -n "$NGSPICE" ] || { echo "ERROR: ngspice not found" >&2; exit 1; }
grep -q "def cmd_rowmap" "$BENCH" || { echo "ERROR: $BENCH is an older version; copy the one of 2026-10-11 (3)" >&2; exit 1; }
"$NGSPICE" -v < /dev/null 2>&1 | grep -m1 -i "ngspice-" | sed 's/^/   /'

rm -rf "${WORK:?}"
mkdir -p "$WORK" || exit 1

spiceinit() {
  cat > "$1/.spiceinit" <<EOF
* ngspice settings recommended for the sky130 models
set ngbehavior=hsa
set ng_nomodcheck
set skywaterpdk
set num_threads=$NTHREADS
EOF
}
launch() {   # launch DIR
  local d=$1
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
  echo "   started ${d#$WORK/} at $(stamp)"
}
QUEUE=()
running() {
  local n=0 d
  for d in "${QUEUE[@]}"; do
    [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null && n=$((n + 1))
  done
  echo $n
}
pump() {
  local d
  for d in "${QUEUE[@]}"; do
    [ -f "$d/pid" ] && continue
    [ "$(running)" -lt "$MAXSIM" ] || break
    launch "$d"
  done
}
write_bench() {   # write_bench RUN NETLIST TOP SEQ OPTIONS...
  local R=$1 NET=$2 TOPN=$3 SEQ=$4
  shift 4
  if python3 "$BENCH" bench --sp "$NET" --top "$TOPN" --bin "$BIN" --word-bytes "$WB" --out "$WORK/$R" \
      --models "$MODELS" --corner tt --period "$PERIOD" --seq "$SEQ" "$@" > "$WORK/bench_$R.txt" 2>&1; then
    grep -E "note: (probes|chain)|WARNING" "$WORK/bench_$R.txt" | sed 's/^/      /'
    QUEUE+=("$WORK/$R")
  else
    echo "      ERROR: bench $R not written:"; tail -3 "$WORK/bench_$R.txt" | sed 's/^/      /'
  fi
}

hr "a. sequences and benches"
for r in $ROWS; do
  SEQ=$(python3 "$BENCH" pick --bin "$BIN" --word-bytes "$WB" --mode rowmap --row "$r" --waits "$WAITS" 2>"$WORK/pick_row$r.txt")
  if [ -z "$SEQ" ]; then
    echo "   row $r: no sequence:"; sed 's/^/      /' "$WORK/pick_row$r.txt"; continue
  fi
  echo "   row $r: $(grep -E '^A = ' "$WORK/pick_row$r.txt")"
  echo "      $SEQ"
  write_bench "ext_row$r" "$PEX0" "$MACRO" "$SEQ" --sanitize --plain-nfet --probes full
done
for r in $ROWS; do
  SEQ=$(python3 "$BENCH" pick --bin "$BIN" --word-bytes "$WB" --mode rowmap --row "$r" --waits "$WAITS" 2>/dev/null)
  [ -n "$SEQ" ] || continue
  echo "   asad_row$r"
  write_bench "asad_row$r" "$SP0" "$MACRO" "$SEQ" --fix-asad --probes full --chain-cols auto --chain-step "$CHAIN_STEP"
done
SEQ=$(python3 "$BENCH" pick --bin "$BIN" --word-bytes "$WB" --mode sweep 2>"$WORK/pick_sweep.txt")
echo "   asad_sweep: $(grep -E '^M = ' "$WORK/pick_sweep.txt")"
echo "      $SEQ"
write_bench "asad_sweep" "$SP0" "$MACRO" "$SEQ" --fix-asad --probes full --chain-cols auto --chain-step "$CHAIN_STEP"

hr "b. simulations (at most $MAXSIM at a time; post-layout runs first; progress every $HEARTBEAT s)"
pump
progress
last=$(date +%s)
while :; do
  pump
  busy=0
  for d in "${QUEUE[@]}"; do
    if [ ! -f "$d/pid" ] || kill -0 "$(cat "$d/pid")" 2>/dev/null; then busy=1; fi
  done
  [ "$busy" -eq 0 ] && break
  sleep 30
  if [ $(( $(date +%s) - last )) -ge "$HEARTBEAT" ]; then
    progress
    last=$(date +%s)
  fi
done
wait 2>/dev/null
progress

hr "c. results"
for R in $RUNS; do
  [ -f "$WORK/$R/tb_meta.json" ] && report "$WORK/$R" "$R"
done

hr "d. chain nodes (generator netlist)"
for R in $RUNS; do
  case "$R" in asad_*) [ -f "$WORK/$R/result.json" ] && { echo; echo "---- $R ----"; python3 "$BENCH" chains --dir "$WORK/$R"; } ;; esac
done

hr "e. row maps"
summaries

echo
echo "---- files: $WORK ----"
du -sh "$WORK" 2>/dev/null | sed 's/^/   /'
echo
echo "=============================================================="
echo "Finished $(stamp)."
echo "=============================================================="
