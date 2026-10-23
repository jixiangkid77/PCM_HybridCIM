#!/usr/bin/env bash
# =============================================================================
# e8_4a2_rom_ext.sh   [run | status]
#
# Experiment : P2R-E8.4a-2. Layout check and post-layout simulation of one
#              address-map ROM macro (the step of E8.4a that failed), plus the
#              generator's netlist with corrected junction areas.
#
# Why this run (E8.4a, 2026-10-08/09, and the sandbox afterwards)
#   - E8.4a extracted the layout hierarchically ("ext2spice lvs"). That writes
#     the parent cells' capacitance corrections as negative capacitors (total
#     -18.131 pF). ngspice could not find an operating point (singular
#     matrix), so the two extracted simulations produced no data; the deck
#     retried the failed operating point at every checkpoint for 2h48m and
#     5h40m. This version extracts flat (positive capacitors only), and the
#     deck stops at the first segment that does not reach its checkpoint.
#   - In the sandbox (64-word ROM, same generator commit), the flat extracted
#     netlist read some words wrong. Two causes were found:
#       1. LVS (layout versus schematic) failed: the top-level supply routing
#          lands a via on the wire of the column decoder's address buffer
#          output (A0_out), shorting it to VDD. The column decoder then
#          always selects the same word.
#       2. With the layout's capacitance, the dynamic row decoder selects a
#          second row in every read of row 0: the decoder output of row 1
#          drops from 1.8 V to 0.85-0.86 V by charge sharing with the nodes
#          of its NMOS chain (the precharge raises them only to about
#          VDD - Vt, less if a read discharged them), and its wordline driver
#          switches (3 of 7 reads correct; with corrected junction areas but
#          no wire capacitance, 7 of 7 correct and the same output drops to
#          1.05 V).
#   - OpenRAM writes source/drain areas as "as=0.14u" while the PDK sets
#     ".option scale=1.0u", so in the generator's netlist the junction area
#     capacitance is 1e-6 of its value; the E8.4a schematic numbers miss it.
#   - Sandbox, full-size macro (16 bit x 2,496 words, 13 words per row, the
#     organisation of E8.3, synthetic data): LVS matched (45,538 devices and
#     22,196 nets on both sides) and no signal node is merged into a supply,
#     so the short above may be specific to the 64-word test macro; this run
#     checks the real macro. Its flat extraction has 176,241 capacitors
#     (16.682 pF, none negative); ngspice needs about 1.8 GB for it once the
#     cell transistors are written as sky130_fd_pr__nfet_01v8 (the PDK's
#     special_nfet_01v8 is a wrapper of it; with the wrapper, more than
#     7.5 GB). Its first post-layout reads (bottom row from full precharge,
#     then row 0) were correct and selected one row each; the lowest
#     unselected row-decoder output was 1.08 V and 1.06 V, so the decoder
#     margin is small there too.
#
# Questions on the real macro
#   1. Does the layout match the generator's netlist (netgen LVS)? If not,
#      which nets are merged (top-level merges into a supply net are listed).
#   2. Post-layout: function, selected rows and words, read energy, static
#      power, access time, recovery after a zero-heavy row.
#   3. The generator's netlist with corrected junction areas: same questions,
#      to separate device capacitance from wire capacitance.
#
# Steps
#   a. tools, files, the generator's netlist
#   b. the same two read sequences as E8.4a (main, recovery)
#   c. start the two simulations of the generator's netlist with corrected
#      junction areas (asad_main, asad_recovery)
#   d. magic, one session: extract the layout, write a flat netlist without
#      parasitics (for LVS) and a flat netlist with parasitic capacitance
#      (for simulation)
#   e. top-level supply merges; device and capacitor counts; start netgen LVS
#      and, if no capacitor is negative, the two post-layout simulations
#      (ext_main, ext_recovery)
#   f. wait for everything, printing progress every E8_HEARTBEAT seconds
#   g. results: LVS, each simulation, and a per-read comparison with E8.4a
#
# Every simulation saves all wordlines, the row-decoder outputs near the rows
# read, the column selects and a few bitlines, and writes its data after every
# clock period of simulated time. No time limit (E8_TIMEOUT, default 0).
#   bash scripts/e8_4a2_rom_ext.sh status
# analyses everything as far as it has got, while it keeps running.
#
# Macro   : e8rom_A_pcm_l00_16x2496 (override with E8_MACRO=...)
# Models  : sky130 TT corner, 25 C, 1.8 V; period 100 ns (E8_PERIOD)
# Place   : D:\Project\hybrid_memory\paper2\scripts\  (with e8_4_rom_bench.py
#           of 2026-10-09, which replaces the earlier one)
# Writes  : only reports\e8_rom\e8_4a2\<macro>\ (asad_main, asad_recovery,
#           extract, lvs, ext_main, ext_recovery). The E8.4a folder is only
#           read. A rerun overwrites the e8_4a2 folder of that macro.
# Run     : cd /mnt/d/Project/hybrid_memory/paper2
#           bash scripts/e8_4a2_rom_ext.sh 2>&1 | tee reports/e8_4a2_rom_ext.log
#           Keep the terminal open and the computer awake.
# Status  : bash scripts/e8_4a2_rom_ext.sh status 2>&1 | tee reports/e8_4a2_status.log
# Runtime : magic about 40-50 min (E8.4a: 37 min; sandbox flat extraction of
#           the full-size macro: 44 min on 2 shared cores). Generator-netlist
#           simulations about 20 min each (E8.4a: 16-19 min). Post-layout,
#           sandbox (2 cores, full-size macro): operating point and first
#           period about 11 min, then 2-4 min per period with a read; here
#           probably 1 to 2 hours for the 29-period recovery run. In all about
#           2 hours. Memory (sandbox): about 3 GB per generator-netlist
#           simulation and 2.6 GB per post-layout simulation.
# =============================================================================
set -uo pipefail

MODE="${1:-run}"
PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
MACRO="${E8_MACRO:-e8rom_A_pcm_l00_16x2496}"
PERIOD="${E8_PERIOD:-100}"
TIMEOUT="${E8_TIMEOUT:-0}"
HEARTBEAT="${E8_HEARTBEAT:-1800}"
ROOT="$PAPER2/reports/e8_rom"
SP="$ROOT/macros/$MACRO/$MACRO.sp"
GDS="$ROOT/macros/$MACRO/$MACRO.gds"
BIN="$ROOT/bins/$MACRO.bin"
BENCH="$PAPER2/scripts/e8_4_rom_bench.py"
MODELS="$PDK_ROOT_DIR/sky130A/libs.tech/ngspice/sky130.lib.spice"
MAGICRC="$PDK_ROOT_DIR/sky130A/libs.tech/magic/sky130A.magicrc"
NETGEN_SETUP="$PDK_ROOT_DIR/sky130A/libs.tech/netgen/sky130A_setup.tcl"
OLD="$ROOT/e8_4a/$MACRO"
WORK="$ROOT/e8_4a2/$MACRO"
EXT="$WORK/extract"
LVSNET="$EXT/$MACRO.flat_lvs.spice"
PEXNET="$EXT/$MACRO.flat_pex.spice"
RUNS="asad_main asad_recovery ext_main ext_recovery"
WB=2
case "$MACRO" in *_8x*) WB=1 ;; esac

pick() { ls -d $1 2>/dev/null | sort -V | tail -1; }
NGSPICE="${E8_NGSPICE:-$(pick "/nix/store/*-ngspice-*/bin/ngspice")}"
MAGIC="${E8_MAGIC:-$(pick "/nix/store/*magic-vlsi*/bin/magic")}"
NETGEN="${E8_NETGEN:-$(pick "/nix/store/*netgen*/bin/netgen")}"
NCORES=$(nproc 2>/dev/null || echo 4)
NTHREADS=$(( NCORES / 4 )); [ "$NTHREADS" -lt 1 ] && NTHREADS=1

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
  else echo "not running, stopped before the end"; fi
}

elapsed() {
  local d=$1 s e
  s=$(cat "$d/started" 2>/dev/null) || { echo "-"; return; }
  e=$(cat "$d/finished" 2>/dev/null || date +%s)
  printf "%dh%02dm" $(( (e - s) / 3600 )) $(( (e - s) % 3600 / 60 ))
}

progress() {
  echo "   progress at $(stamp):"
  for R in $RUNS; do
    printf "      %-14s %-40s %-8s %s\n" "$R" "$(state "$WORK/$R")" "$(elapsed "$WORK/$R")" \
      "$( [ -f "$WORK/$R/tb_meta.json" ] && reached "$WORK/$R")"
  done
  if [ -f "$WORK/lvs/finished" ]; then echo "      lvs            finished"
  elif [ -f "$WORK/lvs/started" ]; then echo "      lvs            running"; fi
}

report() {   # report RUN
  local d="$WORK/$1"
  echo; echo "---- $1: $(state "$d"), wall time $(elapsed "$d"), ngspice exit $(cat "$d/exit_code" 2>/dev/null || echo '-') ----"
  [ -f "$d/ngspice.log" ] || { echo "   no log"; return; }
  tr '\r' '\n' < "$d/ngspice.log" | grep -v "Reference value" \
    | grep -iE "error|could not|unknown|singular|timestep too small|abort|E8_FAILED" | sort | uniq -c \
    | sort -rn | head -8 | sed 's/^/   log: /'
  tr '\r' '\n' < "$d/ngspice.log" | grep -iE "total analysis time|total elapsed time" | head -2 | sed 's/^/   /'
  if [ ! -f "$d/tb_done" ]; then
    echo "   the log ends with:"
    tr '\r' '\n' < "$d/ngspice.log" | grep -v "Reference value" | grep -v '^\s*$' | tail -4 | sed 's/^/      /'
  fi
  python3 "$BENCH" analyze --dir "$d"
}

lvs_report() {
  local L="$WORK/lvs"
  echo
  echo "---- LVS (netgen $(basename "$(dirname "$(dirname "$NETGEN")")"), $(
        [ -f "$L/finished" ] && echo "finished, wall time $(( $(cat "$L/finished") - $(cat "$L/started") )) s" \
        || ([ -f "$L/started" ] && echo "running" || echo "not started")) ----"
  [ -f "$L/netgen.log" ] || return
  grep -E "^Circuit 1 contains|Final result|match uniquely|do not match|Top level cell|ERROR|Error" \
      "$L/netgen.log" | tail -6 | sed 's/^/   /'
  if [ -f "$L/lvs_report.txt" ]; then
    echo "   mismatch fragments in the report (top-level comparison, first 60 lines of each kind):"
    awk '/(NET|DEVICE) mismatches/{f=1;n=0} /Netlists do not match|Subcircuit pins/{f=0} f&&n<60{print; n++}' \
        "$L/lvs_report.txt" | tail -150 | cut -c1-140 | sed 's/^/      /'
  fi
}

if [ "$MODE" = "status" ]; then
  echo "=============================================================="
  echo "P2R-E8.4a-2 status, $(stamp)   ($MACRO)"
  echo "=============================================================="
  if [ -f "$EXT/finished" ]; then echo "extraction: finished"
  elif [ -f "$EXT/started" ]; then echo "extraction: running or stopped (started $(date -d @"$(cat "$EXT/started")" '+%F %T'))"
  else echo "extraction: not started"; fi
  progress
  lvs_report
  for R in $RUNS; do report "$R"; done
  exit 0
fi

echo "=============================================================="
echo "P2R-E8.4a-2 layout check and post-layout simulation, started $(stamp)"
echo "=============================================================="
echo "macro    : $MACRO  (word bytes $WB)"
echo "ngspice  : ${NGSPICE:-<missing>}"
echo "magic    : ${MAGIC:-<missing>}"
echo "netgen   : ${NETGEN:-<missing>}"
echo "models   : $MODELS (tt)"
echo "LVS setup: $NETGEN_SETUP"
echo "period   : $PERIOD ns   time limit per simulation: $([ "$TIMEOUT" -gt 0 ] && echo "$TIMEOUT s" || echo none)   threads per simulation: $NTHREADS"
echo "machine  : $NCORES cores, $(free -g | awk '/Mem:/{print $2" GiB memory, "$7" GiB available"}')"
for F in "$SP" "$GDS" "$BIN" "$BENCH" "$MODELS" "$MAGICRC" "$NETGEN_SETUP"; do
  [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
[ -n "$NGSPICE" ] && [ -n "$MAGIC" ] && [ -n "$NETGEN" ] || { echo "ERROR: ngspice, magic or netgen not found" >&2; exit 1; }
grep -q "fix-asad" "$BENCH" || { echo "ERROR: $BENCH is the old version; copy the 2026-10-09 one" >&2; exit 1; }
"$NGSPICE" -v < /dev/null 2>&1 | grep -m1 -i "ngspice-" | sed 's/^/   /'
for R in $RUNS extract lvs; do rm -rf "${WORK:?}/${R:?}"; done
mkdir -p "$EXT" "$WORK/lvs" || exit 1

spiceinit() {
  cat > "$1/.spiceinit" <<EOF
* ngspice settings recommended for the sky130 models
set ngbehavior=hsa
set ng_nomodcheck
set skywaterpdk
set num_threads=$NTHREADS
EOF
}

launch() {   # launch RUN: start ngspice in the background
  local d="$WORK/$1"
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
  echo "   started $1 at $(stamp)"
}

hr "a. the generator's netlist"
python3 "$BENCH" probe --sp "$SP" --top "$MACRO" 2>&1 | grep -v '^{' | grep -E "^(netlist|top|address|devices|capacitors)"

hr "b. read sequences (the same as E8.4a)"
SEQ_main=$(python3 "$BENCH" pick --bin "$BIN" --word-bytes "$WB" --mode main)
SEQ_recovery=$(python3 "$BENCH" pick --bin "$BIN" --word-bytes "$WB" --mode recovery 2>/dev/null)
echo "   main     : $SEQ_main"
echo "   recovery : $SEQ_recovery"
for Q in main recovery; do
  eval "SEQ=\$SEQ_$Q"
  if [ -f "$OLD/sch_$Q/tb_meta.json" ]; then
    python3 - "$OLD/sch_$Q/tb_meta.json" "$SEQ" "$Q" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
old = ",".join(("r%d" % c["addr"]) if c["kind"] == "read" else ("i" if c["kind"] == "idle" else "s1")
               for c in m["cycles"])
new = []
for tok in sys.argv[2].split(","):
    new += ["s1"] * int(tok[1:]) if tok.startswith("s") else [tok]
print(f"   {sys.argv[3]:9s}: {'same as' if old == ','.join(new) else 'DIFFERENT FROM'} the E8.4a sequence")
PY
  fi
done

hr "c. the generator's netlist with corrected junction areas (no wire capacitance)"
for Q in main recovery; do
  eval "SEQ=\$SEQ_$Q"
  python3 "$BENCH" bench --sp "$SP" --top "$MACRO" --bin "$BIN" --word-bytes "$WB" \
      --out "$WORK/asad_$Q" --models "$MODELS" --corner tt --period "$PERIOD" --seq "$SEQ" \
      --fix-asad --probes full \
    || { echo "ERROR: bench for asad_$Q not written" >&2; exit 1; }
  launch "asad_$Q"
done

hr "d. magic: flat extraction for LVS and with parasitic capacitance, meanwhile"
cat > "$EXT/extract.tcl" <<EOF
drc off
gds flatten true
gds ordering true
gds read $GDS
load $MACRO
select top cell
expand
readspice $SP
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
ext2spice -o $LVSNET
ext2spice cthresh 0
ext2spice -o $PEXNET
quit -noprompt
EOF
date +%s > "$EXT/started"
( cd "$EXT" && PDK_ROOT="$PDK_ROOT_DIR" "$MAGIC" -dnull -noconsole \
      -rcfile "$MAGICRC" < extract.tcl > magic_extract.log 2>&1 )
echo "   magic exit $?, wall time $(( $(date +%s) - $(cat "$EXT/started") )) s"
date +%s > "$EXT/finished"
grep -iE "error|fatal|could not|not found|shorted" "$EXT/magic_extract.log" \
    | grep -v "boundary was redefined" | sort | uniq -c | sort -rn | head -12 | sed 's/^/   log: /'
ls -la "$LVSNET" "$PEXNET" 2>/dev/null | sed 's/^/   /'

hr "e. layout checks"
echo "   signal nodes merged into a supply net by the top cell:"
if [ -f "$EXT/$MACRO.ext" ]; then
  python3 "$BENCH" shorts --ext "$EXT/$MACRO.ext" | grep -v '^{' | sed 's/^/   /'
else
  echo "   no $MACRO.ext"
fi
echo
echo "   netlist for LVS (no parasitics):"
[ -s "$LVSNET" ] && python3 "$BENCH" probe --sp "$LVSNET" --top "$MACRO" 2>&1 | grep -v '^{' \
    | awk '/^instances in the top cell/{exit} /^(top|devices|capacitors|negative|   )/' | head -20 | sed 's/^/   /'
echo "   netlist for simulation (with parasitic capacitance):"
NEG=1
if [ -s "$PEXNET" ]; then
  PROBE=$(python3 "$BENCH" probe --sp "$PEXNET" --top "$MACRO" 2>&1)
  echo "$PROBE" | grep -v '^{' | grep -E "^(top|devices|capacitors|negative)" | sed 's/^/   /'
  NEG=$(echo "$PROBE" | grep '^{' | python3 -c "import json,sys; print(json.load(sys.stdin)['caps_negative'])" 2>/dev/null || echo 1)
fi

# LVS in the background: the extracted netlist names the narrow cell
# transistors sky130_fd_pr__special_nfet_01v8 (the PDK defines it as the
# regular nfet_01v8, see the model file); the copy for netgen uses the
# generator's name so that the device classes compare
if [ -s "$LVSNET" ]; then
  sed 's/sky130_fd_pr__special_nfet_01v8/sky130_fd_pr__nfet_01v8/g' "$LVSNET" > "$WORK/lvs/layout.spice"
  date +%s > "$WORK/lvs/started"
  ( cd "$WORK/lvs" && "$NETGEN" -batch lvs "layout.spice $MACRO" "$SP $MACRO" "$NETGEN_SETUP" \
        lvs_report.txt > netgen.log 2>&1; date +%s > finished ) &
  echo "   started LVS at $(stamp)"
fi

if [ -s "$PEXNET" ] && [ "$NEG" = "0" ]; then
  echo "   start the post-layout simulations"
  for Q in main recovery; do
    eval "SEQ=\$SEQ_$Q"
    if python3 "$BENCH" bench --sp "$PEXNET" --top "$MACRO" --bin "$BIN" --word-bytes "$WB" \
        --out "$WORK/ext_$Q" --models "$MODELS" --corner tt --period "$PERIOD" --seq "$SEQ" \
        --sanitize --plain-nfet --probes full; then
      launch "ext_$Q"
    else
      echo "   ERROR: bench for ext_$Q not written; that simulation is skipped"
    fi
  done
else
  echo "   post-layout simulations NOT started: no netlist, or negative capacitors ($NEG)"
fi

hr "f. waiting (progress every $HEARTBEAT s)"
progress
last=$(date +%s)
while :; do
  alive=0
  for R in $RUNS; do
    [ -f "$WORK/$R/pid" ] && kill -0 "$(cat "$WORK/$R/pid")" 2>/dev/null && alive=1
  done
  [ -f "$WORK/lvs/started" ] && [ ! -f "$WORK/lvs/finished" ] && alive=1
  [ "$alive" -eq 0 ] && break
  sleep 30
  if [ $(( $(date +%s) - last )) -ge "$HEARTBEAT" ]; then
    progress
    last=$(date +%s)
  fi
done
wait 2>/dev/null
progress

hr "g. results"
lvs_report
for R in $RUNS; do report "$R"; done
for Q in main recovery; do
  echo
  echo "---- $Q: per-cycle comparison (E8.4a generator netlist | corrected junction areas | post-layout) ----"
  python3 "$BENCH" compare --dirs "$OLD/sch_$Q" "$WORK/asad_$Q" "$WORK/ext_$Q" \
      --labels "E8.4a sch" "asad" "post-layout"
done

echo
echo "---- files, all in the folder $WORK ----"
ls -la "$WORK"/asad_* "$WORK"/ext_* "$WORK"/lvs "$EXT" 2>/dev/null | grep -vE "\.ext$" | sed 's/^/   /'
echo
echo "=============================================================="
echo "Finished $(stamp)."
echo "=============================================================="
