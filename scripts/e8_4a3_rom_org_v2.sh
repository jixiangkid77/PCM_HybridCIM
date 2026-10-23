#!/usr/bin/env bash
# =============================================================================
# e8_4a3_rom_org_v2.sh   [run | status | stop]
#
# Experiment : P2R-E8.4a-3. Compare ROM organisations of the same content
#              (post-layout), to decide how the address-map ROM is organised.
# Version    : 2026-10-11 (2). The first version (e8_4a3_rom_org.sh, 02:03)
#              compared 32 and 64 words per row; both layouts are faulty (see
#              "Why not more than 24 words per row" below). This version
#              compares 16 and 24. It has a new name so that it can be copied
#              while the first version still runs (bash reads a running script
#              from its file; overwriting the file would change what it runs).
#
# Why (E8.4a-2, 2026-10-10, macro e8rom_A_pcm_l00_16x2496, post-layout)
#   - The macro of E8.3 (13 words per row, 192 rows, 208 columns) is LVS-clean
#     and reads correctly, at 138.5-167.1 pJ per 100 ns read cycle for rows
#     with zero bits.
#   - But each bitline is a chain of 192 cells: after a read of a row with
#     many zero bits, a read of the bottom row needs more than 250 ns (less
#     than 550 ns) of precharge. In E8.2, the fully connected layers look up
#     every 140 ns. Shorter chains recover faster; wider rows cost area and
#     discharge more bitlines per read.
#
# Organisations (same data file, same 16-bit words, 2,496 words)
#   w13    13 words per row: 192 rows x 208 columns (the E8.3 macro; its
#          extraction, LVS and main sequence come from E8.4a-2)
#   w16    16 words per row: 156 rows x 256 columns
#   w24    24 words per row: 104 rows x 384 columns
#   w13np  13 words per row without perimeter pins (area reference only)
#   The new organisations are generated with perimeter_pins = False (the
#   pins stay on the internal blocks instead of being routed to the macro
#   edge; with 32 and 64 words per row the escape routing failed in the
#   sandbox), and w13np the same way, so that the area comparison is like
#   for like. With 16 words per row the ROM address equals the entry number;
#   with 24 (as with 13) the decoders divide the entry number by 24.
#
# Why not more than 24 words per row (sandbox, OpenRAM e16d9eb, 2026-10-11)
#   rom_column_mux_array.py places the select rails below the multiplexer
#   transistors, but adds an extra offset after every 4 rails; the offsets
#   accumulate, and from 26 words per row the top rail is pushed into the
#   transistors. magic then reports "Illegal overlap between ndiff and poly"
#   in the column multiplexer: 600 (26 words per row), 408 (28), 606 (32),
#   2,934 (64) errors; 0 for 13, 16, 20 and 24. Flattened, the 32-word
#   multiplexer has 15 extra transistors and 16 misshapen ones. LVS can still
#   match (26 words per row, small macro), because the hierarchical
#   extraction leaves the overlaps out; the full-size 64-word macro fails LVS
#   (46,953 vs 46,968 devices). Such layouts cannot be used, so the script
#   stops if E8_WPRS asks for more than 24 words per row.
#
# Steps
#   a. tools, files, the Python that runs OpenRAM (as found by E8.3)
#   b. generate w13np, w32 and w64 (three at a time); check that each
#      netlist stores the data file bit by bit; drawn layout extent (magic)
#   c. start, on the E8.4a-2 extraction of w13: the precharge sweep and the
#      idle sequence
#   d. magic, w16 and w24 at the same time: flat extraction for LVS and with
#      parasitic capacitance (as E8.4a-2); then for each: extraction errors,
#      top-level supply merges, capacitor check, netgen LVS, and the
#      post-layout main, sweep and idle sequences
#   e. wait (at most E8_MAXSIM simulations at a time, default 4)
#   f. results: per organisation, then the comparison table
#
# Sequences (e8_4_rom_bench.py pick; period 100 ns; M = the row with the most
# zero bits, its word with the most zeros; L = the bottom row, its word with
# the most one bits; P = the word with no zero bit in the lowest row)
#   main   as E8.4a: i, rL, rA, rM, rA, rO, i, s3
#   sweep  i, then for N = 0, 25, 50, 100, 200, 300, 400, 500 ns:
#          rM, N ns with the clock held low, rL (precharge before rL = N + 50 ns)
#   idle   i, rM, rP, i x 10, rM, i x 20, rP, i x 5: the static current after a
#          read with zero bits while the clock keeps running (CS low), and
#          the effect of reading a word with no zero bit ("parking read")
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\  (with e8_4_rom_bench.py
#           of 2026-10-11 (2), which replaces the earlier ones)
# Writes  : only reports\e8_rom\e8_4a3\<macro>\ (configs, macros, logs, area,
#           w13, w16, w24). E8.3's macros and the E8.4a-2 folder are only read.
#           A rerun overwrites the e8_4a3 folder of that macro; it refuses to
#           start while processes of an earlier run still work in that folder.
# Run     : cd /mnt/d/Project/hybrid_memory/paper2
#           bash scripts/e8_4a3_rom_org_v2.sh 2>&1 | tee reports/e8_4a3_rom_org_v2.log
#           Keep the terminal open and the computer awake.
# Status  : bash scripts/e8_4a3_rom_org_v2.sh status 2>&1 | tee reports/e8_4a3_v2_status.log
# Stop    : bash scripts/e8_4a3_rom_org_v2.sh stop
#           Ends a run of this script (either version) and the ngspice, magic
#           and netgen processes working in its folder. Ctrl+C alone ends only
#           the script: the simulations it started keep running.
# Options : E8_WPRS (default "16 24"), E8_MAXSIM (default 4), E8_PERIOD
#           (default 100), E8_OPENRAM_PY (the Python for OpenRAM; default:
#           search as E8.3 did), E8_MACRO, E8_TIMEOUT (default 0 = none).
#           Used only for testing: E8_USE_NIX (written into the configurations
#           if set), E8_OPENRAM_PDK (PDK_ROOT for OpenRAM), E8_FORCE_WPR=1
#           (allow more than 24 words per row).
# Runtime : generation about 10-15 min; magic about 70-100 min (two at a
#           time); eight post-layout simulations, four at a time, 30-60 min
#           each. In all about 3 to 4 hours. Memory: about 3 GB per
#           simulation (at most four), plus magic and netgen.
# =============================================================================
set -uo pipefail

MODE="${1:-run}"
PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
OPENRAM="${E8_OPENRAM:-/home/kid/openram/OpenRAM}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
MACRO="${E8_MACRO:-e8rom_A_pcm_l00_16x2496}"
WPRS="${E8_WPRS:-16 24}"
PERIOD="${E8_PERIOD:-100}"
MAXSIM="${E8_MAXSIM:-4}"
TIMEOUT="${E8_TIMEOUT:-0}"
HEARTBEAT="${E8_HEARTBEAT:-1800}"
ROOT="$PAPER2/reports/e8_rom"
SP0="$ROOT/macros/$MACRO/$MACRO.sp"
GDS0="$ROOT/macros/$MACRO/$MACRO.gds"
LEF0="$ROOT/macros/$MACRO/$MACRO.lef"
BIN="$ROOT/bins/$MACRO.bin"
OLD="$ROOT/e8_4a2/$MACRO"
PEX0="$OLD/extract/$MACRO.flat_pex.spice"
BENCH="$PAPER2/scripts/e8_4_rom_bench.py"
MODELS="$PDK_ROOT_DIR/sky130A/libs.tech/ngspice/sky130.lib.spice"
MAGICRC="$PDK_ROOT_DIR/sky130A/libs.tech/magic/sky130A.magicrc"
NETGEN_SETUP="$PDK_ROOT_DIR/sky130A/libs.tech/netgen/sky130A_setup.tcl"
WORK="$ROOT/e8_4a3/$MACRO"
WB=2
case "$MACRO" in *_8x*) WB=1 ;; esac

pick() { ls -d $1 2>/dev/null | sort -V | tail -1; }
NGSPICE="${E8_NGSPICE:-$(pick "/nix/store/*-ngspice-*/bin/ngspice")}"
MAGIC="${E8_MAGIC:-$(pick "/nix/store/*magic-vlsi*/bin/magic")}"
NETGEN="${E8_NETGEN:-$(pick "/nix/store/*netgen*/bin/netgen")}"
NCORES=$(nproc 2>/dev/null || echo 4)
NTHREADS=2

ORGS="w13"
for w in $WPRS; do
  case "$w" in ''|*[!0-9]*) echo "ERROR: E8_WPRS must list numbers of words per row (got '$w')" >&2; exit 1 ;; esac
  if [ "$w" -gt 24 ] && [ "${E8_FORCE_WPR:-0}" != 1 ]; then
    echo "ERROR: $w words per row: OpenRAM e16d9eb draws a faulty column multiplexer above 24 words per row (see the header)" >&2
    exit 1
  fi
  ORGS="$ORGS w$w"
done

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
    bash|sh)
      case "$a1" in ngspice|magic|netgen|e8_4a3_rom_org.sh|e8_4a3_rom_org_v2.sh) return 0 ;; esac ;;
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
    st=${st##*) }        # after "pid (name) ": state, parent pid, ...
    set -- $st
    q=${2:-}
    n=$((n + 1))
  done
  return 1
}
procs_in_work() {   # this script's tools working in $WORK (a shell or viewer the user opened there is left alone)
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
other_runs() {   # other running instances of this script or the first version in run mode
                 # ("bash .../e8_4a3_rom_org[_v2].sh [run]"),
                 # not this one and not its subshells; an editor or viewer of the script is not one
  local p a0 a1 a2
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    a0="" a1="" a2=""
    { IFS= read -r -d '' a0; IFS= read -r -d '' a1; IFS= read -r -d '' a2; } 2>/dev/null < "/proc/$p/cmdline"
    case "${a0##*/}" in bash|sh) ;; *) continue ;; esac
    case "${a1##*/}" in e8_4a3_rom_org.sh|e8_4a3_rom_org_v2.sh) ;; *) continue ;; esac
    case "$a2" in ""|run) ;; *) continue ;; esac
    is_mine "$p" || echo "$p"
  done
}
runs_of() {   # the simulations of an organisation
  case "$1" in
    w13) echo "ext_sweep ext_idle" ;;
    *)   echo "ext_main ext_sweep ext_idle" ;;
  esac
}
wpr_of() { [ "$1" = w13 ] && echo "" || echo "${1#w}"; }

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
  if [ ! -f "$d/tb_meta.json" ]; then echo "not started"
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
  for O in $ORGS; do
    if [ "$O" != w13 ]; then
      local X="$WORK/$O/extract"
      if [ -f "$X/finished" ]; then xs="finished ($(( $(cat "$X/finished") - $(cat "$X/started") )) s)"
      elif [ -f "$X/started" ]; then xs="running ($(( $(date +%s) - $(cat "$X/started") )) s)"
      else xs="not started"; fi
      local L="$WORK/$O/lvs"
      ls_="$( [ -f "$L/finished" ] && echo finished || ([ -f "$L/started" ] && echo running || echo -))"
      printf "      %-4s extraction %-22s LVS %s\n" "$O" "$xs" "$ls_"
    fi
    for R in $(runs_of "$O"); do
      printf "      %-4s %-10s %-40s %-8s %s\n" "$O" "$R" "$(state "$WORK/$O/$R")" "$(elapsed "$WORK/$O/$R")" \
        "$( [ -f "$WORK/$O/$R/tb_meta.json" ] && reached "$WORK/$O/$R")"
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

lvs_report() {   # lvs_report ORG
  local L="$WORK/$1/lvs"
  echo
  echo "---- $1: LVS $( [ -f "$L/finished" ] && echo "finished, $(( $(cat "$L/finished") - $(cat "$L/started") )) s" \
        || ([ -f "$L/started" ] && echo "running" || echo "not started")) ----"
  [ -f "$L/netgen.log" ] || return
  grep -E "^Circuit 1 contains|Final result|match uniquely|do not match|Top level cell|ERROR|Error" \
      "$L/netgen.log" | tail -6 | sed 's/^/   /'
  if [ -f "$L/lvs_report.txt" ]; then
    awk '/(NET|DEVICE) mismatches/{f=1;n=0} /Netlists do not match|Subcircuit pins/{f=0} f&&n<60{print; n++}' \
        "$L/lvs_report.txt" | tail -120 | cut -c1-140 | sed 's/^/      /'
  fi
}

write_spec() {
  local f="$WORK/orgs.json" first=1
  {
    echo "["
    for O in $ORGS w13np; do
      [ $first -eq 1 ] || echo ","
      first=0
      case "$O" in
        w13)
          printf '{"label": "13 words/row (E8.3, 192 rows)", "bin": "%s", "word_bytes": %s, "wpr": null, "lef": "%s", "box_log": "%s", "lvs_log": "%s", "extract_log": "%s", "main": "%s", "sweep": "%s", "idle": "%s"}' \
            "$BIN" "$WB" "$LEF0" "$WORK/area/$MACRO.box.log" "$OLD/lvs/netgen.log" "$OLD/extract/magic_extract.log" "$OLD/ext_main" \
            "$WORK/w13/ext_sweep" "$WORK/w13/ext_idle" ;;
        w13np)
          printf '{"label": "13 words/row, no perimeter pins", "bin": "%s", "word_bytes": %s, "wpr": null, "lef": "%s", "box_log": "%s"}' \
            "$BIN" "$WB" "$WORK/macros/${MACRO}_w13np/${MACRO}_w13np.lef" "$WORK/area/${MACRO}_w13np.box.log" ;;
        *)
          local N="${MACRO}_$O" W="${O#w}"
          printf '{"label": "%s words/row, no perimeter pins", "bin": "%s", "word_bytes": %s, "wpr": %s, "lef": "%s", "box_log": "%s", "lvs_log": "%s", "extract_log": "%s", "main": "%s", "sweep": "%s", "idle": "%s"}' \
            "$W" "$BIN" "$WB" "$W" "$WORK/macros/$N/$N.lef" "$WORK/area/$N.box.log" "$WORK/$O/lvs/netgen.log" \
            "$WORK/$O/extract/magic_extract.log" "$WORK/$O/ext_main" "$WORK/$O/ext_sweep" "$WORK/$O/ext_idle" ;;
      esac
    done
    echo "]"
  } > "$f"
}

if [ "$MODE" = "status" ]; then
  echo "=============================================================="
  echo "P2R-E8.4a-3 status, $(stamp)   ($MACRO)"
  echo "=============================================================="
  progress
  for O in $ORGS; do
    [ "$O" != w13 ] && lvs_report "$O"
    for R in $(runs_of "$O"); do report "$WORK/$O/$R" "$O $R"; done
  done
  echo
  hr "comparison (as far as available)"
  write_spec
  python3 "$BENCH" orgsum --spec "$WORK/orgs.json"
  exit 0
fi

if [ "$MODE" = "stop" ]; then
  echo "P2R-E8.4a-3 stop, $(stamp)   ($WORK)"
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
  echo "       Let it finish, or end it first with: bash scripts/e8_4a3_rom_org_v2.sh stop" >&2
  exit 1
fi

echo "=============================================================="
echo "P2R-E8.4a-3 ROM organisations (version 2026-10-11 (2)), started $(stamp)"
echo "=============================================================="
echo "macro    : $MACRO  (word bytes $WB)   organisations: w13 (E8.3), $(for w in $WPRS; do printf 'w%s ' "$w"; done)+ w13np (area)"
echo "OpenRAM  : $OPENRAM  $(cat "$OPENRAM/VERSION" 2>/dev/null)  $(git -C "$OPENRAM" log -1 --format='%h %ad' --date=short 2>/dev/null)"
echo "ngspice  : ${NGSPICE:-<missing>}"
echo "magic    : ${MAGIC:-<missing>}"
echo "netgen   : ${NETGEN:-<missing>}"
echo "models   : $MODELS (tt)"
echo "period   : $PERIOD ns   at most $MAXSIM simulations at a time, $NTHREADS threads each   time limit: $([ "$TIMEOUT" -gt 0 ] && echo "$TIMEOUT s" || echo none)"
echo "machine  : $NCORES cores, $(free -g | awk '/Mem:/{print $2" GiB memory, "$7" GiB available"}')"
for F in "$SP0" "$GDS0" "$LEF0" "$BIN" "$BENCH" "$MODELS" "$MAGICRC" "$NETGEN_SETUP" "$PEX0" \
         "$OLD/lvs/netgen.log" "$OLD/ext_main/result.json" "$OPENRAM/rom_compiler.py" "$OPENRAM/setpaths.sh"; do
  [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
[ -n "$NGSPICE" ] && [ -n "$MAGIC" ] && [ -n "$NETGEN" ] || { echo "ERROR: ngspice, magic or netgen not found" >&2; exit 1; }
grep -q "def ext_errors" "$BENCH" || { echo "ERROR: $BENCH is an older version; copy the one of 2026-10-11 (2)" >&2; exit 1; }
"$NGSPICE" -v < /dev/null 2>&1 | grep -m1 -i "ngspice-" | sed 's/^/   /'

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
mkdir -p "$WORK"/{configs,macros,logs,area} || exit 1
for O in $ORGS; do mkdir -p "$WORK/$O"; done

hr "b. generate the organisations (three at a time)"
write_cfg() {   # write_cfg NAME WPR(empty = the generator's choice)
  local n=$1 w=$2
  {
    echo "# P2R-E8.4a-3 ROM configuration for $n (generated by e8_4a3_rom_org_v2.sh)."
    echo "# As E8.3 (scripts/e8_3_rom_tools.py), plus the organisation and perimeter_pins = False."
    echo 'tech_name = "sky130"'
    echo "nominal_corner_only = True"
    echo 'route_supplies = "ring"'
    echo "check_lvsdrc = False"
    echo "word_size = $WB"
    echo "rom_data = \"$BIN\""
    echo 'data_type = "bin"'
    echo "output_name = \"$n\""
    echo "output_path = \"$WORK/macros/$n/\""
    [ -n "$w" ] && echo "words_per_row = $w"
    echo "perimeter_pins = False"
    # E8.3 left use_nix at OpenRAM's default (True: the compiler runs
    # "nix develop --command true" once at start-up; no effect on the layout)
    [ -n "${E8_USE_NIX:-}" ] && echo "use_nix = $E8_USE_NIX"
  } > "$WORK/configs/$n.py"
}
gen() {   # gen NAME
  local n=$1 s
  s=$(date +%s)
  (
    cd "$OPENRAM" && source ./setpaths.sh >/dev/null 2>&1 || exit 99
    [ -n "${E8_OPENRAM_PDK:-}" ] && export PDK_ROOT="$E8_OPENRAM_PDK"
    "$PY" -u rom_compiler.py -v "$WORK/configs/$n.py"
  ) > "$WORK/logs/gen_$n.log" 2>&1
  echo "   $n: exit $?, $(( $(date +%s) - s )) s; $(grep -h 'Read rom data file' "$WORK/logs/gen_$n.log" | sed 's/.*Read rom data file: //')"
}
NAMES="${MACRO}_w13np"
write_cfg "${MACRO}_w13np" ""
for w in $WPRS; do write_cfg "${MACRO}_w$w" "$w"; NAMES="$NAMES ${MACRO}_w$w"; done
for n in $NAMES; do gen "$n" & done
wait
GEN_OK=1
for n in $NAMES; do
  for ext in sp gds lef; do
    [ -f "$WORK/macros/$n/$n.$ext" ] || { echo "   MISSING $n.$ext; the log ends with:"; tail -5 "$WORK/logs/gen_$n.log" | sed 's/^/      /'; GEN_OK=0; }
  done
done
echo "   stored bits:"
for n in $NAMES; do
  w=""; case "$n" in *_w13np) w="" ;; *_w*) w="${n##*_w}" ;; esac
  [ -f "$WORK/macros/$n/$n.sp" ] && python3 "$BENCH" bitcheck --sp "$WORK/macros/$n/$n.sp" --top "$n" --bin "$BIN" \
      --word-bytes "$WB" ${w:+--words-per-row "$w"} 2>&1 | sed 's/^/      /'
done
echo "   drawn layout extent (magic) and LEF:"
box() {   # box NAME GDS
  printf 'gds read %s\nload %s\nselect top cell\nbox\nquit -noprompt\n' "$2" "$1" > "$WORK/area/$1.box.tcl"
  PDK_ROOT="$PDK_ROOT_DIR" timeout 1800 "$MAGIC" -dnull -noconsole -rcfile "$MAGICRC" \
      < "$WORK/area/$1.box.tcl" > "$WORK/area/$1.box.log" 2>&1
  printf "      %-36s layout %s   LEF %s\n" "$1" "$(grep -m1 '^microns:' "$WORK/area/$1.box.log" | awk '{print $2" x "$4}')" \
      "$(grep -m1 -E '^\s*SIZE' "$(dirname "$2")/$1.lef" 2>/dev/null | awk '{print $2" x "$4}')"
}
box "$MACRO" "$GDS0"
for n in $NAMES; do [ -f "$WORK/macros/$n/$n.gds" ] && box "$n" "$WORK/macros/$n/$n.gds"; done

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
pump() {   # start queued simulations while fewer than MAXSIM run
  local d
  for d in "${QUEUE[@]}"; do
    [ -f "$d/pid" ] && continue
    [ "$(running)" -lt "$MAXSIM" ] || break
    launch "$d"
  done
}
bench_org() {   # bench_org ORG NETLIST: write the benches of an organisation and queue them
  local O=$1 NET=$2 W R SEQ
  W=$(wpr_of "$O")
  for R in $(runs_of "$O"); do
    SEQ=$(python3 "$BENCH" pick --bin "$BIN" --word-bytes "$WB" --mode "${R#ext_}" ${W:+--words-per-row "$W"} 2>"$WORK/$O/pick_${R#ext_}.txt")
    echo "   $O ${R#ext_}: $(grep -E '^M = ' "$WORK/$O/pick_${R#ext_}.txt" || head -1 "$WORK/$O/pick_${R#ext_}.txt")"
    echo "      $SEQ"
    if python3 "$BENCH" bench --sp "$NET" --top "$(basename "$NET" | sed -E 's/\.flat_pex\.spice$//')" --bin "$BIN" \
        --word-bytes "$WB" ${W:+--words-per-row "$W"} --out "$WORK/$O/$R" --models "$MODELS" --corner tt \
        --period "$PERIOD" --seq "$SEQ" --sanitize --plain-nfet --probes full > "$WORK/$O/bench_$R.txt" 2>&1; then
      grep -E "note: probes|WARNING" "$WORK/$O/bench_$R.txt" | sed 's/^/      /'
      QUEUE+=("$WORK/$O/$R")
    else
      echo "      ERROR: bench not written:"; tail -3 "$WORK/$O/bench_$R.txt" | sed 's/^/      /'
    fi
  done
}

hr "c. the E8.3 macro (w13): sweep and idle sequences on the E8.4a-2 extraction"
bench_org w13 "$PEX0"
pump

hr "d. magic, $(for w in $WPRS; do printf 'w%s ' "$w"; done)at the same time (flat extraction for LVS and with parasitic capacitance)"
extract() {   # extract ORG
  local O=$1 N="${MACRO}_$1" X="$WORK/$1/extract"
  mkdir -p "$X"
  cat > "$X/extract.tcl" <<EOF
drc off
gds flatten true
gds ordering true
gds read $WORK/macros/$N/$N.gds
load $N
select top cell
expand
readspice $WORK/macros/$N/$N.sp
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
ext2spice -o $X/$N.flat_lvs.spice
ext2spice cthresh 0
ext2spice -o $X/$N.flat_pex.spice
quit -noprompt
EOF
  date +%s > "$X/started"
  ( cd "$X" && PDK_ROOT="$PDK_ROOT_DIR" "$MAGIC" -dnull -noconsole -rcfile "$MAGICRC" < extract.tcl \
        > magic_extract.log 2>&1; echo $? > magic_exit; date +%s > finished ) &
  echo "   started the extraction of $O at $(stamp)"
}
post_extract() {   # post_extract ORG: checks, LVS, benches
  local O=$1 N="${MACRO}_$1" X="$WORK/$1/extract" NEG PROBE
  local LVSNET="$X/$N.flat_lvs.spice" PEXNET="$X/$N.flat_pex.spice"
  echo
  echo "   ---- $O: magic exit $(cat "$X/magic_exit"), $(( $(cat "$X/finished") - $(cat "$X/started") )) s ----"
  grep -iE "error|fatal|could not|not found|shorted" "$X/magic_extract.log" \
      | grep -v "boundary was redefined" | sort | uniq -c | sort -rn | head -8 | sed 's/^/   log: /'
  local XE
  XE=$(grep -m1 -oE "Total of [0-9]+ errors" "$X/magic_extract.log" | grep -oE "[0-9]+")
  if [ -n "$XE" ]; then
    echo "   extraction errors: $XE  -> the layout is FAULTY (must be 0, even if LVS matches)"
  else
    echo "   extraction errors: 0"
  fi
  if [ -f "$X/$N.ext" ]; then
    python3 "$BENCH" shorts --ext "$X/$N.ext" | grep -v '^{' | sed 's/^/   /'
  fi
  [ -s "$LVSNET" ] && python3 "$BENCH" probe --sp "$LVSNET" --top "$N" 2>&1 | grep -E "^(devices|capacitors)" | sed 's/^/   LVS netlist: /'
  NEG=1
  if [ -s "$PEXNET" ]; then
    PROBE=$(python3 "$BENCH" probe --sp "$PEXNET" --top "$N" 2>&1)
    echo "$PROBE" | grep -E "^(devices|capacitors|negative)" | sed 's/^/   simulation netlist: /'
    NEG=$(echo "$PROBE" | grep '^{' | python3 -c "import json,sys; print(json.load(sys.stdin)['caps_negative'])" 2>/dev/null || echo 1)
  fi
  if [ -s "$LVSNET" ]; then
    mkdir -p "$WORK/$O/lvs"
    sed 's/sky130_fd_pr__special_nfet_01v8/sky130_fd_pr__nfet_01v8/g' "$LVSNET" > "$WORK/$O/lvs/layout.spice"
    date +%s > "$WORK/$O/lvs/started"
    ( cd "$WORK/$O/lvs" && "$NETGEN" -batch lvs "layout.spice $N" "$WORK/macros/$N/$N.sp $N" "$NETGEN_SETUP" \
          lvs_report.txt > netgen.log 2>&1; date +%s > finished ) &
    echo "   started LVS of $O at $(stamp)"
  fi
  if [ -s "$PEXNET" ] && [ "$NEG" = "0" ]; then
    bench_org "$O" "$PEXNET"
  else
    echo "   post-layout simulations of $O NOT started: no netlist, or negative capacitors ($NEG)"
  fi
}
if [ "$GEN_OK" -eq 1 ]; then
  for w in $WPRS; do extract "w$w"; done
else
  echo "   not every organisation was generated; extracting those that were"
  for w in $WPRS; do [ -f "$WORK/macros/${MACRO}_w$w/${MACRO}_w$w.gds" ] && extract "w$w"; done
fi

hr "e. waiting (progress every $HEARTBEAT s; at most $MAXSIM simulations at a time)"
progress
last=$(date +%s)
while :; do
  for w in $WPRS; do
    X="$WORK/w$w/extract"
    if [ -f "$X/finished" ] && [ ! -f "$X/post_done" ]; then
      touch "$X/post_done"
      post_extract "w$w"
    fi
  done
  pump
  busy=0
  for w in $WPRS; do
    X="$WORK/w$w/extract"
    [ -f "$X/started" ] && [ ! -f "$X/post_done" ] && busy=1
    [ -f "$WORK/w$w/lvs/started" ] && [ ! -f "$WORK/w$w/lvs/finished" ] && busy=1
  done
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

hr "f. results"
for O in $ORGS; do
  [ "$O" != w13 ] && lvs_report "$O"
  for R in $(runs_of "$O"); do report "$WORK/$O/$R" "$O $R"; done
done
echo
echo "---- comparison of the organisations ----"
write_spec
python3 "$BENCH" orgsum --spec "$WORK/orgs.json"

echo
echo "---- files: $WORK ----"
du -sh "$WORK"/* 2>/dev/null | sed 's/^/   /'
echo
echo "=============================================================="
echo "Finished $(stamp)."
echo "=============================================================="
