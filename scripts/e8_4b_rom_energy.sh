#!/usr/bin/env bash
# =============================================================================
# e8_4b_rom_energy.sh   [run | status | stop]
#
# Experiment : P2R-E8.4b. Energy of the chosen address-map ROM (T1 + r48) in
#              the access pattern of the system, on the 48 macros that E8.4a-7
#              generated, extracted and verified: read energy, the static
#              current that a zero output bit leaves behind, parking reads,
#              leakage, the idle clock; and an energy model for E8.6, checked
#              against post-layout simulations of real lookup sequences.
#
# Why
#   - E8.4a-7 (2026-10-13): every row of the 12 tables reads correctly with the
#     margin rule. At the end of each read cycle the supply power was about
#     25 uW + 47 uW per zero bit of the word read (4,512 reads, r^2 0.70). The
#     column multiplexer (one NMOS per column) leaves the output-buffer input of
#     a zero bit at about VDD - Vth, and the buffer conducts until the next read.
#     Between two lookups (E8.2: 140-410 ns; much longer for a macro that the
#     current layer does not read) this can cost more than the read itself.
#   - Sandbox (2026-10-13, a 16-row macro): after a read of 0x0000 the supply
#     power stayed at 795-824 uW for 10 us with the clock low; a read of a word
#     without zero bits ("parking read") brought it to 0.42 uW. With the clock
#     running and CS low an idle cycle cost 80.8 pJ, after parking 1.4 pJ.
#   - Sandbox (2026-10-13, E8.4b test): the static power after a read depends on
#     which bits of the word are zero, not on how many (a 16-row macro: 0x0000
#     797 uW, 0x027f 746 uW, a word with 10 zero bits 908 uW; per output bit
#     about 0-440 uW). E8.4a-7 refitted: zero bits counted r^2 0.71 (PCM) /
#     0.50 (SRAM), each bit on its own 0.86 (PCM). So the model comes in two
#     forms, and the leave-one-table-out check decides which one E8.6 uses.
#   - E8.6 adds up the energy of every lookup of the trace (833,040 ROM reads
#     per model) for each way of running the ROM (a clock pulse only for a read,
#     or a free-running clock; with or without parking reads). That needs a
#     model from post-layout simulation, checked on real lookup sequences.
#
# Runs (post-layout, tt, 25 C, 1.80 V; CS E8_CS_DELAY ns after the clock edge;
# read cycle 100 ns = 50 ns clock low (precharge) + 50 ns high; every bitline
# saved; the macros, data and netlists of E8.4a-7, not generated again)
#   part A  every macro: Z = its word with the most zero bits, H = about half
#           of them, Ps / Pd = words without zero bits (the shallowest row /
#           a deep row with few zero cells). Sequence (7.4 us):
#             idle, Z, 1 us clock low, Pd, 1 us, Z, Ps at once (parking read,
#             50 ns of precharge), 1 us, Z, Pd at once, 1 us, H, 1 us, Ps,
#             5 idle clock cycles (CS low), 1 us
#           -> static power after Z and H, power after parking (leakage),
#           energy and margins of parking reads, idle clock when parked
#   parking after each part A: the cheaper of Pd and Ps among those that read
#   word    correctly 50 ns after Z with the margin rule and leave at most the
#           lowest parked power + 10 uW (and 5 % of the power after Z)
#   trains  per table, consecutive real lookups of its lane (E8.2 trace; tables
#           are lanes 00, 12, 24 of models A and B) at their real intervals:
#             conv1         macro 0, 13 lookups 410 ns apart; a parking read
#                           after every lookup with zero bits
#             conv2         macro 0, 13 lookups from the middle of conv2, 380-410
#                           ns apart; parking as conv1
#             conv2_nopark  the same 13 lookups without parking
#             fc1           macro 1, 13 lookups 140-170 ns apart (no room for a
#                           parking read in between); parking after the last
#           (conv1 + conv2 are 86 % of all lookups and read rows 0-7 of macro 0)
#   drift   E8_DRIFT macros: idle, Z, 5 idle clock cycles, 20 us clock low, Ps,
#           5 idle cycles, 1 us -> the static power over 20 us, and with the
#           clock running
# Results
#   - every read correct, no wrong selection, margins (rule of E8.4a-6/-7)
#   - per macro: static power after Z and H, per zero bit, leakage, parking
#     reads, idle clock, the parking word
#   - per side (PCM / SRAM), two forms: zero bits counted, or the static power
#     of each output bit (non-negative fit). Static power after a read; read
#     window E = a + b x rows below + c x zero cells of the row + the word's
#     zero bits (or static power) + those of the read before (its current flows
#     until the outputs switch); parking read likewise
#   - the energy of every train against the model fitted without the train's
#     table (leave one table out); criterion fixed before the run: every train
#     within +-10 %, all trains together within +-5 %
#   - conv2 with and without parking; E8.4a-7's screening reads against the
#     read models; the drift of the static power
#   - reports\e8_rom\e8_4b\model.json (all data and the models, for E8.6)
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\  with e8_4b_energy_tools.py
#           (new) and e8_4_rom_bench.py of 2026-10-12 (5) (unchanged)
# Needs   : reports\e8_rom\e8_4a7\ (macro data, extracted netlists, LVS,
#           switching level), reports\e8_rom\bins\<table>.bin (E8.3) and
#           reports\e8_rom\trace\trace_A.txt, trace_B.txt (E8.2); only read
# Writes  : only reports\e8_rom\e8_4b\ (v2: or E8_OUT_NAME). A run replaces the output of the
#           tables it runs and keeps the others; it refuses to start while an
#           earlier run still works there.
# Run     : cd /mnt/d/Project/hybrid_memory/paper2
#           bash scripts/e8_4b_rom_energy.sh 2>&1 | tee reports/e8_4b_rom_energy.log
#           Keep the terminal open and the computer awake (see Runtime).
# Status  : bash scripts/e8_4b_rom_energy.sh status 2>&1 | tee reports/e8_4b_status.log
#           (any time; it does not disturb the run)
# Stop    : bash scripts/e8_4b_rom_energy.sh stop
#           (Ctrl+C alone ends only the script: the simulations keep running)
# Interrupted: run the unfinished tables again with E8_TABLES="e8rom_..." (the
#           others are kept), then status for the summary of all of them.
# Options : E8_TABLES, E8_DRIFT ("A_pcm_l00:0 A_sram_l00:0" = table:macro),
#           E8_CS_DELAY (10), E8_TRAIN_LEN (13), E8_MARGIN (0.10), E8_MAXJOBS
#           (cores - 1), E8_TIMEOUT (0 = none), E8_HEARTBEAT (1800 s),
#           E8_RELTOL (v2; empty = ngspice's 1e-3), E8_OUT_NAME (v2; e8_4b),
#           E8_CORNER, E8_TEMP, E8_VDD, E8_VM, E8_PARK_FROM, E8_TRAINS (v3)
#
# Version 2 (2026-10-18, P2R-E8 time-step check, claude/p2r-e8-tstep-sandbox.md):
#   With the maximum time step of these runs (period / 50 = 2 ns) and ngspice's
#   default tolerances, the static current a read leaves behind came out up to
#   about 10 % off a 20 ps run (per word, either sign), a read energy up to
#   4.7 %, the parked power (about 1 uW) with 20-40 % noise (sandbox). Reads,
#   selections and margins did not change. reltol 1e-4 with the same maximum
#   step agreed with 20 ps within 0.22 % (read energy) and 0.07 % (static
#   power), at 1.1-1.8 times the run time.
#   - E8_RELTOL=1e-4 passes --reltol to every bench (needs e8_4_rom_bench.py of
#     2026-10-18 (6)); empty: the decks are those of version 1.
#   - E8_OUT_NAME=e8_4b_rel4 writes reports\e8_rom\e8_4b_rel4\ instead of
#     reports\e8_rom\e8_4b\ (which is then left unchanged). status and stop
#     need the same E8_OUT_NAME.
#   Without the two options the script does exactly what version 1 did.
#
# Version 3 (2026-10-19, P2R-E8.4e, claude/p2r-e8-plan.md): the same runs at
#   another operating condition, for the sensitivity of the energy to process
#   corner and temperature.
#   - E8_CORNER (tt, ff, ss, fs, sf; default tt), E8_TEMP (C, -55 to 150;
#     default 25) and E8_VDD (V, 1.40 to 2.00; default 1.80) go to every bench.
#   - The switching level of the bitline inverter at that condition: E8_VM if
#     given; else from E8.4a-7's vm.txt when it has the condition; else
#     measured here (DC, the same deck as E8.4a-7, inverter sizes from the
#     generator netlist of the first macro) into the output folder.
#   - E8_PARK_FROM=<model.json of an earlier run>: every macro parks on the
#     word chosen in that run (the choice made here is still printed), so the
#     trains are the same sequences as there.
#   - E8_TRAINS: the trains to run (default "conv1 conv2 conv2_nopark fc1").
#   - E8_DRIFT=none: no drift runs.
#   - The fit compares with E8.4a-7's screening reads only at tt, 25 C, 1.80 V.
#   - The run writes its condition into the output folder; status reads it,
#     and a run at another condition refuses to write into that folder.
#   Without these options the script does exactly what version 2 did.
#           Used only for testing: E8_ROWS (48), E8_WPR (13), E8_TABLE_WORDS (2496)
# Runtime : 48 part-A runs, 4 trains per table (48), 2 drift runs. Estimated from
#           E8.4a-7 on this machine (one read cycle of a 48-row macro about 58 s on
#           the PCM side and 78 s on the SRAM side, 7 jobs at a time) and the
#           sandbox (1 us with the clock low costs about as much as one read
#           cycle): part A 20-26 min per macro, trains 16-40 min, drift 34-45 min;
#           about 6.5 hours in all. Disk: about 5 GB.
# =============================================================================
set -uo pipefail

MODE="${1:-run}"
PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
TW="${E8_TABLE_WORDS:-2496}"
SUF="_16x$TW"
TABLES="${E8_TABLES:-e8rom_A_pcm_l00$SUF e8rom_A_sram_l00$SUF e8rom_B_pcm_l00$SUF e8rom_A_pcm_l12$SUF e8rom_A_pcm_l24$SUF e8rom_B_pcm_l12$SUF e8rom_B_pcm_l24$SUF e8rom_B_sram_l00$SUF e8rom_A_sram_l12$SUF e8rom_A_sram_l24$SUF e8rom_B_sram_l12$SUF e8rom_B_sram_l24$SUF}"
ROWS="${E8_ROWS:-48}"
WPR="${E8_WPR:-13}"
CSD="${E8_CS_DELAY:-10}"
TL="${E8_TRAIN_LEN:-13}"
DRIFT="${E8_DRIFT:-A_pcm_l00:0 A_sram_l00:0}"
MARGIN="${E8_MARGIN:-0.10}"
RELTOL="${E8_RELTOL:-}"         # v2: ngspice relative tolerance for every bench (empty: ngspice's 1e-3, as v1)
OUTNAME="${E8_OUT_NAME:-e8_4b}" # v2: results folder under reports/e8_rom (must start with e8_4b)
CORNER="${E8_CORNER:-tt}"       # v3: model section of every bench
TEMPC="${E8_TEMP:-25}"          # v3: temperature (C)
VDDV="${E8_VDD:-1.80}"          # v3: supply (V)
VMOVR="${E8_VM:-}"              # v3: switching level of the bitline inverter (V), if given
PARKFROM="${E8_PARK_FROM:-}"    # v3: model.json whose parking words every macro uses
TRAINS="${E8_TRAINS:-conv1 conv2 conv2_nopark fc1}"   # v3: the trains to run
[ "$DRIFT" = none ] && DRIFT=""  # v3: E8_DRIFT=none, no drift runs
PERIOD=100                     # the read sequences of e8_4b_energy_tools.py assume 100 ns read cycles
TIMEOUT="${E8_TIMEOUT:-0}"
HEARTBEAT="${E8_HEARTBEAT:-1800}"
ROOT="$PAPER2/reports/e8_rom"
BENCH="$PAPER2/scripts/e8_4_rom_bench.py"
TOOLS="$PAPER2/scripts/e8_4b_energy_tools.py"
MODELS="$PDK_ROOT_DIR/sky130A/libs.tech/ngspice/sky130.lib.spice"
W7="$ROOT/e8_4a7"
case "$OUTNAME" in
  e8_4b|e8_4b_[A-Za-z0-9]*) case "$OUTNAME" in *[!A-Za-z0-9_]*) OUTNAME="" ;; esac ;;
  *) OUTNAME="" ;;
esac
[ -n "$OUTNAME" ] || { echo "ERROR: E8_OUT_NAME must be e8_4b or start with e8_4b_ (letters, digits, _), e.g. e8_4b_rel4" >&2; exit 1; }
WORK="$ROOT/$OUTNAME"
WB=2
SELF="e8_4b_rom_energy.sh"

pick_path() { ls -d $1 2>/dev/null | sort -V | tail -1; }
NGSPICE="${E8_NGSPICE:-$(pick_path "/nix/store/*-ngspice-*/bin/ngspice")}"
NCORES=$(nproc 2>/dev/null || echo 4)
MAXJOBS="${E8_MAXJOBS:-$(( NCORES > 2 ? NCORES - 1 : 1 ))}"
NTHREADS=1          # sandbox, 2026-10-11: a second thread made a 32-row macro only 1.18 times faster

isnum() { python3 -c "import sys; float(sys.argv[1])" "$1" 2>/dev/null; }
case "$ROWS$WPR$TW$TL$MAXJOBS$TIMEOUT$HEARTBEAT" in
  *[!0-9]*|"") echo "ERROR: E8_ROWS, E8_WPR, E8_TABLE_WORDS, E8_TRAIN_LEN, E8_MAXJOBS, E8_TIMEOUT, E8_HEARTBEAT must be integers" >&2; exit 1 ;;
esac
for v in "$ROWS" "$WPR" "$TL" "$MAXJOBS"; do
  [ "$v" -ge 1 ] || { echo "ERROR: E8_ROWS, E8_WPR, E8_TRAIN_LEN, E8_MAXJOBS must be at least 1" >&2; exit 1; }
done
isnum "$CSD" || { echo "ERROR: E8_CS_DELAY must be a number of ns" >&2; exit 1; }
if [ -n "$RELTOL" ]; then
  python3 -c "import sys; v = float(sys.argv[1]); sys.exit(0 if 0 < v < 1e-2 else 1)" "$RELTOL" 2>/dev/null \
    || { echo "ERROR: E8_RELTOL must be a number between 0 and 0.01, e.g. 1e-4 (got '$RELTOL')" >&2; exit 1; }
fi
isnum "$MARGIN" || { echo "ERROR: E8_MARGIN must be a number of V" >&2; exit 1; }
case "$CORNER" in tt|ff|ss|fs|sf) ;; *) echo "ERROR: E8_CORNER must be tt, ff, ss, fs or sf (got '$CORNER')" >&2; exit 1 ;; esac
python3 -c "import sys; v = float(sys.argv[1]); sys.exit(0 if -55 <= v <= 150 else 1)" "$TEMPC" 2>/dev/null \
  || { echo "ERROR: E8_TEMP must be a number of degrees C between -55 and 150 (got '$TEMPC')" >&2; exit 1; }
python3 -c "import sys; v = float(sys.argv[1]); sys.exit(0 if 1.4 <= v <= 2.0 else 1)" "$VDDV" 2>/dev/null \
  || { echo "ERROR: E8_VDD must be a number of volts between 1.40 and 2.00 (got '$VDDV')" >&2; exit 1; }
if [ -n "$VMOVR" ]; then
  python3 -c "import sys; v = float(sys.argv[1]); sys.exit(0 if 0.2 <= v <= 1.8 else 1)" "$VMOVR" 2>/dev/null \
    || { echo "ERROR: E8_VM must be a switching level in volts between 0.2 and 1.8 (got '$VMOVR')" >&2; exit 1; }
fi
COND=$(python3 -c "import sys; t = float(sys.argv[2]); v = float(sys.argv[3]); print(f'{sys.argv[1]}:{int(t) if t == int(t) else t}:{v:.2f}')" "$CORNER" "$TEMPC" "$VDDV")
for x in $TRAINS; do
  case "$x" in conv1|conv2|conv2_nopark|fc1) ;; *) echo "ERROR: E8_TRAINS takes conv1, conv2, conv2_nopark, fc1 (got '$x')" >&2; exit 1 ;; esac
done
if [ -n "$PARKFROM" ]; then
  case "$PARKFROM" in /*) ;; *) PARKFROM="$PAPER2/$PARKFROM" ;; esac
  [ -f "$PARKFROM" ] || { echo "ERROR: E8_PARK_FROM: no file $PARKFROM" >&2; exit 1; }
fi
for t in $TABLES; do
  case "$t" in *[!A-Za-z0-9_]*) echo "ERROR: '$t' is not a table name" >&2; exit 1 ;; esac
  case "$t" in e8rom_[AB]_pcm_l[0-9][0-9]"$SUF"|e8rom_[AB]_sram_l[0-9][0-9]"$SUF") ;;
    *) echo "ERROR: $t is not an E8.3 table name (e8rom_<A|B>_<pcm|sram>_l<lane>_16x$TW)" >&2; exit 1 ;; esac
done
for d in $DRIFT; do
  case "$d" in [AB]_pcm_l[0-9][0-9]:[0-9]|[AB]_sram_l[0-9][0-9]:[0-9]) ;;
    *) echo "ERROR: E8_DRIFT entries are table:macro, e.g. A_pcm_l00:0 (got '$d')" >&2; exit 1 ;; esac
done

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
ttag() {   # e8rom_A_sram_l00_16x2496 -> A_sram_l00
  local x=${1#e8rom_}
  echo "${x%"$SUF"}"
}
tmodel() { local x; x=$(ttag "$1"); echo "${x%%_*}"; }
tside() { local x; x=$(ttag "$1"); x=${x#*_}; echo "${x%%_*}"; }
tlane() { local x; x=$(ttag "$1"); echo "${x##*_l}"; }
mname() { echo "${1}_r${ROWS}k$2"; }                  # the macro name of table $1, macro $2 (E8.4a-7)
nmacros() { local n; n=$(grep -c . "$W7/bins/$1.names" 2>/dev/null); echo "${n:-0}"; }
short() { local x=${1#$WORK/}; x=${x//e8rom_/}; echo "${x//$SUF/}"; }

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
run_dirs() {   # every run directory of the tables (info.json written)
  local t d
  for t in $TABLES; do
    for d in "$WORK/$t"/*/; do
      d=${d%/}
      [ -f "$d/info.json" ] && echo "$d"
    done
  done
}
progress() {
  local d
  echo "   progress at $(stamp):"
  for d in $(run_dirs); do
    printf "      %-36s %-40s %-6s %s\n" "$(short "$d")" "$(state "$d")" "$(elapsed "$d")" \
      "$( [ -f "$d/tb_meta.json" ] && reached "$d")"
  done
}
report() {   # report DIR
  local d=$1
  echo; echo "---- $(short "$d"): $(state "$d"), wall time $(elapsed "$d"), ngspice exit $(cat "$d/exit_code" 2>/dev/null || echo '-') ----"
  [ -f "$d/seq" ] && echo "   sequence: $(cat "$d/seq")"
  [ -f "$d/ngspice.log" ] || { echo "   no log"; return; }
  tr '\r' '\n' < "$d/ngspice.log" | grep -v "Reference value" \
    | grep -iE "error|could not|unknown|singular|timestep too small|abort|E8_FAILED" | sort | uniq -c \
    | sort -rn | head -8 | sed 's/^/   log: /'
  tr '\r' '\n' < "$d/ngspice.log" | grep -iE "total analysis time" | head -1 | sed 's/^/   /'
  python3 "$BENCH" analyze --dir "$d"
}
vm_tt() { awk '$1 == "tt:25:1.80" {print $2}' "$W7/vm/vm.txt" 2>/dev/null | head -1; }
vm_lookup() {   # v3: the switching level at $COND without measuring (E8_VM, E8.4a-7, this folder)
  if [ -n "$VMOVR" ]; then echo "$VMOVR"; return; fi
  local v
  v=$(awk -v c="$COND" '$1 == c {print $2}' "$W7/vm/vm.txt" 2>/dev/null | head -1)
  [ -n "$v" ] || v=$(awk -v c="$COND" '$1 == c {print $2}' "$WORK/vm/vm.txt" 2>/dev/null | head -1)
  echo "$v"
}
vm_source() {
  if [ -n "$VMOVR" ]; then echo "E8_VM"
  elif awk -v c="$COND" '$1 == c {f = 1} END {exit !f}' "$W7/vm/vm.txt" 2>/dev/null; then echo "E8.4a-7"
  else echo "measured by this script"; fi
}
park_ref() {   # v3: park_ref MACRO -> the parking word chosen for MACRO in E8_PARK_FROM ('none' if none), and its text
  python3 - "$PARKFROM" "$1" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
p = next((x for x in m.get("parta", []) if x.get("macro") == sys.argv[2]), None)
if p is None:
    print("MISSING")
else:
    c = (p.get("park_choice") or "").strip()
    w = c.split()[0] if c and c.split()[0].isdigit() else "none"
    print(w, c if c else "(no parking word)")
PY
}
summaries() {
  local VM d dirs="" refs="" t k n
  VM=$(vm_lookup)
  [ -n "$VM" ] || { echo "   no switching level at $COND: no summary"; return; }
  for d in $(run_dirs); do
    if [ ! -f "$d/result.json" ] || [ "$d/tb_out.txt" -nt "$d/result.json" ]; then
      python3 "$BENCH" analyze --dir "$d" > "$d/analyze.txt" 2>&1
    fi
    [ -f "$d/result.json" ] && dirs="$dirs $d"
  done
  [ -n "$dirs" ] || { echo "   no run with results yet"; return; }
  for t in $TABLES; do
    for ((k = 0; k < $(nmacros "$t"); k++)); do
      n=$(mname "$t" "$k")
      [ -f "$W7/$n/tt_cs/result.json" ] && refs="$refs $(tside "$t")=$W7/$n/tt_cs"
    done
  done
  if [ "$COND" = "tt:25:1.80" ]; then
    echo "   switching level of the bitline inverter at tt, 25 C, 1.80 V (E8.4a-7): $VM V"
  else
    refs=""
    echo "   switching level of the bitline inverter at $COND ($(vm_source)): $VM V; no comparison with E8.4a-7 (tt) screening reads"
  fi
  python3 "$TOOLS" fit --dirs $dirs --vm "$VM" --rows "$ROWS" --margin "$MARGIN" --ref $refs --out "$WORK/model.json"
  echo
  echo "   model and data for E8.6: $WORK/model.json"
}

if [ -f "$WORK/condition.txt" ] && [ "$MODE" = "status" ]; then   # v3: the condition of the run in this folder
  read -r COND_F _ < "$WORK/condition.txt"
  if [ -n "$COND_F" ] && [ "$COND_F" != "$COND" ]; then
    COND=$COND_F
    IFS=: read -r CORNER TEMPC VDDV <<< "$COND"
  fi
fi
if [ "$MODE" = "status" ]; then
  echo "=============================================================="
  echo "P2R-E8.4b status, $(stamp)"
  echo "=============================================================="
  progress
  for d in $(run_dirs); do
    [ -f "$d/tb_meta.json" ] && report "$d"
    [ -f "$d/select.txt" ] && { echo "   parking word:"; sed 's/^/   /' "$d/select.txt"; }
  done
  hr "summaries (as far as available)"
  summaries
  exit 0
fi

if [ "$MODE" = "stop" ]; then
  echo "P2R-E8.4b stop, $(stamp)   ($WORK)"
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

if [ "$MODE" != "run" ]; then
  echo "ERROR: unknown mode '$MODE' (run, status or stop)" >&2
  exit 1
fi

R=$(other_runs | tr '\n' ' '); P=$(procs_in_work | tr '\n' ' ')
if [ -n "${R// /}${P// /}" ]; then
  echo "ERROR: an earlier run is still working (script: ${R:-none}; processes in $WORK: ${P:-none})." >&2
  echo "       Let it finish, or end it first with: bash scripts/$SELF stop" >&2
  exit 1
fi

echo "=============================================================="
echo "P2R-E8.4b address-map ROM energy in the system's access pattern, started $(stamp)"
echo "=============================================================="
echo "tables   : $(for t in $TABLES; do printf '%s ' "$(ttag "$t")"; done)($(echo $TABLES | wc -w) tables, $ROWS-row macros of E8.4a-7, $WPR words per row)"
echo "reads    : $CORNER, $TEMPC C, $VDDV V; $PERIOD ns read cycles (50 ns clock low, 50 ns high); CS rises $CSD ns after the clock edge"
if [ "$TRAINS" = "conv1 conv2 conv2_nopark fc1" ]; then
  echo "trains   : $TL real consecutive lookups each (conv1, conv2, conv2 without parking: macro 0; fc1: macro 1)"
else
  echo "trains   : $TL real consecutive lookups each; only: $TRAINS (E8_TRAINS)"
fi
echo "drift    : ${DRIFT:-none}"
[ -n "$PARKFROM" ] && echo "parking  : every macro parks on the word chosen in $PARKFROM (E8_PARK_FROM)"
echo "rule     : every read correct, no wrong selection, margins >= $MARGIN V (E8.4a-6/-7)"
echo "ngspice  : ${NGSPICE:-<missing>}"
echo "models   : $MODELS"
echo "jobs     : at most $MAXJOBS simulations at a time (ngspice threads: $NTHREADS)   time limit: $([ "$TIMEOUT" -gt 0 ] && echo "$TIMEOUT s" || echo none)"
echo "solver   : maximum time step period/50 = $((PERIOD / 50)) ns; relative tolerance reltol $([ -n "$RELTOL" ] && echo "$RELTOL (E8_RELTOL)" || echo "not set (ngspice's 1e-3)")"
echo "output   : $WORK (E8_OUT_NAME=$OUTNAME)"
echo "machine  : $NCORES cores, $(free -g | awk '/Mem:/{print $2" GiB memory, "$7" GiB available"}'), $(df -h "$ROOT" 2>/dev/null | awk 'NR==2{print $4" free on the disk"}')"

hr "a. tools and inputs"
for F in "$BENCH" "$TOOLS" "$MODELS"; do
  [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
[ -n "$NGSPICE" ] || { echo "ERROR: ngspice not found" >&2; exit 1; }
grep -q "def cmd_condsum" "$BENCH" && grep -q "cs_delay" "$BENCH" \
  || { echo "ERROR: $BENCH is an older version; copy the one of 2026-10-12 (5)" >&2; exit 1; }
if [ -n "$RELTOL" ]; then
  grep -q -- '"--reltol"' "$BENCH" \
    || { echo "ERROR: E8_RELTOL needs $BENCH of 2026-10-18 (6) (option --reltol)" >&2; exit 1; }
fi
echo "   bench : $(md5sum "$BENCH" | cut -c1-32)  $BENCH"
echo "   tools : $(md5sum "$TOOLS" | cut -c1-32)  $TOOLS"
"$NGSPICE" -v < /dev/null 2>&1 | grep -m1 -i "ngspice-" | sed 's/^/   /'
grep -qE "^\.lib[[:space:]]+tt([[:space:]]|$)" "$MODELS" || { echo "ERROR: the model library has no section 'tt'" >&2; exit 1; }
grep -qE "^\.lib[[:space:]]+$CORNER([[:space:]]|$)" "$MODELS" || { echo "ERROR: the model library has no section '$CORNER'" >&2; exit 1; }
if [ -f "$WORK/condition.txt" ]; then   # v3: one condition per output folder
  read -r COND_F _ < "$WORK/condition.txt"
  [ "$COND_F" = "$COND" ] || { echo "ERROR: $WORK holds results at $COND_F; use another E8_OUT_NAME for $COND" >&2; exit 1; }
fi
mkdir -p "$WORK/vm" || exit 1
VM=$(vm_lookup)
if [ -z "$VM" ]; then   # v3: measure it (the deck of E8.4a-7)
  t1=$(echo $TABLES | awk '{print $1}'); n1=$(mname "$t1" 0)
  INV=""
  [ -f "$W7/macros/$n1/$n1.sp" ] && INV=$(python3 "$BENCH" invsize --sp "$W7/macros/$n1/$n1.sp" --top "$n1" 2>&1 | grep '^pfet ')
  if [ -z "$INV" ]; then   # the sizes E8.4a-7 printed in its log (the same generator for every r48 macro)
    for f in $(ls "$PAPER2"/reports/e8_4a7*.log 2>/dev/null); do
      INV=$(grep -m1 -oE "_r${ROWS}k0: pfet [0-9.]+ [0-9.]+ nfet [0-9.]+ [0-9.]+" "$f" | sed 's/^[^:]*: //')
      [ -n "$INV" ] && { echo "   inverter sizes from $f"; break; }
    done
  fi
  read -r _ PW PL _ NW NL <<< "$INV"
  [ -n "$PW" ] && [ -n "$NL" ] || { echo "ERROR: inverter sizes not found ($W7/macros/$n1/$n1.sp, reports/e8_4a7*.log); give E8_VM" >&2; exit 1; }
  tag=$(echo "$COND" | tr ':.-' '_pm')
  {
    echo "* P2R-E8.4b (v3) switching level of the bitline inverter at $COND"
    echo ".lib \"$MODELS\" $CORNER"
    echo ".temp $TEMPC"
    echo "Vdd vdd 0 $VDDV"
    echo "Vin a 0 0"
    echo "Xp z a vdd vdd sky130_fd_pr__pfet_01v8 w=$PW l=$PL"
    echo "Xn z a 0 0 sky130_fd_pr__nfet_01v8 w=$NW l=$NL"
    echo ".control"
    echo "dc Vin 0 $VDDV 0.001"
    echo "let d = v(z) - v(a)"
    echo "meas dc vm when d=0"
    echo "quit"
    echo ".endc"
    echo ".end"
  } > "$WORK/vm/$tag.sp"
  ( cd "$WORK/vm" && timeout 900 "$NGSPICE" -b "$tag.sp" > "$tag.log" 2>&1 )
  VM=$(awk '$1 == "vm" {print $3}' "$WORK/vm/$tag.log")
  [ -n "$VM" ] || { echo "ERROR: switching level at $COND not measured (see $WORK/vm/$tag.log)" >&2; exit 1; }
  VM=$(printf "%.3f" "$VM")
  echo "   bitline inverter: $INV"
  printf "%s %s\n" "$COND" "$VM" >> "$WORK/vm/vm.txt"
fi
echo "   switching level of the bitline inverter, $CORNER $TEMPC C $VDDV V ($(vm_source)): $VM V"
if [ -n "$PARKFROM" ]; then
  echo "   parking words from: $(md5sum "$PARKFROM" | cut -c1-32)  $PARKFROM"
  for t in $TABLES; do
    for ((k = 0; k < $(nmacros "$t"); k++)); do
      r=$(park_ref "$(mname "$t" "$k")")
      [ "$r" != MISSING ] || { echo "ERROR: $(mname "$t" "$k") is not in $PARKFROM" >&2; exit 1; }
      echo "      $(mname "$t" "$k"): word ${r%% *}; in that run: ${r#* }"
    done
  done
fi
echo "$COND $TRAINS" > "$WORK/condition.txt"
MODELS_USED=""
for t in $TABLES; do
  M=$(tmodel "$t")
  case " $MODELS_USED " in *" $M "*) ;; *) MODELS_USED="$MODELS_USED $M" ;; esac
done
for M in $MODELS_USED; do
  f="$ROOT/trace/trace_$M.txt"
  [ -f "$f" ] || { echo "ERROR: missing $f (E8.2)" >&2; exit 1; }
  echo "   trace : $(md5sum "$f" | cut -c1-32)  $f  ($(grep -vc '^#' "$f") operations)"
done

# a run replaces the earlier output of the tables it runs, and nothing else
mkdir -p "$WORK/lookups" || exit 1
for t in $TABLES; do rm -rf "${WORK:?}/$t"; done
rm -f "$WORK/model.json"

hr "a. lookups of each lane (E8.2 trace) and the macros of each table (E8.4a-7)"
GOODT=""
for t in $TABLES; do
  M=$(tmodel "$t"); L=$(tlane "$t")
  LK="$WORK/lookups/${M}_l$L.json"
  if [ ! -s "$LK" ] || [ "$LK" -ot "$ROOT/trace/trace_$M.txt" ]; then
    python3 "$TOOLS" lookups --trace "$ROOT/trace/trace_$M.txt" --model "$M" --lane "$((10#$L))" --out "$LK" \
      > "$WORK/lookups/${M}_l$L.txt" 2>&1 || { echo "   $(ttag "$t"): lookups FAILED:"; sed 's/^/      /' "$WORK/lookups/${M}_l$L.txt"; continue; }
  fi
  echo "   $(ttag "$t"): $(cat "$WORK/lookups/${M}_l$L.txt")"
  f="$ROOT/bins/$t.bin"
  if [ ! -f "$f" ] || [ "$(stat -c %s "$f")" != "$((TW * WB))" ]; then
    echo "      SKIPPED: no data file of $TW words ($f)"; continue
  fi
  nm=$(nmacros "$t")
  if [ "$nm" -lt 1 ]; then echo "      SKIPPED: no macros in $W7/bins/$t.names (E8.4a-7)"; continue; fi
  ok=1
  for ((k = 0; k < nm; k++)); do
    n=$(mname "$t" "$k")
    X="$W7/$n/extract"
    msg=""
    grep -qx "$n" "$W7/bins/$t.names" || msg="not in $t.names"
    [ -s "$X/$n.flat_pex.spice" ] || msg="${msg:+$msg; }no extracted netlist"
    grep -qE "Total of [0-9]+ errors" "$X/magic_extract.log" 2>/dev/null && msg="${msg:+$msg; }extraction errors"
    grep -q "match uniquely" "$W7/$n/lvs/netgen.log" 2>/dev/null || msg="${msg:+$msg; }LVS not matched"
    python3 - "$f" "$W7/bins/$n.bin" "$k" "$((ROWS * WPR))" <<'PY' || msg="${msg:+$msg; }data differ from the table"
import sys
t, m, k, per = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read(), int(sys.argv[3]), int(sys.argv[4])
sys.exit(0 if t[2 * k * per:2 * (k + 1) * per] == m else 1)
PY
    if [ -n "$msg" ]; then echo "      macro $k $n: $msg"; ok=0; fi
  done
  [ "$ok" = 1 ] || { echo "      SKIPPED"; continue; }
  echo "      $nm macros of E8.4a-7: data equal to the table, extracted without errors, LVS matched"
  mkdir -p "$WORK/$t"
  python3 "$TOOLS" plan --bin "$f" --lookups "$LK" --rows "$ROWS" --wpr "$WPR" --train-len "$TL" \
      --out "$WORK/$t/plan.json" > "$WORK/$t/plan.txt" 2>&1 \
    || { echo "      plan FAILED:"; sed 's/^/      /' "$WORK/$t/plan.txt"; continue; }
  sed 's/^/   /' "$WORK/$t/plan.txt"
  GOODT="$GOODT $t"
done
TABLES="${GOODT# }"
[ -n "$TABLES" ] || { echo "ERROR: no table to run" >&2; exit 1; }

spiceinit() {
  cat > "$1/.spiceinit" <<EOF
* ngspice settings recommended for the sky130 models
set ngbehavior=hsa
set ng_nomodcheck
set skywaterpdk
set num_threads=$NTHREADS
EOF
}
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
  echo "   started $(short "$d") at $(stamp)"
}
write_info() {   # write_info DIR TABLE K KIND TRAIN PARK
  python3 - "$@" "$(tmodel "$2")" "$(tside "$2")" "$((10#$(tlane "$2")))" "$(mname "$2" "$3")" "$(short "$1")" <<'PY'
import json, os, sys
d, t, k, kind, train, park, model, side, lane, macro, label = sys.argv[1:]
json.dump({"label": label, "table": t, "model": model, "side": side, "lane": int(lane), "k": int(k), "macro": macro,
           "kind": kind, "train": train or None, "park": None if park in ("", "none") else int(park)},
          open(os.path.join(d, "info.json"), "w"), indent=1)
PY
}
PAQ1=()     # part A of macros 0 and 1 (their trains wait for them)
PAQ2=()     # part A of the other macros
TRQ=()      # trains, in the order their parking word is chosen
DRQ=()      # drift runs
write_run() {   # write_run QUEUE DIR TABLE K KIND TRAIN PARK SEQ
  local Q=$1 D=$2 t=$3 k=$4 kind=$5 train=$6 park=$7 SEQ=$8 n
  n=$(mname "$t" "$k")
  mkdir -p "$D"
  echo "$SEQ" > "$D/seq"
  if python3 "$BENCH" bench --sp "$W7/$n/extract/$n.flat_pex.spice" --top "$n" --bin "$W7/bins/$n.bin" \
      --word-bytes "$WB" --words-per-row "$WPR" --out "$D" --models "$MODELS" --period "$PERIOD" --seq "$SEQ" \
      --sanitize --plain-nfet --probes full --bitlines all --corner "$CORNER" --temp "$TEMPC" --vdd "$VDDV" \
      --cs-delay "$CSD" ${RELTOL:+--reltol "$RELTOL"} > "$D/bench.txt" 2>&1; then
    grep -E "WARNING" "$D/bench.txt" | sed 's/^/      /'
    write_info "$D" "$t" "$k" "$kind" "$train" "$park"
    case "$Q" in
      pa1) PAQ1+=("$D") ;;
      pa2) PAQ2+=("$D") ;;
      tr) TRQ+=("$D") ;;
      dr) DRQ+=("$D") ;;
    esac
  else
    echo "      ERROR: bench $(short "$D") not written:"; tail -3 "$D/bench.txt" | sed 's/^/      /'
  fi
}
running_sims() {
  local n=0 d
  for d in "${TRQ[@]}" "${PAQ1[@]}" "${DRQ[@]}" "${PAQ2[@]}"; do
    [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null && n=$((n + 1))
  done
  echo $n
}
pump() {   # trains first (tables finish one after another), then part A of macros 0-1, drift, part A of macros 2-3
  local d
  for d in "${TRQ[@]}" "${PAQ1[@]}" "${DRQ[@]}" "${PAQ2[@]}"; do
    [ -f "$d/pid" ] && continue
    [ "$(running_sims)" -lt "$MAXJOBS" ] || return
    launch "$d"
  done
}
queue_trains() {   # queue_trains TABLE K: the trains of macro K after its part A
  local t=$1 k=$2 D="$WORK/$1/k${2}_parta" P name park S
  python3 "$TOOLS" select --plan "$WORK/$t/plan.json" --macro "$k" --result "$D/result.json" --vm "$VM" \
      --margin "$MARGIN" > "$D/select.txt" 2>&1
  echo
  echo "   ---- $(short "$D"): parking word at $(stamp) ----"
  sed 's/^/   /' "$D/select.txt"
  P=$(sed -n 's/^PARK \([0-9][0-9]*\) .*/\1/p' "$D/select.txt" | head -1)
  if [ -n "$PARKFROM" ]; then   # v3: the parking word of the earlier run
    read -r PW_REF PTXT <<< "$(park_ref "$(mname "$t" "$k")")"
    echo "PARK_FIXED ${PW_REF} from $(basename "$(dirname "$PARKFROM")"): ${PTXT}" >> "$D/select.txt"
    echo "   parking word fixed from $PARKFROM: ${PW_REF} (chosen here: ${P:-none})"
    if [ "$PW_REF" = none ]; then P=""; else P=$PW_REF; fi
  fi
  python3 - "$D/info.json" "$( [ -n "$PARKFROM" ] && sed -n 's/^PARK_FIXED //p' "$D/select.txt" | head -1 || sed -n 's/^PARK //p' "$D/select.txt" | head -1)" <<'PY'
import json, sys
i = json.load(open(sys.argv[1]))
i["park_choice"] = sys.argv[2]
json.dump(i, open(sys.argv[1], "w"), indent=1)
PY
  case "$k" in
    0) set -- $(for x in conv1:park conv2:park conv2_nopark:none; do case " $TRAINS " in *" ${x%%:*} "*) echo "$x" ;; esac; done) ;;
    1) set -- $(case " $TRAINS " in *" fc1 "*) echo fc1:park ;; esac) ;;
    *) set -- ;;
  esac
  for x in "$@"; do
    name=${x%%:*}
    park=${x#*:}
    if [ "$park" = park ]; then
      if [ -n "$P" ]; then park=$P
      elif [ "$name" = conv2 ]; then echo "   $name: not run (no parking word; conv2_nopark covers these lookups)"; continue
      else park=none; echo "   $name: run without parking (no parking word)"; fi
    fi
    S=$(python3 "$TOOLS" seq --plan "$WORK/$t/plan.json" --what "${name%_nopark}" --park "$park" 2>/dev/null) \
      || { echo "   $name: no train in the plan of $(ttag "$t")"; continue; }
    write_run tr "$WORK/$t/$name" "$t" "$k" train "${name%_nopark}" "$park" "$S"
    echo "   queued $(short "$WORK/$t/$name") (parking word: $park)"
  done
}

hr "b. part A of every macro, drift runs (benches written now; trains after each macro's part A)"
for t in $TABLES; do
  for ((k = 0; k < $(nmacros "$t"); k++)); do
    S=$(python3 "$TOOLS" seq --plan "$WORK/$t/plan.json" --what parta --macro "$k")
    if [ "$k" -le 1 ]; then Q=pa1; else Q=pa2; fi
    write_run "$Q" "$WORK/$t/k${k}_parta" "$t" "$k" parta "" none "$S"
  done
done
for x in $DRIFT; do
  t="e8rom_${x%%:*}$SUF"; k=${x#*:}
  case " $TABLES " in *" $t "*) ;; *) echo "   drift $x: table not in this run"; continue ;; esac
  [ "$k" -lt "$(nmacros "$t")" ] || { echo "   drift $x: no macro $k"; continue; }
  S=$(python3 "$TOOLS" seq --plan "$WORK/$t/plan.json" --what drift --macro "$k")
  write_run dr "$WORK/$t/k${k}_drift" "$t" "$k" drift "" none "$S"
done
echo "   $(( ${#PAQ1[@]} + ${#PAQ2[@]} )) part-A runs, ${#DRQ[@]} drift runs written; up to $(echo $TRAINS | wc -w) trains per table follow"
pump
progress
last=$(date +%s)
declare -A POSTED
while :; do
  for d in "${PAQ1[@]}" "${PAQ2[@]}" "${TRQ[@]}" "${DRQ[@]}"; do
    [ -n "${POSTED[$d]:-}" ] && continue
    [ -f "$d/pid" ] && ! kill -0 "$(cat "$d/pid")" 2>/dev/null || continue
    POSTED[$d]=1
    python3 "$BENCH" analyze --dir "$d" > "$d/analyze.txt" 2>&1
    echo "   finished $(short "$d") at $(stamp): $(state "$d"), $(elapsed "$d"), $(grep -m1 '^data:' "$d/analyze.txt" | cut -c7-)"
    case "$d" in
      */k0_parta|*/k1_parta)
        t=$(basename "$(dirname "$d")"); k=${d##*/k}; k=${k%%_*}
        queue_trains "$t" "$k" ;;
    esac
  done
  pump
  busy=0
  for d in "${PAQ1[@]}" "${PAQ2[@]}" "${TRQ[@]}" "${DRQ[@]}"; do
    [ -n "${POSTED[$d]:-}" ] || busy=1
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

hr "c. results of every run"
for d in $(run_dirs); do
  report "$d"
  [ -f "$d/select.txt" ] && { echo "   parking word:"; sed 's/^/   /' "$d/select.txt"; }
done
hr "d. summaries"
summaries

echo
echo "---- files: $WORK ----"
du -sh "$WORK" 2>/dev/null | sed 's/^/   /'
echo
echo "=============================================================="
echo "Finished $(stamp)."
echo "=============================================================="
