#!/usr/bin/env bash
# =============================================================================
# e8_5d_park_runs.sh   [run | status | stop]
#
# Experiment : P2R-E8.5d. The current of an address-map ROM macro parked on a
#              word with zero bits, over milliseconds, on the three macros
#              without a word of 0xFFFF (A_pcm_l04 k1, A_pcm_l18 k1,
#              B_pcm_l00 k1), D_ROM again with the measured curves, and the
#              rule on changing their parking words.
# Why        : D_ROM (E8.6a-3, rel5) counts their parked power as a constant
#              over the about 6 ms each is parked per inference (model A about
#              2.3 uJ, B about 0.47 uJ). In the sandbox (2026-10-19, claude/
#              p2r-e8-5d-sandbox.md) the output-buffer current after parking on
#              a word with zero bits decays to the leakage level within about
#              1-2 ms (25 C: the integral is about 1/24 of the constant).
#
# Steps
#   0  scripts/e8_5d_tools.py prep: the three macros, their Z words, current
#      parking words (rtl/e8/amu_park_<M>.vh) and 3 candidates each (lowest
#      static power of the per-bit model of E8.4b-rel5); the data files of the
#      two tables whose macros E8.5d generates
#   1  the runs of the macros that are already extracted (B_pcm_l00 k1, from
#      E8.4a-7) are written and started (at most E8_MAXJOBS - 2 at a time),
#      so that they run beside step 2
#   2  scripts/e8_5d_rom_macros.sh: generation, extraction, LVS and the tt
#      screening of every row of A_pcm_l04 k1 and A_pcm_l18 k1 (the flow of
#      E8.4a-11); skipped when both are already extracted and LVS-matched;
#      log reports/e8_5d_rom_macros.log
#   3  the other runs; at most E8_MAXJOBS simulations at a time. Every run:
#      post-layout, ngspice, the bench of E8.4b (reltol 1e-5, maximum time
#      step 500 ns, CS 10 ns after the clock edge, all bitlines saved), the
#      sequence idle, Z, the word (read in the next cycle: 50 ns of
#      precharge, as a parking read), then 3 ms with the clock low; the 16
#      output-buffer inputs saved as well (tb_buf.txt)
#        tt 25 C, 1.80 V : 3 macros x 4 words (current + 3 candidates) = 12
#        A_pcm_l04 k1, current word, the conditions of E8.4e: tt -40 C,
#        tt 85 C, ff 25 C, ss 25 C, ff 85 C (1.80 V) = 5
#   4  scripts/e8_5d_tools.py analyze: reads, margins, parked power against
#      time, the energy of a 6.08 ms parked interval (P1, A1)
#   5  scripts/e8_5d_tools.py drom: D_ROM (E8.6a-3's computation) with the
#      parked intervals of the three macros from the measured curves (tt 25 C,
#      current words); the word-change rule (P3); the conditions
#
# Rules (written before the run, claude/p2r-e8-5d-sandbox.md)
#   V  every macro: data = table, extracted without errors, LVS matched, the
#      words at their addresses (scripts/e8_5d_tools.py verify)
#   P1 every run complete; both reads correct with the right selection;
#      margins >= 0.10 V where the switching level of the condition is known
#   P2 the parked energy of an interval of T: the integral up to 3 ms, plus the
#      mean power of the last 100 us x (T - 3 ms) if that power is at most
#      2 x the leakage reference of the condition; else the leakage reference
#      x (T - 3 ms) plus an exponential tail fitted on the last 1 ms (flagged)
#   P3 change a parking word (RTL, amu_park_<M>.vh; a separate step) only if
#      the best candidate's parked energy over 6.08 ms is <= 50 % of the
#      current word's AND the model's D_ROM falls by >= 0.05 uJ
#   D1 the copy of E8.6a-3's replay with the constant power put back gives
#      E8.6a-3's D_ROM (relative difference < 1e-9); D1b the same for the
#      corrected value; D2 a curve for every zero-parked macro; D3 the macros
#      and parking words are E8.6a-3's
#
# Files      : scripts/e8_5d_park_runs.sh, e8_5d_tools.py, e8_5d_rom_macros.sh
#              (all NEW); uses e8_4_rom_bench.py, e8_6a3_rom_energy.py,
#              e8_6a2_rom_energy.py (unchanged)
# Needs      : reports/e8_rom/e8_4b_rel5/model.json, e8_6a3_rel5/d_rom.json,
#              e8_5/ (events), e8_4a7/ (B_pcm_l00 k1), trace/; rtl/e8/
#              amu_park_{A,B}.vh; data/; reports/e8_rom/macros/ and bins/ of
#              E8.3 table A_pcm_l00 (area reference of step 2); the E8.4e
#              folders e8_4b_c_<tag> for the switching levels and leakage at
#              the other conditions (else those margins are not judged and
#              those runs are extended linearly, flagged)
# Writes     : reports/e8_rom/e8_5d/ (step 0 and 2: tables, candidates.json,
#              macros), reports/e8_rom/e8_5d_park/ (runs, park.json,
#              d_rom_e85d.json), reports/e8_5d_rom_macros.log
# Run        : cd /mnt/d/Project/hybrid_memory/paper2
#              bash scripts/e8_5d_park_runs.sh 2>&1 | tee reports/e8_5d_park_runs.log
#              A second run keeps the finished simulations and redoes the rest.
# Status     : bash scripts/e8_5d_park_runs.sh status
# Stop       : bash scripts/e8_5d_park_runs.sh stop
# Options    : E8_MAXJOBS (default: cores - 1), E8_PARK_WAIT (ns, 3000000),
#              E8_TMAX (500), E8_CHECKPOINT (ns, 500000), E8_CONDS, E8_MARGIN
#              (0.10); testing only: E8_SKIP_MACROS=1, E8_TABLE_WORDS, E8_ROWS
# Runtime    : step 2 about 2.3 h (2 macros, E8.4a-11 on this machine); the
#              4 runs of B_pcm_l00 k1 beside it; then 13 runs, 7 at a time,
#              about 1 h each (estimate from the sandbox: 16-row macro, 2 ms
#              in 10 min): in all about 4.5 h. Disk: about 2 GB.
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
SKIP_MACROS="${E8_SKIP_MACROS:-}"
COND_MACRO="${E8_COND_MACRO:-e8rom_A_pcm_l04_16x${TW}_r${ROWS}k1}"
CONDS="${E8_CONDS-tt:-40:1.80:ttm40 tt:85:1.80:tt85 ff:25:1.80:ff25 ss:25:1.80:ss25 ff:85:1.80:ff85}"
ROOT="$PAPER2/reports/e8_rom"
OUT="$ROOT/e8_5d"
RUNS="$ROOT/e8_5d_park"
BENCH="$PAPER2/scripts/e8_4_rom_bench.py"
TOOLS="$PAPER2/scripts/e8_5d_tools.py"
MACROS_SH="$PAPER2/scripts/e8_5d_rom_macros.sh"
SELF=e8_5d_park_runs.sh
MODELS="$PDK_ROOT_DIR/sky130A/libs.tech/ngspice/sky130.lib.spice"
pick_path() { ls -d $1 2>/dev/null | sort -V | tail -1; }
NGSPICE="${E8_NGSPICE:-$(pick_path "/nix/store/*-ngspice-*/bin/ngspice")}"
NCORES=$(nproc 2>/dev/null || echo 4)
MAXJOBS="${E8_MAXJOBS:-$(( NCORES > 2 ? NCORES - 1 : 1 ))}"
EARLY=$(( MAXJOBS > 3 ? MAXJOBS - 2 : 1 ))
NTHREADS=1
stamp() { date "+%Y-%m-%d %H:%M:%S"; }
hr() { echo; echo "########## $* ##########"; }

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
    if [ "$(cat "$d/exit_code")" = 0 ] && [ -f "$d/tb_done" ] && [ ! -f "$d/tb_failed" ]; then echo "finished"
    else echo "FAILED (ngspice exit $(cat "$d/exit_code"))"; fi
  elif [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null; then echo "running, $(reached "$d") ms simulated"
  elif [ -f "$d/pid" ]; then echo "not running, stopped before the end"
  elif [ -f "$d/tb.sp" ]; then echo "written, not started"
  else echo "not written"; fi
}
done_ok() { [ "$(state "$1")" = finished ]; }

if [ "$MODE" = "status" ]; then
  echo "P2R-E8.5d parked-current runs, status at $(stamp)   ($RUNS)"
  R=$(other_runs | tr '\n' ' ')
  echo "   script: ${R:-not running}"
  for d in "$RUNS"/*__*; do
    [ -d "$d" ] || continue
    t0=$(cat "$d/started" 2>/dev/null || echo ""); t1=$(cat "$d/finished" 2>/dev/null || date +%s)
    printf "   %-40s %-36s %s\n" "$(basename "$d")" "$(state "$d")" "$( [ -n "$t0" ] && echo "$(( (t1 - t0) / 60 )) min")"
  done
  if [ -f "$MACROS_SH" ]; then echo; bash "$MACROS_SH" status 2>&1 | head -40; fi
  exit 0
fi

if [ "$MODE" = "stop" ]; then
  echo "P2R-E8.5d parked-current runs, stop at $(stamp)"
  R=$(other_runs | tr '\n' ' ')
  if [ -n "${R// /}" ]; then echo "   ending the running script: $R"; kill $R 2>/dev/null; sleep 2; fi
  [ -f "$MACROS_SH" ] && bash "$MACROS_SH" stop
  P=$(sims_in_runs | tr '\n' ' ')
  if [ -n "${P// /}" ]; then
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
echo "P2R-E8.5d parked current of the macros without a word of 0xFFFF, started $(stamp)"
echo "=============================================================="
cd "$PAPER2" || { echo "ERROR: no folder $PAPER2" >&2; exit 1; }
for F in "$BENCH" "$TOOLS" "$MACROS_SH" scripts/e8_6a3_rom_energy.py scripts/e8_6a2_rom_energy.py \
         "$ROOT/e8_4b_rel5/model.json" "$ROOT/e8_6a3_rel5/d_rom.json" "$ROOT/e8_5/e85_events_A.txt" \
         "$ROOT/e8_5/e85_events_B.txt" rtl/e8/amu_park_A.vh rtl/e8/amu_park_B.vh "$MODELS"; do
  [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
[ -n "$NGSPICE" ] || { echo "ERROR: ngspice not found" >&2; exit 1; }
grep -q -- "--tmax" "$BENCH" || { echo "ERROR: $BENCH has no --tmax (version 6 or later needed)" >&2; exit 1; }
for f in scripts/$SELF "$TOOLS" "$MACROS_SH" "$BENCH" scripts/e8_6a3_rom_energy.py scripts/e8_6a2_rom_energy.py \
         "$ROOT/e8_4b_rel5/model.json" "$ROOT/e8_6a3_rel5/d_rom.json" rtl/e8/amu_park_A.vh rtl/e8/amu_park_B.vh; do
  [ -f "$f" ] && echo "   $(md5sum "$f" | cut -c1-32)  $f"
done
echo "ngspice  : $NGSPICE"
echo "models   : $MODELS"
echo "runs     : idle, Z, word, ${WAIT_NS} ns clock low; reltol 1e-5, maximum time step ${TMAX} ns, checkpoints every ${CHECKPOINT} ns; CS ${CSD} ns after the edge"
echo "conds    : tt:25:1.80 for every word; for $COND_MACRO (current word) also: ${CONDS:-none}"
echo "jobs     : at most $MAXJOBS simulations at a time ($EARLY beside step 2)"
echo "machine  : $NCORES cores, $(free -g | awk '/Mem:/{print $2" GiB memory, "$7" GiB available"}'), $(df -h "$ROOT" 2>/dev/null | awk 'NR==2{print $4" free on the disk"}')"

hr "0. the macros, words and data files (scripts/e8_5d_tools.py prep)"
python3 "$TOOLS" prep --paper2 "$PAPER2" || { echo "ERROR: prep failed" >&2; exit 1; }
mkdir -p "$RUNS"
# one line per run: macro source role addr value z zaddr condition tag
SPECS="$RUNS/specs.txt"
python3 - "$OUT/candidates.json" "$COND_MACRO" "$CONDS" > "$SPECS" <<'PY' || { echo "ERROR: run list not written" >&2; exit 1; }
import json, sys
c = json.load(open(sys.argv[1]))["macros"]
conds = [x for x in sys.argv[3].split() if x]
for n, m in c.items():
    for w in m["words"]:
        role = w["role"].replace(" ", "")
        print(n, m["macro_from"], role, w["addr"], w["value"], w["z"], m["Z"]["addr"], "tt:25:1.80", "tt25")
        if n == sys.argv[2] and role == "current":
            for x in conds:
                corner, temp, vdd, tag = x.split(":")
                print(n, m["macro_from"], role, w["addr"], w["value"], w["z"], m["Z"]["addr"], f"{corner}:{temp}:{vdd}", tag)
PY
echo "   $(wc -l < "$SPECS") runs in $SPECS"
short() { local s=${1#e8rom_}; echo "${s/_16x$TW/}"; }
rdir() { echo "$RUNS/$(short "$1")__$2__$3"; }   # rdir MACRO ROLE TAG
ready() { [ -s "$ROOT/$2/$1/extract/$1.flat_pex.spice" ] && grep -q "match uniquely" "$ROOT/$2/$1/lvs/netgen.log" 2>/dev/null; }

LIST=()
write_run() {   # write_run MACRO SOURCE ROLE ADDR VALUE Z ZADDR COND TAG
  local n=$1 src=$2 role=$3 addr=$4 val=$5 z=$6 za=$7 c=$8 tag=$9 d corner temp vdd
  d=$(rdir "$n" "$role" "$tag")
  if done_ok "$d"; then
    echo "   $(basename "$d"): finished in an earlier run, kept"
    LIST+=("$d")
    return
  fi
  IFS=: read -r corner temp vdd <<< "$c"
  rm -rf "$d"
  mkdir -p "$d"
  echo "i,r$za,r$addr,w$WAIT_NS" > "$d/seq"
  if python3 "$BENCH" bench --sp "$ROOT/$src/$n/extract/$n.flat_pex.spice" --top "$n" --bin "$ROOT/$src/bins/$n.bin" \
       --word-bytes 2 --words-per-row "$WPR" --out "$d" --models "$MODELS" --period 100 \
       --seq "i,r$za,r$addr,w$WAIT_NS" --sanitize --plain-nfet --probes full --bitlines all \
       --corner "$corner" --temp "$temp" --vdd "$vdd" --cs-delay "$CSD" --reltol 1e-5 --tmax "$TMAX" \
       --checkpoint "$CHECKPOINT" > "$d/bench.txt" 2>&1 \
     && python3 "$TOOLS" addprobes --deck "$d/tb.sp" --top "$n" >> "$d/bench.txt" 2>&1; then
    grep -E "WARNING" "$d/bench.txt" | sed 's/^/      /'
    python3 - "$d/info.json" "$(short "$n") $role $c" "$n" "$c" "$role" "$addr" "$val" "$z" "$za" <<'PY'
import json, sys
f, label, n, c, role, addr, val, z, za = sys.argv[1:]
json.dump({"label": label, "macro": n, "cond": c, "role": role, "addr": int(addr), "value": val, "z": int(z),
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
  date +%s > "$d/started"
  ( cd "$d" || exit 99; "$NGSPICE" -b tb.sp > ngspice.log 2>&1; echo $? > exit_code; date +%s > finished ) &
  echo $! > "$d/pid"
  echo "   started $(basename "$d") at $(stamp)"
}
running() { local n=0 d; for d in "${LIST[@]}"; do [ -f "$d/pid" ] && [ ! -f "$d/exit_code" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null && n=$((n + 1)); done; echo $n; }
pump() {   # pump LIMIT: start written runs while fewer than LIMIT run
  local d
  for d in "${LIST[@]}"; do
    [ -f "$d/pid" ] && continue
    done_ok "$d" && continue
    [ "$(running)" -lt "$1" ] || return
    launch "$d"
  done
}
VERIFIED=""
write_ready() {   # write the runs of the macros that are ready and whose runs are not in LIST yet
  local n src role addr val z za c tag d x have
  while read -r n src role addr val z za c tag; do
    ready "$n" "$src" || continue
    d=$(rdir "$n" "$role" "$tag")
    have=0
    for x in "${LIST[@]}"; do [ "$x" = "$d" ] && have=1; done
    [ "$have" = 1 ] && continue
    case " $VERIFIED " in
      *" $n "*) ;;
      *" !$n "*) continue ;;
      *)
        if python3 "$TOOLS" verify --paper2 "$PAPER2" --macros "$n" > "$RUNS/verify_$(short "$n").txt" 2>&1; then
          VERIFIED="$VERIFIED $n"
        else
          VERIFIED="$VERIFIED !$n"
        fi
        sed 's/^/   /' "$RUNS/verify_$(short "$n").txt"
        case " $VERIFIED " in *" !$n "*) echo "   $n: verify FAILED, its runs are not written"; continue ;; esac ;;
    esac
    write_run "$n" "$src" "$role" "$addr" "$val" "$z" "$za" "$c" "$tag"
  done < "$SPECS"
}

hr "1. runs of the macros already extracted (started now, at most $EARLY at a time beside step 2)"
write_ready
echo "   ${#LIST[@]} runs written"
pump "$EARLY"

hr "2. generation, extraction, LVS and screening of the other macros (scripts/e8_5d_rom_macros.sh)"
need=0
while read -r n src; do
  if [ "$src" = e8_5d ] && ! ready "$n" "$src"; then need=1; fi
done < <(awk '{print $1, $2}' "$SPECS" | sort -u)
if [ -n "$SKIP_MACROS" ]; then
  echo "   skipped (E8_SKIP_MACROS, testing)"
elif [ "$need" -eq 0 ]; then
  echo "   already done (extracted netlists and LVS matched): skipped"
else
  echo "   started $(stamp); log reports/e8_5d_rom_macros.log"
  bash "$MACROS_SH" > reports/e8_5d_rom_macros.log 2>&1
  echo "   exit $? at $(stamp); log reports/e8_5d_rom_macros.log ($(wc -l < reports/e8_5d_rom_macros.log) lines)"
  grep -E "^ERROR|STORES THE DATA|extraction errors|match uniquely|PASS|FAIL" reports/e8_5d_rom_macros.log | head -20 | sed 's/^/   /'
fi

hr "3. the other runs (at most $MAXJOBS at a time)"
write_ready
echo "   ${#LIST[@]} runs written of $(wc -l < "$SPECS")"
last=$(date +%s)
while :; do
  pump "$MAXJOBS"
  left=0
  for d in "${LIST[@]}"; do if [ ! -f "$d/pid" ] && ! done_ok "$d"; then left=$((left + 1)); fi; done
  [ "$left" -eq 0 ] && [ "$(running)" -eq 0 ] && break
  if [ $(( $(date +%s) - last )) -ge "$HEARTBEAT" ]; then
    last=$(date +%s)
    echo "   progress at $(stamp):"
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

hr "4. analysis (scripts/e8_5d_tools.py analyze)"
if [ ${#LIST[@]} -gt 0 ]; then
  python3 "$TOOLS" analyze --paper2 "$PAPER2" --runs "${LIST[@]}" --margin "$MARGIN" --out "$RUNS/park.json"
else
  echo "   no runs"
fi

hr "5. D_ROM with the measured parked current (scripts/e8_5d_tools.py drom)"
if [ -f "$RUNS/park.json" ]; then
  python3 "$TOOLS" drom --paper2 "$PAPER2" --park "$RUNS/park.json" --cond-macro "$COND_MACRO" --out "$RUNS/d_rom_e85d.json"
else
  echo "   no park.json"
fi

echo
echo "=============================================================="
echo "Finished $(stamp). Pack for Claude:"
echo "  tar czf reports/e8_5d_results.tar.gz reports/e8_5d_park_runs.log reports/e8_5d_rom_macros.log reports/e8_rom/e8_5d/candidates.json reports/e8_rom/e8_5d_park/park.json reports/e8_rom/e8_5d_park/d_rom_e85d.json reports/e8_rom/e8_5d_park/*/analyze.txt reports/e8_rom/e8_5d_park/*/info.json"
echo "=============================================================="
