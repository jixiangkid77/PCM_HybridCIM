#!/usr/bin/env bash
# =============================================================================
# e8_4c_sram_char.sh   [run | status | stop]
#
# Experiment : P2R-E8.4c. The protected-weight SRAM macro of the manuscript
#              (OpenRAM sky130_sram_4kbytes_1rw_8x4096_8) measured by the method
#              of the address-map ROMs: flat extraction with parasitic
#              capacitance (as E8.4a-2), LVS, ngspice transients at tt, 25 C,
#              1.80 V. Measured: the energy of a read, of a clock cycle without
#              access, the static power after a read with the clock held low and
#              when not selected, the access time and the data read back.
#
# Why (2026-10-16)
#   - The manuscript's SRAM item (3.37 / 2.64 uJ per inference) is reads x
#     11.82 pJ plus 0.034 mW of leakage, both from OpenRAM's analytical model
#     ("Characterization is disabled"; claude/p2r-e8-probe1-results.md).
#     OpenRAM's sky130 technology file marks these power parameters "many values
#     are temporary" (1 nW per bitcell and per gate).
#   - The address map is now measured by post-layout simulation (E8.4b,
#     E8.6a-3); the SRAM item is measured here the same way.
#   - Sandbox (claude/p2r-e8-4c-sandbox.md): 64-byte, 256-byte and 1 KB macros
#     of the same generator; the preparation of the extracted netlist below is
#     needed for a valid simulation. With 16 words per row (the manuscript's
#     macro) OpenRAM e16d9eb lays the top-level metal-3 wire of p_en_bar
#     (precharge enable) on the metal-3 wire of the column-select line sel_7: the
#     two are one net and the macro reads wrong. scripts/e8_4c_openram_fix.py
#     generates the macro with that one wire moved (same size).
#
# Macro   : E8_OPENRAM_FIX=1 (after KID's decision): generated again with
#           scripts/e8_4c_openram_fix.py (OpenRAM's compiler with the corrected
#           route) into the work folder, from the submitted configuration
#           (<name>.py) when it is there. Otherwise the submitted macro
#           reports/12e_openram/macros/paper2_sram_pool_8x4096/ when it has the
#           layout (.gds), both netlists (.sp, .lvs.sp) and the LEF, or OpenRAM's
#           own compiler. The LEF size is compared with the submitted LEF (E8.1b:
#           477.365 x 588.130 um).
# Steps   : a. tools and files; b. the macro; b2. top-level check (magic, top cell
#           only, minutes): a column-select line joined to a control signal stops
#           the run; c. extraction (magic, flat, as the ROM flow) and its checks:
#           the errors by type (feedback listing of the cells that report
#           errors), supply shorts, negative capacitors; d. LVS (netgen, against
#           OpenRAM's LVS netlist, scripts/e8_4c_sram_tools.py lvsprep /
#           lvscheck), before the simulations: a failed LVS stops the run;
#           e. the simulations; f. results and gates.
# Netlist for the simulations (scripts/e8_4c_sram_bench.py; all counted in
#           each run's notes): the substrate node of every foundry cell and the
#           top-level substrate node to ground; the floating gates of the dummy
#           row (OpenRAM's dummy cell has its latch cut, so its pull-down gates
#           float) to ground, i.e. the dummy row as designed; special_nfet_01v8
#           written as nfet_01v8 (as the ROM runs); the transient starts from 0 V
#           with the supply on (uic), as OpenRAM's own simulations.
# Runs    : r10  10 ns clock (100 MHz, the system clock), high half a period:
#                8 writes (8 rows and 8 columns; data 00 FF 00 FF 55 AA 0F F0, so
#                that consecutive reads turn many outputs from 0 to 1), 8 reads
#                each followed by 10 ns of stopped clock (a lane's macro is
#                clocked only when it reads), the 8 reads again in consecutive
#                cycles, 3 cycles without access, 60 ns stopped (not selected),
#                1 read and 60 ns stopped.
#           r20  20 ns clock: the 8 writes, the 8 reads with stops, 2 cycles
#                without access, 60 ns stopped (timing margin; the energy if the
#                10 ns clock fails).
#           Both start with every cell resolved (initial condition; sandbox:
#           the same energies to 0.04 %).
# Gates   : fixed before the run, see claude/p2r-e8-4c-sandbox.md section 5.
#           G0 (2026-10-16, before the first complete run on KID's machine): with a
#           macro generated again, the netlists are also compared with the
#           submitted ones (as sets of subcircuits); a failed G0 stops the run.
#           Files that the submitted configuration reads from its own folder
#           (sky130_sram_common.py) are copied next to the copied configuration.
#           v4 (2026-10-16 evening, after the first run on KID's machine stopped at G2):
#           the LVS preparation gives the reference the bitcell pull-up name the layout
#           uses (scripts/e8_4c_sram_tools.py v2; KID's PDK extracts
#           sky130_fd_pr__special_pfet_pass, the sandbox PDK ..._latch); before the
#           simulations a model check (tools modelcheck) says whether the model library
#           takes every special device name of the netlist and whether the bench must
#           write ..._pfet_pass as ..._pfet_latch (--pfet-pass-alias); E8_RESUME=1.
#           v5 (2026-10-16 evening; the files of the failed LVS showed 33,153 more nets
#           in the layout than in the reference, one per bitcell: the bitcell nFET bodies,
#           which the layout netlist of KID's PDK does not name <path>/SUB): the
#           substrate node name for the bench is taken from the simulation netlist
#           (VSUBS with KID's PDK, SUB with the sandbox PDK) unless E8_SUBSTRATE is set;
#           tools v3 and bench v2 tie the bitcell bodies whatever their name.
#           v6 (2026-10-17): the simulations use a maximum time step of 50 ps (E8_TMAX; it
#           was the period / 50, 200-400 ps, coarser than the sense amplifier's latching,
#           about 0.1 ns: a sandbox proxy read wrong with it, and right with 20 ps and with
#           50 ps, the same reads and energies within 0.3 %); option E8_SENSE_PRECHARGE
#           (bench v3 --sense-precharge, simulation netlist only; KID chose it 2026-10-17).
#           v7 (2026-10-20, P2R-E8.4f): option E8_OPENRAM_SPC=1 generates the macro with
#           scripts/e8_4f_openram_spc.py: the route correction of E8_OPENRAM_FIX plus the
#           sense-side precharge (S, KID 2026-10-17) drawn in the layout: one OpenRAM column
#           precharge cell per data bit on the column multiplexer's outputs, between the
#           multiplexer and the sense amplifiers, gate on p_en_bar. G0 then means: the
#           generated netlists are the submitted ones plus exactly the sense-precharge
#           subcircuit and its instance in port_data; the LEF width is the submitted one
#           and the height not smaller (the change is reported). E8_SENSE_PRECHARGE must be
#           empty. Results go to reports/e8_rom/e8_4f and the work folder
#           /home/kid/p2r_e8/e8_4f (E8_OUT_NAME, E8_WORK): E8.4c's folders are not touched.
# Writes  : the work folder /home/kid/p2r_e8/e8_4c (macro, extraction, LVS,
#           simulations; magic and ngspice write large files, which are slow on
#           /mnt/d) and, at the end, the logs and results in reports/e8_rom/e8_4c/.
#           A run replaces both; it refuses to start while an earlier run still
#           works in the work folder. Does not change the submitted macro or
#           OpenRAM's files.
# Run     : cd /mnt/d/Project/hybrid_memory/paper2
#           E8_OPENRAM_FIX=1 bash scripts/e8_4c_sram_char.sh 2>&1 | tee reports/e8_4c_sram_char.log
#           Keep the terminal open and the computer awake.
#           E8.4f (v7): E8_OPENRAM_SPC=1 bash scripts/e8_4c_sram_char.sh 2>&1 | tee reports/e8_4f_sram_char.log
# Resume  : E8_OPENRAM_FIX=1 E8_RESUME=1 bash scripts/e8_4c_sram_char.sh 2>&1 | tee reports/e8_4c_sram_char_resume.log
#           keeps the macro, the top-level check and the extraction of the previous run and does the LVS and
#           everything after it again; the previous results folder is kept as e8_4c.before_resume_<time>.
# Status  : bash scripts/e8_4c_sram_char.sh status 2>&1 | tee reports/e8_4c_status.log
# Stop    : bash scripts/e8_4c_sram_char.sh stop
# Options : E8_OPENRAM_FIX (1: generate with scripts/e8_4c_openram_fix.py), E8_WORK,
#           E8_MAXRUN (simulations at a time; default from the available memory,
#           7 GB each, 1-3), E8_THREADS (ngspice threads per run, 1), E8_TIMEOUT
#           (0 = none), E8_HEARTBEAT (1800 s), E8_OPENRAM_PY, E8_REGENERATE (1:
#           generate the macro again even if the submitted one is complete), E8_RESUME
#           (1: continue after the extraction of the previous run), E8_TMAX (maximum
#           time step of the simulations in ns, default 0.05), E8_SENSE_PRECHARGE (pfet
#           width in um of a copy of the column precharge cell added on the inputs of every
#           sense amplifier in the simulation netlist; empty: none). For
#           testing only: E8_SRAM_DIR, E8_SRAM_NAME, E8_SRAM_WORDS, E8_SRAM_WPR,
#           E8_LEF_REF, E8_SUBSTRATE. v7: E8_OPENRAM_SPC (1: generate with
#           scripts/e8_4f_openram_spc.py), E8_OUT_NAME (results folder under reports/e8_rom;
#           default e8_4c, or e8_4f with E8_OPENRAM_SPC=1; the work folder follows it).
# =============================================================================
set -uo pipefail

MODE="${1:-run}"
PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
OPENRAM="${E8_OPENRAM:-/home/kid/openram/OpenRAM}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
NAME="${E8_SRAM_NAME:-sky130_sram_4kbytes_1rw_8x4096_8}"
SUBDIR="${E8_SRAM_DIR:-$PAPER2/reports/12e_openram/macros/paper2_sram_pool_8x4096}"
WORDS="${E8_SRAM_WORDS:-4096}"
WPR="${E8_SRAM_WPR:-16}"
LEF_REF="${E8_LEF_REF:-477.365 588.13}"
SUBSTRATE="${E8_SUBSTRATE:-}"      # empty: taken from the simulation netlist (VSUBS or SUB) before the bench
TMAX="${E8_TMAX:-0.05}"          # ns, maximum time step of the simulations (v6)
SPC="${E8_SENSE_PRECHARGE:-}"     # um, sense-side precharge in the simulation netlist (v6); empty: none
REGEN="${E8_REGENERATE:-0}"
FIX="${E8_OPENRAM_FIX:-0}"
SPCL="${E8_OPENRAM_SPC:-0}"       # v7: 1 = the sense-side precharge drawn in the layout (scripts/e8_4f_openram_spc.py)
RESUME="${E8_RESUME:-0}"
TIMEOUT="${E8_TIMEOUT:-0}"
HEARTBEAT="${E8_HEARTBEAT:-1800}"
ROOT="$PAPER2/reports/e8_rom"
OUTNAME="${E8_OUT_NAME:-$( [ "$SPCL" = "1" ] && echo e8_4f || echo e8_4c )}"   # v7
OUT="$ROOT/$OUTNAME"                           # what is kept in the project: logs, results, summaries
WORK="${E8_WORK:-/home/kid/p2r_e8/$OUTNAME}"   # Linux folder: magic and ngspice read and write large files
MAC="$WORK/macro"
BENCH="$PAPER2/scripts/e8_4_rom_bench.py"
SBENCH="$PAPER2/scripts/e8_4c_sram_bench.py"
STOOLS="$PAPER2/scripts/e8_4c_sram_tools.py"
FIXPY="$PAPER2/scripts/e8_4c_openram_fix.py"
SPCPY="$PAPER2/scripts/e8_4f_openram_spc.py"   # v7
MODELS="$PDK_ROOT_DIR/sky130A/libs.tech/ngspice/sky130.lib.spice"
MAGICRC="$PDK_ROOT_DIR/sky130A/libs.tech/magic/sky130A.magicrc"
NETGEN_SETUP="$PDK_ROOT_DIR/sky130A/libs.tech/netgen/sky130A_setup.tcl"
SELF="e8_4c_sram_char.sh"
RUNS="r10 r20"

pick_path() { ls -d $1 2>/dev/null | sort -V | tail -1; }
NGSPICE="${E8_NGSPICE:-$(pick_path "/nix/store/*-ngspice-*/bin/ngspice")}"
MAGIC="${E8_MAGIC:-$(pick_path "/nix/store/*magic-vlsi*/bin/magic")}"
NETGEN="${E8_NETGEN:-$(pick_path "/nix/store/*netgen*/bin/netgen")}"
NCORES=$(nproc 2>/dev/null || echo 4)
NTHREADS="${E8_THREADS:-1}"     # ngspice threads per run (as the ROM runs: a second thread gave only 1.18 times)

case "$WORDS$WPR$TIMEOUT$HEARTBEAT$REGEN$NTHREADS$FIX$RESUME$SPCL" in
  *[!0-9]*|"") echo "ERROR: E8_SRAM_WORDS, E8_SRAM_WPR, E8_TIMEOUT, E8_HEARTBEAT, E8_REGENERATE, E8_THREADS, E8_OPENRAM_FIX, E8_RESUME, E8_OPENRAM_SPC must be integers" >&2; exit 1 ;;
esac
[ "$FIX" = "1" ] && REGEN=1      # the corrected generator always generates the macro again
[ "$SPCL" = "1" ] && REGEN=1     # v7: so does the generator with the sense precharge (it includes the correction)
if [ "$SPCL" = "1" ] && [ -n "$SPC" ]; then
  echo "ERROR: E8_OPENRAM_SPC=1 draws the sense precharge in the layout; E8_SENSE_PRECHARGE must be empty" >&2; exit 1
fi
case "$OUTNAME" in e8_4[a-z0-9_]*) case "$OUTNAME" in *[!A-Za-z0-9_]*) OUTNAME="" ;; esac ;; *) OUTNAME="" ;; esac
[ -n "$OUTNAME" ] || { echo "ERROR: E8_OUT_NAME must start with e8_4 (letters, digits, _)" >&2; exit 1; }
case "$NAME" in *[!A-Za-z0-9_]*|"") echo "ERROR: '$NAME' is not a macro name" >&2; exit 1 ;; esac

# ---- processes of a run of this script (as the ROM scripts) ----
args01() {
  local a0="" a1=""
  { IFS= read -r -d '' a0; IFS= read -r -d '' a1; } 2>/dev/null < "/proc/$1/cmdline"
  echo "${a0##*/} ${a1##*/}"
}
is_tool() {
  local a0 a1
  read -r a0 a1 <<< "$(args01 "$1")"
  case "$a0" in
    ngspice|magic|magicdnull|magicexec|netgen|netgenexec|tclsh*|wish*) return 0 ;;
    bash|sh) case "$a1" in ngspice|magic|netgen|"$SELF") return 0 ;; esac ;;
  esac
  return 1
}
uses_config() {
  local e
  while IFS= read -r -d '' e; do
    case "$e" in "$WORK"/configs/*) return 0 ;; esac
  done 2>/dev/null < "/proc/$1/cmdline"
  return 1
}
is_mine() {
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
procs_in_work() {
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
other_runs() {
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
elapsed() {
  local d=$1 s e
  s=$(cat "$d/started" 2>/dev/null) || { echo "-"; return; }
  e=$(cat "$d/finished" 2>/dev/null || date +%s)
  printf "%dh%02dm" $(( (e - s) / 3600 )) $(( (e - s) % 3600 / 60 ))
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
progress() {
  local r X="$WORK/extract"
  echo "   progress at $(stamp):"
  if [ -f "$MAC/gen_started" ]; then
    echo "      generation : $( [ -f "$MAC/gen_finished" ] && echo "finished ($(( $(cat "$MAC/gen_finished") - $(cat "$MAC/gen_started") )) s)" || echo "running ($(( $(date +%s) - $(cat "$MAC/gen_started") )) s)")"
  fi
  if [ -f "$X/started" ]; then
    echo "      extraction : $( [ -f "$X/finished" ] && echo "finished ($(( $(cat "$X/finished") - $(cat "$X/started") )) s, magic exit $(cat "$X/magic_exit" 2>/dev/null))" || echo "running ($(( $(date +%s) - $(cat "$X/started") )) s)")"
  fi
  [ -f "$WORK/lvs/started" ] && echo "      LVS        : $( [ -f "$WORK/lvs/finished" ] && echo finished || echo running)"
  for r in $RUNS; do
    [ -f "$WORK/$r/tb_meta.json" ] && printf "      %-4s %-40s %-6s %s\n" "$r" "$(state "$WORK/$r")" "$(elapsed "$WORK/$r")" "$(reached "$WORK/$r")"
  done
}
report() {   # report RUN
  local d="$WORK/$1"
  echo; echo "---- run $1: $(state "$d"), wall time $(elapsed "$d"), ngspice exit $(cat "$d/exit_code" 2>/dev/null || echo '-') ----"
  [ -f "$d/ngspice.log" ] || { echo "   no log"; return; }
  tr '\r' '\n' < "$d/ngspice.log" | grep -iE "error|could not|unknown|singular|timestep too small|abort|E8_FAILED" \
    | sort | uniq -c | sort -rn | head -8 | sed 's/^/   log: /'
  tr '\r' '\n' < "$d/ngspice.log" | grep -iE "total analysis time" | head -1 | sed 's/^/   /'
  [ -f "$d/peak_rss_kb" ] && echo "   peak memory of ngspice: $(( $(cat "$d/peak_rss_kb") / 1024 )) MB"
  python3 "$SBENCH" analyze --dir "$d"
}

if [ "$MODE" = "status" ]; then
  echo "=============================================================="
  echo "P2R-E8.4c status, $(stamp)"
  echo "=============================================================="
  progress
  for r in $RUNS; do [ -f "$WORK/$r/tb_meta.json" ] && report "$r"; done
  exit 0
fi

if [ "$MODE" = "stop" ]; then
  echo "P2R-E8.4c stop, $(stamp)   ($WORK)"
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

T_START=$(date +%s)
echo "=============================================================="
echo "P2R-E8.4c protected-weight SRAM macro by the method of the ROMs, started $(stamp)"
echo "=============================================================="
echo "macro    : $NAME ($WORDS words, $WPR words per row); submitted folder $SUBDIR"
echo "runs     : r10 (10 ns clock), r20 (20 ns clock); tt, 25 C, 1.80 V"
echo "OpenRAM  : $OPENRAM  $(cat "$OPENRAM/VERSION" 2>/dev/null)  $(git -C "$OPENRAM" log -1 --format='%h %ad' --date=short 2>/dev/null)"
echo "ngspice  : ${NGSPICE:-<missing>}"
echo "magic    : ${MAGIC:-<missing>}"
echo "netgen   : ${NETGEN:-<missing>}"
echo "models   : $MODELS"
echo "work     : $WORK (copies of the results: $OUT)"
mkdir -p "$(dirname "$WORK")" || { echo "ERROR: cannot create $(dirname "$WORK")" >&2; exit 1; }
echo "machine  : $NCORES cores, $(free -g | awk '/Mem:/{print $2" GiB memory, "$7" GiB available"}'), $(df -h "$(dirname "$WORK")" 2>/dev/null | awk 'NR==2{print $4" free for the work folder"}')"

hr "a. tools and files"
for F in "$BENCH" "$SBENCH" "$STOOLS" "$MODELS" "$MAGICRC" "$NETGEN_SETUP"; do
  [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
[ -n "$NGSPICE" ] && [ -n "$MAGIC" ] && [ -n "$NETGEN" ] || { echo "ERROR: ngspice, magic or netgen not found" >&2; exit 1; }
grep -q "def cmd_condsum" "$BENCH" && grep -q "cs_delay" "$BENCH" \
  || { echo "ERROR: $BENCH is an older version; the one of 2026-10-12 (5) is needed" >&2; exit 1; }
[ "$FIX" = "1" ] && { [ -f "$FIXPY" ] || { echo "ERROR: E8_OPENRAM_FIX=1 but $FIXPY is missing" >&2; exit 1; }; }
[ "$SPCL" = "1" ] && { [ -f "$SPCPY" ] || { echo "ERROR: E8_OPENRAM_SPC=1 but $SPCPY is missing" >&2; exit 1; }; }
grep -q "def cmd_topshort" "$STOOLS" || { echo "ERROR: $STOOLS is an older version (no topshort, 2026-10-16 needed)" >&2; exit 1; }
for F in "$BENCH" "$SBENCH" "$STOOLS" "$FIXPY" "$SPCPY" "$PAPER2/scripts/$SELF"; do
  [ -f "$F" ] && echo "   $(md5sum "$F" | cut -c1-32)  $F"
done
echo "   OpenRAM route correction (E8_OPENRAM_FIX): $( [ "$FIX" = "1" ] && echo "on, scripts/e8_4c_openram_fix.py" || echo off)"
echo "   sense-side precharge in the layout (E8_OPENRAM_SPC, v7): $( [ "$SPCL" = "1" ] && echo "on, scripts/e8_4f_openram_spc.py (with the route correction); results $OUT" || echo off)"
"$NGSPICE" -v < /dev/null 2>&1 | grep -m1 -i "ngspice-" | sed 's/^/   /'
grep -qE "^\.lib[[:space:]]+tt([[:space:]]|$)" "$MODELS" || { echo "ERROR: the model library has no section 'tt'" >&2; exit 1; }
FREEGB=$(df -BG "$(dirname "$WORK")" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}')
MINFREE="${E8_MIN_FREE_GB:-20}"
[ -n "$FREEGB" ] && [ "$FREEGB" -lt "$MINFREE" ] && { echo "ERROR: less than $MINFREE GB free for the work folder $WORK" >&2; exit 1; }

X="$WORK/extract"
T2="$WORK/topcheck"
L="$WORK/lvs"
if [ "$RESUME" = "1" ]; then
  hr "resume (E8_RESUME=1): the macro, the top-level check and the extraction of the previous run are kept"
  for f in "$MAC/$NAME.gds" "$MAC/$NAME.sp" "$MAC/$NAME.lvs.sp" "$MAC/$NAME.lef" "$MAC/gen_finished" \
           "$X/started" "$X/finished" "$X/magic_exit" "$X/$NAME.ext" "$X/$NAME.flat_lvs.spice" "$X/$NAME.flat_pex.spice" \
           "$X/magic_extract.log"; do
    [ -s "$f" ] || { echo "ERROR: E8_RESUME=1, but $f of the previous run is missing or empty; run without E8_RESUME" >&2; exit 1; }
  done
  if [ "$FIX" = "1" ] && [ ! -s "$MAC/$NAME.e8fix.json" ]; then
    echo "ERROR: E8_RESUME=1 with E8_OPENRAM_FIX=1, but the kept macro has no $NAME.e8fix.json (not generated with the corrected route)" >&2
    exit 1
  fi
  if [ "$SPCL" = "1" ] && [ ! -s "$MAC/$NAME.e8spc.json" ]; then
    echo "ERROR: E8_RESUME=1 with E8_OPENRAM_SPC=1, but the kept macro has no $NAME.e8spc.json (not generated with the sense precharge)" >&2
    exit 1
  fi
  [ "$(cat "$X/magic_exit")" = "0" ] || { echo "ERROR: the kept extraction ended with magic exit $(cat "$X/magic_exit"); run without E8_RESUME" >&2; exit 1; }
  echo "   kept macro    : generated $(date -d @"$(cat "$MAC/gen_finished")" '+%Y-%m-%d %H:%M:%S')"
  echo "   kept extraction: $(( $(cat "$X/finished") - $(cat "$X/started") )) s, finished $(date -d @"$(cat "$X/finished")" '+%Y-%m-%d %H:%M:%S'), magic exit 0"
  if [ -d "$OUT" ]; then
    KEEP="$OUT.before_resume_$(date +%Y%m%d_%H%M%S)"
    mv "$OUT" "$KEEP" && echo "   the previous results folder is kept as $KEEP"
  fi
  rm -rf "${L:?}" "${WORK:?}/r10" "${WORK:?}/r20" "${WORK:?}/modelcheck" "${WORK:?}"/bench_r*.txt
  mkdir -p "$OUT" "$WORK"/{configs,logs} || exit 1
else
  rm -rf "${WORK:?}" "${OUT:?}"
  mkdir -p "$WORK"/{configs,logs} "$MAC" "$OUT" || exit 1
fi

hr "b. the macro"
echo "   submitted folder: $SUBDIR"
if [ -d "$SUBDIR" ]; then
  for f in "$SUBDIR"/*; do
    [ -f "$f" ] && printf "      %-48s %10s bytes  md5 %s\n" "${f##*/}" "$(stat -c %s "$f")" "$(md5sum "$f" | cut -c1-32)"
  done
else
  echo "      (not found)"
fi
if [ "$RESUME" = "1" ]; then
  SRC="kept from the previous run$( [ "$FIX" = "1" ] && echo ", generated with the corrected route")"
  echo "   the macro of the previous run is kept (E8_RESUME=1); its route correction:"
  grep -E "^E8FIX " "$WORK/logs/gen_$NAME.log" 2>/dev/null | cut -c1-260 | sed 's/^/      /'
else
SRC=""
if [ "$REGEN" = "0" ] && [ -s "$SUBDIR/$NAME.gds" ] && [ -s "$SUBDIR/$NAME.sp" ] && [ -s "$SUBDIR/$NAME.lvs.sp" ] && [ -s "$SUBDIR/$NAME.lef" ]; then
  for e in gds sp lvs.sp lef lib py; do
    [ -f "$SUBDIR/$NAME.$e" ] && cp "$SUBDIR/$NAME.$e" "$MAC/"
  done
  for f in "$SUBDIR/$NAME"_*.lib; do [ -f "$f" ] && cp "$f" "$MAC/"; done
  SRC="submitted"
  echo "   using the submitted macro (layout, both netlists and LEF are there)"
else
  if [ "$SPCL" = "1" ]; then WHY="E8_OPENRAM_SPC=1: with the sense precharge in the layout and the corrected route"
  elif [ "$FIX" = "1" ]; then WHY="E8_OPENRAM_FIX=1: with the corrected route"
  else WHY="the submitted folder lacks the layout, a netlist or the LEF, or E8_REGENERATE=1"; fi
  echo "   generating the macro again ($WHY)"
  PROBE='import numpy, scipy, sys; print("PROBE OK", sys.executable, sys.version.split()[0])'
  PY=""
  CANDS=()
  [ -n "${E8_OPENRAM_PY:-}" ] && CANDS+=("$E8_OPENRAM_PY")
  CANDS+=("$HOME/openram-venv/bin/python3" "$OPENRAM/compiler/.venv/bin/python3")
  for p in "${CANDS[@]}"; do
    [ -x "$p" ] || continue
    out=$(cd "$OPENRAM" && source ./setpaths.sh >/dev/null 2>&1 && timeout 600 "$p" -c "$PROBE" 2>&1 | grep "^PROBE OK")
    [ -n "$out" ] && { PY="$p"; echo "   OpenRAM Python: ${out#PROBE OK }"; break; }
  done
  [ -n "$PY" ] || { echo "ERROR: no Python for OpenRAM (numpy, scipy)" >&2; exit 1; }
  [ -f "$OPENRAM/sram_compiler.py" ] || { echo "ERROR: missing $OPENRAM/sram_compiler.py" >&2; exit 1; }
  CFG="$WORK/configs/$NAME.py"
  if [ -f "$SUBDIR/$NAME.py" ]; then
    echo "   configuration: the submitted $NAME.py with output_path, netlist_only = False and check_lvsdrc = False"
    grep -vE "^[[:space:]]*(output_path|netlist_only|check_lvsdrc|output_name)[[:space:]]*=" "$SUBDIR/$NAME.py" > "$CFG"
    # A configuration may read files from its own folder (OpenRAM's macro configurations include sky130_sram_common.py
    # by exec(open(os.path.join(os.path.dirname(__file__), ...)).read())). Each such file is copied next to the copied
    # configuration, from the first of: the submitted folder; the folder of the configuration the submitted macro was
    # generated from (named in its OpenRAM log); OpenRAM's macros/sram_configs. Every place is listed with the md5 of
    # its copy; G0 below compares the generated netlists with the submitted ones.
    GENCFG=""
    if [ -f "$SUBDIR/$NAME.log" ]; then
      GENCFG=$(grep -m1 -oE "Configuration file is [^[:space:]]+" "$SUBDIR/$NAME.log" | awk '{print $4}')
      echo "   OpenRAM log of the submitted macro: $(grep -m1 -oE "OpenRAM v[0-9.]+" "$SUBDIR/$NAME.log" || echo "no version line"); configuration ${GENCFG:-not named}"
    fi
    INCS=$(grep -oE "dirname\([[:space:]]*__file__[[:space:]]*\)[[:space:]]*,[[:space:]]*['\"][A-Za-z0-9_.-]+['\"]" "$SUBDIR/$NAME.py" \
             | grep -oE "['\"][A-Za-z0-9_.-]+['\"]" | tr -d "'\"" | sort -u)
    for inc in $INCS; do
      echo "   the configuration reads $inc from its own folder; copies:"
      SRCINC=""
      for c in "$SUBDIR/$inc" "${GENCFG:+$(dirname "$GENCFG")/$inc}" "$OPENRAM/macros/sram_configs/$inc"; do
        [ -n "$c" ] || continue
        if [ -f "$c" ]; then
          echo "      $c  md5 $(md5sum "$c" | cut -c1-32)"
          [ -n "$SRCINC" ] || SRCINC="$c"
        else
          echo "      $c  (not there)"
        fi
      done
      [ -n "$SRCINC" ] || { echo "ERROR: no copy of $inc, which the submitted $NAME.py reads, was found (places above)" >&2; exit 1; }
      cp -f "$SRCINC" "$WORK/configs/$inc" || exit 1
      echo "      used: $SRCINC"
      sed 's/^/         | /' "$WORK/configs/$inc"
    done
  else
    echo "   configuration: no submitted $NAME.py; the configuration of the manuscript's macro (claude/p2r-e8-4c-sandbox.md)"
    cat > "$CFG" <<EOF
word_size = 8
num_words = $WORDS
write_size = 8
num_rw_ports = 1
num_r_ports = 0
num_w_ports = 0
num_spare_cols = 1
num_spare_rows = 1
tech_name = "sky130"
nominal_corner_only = True
route_supplies = "ring"
uniquify = True
analytical_delay = True
EOF
  fi
  {
    echo "output_name = \"$NAME\""
    echo "output_path = \"$MAC/\""
    echo "netlist_only = False"
    echo "check_lvsdrc = False"
  } >> "$CFG"
  sed 's/^/      /' "$CFG"
  date +%s > "$MAC/gen_started"
  echo "   generation started at $(stamp) (sandbox, 2 cores: 1 KB 12 min; 4 KB more than 2 h, see claude/p2r-e8-4c-sandbox.md)"
  ( cd "$OPENRAM" && source ./setpaths.sh >/dev/null 2>&1 || exit 99
    [ -n "${E8_OPENRAM_PDK:-}" ] && export PDK_ROOT="$E8_OPENRAM_PDK"
    if [ "$SPCL" = "1" ]; then "$PY" -u "$SPCPY" -v "$CFG"
    elif [ "$FIX" = "1" ]; then "$PY" -u "$FIXPY" -v "$CFG"; else "$PY" -u sram_compiler.py -v "$CFG"; fi ) > "$WORK/logs/gen_$NAME.log" 2>&1
  echo "   OpenRAM exit $?, $(( $(date +%s) - $(cat "$MAC/gen_started") )) s"
  date +%s > "$MAC/gen_finished"
  grep -E "^\*\* " "$WORK/logs/gen_$NAME.log" | sed 's/^/      /' | tail -16
  grep -E "^E8FIX " "$WORK/logs/gen_$NAME.log" | cut -c1-260 | sed 's/^/      /'
  grep -E "^E8SPC " "$WORK/logs/gen_$NAME.log" | cut -c1-400 | sed 's/^/      /'
  if [ "$FIX" = "1" ] && [ "$SPCL" != "1" ] && [ ! -s "$MAC/$NAME.e8fix.json" ]; then
    echo "ERROR: the corrected compiler did not write $NAME.e8fix.json" >&2; tail -20 "$WORK/logs/gen_$NAME.log" >&2; exit 1
  fi
  if [ "$SPCL" = "1" ] && [ ! -s "$MAC/$NAME.e8spc.json" ]; then
    echo "ERROR: the compiler with the sense precharge did not write $NAME.e8spc.json" >&2; tail -20 "$WORK/logs/gen_$NAME.log" >&2; exit 1
  fi
  for e in gds sp lvs.sp lef; do
    [ -s "$MAC/$NAME.$e" ] || { echo "ERROR: the generation did not write $NAME.$e" >&2; tail -20 "$WORK/logs/gen_$NAME.log" >&2; exit 1; }
  done
  SRC=$( [ "$SPCL" = "1" ] && echo "generated with the sense precharge in the layout and the corrected route" || { [ "$FIX" = "1" ] && echo "generated with the corrected route"; } || echo "generated" )
fi
fi
echo "   files used ($SRC):"
for f in "$MAC"/*; do
  [ -f "$f" ] && printf "      %-48s md5 %s\n" "${f##*/}" "$(md5sum "$f" | cut -c1-32)"
done
LEFSIZE=$(grep -m1 -E "^\s*SIZE" "$MAC/$NAME.lef" | awk '{print $2" "$4}')
echo "   LEF size: ${LEFSIZE:-?} um; the submitted macro (E8.1b): $LEF_REF um"
G0L="FAIL"
python3 - "$LEFSIZE" "$LEF_REF" "$SPCL" <<'PY' && G0L="PASS"
import sys
a = [float(x) for x in sys.argv[1].split()]; b = [float(x) for x in sys.argv[2].split()]
if sys.argv[3] == "1":   # v7: the sense precharge may make the macro taller, never wider
    ok = len(a) == 2 and abs(a[0] - b[0]) < 0.0015 and a[1] > b[1] - 0.0015
    if len(a) == 2:
        print(f"   v7: width {a[0] - b[0]:+.3f} um, height {a[1] - b[1]:+.3f} um ({100 * (a[1] / b[1] - 1):+.3f} %), "
              f"area {100 * (a[0] * a[1] / (b[0] * b[1]) - 1):+.3f} % against the submitted macro")
    sys.exit(0 if ok else 1)
sys.exit(0 if len(a) == 2 and all(abs(x - y) < 0.0015 for x, y in zip(a, b)) else 1)
PY
G0N="SUBMITTED"
if [ "$SRC" != "submitted" ]; then
  # The generated macro must be the submitted one. OpenRAM writes the subcircuits in an order that changes from run to
  # run (sandbox: one configuration generated twice, different md5, the same lines), so the netlists are compared as
  # sets of subcircuits, comment lines left out.
  echo "   netlists generated again, against the submitted ones:"
  G0N=$(python3 - "$MAC" "$SUBDIR" "$NAME" "$SPCL" <<'PY'
import collections, hashlib, os, sys
mac, sub, name, spcl = sys.argv[1:5]

def blocks(path):
    """the netlist as a multiset: every .SUBCKT ... .ENDS block and every other line; comment and blank lines left out"""
    out, cur = [], None
    with open(path, errors="replace") as fh:
        for raw in fh:
            s = raw.rstrip()
            t = s.lstrip()
            if not t or t.startswith("*"):
                continue
            u = t.upper()
            if cur is None and u.startswith(".SUBCKT"):
                cur = [s]
            elif cur is not None:
                cur.append(s)
                if u.startswith(".ENDS"):
                    out.append("\n".join(cur))
                    cur = None
            else:
                out.append(s)
    if cur is not None:
        out.append("\n".join(cur))
    return collections.Counter(out)

def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def label(b):
    w = b.split("\n", 1)[0].split()
    return w[1] if len(w) > 1 and w[0].upper() == ".SUBCKT" else b[:60]

def logical(b):
    """the lines of a block with the '+' continuations joined"""
    out = []
    for ln in b.split("\n"):
        t = ln.strip()
        if t.startswith("+") and out:
            out[-1] += " " + t[1:].strip()
        else:
            out.append(t)
    return out

def spc_diff(only_a, only_b):
    """v7: the generated netlist must be the submitted one plus exactly the sense precharge: a new subcircuit
    <name>_sense_precharge_array_0 (one instance of the column precharge cell of the main precharge array per data bit,
    on bl_<i>, br_<i>, en_bar, vdd) and, in port_data, one instance of it on bl_out_<i>, br_out_<i>, p_en_bar, vdd"""
    msgs = []
    a = {label(k): k for k in only_a}
    b = {label(k): k for k in only_b}
    spc = [k for k in a if k.endswith("_sense_precharge_array_0")]
    pd = [k for k in a if k.endswith("_port_data")]
    if not (len(only_a) == 2 and len(only_b) == 1 and len(spc) == 1 and len(pd) == 1 and list(b) == pd):
        return False, [f"blocks only in the generated one: {sorted(a)}; only in the submitted one: {sorted(b)}"]
    new, old = logical(a[pd[0]]), logical(b[pd[0]])
    inst = [ln for ln in new if ln.split()[0].lower().startswith("xsense_precharge_array")]
    rest = [ln for ln in new if ln not in inst]
    if len(inst) != 1 or rest != old:
        return False, [f"port_data: {len(inst)} sense-precharge instances; the other lines {'equal' if rest == old else 'DIFFERENT'}"]
    w = inst[0].split()
    nets, cell = w[1:-1], w[-1]
    nbit = (len(nets) - 2) // 2
    want = [x for i in range(nbit) for x in (f"bl_out_{i}", f"br_out_{i}")] + ["p_en_bar", "vdd"]
    if cell != spc[0] or nets != want:
        return False, [f"port_data instance: {inst[0][:200]}"]
    body = logical(a[spc[0]])
    ports = body[0].split()[2:]
    insts = [ln.split() for ln in body[1:] if ln.upper().startswith("X")]
    cells = {x[-1] for x in insts}
    main = [k for k, v in (ca.items()) if label(k).endswith("_precharge_array") and v]
    main_cells = {ln.split()[-1] for k in main for ln in logical(k)[1:] if ln.upper().startswith("X")}
    ok = (ports == [x for i in range(nbit) for x in (f"bl_{i}", f"br_{i}")] + ["en_bar", "vdd"]
          and len(insts) == nbit and len(cells) == 1 and cells <= main_cells
          and all(x[1:-1] == [f"bl_{i}", f"br_{i}", "en_bar", "vdd"] for i, x in enumerate(insts)))
    msgs.append(f"sense precharge: {nbit} cells of {sorted(cells)} (the main precharge array uses {sorted(main_cells)}); "
                f"port_data = the submitted port_data plus its instance on bl_out_*, br_out_*, p_en_bar, vdd")
    return ok, msgs

verdicts = []
for ext in ("sp", "lvs.sp"):
    a, b = os.path.join(mac, f"{name}.{ext}"), os.path.join(sub, f"{name}.{ext}")
    if not (os.path.isfile(a) and os.path.isfile(b)):
        print(f"{name}.{ext}: not compared (the {'generated' if not os.path.isfile(a) else 'submitted'} file is missing)")
        verdicts.append("NOT COMPARED")
        continue
    ma, mb = md5(a), md5(b)
    ca, cb = blocks(a), blocks(b)
    nsub = sum(v for k, v in ca.items() if k.lstrip().upper().startswith(".SUBCKT"))
    if ma == mb:
        print(f"{name}.{ext}: identical ({nsub} subcircuits, md5 {ma})")
        verdicts.append("SAME")
    elif ca == cb:
        print(f"{name}.{ext}: the same {nsub} subcircuits in another order (md5 generated {ma}, submitted {mb})")
        verdicts.append("SAME")
    elif spcl == "1":
        only_a, only_b = ca - cb, cb - ca
        ok, msgs = spc_diff(only_a, only_b)
        print(f"{name}.{ext}: {'the submitted netlist plus the sense precharge' if ok else 'DIFFERENT from the submitted netlist plus the sense precharge'}")
        for m_ in msgs:
            print("   " + m_)
        verdicts.append("SAME PLUS SENSE PRECHARGE" if ok else "DIFFERENT")
    else:
        only_a, only_b = ca - cb, cb - ca
        print(f"{name}.{ext}: DIFFERENT: {sum(only_a.values())} blocks only in the generated netlist, "
              f"{sum(only_b.values())} only in the submitted one")
        for tag, c in (("generated", only_a), ("submitted", only_b)):
            names = sorted(label(k) for k in c)[:8]
            if names:
                print(f"   only in the {tag} one: " + ", ".join(names))
        verdicts.append("DIFFERENT")
print("DIFFERENT" if "DIFFERENT" in verdicts else "NOT COMPARED" if "NOT COMPARED" in verdicts
      else "SAME PLUS SENSE PRECHARGE" if "SAME PLUS SENSE PRECHARGE" in verdicts else "SAME")
PY
)
  echo "$G0N" | sed '$d' | sed 's/^/      /'
  G0N=$(echo "$G0N" | tail -1)
  [ "$G0N" = "NOT COMPARED" ] && echo "   WARNING: the netlists could not be compared; G0 rests on the LEF size alone"
fi
G0="FAIL"
if [ "$SPCL" = "1" ]; then   # v7
  [ "$G0L" = "PASS" ] && case "$G0N" in "SAME PLUS SENSE PRECHARGE"|"NOT COMPARED") true ;; *) false ;; esac && G0="PASS"
  echo "   G0 (v7: the macro of the manuscript plus the sense precharge): $G0 (LEF width equal, height not smaller: $G0L; netlists: $G0N)"
else
[ "$G0L" = "PASS" ] && case "$G0N" in SUBMITTED|SAME|"NOT COMPARED") true ;; *) false ;; esac && G0="PASS"
echo "   G0 (the macro of the manuscript): $G0 (LEF size equal: $G0L; netlists: $G0N)"
fi
if [ "$G0" != "PASS" ]; then
  echo "ERROR: G0 failed: this is not the macro of the manuscript; no extraction or simulation (send this log)" >&2
  for f in "$WORK"/logs/* "$MAC"/*.lef "$MAC"/*.e8fix.json; do [ -f "$f" ] && cp -f "$f" "$OUT/"; done
  mkdir -p "$OUT/configs" && cp -f "$WORK"/configs/* "$OUT/configs/" 2>/dev/null
  exit 1
fi
for f in "$MAC"/*.lib; do
  [ -f "$f" ] && python3 "$STOOLS" libvals --lib "$f" | sed 's/^/   OpenRAM analytical values, /'
done

hr "b2. top-level check (magic, top cell only): a column-select line joined to a control signal"
mkdir -p "$T2"
if [ "$RESUME" = "1" ] && [ -s "$T2/$NAME.ext" ] && [ "$(cat "$T2/magic_exit" 2>/dev/null || echo 0)" = "0" ]; then
  echo "   the top-level extraction of the previous run is kept: $T2/$NAME.ext (its magic exit code is in the previous log)"
else
cat > "$T2/top.tcl" <<EOF
drc off
gds flatten true
gds ordering true
gds read $MAC/$NAME.gds
load $NAME
select top cell
extract no all
extract cell $NAME
quit -noprompt
EOF
t0=$(date +%s)
( cd "$T2" && PDK_ROOT="$PDK_ROOT_DIR" timeout 7200 "$MAGIC" -dnull -noconsole -rcfile "$MAGICRC" < top.tcl > magic_top.log 2>&1 )
MX=$?
echo "$MX" > "$T2/magic_exit"
echo "   magic exit $MX, $(( $(date +%s) - t0 )) s$( [ "$MX" = "124" ] && echo " (cut by the time limit)")"
fi
G1T="NOT JUDGED"
if [ -s "$T2/$NAME.ext" ]; then
  python3 "$STOOLS" topshort --ext "$T2/$NAME.ext" --json "$T2/topshort.json" | cut -c1-600 | sed 's/^/   /'
  G1T=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['verdict'])" "$T2/topshort.json" 2>/dev/null || echo "NOT JUDGED")
fi
echo "   G1t (no column-select line joined to a control signal at the top level): $G1T"
if [ "$G1T" = "SHORT" ]; then
  echo "ERROR: the macro has the short of OpenRAM's control route with a column-select line (claude/p2r-e8-4c-sandbox.md);" >&2
  echo "       it cannot be measured as it is. After KID's decision: E8_OPENRAM_FIX=1 bash scripts/$SELF (send this log)" >&2
  cp -f "$T2/topshort.json" "$OUT/" 2>/dev/null
  exit 1
fi
[ "$G1T" = "NO SHORT OF THIS KIND" ] || echo "   WARNING: the top-level check could not judge; the LVS below decides"

hr "c. extraction (magic, flat; LVS netlist without and simulation netlist with parasitic capacitance)"
mkdir -p "$X"
if [ "$RESUME" = "1" ]; then
  echo "   the extraction of the previous run is kept: $X ($(( $(cat "$X/finished") - $(cat "$X/started") )) s, magic exit $(cat "$X/magic_exit"))"
  PEAK=0
else
cat > "$X/extract.tcl" <<EOF
drc off
gds flatten true
gds ordering true
gds read $MAC/$NAME.gds
load $NAME
select top cell
expand
readspice $MAC/$NAME.sp
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
ext2spice -o $X/$NAME.flat_lvs.spice
ext2spice cthresh 0
ext2spice -o $X/$NAME.flat_pex.spice
quit -noprompt
EOF
date +%s > "$X/started"
echo "   started at $(stamp) (sandbox: see claude/p2r-e8-4c-sandbox.md)"
( cd "$X" && PDK_ROOT="$PDK_ROOT_DIR" "$MAGIC" -dnull -noconsole -rcfile "$MAGICRC" < extract.tcl > magic_extract.log 2>&1
  echo $? > magic_exit ) &
MPID=$!
PEAK=0
LAST=$(date +%s)
while kill -0 "$MPID" 2>/dev/null; do
  r=$(ps -o rss= --ppid "$MPID" 2>/dev/null | sort -n | tail -1)
  [ -n "${r// /}" ] && [ "$r" -gt "$PEAK" ] && PEAK=$r
  if [ $(( $(date +%s) - LAST )) -ge "$HEARTBEAT" ]; then
    echo "   ... extraction running, $(( ($(date +%s) - $(cat "$X/started")) / 60 )) min"; LAST=$(date +%s)
  fi
  sleep 10
done
date +%s > "$X/finished"
echo "   magic exit $(cat "$X/magic_exit"), $(( $(cat "$X/finished") - $(cat "$X/started") )) s, peak memory about $((PEAK / 1024)) MB"
fi
grep -iE "error|fatal|could not|not found|shorted" "$X/magic_extract.log" \
    | grep -v "boundary was redefined" | sort | uniq -c | sort -rn | head -8 | sed 's/^/   log: /'
XE=$(grep -m1 -oE "Total of [0-9]+ errors" "$X/magic_extract.log" | grep -oE "[0-9]+")
echo "   extraction errors: ${XE:-0}"
G1X="PASS"
if [ -n "$XE" ]; then
  ECELLS=$(grep -E "^[A-Za-z0-9_]+: [0-9]+ errors" "$X/magic_extract.log" | sed 's/:.*//' | sort -u)
  echo "   cells that report errors: $(echo $ECELLS)"
  {
    echo "drc off"; echo "gds flatten true"; echo "gds ordering true"; echo "gds read $MAC/$NAME.gds"
    for c in $ECELLS; do
      echo "load $c"; echo "select top cell"; echo "expand"; echo "extract do local"; echo "extract all"
      echo 'set n [feedback count]'
      echo 'for {set i 1} {$i <= $n} {incr i} { feedback find $i }'
      echo "feedback clear"
    done
    echo "quit -noprompt"
  } > "$X/feedback.tcl"
  ( cd "$X" && PDK_ROOT="$PDK_ROOT_DIR" timeout 7200 "$MAGIC" -dnull -noconsole -rcfile "$MAGICRC" < feedback.tcl > feedback.log 2>&1 )
  python3 "$STOOLS" fbclass --log "$X/feedback.log" --expect "$XE" | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" = "0" ] || G1X="FAIL"
fi
python3 "$BENCH" shorts --ext "$X/$NAME.ext" 2>&1 | grep -v '^{' | sed 's/^/   /'
SHORTS=$(python3 "$BENCH" shorts --ext "$X/$NAME.ext" 2>/dev/null | grep '^{' | python3 -c "import json,sys; print(len(json.load(sys.stdin)['supply_shorts']))" 2>/dev/null || echo 1)
[ -s "$X/$NAME.flat_lvs.spice" ] && python3 "$BENCH" probe --sp "$X/$NAME.flat_lvs.spice" --top "$NAME" 2>&1 \
    | grep -E "^(devices|capacitors)" | sed 's/^/   LVS netlist: /'
NEG=1
if [ -s "$X/$NAME.flat_pex.spice" ]; then
  PROBE=$(python3 "$BENCH" probe --sp "$X/$NAME.flat_pex.spice" --top "$NAME" 2>&1)
  echo "$PROBE" | grep -E "^(devices|capacitors|negative)" | sed 's/^/   simulation netlist: /'
  NEG=$(echo "$PROBE" | grep '^{' | python3 -c "import json,sys; print(json.load(sys.stdin)['caps_negative'])" 2>/dev/null || echo 1)
fi
G1="FAIL"
[ "$G1X" = "PASS" ] && [ "$SHORTS" = "0" ] && [ "$NEG" = "0" ] && [ -s "$X/$NAME.flat_pex.spice" ] && G1="PASS"
echo "   G1 (extraction: errors only of the known foundry-cell type, no supply short, no negative capacitor): $G1"
[ "$G1" = "PASS" ] || { echo "ERROR: G1 failed; no simulation (send this log)" >&2; exit 1; }

hr "d. LVS (netgen, against OpenRAM's LVS netlist; preparation in scripts/e8_4c_sram_tools.py)"
rm -rf "${L:?}"
mkdir -p "$L"
python3 "$STOOLS" lvsprep --layout "$X/$NAME.flat_lvs.spice" --ref "$MAC/$NAME.lvs.sp" --out "$L" | sed 's/^/   /'
date +%s > "$L/started"
echo "   started at $(stamp)"
( cd "$L" && "$NETGEN" -batch lvs "layout.spice $NAME" "reference.spice $NAME" "$NETGEN_SETUP" \
      lvs_report.txt > netgen.log 2>&1; date +%s > finished )
echo "   LVS: $(( $(cat "$L/finished") - $(cat "$L/started") )) s"
grep -E "^Circuit 1 contains|^Circuit 2 contains|Final result" "$L/netgen.log" | tail -4 | sed 's/^/      /'
G2="FAIL"
python3 "$STOOLS" lvscheck --report "$L/lvs_report.txt" --log "$L/netgen.log" --json "$L/lvscheck.json" && G2="PASS"
echo "   G2 (LVS: counts equal, differences only the known ones): $G2"
if [ "$G2" != "PASS" ]; then
  echo "ERROR: G2 failed; no simulation (send this log)" >&2
  for f in "$L/netgen.log" "$L/lvsprep.json" "$L/lvscheck.json" "$X/magic_extract.log" "$X/feedback.log"; do [ -f "$f" ] && cp -f "$f" "$OUT/"; done
  gzip -c "$L/lvs_report.txt" > "$OUT/lvs_report.txt.gz" 2>/dev/null
  exit 1
fi

hr "e. simulations (r10, r20; tt, 25 C, 1.80 V)"
SEQS=$(python3 - "$WORDS" "$WPR" <<'PY'
import sys
words, wpr = int(sys.argv[1]), int(sys.argv[2])
rows = words // wpr
# 8 words in 8 different rows and 8 different columns; the data alternate so that consecutive reads turn many
# outputs from 0 to 1 (the read failure of the sandbox macros, claude/p2r-e8-4c-sandbox.md section 2, item 8)
rc = [(0, 0), (rows - 1, wpr - 1), (rows // 2, wpr // 2 - 1), (rows // 4, wpr // 2), (1, 3 % wpr),
      (3 * rows // 4, (wpr * 3) // 4), (rows // 8, 1 % wpr), (7 * rows // 8, wpr - 2)]
addrs = []
for r, c in rc:
    a = (r % rows) * wpr + (c % wpr)
    if a not in addrs:
        addrs.append(a)
data = [0x00, 0xFF, 0x00, 0xFF, 0x55, 0xAA, 0x0F, 0xF0][:len(addrs)]
w = " ".join(f"w:{a}:{d:02x}" for a, d in zip(addrs, data))
gated = " ".join(f"r:{a} s:10" for a in addrs)
b2b = " ".join(f"r:{a}" for a in addrs)
print("R10", f"i i {w} i {gated} {b2b} i i i s:60 r:{addrs[1]} s:60")
print("R20", f"i i {w} i {gated} i i s:60")
PY
)
SEQ_R10=$(echo "$SEQS" | sed -n 's/^R10 //p')
SEQ_R20=$(echo "$SEQS" | sed -n 's/^R20 //p')
echo "   r10 sequence: $SEQ_R10"
echo "   r20 sequence: $SEQ_R20"
# the global substrate node of the simulation netlist (v5): magic names it after the PDK's tech file (KID's PDK:
# VSUBS, the sandbox PDK: SUB); whole-token counts in the netlist, the larger one is tied to ground by the bench
if [ -z "$SUBSTRATE" ]; then
  SUBC=$(awk '{for (i = 2; i <= NF; i++) { if ($i == "VSUBS") v++; else if ($i == "SUB") s++ }} END {printf "%d %d", v, s}' "$X/$NAME.flat_pex.spice")
  read -r NV NS <<< "$SUBC"
  if [ "$NV" -gt 0 ] || [ "$NS" -gt 0 ]; then
    if [ "$NV" -ge "$NS" ]; then SUBSTRATE="VSUBS"; else SUBSTRATE="SUB"; fi
  fi
  echo "   substrate node of the simulation netlist: ${SUBSTRATE:-none found} (whole-token counts: VSUBS $NV, SUB $NS)"
  [ -n "$SUBSTRATE" ] || echo "   WARNING: no VSUBS or SUB node in the simulation netlist; no global substrate node is tied (check the bench notes)"
else
  echo "   substrate node (E8_SUBSTRATE): $SUBSTRATE"
fi
BOPTS="--sanitize --tie-cell-sub ${SUBSTRATE:+--substrate $SUBSTRATE} --tie-float-gates --plain-nfet --uic --ic-cells --threads $NTHREADS"
BOPTS="$BOPTS --tmax $TMAX"
echo "   maximum time step of the simulations: $TMAX ns (v6; the period / 50 was too coarse for the sense amplifier)"
if [ -n "$SPC" ]; then
  BOPTS="$BOPTS --sense-precharge $SPC"
  echo "   sense-side precharge (E8_SENSE_PRECHARGE, simulation netlist only, not in the layout): pfet W = $SPC um"
fi
# the special SRAM device names of the simulation netlist against the model library (v4): one-device ngspice decks
MCJ="$WORK/modelcheck/modelcheck.json"
python3 "$STOOLS" modelcheck --sp "$X/$NAME.flat_pex.spice" --models "$MODELS" --corner tt --ngspice "$NGSPICE" \
    --dir "$WORK/modelcheck" --json "$MCJ" --plain-nfet | cut -c1-1200 | sed 's/^/   /'
MCV=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['verdict'] + (' alias' if d['pfet_pass_alias'] else ''))" "$MCJ" 2>/dev/null || echo "NO RESULT")
case "$MCV" in
  "OK alias")
    BOPTS="$BOPTS --pfet-pass-alias"
    echo "   model check: OK with --pfet-pass-alias (the library takes the bitcell pull-ups only as sky130_fd_pr__special_pfet_latch)" ;;
  "OK")
    echo "   model check: OK (the library takes every special device name of the netlist as it is)" ;;
  *)
    echo "ERROR: model check: $MCV; the model library does not take every special device name of the netlist; no simulation (send this log)" >&2
    cp -f "$MCJ" "$OUT/" 2>/dev/null
    exit 1 ;;
esac
# saved for diagnosis: the control signals and both inputs of every sense amplifier
PROBES="__s_en0,__p_en_bar0,__wl_en0,__w_en0,__rbl_bl_0_0,sense_amp_array_0__b[lr]_[0-9]+"
for r in $RUNS; do
  case "$r" in r10) per=10; seq="$SEQ_R10" ;; r20) per=20; seq="$SEQ_R20" ;; esac
  python3 "$SBENCH" bench --sp "$X/$NAME.flat_pex.spice" --top "$NAME" --models "$MODELS" --corner tt \
      --out "$WORK/$r" --seq "$seq" --period "$per" $BOPTS --probe "$PROBES" > "$WORK/bench_$r.txt" 2>&1 \
    || { echo "ERROR: bench $r not written:"; tail -5 "$WORK/bench_$r.txt"; exit 1; }
  sed 's/^/   '"$r"': /' "$WORK/bench_$r.txt"
done
FG=$(grep -o "floating gates (nets that reach transistors only through gates: [0-9]*, in [^)]*)" "$WORK/bench_r10.txt" | head -1)
FGOTHER=$(echo "$FG" | sed 's/.*, in //; s/)$//' | tr ',' '\n' | grep -v "dummy" | grep "[a-z]")
if [ -n "$FGOTHER" ]; then
  G1B="FAIL"; echo "   WARNING: floating gates outside the dummy cells: $FGOTHER"
else
  G1B="PASS"
fi
echo "   G1b (the floating gates tied to ground are all in the dummy cells): $G1B"
# memory: about 1.4 GB for the 1 KB test macro (72,000 devices) in the sandbox, so about 6 GB per run for 4 KB;
# runs start while the available memory allows (7 GB each), at least one
AVAIL_GB=$(free -g | awk '/Mem:/{print $7}')
MAXRUN="${E8_MAXRUN:-$(( AVAIL_GB / 7 ))}"
[ "$MAXRUN" -ge 1 ] 2>/dev/null || MAXRUN=1
[ "$MAXRUN" -le 3 ] || MAXRUN=3
echo "   available memory $AVAIL_GB GiB: at most $MAXRUN simulation(s) at a time"
start_run() {
  local r=$1 d="$WORK/$1"
  date +%s > "$d/started"
  (
    cd "$d" || exit 99
    if [ "$TIMEOUT" -gt 0 ]; then timeout "$TIMEOUT" "$NGSPICE" -b tb.sp > ngspice.log 2>&1
    else "$NGSPICE" -b tb.sp > ngspice.log 2>&1; fi
    echo $? > exit_code
    date +%s > finished
  ) &
  echo $! > "$d/pid"
  echo "   started $r at $(stamp)"
}
LAST=$(date +%s)
while :; do
  alive=0 queued=""
  for r in $RUNS; do
    d="$WORK/$r"
    if [ ! -f "$d/pid" ]; then queued="$queued $r"; continue; fi
    if kill -0 "$(cat "$d/pid")" 2>/dev/null; then
      alive=$((alive + 1))
      m=$(ps -o rss= --ppid "$(cat "$d/pid")" 2>/dev/null | sort -n | tail -1)
      p=$(cat "$d/peak_rss_kb" 2>/dev/null || echo 0)
      [ -n "${m// /}" ] && [ "$m" -gt "$p" ] && echo "$m" > "$d/peak_rss_kb"
    fi
  done
  for r in $queued; do
    [ "$alive" -lt "$MAXRUN" ] || break
    start_run "$r"; alive=$((alive + 1))
  done
  [ "$alive" -gt 0 ] || break
  if [ $(( $(date +%s) - LAST )) -ge "$HEARTBEAT" ]; then progress; LAST=$(date +%s); fi
  sleep 20
done
hr "f. results"
echo "   G2 LVS (step d): $G2"
for r in $RUNS; do report "$r"; done
python3 - "$WORK" "$G0" "$G1" "$G2" "$G1B" "$G1T" "$SPCL" "${LEFSIZE:-}" <<'PY'
import json, os, sys
work, g0, g1, g2, g1b, g1t, spcl, lefsize = sys.argv[1:9]
res = {}
for r in ("r10", "r20"):
    p = os.path.join(work, r, "result.json")
    res[r] = json.load(open(p)) if os.path.isfile(p) else None
def S(r, k, d=None):
    return (res[r] or {}).get("summary", {}).get(k, d)
ok = lambda r: res[r] is not None and S(r, "complete") and S(r, "reads") and S(r, "reads_ok") == S(r, "reads")
done = all(res[r] is not None and S(r, "complete") for r in ("r10", "r20"))
g3 = "PASS" if (done and S("r20", "reads") and S("r20", "reads_ok") >= 0.9 * S("r20", "reads")) else "FAIL"
f1 = sum(len(S(r, "wrong_bits", []) or []) for r in ("r10", "r20") if res[r] is not None)
f2 = "yes" if ok("r10") else "no"
# F2b: every gated read of r10 correct at the end of its stopped segment (the lane's clock gated after the read; the data
# sampled two system cycles after the rising edge)
f2b = "yes" if (res["r10"] is not None and S("r10", "reads_gated") and
                S("r10", "reads_ok_after_stop") == S("r10", "reads_gated")) else "no"
print()
print("P2R-E8.4c summary" + (" (v7, E8.4f: the sense-side precharge drawn in the layout)" if spcl == "1" else ""))
if spcl == "1":
    print(f"   G0 the macro of the manuscript plus the sense precharge (netlists; LEF width equal, height {lefsize} um): {g0}")
else:
    print(f"   G0 macro of the manuscript (LEF size; with a macro generated again also the netlists): {g0}")
print(f"   G1t top-level check (no column-select line joined to a control signal): {g1t}")
print(f"   G1 extraction: {g1}; G1b floating gates only in the dummy cells: {g1b}")
print(f"   G2 LVS: {g2}")
print(f"   G3 both simulations complete, at least 90 % of the reads correct with a 20 ns clock: {g3}")
print(f"   F1 wrong bits in the two runs: {f1}")
print(f"   F2 every read correct with the 10 ns clock (the system clock), r10: {f2}")
print(f"   F2b every gated read of r10 correct at the end of its 10 ns stop (data within two system cycles): {f2b}")
for r in ("r10", "r20"):
    if res[r] is None:
        print(f"   {r}: no result"); continue
    s = res[r]["summary"]
    print(f"   {r}: reads {s['reads_ok']}/{s['reads']} correct at the end of the cycle, {s.get('reads_ok_at_half')} at the falling edge; "
          f"read cycle {s['E_read_pJ_mean']:.3f} pJ (min {s['E_read_pJ_min']:.3f}, max {s['E_read_pJ_max']:.3f}); "
          f"gated read {s.get('E_read_gated_pJ')}; cycle without access {s['E_idle_pJ_mean']:.3f} pJ; "
          f"stopped after a read {s.get('P_stop_after_read_uW')} uW, after cycles without access {s.get('P_stop_after_idle_uW')} uW; "
          f"access time up to {s['t_acc_ns_max']} ns; gated reads correct at the end of the stop "
          f"{s.get('reads_ok_after_stop')}/{s.get('reads_gated')}, access time up to {s.get('t_acc_gated_ns_max')} ns")
    cyc = res[r]["cycles"]
    b2b = [c["E_vdd_pJ"] for i, c in enumerate(cyc) if c["kind"] == "read" and i > 0 and cyc[i - 1]["kind"] == "read"]
    if b2b:
        print(f"   {r}: reads in consecutive cycles (after a read): {len(b2b)}, {sum(b2b) / len(b2b):.3f} pJ "
              f"(min {min(b2b):.3f}, max {max(b2b):.3f})")
for r in ("r10", "r20"):
    if res[r] is None:
        continue
    wb = S(r, "wrong_bits", []) or []
    if wb:
        n01 = sum(1 for w in wb if w.get("prev_bit") == 0 and w.get("expected") == 1)
        print(f"   {r}: {len(wb)} wrong bits, {n01} of them read 0 where the previous read of that output gave 0 and 1 was "
              f"expected: " + "; ".join(f"k{w['k']} addr {w['addr']} bit {w['bit']} (previous read addr {w['prev_addr']}, "
                                         f"bit {w['prev_bit']})" for w in wb[:12]))
print("   OpenRAM analytical values used by the manuscript: 11.81819 pJ per access, 0.034375 mW leakage")
json.dump({"G0": g0, "G1t": g1t, "G1": g1, "G1b": g1b, "G2": g2, "G3": g3, "F1_wrong_bits": f1, "F2_reads_ok_at_10ns": f2,
           "F2b_gated_reads_ok_within_two_cycles": f2b, "layout_sense_precharge": spcl == "1", "lef_size_um": lefsize,
           "summary": {r: (res[r] or {}).get("summary") for r in res}}, open(os.path.join(work, "e8_4c_summary.json"), "w"), indent=1)
PY
# keep the logs and results in the project (the netlists and waveforms stay in the work folder)
for f in "$MAC"/*.lef "$MAC"/*.py "$MAC"/*.lib "$MAC"/*.e8fix.json "$MAC"/*.e8spc.json "$WORK"/logs/* "$T2/topshort.json" "$T2/magic_top.log" \
         "$X/magic_extract.log" "$X/feedback.log" "$X/extract.tcl" \
         "$L/netgen.log" "$L/lvsprep.json" "$L/lvscheck.json" "$WORK/e8_4c_summary.json" "$WORK"/bench_*.txt \
         "$WORK/modelcheck/modelcheck.json"; do
  [ -f "$f" ] && cp -f "$f" "$OUT/"
done
gzip -c "$L/lvs_report.txt" > "$OUT/lvs_report.txt.gz" 2>/dev/null
mkdir -p "$OUT/configs" && cp -f "$WORK"/configs/* "$OUT/configs/" 2>/dev/null
for r in $RUNS; do
  mkdir -p "$OUT/$r"
  for f in tb.sp tb_meta.json result.json ngspice.log tb_out.txt exit_code peak_rss_kb; do
    [ -f "$WORK/$r/$f" ] && cp -f "$WORK/$r/$f" "$OUT/$r/"
  done
done
echo
echo "copied the logs and results to $OUT ($(du -sh "$OUT" 2>/dev/null | cut -f1)); work folder $WORK ($(du -sh "$WORK" 2>/dev/null | cut -f1))"
echo "finished $(stamp), $(( ($(date +%s) - T_START) / 60 )) min; send the log of this run (reports/$( [ "$SPCL" = "1" ] && echo e8_4f || echo e8_4c )_sram_char*.log)"
