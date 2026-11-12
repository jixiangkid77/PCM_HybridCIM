#!/usr/bin/env bash
# =============================================================================
# e10_1_bank_char.sh   [run | status | stop]
#
# Experiment : P2R-E10.1. One bank of the banked protected-weight pool of E10.0
#              (25 single-port banks of 128 words of 8 bit, rtl/e10/sram_bank_128x8.v)
#              as an OpenRAM macro, measured by the method of the 4-KB macro (E8.4c,
#              E8.4f): flat extraction with the capacitance of every net, LVS, ngspice
#              transients at tt, 25 C, 1.80 V with the r10 and r20 sequences. This
#              script is scripts/e8_4c_sram_char.sh (v7) for a macro that has no
#              submitted copy; the simulation flow (b2 to f) is that script's.
#
# Why (2026-11-10)
#   - E10.0 (scripts/e10_0_banked_sram.sh): the pool as 25 banks, bank = pool
#     address mod 25, row = address div 25, reads every datapath step without a
#     conflict, and the full inference of both models gives the E8.5e files byte
#     for byte. Each bank is read at most once in 14 cycles (the E8.5 traces), so
#     its clock is gated after each read as the 4-KB macro's: the gated read of r10
#     is the access of the system.
#   - The 4-KB macro (16 words per row, 257 rows) needed two fixes: the route
#     correction (p_en_bar on the wire of sel_7) and the sense-side precharge S.
#     The bank has 4 words per row (4 select lines) and 33 rows. Measured here:
#     variant F, the route correction only (scripts/e8_4c_openram_fix.py; it
#     changes no wire when no control signal runs in the band of the select lines,
#     and its log says which it moved), and variant S, the route correction and S
#     drawn in the layout (scripts/e8_4f_openram_spc.py, the macro of the paper).
#   - The library energy of the bank for the comparison of V-D: the netlist-only
#     generation with the 6.89-fF load of the 4-KB library and with the
#     compiler's default loads (as reports/12e_openram/lib_20260608 and
#     lib_default_loads), variant F only.
#
# Macro   : sky130_sram_128bytes_1rw_8x128_8: the configuration of the 4-KB macro
#           (reports/e8_rom/e8_4f/configs/: write_size 8, 1 rw port, 1 spare column,
#           1 spare row, sky130_sram_common.py) with num_words 128 and
#           words_per_row 4 (the compiler's own choice for this size, written so
#           that the bench addresses follow it): 32 rows x 32 columns.
# Steps   : a. tools and files; b. the macro, its organization, route log and
#           layout extent (magic, as E8.1b); b1. the bank's timing library
#           (netlist only; variant F); b2. top-level
#           check; c. extraction; d. LVS; e. simulations r10 and r20 (the sequences
#           of E8.4c for 128 words and 4 words per row); f. results and gates.
# Gates   : written before the run (protocol P2R-E10.1 of 2026-11-10):
#           G0 the compiler wrote the layout, both netlists and the LEF, its log
#           gives 4 words per row and 32 x 32, the route log is there; variant S
#           also: its netlists are variant F's plus exactly the sense precharge,
#           LEF width equal to F's, height not smaller. G1t, G1, G1b, G2, G3, F1, F2,
#           F2b as E8.4c (F2b: every gated read of r10 correct at the end of its
#           10-ns stop, the read of the system).
# Variants: E8_OPENRAM_SPC=0 (default): F, results reports/e10/e10_1f, work folder
#           /home/kid/p2r_e10/e10_1f. E8_OPENRAM_SPC=1: S, reports/e10/e10_1s,
#           /home/kid/p2r_e10/e10_1s; needs variant F's macro (E10_F_MACRO, default
#           /home/kid/p2r_e10/e10_1f/macro). scripts/e10_1_run.sh runs F, S and the
#           conditions of the chosen variant.
# Writes  : the work folder of the variant and, at the end, the logs and results
#           in its reports/e10/ folder. A run replaces both; it refuses to start
#           while an earlier run still works in the work folder. Nothing outside
#           these two folders is changed.
# Run     : cd /mnt/d/Project/hybrid_memory/paper2
#           bash scripts/e10_1_run.sh 2>&1 | tee reports/e10_1_run.log
#           (one variant alone: bash scripts/e10_1_bank_char.sh 2>&1 | tee reports/e10_1f_bank_char.log)
# Resume  : E8_RESUME=1 keeps the macro, the top-level check and the extraction of
#           the previous run of the variant and does the LVS and everything after it.
# Status  : bash scripts/e10_1_bank_char.sh status      (E8_OPENRAM_SPC=1 for S)
# Stop    : bash scripts/e10_1_bank_char.sh stop        (E8_OPENRAM_SPC=1 for S)
# Options : E8_OPENRAM_SPC (0 F, 1 S), E8_WORK, E10_F_MACRO, E8_MAXRUN, E8_THREADS,
#           E8_TIMEOUT, E8_HEARTBEAT, E8_OPENRAM_PY, E8_RESUME, E8_TMAX (0.05 ns),
#           E8_MIN_FREE_GB (5). For testing only: E8_SRAM_NAME, E8_SRAM_WORDS,
#           E8_SRAM_WPR, E8_SUBSTRATE, E10_COMMON, E8_PAPER2, E8_OPENRAM, E8_PDK.
# Runtime : estimated from the 64-byte test macro of E8.4c (a 2-core test machine:
#           10 min with the extraction kept) and the 4-KB runs on this machine:
#           generation a few minutes, extraction about 5-15 min, LVS about 1 min,
#           r10 and r20 together about 10-40 min; one variant about 30-60 min.
# =============================================================================
set -uo pipefail

MODE="${1:-run}"
PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
OPENRAM="${E8_OPENRAM:-/home/kid/openram/OpenRAM}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
NAME="${E8_SRAM_NAME:-sky130_sram_128bytes_1rw_8x128_8}"
WORDS="${E8_SRAM_WORDS:-128}"
WPR="${E8_SRAM_WPR:-4}"
COMMON="${E10_COMMON:-$PAPER2/reports/e8_rom/e8_4f/configs/sky130_sram_common.py}"   # include of the 4-KB macro's configuration
SUBSTRATE="${E8_SUBSTRATE:-}"      # empty: taken from the simulation netlist (VSUBS or SUB) before the bench
TMAX="${E8_TMAX:-0.05}"          # ns, maximum time step of the simulations (v6)
SPC=""                            # E10.1: no sense precharge in the simulation netlist only (variant S draws it in the layout)
REGEN=1                           # E10.1: the macro is always generated
FIX=1                             # E10.1: always with the route correction (variant S's generator includes it)
SPCL="${E8_OPENRAM_SPC:-0}"       # 0: variant F; 1: variant S, the sense-side precharge drawn in the layout
RESUME="${E8_RESUME:-0}"
TIMEOUT="${E8_TIMEOUT:-0}"
HEARTBEAT="${E8_HEARTBEAT:-1800}"
case "$SPCL" in 0|1) ;; *) echo "ERROR: E8_OPENRAM_SPC must be 0 (variant F) or 1 (variant S)" >&2; exit 1 ;; esac
VAR=$( [ "$SPCL" = "1" ] && echo S || echo F )
ROOT="$PAPER2/reports/e10"
OUTNAME=$( [ "$SPCL" = "1" ] && echo e10_1s || echo e10_1f )
OUT="$ROOT/$OUTNAME"                           # what is kept in the project: logs, results, summaries
WORK="${E8_WORK:-/home/kid/p2r_e10/$OUTNAME}"  # Linux folder: magic and ngspice read and write large files
FMAC="${E10_F_MACRO:-/home/kid/p2r_e10/e10_1f/macro}"   # variant F's macro: the reference of variant S's G0
MAC="$WORK/macro"
BENCH="$PAPER2/scripts/e8_4_rom_bench.py"
SBENCH="$PAPER2/scripts/e8_4c_sram_bench.py"
STOOLS="$PAPER2/scripts/e8_4c_sram_tools.py"
FIXPY="$PAPER2/scripts/e8_4c_openram_fix.py"
SPCPY="$PAPER2/scripts/e8_4f_openram_spc.py"   # v7
MODELS="$PDK_ROOT_DIR/sky130A/libs.tech/ngspice/sky130.lib.spice"
MAGICRC="$PDK_ROOT_DIR/sky130A/libs.tech/magic/sky130A.magicrc"
NETGEN_SETUP="$PDK_ROOT_DIR/sky130A/libs.tech/netgen/sky130A_setup.tcl"
SELF="e10_1_bank_char.sh"
RUNS="r10 r20"

pick_path() { ls -d $1 2>/dev/null | sort -V | tail -1; }
NGSPICE="${E8_NGSPICE:-$(pick_path "/nix/store/*-ngspice-*/bin/ngspice")}"
MAGIC="${E8_MAGIC:-$(pick_path "/nix/store/*magic-vlsi*/bin/magic")}"
NETGEN="${E8_NETGEN:-$(pick_path "/nix/store/*netgen*/bin/netgen")}"
NCORES=$(nproc 2>/dev/null || echo 4)
NTHREADS="${E8_THREADS:-1}"     # ngspice threads per run (as the ROM runs: a second thread gave only 1.18 times)

case "$WORDS$WPR$TIMEOUT$HEARTBEAT$NTHREADS$RESUME" in
  *[!0-9]*|"") echo "ERROR: E8_SRAM_WORDS, E8_SRAM_WPR, E8_TIMEOUT, E8_HEARTBEAT, E8_THREADS, E8_RESUME must be integers" >&2; exit 1 ;;
esac
case "$WPR" in 2|4|8|16) ;; *) echo "ERROR: E8_SRAM_WPR must be 2, 4, 8 or 16 (a column multiplexer)" >&2; exit 1 ;; esac
[ $((WORDS % WPR)) -eq 0 ] && [ $((WORDS / WPR)) -ge 16 ] \
  || { echo "ERROR: E8_SRAM_WORDS must be a multiple of E8_SRAM_WPR with at least 16 rows" >&2; exit 1; }
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
  echo "P2R-E10.1 status, variant $VAR, $(stamp)"
  echo "=============================================================="
  progress
  for r in $RUNS; do [ -f "$WORK/$r/tb_meta.json" ] && report "$r"; done
  exit 0
fi

if [ "$MODE" = "stop" ]; then
  echo "P2R-E10.1 stop, variant $VAR, $(stamp)   ($WORK)"
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
echo "P2R-E10.1 SRAM bank macro, variant $VAR, by the method of the 4-KB macro (E8.4c, E8.4f), started $(stamp)"
echo "=============================================================="
echo "macro    : $NAME ($WORDS words, $WPR words per row), generated here; variant $VAR: $( [ "$SPCL" = "1" ] && echo "route correction and sense precharge in the layout" || echo "route correction only")"
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
[ "$FIX" = "1" ] && { [ -f "$FIXPY" ] || { echo "ERROR: missing $FIXPY (the route correction)" >&2; exit 1; }; }
[ "$SPCL" = "1" ] && { [ -f "$SPCPY" ] || { echo "ERROR: E8_OPENRAM_SPC=1 but $SPCPY is missing" >&2; exit 1; }; }
grep -q "def cmd_topshort" "$STOOLS" || { echo "ERROR: $STOOLS is an older version (no topshort, 2026-10-16 needed)" >&2; exit 1; }
for F in "$BENCH" "$SBENCH" "$STOOLS" "$FIXPY" "$SPCPY" "$PAPER2/scripts/$SELF"; do
  [ -f "$F" ] && echo "   $(md5sum "$F" | cut -c1-32)  $F"
done
echo "   route correction: on ($( [ "$SPCL" = "1" ] && echo "inside scripts/e8_4f_openram_spc.py" || echo "scripts/e8_4c_openram_fix.py"))"
echo "   sense-side precharge in the layout (E8_OPENRAM_SPC): $( [ "$SPCL" = "1" ] && echo "on, scripts/e8_4f_openram_spc.py: variant S" || echo "off: variant F")"
echo "   results $OUT; work folder $WORK"
[ -f "$COMMON" ] || { echo "ERROR: missing $COMMON (the include of the 4-KB macro's configuration, E8.4f)" >&2; exit 1; }
echo "   $(md5sum "$COMMON" | cut -c1-32)  $COMMON (include of the configuration)"
if [ "$SPCL" = "1" ]; then
  for f in "$FMAC/$NAME.sp" "$FMAC/$NAME.lvs.sp" "$FMAC/$NAME.lef"; do
    [ -s "$f" ] || { echo "ERROR: variant S needs variant F's macro: missing $f (run variant F first; E10_F_MACRO)" >&2; exit 1; }
  done
  echo "   variant F's macro, the reference of G0: $FMAC"
fi
"$NGSPICE" -v < /dev/null 2>&1 | grep -m1 -i "ngspice-" | sed 's/^/   /'
grep -qE "^\.lib[[:space:]]+tt([[:space:]]|$)" "$MODELS" || { echo "ERROR: the model library has no section 'tt'" >&2; exit 1; }
FREEGB=$(df -BG "$(dirname "$WORK")" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}')
MINFREE="${E8_MIN_FREE_GB:-5}"
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
  if [ "$FIX" = "1" ] && [ "$SPCL" != "1" ] && [ ! -s "$MAC/$NAME.e8fix.json" ]; then
    echo "ERROR: E8_RESUME=1, but the kept macro of variant F has no $NAME.e8fix.json (not generated with the corrected route)" >&2
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

bank_cfg() {   # bank_cfg FILE: the configuration of the 4-KB macro (E8.4f) with num_words and words_per_row of the bank
  cat > "$1" <<EOF
# P2R-E10.1: one bank of the banked protected-weight pool (rtl/e10/sram_bank_128x8.v)
# the configuration of the manuscript's 4-KB macro (reports/e8_rom/e8_4f/configs/) with num_words and words_per_row
word_size = 8
num_words = $WORDS
words_per_row = $WPR
human_byte_size = "{:.0f}bytes".format((word_size * num_words)/8)
write_size = 8
num_rw_ports = 1
num_r_ports = 0
num_w_ports = 0
ports_human = '1rw'
num_spare_cols = 1
num_spare_rows = 1

import os
exec(open(os.path.join(os.path.dirname(__file__), 'sky130_sram_common.py')).read())
EOF
  cp -f "$COMMON" "$(dirname "$1")/sky130_sram_common.py"
}

hr "b. the macro"
echo "   a new macro, no submitted copy; variant $VAR"
if [ "$RESUME" = "1" ]; then
  SRC="kept from the previous run$( [ "$FIX" = "1" ] && echo ", generated with the corrected route")"
  echo "   the macro of the previous run is kept (E8_RESUME=1); its route correction:"
  grep -E "^E8FIX " "$WORK/logs/gen_$NAME.log" 2>/dev/null | cut -c1-260 | sed 's/^/      /'
else
SRC=""
if :; then
  if [ "$SPCL" = "1" ]; then WHY="variant S: the sense precharge in the layout and the route correction, scripts/e8_4f_openram_spc.py"
  else WHY="variant F: the route correction, scripts/e8_4c_openram_fix.py"; fi
  echo "   generating the macro ($WHY)"
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
  echo "   configuration: that of the 4-KB macro (reports/e8_rom/e8_4f/configs/) with num_words $WORDS and words_per_row $WPR"
  bank_cfg "$CFG" || exit 1
  {
    echo "output_name = \"$NAME\""
    echo "output_path = \"$MAC/\""
    echo "netlist_only = False"
    echo "check_lvsdrc = False"
  } >> "$CFG"
  sed 's/^/      /' "$CFG"
  date +%s > "$MAC/gen_started"
  echo "   generation started at $(stamp) (2-core test machine: 1 KB 12 min; the 4-KB macro on this machine 52-64 min)"
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
echo "   LEF size: ${LEFSIZE:-?} um"
ORG=$(python3 - "$WORK/logs/gen_$NAME.log" "$WORDS" "$WPR" <<'PY'
import re, sys
log, words, wpr = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
t = open(log, errors="replace").read()
rows, cols = words // wpr, wpr * 8
m1 = re.findall(r"Set SRAM Words Per Row=(\d+)", t)
m2 = re.findall(r"Rows: (\d+) Cols: (\d+)", t)
ok = bool(m1) and int(m1[-1]) == wpr and bool(m2) and (int(m2[-1][0]), int(m2[-1][1])) == (rows, cols)
print(f"   organization in the OpenRAM log: words per row {m1[-1] if m1 else '?'}, rows x columns "
      f"{' x '.join(m2[-1]) if m2 else '?'} (configured {wpr}, {rows} x {cols}; plus the spare row and column)")
print("PASS" if ok else "FAIL")
PY
)
echo "$ORG" | sed '$d'
G0O=$(echo "$ORG" | tail -1)
RJ="$MAC/$NAME.$( [ "$SPCL" = "1" ] && echo e8spc || echo e8fix ).json"
G0R=$(python3 - "$RJ" "$SPCL" "$WPR" <<'PY'
import json, os, sys
p, spcl, wpr = sys.argv[1], sys.argv[2], int(sys.argv[3])
if not os.path.isfile(p):
    print(f"   no route log {os.path.basename(p)}")
    print("FAIL")
    sys.exit()
d = json.load(open(p))
routes = d.get("routes_e8fix" if spcl == "1" else "routes", [])
for r in routes:
    print(f"   route of {r['signal']}: pin at {r['pin_y_um']} um, band of the {r['select_lines']} select lines {r['band_um']} um: "
          + (f"MOVED to {r.get('new_y_um')} um" if r.get("moved") else "not moved"))
ok = len(routes) > 0 and all(r.get("select_lines") == wpr for r in routes)
print(f"   route correction: {sum(1 for r in routes if r.get('moved'))} of {len(routes)} control signals moved")
if spcl == "1":
    cells = [x for x in d.get("sense_precharge", []) if "cells" in x]
    for x in cells:
        print(f"   sense precharge: {x['cells']} cells at columns {x['columns']} ({x['words_per_row']} words per row)")
    ok = ok and len(cells) == 1 and cells[0]["cells"] == 8 and cells[0]["columns"] == [b * wpr for b in range(8)]
print("PASS" if ok else "FAIL")
PY
)
echo "$G0R" | sed '$d'
G0R=$(echo "$G0R" | tail -1)
G0L="-"
G0N="-"
if [ "$SPCL" = "1" ]; then
  LEF_REF=$(grep -m1 -E "^\s*SIZE" "$FMAC/$NAME.lef" | awk '{print $2" "$4}')
  echo "   variant F's LEF size: ${LEF_REF:-?} um"
  G0L="FAIL"
  python3 - "$LEFSIZE" "$LEF_REF" <<'PY' && G0L="PASS"
import sys
a = [float(x) for x in sys.argv[1].split()]
b = [float(x) for x in sys.argv[2].split()]
ok = len(a) == 2 and len(b) == 2 and abs(a[0] - b[0]) < 0.0015 and a[1] > b[1] - 0.0015
if len(a) == 2 and len(b) == 2:
    print(f"   against variant F: width {a[0] - b[0]:+.3f} um, height {a[1] - b[1]:+.3f} um ({100 * (a[1] / b[1] - 1):+.3f} %), "
          f"area {100 * (a[0] * a[1] / (b[0] * b[1]) - 1):+.3f} %")
sys.exit(0 if ok else 1)
PY
  echo "   netlists of variant S against those of variant F (the reference):"
G0N=$(python3 - "$MAC" "$FMAC" "$NAME" "$SPCL" <<'PY'
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
    """v7: the generated netlist must be the reference one plus exactly the sense precharge: a new subcircuit
    <name>_sense_precharge_array_0 (one instance of the column precharge cell of the main precharge array per data bit,
    on bl_<i>, br_<i>, en_bar, vdd) and, in port_data, one instance of it on bl_out_<i>, br_out_<i>, p_en_bar, vdd"""
    msgs = []
    a = {label(k): k for k in only_a}
    b = {label(k): k for k in only_b}
    spc = [k for k in a if k.endswith("_sense_precharge_array_0")]
    pd = [k for k in a if k.endswith("_port_data")]
    if not (len(only_a) == 2 and len(only_b) == 1 and len(spc) == 1 and len(pd) == 1 and list(b) == pd):
        return False, [f"blocks only in the generated one: {sorted(a)}; only in the reference one: {sorted(b)}"]
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
                f"port_data = the reference port_data plus its instance on bl_out_*, br_out_*, p_en_bar, vdd")
    return ok, msgs

verdicts = []
for ext in ("sp", "lvs.sp"):
    a, b = os.path.join(mac, f"{name}.{ext}"), os.path.join(sub, f"{name}.{ext}")
    if not (os.path.isfile(a) and os.path.isfile(b)):
        print(f"{name}.{ext}: not compared (the {'generated' if not os.path.isfile(a) else 'reference'} file is missing)")
        verdicts.append("NOT COMPARED")
        continue
    ma, mb = md5(a), md5(b)
    ca, cb = blocks(a), blocks(b)
    nsub = sum(v for k, v in ca.items() if k.lstrip().upper().startswith(".SUBCKT"))
    if ma == mb:
        print(f"{name}.{ext}: identical ({nsub} subcircuits, md5 {ma})")
        verdicts.append("SAME")
    elif ca == cb:
        print(f"{name}.{ext}: the same {nsub} subcircuits in another order (md5 generated {ma}, reference {mb})")
        verdicts.append("SAME")
    elif spcl == "1":
        only_a, only_b = ca - cb, cb - ca
        ok, msgs = spc_diff(only_a, only_b)
        print(f"{name}.{ext}: {'the reference netlist plus the sense precharge' if ok else 'DIFFERENT from the reference netlist plus the sense precharge'}")
        for m_ in msgs:
            print("   " + m_)
        verdicts.append("SAME PLUS SENSE PRECHARGE" if ok else "DIFFERENT")
    else:
        only_a, only_b = ca - cb, cb - ca
        print(f"{name}.{ext}: DIFFERENT: {sum(only_a.values())} blocks only in the generated netlist, "
              f"{sum(only_b.values())} only in the reference one")
        for tag, c in (("generated", only_a), ("reference", only_b)):
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
fi
G0="FAIL"
if [ "$SPCL" = "1" ]; then
  [ "$G0O" = "PASS" ] && [ "$G0R" = "PASS" ] && [ "$G0L" = "PASS" ] && [ "$G0N" = "SAME PLUS SENSE PRECHARGE" ] && G0="PASS"
  echo "   G0 (variant S: organization $G0O; route and sense-precharge log $G0R; LEF against F $G0L; netlists against F: $G0N): $G0"
else
  [ "$G0O" = "PASS" ] && [ "$G0R" = "PASS" ] && G0="PASS"
  echo "   G0 (variant F: organization $G0O; route log $G0R): $G0"
fi
if [ "$G0" != "PASS" ]; then
  echo "ERROR: G0 failed: the macro is not the bank as configured; no extraction or simulation (send this log)" >&2
  for f in "$WORK"/logs/* "$MAC"/*.lef "$MAC"/*.e8fix.json "$MAC"/*.e8spc.json; do [ -f "$f" ] && cp -f "$f" "$OUT/"; done
  mkdir -p "$OUT/configs" && cp -f "$WORK"/configs/* "$OUT/configs/" 2>/dev/null
  exit 1
fi
for f in "$MAC"/*.lib; do
  [ -f "$f" ] && python3 "$STOOLS" libvals --lib "$f" | sed 's/^/   OpenRAM analytical values (layout generation), /'
done
# layout extent of the GDS top cell, by the method of E8.1b (magic: select top cell, box); E8.1b found the LEF of the
# 4-KB and 5-KB SRAM macros equal to it
mkdir -p "$WORK/extent"
printf 'gds read %s\nload %s\nselect top cell\nbox\nquit -noprompt\n' "$MAC/$NAME.gds" "$NAME" > "$WORK/extent/box.tcl"
( cd "$WORK/extent" && PDK_ROOT="$PDK_ROOT_DIR" timeout 900 "$MAGIC" -dnull -noconsole -rcfile "$MAGICRC" < box.tcl > box.log 2>&1 )
BOXL=$(grep -m1 "^microns:" "$WORK/extent/box.log")
echo "   layout extent of the GDS top cell (magic, as E8.1b): ${BOXL:-NO BOX FROM MAGIC, see $WORK/extent/box.log}; LEF ${LEFSIZE:-?} um"

if [ "$SPCL" != "1" ] && [ "$RESUME" != "1" ]; then
  hr "b1. the bank's timing library: netlist only, with the 6.89-fF load of the 4-KB library (l689) and the default loads (ldef)"
  for LV in l689 ldef; do
    D="$WORK/libgen_$LV"
    rm -rf "${D:?}"
    mkdir -p "$D/configs" "$D/out" || exit 1
    C="$D/configs/$NAME.py"
    bank_cfg "$C" || exit 1
    {
      [ "$LV" = "ldef" ] && echo "use_specified_load_slew = None"
      echo "output_name = \"$NAME\""
      echo "output_path = \"$D/out/\""
      echo "netlist_only = True"
      echo "check_lvsdrc = False"
    } >> "$C"
    ( cd "$OPENRAM" && source ./setpaths.sh >/dev/null 2>&1 || exit 99
      [ -n "${E8_OPENRAM_PDK:-}" ] && export PDK_ROOT="$E8_OPENRAM_PDK"
      timeout 3600 "$PY" -u sram_compiler.py -v "$C" ) > "$D/gen.log" 2>&1
    RC=$?
    echo "   $LV: OpenRAM exit $RC; $(grep -m1 -oE "Loads: \[[^]]*\]" "$D/gen.log" || echo "no Loads line"); $(grep -m1 -oE "Dynamic Power: [0-9.eE+-]+ mW" "$D/gen.log" || echo "no Dynamic Power line"); $(grep -m1 -oE "Leakage Power: [0-9.eE+-]+ mW" "$D/gen.log" || echo "no Leakage Power line")"
    for f in "$D"/out/*.lib; do
      [ -f "$f" ] && python3 "$STOOLS" libvals --lib "$f" | sed "s/^/   $LV: /"
    done
    mkdir -p "$OUT/libgen_$LV"
    cp -f "$D/gen.log" "$C" "$D/configs/sky130_sram_common.py" "$OUT/libgen_$LV/" 2>/dev/null
    for f in "$D"/out/*.lib "$D"/out/*.log "$D"/out/*.py; do [ -f "$f" ] && cp -f "$f" "$OUT/libgen_$LV/"; done
  done
fi

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
  echo "ERROR: a column-select line is joined to a control signal at the top level although the route correction was on;" >&2
  echo "       the macro cannot be measured as it is (send this log)" >&2
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
echo "   started at $(stamp)"
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
# outputs from 0 to 1 (the read failure of the small test macros of E8.4c)
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
# the global substrate node of the simulation netlist (v5): magic names it after the PDK's tech file (my PDK:
# VSUBS, another PDK install: SUB); whole-token counts in the netlist, the larger one is tied to ground by the bench
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
# memory: about 1.4 GB for the 1 KB test macro (72,000 devices) on a test machine, so less for the 128-byte bank;
# runs start while the available memory allows (2 GB each), at least one
AVAIL_GB=$(free -g | awk '/Mem:/{print $7}')
MAXRUN="${E8_MAXRUN:-$(( AVAIL_GB / 2 ))}"
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
print("P2R-E10.1 summary, variant " + ("S (route correction and sense precharge in the layout)" if spcl == "1" else
                                       "F (route correction only)"))
if spcl == "1":
    print(f"   G0 the bank as configured, variant F's netlists plus the sense precharge, LEF width of F's ({lefsize} um): {g0}")
else:
    print(f"   G0 the bank as configured (organization in the compiler's log, route log; LEF {lefsize} um): {g0}")
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
# the read of the system (E8.4f: 86.48 pJ, 85.38 to 90.09, r10): the gated reads whose previous access was also a read,
# the 2nd to 8th of the eight gated reads (the first follows the writes, the ninth idle cycles)
sysr = {}
for r in ("r10", "r20"):
    g = S(r, "E_read_gated_pJ", []) or []
    if len(g) >= 8:
        sel = g[1:8]
        sysr[r] = {"mean": sum(sel) / len(sel), "min": min(sel), "max": max(sel), "n": len(sel)}
        print(f"   {r}: gated reads after a read (the read of the system): {sysr[r]['mean']:.3f} pJ "
              f"({sysr[r]['min']:.3f} to {sysr[r]['max']:.3f}, {len(sel)} reads)")
json.dump({"G0": g0, "G1t": g1t, "G1": g1, "G1b": g1b, "G2": g2, "G3": g3, "F1_wrong_bits": f1, "F2_reads_ok_at_10ns": f2,
           "F2b_gated_reads_ok_within_two_cycles": f2b, "layout_sense_precharge": spcl == "1", "lef_size_um": lefsize,
           "variant": "S" if spcl == "1" else "F", "system_read_pJ": sysr,
           "summary": {r: (res[r] or {}).get("summary") for r in res}}, open(os.path.join(work, "e10_1_summary.json"), "w"), indent=1)
PY
# keep the logs and results in the project (the netlists and waveforms stay in the work folder)
for f in "$MAC"/*.lef "$MAC"/*.py "$MAC"/*.lib "$MAC"/*.e8fix.json "$MAC"/*.e8spc.json "$WORK"/logs/* "$T2/topshort.json" "$T2/magic_top.log" \
         "$X/magic_extract.log" "$X/feedback.log" "$X/extract.tcl" \
         "$L/netgen.log" "$L/lvsprep.json" "$L/lvscheck.json" "$WORK/e10_1_summary.json" "$WORK"/bench_*.txt "$WORK/extent/box.log" \
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
echo "finished $(stamp), $(( ($(date +%s) - T_START) / 60 )) min (variant $VAR)"
