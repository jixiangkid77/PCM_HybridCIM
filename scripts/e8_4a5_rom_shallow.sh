#!/usr/bin/env bash
# =============================================================================
# e8_4a5_rom_shallow.sh   [run | status | stop]
#
# Experiment : P2R-E8.4a-5. Shallow ROM macros: one address-map table cut into
#              several macros with fewer rows, so that every bitline chain is
#              short. Can such macros be built (LVS, extraction errors), what
#              do they cost in area, and do their deepest rows read correctly
#              at the system's lookup interval, also at slow corners?
#
# Why (E8.4a-4, 2026-10-11, post-layout, the E8.3 macro: 13 words per row,
# 192 rows)
#   - After a read of row 0, the tested word (the one with the most one bits)
#     of rows down to 64 read correctly with 90 ns of precharge (the 140 ns
#     lookup interval minus the 50 ns evaluation), row 64 with little margin;
#     rows 96 and deeper needed 150-450 ns. Only one word per row was tested.
#   - Mechanism: the chain nodes above the read cell are precharged only
#     through the series NMOS (to about 1.0-1.25 V, the far ones slowly); a
#     one bit reads 0 when its bitline, sharing charge with these nodes,
#     falls below the bitline inverter's switching level (0.867-0.896 V).
#     Deep rows in columns with many zero cells are the worst.
#   - KID chose option A (2026-10-11 21:38): split each table into macros of
#     64 or 48 rows.
#
# Options (same table, same 16-bit words, 13 words per row as E8.3)
#   r64   3 macros of 64 rows x 208 columns (832 words each)
#   r48   4 macros of 48 rows x 208 columns (624 words each)
#   r32   6 macros of 32 rows x 208 columns (416 words each)
#   Macro k holds the entries k*832 ... (r64), k*624 ... (r48) or k*416 ...
#   (r32), i.e. rows 64k ..., 48k ... or 32k ... of the E8.3 macro (bench
#   split checks this bit by bit). The configurations are E8.3's (perimeter
#   pins as E8.3) plus words_per_row = 13 (OpenRAM would choose 8, 7 or 5
#   words per row); 13 is below the column-multiplexer fault (26 and more).
#   Why r32 as well (sandbox, 2026-10-11, synthetic data, post-layout, tt,
#   90 ns of precharge after a read of row 0): the same four table rows read
#   as the deepest rows of a 64-, 48- and 32-row macro gave a lowest one-cell
#   bitline of 0.822-0.912 V (r64; 2 of 4 reads wrong), 0.831-0.872 V (r48;
#   1 of 4 wrong) and 0.947-1.459 V (r32; all correct). r64 and r48 were
#   alike; only r32 had margin. The real table decides.
#
# Steps
#   a. tools and files; the Python that runs OpenRAM (as E8.3); which model
#      sections are slow or fast (drive current of a 1 um / 0.15 um NMOS and
#      PMOS at 25 C against tt)
#   b. cut the table; generate every macro (E8_MAXGEN at a time, default 4);
#      check that each netlist stores its part bit by bit; drawn layout
#      extent (magic box) of each and of the E8.3 macro
#   c. flat extraction of every macro (for LVS, and with parasitic
#      capacitance, as E8.4a-2), at most E8_MAXMAGIC at a time (default 4);
#      then extraction errors, supply merges, capacitor check, netgen LVS, and
#      the screening simulation of the macro. At most E8_MAXJOBS magic and
#      ngspice jobs run at a time (default: the number of cores minus one);
#      each ngspice uses one thread (sandbox: a second thread made a 32-row
#      macro only 1.18 times faster)
#   d. screening (post-layout, tt, 25 C, 1.8 V): for each of the deepest
#      E8_SCREEN_ROWS rows (default 16), deepest first: a read of row 0 (it
#      discharges every chain node below row 0 in every column), the clock
#      held low for E8_SCREEN_WAIT ns (default 40: 90 ns of precharge), a read
#      of the row. Every bitline is saved: the wordline of the read row goes
#      low in all 208 columns and each bitline has its own inverter before the
#      column multiplexer, so one read tests every cell of the row (the lowest
#      bitline of its one cells while evaluating, the highest of its zero
#      cells at the sampling time).
#   e. per option, when its screenings are done: the macro with the lowest
#      one-cell bitline, and in it the E8_NWORST rows (default 2) with the
#      lowest one-cell bitline, each with its worst word; on that macro:
#        sweep   tt, 25 C, 1.8 V: precharge 50, 70, 90, 110, 150, 250 ns
#                (E8_SWEEP_WAITS "0,20,40,60,100,200") before each word
#        corners only if every screening read was correct and the lowest
#                one-cell bitline is at least E8_CORNER_MIN_V (0.90 V):
#                E8_CORNERS (model section : temperature in C : supply in V;
#                default "fs:25:1.80 ss:25:1.80 tt:25:1.60 fs:-40:1.60
#                ss:100:1.60"), precharge 90 and 300 ns (E8_CORNER_WAITS
#                "40,250"). The first three change one thing against tt,
#                25 C, 1.80 V (process skew, slow process, supply); the last
#                two are the worst cases for a one bit and for a zero bit
#                (1.60 V and 100 C / -40 C are the slow supply and the
#                temperatures of sky130's standard-cell corners, ss_100C_1v60,
#                ss_n40C_1v60). In this model library the section fs has a
#                slow NMOS and a fast PMOS (sandbox: drive at 25 C against tt,
#                NMOS -16 %, PMOS +33 %; sf is the reverse); step a measures
#                it again on this PDK. A slow NMOS lowers the chain nodes, a
#                fast PMOS raises the bitline inverter's switching level.
#                Sandbox (synthetic data, 32-row macro, its worst word): tt,
#                25 C, 1.80 V correct from 50 ns; fs 25 C 1.80 V, ss 100 C
#                1.80 V, fs -40 C 1.60 V and ss 100 C 1.60 V wrong at 90 and
#                300 ns (fs -40 C 1.60 V also at 600 ns); tt 25 C 1.60 V wrong
#                at 90 ns, correct at 300 ns. Step b also measures the
#                inverter's switching level at each condition.
#   f. results: area, stored bits, LVS and extraction errors per macro and
#      per option; each simulation; the row margins of the screenings; the
#      precharge each worst word needs (tt sweep, corners) and whether it is
#      safe at the lookup interval (E8_INTERVAL, default 140 ns)
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\  with e8_4_rom_bench.py of
#           2026-10-11 (4), which replaces the earlier ones
# Writes  : only reports\e8_rom\e8_4a5\<macro>\ (a rerun replaces it; it refuses
#           to start while an earlier run still works there). E8.3's macro and
#           data file are only read.
# Run     : cd /mnt/d/Project/hybrid_memory/paper2
#           bash scripts/e8_4a5_rom_shallow.sh 2>&1 | tee reports/e8_4a5_rom_shallow.log
#           Keep the terminal open and the computer awake.
# Status  : bash scripts/e8_4a5_rom_shallow.sh status 2>&1 | tee reports/e8_4a5_status.log
# Stop    : bash scripts/e8_4a5_rom_shallow.sh stop
#           (Ctrl+C alone ends only the script: the jobs it started keep running)
# Options : E8_SPLITS (rows per macro, default "64 48 32"), E8_SCREEN_ROWS (16),
#           E8_SCREEN_WAIT (40), E8_SWEEP_WAITS, E8_CORNERS, E8_CORNER_WAITS,
#           E8_CORNER_MIN_V (0.90), E8_NWORST (2), E8_INTERVAL (140),
#           E8_MAXGEN (4), E8_MAXMAGIC (4), E8_MAXJOBS (cores - 1), E8_PERIOD
#           (100), E8_MACRO, E8_TIMEOUT (0 = none), E8_OPENRAM_PY.
#           Used only for testing: E8_WPR (13), E8_USE_NIX, E8_OPENRAM_PDK.
# Runtime : 13 macros. Estimated from the sandbox: generation about 5 min;
#           extraction 15-40 min per macro; screenings 30-60 min, tt sweeps
#           30-50 min, corner runs 30-55 min each. In all about 3.5 to 4.5
#           hours (more if several options pass at tt and get corner runs).
#           Memory: under 1 GB per simulation. Disk: about 2 GB.
# =============================================================================
set -uo pipefail

MODE="${1:-run}"
PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
OPENRAM="${E8_OPENRAM:-/home/kid/openram/OpenRAM}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
MACRO="${E8_MACRO:-e8rom_A_pcm_l00_16x2496}"
SPLITS="${E8_SPLITS:-64 48 32}"
WPR="${E8_WPR:-13}"
SCREEN_ROWS="${E8_SCREEN_ROWS:-16}"
SCREEN_WAIT="${E8_SCREEN_WAIT:-40}"
SWEEP_WAITS="${E8_SWEEP_WAITS:-0,20,40,60,100,200}"
CORNERS="${E8_CORNERS:-fs:25:1.80 ss:25:1.80 tt:25:1.60 fs:-40:1.60 ss:100:1.60}"
CORNER_WAITS="${E8_CORNER_WAITS:-40,250}"
CORNER_MIN_V="${E8_CORNER_MIN_V:-0.90}"
NWORST="${E8_NWORST:-2}"
INTERVAL="${E8_INTERVAL:-140}"
PERIOD="${E8_PERIOD:-100}"
MAXGEN="${E8_MAXGEN:-4}"
MAXMAGIC="${E8_MAXMAGIC:-4}"
TIMEOUT="${E8_TIMEOUT:-0}"
HEARTBEAT="${E8_HEARTBEAT:-1800}"
ROOT="$PAPER2/reports/e8_rom"
SP0="$ROOT/macros/$MACRO/$MACRO.sp"
GDS0="$ROOT/macros/$MACRO/$MACRO.gds"
LEF0="$ROOT/macros/$MACRO/$MACRO.lef"
BIN="$ROOT/bins/$MACRO.bin"
BENCH="$PAPER2/scripts/e8_4_rom_bench.py"
MODELS="$PDK_ROOT_DIR/sky130A/libs.tech/ngspice/sky130.lib.spice"
MAGICRC="$PDK_ROOT_DIR/sky130A/libs.tech/magic/sky130A.magicrc"
NETGEN_SETUP="$PDK_ROOT_DIR/sky130A/libs.tech/netgen/sky130A_setup.tcl"
WORK="$ROOT/e8_4a5/$MACRO"
WB=2
case "$MACRO" in *_8x*) WB=1 ;; esac
SELF="e8_4a5_rom_shallow.sh"

pick_path() { ls -d $1 2>/dev/null | sort -V | tail -1; }
NGSPICE="${E8_NGSPICE:-$(pick_path "/nix/store/*-ngspice-*/bin/ngspice")}"
MAGIC="${E8_MAGIC:-$(pick_path "/nix/store/*magic-vlsi*/bin/magic")}"
NETGEN="${E8_NETGEN:-$(pick_path "/nix/store/*netgen*/bin/netgen")}"
NCORES=$(nproc 2>/dev/null || echo 4)
MAXJOBS="${E8_MAXJOBS:-$(( NCORES > 2 ? NCORES - 1 : 1 ))}"
NTHREADS=1          # sandbox, 2026-10-11: a second thread made a 32-row macro only 1.18 times faster

for r in $SPLITS; do
  case "$r" in ''|*[!0-9]*) echo "ERROR: E8_SPLITS must list numbers of rows per macro (got '$r')" >&2; exit 1 ;; esac
done
case "$WPR" in ''|*[!0-9]*) echo "ERROR: E8_WPR must be a number" >&2; exit 1 ;; esac
if [ "$WPR" -gt 24 ]; then
  echo "ERROR: $WPR words per row: OpenRAM e16d9eb draws a faulty column multiplexer from 26 words per row" >&2
  exit 1
fi
for c in $CORNERS; do
  case "$c" in *:*:*) ;; *) echo "ERROR: E8_CORNERS entries are section:temperature:supply (got '$c')" >&2; exit 1 ;; esac
done

# ---- processes of a run of this script (for the guard and the stop mode) ----
args01() {   # the first two words of the command line of process $1 (base names), as "a0 a1"
  local a0="" a1=""
  { IFS= read -r -d '' a0; IFS= read -r -d '' a1; } 2>/dev/null < "/proc/$1/cmdline"
  echo "${a0##*/} ${a1##*/}"
}
is_tool() {   # process $1 is ngspice, magic or netgen (or a shell running their wrapper), or this script
  local a0 a1
  read -r a0 a1 <<< "$(args01 "$1")"
  case "$a0" in
    ngspice|magic|magicdnull|magicexec|netgen|netgenexec|tclsh*|wish*) return 0 ;;
    bash|sh) case "$a1" in ngspice|magic|netgen|"$SELF") return 0 ;; esac ;;
  esac
  return 1
}
uses_config() {   # the command line of process $1 names a configuration of this run (OpenRAM)
  local e
  while IFS= read -r -d '' e; do
    case "$e" in "$WORK"/configs/*) return 0 ;; esac
  done 2>/dev/null < "/proc/$1/cmdline"
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
procs_in_work() {   # this script's tools working in $WORK (a shell or viewer opened there is left alone)
  local p c hit
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    c=$(readlink "/proc/$p/cwd" 2>/dev/null) || continue
    hit=0
    case "$c" in
      "$WORK"|"$WORK"/*) is_tool "$p" && hit=1 ;;
      *) uses_config "$p" && hit=1 ;;
    esac
    [ "$hit" = 1 ] && ! is_mine "$p" && echo "$p"
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

# ---- names ----
opt_names() {   # the macros of option r<R> (from the split written in step b)
  cat "$WORK/bins/r$1.names" 2>/dev/null
}
all_names() { local r; for r in $SPLITS; do opt_names "$r"; done; }
corner_tag() { local s t v; IFS=: read -r s t v <<< "$1"; echo "${s}_${t/-/m}C_${v/./v}"; }
opt_runs() {   # the sweep and corner runs of option r<R>
  local c
  echo "$WORK/r$1/sweep_tt"
  for c in $CORNERS; do echo "$WORK/r$1/corner_$(corner_tag "$c")"; done
}

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
ext_state() {   # state of the extraction of macro $1
  local X="$WORK/$1/extract"
  if [ -f "$X/finished" ]; then echo "finished ($(( $(cat "$X/finished") - $(cat "$X/started") )) s, magic exit $(cat "$X/magic_exit" 2>/dev/null))"
  elif [ -f "$X/started" ]; then echo "running ($(( $(date +%s) - $(cat "$X/started") )) s)"
  else echo "not started"; fi
}
progress() {
  local r n L R
  echo "   progress at $(stamp):"
  for r in $SPLITS; do
    for n in $(opt_names "$r"); do
      L="$WORK/$n/lvs"
      printf "      %-34s extraction %-34s LVS %-9s screen %-12s %-6s %s\n" "$n" "$(ext_state "$n")" \
        "$( [ -f "$L/finished" ] && echo finished || ([ -f "$L/started" ] && echo running || echo -))" \
        "$(state "$WORK/$n/screen")" "$(elapsed "$WORK/$n/screen")" \
        "$( [ -f "$WORK/$n/screen/tb_meta.json" ] && reached "$WORK/$n/screen")"
    done
    for R in $(opt_runs "$r"); do
      [ -f "$R/tb_meta.json" ] || continue
      printf "      r%-3s %-30s %-40s %-6s %s\n" "$r" "${R##*/}" "$(state "$R")" "$(elapsed "$R")" "$(reached "$R")"
    done
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
lvs_report() {   # lvs_report NAME
  local L="$WORK/$1/lvs"
  echo
  echo "---- $1: LVS $( [ -f "$L/finished" ] && echo "finished, $(( $(cat "$L/finished") - $(cat "$L/started") )) s" \
        || ([ -f "$L/started" ] && echo "running" || echo "not started")) ----"
  [ -f "$L/netgen.log" ] || return
  grep -E "^Circuit 1 contains|^Circuit 2 contains|Final result|match uniquely|do not match|ERROR|Error" \
      "$L/netgen.log" | tail -6 | sed 's/^/   /'
  if [ -f "$L/lvs_report.txt" ] && ! grep -q "match uniquely" "$L/netgen.log"; then
    awk '/(NET|DEVICE) mismatches/{f=1;n=0} /Netlists do not match|Subcircuit pins/{f=0} f&&n<60{print; n++}' \
        "$L/lvs_report.txt" | tail -120 | cut -c1-140 | sed 's/^/      /'
  fi
}
write_spec() {   # macrosum spec
  local f="$WORK/macros.json" first=1 r n
  {
    echo "{"
    printf '"reference": {"label": "%s (E8.3, 192 rows)", "bin": "%s", "word_bytes": %s, "wpr": null, "lef": "%s", "box_log": "%s"},\n' \
      "$MACRO" "$BIN" "$WB" "$LEF0" "$WORK/area/$MACRO.box.log"
    echo '"macros": ['
    for r in $SPLITS; do
      for n in $(opt_names "$r"); do
        [ $first -eq 1 ] || echo ","
        first=0
        printf '{"option": "r%s", "label": "%s", "bin": "%s", "word_bytes": %s, "wpr": %s, "lef": "%s", "box_log": "%s", "bitcheck_log": "%s", "lvs_log": "%s", "extract_log": "%s"}' \
          "$r" "$n" "$WORK/bins/$n.bin" "$WB" "$WPR" "$WORK/macros/$n/$n.lef" "$WORK/area/$n.box.log" \
          "$WORK/logs/bitcheck_$n.txt" "$WORK/$n/lvs/netgen.log" "$WORK/$n/extract/magic_extract.log"
      done
    done
    echo "]}"
  } > "$f"
}
summaries() {
  local r n dirs labs R
  echo
  write_spec
  python3 "$BENCH" macrosum --spec "$WORK/macros.json"
  if [ -s "$WORK/vm/vm.txt" ]; then
    echo
    echo "switching level of the bitline inverter (section:temperature:supply; a one bit needs its bitline above it):"
    sed 's/^/ /' "$WORK/vm/vm.txt"
  fi
  for r in $SPLITS; do
    dirs=""; labs=""
    for n in $(opt_names "$r"); do
      [ -f "$WORK/$n/screen/result.json" ] && { dirs="$dirs $WORK/$n/screen"; labs="$labs $n"; }
    done
    echo
    echo "==== option r$r: screening (precharge $((SCREEN_WAIT + PERIOD / 2)) ns before each target read; tt, 25 C, 1.8 V) ===="
    if [ -n "$dirs" ]; then
      python3 "$BENCH" margins --dirs $dirs --labels $labs --n "$NWORST" --per-row \
        | grep -vE "^(WORST_RUN|WORST_WORDS|TARGET_READS|LOWEST_ONE_CELL_V) "
    else
      echo "   no screening results yet"
    fi
    [ -f "$WORK/r$r/corners_skipped" ] && echo "   corner runs of r$r: $(cat "$WORK/r$r/corners_skipped")"
    for R in $(opt_runs "$r"); do
      [ -f "$R/result.json" ] || continue
      echo
      python3 "$BENCH" rowmap --dirs "$R" --interval "$INTERVAL" \
        --title "option r$r, ${R##*/} ($(cat "$R/macro" 2>/dev/null), $(cat "$R/corner" 2>/dev/null))"
    done
  done
}

if [ "$MODE" = "status" ]; then
  echo "=============================================================="
  echo "P2R-E8.4a-5 status, $(stamp)   ($MACRO)"
  echo "=============================================================="
  progress
  for n in $(all_names); do
    [ -f "$WORK/$n/lvs/started" ] && lvs_report "$n"
    [ -f "$WORK/$n/screen/tb_meta.json" ] && report "$WORK/$n/screen" "$n screen"
  done
  for r in $SPLITS; do
    for R in $(opt_runs "$r"); do [ -f "$R/tb_meta.json" ] && report "$R" "r$r ${R##*/}"; done
  done
  hr "summaries (as far as available)"
  summaries
  exit 0
fi

if [ "$MODE" = "stop" ]; then
  echo "P2R-E8.4a-5 stop, $(stamp)   ($WORK)"
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
echo "P2R-E8.4a-5 shallow ROM macros, started $(stamp)"
echo "=============================================================="
echo "macro    : $MACRO  (word bytes $WB)   rows per macro: $SPLITS   words per row: $WPR"
echo "screening: the $SCREEN_ROWS deepest rows, $((SCREEN_WAIT + PERIOD / 2)) ns of precharge; then $NWORST words per option"
echo "sweep    : waits $SWEEP_WAITS ns (tt, 25 C, 1.8 V)   corners: $CORNERS (waits $CORNER_WAITS ns)"
echo "OpenRAM  : $OPENRAM  $(cat "$OPENRAM/VERSION" 2>/dev/null)  $(git -C "$OPENRAM" log -1 --format='%h %ad' --date=short 2>/dev/null)"
echo "ngspice  : ${NGSPICE:-<missing>}"
echo "magic    : ${MAGIC:-<missing>}"
echo "netgen   : ${NETGEN:-<missing>}"
echo "models   : $MODELS"
echo "period   : $PERIOD ns   at most $MAXJOBS magic or ngspice jobs at a time (ngspice threads: $NTHREADS)   time limit: $([ "$TIMEOUT" -gt 0 ] && echo "$TIMEOUT s" || echo none)"
echo "machine  : $NCORES cores, $(free -g | awk '/Mem:/{print $2" GiB memory, "$7" GiB available"}')"
for F in "$SP0" "$GDS0" "$LEF0" "$BIN" "$BENCH" "$MODELS" "$MAGICRC" "$NETGEN_SETUP" \
         "$OPENRAM/rom_compiler.py" "$OPENRAM/setpaths.sh"; do
  [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
[ -n "$NGSPICE" ] && [ -n "$MAGIC" ] && [ -n "$NETGEN" ] || { echo "ERROR: ngspice, magic or netgen not found" >&2; exit 1; }
grep -q "def cmd_margins" "$BENCH" || { echo "ERROR: $BENCH is an older version; copy the one of 2026-10-11 (4)" >&2; exit 1; }
"$NGSPICE" -v < /dev/null 2>&1 | grep -m1 -i "ngspice-" | sed 's/^/   /'
for c in $CORNERS; do
  IFS=: read -r sec tmp vdd <<< "$c"
  grep -qE "^\.lib[[:space:]]+$sec([[:space:]]|$)" "$MODELS" || { echo "ERROR: the model library has no section '$sec' (E8_CORNERS)" >&2; exit 1; }
done

hr "a. the Python that runs OpenRAM"
PROBE='import numpy, scipy, sklearn.linear_model, sklearn.neural_network, sys; print("PROBE OK", sys.executable, sys.version.split()[0], numpy.__version__, scipy.__version__)'
try_py() {
  local out
  out=$(cd "$OPENRAM" && source ./setpaths.sh >/dev/null 2>&1 && timeout 600 "$1" -c "$PROBE" 2>&1 | grep "^PROBE OK")
  [ -n "$out" ] && { echo "   ${out#PROBE OK }"; return 0; }
  echo "   $1: does not import numpy, scipy and scikit-learn"
  return 1
}
PY=""
CANDS=()
[ -n "${E8_OPENRAM_PY:-}" ] && CANDS+=("$E8_OPENRAM_PY")
CANDS+=("$HOME/openram-venv/bin/python3" "$OPENRAM/compiler/.venv/bin/python3")
for p in "${CANDS[@]}"; do
  [ -x "$p" ] || continue
  try_py "$p" && { PY="$p"; break; }
done
if [ -z "$PY" ]; then
  mapfile -t OTHERS < <( {
      timeout 120 find "$HOME" -maxdepth 7 \
        \( -name .cache -o -name node_modules -o -name .git -o -name site-packages \) -prune \
        -o -path '*/bin/python3' \( -type f -o -type l \) -print 2>/dev/null
      command -v python3
    } | sort -u | head -20 )
  for p in "${OTHERS[@]}"; do
    try_py "$p" && { PY="$p"; break; }
  done
fi
[ -n "$PY" ] || { echo "ERROR: no Python imports numpy, scipy and scikit-learn (see E8.3, E8_INSTALL)" >&2; exit 1; }
echo "   using $PY"

# a rerun replaces this script's own previous output for this macro, nothing else
rm -rf "${WORK:?}"
mkdir -p "$WORK"/{configs,macros,logs,area,bins,drive} || exit 1

spiceinit() {
  cat > "$1/.spiceinit" <<EOF
* ngspice settings recommended for the sky130 models
set ngbehavior=hsa
set ng_nomodcheck
set skywaterpdk
set num_threads=$NTHREADS
EOF
}

hr "a. model sections: drive current of a 1 um / 0.15 um transistor at 25 C, 1.8 V (Vgs = Vds = 1.8 V)"
spiceinit "$WORK/drive"
drive() {   # drive SECTION: prints "NMOS_A PMOS_A"
  local f="$WORK/drive/$1.sp"
  cat > "$f" <<EOF
* P2R-E8.4a-5 drive check of model section $1
.lib "$MODELS" $1
.temp 25
Vd d 0 1.8
Vg g 0 1.8
Xn d g 0 0 sky130_fd_pr__nfet_01v8 w=1 l=0.15
Vdp dp 0 0
Vgp gp 0 0
Vs s 0 1.8
Xp dp gp s s sky130_fd_pr__pfet_01v8 w=1 l=0.15
.control
op
print -i(vd) i(vdp)
quit
.endc
.end
EOF
  ( cd "$WORK/drive" && timeout 900 "$NGSPICE" -b "$1.sp" > "$1.log" 2>&1 )
  awk '/^-i\(vd\)/{n=$3} /^i\(vdp\)/{p=$3} END{if (n != "" && p != "") print n, p}' "$WORK/drive/$1.log"
}
declare -A DRV
SECS="tt $(for c in $CORNERS; do echo "${c%%:*}"; done | grep -vx tt | sort -u | tr '\n' ' ')"
for sec in $SECS; do
  DRV[$sec]="$(drive "$sec")"
  [ -n "${DRV[$sec]}" ] || { echo "   $sec: no result:"; tail -3 "$WORK/drive/$sec.log" | sed 's/^/      /'; }
done
if [ -z "${DRV[tt]}" ]; then
  echo "ERROR: the drive check of section tt failed (see $WORK/drive/tt.log)" >&2; exit 1
fi
for sec in $SECS; do
  [ -n "${DRV[$sec]}" ] || continue
  python3 - "$sec" ${DRV[$sec]} ${DRV[tt]} <<'PY'
import sys
s, n, p, n0, p0 = sys.argv[1], *map(float, sys.argv[2:])
dn, dp = 100 * (n / n0 - 1), 100 * (p / p0 - 1)
kind = lambda d: "fast" if d > 2 else ("slow" if d < -2 else "typical")
print(f"   {s:3s}  NMOS {n*1e6:7.1f} uA ({dn:+5.1f} %, {kind(dn)})   PMOS {p*1e6:7.1f} uA ({dp:+5.1f} %, {kind(dp)})")
PY
done
CORNERS_USED=""
for c in $CORNERS; do
  IFS=: read -r sec tmp vdd <<< "$c"
  [ -n "${DRV[$sec]:-}" ] || { echo "   corner $c dropped: its drive check failed"; continue; }
  CORNERS_USED="$CORNERS_USED $c"
  if [ "$sec" = fs ] || [ "$sec" = sf ]; then
    python3 - ${DRV[$sec]} ${DRV[tt]} "$sec" <<'PY'
import sys
n, p, n0, p0 = map(float, sys.argv[1:5])
s = sys.argv[5]
if not (n < n0 and p > p0):
    print(f"   NOTE: section {s} is not 'slow NMOS, fast PMOS' in this library (see the table); "
          "the corner runs use it as given")
PY
  fi
done
CORNERS="${CORNERS_USED# }"
echo "   corners used: ${CORNERS:-none}"

hr "b. cut the table, generate the macros ($MAXGEN at a time), stored bits, layout extent"
for r in $SPLITS; do
  if ! python3 "$BENCH" split --bin "$BIN" --word-bytes "$WB" --words-per-row "$WPR" --rows "$r" \
       --out-prefix "$WORK/bins/${MACRO}_r${r}k" > "$WORK/logs/split_r$r.txt" 2>&1; then
    echo "   r$r: cannot cut the table:"; sed 's/^/      /' "$WORK/logs/split_r$r.txt"; continue
  fi
  echo "   r$r:"; grep -v '^{' "$WORK/logs/split_r$r.txt" | sed "s#$WORK/##; s/^/   /"
  ls "$WORK/bins/${MACRO}_r${r}k"*.bin 2>/dev/null | sort -V | while read -r f; do basename "$f" .bin; done > "$WORK/bins/r$r.names"
done
write_cfg() {   # write_cfg NAME
  local n=$1
  {
    echo "# P2R-E8.4a-5 ROM configuration for $n (generated by $SELF)."
    echo "# As E8.3 (scripts/e8_3_rom_tools.py), plus words_per_row."
    echo 'tech_name = "sky130"'
    echo "nominal_corner_only = True"
    echo 'route_supplies = "ring"'
    echo "check_lvsdrc = False"
    echo "word_size = $WB"
    echo "rom_data = \"$WORK/bins/$n.bin\""
    echo 'data_type = "bin"'
    echo "output_name = \"$n\""
    echo "output_path = \"$WORK/macros/$n/\""
    echo "words_per_row = $WPR"
    [ -n "${E8_USE_NIX:-}" ] && echo "use_nix = $E8_USE_NIX"
  } > "$WORK/configs/$n.py"
}
gen() {   # gen NAME
  local n=$1 s rc
  s=$(date +%s)
  (
    cd "$OPENRAM" && source ./setpaths.sh >/dev/null 2>&1 || exit 99
    [ -n "${E8_OPENRAM_PDK:-}" ] && export PDK_ROOT="$E8_OPENRAM_PDK"
    "$PY" -u rom_compiler.py -v "$WORK/configs/$n.py"
  ) > "$WORK/logs/gen_$n.log" 2>&1
  rc=$?
  echo "   $n: exit $rc, $(( $(date +%s) - s )) s; $(grep -h 'Read rom data file' "$WORK/logs/gen_$n.log" | sed 's/.*Read rom data file: //')"
}
NAMES="$(all_names | tr '\n' ' ')"
[ -n "${NAMES// /}" ] || { echo "ERROR: no macro to generate" >&2; exit 1; }
nrun=0
for n in $NAMES; do
  write_cfg "$n"
  if [ "$nrun" -ge "$MAXGEN" ]; then wait -n; nrun=$((nrun - 1)); fi
  gen "$n" &
  nrun=$((nrun + 1))
done
wait
GOOD=""
for n in $NAMES; do
  ok=1
  for ext in sp gds lef; do
    [ -f "$WORK/macros/$n/$n.$ext" ] || { echo "   MISSING $n.$ext; the log ends with:"; tail -5 "$WORK/logs/gen_$n.log" | sed 's/^/      /'; ok=0; }
  done
  [ "$ok" = 1 ] && GOOD="$GOOD $n"
done
echo "   stored bits:"
for n in $GOOD; do
  python3 "$BENCH" bitcheck --sp "$WORK/macros/$n/$n.sp" --top "$n" --bin "$WORK/bins/$n.bin" \
      --word-bytes "$WB" --words-per-row "$WPR" > "$WORK/logs/bitcheck_$n.txt" 2>&1
  sed 's/^/      /' "$WORK/logs/bitcheck_$n.txt"
done
echo "   drawn layout extent (magic) and LEF (um):"
box() {   # box NAME GDS
  printf 'gds read %s\nload %s\nselect top cell\nbox\nquit -noprompt\n' "$2" "$1" > "$WORK/area/$1.box.tcl"
  PDK_ROOT="$PDK_ROOT_DIR" timeout 1800 "$MAGIC" -dnull -noconsole -rcfile "$MAGICRC" \
      < "$WORK/area/$1.box.tcl" > "$WORK/area/$1.box.log" 2>&1
  printf "      %-36s layout %-20s LEF %s\n" "$1" "$(grep -m1 '^microns:' "$WORK/area/$1.box.log" | awk '{print $2" x "$4}')" \
      "$(grep -m1 -E '^\s*SIZE' "$(dirname "$2")/$1.lef" 2>/dev/null | awk '{print $2" x "$4}')"
}
box "$MACRO" "$GDS0"
for n in $GOOD; do box "$n" "$WORK/macros/$n/$n.gds"; done

hr "b. switching level of the bitline inverter (DC, the input where the output equals it)"
# a one bit reads correctly only while its bitline stays above this level
mkdir -p "$WORK/vm"
spiceinit "$WORK/vm"
n1=$(echo $GOOD | awk '{print $1}')
INV=""
[ -n "$n1" ] && INV=$(python3 "$BENCH" invsize --sp "$WORK/macros/$n1/$n1.sp" --top "$n1" 2>&1)
echo "$INV" | sed "s/^/   $n1: /"
PW="" PL="" NW="" NL=""
read -r _ PW PL _ NW NL <<< "$(echo "$INV" | grep '^pfet ')"
: > "$WORK/vm/vm.txt"
if [ -n "$PW" ] && [ -n "$NL" ]; then
  for c in "tt:25:1.80" $CORNERS; do
    IFS=: read -r sec tmp vdd <<< "$c"
    tag=$(corner_tag "$c")
    {
      echo "* P2R-E8.4a-5 switching level of the bitline inverter at $c"
      echo ".lib \"$MODELS\" $sec"
      echo ".temp $tmp"
      echo "Vdd vdd 0 $vdd"
      echo "Vin a 0 0"
      echo "Xp z a vdd vdd sky130_fd_pr__pfet_01v8 w=$PW l=$PL"
      echo "Xn z a 0 0 sky130_fd_pr__nfet_01v8 w=$NW l=$NL"
      echo ".control"
      echo "dc Vin 0 $vdd 0.001"
      echo "let d = v(z) - v(a)"
      echo "meas dc vm when d=0"
      echo "quit"
      echo ".endc"
      echo ".end"
    } > "$WORK/vm/$tag.sp"
    ( cd "$WORK/vm" && timeout 900 "$NGSPICE" -b "$tag.sp" > "$tag.log" 2>&1 )
    VM=$(awk '$1 == "vm" {print $3}' "$WORK/vm/$tag.log")
    if [ -n "$VM" ]; then
      printf "   %-14s %.3f V\n" "$c" "$VM" | tee -a "$WORK/vm/vm.txt"
    else
      echo "   $c: not measured (see $WORK/vm/$tag.log)" | tee -a "$WORK/vm/vm.txt"
    fi
  done
else
  echo "   inverter sizes not found: switching levels not measured"
fi

hr "c-e. extraction, LVS and simulations (at most $MAXJOBS magic or ngspice jobs at a time; progress every $HEARTBEAT s)"
launch() {   # launch DIR: start ngspice on DIR/tb.sp in the background
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
extract() {   # extract NAME: flat extraction for LVS and with parasitic capacitance (as E8.4a-2), in the background
  local n=$1 X="$WORK/$1/extract"
  mkdir -p "$X"
  cat > "$X/extract.tcl" <<EOF
drc off
gds flatten true
gds ordering true
gds read $WORK/macros/$n/$n.gds
load $n
select top cell
expand
readspice $WORK/macros/$n/$n.sp
extract do local
extract all
ext2spice hierarchy off
ext2spice format ngspice
ext2spice renumber off
ext2spice scale off
ext2spice blackbox on
ext2spice subcircuit top on
ext2spice global off
ext2spice rthresh infinite
ext2spice cthresh infinite
ext2spice -o $X/$n.flat_lvs.spice
ext2spice cthresh 0
ext2spice -o $X/$n.flat_pex.spice
quit -noprompt
EOF
  date +%s > "$X/started"
  ( cd "$X" && PDK_ROOT="$PDK_ROOT_DIR" "$MAGIC" -dnull -noconsole -rcfile "$MAGICRC" < extract.tcl \
        > magic_extract.log 2>&1; echo $? > magic_exit; date +%s > finished ) &
  echo "   started the extraction of $n at $(stamp)"
}
EXTQ=()      # macros to extract, in order
SIMQ=()      # simulation directories, in order
running_ext() {
  local n=0 m
  for m in "${EXTQ[@]}"; do
    [ -f "$WORK/$m/extract/started" ] && [ ! -f "$WORK/$m/extract/finished" ] && n=$((n + 1))
  done
  echo $n
}
running_sims() {
  local n=0 d
  for d in "${SIMQ[@]}"; do
    [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null && n=$((n + 1))
  done
  echo $n
}
pump() {   # extractions first (at most MAXMAGIC), then simulations, while fewer than MAXJOBS run
  local m d
  for m in "${EXTQ[@]}"; do
    [ -f "$WORK/$m/extract/started" ] && continue
    [ "$(running_ext)" -lt "$MAXMAGIC" ] || break
    [ $(( $(running_ext) + $(running_sims) )) -lt "$MAXJOBS" ] || return
    extract "$m"
  done
  for d in "${SIMQ[@]}"; do
    [ -f "$d/pid" ] && continue
    [ $(( $(running_ext) + $(running_sims) )) -lt "$MAXJOBS" ] || return
    launch "$d"
  done
}
write_bench() {   # write_bench DIR NAME SEQ OPTIONS...: post-layout bench of macro NAME
  local D=$1 n=$2 SEQ=$3
  shift 3
  mkdir -p "$D"
  if python3 "$BENCH" bench --sp "$WORK/$n/extract/$n.flat_pex.spice" --top "$n" --bin "$WORK/bins/$n.bin" \
      --word-bytes "$WB" --words-per-row "$WPR" --out "$D" --models "$MODELS" --period "$PERIOD" --seq "$SEQ" \
      --sanitize --plain-nfet --probes full --bitlines all "$@" > "$D/bench.txt" 2>&1; then
    grep -E "note: probes|WARNING" "$D/bench.txt" | sed 's/^/      /'
    echo "$n" > "$D/macro"
    SIMQ+=("$D")
  else
    echo "      ERROR: bench not written:"; tail -3 "$D/bench.txt" | sed 's/^/      /'
  fi
}
post_extract() {   # post_extract NAME: checks, LVS, screening bench
  local n=$1 X="$WORK/$1/extract" NEG PROBE XE SEQ
  local LVSNET="$X/$n.flat_lvs.spice" PEXNET="$X/$n.flat_pex.spice"
  echo
  echo "   ---- $n: magic exit $(cat "$X/magic_exit"), $(( $(cat "$X/finished") - $(cat "$X/started") )) s ----"
  grep -iE "error|fatal|could not|not found|shorted" "$X/magic_extract.log" \
      | grep -v "boundary was redefined" | sort | uniq -c | sort -rn | head -8 | sed 's/^/   log: /'
  XE=$(grep -m1 -oE "Total of [0-9]+ errors" "$X/magic_extract.log" | grep -oE "[0-9]+")
  if [ -n "$XE" ]; then
    echo "   extraction errors: $XE  -> the layout is FAULTY (must be 0, even if LVS matches)"
  else
    echo "   extraction errors: 0"
  fi
  [ -f "$X/$n.ext" ] && python3 "$BENCH" shorts --ext "$X/$n.ext" | grep -v '^{' | sed 's/^/   /'
  [ -s "$LVSNET" ] && python3 "$BENCH" probe --sp "$LVSNET" --top "$n" 2>&1 | grep -E "^(devices|capacitors)" | sed 's/^/   LVS netlist: /'
  NEG=1
  if [ -s "$PEXNET" ]; then
    PROBE=$(python3 "$BENCH" probe --sp "$PEXNET" --top "$n" 2>&1)
    echo "$PROBE" | grep -E "^(devices|capacitors|negative)" | sed 's/^/   simulation netlist: /'
    NEG=$(echo "$PROBE" | grep '^{' | python3 -c "import json,sys; print(json.load(sys.stdin)['caps_negative'])" 2>/dev/null || echo 1)
  fi
  if [ -s "$LVSNET" ]; then
    mkdir -p "$WORK/$n/lvs"
    sed 's/sky130_fd_pr__special_nfet_01v8/sky130_fd_pr__nfet_01v8/g' "$LVSNET" > "$WORK/$n/lvs/layout.spice"
    date +%s > "$WORK/$n/lvs/started"
    ( cd "$WORK/$n/lvs" && "$NETGEN" -batch lvs "layout.spice $n" "$WORK/macros/$n/$n.sp $n" "$NETGEN_SETUP" \
          lvs_report.txt > netgen.log 2>&1; date +%s > finished ) &
    echo "   started LVS of $n at $(stamp)"
  fi
  if [ -s "$PEXNET" ] && [ "$NEG" = "0" ]; then
    SEQ=$(python3 "$BENCH" pick --bin "$WORK/bins/$n.bin" --word-bytes "$WB" --words-per-row "$WPR" --mode deep \
          --deep-rows "$SCREEN_ROWS" --waits "$SCREEN_WAIT" 2>"$WORK/$n/pick_screen.txt")
    if [ -n "$SEQ" ]; then
      echo "   screening: $(grep -E '^A = ' "$WORK/$n/pick_screen.txt" | cut -c1-200)..."
      write_bench "$WORK/$n/screen" "$n" "$SEQ" --corner tt --temp 25 --vdd 1.8
      echo "tt, 25 C, 1.8 V" > "$WORK/$n/screen/corner"
    else
      echo "   screening: no sequence:"; sed 's/^/      /' "$WORK/$n/pick_screen.txt"
    fi
  else
    echo "   post-layout simulation of $n NOT started: no netlist, or negative capacitors ($NEG)"
  fi
}
select_and_queue() {   # select_and_queue R: worst macro and words of option r<R>; queue its sweep and corners
  local r=$1 n dirs="" labs="" WRUN WWORDS WN SEQ c sec tmp vdd D NWRONG VLOW
  mkdir -p "$WORK/r$r"
  for n in $(opt_names "$r"); do
    [ -f "$WORK/$n/screen/tb_done" ] && { python3 "$BENCH" analyze --dir "$WORK/$n/screen" > "$WORK/$n/screen/analyze.txt" 2>&1; dirs="$dirs $WORK/$n/screen"; labs="$labs $n"; }
  done
  echo
  echo "   ---- option r$r: selection from the screenings at $(stamp) ----"
  if [ -z "$dirs" ]; then
    echo "   no finished screening: no sweep and no corner runs for r$r"
    return
  fi
  python3 "$BENCH" margins --dirs $dirs --labels $labs --n "$NWORST" --per-row > "$WORK/r$r/select.txt" 2>&1
  sed -n '/^all runs/,$p' "$WORK/r$r/select.txt" | grep -vE "^(WORST_RUN|WORST_WORDS|TARGET_READS|LOWEST_ONE_CELL_V) " \
    | sed 's/^/   /'
  WRUN=$(sed -n 's/^WORST_RUN //p' "$WORK/r$r/select.txt")
  WWORDS=$(sed -n 's/^WORST_WORDS //p' "$WORK/r$r/select.txt")
  NWRONG=$(sed -n 's/^TARGET_READS [0-9]* WRONG //p' "$WORK/r$r/select.txt")
  VLOW=$(sed -n 's/^LOWEST_ONE_CELL_V //p' "$WORK/r$r/select.txt")
  if [ -z "$WRUN" ] || [ -z "$WWORDS" ]; then
    echo "   no words selected (see $WORK/r$r/select.txt)"
    return
  fi
  WN=$(basename "$(dirname "$WRUN")")
  echo "   tt sweep on $WN, words $WWORDS"
  SEQ=$(python3 "$BENCH" pick --bin "$WORK/bins/$WN.bin" --word-bytes "$WB" --words-per-row "$WPR" --mode words \
        --addrs "$WWORDS" --waits "$SWEEP_WAITS" 2>/dev/null)
  D="$WORK/r$r/sweep_tt"
  write_bench "$D" "$WN" "$SEQ" --corner tt --temp 25 --vdd 1.8
  echo "tt, 25 C, 1.8 V" > "$D/corner"
  # the corners only for an option that reads correctly at tt with some margin
  if [ "${NWRONG:-1}" != 0 ] || ! python3 -c "import sys; sys.exit(0 if float('${VLOW:-0}') >= float('$CORNER_MIN_V') else 1)"; then
    echo "   corners NOT run for r$r: at tt, $NWRONG target read(s) wrong, lowest one-cell bitline ${VLOW:-?} V"
    echo "   (the corners run only if every target read is correct and the lowest one-cell bitline is at least $CORNER_MIN_V V)"
    echo "skipped: $NWRONG wrong, lowest ${VLOW:-?} V" > "$WORK/r$r/corners_skipped"
    return
  fi
  echo "   corners on $WN, words $WWORDS: $CORNERS"
  for c in $CORNERS; do
    IFS=: read -r sec tmp vdd <<< "$c"
    SEQ=$(python3 "$BENCH" pick --bin "$WORK/bins/$WN.bin" --word-bytes "$WB" --words-per-row "$WPR" --mode words \
          --addrs "$WWORDS" --waits "$CORNER_WAITS" 2>/dev/null)
    D="$WORK/r$r/corner_$(corner_tag "$c")"
    write_bench "$D" "$WN" "$SEQ" --corner "$sec" --temp "$tmp" --vdd "$vdd"
    echo "$sec, $tmp C, $vdd V" > "$D/corner"
  done
}

for n in $GOOD; do EXTQ+=("$n"); done
echo "   $(echo $GOOD | wc -w) extractions (at most $MAXMAGIC at a time), then $(echo $GOOD | wc -w) screenings, $(echo $SPLITS | wc -w) tt sweeps"
echo "   and up to $(( $(echo $SPLITS | wc -w) * $(echo $CORNERS | wc -w) )) corner runs; at most $MAXJOBS jobs at a time"
pump
progress
last=$(date +%s)
declare -A SELECTED
while :; do
  for n in "${EXTQ[@]}"; do
    X="$WORK/$n/extract"
    if [ -f "$X/finished" ] && [ ! -f "$X/post_done" ]; then
      touch "$X/post_done"
      post_extract "$n"
    fi
  done
  for r in $SPLITS; do
    [ -n "${SELECTED[$r]:-}" ] && continue
    pending=0
    for n in $(opt_names "$r"); do
      case " $GOOD " in *" $n "*) ;; *) continue ;; esac
      X="$WORK/$n/extract"
      [ -f "$X/post_done" ] || { pending=1; continue; }
      D="$WORK/$n/screen"
      [ -f "$D/tb.sp" ] || continue                       # no screening for this macro
      if [ ! -f "$D/pid" ] || kill -0 "$(cat "$D/pid")" 2>/dev/null; then pending=1; fi
    done
    if [ "$pending" = 0 ]; then
      SELECTED[$r]=1
      select_and_queue "$r"
    fi
  done
  pump
  busy=0
  for n in "${EXTQ[@]}"; do
    X="$WORK/$n/extract"
    [ -f "$X/post_done" ] || busy=1
    [ -f "$WORK/$n/lvs/started" ] && [ ! -f "$WORK/$n/lvs/finished" ] && busy=1
  done
  for d in "${SIMQ[@]}"; do
    if [ ! -f "$d/pid" ] || kill -0 "$(cat "$d/pid")" 2>/dev/null; then busy=1; fi
  done
  for r in $SPLITS; do [ -n "${SELECTED[$r]:-}" ] || busy=1; done
  [ "$busy" -eq 0 ] && break
  sleep 30
  if [ $(( $(date +%s) - last )) -ge "$HEARTBEAT" ]; then
    progress
    last=$(date +%s)
  fi
done
wait 2>/dev/null
progress

hr "f. results"
for n in $(all_names); do
  [ -f "$WORK/$n/lvs/started" ] && lvs_report "$n"
  [ -f "$WORK/$n/screen/tb_meta.json" ] && report "$WORK/$n/screen" "$n screen"
done
for r in $SPLITS; do
  for R in $(opt_runs "$r"); do [ -f "$R/tb_meta.json" ] && report "$R" "r$r ${R##*/} ($(cat "$R/macro" 2>/dev/null), $(cat "$R/corner" 2>/dev/null))"; done
done
hr "g. summaries"
summaries

echo
echo "---- files: $WORK ----"
du -sh "$WORK" 2>/dev/null | sed 's/^/   /'
echo
echo "=============================================================="
echo "Finished $(stamp)."
echo "=============================================================="
