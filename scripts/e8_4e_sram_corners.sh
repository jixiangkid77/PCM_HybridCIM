#!/usr/bin/env bash
# =============================================================================
# e8_4e_sram_corners.sh   [run | status | stop]
#
# Experiment : P2R-E8.4e, SRAM part. Energy of the protected-weight SRAM macro
#              (4 KB, sense-side precharge drawn in the layout: E8.4f) at five
#              further conditions, tt -40 C, tt 85 C, ff 25 C, ss 25 C and
#              ff 85 C (all 1.80 V), and at tt 25 C as the reference of the same
#              sequence; whether the two-cycle read still gives the right word.
# Why        : the paper's SRAM energy is at tt, 25 C, 1.80 V only (E8.4f);
#              resubmission plan, section 5.2 (adopted 2026-10-19 21:34). The
#              ROM part is scripts/e8_4e_rom_corners.sh.
#
# Method (claude/p2r-e8-4e-sram-sandbox.md)
#   - the extracted netlist and the bench options of E8.4f, no new generation
#     or extraction: E8.4f's r10 deck is written again here with the options
#     rebuilt from E8.4f's files and must come out identical (P2)
#   - sequence (scripts/e8_4e_sram_tools.py seq): the 2 cycles without access
#     and the first 5 writes of r10, 1 cycle without access, 4 gated reads
#     (read, then the clock stopped for 10 ns, as r10) of the first 4 written
#     words, 1 read of the fifth followed by a 60 ns stop (static power after
#     a read): 242.5 ns, against 522.5 ns for r10
#   - maximum time step of E8.4f (50 ps); one ngspice run per condition
#
# Steps      : 0 files, tools and E8.4f's gates (P0); 1 options and the check
#              of E8.4f's deck (P2); 2 for each condition: model check at its
#              corner (P1), deck, netlist copy identical to E8.4f's (P3);
#              3 runs, at most E8_MAXRUN at a time (7 GB each) in the order of
#              E8_CONDS, each analysed when it finishes; 4 gates and results
#              (scripts/e8_4e_sram_tools.py compare), copied to
#              reports/e8_rom/e8_4e_sram
# Rules      : written before the run in claude/p2r-e8-4e-sram-sandbox.md
# Files      : scripts/e8_4e_sram_corners.sh, scripts/e8_4e_sram_tools.py (both
#              NEW); uses e8_4c_sram_bench.py v3, e8_4c_sram_tools.py v3 and
#              e8_4_rom_bench.py (all unchanged)
# Needs      : E8.4f finished and valid: /home/kid/p2r_e8/e8_4f with extract/,
#              modelcheck/, r10/ and e8_4c_summary.json (G0-G3 PASS, F2b yes)
# Writes     : the work folder /home/kid/p2r_e8/e8_4e_sram and
#              reports/e8_rom/e8_4e_sram/
# Run        : cd /mnt/d/Project/hybrid_memory/paper2
#              bash scripts/e8_4e_sram_corners.sh 2>&1 | tee reports/e8_4e_sram_corners.log
#              A second run keeps the finished conditions and redoes the others.
# Status     : bash scripts/e8_4e_sram_corners.sh status
# Stop       : bash scripts/e8_4e_sram_corners.sh stop
# Options    : E8_CONDS (corner:temperature, default "tt:25 ss:25 ff:85 tt:85
#              tt:-40 ff:25", run in this order), E8_MAXRUN (default from the
#              available memory, 7 GB per run, 1-3), E8_HEARTBEAT (1800 s),
#              E8_SRC_WORK (E8.4f's work folder), E8_WORK; testing only:
#              E8_SRAM_NAME, E8_NW (5), E8_PDK, E8_NGSPICE, E8_PAPER2, E8_MEM_GB
# Runtime    : 6 runs; each about 5-6 h with 3 at a time (E8.4c resume3: r10,
#              522.5 ns, 10 h 19 min with 2 at a time), so about 10-12 h in two
#              rounds, or about 15 h in three if only 2 fit in memory. The first
#              round (tt 25, ss 25, ff 85) can be analysed on its own. Disk: one
#              netlist copy per condition (the size of E8.4f's r10/netlist.sp).
# =============================================================================
set -uo pipefail

MODE="${1:-run}"
PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
NAME="${E8_SRAM_NAME:-sky130_sram_4kbytes_1rw_8x4096_8}"
SRC="${E8_SRC_WORK:-/home/kid/p2r_e8/e8_4f}"
WORK="${E8_WORK:-/home/kid/p2r_e8/e8_4e_sram}"
CONDS="${E8_CONDS:-tt:25 ss:25 ff:85 tt:85 tt:-40 ff:25}"
NW="${E8_NW:-5}"
HEARTBEAT="${E8_HEARTBEAT:-1800}"
MEMGB="${E8_MEM_GB:-7}"     # GB per 4-KB simulation (E8.4c: 7.14 GB peak); testing only
ROOT="$PAPER2/reports/e8_rom"
OUT="$ROOT/e8_4e_sram"
SBENCH="$PAPER2/scripts/e8_4c_sram_bench.py"
STOOLS="$PAPER2/scripts/e8_4c_sram_tools.py"
ETOOLS="$PAPER2/scripts/e8_4e_sram_tools.py"
RBENCH="$PAPER2/scripts/e8_4_rom_bench.py"
MODELS="$PDK_ROOT_DIR/sky130A/libs.tech/ngspice/sky130.lib.spice"
SELF=e8_4e_sram_corners.sh
PROBES="__s_en0,__p_en_bar0,__wl_en0,__w_en0,__rbl_bl_0_0,sense_amp_array_0__b[lr]_[0-9]+"   # as E8.4f
pick_path() { ls -d $1 2>/dev/null | sort -V | tail -1; }
NGSPICE="${E8_NGSPICE:-$(pick_path "/nix/store/*-ngspice-*/bin/ngspice")}"
NCORES=$(nproc 2>/dev/null || echo 4)
stamp() { date "+%Y-%m-%d %H:%M:%S"; }
hr() { echo; echo "########## $* ##########"; }
tag_of() {   # tt:-40 -> c_tt_m40
  local c=${1%%:*} t=${1#*:}
  case "$t" in -*) echo "c_${c}_m${t#-}" ;; *) echo "c_${c}_${t}" ;; esac
}

# ---- processes (guard, status, stop); ended only by PID ----
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
other_runs() {   # other running instances of this script in run mode (not their subshells)
  local p a0 a1 a2 all="" st pp
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    a0="" a1="" a2=""
    { IFS= read -r -d '' a0; IFS= read -r -d '' a1; IFS= read -r -d '' a2; } 2>/dev/null < "/proc/$p/cmdline"
    case "${a0##*/}" in bash|sh) ;; *) continue ;; esac
    [ "${a1##*/}" = "$SELF" ] || continue
    case "$a2" in ""|run) ;; *) continue ;; esac
    is_mine "$p" || all="$all $p"
  done
  for p in $all; do
    { read -r st < "/proc/$p/stat"; } 2>/dev/null || continue
    st=${st##*) }
    set -- $st
    pp=${2:-}
    case " $all " in *" $pp "*) ;; *) echo "$p" ;; esac
  done
}
sims_in_work() {   # ngspice processes working in $WORK
  local p c a0
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    c=$(readlink "/proc/$p/cwd" 2>/dev/null) || continue
    case "$c" in "$WORK"/*) ;; *) continue ;; esac
    a0=""
    { IFS= read -r -d '' a0; } 2>/dev/null < "/proc/$p/cmdline"
    [ "${a0##*/}" = ngspice ] && echo "$p"
  done
}
state() {   # state DIR
  local d=$1
  if [ -f "$d/skip" ]; then echo "SKIPPED ($(cat "$d/skip"))"
  elif [ -f "$d/exit_code" ]; then
    if [ "$(cat "$d/exit_code")" = 0 ] && [ -f "$d/tb_done" ] && [ ! -f "$d/tb_failed" ]; then echo "finished"
    elif [ -f "$d/stopped" ]; then echo "stopped by the stop command"
    else echo "FAILED (ngspice exit $(cat "$d/exit_code"))"; fi
  elif [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null; then echo "running"
  elif [ -f "$d/pid" ]; then echo "stopped before the end"
  elif [ -f "$d/tb.sp" ]; then echo "written"
  else echo "not written"; fi
}
elapsed() {   # wall time of a run so far or in all
  local d=$1 a b
  [ -f "$d/started" ] || { echo "-"; return; }
  a=$(cat "$d/started"); b=$(cat "$d/finished" 2>/dev/null || date +%s)
  printf "%dh%02dm" $(( (b - a) / 3600 )) $(( (b - a) % 3600 / 60 ))
}
reached() {   # simulated time reached (the last checkpoint written by the deck)
  local d=$1 x
  [ -f "$d/ngspice.log" ] || { echo ""; return; }
  [ -f "$d/tb_done" ] && { echo "complete"; return; }
  x=$(tr '\r' '\n' < "$d/ngspice.log" | grep -o "segment ending at [0-9.]* ns" | tail -1 | grep -o "[0-9.]* ns")
  [ -n "$x" ] && echo "reached $x of $(python3 -c "import json,sys; print(round(json.load(open(sys.argv[1]))['tstop'] * 1e9, 1))" "$d/tb_meta.json" 2>/dev/null) ns"
}
peak_rss() { local d=$1; [ -f "$d/peak_rss_kb" ] && echo "$(( $(cat "$d/peak_rss_kb") / 1024 )) MB" || echo "-"; }

if [ "$MODE" = "status" ]; then
  echo "P2R-E8.4e SRAM corners, status at $(stamp)   ($WORK)"
  R=$(other_runs | tr '\n' ' ')
  echo "   script: ${R:-not running}"
  for c in $CONDS; do
    d="$WORK/$(tag_of "$c")"
    printf "   %-8s %-40s %-7s %-9s %s\n" "$c" "$(state "$d")" "$(elapsed "$d")" "$(peak_rss "$d")" "$(reached "$d")"
  done
  if [ -f "$ETOOLS" ] && [ -f "$SRC/r10/result.json" ] && ls "$WORK"/c_*/result.json > /dev/null 2>&1; then
    echo
    python3 "$ETOOLS" compare --work "$WORK" --ref-r10 "$SRC/r10" --ref-modelcheck "$SRC/modelcheck/modelcheck.json" \
      --rb "$RBENCH" --conds "$CONDS" --nw "$NW" 2>&1 | tail -40
  fi
  exit 0
fi

if [ "$MODE" = "stop" ]; then
  echo "P2R-E8.4e SRAM corners, stop at $(stamp)"
  R=$(other_runs | tr '\n' ' ')
  if [ -n "${R// /}" ]; then echo "   ending the running script: $R"; kill $R 2>/dev/null; sleep 2; fi
  P=$(sims_in_work | tr '\n' ' ')
  if [ -n "${P// /}" ]; then
    echo "   ending $(echo $P | wc -w) simulation(s): $P"
    for p in $P; do c=$(readlink "/proc/$p/cwd" 2>/dev/null) && [ -d "$c" ] && touch "$c/stopped"; done
    kill $P 2>/dev/null; sleep 5
    P=$(sims_in_work | tr '\n' ' ')
    if [ -n "${P// /}" ]; then echo "   still running, forcing: $P"; kill -9 $P 2>/dev/null; sleep 1; fi
  fi
  R=$(other_runs | tr '\n' ' '); P=$(sims_in_work | tr '\n' ' ')
  if [ -n "${R// /}${P// /}" ]; then echo "   NOT everything ended (script: ${R:-none}; simulations: ${P:-none})"; exit 1; fi
  echo "   nothing of this script is running any more"
  exit 0
fi

[ "$MODE" = "run" ] || { echo "ERROR: unknown mode '$MODE' (run, status or stop)" >&2; exit 1; }
case "$NW$HEARTBEAT$MEMGB${E8_MAXRUN:-0}" in *[!0-9]*|"") echo "ERROR: E8_NW, E8_HEARTBEAT, E8_MEM_GB, E8_MAXRUN must be integers" >&2; exit 1 ;; esac
for c in $CONDS; do
  echo "$c" | grep -qE '^(tt|ff|ss|fs|sf):-?[0-9]+$' || { echo "ERROR: condition '$c' is not corner:temperature (e.g. ff:85)" >&2; exit 1; }
done
case " $CONDS " in *" tt:25 "*) ;; *) echo "ERROR: E8_CONDS must contain tt:25 (the reference of the ratios)" >&2; exit 1 ;; esac
R=$(other_runs | tr '\n' ' '); P=$(sims_in_work | tr '\n' ' ')
if [ -n "${R// /}${P// /}" ]; then
  echo "ERROR: an earlier run is still working (script: ${R:-none}; simulations in $WORK: ${P:-none})." >&2
  echo "       Let it finish, or end it first with: bash scripts/$SELF stop" >&2
  exit 1
fi

echo "=============================================================="
echo "P2R-E8.4e SRAM macro at other corners and temperatures, started $(stamp)"
echo "=============================================================="
cd "$PAPER2" || { echo "ERROR: no folder $PAPER2" >&2; exit 1; }

hr "0. files, tools and E8.4f (P0)"
for F in "$SBENCH" "$STOOLS" "$ETOOLS" "$RBENCH" "$MODELS" "$SRC/e8_4c_summary.json" "$SRC/extract/$NAME.flat_pex.spice" \
         "$SRC/modelcheck/modelcheck.json" "$SRC/r10/tb.sp" "$SRC/r10/tb_meta.json" "$SRC/r10/netlist.sp" \
         "$SRC/r10/.spiceinit" "$SRC/r10/result.json"; do
  [ -f "$F" ] || { echo "ERROR: missing $F (E8.4f must have finished; E8_SRC_WORK)" >&2; exit 1; }
done
[ -n "$NGSPICE" ] && [ -x "$NGSPICE" ] || { echo "ERROR: ngspice not found (E8_NGSPICE)" >&2; exit 1; }
for f in "scripts/$SELF" "$ETOOLS" "$SBENCH" "$STOOLS" "$RBENCH" "$MODELS" "$SRC/e8_4c_summary.json"; do
  echo "   $(md5sum "$f" | cut -c1-32)  $f"
done
echo "ngspice  : $NGSPICE ($("$NGSPICE" -v 2>/dev/null | grep -m1 -o 'ngspice-[0-9]*' || echo version unknown))"
echo "E8.4f    : $SRC"
P0=$(python3 - "$SRC/e8_4c_summary.json" "$SRC/r10/tb_meta.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
m = json.load(open(sys.argv[2]))
bad = [k for k in ("G0", "G1", "G1b", "G2", "G3") if s.get(k) != "PASS"]
if s.get("G1t") != "NO SHORT OF THIS KIND":
    bad.append("G1t")
if s.get("F2b_gated_reads_ok_within_two_cycles") != "yes":
    bad.append("F2b")
if not s.get("layout_sense_precharge"):
    bad.append("layout_sense_precharge (E8.4f was not run with E8_OPENRAM_SPC=1)")
if any("sense-side precharge added" in n for n in m.get("notes", [])):
    bad.append("r10 has the netlist-only sense precharge")
print("PASS" if not bad else "FAIL: " + ", ".join(bad))
PY
)
echo "   P0 E8.4f valid (G0, G1t, G1, G1b, G2, G3, F2b; sense precharge in the layout, none in the netlist): $P0"
[ "$P0" = "PASS" ] || { echo "ERROR: E8.4f is not valid ($P0); nothing to simulate" >&2; exit 1; }
AVAIL_GB=$(free -g | awk '/Mem:/{print $7}')
echo "machine  : $NCORES cores, $(free -g | awk '/Mem:/{print $2}') GiB memory, $AVAIL_GB GiB available, $(df -h "$(dirname "$WORK")" 2>/dev/null | awk 'NR==2{print $4}') free for the work folder"
mkdir -p "$WORK" "$OUT" || { echo "ERROR: cannot make $WORK or $OUT" >&2; exit 1; }

hr "1. bench options and sequence of E8.4f; its r10 deck written again (P2)"
X="$SRC/extract/$NAME.flat_pex.spice"
SUBC=$(awk '{for (i = 2; i <= NF; i++) { if ($i == "VSUBS") v++; else if ($i == "SUB") s++ }} END {printf "%d %d", v, s}' "$X")
read -r NV NS <<< "$SUBC"
SUBSTRATE=""
if [ "$NV" -gt 0 ] || [ "$NS" -gt 0 ]; then
  if [ "$NV" -ge "$NS" ]; then SUBSTRATE="VSUBS"; else SUBSTRATE="SUB"; fi
fi
NTHREADS=$(sed -n 's/^set num_threads=\([0-9]*\)$/\1/p' "$SRC/r10/.spiceinit")
TMAX=$(python3 -c "
import sys
for l in open(sys.argv[1]):
    t = l.split()
    if t and t[0] == '.tran':
        print(f'{float(t[4]) * 1e9:g}'); break" "$SRC/r10/tb.sp")
ALIAS=$(python3 -c "import json,sys; print('yes' if json.load(open(sys.argv[1])).get('pfet_pass_alias') else 'no')" "$SRC/modelcheck/modelcheck.json")
[ -n "$NTHREADS" ] && [ -n "$TMAX" ] || { echo "ERROR: threads or time step not found in E8.4f's r10 deck" >&2; exit 1; }
BOPTS="--sanitize --tie-cell-sub ${SUBSTRATE:+--substrate $SUBSTRATE} --tie-float-gates --plain-nfet --uic --ic-cells --threads $NTHREADS --tmax $TMAX"
[ "$ALIAS" = "yes" ] && BOPTS="$BOPTS --pfet-pass-alias"
echo "   substrate node ${SUBSTRATE:-none} (VSUBS $NV, SUB $NS); ngspice threads $NTHREADS; maximum time step $TMAX ns; pfet_pass alias $ALIAS"
echo "   bench options: $BOPTS"
SEQJ=$(python3 "$ETOOLS" seq --meta "$SRC/r10/tb_meta.json" --nw "$NW") || { echo "ERROR: sequence" >&2; exit 1; }
SEQ_R10=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['r10'])" "$SEQJ")
SEQ_E=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['e84e'])" "$SEQJ")
PER=$(python3 -c "import json,sys; print(f\"{json.loads(sys.argv[1])['period_ns']:g}\")" "$SEQJ")
echo "   r10 of E8.4f   : $SEQ_R10"
echo "   E8.4e sequence : $SEQ_E   (period $PER ns)"
DC="$WORK/deckcheck"
rm -rf "${DC:?}"
python3 "$SBENCH" bench --sp "$X" --top "$NAME" --models "$MODELS" --corner tt --out "$DC" --seq "$SEQ_R10" \
    --period "$PER" $BOPTS --probe "$PROBES" > "$WORK/bench_deckcheck.txt" 2>&1 \
  || { echo "ERROR: the r10 deck could not be written:"; tail -5 "$WORK/bench_deckcheck.txt"; exit 1; }
P2LINE=$(python3 "$ETOOLS" deckcmp --ref "$SRC/r10" --new "$DC")
P2RC=$?
echo "   P2 E8.4f's r10 deck written again with these options: $P2LINE"
[ "$P2RC" = 0 ] || { echo "ERROR: P2 failed: the options rebuilt here do not give E8.4f's deck; nothing simulated" >&2; exit 1; }
REFMD5=$(md5sum "$SRC/r10/netlist.sp" | cut -c1-32)
rm -f "$DC/netlist.sp"
SIG="$SEQ_E | $BOPTS | $MODELS | $REFMD5"

hr "2. decks of the conditions (P1 model check at the corner, P3 deck)"
declare -A MCV
for c in $CONDS; do
  corner=${c%%:*} temp=${c#*:}
  d="$WORK/$(tag_of "$c")"
  if [ -f "$d/sig.txt" ] && [ "$(cat "$d/sig.txt")" = "$SIG" ] && [ "$(state "$d")" = finished ]; then
    echo "   $c: finished in an earlier run, kept ($d)"
    continue
  fi
  case "$(state "$d")" in running) echo "ERROR: $d is running" >&2; exit 1 ;; esac
  rm -rf "${d:?}"
  mkdir -p "$d"
  if [ -z "${MCV[$corner]:-}" ]; then
    python3 "$STOOLS" modelcheck --sp "$X" --models "$MODELS" --corner "$corner" --ngspice "$NGSPICE" \
        --dir "$WORK/modelcheck_$corner" --json "$WORK/modelcheck_$corner/modelcheck.json" --plain-nfet > "$WORK/modelcheck_$corner.txt" 2>&1
    MCV[$corner]=$(python3 -c "
import json, sys
m = json.load(open(sys.argv[1])); r = json.load(open(sys.argv[2]))
same = bool(m.get('pfet_pass_alias')) == bool(r.get('pfet_pass_alias'))
print('PASS' if m.get('verdict') == 'OK' and same else 'FAIL (verdict %s, alias %s, E8.4f alias %s)' % (m.get('verdict'), m.get('pfet_pass_alias'), r.get('pfet_pass_alias')))" \
      "$WORK/modelcheck_$corner/modelcheck.json" "$SRC/modelcheck/modelcheck.json" 2>/dev/null || echo "FAIL (no model check result)")
  fi
  if [ "${MCV[$corner]}" != "PASS" ]; then
    echo "   $c: P1 model check at $corner: ${MCV[$corner]}; not simulated"
    echo "P1 ${MCV[$corner]}" > "$d/skip"
    continue
  fi
  python3 "$SBENCH" bench --sp "$X" --top "$NAME" --models "$MODELS" --corner "$corner" --temp "$temp" --out "$d" \
      --seq "$SEQ_E" --period "$PER" $BOPTS --probe "$PROBES" > "$d.bench.txt" 2>&1 \
    || { echo "   $c: deck not written: $(tail -1 "$d.bench.txt")"; echo "deck not written" > "$d/skip"; continue; }
  M=$(md5sum "$d/netlist.sp" | cut -c1-32)
  if [ "$M" != "$REFMD5" ]; then
    echo "   $c: P3 FAIL: netlist copy $M, E8.4f's $REFMD5; not simulated"
    echo "P3 netlist copy differs" > "$d/skip"
    continue
  fi
  echo "$SIG" > "$d/sig.txt"
  echo "   $c: P1 PASS, deck written $(head -1 "$d.bench.txt" | grep -o "([^)]*)" | head -1), netlist copy identical to E8.4f's"
done

hr "3. runs (in the order of E8_CONDS)"
MAXRUN="${E8_MAXRUN:-$(( AVAIL_GB / MEMGB ))}"
[ "$MAXRUN" -ge 1 ] 2>/dev/null || MAXRUN=1
[ "$MAXRUN" -le 3 ] || MAXRUN=3
echo "   available memory $AVAIL_GB GiB: at most $MAXRUN simulation(s) at a time (about $MEMGB GB each for the 4-KB macro)"
LIST=()
for c in $CONDS; do LIST+=("$WORK/$(tag_of "$c")"); done
launch() {
  local d=$1
  rm -f "$d"/{tb_out.txt,tb_out.part,tb_done,tb_failed,exit_code,finished,started,pid,ngspice.log,result.json,analyze.txt,peak_rss_kb,stopped}
  date +%s > "$d/started"
  ( cd "$d" || exit 99; "$NGSPICE" -b tb.sp > ngspice.log 2>&1; echo $? > exit_code; date +%s > finished ) &
  echo $! > "$d/pid"
  echo "   started $(basename "$d") at $(stamp)"
}
alive() { local n=0 d; for d in "${LIST[@]}"; do [ "$(state "$d")" = running ] && n=$((n + 1)); done; echo $n; }
digest() {   # analyse a finished run once
  local d=$1
  [ -f "$d/result.json" ] && return
  python3 "$SBENCH" analyze --dir "$d" > "$d/analyze.txt" 2>&1
  echo "   $(basename "$d") finished at $(stamp) ($(elapsed "$d"), peak $(peak_rss "$d")): $(grep -c " read " "$d/analyze.txt") read lines analysed"
}
T_START=$(date +%s); LAST=$T_START
for d in "${LIST[@]}"; do [ "$(state "$d")" = finished ] && digest "$d"; done
while :; do
  for d in "${LIST[@]}"; do
    [ "$(alive)" -lt "$MAXRUN" ] || break
    case "$(state "$d")" in written) ;; *) continue ;; esac
    if [ "$(alive)" -gt 0 ]; then
      av=$(free -g | awk '/Mem:/{print $7}')
      [ "$av" -ge "$MEMGB" ] || continue      # not enough memory now; try again later
    fi
    launch "$d"
  done
  for d in "${LIST[@]}"; do
    if [ "$(state "$d")" = running ]; then
      m=$(ps -o rss= --ppid "$(cat "$d/pid")" 2>/dev/null | sort -n | tail -1)
      p=$(cat "$d/peak_rss_kb" 2>/dev/null || echo 0)
      [ -n "${m// /}" ] && [ "$m" -gt "$p" ] && echo "$m" > "$d/peak_rss_kb"
    fi
    [ "$(state "$d")" = finished ] && digest "$d"
  done
  left=0
  for d in "${LIST[@]}"; do case "$(state "$d")" in running|written) left=$((left + 1)) ;; esac; done
  [ "$left" -eq 0 ] && break
  if [ $(( $(date +%s) - LAST )) -ge "$HEARTBEAT" ]; then
    LAST=$(date +%s)
    echo "   progress at $(stamp), $(free -g | awk '/Mem:/{print $7}') GiB available:"
    for d in "${LIST[@]}"; do printf "      %-10s %-36s %-7s %-9s %s\n" "$(basename "$d")" "$(state "$d")" "$(elapsed "$d")" "$(peak_rss "$d")" "$(reached "$d")"; done
  fi
  sleep 20
done
wait 2>/dev/null
for d in "${LIST[@]}"; do [ "$(state "$d")" = finished ] && digest "$d"; done
for d in "${LIST[@]}"; do
  printf "   %-10s %-40s %-7s peak %s\n" "$(basename "$d")" "$(state "$d")" "$(elapsed "$d")" "$(peak_rss "$d")"
  case "$(state "$d")" in finished|SKIPPED*) ;; *) [ -f "$d/ngspice.log" ] && tr '\r' '\n' < "$d/ngspice.log" | \
      grep -iE "error|singular|timestep too small|abort|E8_FAILED" | sort | uniq -c | sort -rn | head -4 | sed 's/^/      log: /' ;; esac
done

hr "4. gates and results (scripts/e8_4e_sram_tools.py compare)"
python3 "$ETOOLS" compare --work "$WORK" --ref-r10 "$SRC/r10" --ref-modelcheck "$SRC/modelcheck/modelcheck.json" \
  --rb "$RBENCH" --conds "$CONDS" --nw "$NW" --json "$WORK/e8_4e_sram_summary.json"
# keep the results in the project (the netlist copies stay in the work folder)
cp -f "$WORK/e8_4e_sram_summary.json" "$WORK/bench_deckcheck.txt" "$OUT/" 2>/dev/null
mkdir -p "$OUT/deckcheck" && cp -f "$DC/tb.sp" "$DC/tb_meta.json" "$OUT/deckcheck/" 2>/dev/null
for f in "$WORK"/modelcheck_*/modelcheck.json; do
  [ -f "$f" ] && cp -f "$f" "$OUT/$(basename "$(dirname "$f")").json"
done
for d in "${LIST[@]}"; do
  t=$(basename "$d"); mkdir -p "$OUT/$t"
  for f in tb.sp tb_meta.json result.json analyze.txt exit_code peak_rss_kb started finished skip sig.txt; do
    [ -f "$d/$f" ] && cp -f "$d/$f" "$OUT/$t/"
  done
  [ -f "$d.bench.txt" ] && cp -f "$d.bench.txt" "$OUT/$t/bench.txt"
  [ -f "$d/ngspice.log" ] && gzip -c "$d/ngspice.log" > "$OUT/$t/ngspice.log.gz"
  [ -f "$d/tb_out.txt" ] && gzip -c "$d/tb_out.txt" > "$OUT/$t/tb_out.txt.gz"
done
echo
echo "=============================================================="
echo "Finished $(stamp), $(( ($(date +%s) - T_START) / 60 )) min of runs. Results in $OUT. Pack for Claude:"
echo "  tar czf reports/e8_4e_sram_results.tar.gz reports/e8_4e_sram_corners.log reports/e8_rom/e8_4e_sram/e8_4e_sram_summary.json reports/e8_rom/e8_4e_sram/modelcheck_*.json reports/e8_rom/e8_4e_sram/deckcheck reports/e8_rom/e8_4e_sram/c_*/analyze.txt reports/e8_rom/e8_4e_sram/c_*/result.json reports/e8_rom/e8_4e_sram/c_*/tb_meta.json reports/e8_rom/e8_4e_sram/c_*/bench.txt"
echo "=============================================================="
