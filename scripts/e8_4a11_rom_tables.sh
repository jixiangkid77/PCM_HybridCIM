#!/usr/bin/env bash
# =============================================================================
# e8_4a11_rom_tables.sh   [run | status | stop]
#
# Experiment : P2R-E8.4a-11. The flow of E8.4a-10 (scripts/e8_4a10_rom_tables.sh,
#              unchanged except for the input and output folders, the labels,
#              the condition penalty that the verdict writes, and the model check
#              of scripts/e8_4a11_select.py) on the macros chosen by
#              scripts/e8_4a11_select.py: reports\e8_rom\e8_4a11\tables\
#              selected.txt (tables) and selected_macros.txt (macros): r48, T1,
#              every row of every chosen macro at tt, the worst rows of each
#              table's worst chosen macro at fs 25 C 1.80 V, tt 25 C 1.60 V and
#              fs -40 C 1.60 V, the margin rule of E8.4a-6.
#
# Why (2026-10-15)
#   - E8.4a-10: the 12 chosen macros all PASS, but one (B_pcm_l01 k0) is lower
#     than predicted by 110.7 mV (rule J3: at most 65 mV), so the model did not
#     cover the 316 macros not simulated.
#   - Sandbox (2026-10-15): the model fitted again with the 12 macros; leaving
#     one table out of the 30 simulated tables gives the largest error of a
#     cell in two groups (a strongly discharging neighbour or a sparse group;
#     the others); every cell gets a lower bound, every macro the lowest bound
#     of its cells. The rule fixed before this run (claude/
#     p2r-e8-4a11-sandbox.md) simulates every macro whose bound is below
#     1.151 V and adds the lowest bounds up to 12 macros; the last summary
#     checks the bound on them (rule J3) and the coverage of the others.
#
# Tables  : E8_TABLES, default reports\e8_rom\e8_4a11\tables\selected.txt;
#           data files reports\e8_rom\e8_4a11\tables\<table>.bin; only the
#           macros in reports\e8_rom\e8_4a11\tables\selected_macros.txt (all
#           macros of a table if the file is missing)
#
# Steps   : as E8.4a-10 (a. tools and files; b. cut, generate, stored bits,
#           layout extent, switching levels; c. extraction, LVS, screening of
#           every row at tt; d. condition runs of each table's worst macro and
#           rows; e. results and a verdict per table, and the condition penalty
#           of each table (tt margin - lowest condition margin) written to
#           reports\e8_rom\e8_4a11\penalty.txt); f. the model check
#           (scripts/e8_4a11_select.py check). No comparison with E8.4a-6.
#
# Needs   : reports\e8_rom\e8_4a11\tables\ (scripts/e8_4a11_select.py select);
#           reports\e8_rom\macros\ and reports\e8_rom\bins\ of E8.3 table
#           A_pcm_l00 for the area reference
# Writes  : only reports\e8_rom\e8_4a11\ (not tables\). A run replaces the
#           output of the tables it runs and keeps the others; it refuses to
#           start while an earlier run still works there.
# Run     : cd /mnt/d/Project/hybrid_memory/paper2
#           bash scripts/e8_4a11_rom_tables.sh 2>&1 | tee reports/e8_4a11_rom_tables.log
#           Keep the terminal open and the computer awake.
# Status  : bash scripts/e8_4a11_rom_tables.sh status 2>&1 | tee reports/e8_4a11_status.log
# Stop    : bash scripts/e8_4a11_rom_tables.sh stop
# Options : E8_TABLES, E8_ROWS (48), E8_CS_DELAY (10), E8_SCREEN_ROWS (rows - 1,
#           i.e. all), E8_SCREEN_WAIT (40), E8_CORNERS ("fs:25:1.80 tt:25:1.60
#           fs:-40:1.60"), E8_CORNER_ROWS (8), E8_OUTPUT_EXEMPT (fs:-40:1.60),
#           E8_MARGIN (0.10), E8_MAXGEN (4), E8_MAXMAGIC (4), E8_MAXJOBS
#           (cores - 1), E8_PERIOD (100), E8_TIMEOUT (0 = none), E8_HEARTBEAT
#           (1800 s between progress lines), E8_OPENRAM_PY.
#           Used only for testing: E8_WPR (13), E8_TABLE_WORDS (2496),
#           E8_USE_NIX, E8_OPENRAM_PDK.
# Runtime : 13 macros of 11 tables. From E8.4a-10 on this machine (7 jobs at a
#           time): generation about 1 min each; extraction 15-27 min each, 4 at a
#           time; screening of all 47 rows 1 h 43 min - 1 h 51 min each; condition
#           runs 9-17 min each, 3 per table. 8 macros took 3 h 59 min (about 30
#           min per macro), so about 6.5 hours. Disk: about 3.5 GB.
# =============================================================================
set -uo pipefail

MODE="${1:-run}"
PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
OPENRAM="${E8_OPENRAM:-/home/kid/openram/OpenRAM}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
TW="${E8_TABLE_WORDS:-2496}"
SUF="_16x$TW"
IN="$PAPER2/reports/e8_rom/e8_4a11/tables"
TABLES="${E8_TABLES:-$(cat "$IN/selected.txt" 2>/dev/null)}"
ROWS="${E8_ROWS:-48}"
WPR="${E8_WPR:-13}"
CSD="${E8_CS_DELAY:-10}"
SCREEN_ROWS="${E8_SCREEN_ROWS:-}"
SCREEN_WAIT="${E8_SCREEN_WAIT:-40}"
CORNERS="${E8_CORNERS:-fs:25:1.80 tt:25:1.60 fs:-40:1.60}"
CORNER_ROWS="${E8_CORNER_ROWS:-8}"
EXEMPT="${E8_OUTPUT_EXEMPT:-fs:-40:1.60}"
MARGIN="${E8_MARGIN:-0.10}"
PERIOD="${E8_PERIOD:-100}"
MAXGEN="${E8_MAXGEN:-4}"
MAXMAGIC="${E8_MAXMAGIC:-4}"
TIMEOUT="${E8_TIMEOUT:-0}"
HEARTBEAT="${E8_HEARTBEAT:-1800}"
ROOT="$PAPER2/reports/e8_rom"
BENCH="$PAPER2/scripts/e8_4_rom_bench.py"
MODELS="$PDK_ROOT_DIR/sky130A/libs.tech/ngspice/sky130.lib.spice"
MAGICRC="$PDK_ROOT_DIR/sky130A/libs.tech/magic/sky130A.magicrc"
NETGEN_SETUP="$PDK_ROOT_DIR/sky130A/libs.tech/netgen/sky130A_setup.tcl"
WORK="$ROOT/e8_4a11"
REPRO_T="none"                          # no comparison with E8.4a-6 in E8.4a-11
A6="$ROOT/e8_4a6/$REPRO_T"
WB=2
SELF="e8_4a11_rom_tables.sh"

pick_path() { ls -d $1 2>/dev/null | sort -V | tail -1; }
NGSPICE="${E8_NGSPICE:-$(pick_path "/nix/store/*-ngspice-*/bin/ngspice")}"
MAGIC="${E8_MAGIC:-$(pick_path "/nix/store/*magic-vlsi*/bin/magic")}"
NETGEN="${E8_NETGEN:-$(pick_path "/nix/store/*netgen*/bin/netgen")}"
NCORES=$(nproc 2>/dev/null || echo 4)
MAXJOBS="${E8_MAXJOBS:-$(( NCORES > 2 ? NCORES - 1 : 1 ))}"
NTHREADS=1          # sandbox, 2026-10-11: a second thread made a 32-row macro only 1.18 times faster

isnum() { python3 -c "import sys; float(sys.argv[1])" "$1" 2>/dev/null; }
case "$ROWS$SCREEN_WAIT$CORNER_ROWS$WPR$TW$MAXGEN$MAXMAGIC$MAXJOBS$PERIOD$TIMEOUT" in
  *[!0-9]*|"") echo "ERROR: E8_ROWS, E8_SCREEN_WAIT, E8_CORNER_ROWS, E8_WPR, E8_TABLE_WORDS, E8_MAXGEN, E8_MAXMAGIC, E8_MAXJOBS, E8_PERIOD, E8_TIMEOUT must be integers" >&2; exit 1 ;;
esac
[ "$ROWS" -ge 2 ] || { echo "ERROR: E8_ROWS must be at least 2" >&2; exit 1; }
for v in "$MAXGEN" "$MAXMAGIC" "$MAXJOBS" "$PERIOD" "$WPR" "$CORNER_ROWS"; do
  [ "$v" -ge 1 ] || { echo "ERROR: E8_MAXGEN, E8_MAXMAGIC, E8_MAXJOBS, E8_PERIOD, E8_WPR, E8_CORNER_ROWS must be at least 1" >&2; exit 1; }
done
[ -n "$SCREEN_ROWS" ] || SCREEN_ROWS=$((ROWS - 1))
case "$SCREEN_ROWS" in *[!0-9]*|"") echo "ERROR: E8_SCREEN_ROWS must be an integer" >&2; exit 1 ;; esac
[ "$SCREEN_ROWS" -ge 1 ] || { echo "ERROR: E8_SCREEN_ROWS must be at least 1" >&2; exit 1; }
[ "$SCREEN_ROWS" -le $((ROWS - 1)) ] || SCREEN_ROWS=$((ROWS - 1))
isnum "$CSD" || { echo "ERROR: E8_CS_DELAY must be a number of ns" >&2; exit 1; }
isnum "$MARGIN" || { echo "ERROR: E8_MARGIN must be a number of V" >&2; exit 1; }
for c in $CORNERS $EXEMPT; do
  case "$c" in *:*:*) ;; *) echo "ERROR: conditions are section:temperature:supply (got '$c')" >&2; exit 1 ;; esac
done
for t in $TABLES; do
  case "$t" in *[!A-Za-z0-9_]*) echo "ERROR: '$t' is not a table name" >&2; exit 1 ;; esac
  case "$t" in e8rom_*"$SUF") ;; *) echo "ERROR: $t is not a 16-bit x $TW table (E8.3 names: e8rom_..._16x2496)" >&2; exit 1 ;; esac
done

# ---- processes of a run of this script (for the guard and the stop mode) ----
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
    bash|sh) case "$a1" in ngspice|magic|netgen|"$SELF") return 0 ;; esac ;;
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
    st=${st##*) }
    set -- $st
    q=${2:-}
    n=$((n + 1))
  done
  return 1
}
procs_in_work() {   # this script's tools working in $WORK (a shell or viewer opened there is left alone)
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
ttag() {   # short tag of a table: e8rom_A_sram_l00_16x2496 -> A_sram00
  local x=${1#e8rom_}
  x=${x%"$SUF"}
  echo "${x/_l/}"
}
tab_names() { cat "$WORK/bins/$1.names" 2>/dev/null; }      # the macros of table $1
all_names() { local t; for t in $TABLES; do tab_names "$t"; done; }
tab_runs() {   # the condition runs of table $1 that exist
  local d
  for d in "$WORK/$1"/corner_*; do [ -f "$d/tb_meta.json" ] && echo "$d"; done
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
ext_state() {   # state of the extraction of macro $1
  local X="$WORK/$1/extract"
  if [ -f "$X/finished" ]; then echo "finished ($(( $(cat "$X/finished") - $(cat "$X/started") )) s, magic exit $(cat "$X/magic_exit" 2>/dev/null))"
  elif [ -f "$X/started" ]; then echo "running ($(( $(date +%s) - $(cat "$X/started") )) s)"
  else echo "not started"; fi
}
progress() {
  local t n L d
  echo "   progress at $(stamp):"
  for t in $TABLES; do
    for n in $(tab_names "$t"); do
      L="$WORK/$n/lvs"
      printf "      %-34s extraction %-34s LVS %-9s tt_cs %-12s %-6s %s\n" "$n" "$(ext_state "$n")" \
        "$( [ -f "$L/finished" ] && echo finished || ([ -f "$L/started" ] && echo running || echo -))" \
        "$(state "$WORK/$n/tt_cs")" "$(elapsed "$WORK/$n/tt_cs")" \
        "$( [ -f "$WORK/$n/tt_cs/tb_meta.json" ] && reached "$WORK/$n/tt_cs")"
    done
    for d in $(tab_runs "$t"); do
      printf "      %-34s %-40s %-6s %s\n" "$(ttag "$t")/${d##*/}" "$(state "$d")" "$(elapsed "$d")" "$(reached "$d")"
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
lvs_report() {   # lvs_report NAME
  local L="$WORK/$1/lvs"
  echo
  echo "---- $1: LVS $( [ -f "$L/finished" ] && echo "finished, $(( $(cat "$L/finished") - $(cat "$L/started") )) s" \
        || ([ -f "$L/started" ] && echo "running" || echo "not started")) ----"
  [ -f "$L/netgen.log" ] || return
  grep -E "^Circuit 1 contains|^Circuit 2 contains|Final result|match uniquely|do not match|ERROR|Error" \
      "$L/netgen.log" | tail -6 | sed 's/^/   /'
  if [ -f "$L/lvs_report.txt" ] && ! grep -q "match uniquely" "$L/netgen.log"; then
    awk '/(NET|DEVICE) mismatches/{f=1;n=0} /Netlists do not match|Subcircuit pins/{f=0} f&&n<60{print; n++}' \
        "$L/lvs_report.txt" | tail -120 | cut -c1-140 | sed 's/^/      /'
  fi
}
vm_of() {   # vm_of SECTION:TEMP:VDD -> the switching level measured in step b (empty if none)
  awk -v c="$1" '$1 == c {print $2}' "$WORK/vm/vm.txt" 2>/dev/null | head -1
}
cond_of() { cat "$1/cond" 2>/dev/null; }
short() { local x=${1#$WORK/}; x=${x//e8rom_/}; echo "${x//$SUF/}"; }
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
write_spec() {   # macrosum spec: every macro, one option per table, against the first table's E8.3 macro
  local f="$WORK/macros.json" first=1 t n t0
  t0="e8rom_A_pcm_l00$SUF"      # E8.3 reference macro
  {
    echo "{"
    printf '"reference": {"label": "%s (E8.3, %s rows)", "bin": "%s", "word_bytes": %s, "wpr": null, "lef": "%s", "box_log": "%s"},\n' \
      "$t0" "$((TW / WPR))" "$ROOT/bins/$t0.bin" "$WB" "$ROOT/macros/$t0/$t0.lef" "$WORK/area/$t0.box.log"
    echo '"macros": ['
    for t in $TABLES; do
      for n in $(tab_names "$t"); do
        [ $first -eq 1 ] || echo ","
        first=0
        printf '{"option": "%s", "label": "%s", "bin": "%s", "word_bytes": %s, "wpr": %s, "lef": "%s", "box_log": "%s", "bitcheck_log": "%s", "lvs_log": "%s", "extract_log": "%s"}' \
          "$(ttag "$t")" "$n" "$WORK/bins/$n.bin" "$WB" "$WPR" "$WORK/macros/$n/$n.lef" "$WORK/area/$n.box.log" \
          "$WORK/logs/bitcheck_$n.txt" "$WORK/$n/lvs/netgen.log" "$WORK/$n/extract/magic_extract.log"
      done
    done
    echo "]}"
  } > "$f"
}
verdicts() {   # one line per table: tt (every macro's screening) and every condition, with the margin rule
  local t n c args=""
  for t in $TABLES; do
    args="$args TABLE=$(ttag "$t")"
    for n in $(tab_names "$t"); do args="$args tt:25:1.80=$WORK/$n/tt_cs"; done
    [ -n "$(tab_names "$t")" ] || args="$args tt:25:1.80=$WORK/$t/no_macros"
    for c in $CORNERS; do args="$args $c=$WORK/$t/corner_$(corner_tag "$c")"; done
  done
  python3 - "$WORK/vm/vm.txt" "$MARGIN" "$EXEMPT" "tt:25:1.80 $CORNERS" $args <<'PY'
import json, os, sys
vmf, margin, exempt, conds = sys.argv[1], float(sys.argv[2]), set(sys.argv[3].split()), sys.argv[4].split()
vm = {}
try:
    for line in open(vmf):
        f = line.split()
        if len(f) == 2:
            vm[f[0]] = float(f[1])
except OSError:
    pass
tables, cur = [], None
for a in sys.argv[5:]:
    if a.startswith("TABLE="):
        cur = (a[6:], {})
        tables.append(cur)
        continue
    c, d = a.split("=", 1)
    cur[1].setdefault(c, []).append(d)
def stats(dirs):
    """reads, wrong, wrong selections, lowest target one-cell bitline, highest zero-cell bitline,
    and the runs that are missing or incomplete"""
    reads = wrong = sel = 0
    low = high0 = None
    missing = 0
    for d in dirs:
        try:
            r = json.load(open(os.path.join(d, "result.json")))
        except (OSError, ValueError):
            missing += 1
            continue
        s = r.get("summary", {})
        if s.get("failed") or s.get("cycles_complete") != s.get("cycles_total"):
            missing += 1
        cyc = r["meta"]["cycles"]
        rd = [(cy, x) for cy, x in zip(cyc, r["cycles"]) if cy["kind"] == "read" and x.get("complete")]
        if not rd:
            continue
        first = rd[0][0]["addr"]
        reads += len(rd)
        wrong += sum(1 for _, x in rd if not x.get("ok"))
        sel += sum(1 for _, x in rd if x.get("selection_ok") is False)
        for cy, x in rd:
            if cy["addr"] != first and x.get("bl1_min_V") is not None:
                low = x["bl1_min_V"] if low is None else min(low, x["bl1_min_V"])
            if x.get("bl0_max_V") is not None:
                high0 = x["bl0_max_V"] if high0 is None else max(high0, x["bl0_max_V"])
    return reads, wrong, sel, low, high0, missing
print(f"   rule: lowest one-cell bitline of the target reads - switching level >= {margin:.2f} V; highest zero-cell "
      f"bitline at sampling <= switching level - {margin:.2f} V; no wrong selection; every read correct "
      f"(at {' '.join(sorted(exempt)) or '-'} only the bitlines are judged)")
hdr = f"   {'table':<12}"
for c in conds:
    hdr += f" | {c:>21}"
print(hdr + " | verdict")
print(f"   {'':<12}" + "".join(f" | {'margin V (wrong/reads)':>21}" for _ in conds) + " |")
n_pass = n_fail = n_inc = 0
pens = []
for name, runs in tables:
    line = f"   {name:<12}"
    bad = incomplete = False
    mg = {}
    for c in conds:
        dirs = runs.get(c, [])
        reads, wrong, sel, low, high0, missing = stats(dirs)
        v = vm.get(c)
        if reads == 0 or low is None or v is None:
            why = "not run" if reads == 0 else ("no switching level" if v is None else "no one cell read")
            line += f" | {why:>21}"
            incomplete = True
            continue
        m = low - v
        mg[c] = m
        good = m >= margin and sel == 0 and (high0 is None or high0 <= v - margin)
        if c not in exempt:
            good = good and wrong == 0
        bad = bad or not good
        incomplete = incomplete or missing > 0
        cell = f"{m:+.3f} ({wrong}/{reads})" + ("" if good else " X") + (" ..." if missing else "")
        line += f" | {cell:>21}"
    verdict = "FAIL" if bad else ("INCOMPLETE" if incomplete else "PASS")
    if not incomplete and len(conds) > 1 and all(c in mg for c in conds):
        pens.append((name, mg[conds[0]] - min(mg[c] for c in conds[1:])))
    n_pass += verdict == "PASS"
    n_fail += verdict == "FAIL"
    n_inc += verdict == "INCOMPLETE"
    print(line + " | " + verdict)
print(f"   tables: {n_pass} PASS, {n_fail} FAIL, {n_inc} INCOMPLETE   (X: the cell breaks the rule; ...: a run "
      f"is missing, unfinished or failed; a FAIL is final, an INCOMPLETE table needs its missing runs)")
pf = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(vmf))), "penalty.txt")
with open(pf, "w") as fh:
    for nm_, p_ in pens:
        fh.write(f"{nm_} {p_:.4f}\n")
if pens:
    print(f"   condition penalty (tt margin - lowest condition margin), complete tables: " +
          ", ".join(f"{nm_} {p_:.3f}" for nm_, p_ in pens) + f"; largest {max(p_ for _, p_ in pens):.3f} V -> {pf}")
else:
    print(f"   condition penalty: no complete table yet ({pf} written empty)")
PY
}
crosstalk() {   # one-cell bitlines of the screenings: adjacent columns that discharge in the same read, depth
  local t n args=""
  for t in $TABLES; do
    args="$args TABLE=$(ttag "$t")"
    for n in $(tab_names "$t"); do args="$args $WORK/bins/$n.bin=$WORK/$n/tt_cs"; done
  done
  python3 - "$BENCH" "$WB" "$WPR" "$ROWS" $args <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("e8bench", sys.argv[1])
B = importlib.util.module_from_spec(spec)
spec.loader.exec_module(B)
wb, wpr, nrows = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
tables, cur = [], None
for a in sys.argv[5:]:
    if a.startswith("TABLE="):
        cur = (a[6:], [])
        tables.append(cur)
        continue
    b, d = a.split("=", 1)
    cur[1].append((b, d))
def lsq(X, y):
    """least squares by the normal equations (few unknowns)"""
    n = len(X[0])
    M = [[sum(r[i] * r[j] for r in X) for j in range(n)] for i in range(n)]
    v = [sum(r[i] * t for r, t in zip(X, y)) for i in range(n)]
    for i in range(n):
        p = max(range(i, n), key=lambda k: abs(M[k][i]))
        if abs(M[p][i]) < 1e-12:
            return None
        M[i], M[p], v[i], v[p] = M[p], M[i], v[p], v[i]
        for k in range(n):
            if k != i:
                f = M[k][i] / M[i][i]
                M[k] = [x - f * z for x, z in zip(M[k], M[i])]
                v[k] -= f * v[i]
    return [v[i] / M[i][i] for i in range(n)]
b1, b2 = max(1, round(nrows / 3)), max(2, round(2 * nrows / 3))
bands = [(1, b1 - 1), (b1, b2 - 1), (b2, nrows - 1)]
print("   one cells of the target reads (rows 1 and below) at tt: lowest bitline while evaluating, grouped by the")
print("   number of adjacent columns whose cell in the read row is a zero cell (they discharge in the same read)")
allp = []
for name, runs in tables:
    pts = []
    for binf, d in runs:
        try:
            r = json.load(open(os.path.join(d, "result.json")))
            data = open(binf, "rb").read()
        except (OSError, ValueError):
            continue
        meta = r["meta"]
        if meta.get("bitlines") != "all":
            continue
        _, w_, cols, rows = B.organisation(len(data), wb, wpr)
        bm = B.bitmap(data, wb, w_, cols)
        mac = os.path.basename(os.path.dirname(d.rstrip("/")))
        for cy, x in zip(meta["cycles"], r["cycles"]):
            if cy["kind"] != "read" or not x.get("complete") or cy["row"] == 0 or not x.get("bl1_by_col"):
                continue
            R = cy["row"]
            for cs, v in x["bl1_by_col"].items():
                c = int(cs)
                nb = sum(1 for cc in (c - 1, c + 1) if 0 <= cc < cols and bm[R][cc] == 0)
                run = 0
                while run < R and bm[R - 1 - run][c] == 0:
                    run += 1
                tr = sum(bm[i][c] for i in range(R))
                pts.append((v, R, nb, run, tr, mac, c))
    if not pts:
        print(f"   {name}: no finished screening")
        continue
    allp += pts
    nmac = len(set(p[5] for p in pts))
    print(f"\n   {name}: {len(pts)} one cells in {len(set((p[5], p[1]) for p in pts))} rows of {nmac} macros")
    line = "      neighbours discharging        "
    for k in (0, 1, 2):
        g = [p[0] for p in pts if p[2] == k]
        line += (f" | {k}: {len(g):6d} cells, mean {sum(g)/len(g):.3f} lowest {min(g):.3f} V" if g
                 else f" | {k}: {'none':>36}")
    print(line)
    line = "      lowest V by depth (rows)       "
    for lo, hi in bands:
        g = [p[0] for p in pts if lo <= p[1] <= hi]
        g2 = [p[0] for p in pts if lo <= p[1] <= hi and p[2] == 2]
        line += (f" | {lo:2d}-{hi:2d}: {min(g):.3f}" + (f" (2 neighbours {min(g2):.3f})" if g2 else "")) if g \
            else f" | {lo:2d}-{hi:2d}: -"
    print(line)
    co = lsq([(1.0, p[1], p[2], p[3]) for p in pts], [p[0] for p in pts]) if len(pts) > 8 else None
    if co:
        y = [p[0] for p in pts]
        ym = sum(y) / len(y)
        ss = sum((t - ym) ** 2 for t in y)
        sr = sum((t - (co[0] + co[1] * p[1] + co[2] * p[2] + co[3] * p[3])) ** 2 for t, p in zip(y, pts))
        print(f"      fit V = {co[0]:.3f} {co[1]*1e3:+.2f} mV x row {co[2]*1e3:+.1f} mV x neighbours "
              f"{co[3]*1e3:+.2f} mV x zero cells directly above (r^2 {1 - sr/ss if ss > 0 else float('nan'):.3f})")
    print("      lowest cells:  V      macro                              row  col (bit, word)  neighbours  "
          "zero run above  transistors above")
    for p in sorted(pts)[:5]:
        print(f"                  {p[0]:.3f}  {p[5]:<34} {p[1]:3d}  {p[6]:3d} ({p[6] // wpr:2d}, {p[6] % wpr:2d})"
              f"  {p[2]:10d}  {p[3]:14d}  {p[4]:17d}")
if allp and len(tables) > 1:
    print(f"\n   all tables: {len(allp)} one cells")
    for k in (0, 1, 2):
        g = [p[0] for p in allp if p[2] == k]
        if g:
            print(f"      {k} neighbours discharging: {len(g):7d} cells, mean {sum(g)/len(g):.3f} V, lowest {min(g):.3f} V")
PY
}
repro() {   # A_pcm_l00 generated again against E8.4a-6: the same circuit, the same first reads
  local n args=""
  case " $TABLES " in *" $REPRO_T "*) ;; *) return 0 ;; esac
  if [ ! -d "$A6" ]; then echo "   no E8.4a-6 output ($A6)"; return 0; fi
  for n in $(tab_names "$REPRO_T"); do args="$args $n=$WORK/$n/tt_cs=$A6/$n/tt_cs"; done
  [ -n "$args" ] || { echo "   no macro of $REPRO_T"; return 0; }
  python3 - $args <<'PY'
import hashlib, json, os, sys
def digests(p):
    """md5 of the netlist, and its numbers of devices (X lines) and capacitors (C lines)"""
    try:
        b = open(p, "rb").read()
    except OSError:
        return None, None
    lines = b.splitlines()
    return hashlib.md5(b).hexdigest(), (sum(1 for x in lines if x[:1] in (b"X", b"x")),
                                         sum(1 for x in lines if x[:1] in (b"C", b"c")))
key = lambda c: (c["kind"], c.get("addr"), c.get("len"))
n_ok = n_all = 0
for a in sys.argv[1:]:
    n, d7, d6 = a.split("=", 2)
    try:
        r7 = json.load(open(os.path.join(d7, "result.json")))
    except (OSError, ValueError):
        print(f"   {n}: no E8.4a-11 result")
        continue
    try:
        r6 = json.load(open(os.path.join(d6, "result.json")))
    except (OSError, ValueError):
        print(f"   {n}: no E8.4a-6 result ({d6})")
        continue
    f7, s7 = digests(os.path.join(d7, "netlist.sp"))
    f6, s6 = digests(os.path.join(d6, "netlist.sp"))
    net = ("identical" if f7 and f7 == f6 else
           f"not identical (devices {s7[0] if s7 else '-'} / {s6[0] if s6 else '-'}, capacitors "
           f"{s7[1] if s7 else '-'} / {s6[1] if s6 else '-'})")
    c7, c6 = r7["meta"]["cycles"], r6["meta"]["cycles"]
    k = 0
    while k < min(len(c7), len(c6)) and key(c7[k]) == key(c6[k]):
        k += 1
    n_r = diff = 0
    dv, de = [], []
    for j in range(k):
        if c7[j]["kind"] != "read":
            continue
        x7, x6 = r7["cycles"][j], r6["cycles"][j]
        if not (x7.get("complete") and x6.get("complete")):
            continue
        n_r += 1
        diff += (x7.get("ok"), x7.get("read_bits")) != (x6.get("ok"), x6.get("read_bits"))
        if x7.get("bl1_min_V") is not None and x6.get("bl1_min_V") is not None:
            dv.append(abs(x7["bl1_min_V"] - x6["bl1_min_V"]))
        if x6.get("E_vdd_pJ") and j < len(c6) - 1:     # the last cycle of a run ends with its simulation
            de.append(abs(x7["E_vdd_pJ"] / x6["E_vdd_pJ"] - 1))
    ok = n_r > 0 and k == len(c6) and diff == 0 and bool(dv) and max(dv) <= 0.005
    n_all += 1
    n_ok += ok
    print(f"   {n}: netlist {net}; the same sequence for {k} of E8.4a-6's {len(c6)} cycles; {n_r} reads compared, "
          f"{diff} with another result; largest difference of the lowest one-cell bitline "
          f"{max(dv) * 1e3 if dv else float('nan'):.3f} mV, of the read energy {100 * max(de) if de else float('nan'):.3f} % "
          f"(not E8.4a-6's last cycle, which ends with its simulation) -> {'consistent' if ok else 'NOT CONSISTENT'}")
if n_all:
    print(f"   {n_ok} of {n_all} macros consistent with E8.4a-6 (the same sequence, the same read results, lowest one-cell "
          f"bitlines within 5 mV)")
PY
}
summaries() {
  local t n dirs
  echo
  write_spec
  python3 "$BENCH" macrosum --spec "$WORK/macros.json"
  if [ -s "$WORK/vm/vm.txt" ]; then
    echo
    echo "switching level of the bitline inverter (a one bit needs its bitline above it):"
    sed 's/^/   /' "$WORK/vm/vm.txt"
  fi
  for t in $TABLES; do
    echo
    echo "==== table $t: $ROWS-row macros, CS $CSD ns after the clock ===="
    dirs=""
    for n in $(tab_names "$t"); do [ -f "$WORK/$n/tt_cs/result.json" ] && dirs="$dirs $WORK/$n/tt_cs"; done
    echo "   screening, tt, 25 C, 1.80 V ($SCREEN_ROWS rows of every macro):"
    condsum_dirs $dirs
    if [ -f "$WORK/$t/worst_macro" ]; then
      echo "   conditions on $(cat "$WORK/$t/worst_macro"), words $(cat "$WORK/$t/corner_words" 2>/dev/null):"
      condsum_dirs $(tab_runs "$t")
    fi
  done
  echo
  echo "==== verdict per table (tt: every screening read of the table; conditions: the worst rows of its worst macro) ===="
  verdicts
  echo
  echo "==== one-cell bitlines of the screenings (tt, 25 C, 1.80 V) ===="
  crosstalk
  echo
  echo "==== $(ttag "$REPRO_T") against E8.4a-6 (macros generated and extracted again, the same reads first) ===="
  repro
  if [ -s "$IN/predictions.json" ]; then
    echo
    echo "==== model check: measured against predicted one-cell bitlines (scripts/e8_4a11_select.py check) ===="
    python3 "$PAPER2/scripts/e8_4a11_select.py" check --paper2 "$PAPER2" --work "$WORK" --in-dir "$IN" 2>&1
  fi
}

if [ "$MODE" = "status" ]; then
  echo "=============================================================="
  echo "P2R-E8.4a-11 status, $(stamp)"
  echo "=============================================================="
  progress
  for n in $(all_names); do
    [ -f "$WORK/$n/lvs/started" ] && lvs_report "$n"
    [ -f "$WORK/$n/tt_cs/tb_meta.json" ] && report "$WORK/$n/tt_cs" "$n tt_cs"
  done
  for t in $TABLES; do
    for d in $(tab_runs "$t"); do report "$d" "$(short "$d") ($(cond_of "$d"), $(cat "$d/macro" 2>/dev/null))"; done
  done
  hr "summaries (as far as available)"
  summaries
  exit 0
fi

if [ "$MODE" = "stop" ]; then
  echo "P2R-E8.4a-11 stop, $(stamp)   ($WORK)"
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
echo "P2R-E8.4a-11 address-map tables, $ROWS-row macros, CS after the clock, started $(stamp)"
echo "=============================================================="
echo "tables   : $(for t in $TABLES; do printf '%s ' "$(ttag "$t")"; done)($(echo $TABLES | wc -w) tables, $ROWS rows per macro, $WPR words per row)"
echo "CS       : rises $CSD ns after the clock edge, falls with the clock"
echo "screening: $SCREEN_ROWS rows of every macro (deepest first), each after a read of row 0 and $((SCREEN_WAIT + PERIOD / 2)) ns of precharge; tt, 25 C, 1.80 V"
echo "conditions: $CORNERS ($CORNER_ROWS worst rows of each table's worst macro); bitlines only at: $EXEMPT"
echo "rule     : margin >= $MARGIN V at tt and every condition, every read correct"
echo "OpenRAM  : $OPENRAM  $(cat "$OPENRAM/VERSION" 2>/dev/null)  $(git -C "$OPENRAM" log -1 --format='%h %ad' --date=short 2>/dev/null)"
echo "ngspice  : ${NGSPICE:-<missing>}"
echo "magic    : ${MAGIC:-<missing>}"
echo "netgen   : ${NETGEN:-<missing>}"
echo "models   : $MODELS"
echo "period   : $PERIOD ns   at most $MAXJOBS magic or ngspice jobs at a time (ngspice threads: $NTHREADS)   time limit: $([ "$TIMEOUT" -gt 0 ] && echo "$TIMEOUT s" || echo none)"
echo "machine  : $NCORES cores, $(free -g | awk '/Mem:/{print $2" GiB memory, "$7" GiB available"}'), $(df -h "$ROOT" 2>/dev/null | awk 'NR==2{print $4" free on the disk"}')"

hr "a. tools, files and tables"
for F in "$BENCH" "$MODELS" "$MAGICRC" "$NETGEN_SETUP" "$OPENRAM/rom_compiler.py" "$OPENRAM/setpaths.sh" \
         "$PAPER2/scripts/e8_4a11_select.py"; do
  [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
[ -n "$NGSPICE" ] && [ -n "$MAGIC" ] && [ -n "$NETGEN" ] || { echo "ERROR: ngspice, magic or netgen not found" >&2; exit 1; }
grep -q "def cmd_condsum" "$BENCH" && grep -q "cs_delay" "$BENCH" \
  || { echo "ERROR: $BENCH is an older version; copy the one of 2026-10-12 (5)" >&2; exit 1; }
echo "   bench : $(md5sum "$BENCH" | cut -c1-32)  $BENCH"
"$NGSPICE" -v < /dev/null 2>&1 | grep -m1 -i "ngspice-" | sed 's/^/   /'
for c in "tt:25:1.80" $CORNERS; do
  IFS=: read -r sec tmp vdd <<< "$c"
  grep -qE "^\.lib[[:space:]]+$sec([[:space:]]|$)" "$MODELS" || { echo "ERROR: the model library has no section '$sec'" >&2; exit 1; }
done
GOODT=""
echo "   tables (reports/e8_rom/e8_4a11/tables):"
for t in $TABLES; do
  f="$IN/$t.bin"
  if [ ! -f "$f" ]; then
    echo "      $(printf '%-26s' "$t") SKIPPED: no $f"
    continue
  fi
  sz=$(stat -c %s "$f")
  if [ "$sz" != "$((TW * WB))" ]; then
    echo "      $(printf '%-26s' "$t") SKIPPED: $sz bytes (16-bit x $TW words is $((TW * WB)) bytes)"
    continue
  fi
  python3 - "$f" "$t" <<'PY'
import hashlib, sys
d = open(sys.argv[1], "rb").read()
w = [int.from_bytes(d[2 * i:2 * i + 2], "big") for i in range(len(d) // 2)]
z = sum(16 - bin(x).count("1") for x in w)
print(f"      {sys.argv[2]:<26} md5 {hashlib.md5(d).hexdigest()}  0xFFFF words {sum(1 for x in w if x == 0xFFFF):5d}  "
      f"zero bits {z} of {16 * len(w)} ({100 * z / (16 * len(w)):.2f} %)")
PY
  GOODT="$GOODT $t"
done
TABLES="${GOODT# }"
[ -n "$TABLES" ] || { echo "ERROR: no table to run" >&2; exit 1; }
if [ -s "$IN/selected_macros.txt" ]; then
  echo "   macros (selected_macros.txt, md5 $(md5sum "$IN/selected_macros.txt" | cut -c1-32)): $(grep -c . "$IN/selected_macros.txt") listed; the other macros of these tables are cut but not simulated"
else
  echo "   macros: no selected_macros.txt, every macro of every table"
fi
[ -s "$IN/predictions.json" ] && echo "   predictions: md5 $(md5sum "$IN/predictions.json" | cut -c1-32)  $IN/predictions.json"
case " $TABLES " in
  *" $REPRO_T "*) [ -d "$A6" ] && echo "   E8.4a-6 output for the comparison: $A6" \
                  || echo "   E8.4a-6 output not found ($A6): no comparison" ;;
esac

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
[ -n "$PY" ] || { echo "ERROR: no Python imports numpy, scipy and scikit-learn (see E8.3)" >&2; exit 1; }
echo "   using $PY"

# a run replaces the earlier output of the tables it runs, and nothing else
mkdir -p "$WORK"/{configs,macros,logs,area,bins,drive,vm} || exit 1
for t in $TABLES; do
  rm -rf "${WORK:?}/$t" "$WORK/bins/$t".* "$WORK/bins/${t}"_r* "$WORK/${t}"_r* "$WORK/macros/${t}"_r* \
         "$WORK/configs/${t}"_r* "$WORK/area/${t}".* "$WORK/area/${t}"_r* "$WORK/logs/"*"_${t}".* \
         "$WORK/logs/"*"_${t}"_r*
done
rm -f "$WORK"/drive/*

spiceinit() {
  cat > "$1/.spiceinit" <<EOF
* ngspice settings recommended for the sky130 models
set ngbehavior=hsa
set ng_nomodcheck
set skywaterpdk
set num_threads=$NTHREADS
EOF
}

hr "a. model sections: drive current of a 1 um / 0.15 um transistor at 25 C, 1.8 V (Vgs = Vds = 1.8 V)"
spiceinit "$WORK/drive"
drive() {   # drive SECTION: prints "NMOS_A PMOS_A"
  local f="$WORK/drive/$1.sp"
  cat > "$f" <<EOF
* P2R-E8.4a-11 drive check of model section $1
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
SECS="tt $(for c in $CORNERS; do echo "${c%%:*}"; done | grep -vx tt | sort -u | tr '\n' ' ')"
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
print(f"   {s:3s}  NMOS {n*1e6:7.1f} uA ({dn:+5.1f} %, {kind(dn)})   PMOS {p*1e6:7.1f} uA ({dp:+5.1f} %, {kind(dp)})")
PY
done
CORNERS_USED=""
for c in $CORNERS; do
  [ -n "${DRV[${c%%:*}]:-}" ] || { echo "   condition $c dropped: its drive check failed"; continue; }
  CORNERS_USED="$CORNERS_USED $c"
done
CORNERS="${CORNERS_USED# }"
echo "   conditions used: ${CORNERS:-none}"

hr "b. cut the tables, generate the macros ($MAXGEN at a time), stored bits, layout extent"
for t in $TABLES; do
  if ! python3 "$BENCH" split --bin "$IN/$t.bin" --word-bytes "$WB" --words-per-row "$WPR" --rows "$ROWS" \
       --out-prefix "$WORK/bins/${t}_r${ROWS}k" > "$WORK/logs/split_$t.txt" 2>&1; then
    echo "   $t: cannot cut the table:"; sed 's/^/      /' "$WORK/logs/split_$t.txt"; continue
  fi
  echo "   $(ttag "$t"):"; grep -v '^{' "$WORK/logs/split_$t.txt" | sed "s#$WORK/##; s/^/   /"
  ls "$WORK/bins/${t}_r${ROWS}k"*.bin 2>/dev/null | sort -V | while read -r f; do basename "$f" .bin; done > "$WORK/bins/$t.names"
  if [ -s "$IN/selected_macros.txt" ]; then     # E8.4a-11: only the macros chosen by scripts/e8_4a11_select.py
    grep -Fx -f "$IN/selected_macros.txt" "$WORK/bins/$t.names" > "$WORK/bins/$t.names.chosen"
    mv -f "$WORK/bins/$t.names.chosen" "$WORK/bins/$t.names"
    if [ -s "$WORK/bins/$t.names" ]; then
      echo "      simulated (selected_macros.txt): $(tr '\n' ' ' < "$WORK/bins/$t.names")"
    else
      echo "      WARNING: no macro of $t is in selected_macros.txt; the table is not simulated"
    fi
  fi
done
write_cfg() {   # write_cfg NAME
  local n=$1
  {
    echo "# P2R-E8.4a-11 ROM configuration for $n (generated by $SELF)."
    echo "# As E8.4a-5 (E8.3's configuration plus words_per_row)."
    echo 'tech_name = "sky130"'
    echo "nominal_corner_only = True"
    echo 'route_supplies = "ring"'
    echo "check_lvsdrc = False"
    echo "word_size = $WB"
    echo "rom_data = \"$WORK/bins/$n.bin\""
    echo 'data_type = "bin"'
    echo "output_name = \"$n\""
    echo "output_path = \"$WORK/macros/$n/\""
    echo "words_per_row = $WPR"
    [ -n "${E8_USE_NIX:-}" ] && echo "use_nix = $E8_USE_NIX"
  } > "$WORK/configs/$n.py"
}
gen() {   # gen NAME
  local n=$1 s rc
  s=$(date +%s)
  (
    cd "$OPENRAM" && source ./setpaths.sh >/dev/null 2>&1 || exit 99
    [ -n "${E8_OPENRAM_PDK:-}" ] && export PDK_ROOT="$E8_OPENRAM_PDK"
    "$PY" -u rom_compiler.py -v "$WORK/configs/$n.py"
  ) > "$WORK/logs/gen_$n.log" 2>&1
  rc=$?
  echo "   $n: exit $rc, $(( $(date +%s) - s )) s; $(grep -h 'Read rom data file' "$WORK/logs/gen_$n.log" | sed 's/.*Read rom data file: //')"
}
NAMES="$(all_names | tr '\n' ' ')"
[ -n "${NAMES// /}" ] || { echo "ERROR: no macro to generate" >&2; exit 1; }
nrun=0
for n in $NAMES; do
  write_cfg "$n"
  if [ "$nrun" -ge "$MAXGEN" ]; then wait -n; nrun=$((nrun - 1)); fi
  gen "$n" &
  nrun=$((nrun + 1))
done
wait
GOOD=""
for n in $NAMES; do
  ok=1
  for ext in sp gds lef; do
    [ -f "$WORK/macros/$n/$n.$ext" ] || { echo "   MISSING $n.$ext; the log ends with:"; tail -5 "$WORK/logs/gen_$n.log" | sed 's/^/      /'; ok=0; }
  done
  [ "$ok" = 1 ] && GOOD="$GOOD $n"
done
echo "   stored bits:"
for n in $GOOD; do
  python3 "$BENCH" bitcheck --sp "$WORK/macros/$n/$n.sp" --top "$n" --bin "$WORK/bins/$n.bin" \
      --word-bytes "$WB" --words-per-row "$WPR" > "$WORK/logs/bitcheck_$n.txt" 2>&1
  sed 's/^/      /' "$WORK/logs/bitcheck_$n.txt"
done
echo "   drawn layout extent (magic) and LEF (um):"
box() {   # box NAME GDS
  printf 'gds read %s\nload %s\nselect top cell\nbox\nquit -noprompt\n' "$2" "$1" > "$WORK/area/$1.box.tcl"
  PDK_ROOT="$PDK_ROOT_DIR" timeout 1800 "$MAGIC" -dnull -noconsole -rcfile "$MAGICRC" \
      < "$WORK/area/$1.box.tcl" > "$WORK/area/$1.box.log" 2>&1
  printf "      %-36s layout %-20s LEF %s\n" "$1" "$(grep -m1 '^microns:' "$WORK/area/$1.box.log" | awk '{print $2" x "$4}')" \
      "$(grep -m1 -E '^\s*SIZE' "$(dirname "$2")/$1.lef" 2>/dev/null | awk '{print $2" x "$4}')"
}
T0="e8rom_A_pcm_l00$SUF"      # E8.3 reference macro
if [ -f "$ROOT/macros/$T0/$T0.gds" ]; then
  box "$T0" "$ROOT/macros/$T0/$T0.gds"
else
  echo "      (no E8.3 macro of $T0 for the reference extent)"
fi
for n in $GOOD; do box "$n" "$WORK/macros/$n/$n.gds"; done

hr "b. switching level of the bitline inverter (DC, the input where the output equals it)"
spiceinit "$WORK/vm"
n1=$(echo $GOOD | awk '{print $1}')
INV=""
[ -n "$n1" ] && INV=$(python3 "$BENCH" invsize --sp "$WORK/macros/$n1/$n1.sp" --top "$n1" 2>&1)
echo "$INV" | sed "s/^/   $n1: /"
PW="" PL="" NW="" NL=""
read -r _ PW PL _ NW NL <<< "$(echo "$INV" | grep '^pfet ')"
VMNEW="$WORK/vm/vm_new.txt"
: > "$VMNEW"
if [ -n "$PW" ] && [ -n "$NL" ]; then
  for c in $(printf '%s\n' "tt:25:1.80" $CORNERS | awk '!seen[$0]++'); do
    IFS=: read -r sec tmp vdd <<< "$c"
    tag=$(corner_tag "$c")
    {
      echo "* P2R-E8.4a-11 switching level of the bitline inverter at $c"
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
      printf "%s %.3f\n" "$c" "$VM" >> "$VMNEW"
      printf "   %-14s %.3f V\n" "$c" "$VM"
    else
      echo "   $c: not measured (see $WORK/vm/$tag.log)"
    fi
  done
else
  echo "   inverter sizes not found: switching levels not measured"
fi
# keep the levels that an earlier run measured at other conditions (same inverter, same models)
if [ -s "$WORK/vm/vm.txt" ]; then
  awk 'FILENAME == ARGV[1] {seen[$1] = 1; next} !($1 in seen)' "$VMNEW" "$WORK/vm/vm.txt" > "$WORK/vm/vm_old.txt"
  if [ -s "$WORK/vm/vm_old.txt" ]; then
    echo "   kept from an earlier run: $(awk '{printf "%s %s  ", $1, $2}' "$WORK/vm/vm_old.txt")"
    cat "$WORK/vm/vm_old.txt" >> "$VMNEW"
  fi
  rm -f "$WORK/vm/vm_old.txt"
fi
mv "$VMNEW" "$WORK/vm/vm.txt"

hr "c-e. extraction, LVS and simulations (at most $MAXJOBS magic or ngspice jobs at a time; progress every $HEARTBEAT s)"
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
extract() {   # extract NAME: flat extraction for LVS and with parasitic capacitance (as E8.4a-2), in the background
  local n=$1 X="$WORK/$1/extract"
  mkdir -p "$X"
  cat > "$X/extract.tcl" <<EOF
drc off
gds flatten true
gds ordering true
gds read $WORK/macros/$n/$n.gds
load $n
select top cell
expand
readspice $WORK/macros/$n/$n.sp
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
ext2spice -o $X/$n.flat_lvs.spice
ext2spice cthresh 0
ext2spice -o $X/$n.flat_pex.spice
quit -noprompt
EOF
  date +%s > "$X/started"
  ( cd "$X" && PDK_ROOT="$PDK_ROOT_DIR" "$MAGIC" -dnull -noconsole -rcfile "$MAGICRC" < extract.tcl \
        > magic_extract.log 2>&1; echo $? > magic_exit; date +%s > finished ) &
  echo "   started the extraction of $n at $(stamp)"
}
EXTQ=()      # macros to extract, in order
SCRQ=()      # screening runs, in order
CORQ=()      # condition runs, in order (they start before waiting screenings)
running_ext() {
  local n=0 m
  for m in "${EXTQ[@]}"; do
    [ -f "$WORK/$m/extract/started" ] && [ ! -f "$WORK/$m/extract/finished" ] && n=$((n + 1))
  done
  echo $n
}
running_sims() {
  local n=0 d
  for d in "${CORQ[@]}" "${SCRQ[@]}"; do
    [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null && n=$((n + 1))
  done
  echo $n
}
pump() {   # extractions first (at most MAXMAGIC), then condition runs, then screenings, while fewer than MAXJOBS run
  local m d
  for m in "${EXTQ[@]}"; do
    [ -f "$WORK/$m/extract/started" ] && continue
    [ "$(running_ext)" -lt "$MAXMAGIC" ] || break
    [ $(( $(running_ext) + $(running_sims) )) -lt "$MAXJOBS" ] || return
    extract "$m"
  done
  for d in "${CORQ[@]}" "${SCRQ[@]}"; do
    [ -f "$d/pid" ] && continue
    [ $(( $(running_ext) + $(running_sims) )) -lt "$MAXJOBS" ] || return
    launch "$d"
  done
}
sim_done() {   # the run in DIR has ended (or was never written because its bench failed)
  local d=$1
  [ -f "$d/tb.sp" ] || return 0
  [ -f "$d/pid" ] && ! kill -0 "$(cat "$d/pid")" 2>/dev/null
}
write_bench() {   # write_bench QUEUE DIR NAME COND SEQ: post-layout bench of macro NAME at COND, CS delayed
  local Q=$1 D=$2 n=$3 COND=$4 SEQ=$5 sec tmp vdd
  IFS=: read -r sec tmp vdd <<< "$COND"
  mkdir -p "$D"
  echo "$COND" > "$D/cond"
  echo "$n" > "$D/macro"
  if python3 "$BENCH" bench --sp "$WORK/$n/extract/$n.flat_pex.spice" --top "$n" --bin "$WORK/bins/$n.bin" \
      --word-bytes "$WB" --words-per-row "$WPR" --out "$D" --models "$MODELS" --period "$PERIOD" --seq "$SEQ" \
      --sanitize --plain-nfet --probes full --bitlines all --corner "$sec" --temp "$tmp" --vdd "$vdd" \
      --cs-delay "$CSD" > "$D/bench.txt" 2>&1; then
    grep -E "WARNING" "$D/bench.txt" | sed 's/^/      /'
    case "$Q" in
      cor) CORQ+=("$D") ;;
      *) SCRQ+=("$D") ;;
    esac
  else
    echo "      ERROR: bench $(short "$D") not written:"; tail -3 "$D/bench.txt" | sed 's/^/      /'
  fi
}
post_extract() {   # post_extract NAME: checks, LVS, screening bench
  local n=$1 X="$WORK/$1/extract" NEG PROBE XE SEQ
  local LVSNET="$X/$n.flat_lvs.spice" PEXNET="$X/$n.flat_pex.spice"
  echo
  echo "   ---- $n: magic exit $(cat "$X/magic_exit"), $(( $(cat "$X/finished") - $(cat "$X/started") )) s ----"
  grep -iE "error|fatal|could not|not found|shorted" "$X/magic_extract.log" \
      | grep -v "boundary was redefined" | sort | uniq -c | sort -rn | head -8 | sed 's/^/   log: /'
  XE=$(grep -m1 -oE "Total of [0-9]+ errors" "$X/magic_extract.log" | grep -oE "[0-9]+")
  if [ -n "$XE" ]; then
    echo "   extraction errors: $XE  -> the layout is FAULTY (must be 0, even if LVS matches)"
  else
    echo "   extraction errors: 0"
  fi
  [ -f "$X/$n.ext" ] && python3 "$BENCH" shorts --ext "$X/$n.ext" | grep -v '^{' | sed 's/^/   /'
  [ -s "$LVSNET" ] && python3 "$BENCH" probe --sp "$LVSNET" --top "$n" 2>&1 | grep -E "^(devices|capacitors)" | sed 's/^/   LVS netlist: /'
  NEG=1
  if [ -s "$PEXNET" ]; then
    PROBE=$(python3 "$BENCH" probe --sp "$PEXNET" --top "$n" 2>&1)
    echo "$PROBE" | grep -E "^(devices|capacitors|negative)" | sed 's/^/   simulation netlist: /'
    NEG=$(echo "$PROBE" | grep '^{' | python3 -c "import json,sys; print(json.load(sys.stdin)['caps_negative'])" 2>/dev/null || echo 1)
  fi
  if [ -s "$LVSNET" ]; then
    mkdir -p "$WORK/$n/lvs"
    sed 's/sky130_fd_pr__special_nfet_01v8/sky130_fd_pr__nfet_01v8/g' "$LVSNET" > "$WORK/$n/lvs/layout.spice"
    date +%s > "$WORK/$n/lvs/started"
    ( cd "$WORK/$n/lvs" && "$NETGEN" -batch lvs "layout.spice $n" "$WORK/macros/$n/$n.sp $n" "$NETGEN_SETUP" \
          lvs_report.txt > netgen.log 2>&1; date +%s > finished ) &
    echo "   started LVS of $n at $(stamp)"
  fi
  if [ -s "$PEXNET" ] && [ "$NEG" = "0" ] && [ -z "$XE" ]; then
    SEQ=$(python3 "$BENCH" pick --bin "$WORK/bins/$n.bin" --word-bytes "$WB" --words-per-row "$WPR" --mode deep \
          --deep-rows "$SCREEN_ROWS" --waits "$SCREEN_WAIT" 2>"$WORK/$n/pick_screen.txt")
    if [ -n "$SEQ" ]; then
      echo "   screening: $(grep -E '^A = ' "$WORK/$n/pick_screen.txt" | cut -c1-200)..."
      write_bench scr "$WORK/$n/tt_cs" "$n" "tt:25:1.80" "$SEQ"
    else
      echo "   screening: no sequence:"; sed 's/^/      /' "$WORK/$n/pick_screen.txt"
    fi
  else
    echo "   post-layout simulation of $n NOT started: no netlist, negative capacitors ($NEG) or extraction errors (${XE:-0})"
  fi
}
select_and_queue() {   # select_and_queue TABLE: its worst macro and rows (tt, CS delayed); queue the conditions
  local t=$1 n dirs="" labs="" WRUN WWORDS WN SEQ c
  mkdir -p "$WORK/$t"
  for n in $(tab_names "$t"); do
    [ -f "$WORK/$n/tt_cs/tb_done" ] || continue
    python3 "$BENCH" analyze --dir "$WORK/$n/tt_cs" > "$WORK/$n/tt_cs/analyze.txt" 2>&1
    dirs="$dirs $WORK/$n/tt_cs"; labs="$labs $n"
  done
  echo
  echo "   ---- table $(ttag "$t"): selection from its screenings at $(stamp) ----"
  [ -n "$dirs" ] || { echo "   no finished screening: no condition runs for $t"; return; }
  python3 "$BENCH" margins --dirs $dirs --labels $labs --n "$CORNER_ROWS" --per-row > "$WORK/$t/select.txt" 2>&1
  sed -n '/^all runs/,$p' "$WORK/$t/select.txt" | grep -vE "^(WORST_RUN|WORST_WORDS|TARGET_READS|LOWEST_ONE_CELL_V) " \
    | sed 's/^/   /'
  WRUN=$(sed -n 's/^WORST_RUN //p' "$WORK/$t/select.txt")
  WWORDS=$(sed -n 's/^WORST_WORDS //p' "$WORK/$t/select.txt")
  if [ -z "$WRUN" ] || [ -z "$WWORDS" ]; then
    echo "   no words selected (see $WORK/$t/select.txt)"
    return
  fi
  WN=$(basename "$(dirname "$WRUN")")
  echo "$WN" > "$WORK/$t/worst_macro"
  echo "$WWORDS" > "$WORK/$t/corner_words"
  SEQ=$(python3 "$BENCH" pick --bin "$WORK/bins/$WN.bin" --word-bytes "$WB" --words-per-row "$WPR" --mode words \
        --addrs "$WWORDS" --waits "$SCREEN_WAIT" 2>"$WORK/$t/pick_corner.txt")
  if [ -z "$SEQ" ]; then
    echo "   no sequence for the conditions:"; sed 's/^/      /' "$WORK/$t/pick_corner.txt"
    return
  fi
  echo "   conditions on $WN, words $WWORDS: $CORNERS"
  for c in $CORNERS; do
    write_bench cor "$WORK/$t/corner_$(corner_tag "$c")" "$WN" "$c" "$SEQ"
  done
}

for n in $GOOD; do EXTQ+=("$n"); done
echo "   $(echo $GOOD | wc -w) extractions (at most $MAXMAGIC at a time), then $(echo $GOOD | wc -w) screenings of $SCREEN_ROWS rows,"
echo "   then $(echo $CORNERS | wc -w) condition runs per table; at most $MAXJOBS jobs at a time"
pump
progress
last=$(date +%s)
declare -A SELECTED
while :; do
  for n in "${EXTQ[@]}"; do
    X="$WORK/$n/extract"
    if [ -f "$X/finished" ] && [ ! -f "$X/post_done" ]; then
      touch "$X/post_done"
      post_extract "$n"
    fi
  done
  for t in $TABLES; do
    [ -n "${SELECTED[$t]:-}" ] && continue
    pending=0
    for n in $(tab_names "$t"); do
      case " $GOOD " in *" $n "*) ;; *) continue ;; esac
      [ -f "$WORK/$n/extract/post_done" ] || { pending=1; continue; }
      sim_done "$WORK/$n/tt_cs" || pending=1
    done
    if [ "$pending" = 0 ]; then
      SELECTED[$t]=1
      select_and_queue "$t"
    fi
  done
  pump
  busy=0
  for n in "${EXTQ[@]}"; do
    X="$WORK/$n/extract"
    [ -f "$X/post_done" ] || busy=1
    [ -f "$WORK/$n/lvs/started" ] && [ ! -f "$WORK/$n/lvs/finished" ] && busy=1
  done
  for d in "${CORQ[@]}" "${SCRQ[@]}"; do
    if [ ! -f "$d/pid" ] || kill -0 "$(cat "$d/pid")" 2>/dev/null; then busy=1; fi
  done
  for t in $TABLES; do [ -n "${SELECTED[$t]:-}" ] || busy=1; done
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
for n in $(all_names); do
  [ -f "$WORK/$n/lvs/started" ] && lvs_report "$n"
  [ -f "$WORK/$n/tt_cs/tb_meta.json" ] && report "$WORK/$n/tt_cs" "$n tt_cs"
done
for t in $TABLES; do
  for d in $(tab_runs "$t"); do report "$d" "$(short "$d") ($(cond_of "$d"), $(cat "$d/macro" 2>/dev/null))"; done
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
