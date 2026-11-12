#!/usr/bin/env bash
# =============================================================================
# e9_3b_rom_check.sh   [run | status | stop]
#
# Experiment : P2R-E9.3b. Held-out windows for the lookup model of the address-map ROM of E9 (the remedy
#              I chose on 2026-11-12 17:04 for gate V3 of E9.3).
# Why        : E9.3's check window of A k1 was 12.3 % above its fit (limit 10 %): the read energy of this
#              NAND-type ROM grows with the row's distance from the footer (about 0.6 pJ per row), which the
#              fits of E9.3 (zero bits only) did not have. The lookup model with the row position was fixed
#              before these runs (one set of coefficients for the 14 macros, from the 420 lookups of E9.3).
# Runs       : one per macro (scripts/e9_3b_tools.py plan; rules written before the run in
#              protocol P2R-E9.3b of 2026-11-12): 300 ns unread; macro 0 six lookup-and-park pairs
#              that E9.3 did not use; one window N of 16 consecutive real lookups that shares no lookup with
#              E9.3's windows and lies the farthest from the row positions E9.3 sampled in that macro; the
#              parking read 5 cycles after the last lookup and 400 ns parked. Conditions as E9.3: tt 25 C
#              1.80 V, CS 10 ns after the clock edge, the netlists and probes of E9.2, reltol 1e-4,
#              waveforms written every 1000 ns, scripts/e8_4_rom_bench.py version 6.
# Gates      : W4 the inputs the rules were fixed on (E9.3's plan and runs give the fixed coefficients and
#              E9.3's D_ROM again), W0 every read correct, W1 every run complete, W2 per model the sum of the
#              7 new windows within 5 % of the fixed lookup model, W3 per model the sum of the 6 new pairs
#              within 10 % of E9.3's pair fit. Then the final D_ROM (scripts/e9_3b_tools.py judge).
# Place      : D:\Project\hybrid_memory\paper2\scripts\  (new); with scripts/e9_3b_tools.py (new) and
#              rtl/e9/e9_3b_manifest.md5 (new); uses scripts/e9_3_tools.py of E9.3 unchanged
# Needs      : E9.3 finished (reports/e9_rom/e9_3: its plan and 14 complete runs), E9.2 and E9.1 as for
#              E9.3; the sky130 models; ngspice. Only read.
# Writes     : reports/e9_rom/e9_3b/ (plan, one folder per run, summary). A run keeps the runs that ended
#              with a complete result and simulates the rest (so it can be started again after a stop).
# Run        : cd /mnt/d/Project/hybrid_memory/paper2
#              bash scripts/e9_3b_rom_check.sh 2>&1 | tee reports/e9_3b_rom_check.log
#              Keep the terminal open and the computer awake.
# Status     : bash scripts/e9_3b_rom_check.sh status
# Stop       : bash scripts/e9_3b_rom_check.sh stop
# Options    : E8_MAXJOBS (cores - 1), E8_TIMEOUT (0 = none, seconds per run), E8_HEARTBEAT (1800 s),
#              E8_PDK, E8_NGSPICE, E8_PAPER2
# Runtime    : 14 runs, 48.5 us simulated in all (macro 0: 5.8 us, the others 3.0-3.1 us), the longest
#              first; E9.3 on this machine took 18-24 min per simulated us with 7 at a time: about 3-3.5 h.
#              Disk: 10 GB free needed, about 1-2 GB written. Each run is analysed when its ngspice ends.
# =============================================================================
set -uo pipefail

MODE="${1:-run}"
PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
MODELS="$PDK_ROOT_DIR/sky130A/libs.tech/ngspice/sky130.lib.spice"
BENCH="$PAPER2/scripts/e8_4_rom_bench.py"
TOOLS="$PAPER2/scripts/e9_3b_tools.py"
W3="$PAPER2/reports/e9_rom/e9_3"
W2="$PAPER2/reports/e9_rom/e9_2"
LOG2="$PAPER2/reports/e9_2_rom_macros.log"
E91="$PAPER2/reports/e9/e9_1/rtl"
WORK="$PAPER2/reports/e9_rom/e9_3b"
SELF="e9_3b_rom_check.sh"
PERIOD=100
CSD=10
RELTOL=1e-4
CKPT=1000
TIMEOUT="${E8_TIMEOUT:-0}"
HEARTBEAT="${E8_HEARTBEAT:-1800}"
pick_path() { ls -d $1 2>/dev/null | sort -V | tail -1; }
NGSPICE="${E8_NGSPICE:-$(pick_path "/nix/store/*-ngspice-*/bin/ngspice")}"
NCORES=$(nproc 2>/dev/null || echo 4)
MAXJOBS="${E8_MAXJOBS:-$(( NCORES > 2 ? NCORES - 1 : 1 ))}"
NTHREADS=1
case "$MAXJOBS$TIMEOUT$HEARTBEAT" in *[!0-9]*|"") echo "ERROR: E8_MAXJOBS, E8_TIMEOUT, E8_HEARTBEAT must be whole numbers" >&2; exit 1 ;; esac
[ "$MAXJOBS" -ge 1 ] || MAXJOBS=1
NAMES=""
for M in A B; do for k in 0 1 2 3 4 5 6; do NAMES="$NAMES e9rom_${M}_40x2688_w8_r48k$k"; done; done
stamp() { date '+%Y-%m-%d %H:%M:%S'; }
hr() { echo; echo "########## $* ##########"; }
keys() { python3 -c "import json, sys; print(' '.join(json.load(open(sys.argv[1]))['runs']))" "$WORK/plan.json" 2>/dev/null; }
state() {   # state DIR
  local d=$1
  if [ ! -f "$d/tb.sp" ]; then echo "not written"
  elif [ -f "$d/result.json" ] && [ -f "$d/done_ok" ]; then echo "done"
  elif [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null; then echo "running"
  elif [ -f "$d/exit_code" ]; then echo "ended, exit $(cat "$d/exit_code")"
  else echo "waiting"; fi
}
elapsed() { local d=$1; [ -f "$d/started" ] || { echo "-"; return; }
  local e; e=$( [ -f "$d/finished" ] && cat "$d/finished" || date +%s ); echo "$(( (e - $(cat "$d/started")) / 60 )) min"; }
reached() {   # simulated time so far (the bench rewrites tb_out.txt at every checkpoint)
  local d=$1
  [ -f "$d/tb_out.txt" ] || { echo "-"; return; }
  python3 - "$d" <<'EOF' 2>/dev/null || echo "-"
import json, os, sys
d = sys.argv[1]
meta = json.load(open(os.path.join(d, "tb_meta.json")))
last = None
with open(os.path.join(d, "tb_out.txt"), "rb") as f:
    f.seek(0, 2); n = f.tell(); f.seek(max(0, n - 4096)); tail = f.read().decode(errors="replace").splitlines()
for ln in reversed(tail):
    p = ln.split()
    try:
        last = float(p[0]); break
    except (ValueError, IndexError):
        continue
print(f"{last * 1e9:.0f} of {meta['tstop'] * 1e9:.0f} ns" if last is not None else "-")
EOF
}
progress() {
  local k d
  echo "   progress at $(stamp):"
  for k in $(keys); do
    d="$WORK/runs/$k"
    printf "      %-6s %-14s %-8s %s\n" "$k" "$(state "$d")" "$(elapsed "$d")" "$(reached "$d")"
  done
}
is_this_script() {   # process $1 runs this script (the main shell or one of its run subshells)
  tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q "$SELF"
}
my_pids() {   # the run subshells of this experiment that are still alive (each waits for its ngspice)
  local k d p
  for k in $(keys); do
    d="$WORK/runs/$k"
    [ -f "$d/pid" ] || continue
    p=$(cat "$d/pid")
    kill -0 "$p" 2>/dev/null && is_this_script "$p" && echo "$p"
  done
}
main_pid() {   # the main script of a run of this experiment that is still alive (not this process)
  local p
  [ -f "$WORK/main.pid" ] || return 0
  p=$(cat "$WORK/main.pid")
  [ -n "$p" ] && [ "$p" != "$$" ] && kill -0 "$p" 2>/dev/null && is_this_script "$p" && echo "$p"
  return 0
}

case "$MODE" in
  status)
    echo "P2R-E9.3b status, $(stamp)   ($WORK)"
    [ -f "$WORK/plan.json" ] || { echo "   no plan yet"; exit 0; }
    progress
    exit 0 ;;
  stop)
    echo "P2R-E9.3b stop, $(stamp)   ($WORK)"
    M=$(main_pid); P=$(my_pids)
    [ -n "$M$P" ] || { echo "   nothing running"; exit 0; }
    if [ -n "$M" ]; then   # first the main script, so that it starts no more runs
      kill "$M" 2>/dev/null && echo "   stopped the running script $M"
      sleep 1
    fi
    for p in $P; do
      for c in $(pgrep -P "$p" 2>/dev/null); do
        cn=$(ps -o comm= -p "$c" 2>/dev/null)
        kill "$c" 2>/dev/null && echo "   stopped ${cn:-process} $c"
      done
      kill "$p" 2>/dev/null && echo "   stopped run shell $p"
    done
    sleep 2
    M=$(main_pid); P=$(my_pids)
    if [ -n "$M$P" ]; then echo "   NOT everything ended: $M $P"; exit 1; fi
    echo "   nothing of this experiment runs any more (bash scripts/$SELF starts it again; finished runs are kept)"
    exit 0 ;;
  run) ;;
  *) echo "usage: bash scripts/$SELF [run | status | stop]" >&2; exit 1 ;;
esac

echo "=============================================================="
echo "P2R-E9.3b held-out windows for the lookup model of the address-map ROM of E9, started $(stamp)"
echo "=============================================================="
cd "$PAPER2" || exit 1
if [ -n "$(main_pid)$(my_pids)" ]; then
  echo "ERROR: an earlier run still works in $WORK (bash scripts/$SELF status / stop)" >&2
  exit 1
fi
mkdir -p "$WORK" && echo $$ > "$WORK/main.pid"

hr "0. files, the E9.3, E9.2 and E9.1 results, tools"
md5sum -c "$PAPER2/rtl/e9/e9_3b_manifest.md5" || { echo "ERROR: a delivered or used file differs from rtl/e9/e9_3b_manifest.md5 (above)" >&2; exit 1; }
[ -f "$LOG2" ] || { echo "ERROR: missing $LOG2 (the log of E9.2)" >&2; exit 1; }
grep -E "^ +tables: " "$LOG2" | tail -1 | grep -qE "^ +tables: 2 PASS, 0 FAIL, 0 INCOMPLETE" \
  || { echo "ERROR: the last verdict of $LOG2 is not 'tables: 2 PASS, 0 FAIL, 0 INCOMPLETE': E9.3b runs only on macros that passed E9.2" >&2; exit 1; }
echo "   E9.2: $(grep -E "^ +tables: " "$LOG2" | tail -1 | sed 's/^ *//' | cut -c1-48)"
for n in $NAMES; do
  for f in "$W2/$n/extract/$n.flat_pex.spice" "$W2/bins/$n.bin" "$W2/$n/lvs/netgen.log"; do
    [ -f "$f" ] || { echo "ERROR: missing $f (E9.2)" >&2; exit 1; }
  done
  grep -q "match uniquely" "$W2/$n/lvs/netgen.log" || { echo "ERROR: $n: the LVS of E9.2 did not match" >&2; exit 1; }
done
echo "   E9.2: 14 extracted netlists, macro images and LVS matches found"
[ -f "$W3/plan.json" ] || { echo "ERROR: missing $W3/plan.json (E9.3)" >&2; exit 1; }
[ "$(md5sum < "$W3/plan.json" | cut -c1-32)" = "df6400b4c7f49cf82f451ed111559cc5" ] \
  || { echo "ERROR: $W3/plan.json is not the plan of E9.3 the rules were fixed on (md5 df6400b4...)" >&2; exit 1; }
for k in A_k0 A_k1 A_k2 A_k3 A_k4 A_k5 A_k6 B_k0 B_k1 B_k2 B_k3 B_k4 B_k5 B_k6; do
  [ -f "$W3/runs/$k/result.json" ] && [ -f "$W3/runs/$k/done_ok" ] \
    || { echo "ERROR: the E9.3 run $k is missing or not complete ($W3/runs/$k)" >&2; exit 1; }
done
echo "   E9.3: plan df6400b4..., 14 runs complete with every read right"
for M in A B; do
  [ -f "$E91/e9ev_normal_$M.txt" ] || { echo "ERROR: missing $E91/e9ev_normal_$M.txt (E9.1)" >&2; exit 1; }
  echo "   E9.1 events $M: $(md5sum "$E91/e9ev_normal_$M.txt" | cut -c1-32)"
done
[ -n "$NGSPICE" ] && [ -x "$NGSPICE" ] || { echo "ERROR: ngspice not found" >&2; exit 1; }
[ -f "$MODELS" ] || { echo "ERROR: missing the model library $MODELS" >&2; exit 1; }
grep -qE "^\.lib[[:space:]]+tt([[:space:]]|$)" "$MODELS" || { echo "ERROR: the model library has no section 'tt'" >&2; exit 1; }
grep -q -- '"--reltol"' "$BENCH" && grep -q "cs_delay" "$BENCH" || { echo "ERROR: $BENCH is older than version 6 of 2026-10-18 (no --reltol)" >&2; exit 1; }
echo "ngspice  : $NGSPICE"
"$NGSPICE" -v < /dev/null 2>&1 | grep -m1 -i "ngspice-" | sed 's/^/   /'
echo "models   : $MODELS"
echo "bench    : $(md5sum "$BENCH" | cut -c1-32)"
echo "python3  : $(command -v python3)  $(python3 --version 2>&1)"
echo "jobs     : at most $MAXJOBS ngspice runs at a time (E8_MAXJOBS); timeout ${TIMEOUT}s per run (0 = none)"
mkdir -p "$WORK/runs" || exit 1
FREE_KB=$(df -Pk "$WORK" | awk 'NR == 2 {print $4}')
echo "disk     : $((FREE_KB / 1024 / 1024)) GB free for $WORK (needs 10 GB)"
[ "$FREE_KB" -ge 10485760 ] || { echo "ERROR: less than 10 GB free for $WORK" >&2; exit 1; }

hr "1. the read sequences (scripts/e9_3b_tools.py plan)"
python3 "$TOOLS" plan --plan3 "$W3/plan.json" --e91 "$E91" --bins "$W2/bins" --out "$WORK/plan.new.json" || { echo "ERROR: plan" >&2; exit 1; }
if [ -f "$WORK/plan.json" ] && ! cmp -s "$WORK/plan.json" "$WORK/plan.new.json"; then
  echo "   the plan differs from the one of an earlier run: the earlier runs are not kept"
  rm -rf "${WORK:?}/runs"
  mkdir -p "$WORK/runs"
fi
mv -f "$WORK/plan.new.json" "$WORK/plan.json"
echo "   plan md5 $(md5sum "$WORK/plan.json" | cut -c1-32)"

hr "2. benches (scripts/e8_4_rom_bench.py bench, tt 25 C 1.80 V, CS ${CSD} ns after the clock, reltol $RELTOL, every bitline, data every $CKPT ns)"
spiceinit() {
  cat > "$1/.spiceinit" <<EOF
* ngspice settings recommended for the sky130 models
set ngbehavior=hsa
set ng_nomodcheck
set skywaterpdk
set num_threads=$NTHREADS
EOF
}
analyze_run() {   # analyze_run DIR: result.json; done_ok if ngspice ended with 0, the run is complete, every read right
  local d=$1
  python3 "$BENCH" analyze --dir "$d" > "$d/analyze.txt" 2>&1
  if [ "$(cat "$d/exit_code" 2>/dev/null)" = 0 ] && python3 -c "import json, sys; s = json.load(open(sys.argv[1]))['summary']; \
r = s.get('reads'); sys.exit(0 if s['cycles_complete'] == s['cycles_total'] and not s['failed'] and r and s.get('reads_ok') == r \
and s.get('reads_selection_ok', r) == r else 1)" "$d/result.json" 2>/dev/null; then
    touch "$d/done_ok"
  fi
}
QUEUE=()
BMD5=$(md5sum "$BENCH" | cut -c1-32)
# the longest runs first (fewer hours at the end with only one or two runs left)
ORDER=$(python3 -c "import json, sys; p = json.load(open(sys.argv[1]))['runs']; \
t = {k: 100.0 * sum(1 for x in r['roles'] if x.get('addr') is not None) + sum(float(w[1:]) for w in r['seq'].split(',') if w[0] == 'w') \
for k, r in p.items()}; print(' '.join(sorted(t, key=lambda k: (-t[k], k))))" "$WORK/plan.json")
[ -n "$ORDER" ] || { echo "ERROR: no runs in the plan" >&2; exit 1; }
for k in $ORDER; do
  d="$WORK/runs/$k"
  read -r n SEQ <<< "$(python3 -c "import json, sys; r = json.load(open(sys.argv[1]))['runs'][sys.argv[2]]; print(r['name'], r['seq'])" "$WORK/plan.json" "$k")"
  ARGS=(bench --sp "$W2/$n/extract/$n.flat_pex.spice" --top "$n" --bin "$W2/bins/$n.bin" \
        --word-bytes 5 --words-per-row 8 --out "$d" --models "$MODELS" --period "$PERIOD" --seq "$SEQ" \
        --sanitize --plain-nfet --probes full --bitlines all --corner tt --temp 25 --vdd 1.8 --cs-delay "$CSD" \
        --reltol "$RELTOL" --checkpoint "$CKPT")
  # what a kept run must have been made with: the same bench command, bench, netlist and macro image
  CMD="$(printf '%q ' "${ARGS[@]}")| bench $BMD5 | netlist $(md5sum < "$W2/$n/extract/$n.flat_pex.spice" | cut -c1-32) | image $(md5sum < "$W2/bins/$n.bin" | cut -c1-32)"
  if [ "$(cat "$d/bench.cmd" 2>/dev/null)" = "$CMD" ]; then
    if [ "$(state "$d")" = "done" ]; then
      echo "   $k: done in an earlier run of the same plan, kept"
      continue
    fi
    if [ -f "$d/tb_done" ] && [ "$(cat "$d/exit_code" 2>/dev/null)" = 0 ] && [ "$(state "$d")" != "running" ]; then
      analyze_run "$d"     # simulated, but stopped before its analysis
      if [ -f "$d/done_ok" ]; then echo "   $k: simulated in an earlier run of the same plan, analysed now, kept"; continue; fi
    fi
  fi
  rm -rf "$d"
  mkdir -p "$d"
  if python3 "$BENCH" "${ARGS[@]}" > "$d/bench.txt" 2>&1; then
    echo "$CMD" > "$d/bench.cmd"
    grep -E "WARNING" "$d/bench.txt" | sed 's/^/      /'
    spiceinit "$d"
    QUEUE+=("$d")
    echo "   $k ($n): bench written, $(grep -c '' "$d/tb.sp") lines"
  else
    echo "ERROR: bench $k not written:" >&2; tail -5 "$d/bench.txt" >&2
    exit 1
  fi
done

hr "3. runs (at most $MAXJOBS at a time; progress every $HEARTBEAT s), started $(stamp)"
launch() {
  local d=$1
  date +%s > "$d/started"
  (
    cd "$d" || exit 99
    if [ "$TIMEOUT" -gt 0 ]; then timeout "$TIMEOUT" "$NGSPICE" -b tb.sp > ngspice.log 2>&1
    else "$NGSPICE" -b tb.sp > ngspice.log 2>&1; fi
    echo $? > exit_code
    date +%s > finished
    analyze_run "$d"
  ) &
  echo $! > "$d/pid"
  echo "   started ${d##*/} at $(stamp)"
}
running() { local n=0 d; for d in "${QUEUE[@]}"; do [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null && n=$((n + 1)); done; echo $n; }
last=$(date +%s)
while :; do
  for d in "${QUEUE[@]}"; do
    [ -f "$d/pid" ] && continue
    [ "$(running)" -lt "$MAXJOBS" ] || break
    launch "$d"
  done
  busy=0
  for d in "${QUEUE[@]}"; do
    if [ ! -f "$d/pid" ] || kill -0 "$(cat "$d/pid")" 2>/dev/null; then busy=1; fi
  done
  [ "$busy" -eq 0 ] && break
  sleep 30
  if [ $(( $(date +%s) - last )) -ge "$HEARTBEAT" ]; then progress; last=$(date +%s); fi
done
wait 2>/dev/null

hr "4. results of the runs (each analysed by scripts/e8_4_rom_bench.py analyze when its ngspice ended)"
for k in $(keys); do
  d="$WORK/runs/$k"
  [ -f "$d/exit_code" ] && [ ! -f "$d/analyze.txt" ] && analyze_run "$d"
  echo
  echo "---- $k: ngspice exit $(cat "$d/exit_code" 2>/dev/null || echo '-'), $(elapsed "$d"), $( [ -f "$d/done_ok" ] \
    && echo "complete, every read right" || echo "NOT COMPLETE OR NOT EVERY READ RIGHT") ----"
  tr '\r' '\n' < "$d/ngspice.log" 2>/dev/null | grep -v "Reference value" \
    | grep -iE "error|could not|unknown|singular|timestep too small|abort|E8_FAILED" | sort | uniq -c | sort -rn | head -6 | sed 's/^/   log: /'
  tr '\r' '\n' < "$d/ngspice.log" 2>/dev/null | grep -iE "total analysis time" | head -1 | sed 's/^/   /'
  grep -E "^summary:|^data:|SIMULATION FAILED|Traceback|Error" "$d/analyze.txt" 2>/dev/null | sed 's/^/   /'
done
progress

hr "5. the fixed models against the new windows and pairs, and the final D_ROM (scripts/e9_3b_tools.py judge)"
python3 "$TOOLS" judge --plan3 "$W3/plan.json" --runs3 "$W3/runs" --plan "$WORK/plan.json" --runs "$WORK/runs" \
    --e91 "$E91" --bins "$W2/bins" --out "$WORK/e9_3b_summary.json" | tee "$WORK/e9_3b_summary.txt"
RC=${PIPESTATUS[0]}
echo
echo "---- files: $WORK ----"
du -sh "$WORK" 2>/dev/null | sed 's/^/   /'
echo
echo "=============================================================="
echo "Finished $(stamp)."
if [ "$RC" -eq 0 ]; then echo "E9.3b: all gates pass"; else echo "E9.3b: NOT ALL GATES PASS, see above"; fi
echo "Pack the results for checking:"
echo "   cd $PAPER2 && find reports/e9_rom/e9_3b -type f \\( -name '*.json' -o -name '*.txt' -o -name 'ngspice.log' -o -name bench.cmd \\) ! -name 'tb_*.txt' -size -20M > /tmp/e9_3b_list.txt && tar czf reports/e9_3b_results.tar.gz -T /tmp/e9_3b_list.txt"
echo "=============================================================="
[ "$RC" -eq 0 ]
