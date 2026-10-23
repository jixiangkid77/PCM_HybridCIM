#!/usr/bin/env bash
# =============================================================================
# e8_5f_allones_runs.sh   [run | status | stop]
#
# Experiment : P2R-E8.5f. The power of an address-map ROM macro parked on a
#              word of 0xFFFF, over 3 ms with the clock low.
# Why        : D_ROM holds the parked level of the macros parked on a word of
#              0xFFFF constant over milliseconds (rel5: 1.173 uW, the mean of
#              the first microsecond after a parking read). The macros parked on
#              a word with zero bits settle at 0.284-0.295 uW after 3 ms at
#              tt 25 C (E8.5d), a quarter of that level; whether the all-ones
#              level also falls over milliseconds decides whether D_ROM
#              overstates it (claude/p2r-e8-5d-results.md, section 8).
#
# Steps
#   0  scripts/e8_5f_tools.py prep: the macros (A_pcm_l00 k0-k3 and
#      A_sram_l00 k0-k1, extracted in E8.4a-7), their Z words and current
#      parking words (rtl/e8/amu_park_A.vh; each must be 0xFFFF)
#   1  scripts/e8_5f_tools.py verify (V1-V4)
#   2  the runs: post-layout, ngspice, the bench of E8.5d (reltol 1e-5,
#      maximum time step 500 ns, CS 10 ns after the clock edge, all bitlines
#      and the 16 output-buffer inputs saved); the sequence idle, Z, the
#      parking word (next cycle: 50 ns of precharge), then 3 ms with the clock
#      low
#        tt 25 C, 1.80 V : the 6 macros                                     6
#        A_pcm_l00 k0 also at tt -40 C, tt 85 C, ff 25 C, ss 25 C, ff 85 C   5
#      at most E8_MAXJOBS (3) at a time, and a run starts only while at least
#      E8_MEM_GB (4) GiB of memory are available (it may run beside E8.4f)
#   3  scripts/e8_5d_tools.py analyze (unchanged): reads, margins, the parked
#      power against time (P1, A1)
#   4  scripts/e8_5f_tools.py judge: F1 per side, F2
#
# Rules (written before the run, claude/p2r-e8-5f-sandbox.md)
#   V   data = table, extracted without errors, LVS matched, Z and the
#       parking word at their addresses, the parking word 0xFFFF
#   P1  as E8.5d: complete; both reads correct with the right selection;
#       margins >= 0.10 V where the switching level is known
#   F1  per side, Q = E(6.08 ms) / (L x 6.08 ms) of the tt 25 C runs, L the
#       macro's part-A parked level that D_ROM holds constant (rel5
#       model.json; the E8.4e folder at the other conditions); the side
#       decays if the median Q < 0.90 (at least 3 PCM runs and 1 SRAM run),
#       else it is constant
#   F2  information: R = P_end (last 100 us) / L; the first us of the run
#       against L; Q and R at the other conditions
#
# Files      : scripts/e8_5f_allones_runs.sh, e8_5f_tools.py (NEW); uses
#              e8_4_rom_bench.py, e8_5d_tools.py, e8_6a2_rom_energy.py
#              (unchanged)
# Needs      : reports/e8_rom/e8_4a7/ (the macros, bins/), e8_4b_rel5/model.json,
#              the E8.4e folders e8_4b_c_<tag> (switching levels and leakage at
#              the other conditions), rtl/e8/amu_park_A.vh, data/
# Writes     : reports/e8_rom/e8_5f/ (words.json), reports/e8_rom/e8_5f_park/
#              (runs, park.json, judge.json)
# Run        : cd /mnt/d/Project/hybrid_memory/paper2
#              bash scripts/e8_5f_allones_runs.sh 2>&1 | tee reports/e8_5f_allones_runs.log
#              A second run keeps the finished simulations and redoes the rest.
# Status     : bash scripts/e8_5f_allones_runs.sh status
# Stop       : bash scripts/e8_5f_allones_runs.sh stop
#              (ends only this script and the simulations in e8_5f_park, by PID)
# Options    : E8_MAXJOBS (3), E8_MEM_GB (4), E8_PARK_WAIT (ns, 3000000),
#              E8_TMAX (500), E8_CHECKPOINT (ns, 500000), E8_CONDS, E8_MARGIN
#              (0.10); testing only: E8_TABLE_WORDS, E8_ROWS, E8_MACROS
# Runtime    : about 20 min per run (E8.5d: 19-24 min); 11 runs, 3 at a time:
#              about 1.5 h. Disk: about 0.7 GB.
# =============================================================================
set -uo pipefail

MODE="${1:-run}"
PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
ROWS="${E8_ROWS:-48}"
WPR="${E8_WPR:-13}"
TW="${E8_TABLE_WORDS:-2496}"
WAIT_NS="${E8_PARK_WAIT:-3000000}"
TMAX="${E8_TMAX:-500}"
CHECKPOINT="${E8_CHECKPOINT:-500000}"
CSD="${E8_CS_DELAY:-10}"
MARGIN="${E8_MARGIN:-0.10}"
HEARTBEAT="${E8_HEARTBEAT:-1800}"
MEM_GB="${E8_MEM_GB:-4}"
MACROS="${E8_MACROS:-}"
COND_MACRO="${E8_COND_MACRO:-e8rom_A_pcm_l00_16x${TW}_r${ROWS}k0}"
CONDS="${E8_CONDS-tt:-40:1.80:ttm40 tt:85:1.80:tt85 ff:25:1.80:ff25 ss:25:1.80:ss25 ff:85:1.80:ff85}"
ROOT="$PAPER2/reports/e8_rom"
OUT="$ROOT/e8_5f"
RUNS="$ROOT/e8_5f_park"
BENCH="$PAPER2/scripts/e8_4_rom_bench.py"
TOOLS="$PAPER2/scripts/e8_5f_tools.py"
TOOLS5D="$PAPER2/scripts/e8_5d_tools.py"
SELF=e8_5f_allones_runs.sh
MODELS="$PDK_ROOT_DIR/sky130A/libs.tech/ngspice/sky130.lib.spice"
pick_path() { ls -d $1 2>/dev/null | sort -V | tail -1; }
NGSPICE="${E8_NGSPICE:-$(pick_path "/nix/store/*-ngspice-*/bin/ngspice")}"
NCORES=$(nproc 2>/dev/null || echo 4)
MAXJOBS="${E8_MAXJOBS:-3}"
NTHREADS=1
stamp() { date "+%Y-%m-%d %H:%M:%S"; }
hr() { echo; echo "########## $* ##########"; }
mem_avail_gb() { awk '/MemAvailable:/{printf "%d", $2 / 1048576}' /proc/meminfo; }

# ---- processes (guard, status, stop); killed only by PID ----
args01() { local a0="" a1=""; { IFS= read -r -d '' a0; IFS= read -r -d '' a1; } 2>/dev/null < "/proc/$1/cmdline"; echo "${a0##*/} ${a1##*/}"; }
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
  for p in $all; do   # a subshell of an instance (it waits for one simulation) has the instance as its parent
    { read -r st < "/proc/$p/stat"; } 2>/dev/null || continue
    st=${st##*) }
    set -- $st
    pp=${2:-}
    case " $all " in *" $pp "*) ;; *) echo "$p" ;; esac
  done
}
sims_in_runs() {   # ngspice processes working in $RUNS
  local p c a0 a1
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    c=$(readlink "/proc/$p/cwd" 2>/dev/null) || continue
    case "$c" in "$RUNS"/*) ;; *) continue ;; esac
    read -r a0 a1 <<< "$(args01 "$p")"
    [ "$a0" = ngspice ] && echo "$p"
  done
}
reached() { if [ -s "$1/tb_out.txt" ]; then tail -1 "$1/tb_out.txt" | awk '{printf "%.2f", $1 * 1e3}'; else echo "0.00"; fi; }
state() {   # state DIR
  local d=$1
  if [ -f "$d/exit_code" ]; then
    if [ -f "$d/stopped" ]; then echo "stopped by the stop command"
    elif [ "$(cat "$d/exit_code")" = 0 ] && [ -f "$d/tb_done" ] && [ ! -f "$d/tb_failed" ]; then echo "finished"
    else echo "FAILED (ngspice exit $(cat "$d/exit_code"))"; fi
  elif [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null; then echo "running, $(reached "$d") ms simulated"
  elif [ -f "$d/pid" ]; then echo "not running, stopped before the end"
  elif [ -f "$d/tb.sp" ]; then echo "written, not started"
  else echo "not written"; fi
}
done_ok() { [ "$(state "$1")" = finished ]; }

if [ "$MODE" = "status" ]; then
  echo "P2R-E8.5f all-ones parked runs, status at $(stamp)   ($RUNS)"
  R=$(other_runs | tr '\n' ' ')
  echo "   script: ${R:-not running}"
  echo "   memory available: $(mem_avail_gb) GiB"
  for d in "$RUNS"/*__*; do
    [ -d "$d" ] || continue
    t0=$(cat "$d/started" 2>/dev/null || echo ""); t1=$(cat "$d/finished" 2>/dev/null || date +%s)
    printf "   %-40s %-36s %s\n" "$(basename "$d")" "$(state "$d")" "$( [ -n "$t0" ] && echo "$(( (t1 - t0) / 60 )) min")"
  done
  exit 0
fi

if [ "$MODE" = "stop" ]; then
  echo "P2R-E8.5f all-ones parked runs, stop at $(stamp)"
  R=$(other_runs | tr '\n' ' ')
  if [ -n "${R// /}" ]; then echo "   ending the running script: $R"; kill $R 2>/dev/null; sleep 2; fi
  P=$(sims_in_runs | tr '\n' ' ')
  if [ -n "${P// /}" ]; then
    for p in $P; do d=$(readlink "/proc/$p/cwd" 2>/dev/null) && touch "$d/stopped"; done
    echo "   ending $(echo $P | wc -w) simulation(s): $P"
    kill $P 2>/dev/null; sleep 5
    P=$(sims_in_runs | tr '\n' ' ')
    if [ -n "${P// /}" ]; then echo "   still running, forcing: $P"; kill -9 $P 2>/dev/null; sleep 1; fi
  fi
  R=$(other_runs | tr '\n' ' '); P=$(sims_in_runs | tr '\n' ' ')
  if [ -n "${R// /}${P// /}" ]; then echo "   NOT everything ended (script: ${R:-none}; simulations: ${P:-none})"; exit 1; fi
  echo "   nothing of this script is running any more"
  exit 0
fi

[ "$MODE" = "run" ] || { echo "ERROR: unknown mode '$MODE' (run, status or stop)" >&2; exit 1; }
R=$(other_runs | tr '\n' ' '); P=$(sims_in_runs | tr '\n' ' ')
if [ -n "${R// /}${P// /}" ]; then
  echo "ERROR: an earlier run is still working (script: ${R:-none}; simulations in $RUNS: ${P:-none})." >&2
  echo "       Let it finish, or end it first with: bash scripts/$SELF stop" >&2
  exit 1
fi

echo "=============================================================="
echo "P2R-E8.5f power of the macros parked on a word of 0xFFFF over 3 ms, started $(stamp)"
echo "=============================================================="
cd "$PAPER2" || { echo "ERROR: no folder $PAPER2" >&2; exit 1; }
for F in "$BENCH" "$TOOLS" "$TOOLS5D" scripts/e8_6a2_rom_energy.py "$ROOT/e8_4b_rel5/model.json" \
         rtl/e8/amu_park_A.vh "$MODELS"; do
  [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
[ -n "$NGSPICE" ] || { echo "ERROR: ngspice not found" >&2; exit 1; }
grep -q -- "--tmax" "$BENCH" || { echo "ERROR: $BENCH has no --tmax (version 6 or later needed)" >&2; exit 1; }
for f in scripts/$SELF "$TOOLS" "$TOOLS5D" "$BENCH" scripts/e8_6a2_rom_energy.py "$ROOT/e8_4b_rel5/model.json" \
         rtl/e8/amu_park_A.vh; do
  [ -f "$f" ] && echo "   $(md5sum "$f" | cut -c1-32)  $f"
done
echo "ngspice  : $NGSPICE"
echo "models   : $MODELS"
echo "runs     : idle, Z, the parking word, ${WAIT_NS} ns clock low; reltol 1e-5, maximum time step ${TMAX} ns, checkpoints every ${CHECKPOINT} ns; CS ${CSD} ns after the edge"
echo "conds    : tt:25:1.80 for every macro; for $COND_MACRO also: ${CONDS:-none}"
echo "jobs     : at most $MAXJOBS simulations at a time, each started only with at least $MEM_GB GiB of memory available"
echo "machine  : $NCORES cores, $(free -g | awk '/Mem:/{print $2" GiB memory, "$7" GiB available"}'), $(df -h "$ROOT" 2>/dev/null | awk 'NR==2{print $4" free on the disk"}')"

hr "0. the macros and words (scripts/e8_5f_tools.py prep)"
if [ -n "$MACROS" ]; then
  python3 "$TOOLS" prep --paper2 "$PAPER2" --macros $MACROS || { echo "ERROR: prep failed" >&2; exit 1; }
else
  python3 "$TOOLS" prep --paper2 "$PAPER2" || { echo "ERROR: prep failed" >&2; exit 1; }
fi

hr "1. the macros (scripts/e8_5f_tools.py verify)"
python3 "$TOOLS" verify --paper2 "$PAPER2" || { echo "ERROR: verify failed: no run is written" >&2; exit 1; }

hr "2. the runs (at most $MAXJOBS at a time)"
mkdir -p "$RUNS"
SPECS="$RUNS/specs.txt"   # one line per run: macro source addr value z zaddr condition tag
python3 - "$OUT/words.json" "$COND_MACRO" "$CONDS" > "$SPECS" <<'PY' || { echo "ERROR: run list not written" >&2; exit 1; }
import json, sys
c = json.load(open(sys.argv[1]))["macros"]
conds = [x for x in sys.argv[3].split() if x]
for n, m in c.items():
    p, z = m["park"], m["Z"]
    print(n, m["macro_from"], p["addr"], p["value"], p["z"], z["addr"], "tt:25:1.80", "tt25")
    if n == sys.argv[2]:
        for x in conds:
            corner, temp, vdd, tag = x.split(":")
            print(n, m["macro_from"], p["addr"], p["value"], p["z"], z["addr"], f"{corner}:{temp}:{vdd}", tag)
PY
echo "   $(wc -l < "$SPECS") runs in $SPECS"
grep -q "$COND_MACRO" "$SPECS" || echo "   WARNING: $COND_MACRO is not among the macros: no runs at the other conditions"
short() { local s=${1#e8rom_}; echo "${s/_16x$TW/}"; }
rdir() { echo "$RUNS/$(short "$1")__park__$2"; }   # rdir MACRO TAG

LIST=()
write_run() {   # write_run MACRO SOURCE ADDR VALUE Z ZADDR COND TAG
  local n=$1 src=$2 addr=$3 val=$4 z=$5 za=$6 c=$7 tag=$8 d corner temp vdd
  d=$(rdir "$n" "$tag")
  local want="i,r$za,r$addr,w$WAIT_NS $c tmax $TMAX reltol 1e-5 cs $CSD"
  if done_ok "$d" && [ "$(cat "$d/seq" 2>/dev/null)" = "$want" ]; then
    echo "   $(basename "$d"): finished in an earlier run with the same settings, kept"
    LIST+=("$d")
    return
  fi
  IFS=: read -r corner temp vdd <<< "$c"
  rm -rf "$d"
  mkdir -p "$d"
  echo "$want" > "$d/seq"
  if python3 "$BENCH" bench --sp "$ROOT/$src/$n/extract/$n.flat_pex.spice" --top "$n" --bin "$ROOT/$src/bins/$n.bin" \
       --word-bytes 2 --words-per-row "$WPR" --out "$d" --models "$MODELS" --period 100 \
       --seq "i,r$za,r$addr,w$WAIT_NS" --sanitize --plain-nfet --probes full --bitlines all \
       --corner "$corner" --temp "$temp" --vdd "$vdd" --cs-delay "$CSD" --reltol 1e-5 --tmax "$TMAX" \
       --checkpoint "$CHECKPOINT" > "$d/bench.txt" 2>&1 \
     && python3 "$TOOLS5D" addprobes --deck "$d/tb.sp" --top "$n" >> "$d/bench.txt" 2>&1; then
    grep -E "WARNING" "$d/bench.txt" | sed 's/^/      /'
    python3 - "$d/info.json" "$(short "$n") park $c" "$n" "$c" "$addr" "$val" "$z" "$za" <<'PY'
import json, sys
f, label, n, c, addr, val, z, za = sys.argv[1:]
json.dump({"label": label, "macro": n, "cond": c, "role": "parking", "addr": int(addr), "value": val, "z": int(z),
           "z_addr": int(za)}, open(f, "w"), indent=1)
PY
    LIST+=("$d")
  else
    echo "   ERROR: bench of $(basename "$d") not written:"; tail -3 "$d/bench.txt" | sed 's/^/      /'
  fi
}
launch() {
  local d=$1
  printf '* ngspice settings recommended for the sky130 models\nset ngbehavior=hsa\nset ng_nomodcheck\nset skywaterpdk\nset num_threads=%s\n' "$NTHREADS" > "$d/.spiceinit"
  rm -f "$d/stopped"
  date +%s > "$d/started"
  ( cd "$d" || exit 99; "$NGSPICE" -b tb.sp > ngspice.log 2>&1; echo $? > exit_code; date +%s > finished ) &
  echo $! > "$d/pid"
  echo "   started $(basename "$d") at $(stamp) ($(mem_avail_gb) GiB available)"
}
running() { local n=0 d; for d in "${LIST[@]}"; do [ -f "$d/pid" ] && [ ! -f "$d/exit_code" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null && n=$((n + 1)); done; echo $n; }
WAITED=""
pump() {   # start written runs while fewer than MAXJOBS run and memory allows
  local d
  for d in "${LIST[@]}"; do
    [ -f "$d/pid" ] && continue
    done_ok "$d" && continue
    [ "$(running)" -lt "$MAXJOBS" ] || return
    if [ "$(mem_avail_gb)" -lt "$MEM_GB" ]; then
      [ -z "$WAITED" ] && echo "   $(stamp): only $(mem_avail_gb) GiB of memory available (< $MEM_GB): waiting before the next start"
      WAITED=1
      return
    fi
    WAITED=""
    launch "$d"
  done
}
while read -r n src addr val z za c tag; do
  write_run "$n" "$src" "$addr" "$val" "$z" "$za" "$c" "$tag"
done < "$SPECS"
echo "   ${#LIST[@]} runs written of $(wc -l < "$SPECS")"
last=$(date +%s)
while :; do
  pump
  left=0
  for d in "${LIST[@]}"; do if [ ! -f "$d/pid" ] && ! done_ok "$d"; then left=$((left + 1)); fi; done
  [ "$left" -eq 0 ] && [ "$(running)" -eq 0 ] && break
  if [ $(( $(date +%s) - last )) -ge "$HEARTBEAT" ]; then
    last=$(date +%s)
    echo "   progress at $(stamp) ($(mem_avail_gb) GiB available):"
    for d in "${LIST[@]}"; do printf "      %-40s %s\n" "$(basename "$d")" "$(state "$d")"; done
  fi
  sleep 30
done
wait 2>/dev/null
for d in "${LIST[@]}"; do
  if [ ! -f "$d/result.json" ] || [ "$d/exit_code" -nt "$d/result.json" ]; then
    python3 "$BENCH" analyze --dir "$d" > "$d/analyze.txt" 2>&1
  fi
  t0=$(cat "$d/started" 2>/dev/null || echo 0); t1=$(cat "$d/finished" 2>/dev/null || echo "$t0")
  echo "   $(basename "$d"): $(state "$d"), $(( (t1 - t0) / 60 )) min; $(grep -m1 '^data:' "$d/analyze.txt" 2>/dev/null | cut -c7-)"
done

hr "3. analysis (scripts/e8_5d_tools.py analyze)"
if [ ${#LIST[@]} -gt 0 ]; then
  python3 "$TOOLS5D" analyze --paper2 "$PAPER2" --runs "${LIST[@]}" --margin "$MARGIN" --out "$RUNS/park.json"
else
  echo "   no runs"
fi

hr "4. judgment (scripts/e8_5f_tools.py judge)"
if [ -f "$RUNS/park.json" ]; then
  python3 "$TOOLS" judge --paper2 "$PAPER2" --park "$RUNS/park.json" --out "$RUNS/judge.json"
else
  echo "   no park.json"
fi

echo
echo "=============================================================="
echo "Finished $(stamp). Pack for Claude:"
echo "  tar czf reports/e8_5f_results.tar.gz reports/e8_5f_allones_runs.log reports/e8_rom/e8_5f/words.json reports/e8_rom/e8_5f_park/park.json reports/e8_rom/e8_5f_park/judge.json reports/e8_rom/e8_5f_park/*/analyze.txt reports/e8_rom/e8_5f_park/*/info.json"
echo "=============================================================="
