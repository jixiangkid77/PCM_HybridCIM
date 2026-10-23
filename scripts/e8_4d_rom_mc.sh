#!/usr/bin/env bash
# =============================================================================
# e8_4d_rom_mc.sh   [run | status | stop]
#
# Experiment : P2R-E8.4d. Local-mismatch Monte Carlo of the address-map ROM
#              read margin at the worst places of E8.4a-10 (the lowest margins
#              of all 97 simulated macros): B_pcm_l01 k0 and B_pcm_l07 k1, each
#              at tt 25 C 1.80 V, fs 25 C 1.80 V, tt 25 C 1.60 V and
#              fs -40 C 1.60 V (8 sites), the worst read of each.
# Why        : E8.4a judged the margin at process corners only; local
#              (within-die) mismatch was not simulated (resubmission plan,
#              section 5.2, adopted 2026-10-19 21:34).
#
# Method (claude/p2r-e8-4d-sandbox.md)
#   - the extracted netlists of E8.4a-10 (no new generation); the bench of
#     E8.4a-10 (same options: T1, all bitlines saved), the sequence of its
#     condition runs for one word: idle, read of row 0, 40 ns, the worst read;
#     reltol 1e-5 (E8.4b-rel5's setting)
#   - mismatch: the PDK's sections tt_mm / fs_mm (mc_mm_switch=1), every
#     transistor of the macro varies; one sample = one ngspice run with its
#     own seed; the nominal section once per site (no mismatch) as reference
#   - each sample measures the switching level of all 208 bitline inverters
#     in the same run (switches from the bitlines to a common node, open
#     during the transient, then a DC sweep), so the margin of every one cell
#     uses its own inverter's level
#
# Steps      : 0 files and tools; 1 sites (scripts/e8_4d_rom_mc.py sites);
#              2 decks (prepare); 3 sample decks; 4 runs (at most E8_MAXJOBS at a
#              time; each finished sample is analysed at once and its large
#              waveform files deleted, except for the nominal run and the
#              first sample of each site); 5 analysis, gates and verdict
# Rules      : written before the run in claude/p2r-e8-4d-sandbox.md
# Files      : scripts/e8_4d_rom_mc.sh, scripts/e8_4d_rom_mc.py (both NEW);
#              uses scripts/e8_4_rom_bench.py (version 6 or later, unchanged)
# Needs      : reports/e8_rom/e8_4a10/ (extracted netlists, LVS logs, data
#              files, the tt screenings, the condition runs, vm/vm.txt); the
#              PDK library with the sections tt_mm and fs_mm
# Writes     : only reports/e8_rom/e8_4d/
# Run        : cd /mnt/d/Project/hybrid_memory/paper2
#              bash scripts/e8_4d_rom_mc.sh 2>&1 | tee reports/e8_4d_rom_mc.log
#              A second run keeps the finished samples and redoes the rest.
# Status     : bash scripts/e8_4d_rom_mc.sh status
# Stop       : bash scripts/e8_4d_rom_mc.sh stop
# Options    : E8_MC_N (samples per site, 30), E8_MAXJOBS (cores - 1),
#              E8_MC_SITES (site names, default all 8), E8_MARGIN (0.10),
#              E8_HEARTBEAT (1800 s); testing only: E8_MC_TABLES, E8_MC_CONDS,
#              E8_MODELS
# Runtime    : 8 sites x (30 + 2) = 256 runs of about 1 us each (390 ns of the
#              bench, 600 ns of ramps); estimated from the sandbox (966 s per
#              run beside another job) and E8.4a-10 on this machine: about
#              8-11 min per run with 7 at a time, i.e. about 5-7 h. Disk: about
#              1 GB (large waveform files are deleted after each run's analysis,
#              except for s0000 and s0001 of each site).
# =============================================================================
set -uo pipefail

MODE="${1:-run}"
PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
N="${E8_MC_N:-30}"
MARGIN="${E8_MARGIN:-0.10}"
HEARTBEAT="${E8_HEARTBEAT:-1800}"
ROOT="$PAPER2/reports/e8_rom"
A10="$ROOT/e8_4a10"
OUT="$ROOT/e8_4d"
BENCH="$PAPER2/scripts/e8_4_rom_bench.py"
TOOLS="$PAPER2/scripts/e8_4d_rom_mc.py"
SELF=e8_4d_rom_mc.sh
MODELS="${E8_MODELS:-$PDK_ROOT_DIR/sky130A/libs.tech/ngspice/sky130.lib.spice}"
pick_path() { ls -d $1 2>/dev/null | sort -V | tail -1; }
NGSPICE="${E8_NGSPICE:-$(pick_path "/nix/store/*-ngspice-*/bin/ngspice")}"
NCORES=$(nproc 2>/dev/null || echo 4)
MAXJOBS="${E8_MAXJOBS:-$(( NCORES > 2 ? NCORES - 1 : 1 ))}"
NTHREADS=1
stamp() { date "+%Y-%m-%d %H:%M:%S"; }
hr() { echo; echo "########## $* ##########"; }

# ---- processes (guard, status, stop); killed only by PID ----
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
sims_in_out() {   # ngspice processes working in $OUT
  local p c a0
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    c=$(readlink "/proc/$p/cwd" 2>/dev/null) || continue
    case "$c" in "$OUT"/*) ;; *) continue ;; esac
    a0=""
    { IFS= read -r -d '' a0; } 2>/dev/null < "/proc/$p/cmdline"
    [ "${a0##*/}" = ngspice ] && echo "$p"
  done
}
state() {   # state DIR
  local d=$1
  if [ -f "$d/exit_code" ]; then
    if [ "$(cat "$d/exit_code")" = 0 ] && [ -f "$d/tb_done" ] && [ ! -f "$d/tb_failed" ] && [ -f "$d/vm_done" ]; then
      echo "finished"
    else echo "FAILED (ngspice exit $(cat "$d/exit_code"))"; fi
  elif [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null; then echo "running"
  elif [ -f "$d/pid" ]; then echo "stopped before the end"
  elif [ -f "$d/tb.sp" ]; then echo "written"
  else echo "not written"; fi
}

if [ "$MODE" = "status" ]; then
  echo "P2R-E8.4d mismatch Monte Carlo, status at $(stamp)   ($OUT)"
  R=$(other_runs | tr '\n' ' ')
  echo "   script: ${R:-not running}"
  for s in "$OUT"/*/; do
    [ -d "$s/base" ] || continue
    nf=0 nr=0 nw=0 nx=0
    for d in "$s"[sr][0-9][0-9][0-9][0-9]; do
      [ -d "$d" ] || continue
      case "$(state "$d")" in finished) nf=$((nf + 1)) ;; running) nr=$((nr + 1)) ;; written) nw=$((nw + 1)) ;; *) nx=$((nx + 1)) ;; esac
    done
    printf "   %-28s finished %4d, running %2d, waiting %4d, failed or stopped %3d\n" "$(basename "$s")" $nf $nr $nw $nx
  done
  [ -f "$TOOLS" ] && [ -f "$OUT/sites.json" ] && python3 "$TOOLS" analyze --bench "$BENCH" --out "$OUT" --margin "$MARGIN" --quiet 2>&1 | tail -40
  exit 0
fi

if [ "$MODE" = "stop" ]; then
  echo "P2R-E8.4d mismatch Monte Carlo, stop at $(stamp)"
  R=$(other_runs | tr '\n' ' ')
  if [ -n "${R// /}" ]; then echo "   ending the running script: $R"; kill $R 2>/dev/null; sleep 2; fi
  P=$(sims_in_out | tr '\n' ' ')
  if [ -n "${P// /}" ]; then
    echo "   ending $(echo $P | wc -w) simulation(s): $P"
    kill $P 2>/dev/null; sleep 5
    P=$(sims_in_out | tr '\n' ' ')
    if [ -n "${P// /}" ]; then echo "   still running, forcing: $P"; kill -9 $P 2>/dev/null; sleep 1; fi
  fi
  R=$(other_runs | tr '\n' ' '); P=$(sims_in_out | tr '\n' ' ')
  if [ -n "${R// /}${P// /}" ]; then echo "   NOT everything ended (script: ${R:-none}; simulations: ${P:-none})"; exit 1; fi
  echo "   nothing of this script is running any more"
  exit 0
fi

[ "$MODE" = "run" ] || { echo "ERROR: unknown mode '$MODE' (run, status or stop)" >&2; exit 1; }
case "$N$MAXJOBS$HEARTBEAT" in *[!0-9]*|"") echo "ERROR: E8_MC_N, E8_MAXJOBS, E8_HEARTBEAT must be integers" >&2; exit 1 ;; esac
[ "$N" -ge 2 ] && [ "$MAXJOBS" -ge 1 ] || { echo "ERROR: E8_MC_N must be at least 2, E8_MAXJOBS at least 1" >&2; exit 1; }
R=$(other_runs | tr '\n' ' '); P=$(sims_in_out | tr '\n' ' ')
if [ -n "${R// /}${P// /}" ]; then
  echo "ERROR: an earlier run is still working (script: ${R:-none}; simulations in $OUT: ${P:-none})." >&2
  echo "       Let it finish, or end it first with: bash scripts/$SELF stop" >&2
  exit 1
fi

echo "=============================================================="
echo "P2R-E8.4d local-mismatch Monte Carlo of the ROM read margin, started $(stamp)"
echo "=============================================================="
cd "$PAPER2" || { echo "ERROR: no folder $PAPER2" >&2; exit 1; }
for F in "$BENCH" "$TOOLS" "$MODELS" "$A10/vm/vm.txt"; do
  [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
[ -n "$NGSPICE" ] && [ -x "$NGSPICE" ] || { echo "ERROR: ngspice not found (E8_NGSPICE)" >&2; exit 1; }
grep -q -- "--reltol" "$BENCH" || { echo "ERROR: $BENCH has no --reltol (version 6 or later needed)" >&2; exit 1; }
for sec in tt_mm fs_mm; do
  grep -qE "^\.lib[[:space:]]+$sec[[:space:]]*$" "$MODELS" || { echo "ERROR: $MODELS has no section $sec" >&2; exit 1; }
done
for f in scripts/$SELF "$TOOLS" "$BENCH" "$MODELS" "$A10/vm/vm.txt"; do
  echo "   $(md5sum "$f" | cut -c1-32)  $f"
done
echo "ngspice  : $NGSPICE ($("$NGSPICE" -v 2>/dev/null | grep -m1 -o 'ngspice-[0-9]*' || echo version unknown))"
echo "models   : $MODELS"
python3 - "$MODELS" <<'PY'
import re, sys
lines = open(sys.argv[1], errors="replace").read().split("\n")
for sec in ("tt", "tt_mm", "fs", "fs_mm"):
    i = next((k for k, l in enumerate(lines) if re.match(r"^\.lib\s+" + sec + r"\s*$", l)), None)
    if i is None:
        print(f"           section {sec}: not found")
        continue
    j = next((k for k in range(i + 1, len(lines)) if lines[k].lower().startswith(".endl")), len(lines))
    sw = [l.strip() for l in lines[i + 1:j] if "mc_mm_switch" in l.lower()]
    inc = [l.strip() for l in lines[i + 1:j] if l.lower().startswith((".include", ".lib"))]
    print(f"           section {sec}: {', '.join(sw) if sw else 'mc_mm_switch not set in the section itself'}; "
          f"{len(inc)} include line(s): {', '.join(x.split()[-1] for x in inc)[:150]}")
PY
echo "samples  : $N per site with mismatch, 1 nominal, 1 repeat; at most $MAXJOBS simulations at a time"
echo "machine  : $NCORES cores, $(free -g | awk '/Mem:/{print $2" GiB memory, "$7" GiB available"}'), $(df -h "$ROOT" 2>/dev/null | awk 'NR==2{print $4" free on the disk"}')"
mkdir -p "$OUT"

hr "1. sites: the worst read of each macro at each condition (E8.4a-10)"
SARGS=()
[ -n "${E8_MC_TABLES:-}" ] && SARGS+=(--tables "$E8_MC_TABLES")
[ -n "${E8_MC_CONDS:-}" ] && SARGS+=(--conds $E8_MC_CONDS)
python3 "$TOOLS" sites --bench "$BENCH" --work "$A10" --out "$OUT" "${SARGS[@]}" || { echo "ERROR: sites failed" >&2; exit 1; }
SITES="${E8_MC_SITES:-$(python3 -c "import json,sys; print(' '.join(s['name'] for s in json.load(open(sys.argv[1]))['sites']))" "$OUT/sites.json")}"
echo "   sites: $SITES"

hr "2. the deck of each site (scripts/e8_4d_rom_mc.py prepare)"
for s in $SITES; do
  python3 "$TOOLS" prepare --bench "$BENCH" --models "$MODELS" --out "$OUT" --site "$s" --keep \
    || { echo "ERROR: $s: deck not written" >&2; exit 1; }
done

hr "3. sample decks (scripts/e8_4d_rom_mc.py samples)"
for s in $SITES; do
  python3 "$TOOLS" samples --out "$OUT" --site "$s" --n "$N" --repeat 1 || { echo "ERROR: $s: samples" >&2; exit 1; }
done
# the order: every site's nominal run, then its first sample and the repeat, then the samples round-robin
LIST=()
for s in $SITES; do LIST+=("$OUT/$s/s0000"); done
for s in $SITES; do LIST+=("$OUT/$s/s0001" "$OUT/$s/r0001"); done
for k in $(seq 2 "$N"); do
  t=$(printf "s%04d" "$k")
  for s in $SITES; do LIST+=("$OUT/$s/$t"); done
done
echo "   ${#LIST[@]} runs"

hr "4. runs (at most $MAXJOBS at a time)"
clean() {   # remove what an earlier, unfinished run of this sample left
  local d=$1
  rm -f "$d"/{tb_out,tb_int,tb_wl}.{txt,part} "$d"/tb_out.txt.gz "$d"/{tb_done,tb_failed,vm_done,exit_code} \
        "$d"/{finished,started,pid,ngspice.log,ngspice.log.gz,result_mc.json,analyze.txt,mc.json}
}
launch() {
  local d=$1
  clean "$d"
  printf '* ngspice settings recommended for the sky130 models\nset ngbehavior=hsa\nset ng_nomodcheck\nset skywaterpdk\nset num_threads=%s\n' "$NTHREADS" > "$d/.spiceinit"
  date +%s > "$d/started"
  ( cd "$d" || exit 99; "$NGSPICE" -b tb.sp > ngspice.log 2>&1; echo $? > exit_code; date +%s > finished ) &
  echo $! > "$d/pid"
}
running() { local n=0 d; for d in "${LIST[@]}"; do [ -f "$d/pid" ] && [ ! -f "$d/exit_code" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null && n=$((n + 1)); done; echo $n; }
keep_waves() { case "$(basename "$1")" in s0000|s0001) return 0 ;; *) return 1 ;; esac; }
digest() {   # analyse a finished sample once; then delete its large waveform files (not for s0000, s0001)
  local d=$1
  [ -f "$d/mc.json" ] && return
  python3 "$TOOLS" one --bench "$BENCH" --out "$OUT" --dir "$d" > /dev/null 2>&1
  if [ -f "$d/mc.json" ] && ! keep_waves "$d"; then
    if python3 -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get('state') == 'finished' else 1)" "$d/mc.json"; then
      rm -f "$d/tb_int.txt" "$d/tb_wl.txt"
      gzip -f "$d/tb_out.txt" "$d/ngspice.log" 2>/dev/null
    fi
  fi
}
started_n=0
for d in "${LIST[@]}"; do [ "$(state "$d")" = finished ] && digest "$d"; done
echo "   finished in earlier runs: $(for d in "${LIST[@]}"; do [ "$(state "$d")" = finished ] && echo x; done | wc -l)"
last=$(date +%s); t_start=$(date +%s)
while :; do
  for d in "${LIST[@]}"; do
    [ "$(running)" -lt "$MAXJOBS" ] || break
    case "$(state "$d")" in finished|running) continue ;; esac
    if [ -f "$d/pid" ] && [ "$(cat "$d/started" 2>/dev/null || echo 0)" -ge "$t_start" ]; then continue; fi   # failed in this run
    launch "$d"; started_n=$((started_n + 1))
  done
  for d in "${LIST[@]}"; do [ "$(state "$d")" = finished ] && [ ! -f "$d/mc.json" ] && digest "$d"; done
  left=0
  for d in "${LIST[@]}"; do
    case "$(state "$d")" in finished) ;; running) left=$((left + 1)) ;;
      *) if [ -f "$d/pid" ] && [ "$(cat "$d/started" 2>/dev/null || echo 0)" -ge "$t_start" ]; then :; else left=$((left + 1)); fi ;;
    esac
  done
  [ "$left" -eq 0 ] && break
  if [ $(( $(date +%s) - last )) -ge "$HEARTBEAT" ]; then
    last=$(date +%s)
    nf=0; for d in "${LIST[@]}"; do [ "$(state "$d")" = finished ] && nf=$((nf + 1)); done
    echo "   progress at $(stamp): $nf of ${#LIST[@]} finished, $(running) running, $(df -h "$OUT" | awk 'NR==2{print $4}') free"
  fi
  sleep 20
done
wait 2>/dev/null
nf=0; nb=0
for d in "${LIST[@]}"; do if [ "$(state "$d")" = finished ]; then nf=$((nf + 1)); else nb=$((nb + 1)); echo "   $(basename "$(dirname "$d")")/$(basename "$d"): $(state "$d")"; fi; done
echo "   $nf finished, $nb not finished; started in this run: $started_n; $(stamp)"

hr "5. analysis (scripts/e8_4d_rom_mc.py analyze)"
python3 "$TOOLS" analyze --bench "$BENCH" --out "$OUT" --margin "$MARGIN" --json "$OUT/e8_4d_summary.json"

echo
echo "=============================================================="
echo "Finished $(stamp). Pack for Claude:"
echo "  tar czf reports/e8_4d_results.tar.gz reports/e8_4d_rom_mc.log reports/e8_rom/e8_4d/sites.json reports/e8_rom/e8_4d/e8_4d_summary.json reports/e8_rom/e8_4d/*/base/prepare.json reports/e8_rom/e8_4d/*/base/bench.txt reports/e8_rom/e8_4d/*/s0000/analyze.txt reports/e8_rom/e8_4d/*/s0001/analyze.txt"
echo "=============================================================="
