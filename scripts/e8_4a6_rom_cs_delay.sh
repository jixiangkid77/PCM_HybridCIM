#!/usr/bin/env bash
# =============================================================================
# e8_4a6_rom_cs_delay.sh   [run | status | stop]
#
# Experiment : P2R-E8.4a-6. ROM reads with the array evaluated only after the
#              row is selected: the chip select (CS) of a read rises
#              E8_CS_DELAY ns after the clock edge instead of before it. Uses
#              the macros generated and extracted in E8.4a-5 as they are (no
#              generation, no extraction, no change of any layout).
#
# Why (sandbox analysis, 2026-10-12)
#   - In OpenRAM's ROM (e16d9eb) the precharge signal of the array is
#     CS AND clock (control NAND, then 7 inverters). The same signal turns the
#     precharge PMOS off and the footer transistor at the bottom of every
#     column on. The selected wordline goes low only after the row decoder
#     (itself a dynamic NMOS-chain circuit) and the wordline buffer. At tt the
#     footers turn on 0.09-0.26 ns (32-row macro) and 0.25-0.47 ns (64-row
#     macro) BEFORE the selected wordline turns off; at fs -40 C 1.60 V
#     0.70-0.73 ns (32-row macro, synthetic data). In that window every row of
#     every column is on: each column conducts to ground, the one-cell
#     bitlines lose charge, and the large node of zero cells right above the
#     read cell is pulled down and then shares charge with the bitline.
#     This, not a short precharge, is why E8.4a-5's one bits read as 0 and why
#     a longer precharge did not help.
#   - Sandbox what-if (array precharge/footer signal delayed 2 ns, netlist
#     edit, tt): E8.4a-5's screening of the real r32k0 and r64k0 read all 32 +
#     32 reads correctly (before: 1 and 9 wrong); lowest one-cell bitline
#     1.376 / 1.125 V (before 0.800 / 0.624 V; switching level 0.876 V).
#   - The same order without any change of the macro: raise CS after the
#     clock edge. The row decoder selects the row while the array is still
#     precharged (footers off); the array evaluates when CS rises. CS falls
#     with the clock (this script's bench), so the footers turn off at the end
#     of the read as before. Sandbox, E8.4a-5's screening of r32k0, tt, CS
#     10 ns after the clock: 32 of 32 reads correct, lowest one-cell bitline
#     1.406 V (as generated 0.800 V); r64k0 at ss -40 C 1.60 V: correct.
#   - A second, separate weakness (sandbox): at fs -40 C 1.60 V (slow NMOS,
#     fast PMOS, cold, low supply) the column multiplexer (one 2.88 um NMOS
#     per column) passes the bitline inverter's high level only to about the
#     switching level of the output inverter, so a zero bit reaches dout
#     slowly. As generated those reads took about 48 ns of the 50 ns (a
#     synthetic 32-row macro); with CS 10 ns late, 15 of 16 reads of r64k0
#     were wrong although every bitline was correct (margin +0.33 V). The
#     summaries list the bitline margins and the read results separately, so
#     such a case shows which part fails.
#
# Steps
#   a. tools and files; the E8.4a-5 macros (their extracted netlists, data,
#      LVS result, extraction errors, md5 of each netlist); model sections
#      (drive current of a 1 um / 0.15 um NMOS and PMOS against tt)
#   b. switching level of the bitline inverter (DC) at tt and every condition
#   c. E8.4a-5's screenings analysed again (read only; results written here):
#      for every read, when the footers turned on and when the selected
#      wordline went low after the clock edge
#   d. simulations (post-layout, every bitline saved), at most E8_MAXJOBS at
#      a time:
#        tt_cs       every macro: E8.4a-5's screening sequence exactly (the
#                    16 deepest rows, each after a read of row 0 and 90 ns of
#                    precharge), CS E8_CS_DELAY ns after the clock; tt, 25 C,
#                    1.80 V; compared read by read with E8.4a-5
#        full_orig   E8.3's macro (192 rows; E8.4a-2's extraction): rows
#        full_cs     64, 96, 128, 160 and 191 (E8_FULL_ADDRS, E8.4a-4's
#                    words), each after a read of row 0 and 90 ns of
#                    precharge; CS as before (orig) and delayed (cs); tt. Tells
#                    whether the macros still need to be split
#      when all tt_cs runs of an option are finished: its macro with the
#      lowest one-cell bitline (or a wrong read), and in it the
#      E8_CORNER_ROWS rows (default 8) with the lowest one-cell bitline, each
#      with its worst word:
#        corner_*    those words at every E8_CORNERS condition, CS delayed
#        sweep_*     its E8_NSWEEP (2) worst words with CS delays E8_SWEEP_CSD
#                    (ns; 0 = CS with the clock edge, about as generated), at
#                    tt and at each E8_SWEEP_CORNERS condition: the smallest delay that reads
#                    correctly (needed if the delay were built into the macro)
#   e. results per macro, per option and per condition; the margin above the
#      switching level at each condition
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\  with e8_4_rom_bench.py of
#           2026-10-12 (5), which replaces the earlier ones (the earlier
#           commands are unchanged)
# Needs   : the output of E8.4a-5 (reports\e8_rom\e8_4a5\<macro>\) and of
#           E8.4a-2 (reports\e8_rom\e8_4a2\<macro>\extract\), only read
# Writes  : only reports\e8_rom\e8_4a6\<macro>\ (a rerun replaces it; it refuses
#           to start while an earlier run still works there)
# Run     : cd /mnt/d/Project/hybrid_memory/paper2
#           bash scripts/e8_4a6_rom_cs_delay.sh 2>&1 | tee reports/e8_4a6_rom_cs_delay.log
#           Keep the terminal open and the computer awake.
# Status  : bash scripts/e8_4a6_rom_cs_delay.sh status 2>&1 | tee reports/e8_4a6_status.log
# Stop    : bash scripts/e8_4a6_rom_cs_delay.sh stop
#           (Ctrl+C alone ends only the script: the jobs it started keep running)
# Options : E8_CS_DELAY (10), E8_SPLITS ("64 48 32"), E8_CORNERS (below),
#           E8_CORNER_ROWS (8), E8_SWEEP_CSD ("0,0.5,1,2,10"),
#           E8_SWEEP_CORNERS ("fs:25:1.80 fs:-40:1.60"), E8_NSWEEP (2), E8_SCREEN_WAIT (40),
#           E8_FULL (1 = run the E8.3 macro), E8_FULL_ADDRS, E8_MARGIN (0.10 V,
#           only for the summary), E8_MAXJOBS (cores - 1), E8_PERIOD (100),
#           E8_MACRO, E8_TIMEOUT (0 = none).
#           E8_CORNERS default: tt:25:1.60 fs:25:1.80 sf:25:1.80 ss:25:1.80
#           fs:-40:1.60 ss:-40:1.60 ss:100:1.60 ff:-40:1.95 ff:100:1.95
#           (section : temperature in C : supply in V)
# Runtime : estimated from E8.4a-5 on this machine and the sandbox: tt_cs
#           20-35 min per macro, the E8.3 macro 45-90 min per run, corner runs
#           20-60 min (cold corners are slower), sweep runs 5-15 min. In all
#           about 4 hours. Memory: under 1 GB per simulation. Disk: about 2 GB.
# =============================================================================
set -uo pipefail

MODE="${1:-run}"
PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
MACRO="${E8_MACRO:-e8rom_A_pcm_l00_16x2496}"
SPLITS="${E8_SPLITS:-64 48 32}"
CSD="${E8_CS_DELAY:-10}"
CORNERS="${E8_CORNERS:-tt:25:1.60 fs:25:1.80 sf:25:1.80 ss:25:1.80 fs:-40:1.60 ss:-40:1.60 ss:100:1.60 ff:-40:1.95 ff:100:1.95}"
CORNER_ROWS="${E8_CORNER_ROWS:-8}"
SWEEP_CSD="${E8_SWEEP_CSD:-0,0.5,1,2,10}"
SWEEP_CORNERS="${E8_SWEEP_CORNERS:-fs:25:1.80 fs:-40:1.60}"
NSWEEP="${E8_NSWEEP:-2}"
SCREEN_WAIT="${E8_SCREEN_WAIT:-40}"
FULL="${E8_FULL:-1}"
FULL_ADDRS="${E8_FULL_ADDRS:-1033,1542,2053,2564,3056}"
MARGIN="${E8_MARGIN:-0.10}"
PERIOD="${E8_PERIOD:-100}"
TIMEOUT="${E8_TIMEOUT:-0}"
HEARTBEAT="${E8_HEARTBEAT:-1800}"
ROOT="$PAPER2/reports/e8_rom"
BIN0="$ROOT/bins/$MACRO.bin"
SP0="$ROOT/macros/$MACRO/$MACRO.sp"
PEX0="$ROOT/e8_4a2/$MACRO/extract/$MACRO.flat_pex.spice"
LVS0="$ROOT/e8_4a2/$MACRO/lvs/netgen.log"
BENCH="$PAPER2/scripts/e8_4_rom_bench.py"
MODELS="$PDK_ROOT_DIR/sky130A/libs.tech/ngspice/sky130.lib.spice"
W5="$ROOT/e8_4a5/$MACRO"
WORK="$ROOT/e8_4a6/$MACRO"
WB=2
case "$MACRO" in *_8x*) WB=1 ;; esac
WPR=13
SELF="e8_4a6_rom_cs_delay.sh"

pick_path() { ls -d $1 2>/dev/null | sort -V | tail -1; }
NGSPICE="${E8_NGSPICE:-$(pick_path "/nix/store/*-ngspice-*/bin/ngspice")}"
NCORES=$(nproc 2>/dev/null || echo 4)
MAXJOBS="${E8_MAXJOBS:-$(( NCORES > 2 ? NCORES - 1 : 1 ))}"
NTHREADS=1          # sandbox, 2026-10-11: a second thread made a 32-row macro only 1.18 times faster

isnum() { python3 -c "import sys; float(sys.argv[1])" "$1" 2>/dev/null; }
for r in $SPLITS; do
  case "$r" in ''|*[!0-9]*) echo "ERROR: E8_SPLITS must list numbers of rows per macro (got '$r')" >&2; exit 1 ;; esac
done
for c in $CORNERS $SWEEP_CORNERS; do
  case "$c" in *:*:*) ;; *) echo "ERROR: conditions are section:temperature:supply (got '$c')" >&2; exit 1 ;; esac
done
isnum "$CSD" || { echo "ERROR: E8_CS_DELAY must be a number of ns" >&2; exit 1; }
for d in ${SWEEP_CSD//,/ }; do isnum "$d" || { echo "ERROR: E8_SWEEP_CSD must list numbers (got '$d')" >&2; exit 1; }; done
case "$CORNER_ROWS$NSWEEP$SCREEN_WAIT" in *[!0-9]*) echo "ERROR: E8_CORNER_ROWS, E8_NSWEEP, E8_SCREEN_WAIT must be integers" >&2; exit 1 ;; esac

# ---- processes of a run of this script (for the guard and the stop mode) ----
args01() {   # the first two words of the command line of process $1 (base names), as "a0 a1"
  local a0="" a1=""
  { IFS= read -r -d '' a0; IFS= read -r -d '' a1; } 2>/dev/null < "/proc/$1/cmdline"
  echo "${a0##*/} ${a1##*/}"
}
is_tool() {   # process $1 is ngspice (or a shell running it), or this script
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
procs_in_work() {   # this script's tools working in $WORK (a shell or viewer opened there is left alone)
  local p c
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    c=$(readlink "/proc/$p/cwd" 2>/dev/null) || continue
    case "$c" in
      "$WORK"|"$WORK"/*) is_tool "$p" && ! is_mine "$p" && echo "$p" ;;
    esac
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
corner_tag() { local s t v; IFS=: read -r s t v <<< "$1"; echo "${s}_${t/-/m}C_${v/./v}"; }
csd_tag() { echo "cs${1/./p}"; }
by_csd() {   # by_csd DIR...: the directories sorted by the CS delay in their name (..._cs<delay>, "p" = point)
  local d t
  for d in "$@"; do t=${d##*_cs}; echo "${t/p/.} $d"; done | sort -g | cut -d' ' -f2
}
opt_names() { cat "$W5/bins/r$1.names" 2>/dev/null; }      # the macros of option r<R> (E8.4a-5)
all_names() { local r; for r in $SPLITS; do opt_names "$r"; done; }
opt_runs() {   # corner and sweep runs of option r<R> that exist
  local d
  for d in "$WORK/r$1"/corner_* "$WORK/r$1"/sweep_*; do [ -f "$d/tb_meta.json" ] && echo "$d"; done
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
all_runs() {   # every run directory of this script, in a fixed order
  local n r d
  for n in $(all_names); do [ -f "$WORK/$n/tt_cs/tb_meta.json" ] && echo "$WORK/$n/tt_cs"; done
  for d in "$WORK/full/tt_orig" "$WORK/full/tt_cs"; do [ -f "$d/tb_meta.json" ] && echo "$d"; done
  for r in $SPLITS; do opt_runs "$r"; done
}
progress() {
  local d
  echo "   progress at $(stamp):"
  for d in $(all_runs); do
    printf "      %-52s %-36s %-6s %s\n" "${d#$WORK/}" "$(state "$d")" "$(elapsed "$d")" "$(reached "$d")"
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
vm_of() {   # vm_of SECTION:TEMP:VDD -> the switching level measured in step b (empty if none)
  awk -v c="$1" '$1 == c {print $2}' "$WORK/vm/vm.txt" 2>/dev/null | head -1
}
cond_of() {   # the condition (section:temp:vdd) of a run directory
  cat "$1/cond" 2>/dev/null
}
short() {   # short DIR: the run's path below $WORK without the macro name prefix
  local x=${1#$WORK/}
  echo "${x//${MACRO}_/}"
}
condsum_dirs() {   # condsum_dirs DIR...: one line per run, with the switching level of its condition
  local d vms="" labs="" dirs="" v
  for d in "$@"; do
    [ -f "$d/result.json" ] || continue
    v=$(vm_of "$(cond_of "$d")")
    vms="$vms ${v:-nan}"
    dirs="$dirs $d"
    labs="$labs $(short "$d")"
  done
  [ -n "$dirs" ] || { echo "   no finished run"; return; }
  python3 "$BENCH" condsum --dirs $dirs --labels $labs --vm $vms
}
summaries() {
  local r n d dirs WN f
  for r in $SPLITS; do
    echo
    echo "==== option r$r: E8.4a-5 (CS before the clock, as generated) and E8.4a-6 (CS $CSD ns after the clock), tt, 25 C, 1.80 V ===="
    dirs=""; labs=""
    for n in $(opt_names "$r"); do
      [ -f "$WORK/a5/$n.json" ] && { dirs="$dirs $WORK/a5/$n.json"; labs="$labs ${n#${MACRO}_}_E8.4a-5"; }
    done
    if [ -n "$dirs" ]; then
      echo "   E8.4a-5 screenings (analysed again):"
      python3 "$BENCH" condsum --dirs $dirs --labels $labs --vm $(for f in $dirs; do echo "$(vm_of tt:25:1.80)"; done)
    fi
    dirs=""
    for n in $(opt_names "$r"); do [ -f "$WORK/$n/tt_cs/result.json" ] && dirs="$dirs $WORK/$n/tt_cs"; done
    echo "   E8.4a-6, CS $CSD ns after the clock:"
    condsum_dirs $dirs
    WN=$(cat "$WORK/r$r/worst_macro" 2>/dev/null)
    if [ -n "$WN" ]; then
      echo
      echo "   option r$r, worst macro $WN, words $(cat "$WORK/r$r/corner_words" 2>/dev/null): conditions (CS $CSD ns after the clock)"
      condsum_dirs "$WORK/$WN/tt_cs" $(ls -d "$WORK/r$r"/corner_* 2>/dev/null)
      echo
      echo "   option r$r, CS delay sweep on $WN, words $(cat "$WORK/r$r/sweep_words" 2>/dev/null) (delay after the clock edge; 0 = with the edge):"
      condsum_dirs $(by_csd $(ls -d "$WORK/r$r"/sweep_tt_* 2>/dev/null))
      for c in $SWEEP_CORNERS; do
        condsum_dirs $(by_csd $(ls -d "$WORK/r$r"/sweep_c_"$(corner_tag "$c")"_* 2>/dev/null))
      done
    fi
  done
  if [ -f "$WORK/full/tt_orig/result.json" ] || [ -f "$WORK/full/tt_cs/result.json" ]; then
    echo
    echo "==== E8.3 macro (192 rows), rows of E8_FULL_ADDRS ($FULL_ADDRS), 90 ns of precharge, tt ===="
    condsum_dirs "$WORK/full/tt_orig" "$WORK/full/tt_cs"
    if [ -f "$WORK/full/tt_orig/result.json" ] && [ -f "$WORK/full/tt_cs/result.json" ]; then
      python3 "$BENCH" ab --a "$WORK/full/tt_orig/result.json" --b "$WORK/full/tt_cs/result.json" \
          --labels "CS before clock" "CS $CSD ns after"
    fi
  fi
  if [ -s "$WORK/vm/vm.txt" ]; then
    echo
    echo "switching level of the bitline inverter (a one bit needs its bitline above it):"
    sed 's/^/   /' "$WORK/vm/vm.txt"
  fi
  echo
  echo "a margin is the lowest one-cell bitline of the target reads minus the switching level at that condition;"
  echo "E8_MARGIN = $MARGIN V is the margin this summary asks for (to cover the difference between machines"
  echo "and what the screening does not test); it does not change what was run"
}

if [ "$MODE" = "status" ]; then
  echo "=============================================================="
  echo "P2R-E8.4a-6 status, $(stamp)   ($MACRO)"
  echo "=============================================================="
  progress
  for d in $(all_runs); do report "$d" "${d#$WORK/} ($(cond_of "$d"))"; done
  hr "summaries (as far as available)"
  summaries
  exit 0
fi

if [ "$MODE" = "stop" ]; then
  echo "P2R-E8.4a-6 stop, $(stamp)   ($WORK)"
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
echo "P2R-E8.4a-6 ROM reads with CS after the clock edge, started $(stamp)"
echo "=============================================================="
echo "macro    : $MACRO  (word bytes $WB)   options: r$(echo $SPLITS | sed 's/ / r/g') (E8.4a-5's macros, used as they are)"
echo "CS       : rises $CSD ns after the clock edge, falls with the clock (E8.4a-5: CS changed with the address, 25 ns before the edge)"
echo "corners  : $CORNERS   ($CORNER_ROWS worst rows of the worst macro per option)"
echo "sweep    : CS delays $SWEEP_CSD ns at tt:25:1.80 $SWEEP_CORNERS ($NSWEEP worst words)"
echo "E8.3     : $( [ "$FULL" = 1 ] && echo "rows of words $FULL_ADDRS, CS before and after the clock" || echo "not run (E8_FULL=$FULL)")"
echo "ngspice  : ${NGSPICE:-<missing>}"
echo "models   : $MODELS"
echo "period   : $PERIOD ns   at most $MAXJOBS ngspice jobs at a time (threads: $NTHREADS)   time limit: $([ "$TIMEOUT" -gt 0 ] && echo "$TIMEOUT s" || echo none)"
echo "machine  : $NCORES cores, $(free -g | awk '/Mem:/{print $2" GiB memory, "$7" GiB available"}')"

hr "a. tools, files and the E8.4a-5 macros"
for F in "$BENCH" "$MODELS"; do
  [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
[ -n "$NGSPICE" ] || { echo "ERROR: ngspice not found" >&2; exit 1; }
grep -q "def cmd_condsum" "$BENCH" && grep -q "cs_delay" "$BENCH" \
  || { echo "ERROR: $BENCH is an older version; copy the one of 2026-10-12 (5)" >&2; exit 1; }
echo "   bench : $(md5sum "$BENCH" | cut -c1-32)  $BENCH"
"$NGSPICE" -v < /dev/null 2>&1 | grep -m1 -i "ngspice-" | sed 's/^/   /'
for c in "tt:25:1.80" $CORNERS $SWEEP_CORNERS; do
  IFS=: read -r sec tmp vdd <<< "$c"
  grep -qE "^\.lib[[:space:]]+$sec([[:space:]]|$)" "$MODELS" || { echo "ERROR: the model library has no section '$sec'" >&2; exit 1; }
done
[ -d "$W5" ] || { echo "ERROR: no E8.4a-5 output in $W5" >&2; exit 1; }
GOOD=""
echo "   E8.4a-5 macros (LVS, extraction errors, netlist used here):"
for n in $(all_names); do
  X="$W5/$n/extract"
  PEX="$X/$n.flat_pex.spice"
  why=""
  [ -s "$PEX" ] || why="$why no extracted netlist;"
  [ -f "$W5/bins/$n.bin" ] || why="$why no data file;"
  [ -f "$W5/$n/screen/tb_meta.json" ] || why="$why no E8.4a-5 screening;"
  grep -q "match uniquely" "$W5/$n/lvs/netgen.log" 2>/dev/null || why="$why LVS not 'match uniquely';"
  XE=$(grep -m1 -oE "Total of [0-9]+ errors" "$X/magic_extract.log" 2>/dev/null | grep -oE "[0-9]+")
  [ -z "$XE" ] || [ "$XE" = 0 ] || why="$why $XE extraction errors;"
  if [ -z "$why" ]; then
    GOOD="$GOOD $n"
    printf "      %-36s ok   netlist md5 %s  data md5 %s\n" "$n" "$(md5sum "$PEX" | cut -c1-32)" \
      "$(md5sum "$W5/bins/$n.bin" | cut -c1-32)"
  else
    printf "      %-36s SKIPPED:%s\n" "$n" "$why"
  fi
done
[ -n "${GOOD// /}" ] || { echo "ERROR: no usable E8.4a-5 macro" >&2; exit 1; }
if [ "$FULL" = 1 ]; then
  why=""
  [ -s "$PEX0" ] || why="$why no extracted netlist ($PEX0);"
  [ -f "$BIN0" ] || why="$why no data file ($BIN0);"
  grep -q "match uniquely" "$LVS0" 2>/dev/null || why="$why LVS of E8.4a-2 not 'match uniquely';"
  if [ -z "$why" ]; then
    printf "      %-36s ok   netlist md5 %s  data md5 %s (E8.3 macro, E8.4a-2 extraction)\n" "$MACRO" \
      "$(md5sum "$PEX0" | cut -c1-32)" "$(md5sum "$BIN0" | cut -c1-32)"
  else
    echo "      $MACRO (E8.3 macro) SKIPPED:$why"
    FULL=0
  fi
fi

# a rerun replaces this script's own previous output for this macro, nothing else
rm -rf "${WORK:?}"
mkdir -p "$WORK"/{a5,vm,drive} || exit 1

spiceinit() {
  cat > "$1/.spiceinit" <<EOF
* ngspice settings recommended for the sky130 models
set ngbehavior=hsa
set ng_nomodcheck
set skywaterpdk
set num_threads=$NTHREADS
EOF
}

echo
echo "   model sections: drive current of a 1 um / 0.15 um transistor at 25 C, 1.8 V (Vgs = Vds = 1.8 V)"
spiceinit "$WORK/drive"
drive() {   # drive SECTION: prints "NMOS_A PMOS_A"
  local f="$WORK/drive/$1.sp"
  cat > "$f" <<EOF
* P2R-E8.4a-6 drive check of model section $1
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
SECS="tt $(for c in $CORNERS $SWEEP_CORNERS; do echo "${c%%:*}"; done | grep -vx tt | sort -u | tr '\n' ' ')"
for sec in $SECS; do
  DRV[$sec]="$(drive "$sec")"
  [ -n "${DRV[$sec]}" ] || { echo "   $sec: no result:"; tail -3 "$WORK/drive/$sec.log" | sed 's/^/      /'; }
done
[ -n "${DRV[tt]}" ] || { echo "ERROR: the drive check of section tt failed (see $WORK/drive/tt.log)" >&2; exit 1; }
for sec in $SECS; do
  [ -n "${DRV[$sec]}" ] || continue
  python3 - "$sec" ${DRV[$sec]} ${DRV[tt]} <<'PY'
import sys
s, n, p, n0, p0 = sys.argv[1], *map(float, sys.argv[2:])
dn, dp = 100 * (n / n0 - 1), 100 * (p / p0 - 1)
kind = lambda d: "fast" if d > 2 else ("slow" if d < -2 else "typical")
print(f"      {s:3s}  NMOS {n*1e6:7.1f} uA ({dn:+5.1f} %, {kind(dn)})   PMOS {p*1e6:7.1f} uA ({dp:+5.1f} %, {kind(dp)})")
PY
done
CORNERS_USED=""
for c in $CORNERS; do
  [ -n "${DRV[${c%%:*}]:-}" ] || { echo "   condition $c dropped: its drive check failed"; continue; }
  CORNERS_USED="$CORNERS_USED $c"
done
CORNERS="${CORNERS_USED# }"
SWC_USED=""
for c in $SWEEP_CORNERS; do
  [ -n "${DRV[${c%%:*}]:-}" ] || { echo "   sweep condition $c dropped: its drive check failed"; continue; }
  SWC_USED="$SWC_USED $c"
done
SWEEP_CORNERS="${SWC_USED# }"
echo "   conditions used: ${CORNERS:-none}; sweep conditions: tt:25:1.80 ${SWEEP_CORNERS}"

hr "b. switching level of the bitline inverter (DC, the input where the output equals it)"
spiceinit "$WORK/vm"
n1=$(echo $GOOD | awk '{print $1}')
INV=$(python3 "$BENCH" invsize --sp "$W5/macros/$n1/$n1.sp" --top "$n1" 2>&1)
echo "$INV" | sed "s/^/   $n1: /"
PW="" PL="" NW="" NL=""
read -r _ PW PL _ NW NL <<< "$(echo "$INV" | grep '^pfet ')"
: > "$WORK/vm/vm.txt"
if [ -n "$PW" ] && [ -n "$NL" ]; then
  for c in $(printf '%s\n' "tt:25:1.80" $CORNERS $SWEEP_CORNERS | awk '!seen[$0]++'); do
    IFS=: read -r sec tmp vdd <<< "$c"
    tag=$(corner_tag "$c")
    {
      echo "* P2R-E8.4a-6 switching level of the bitline inverter at $c"
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
      printf "%s %.3f\n" "$c" "$VM" >> "$WORK/vm/vm.txt"
      printf "   %-14s %.3f V\n" "$c" "$VM"
    else
      echo "   $c: not measured (see $WORK/vm/$tag.log)"
    fi
  done
else
  echo "   inverter sizes not found: switching levels not measured"
fi

hr "c. E8.4a-5's screenings analysed again (read only): footers and selected wordline after the clock edge"
for n in $GOOD; do
  python3 "$BENCH" analyze --dir "$W5/$n/screen" --json-out "$WORK/a5/$n.json" > "$WORK/a5/$n.txt" 2>&1
done
python3 - "$WORK/a5" $GOOD <<'PY'
import json, os, sys
d, names = sys.argv[1], sys.argv[2:]
print(f"   {'macro':<36} {'reads':>5} {'wrong':>5} | footers on before the row is selected (ns): {'min':>6} {'max':>6} | "
      f"{'lowest 1 V':>10}")
for n in names:
    p = os.path.join(d, n + ".json")
    if not os.path.isfile(p):
        print(f"   {n:<36} not analysed"); continue
    r = json.load(open(p))
    rd = [c for c in r["cycles"] if c.get("kind") == "read" and c.get("complete")]
    fw = [c["footer_to_wl_ns"] for c in rd if c.get("footer_to_wl_ns") is not None]
    b1 = [c["bl1_min_V"] for c in rd if c.get("bl1_min_V") is not None]
    w = sum(1 for c in rd if not c.get("ok"))
    print(f"   {n:<36} {len(rd):5d} {w:5d} | {'':>44} {min(fw) if fw else float('nan'):6.3f} "
          f"{max(fw) if fw else float('nan'):6.3f} | {min(b1) if b1 else float('nan'):10.3f}")
PY

hr "d. simulations (at most $MAXJOBS at a time; progress every $HEARTBEAT s)"
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
SIMQ=()
running_sims() {
  local n=0 d
  for d in "${SIMQ[@]}"; do
    [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null && n=$((n + 1))
  done
  echo $n
}
pump() {
  local d
  for d in "${SIMQ[@]}"; do
    [ -f "$d/pid" ] && continue
    [ "$(running_sims)" -lt "$MAXJOBS" ] || return
    launch "$d"
  done
}
sim_done() {   # the run in DIR has ended (or was never started because its bench failed)
  local d=$1
  [ -f "$d/tb.sp" ] || return 0
  [ -f "$d/pid" ] && ! kill -0 "$(cat "$d/pid")" 2>/dev/null
}
write_bench() {   # write_bench DIR NETLIST TOP BIN COND SEQ OPTIONS...: post-layout bench
  local D=$1 NET=$2 TOPN=$3 B=$4 COND=$5 SEQ=$6 sec tmp vdd
  shift 6
  IFS=: read -r sec tmp vdd <<< "$COND"
  mkdir -p "$D"
  echo "$COND" > "$D/cond"
  echo "$TOPN" > "$D/macro"
  if python3 "$BENCH" bench --sp "$NET" --top "$TOPN" --bin "$B" --word-bytes "$WB" --words-per-row "$WPR" \
      --out "$D" --models "$MODELS" --period "$PERIOD" --seq "$SEQ" --sanitize --plain-nfet --probes full \
      --bitlines all --corner "$sec" --temp "$tmp" --vdd "$vdd" "$@" > "$D/bench.txt" 2>&1; then
    grep -E "WARNING" "$D/bench.txt" | sed 's/^/      /'
    SIMQ+=("$D")
  else
    echo "      ERROR: bench ${D#$WORK/} not written:"; tail -3 "$D/bench.txt" | sed 's/^/      /'
  fi
}

# the E8.3 macro first (the longest runs), then every macro's tt run
if [ "$FULL" = 1 ]; then
  SEQ=$(python3 "$BENCH" pick --bin "$BIN0" --word-bytes "$WB" --words-per-row "$WPR" --mode words \
        --addrs "$FULL_ADDRS" --waits "$SCREEN_WAIT" 2>"$WORK/pick_full.txt")
  if [ -n "$SEQ" ]; then
    mkdir -p "$WORK/full"
    echo "   E8.3 macro: $(grep -E '^A = ' "$WORK/pick_full.txt" | cut -c1-220)"
    write_bench "$WORK/full/tt_orig" "$PEX0" "$MACRO" "$BIN0" "tt:25:1.80" "$SEQ"
    write_bench "$WORK/full/tt_cs" "$PEX0" "$MACRO" "$BIN0" "tt:25:1.80" "$SEQ" --cs-delay "$CSD"
  else
    echo "   E8.3 macro: no sequence:"; sed 's/^/      /' "$WORK/pick_full.txt"
  fi
fi
for n in $GOOD; do
  SEQ=$(python3 "$BENCH" seqof --dir "$W5/$n/screen" 2>/dev/null)
  [ -n "$SEQ" ] || { echo "   $n: E8.4a-5's sequence not readable"; continue; }
  echo "$SEQ" > "$WORK/a5/$n.seq"
  write_bench "$WORK/$n/tt_cs" "$W5/$n/extract/$n.flat_pex.spice" "$n" "$W5/bins/$n.bin" "tt:25:1.80" "$SEQ" \
      --cs-delay "$CSD"
done

select_and_queue() {   # select_and_queue R: worst macro and rows of option r<R> (CS delayed, tt); queue corners and sweeps
  local r=$1 n dirs="" labs="" WRUN WWORDS SWORDS WN SEQ c sec tmp vdd D d
  mkdir -p "$WORK/r$r"
  for n in $(opt_names "$r"); do
    D="$WORK/$n/tt_cs"
    [ -f "$D/tb_done" ] || continue
    python3 "$BENCH" analyze --dir "$D" > "$D/analyze.txt" 2>&1
    dirs="$dirs $D"; labs="$labs $n"
  done
  echo
  echo "   ---- option r$r: selection from the tt runs with CS delayed at $(stamp) ----"
  [ -n "$dirs" ] || { echo "   no finished tt run: no corner and no sweep runs for r$r"; return; }
  python3 "$BENCH" margins --dirs $dirs --labels $labs --n "$CORNER_ROWS" --per-row > "$WORK/r$r/select.txt" 2>&1
  sed -n '/^all runs/,$p' "$WORK/r$r/select.txt" | grep -vE "^(WORST_RUN|WORST_WORDS|TARGET_READS|LOWEST_ONE_CELL_V) " \
    | sed 's/^/   /'
  WRUN=$(sed -n 's/^WORST_RUN //p' "$WORK/r$r/select.txt")
  WWORDS=$(sed -n 's/^WORST_WORDS //p' "$WORK/r$r/select.txt")
  if [ -z "$WRUN" ] || [ -z "$WWORDS" ]; then
    echo "   no words selected (see $WORK/r$r/select.txt)"
    return
  fi
  WN=$(basename "$(dirname "$WRUN")")
  SWORDS=$(echo "$WWORDS" | cut -d, -f1-"$NSWEEP")
  echo "$WN" > "$WORK/r$r/worst_macro"
  echo "$WWORDS" > "$WORK/r$r/corner_words"
  echo "$SWORDS" > "$WORK/r$r/sweep_words"
  NET="$W5/$WN/extract/$WN.flat_pex.spice"
  BINW="$W5/bins/$WN.bin"
  SEQ=$(python3 "$BENCH" pick --bin "$BINW" --word-bytes "$WB" --words-per-row "$WPR" --mode words \
        --addrs "$WWORDS" --waits "$SCREEN_WAIT" 2>"$WORK/r$r/pick_corner.txt")
  echo "   conditions on $WN, words $WWORDS: $CORNERS"
  for c in $CORNERS; do
    write_bench "$WORK/r$r/corner_$(corner_tag "$c")" "$NET" "$WN" "$BINW" "$c" "$SEQ" --cs-delay "$CSD"
  done
  SEQ=$(python3 "$BENCH" pick --bin "$BINW" --word-bytes "$WB" --words-per-row "$WPR" --mode words \
        --addrs "$SWORDS" --waits "$SCREEN_WAIT" 2>"$WORK/r$r/pick_sweep.txt")
  echo "   CS delay sweep on $WN, words $SWORDS: delays $SWEEP_CSD ns at tt:25:1.80 $SWEEP_CORNERS"
  for d in ${SWEEP_CSD//,/ }; do
    write_bench "$WORK/r$r/sweep_tt_$(csd_tag "$d")" "$NET" "$WN" "$BINW" "tt:25:1.80" "$SEQ" --cs-delay "$d"
    for c in $SWEEP_CORNERS; do
      write_bench "$WORK/r$r/sweep_c_$(corner_tag "$c")_$(csd_tag "$d")" "$NET" "$WN" "$BINW" "$c" "$SEQ" --cs-delay "$d"
    done
  done
}

NSC=$(( 1 + $(echo $SWEEP_CORNERS | wc -w) ))
echo "   queued: $([ "$FULL" = 1 ] && echo "2 runs of the E8.3 macro, ")$(echo $GOOD | wc -w) tt runs; then per option"
echo "   $(echo $CORNERS | wc -w) condition runs and $(( $(echo ${SWEEP_CSD//,/ } | wc -w) * NSC )) sweep runs"
pump
progress
last=$(date +%s)
declare -A SELECTED
while :; do
  for r in $SPLITS; do
    [ -n "${SELECTED[$r]:-}" ] && continue
    pending=0
    for n in $(opt_names "$r"); do
      case " $GOOD " in *" $n "*) ;; *) continue ;; esac
      sim_done "$WORK/$n/tt_cs" || pending=1
    done
    if [ "$pending" = 0 ]; then
      SELECTED[$r]=1
      select_and_queue "$r"
    fi
  done
  pump
  busy=0
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

hr "e. results"
for d in $(all_runs); do report "$d" "${d#$WORK/} ($(cond_of "$d"), $(cat "$d/macro" 2>/dev/null))"; done
echo
echo "---- read by read: E8.4a-5 (CS before the clock) against E8.4a-6 (CS $CSD ns after the clock), tt ----"
for n in $GOOD; do
  [ -f "$WORK/$n/tt_cs/result.json" ] && [ -f "$WORK/a5/$n.json" ] || continue
  echo
  echo "   $n:"
  python3 "$BENCH" ab --a "$WORK/a5/$n.json" --b "$WORK/$n/tt_cs/result.json" --labels "E8.4a-5" "E8.4a-6 CS +$CSD ns"
done
hr "f. summaries"
summaries

echo
echo "---- files: $WORK ----"
du -sh "$WORK" 2>/dev/null | sed 's/^/   /'
echo
echo "=============================================================="
echo "Finished $(stamp)."
echo "=============================================================="
