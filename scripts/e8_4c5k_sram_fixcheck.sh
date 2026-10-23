#!/usr/bin/env bash
# =============================================================================
# e8_4c5k_sram_fixcheck.sh
#
# Experiment : P2R-E8.4c-5K. The 5 KB SRAM macro of the manuscript (the feature buffer,
#              sky130_sram_5kbytes_1rw_8x5120_8; the manuscript uses its area, E8.1b) has the same short as the
#              4 KB macro (E8.4c-0b, 2026-10-16: control_logic p_en_bar, bank p_en_bar0 and port_data sel_7 one net).
#              KID chose A on 2026-10-16 13:02 (generate again with the corrected route; the 5 KB macro follows the
#              4 KB one). This run checks that the corrected 5 KB macro is the manuscript's macro with the short gone:
#              G0  LEF size equal to the submitted one and both netlists (.sp, .lvs.sp) the same subcircuits;
#              G1t the top-level check finds no column-select line joined to a control signal.
#              No extraction, LVS or simulation (the corrected route is checked by the LVS of E8.4c on the 4 KB macro).
# How        : the generation, configuration handling and checks of scripts/e8_4c_sram_char.sh (v3, 2026-10-16),
#              steps b and b2 only, with scripts/e8_4c_openram_fix.py.
# Writes     : /home/kid/p2r_e8/e8_4c5k (macro, top-level check) and reports/e8_rom/e8_4c5k/ (logs, LEF, JSON).
#              Does not change the submitted macro or OpenRAM's files. Runs beside E8.4c (separate folders; it
#              recognises only its own processes).
# Run        : cd /mnt/d/Project/hybrid_memory/paper2
#              bash scripts/e8_4c5k_sram_fixcheck.sh 2>&1 | tee reports/e8_4c5k_sram_fixcheck.log
#              Keep the terminal open; about 1.5 h (generation about 1-1.5 h, top-level check about 20 min).
# Stop       : bash scripts/e8_4c5k_sram_fixcheck.sh stop
# Options    : E8_TIMEOUT (time limit of the top-level check, s; 7200). For testing only: E8_SRAM_DIR, E8_SRAM_NAME,
#              E8_LEF_REF, E8_WORK, E8_OPENRAM_PY, E8_OPENRAM_PDK.
# =============================================================================
set -uo pipefail

MODE="${1:-run}"
PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
OPENRAM="${E8_OPENRAM:-/home/kid/openram/OpenRAM}"
PDK_ROOT_DIR="${E8_PDK:-/home/kid/gf/pdk}"
NAME="${E8_SRAM_NAME:-sky130_sram_5kbytes_1rw_8x5120_8}"
SUBDIR="${E8_SRAM_DIR:-$PAPER2/reports/12e_openram/macros/paper2_feature_buffer_8x5120}"
LEF_REF="${E8_LEF_REF:-485.465 689.25}"
TLIM="${E8_TIMEOUT:-7200}"
FIX=1
REGEN=1
ROOT="$PAPER2/reports/e8_rom"
OUT="$ROOT/e8_4c5k"
WORK="${E8_WORK:-/home/kid/p2r_e8/e8_4c5k}"
MAC="$WORK/macro"
STOOLS="$PAPER2/scripts/e8_4c_sram_tools.py"
FIXPY="$PAPER2/scripts/e8_4c_openram_fix.py"
MAGICRC="$PDK_ROOT_DIR/sky130A/libs.tech/magic/sky130A.magicrc"
SELF="e8_4c5k_sram_fixcheck.sh"

pick_path() { ls -d $1 2>/dev/null | sort -V | tail -1; }
MAGIC="${E8_MAGIC:-$(pick_path "/nix/store/*magic-vlsi*/bin/magic")}"
NCORES=$(nproc 2>/dev/null || echo 4)
case "$TLIM" in *[!0-9]*|"") echo "ERROR: E8_TIMEOUT must be an integer (s)" >&2; exit 1 ;; esac
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

if [ "$MODE" = "status" ]; then
  echo "P2R-E8.4c-5K status, $(stamp)   ($WORK)"
  if [ -f "$MAC/gen_started" ]; then
    echo "   generation: $( [ -f "$MAC/gen_finished" ] && echo "finished ($(( $(cat "$MAC/gen_finished") - $(cat "$MAC/gen_started") )) s)" || echo "running ($(( $(date +%s) - $(cat "$MAC/gen_started") )) s)")"
  else
    echo "   generation: not started"
  fi
  [ -f "$WORK/topcheck/top.tcl" ] && echo "   top-level check: $( [ -f "$WORK/topcheck/topshort.json" ] && echo finished || echo "started")"
  exit 0
fi

if [ "$MODE" = "stop" ]; then
  echo "P2R-E8.4c-5K stop, $(stamp)   ($WORK)"
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
  echo "ERROR: an earlier run of this script is still working (script: ${R:-none}; processes in $WORK: ${P:-none})." >&2
  echo "       Let it finish, or end it first with: bash scripts/$SELF stop" >&2
  exit 1
fi

T_START=$(date +%s)
echo "=============================================================="
echo "P2R-E8.4c-5K the 5 KB SRAM macro generated again with the corrected route: G0 and top-level check, started $(stamp)"
echo "=============================================================="
echo "macro    : $NAME; submitted folder $SUBDIR"
echo "OpenRAM  : $OPENRAM  $(cat "$OPENRAM/VERSION" 2>/dev/null)  $(git -C "$OPENRAM" log -1 --format='%h %ad' --date=short 2>/dev/null)"
echo "magic    : ${MAGIC:-<missing>}"
echo "work     : $WORK (copies of the results: $OUT)"
mkdir -p "$(dirname "$WORK")" || { echo "ERROR: cannot create $(dirname "$WORK")" >&2; exit 1; }
echo "machine  : $NCORES cores, $(free -g | awk '/Mem:/{print $2" GiB memory, "$7" GiB available"}'), $(df -h "$(dirname "$WORK")" 2>/dev/null | awk 'NR==2{print $4" free for the work folder"}')"

hr "a. tools and files"
for F in "$STOOLS" "$FIXPY" "$MAGICRC"; do
  [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
[ -n "$MAGIC" ] || { echo "ERROR: magic not found" >&2; exit 1; }
grep -q "def cmd_topshort" "$STOOLS" || { echo "ERROR: $STOOLS is an older version (no topshort, 2026-10-16 needed)" >&2; exit 1; }
for F in "$STOOLS" "$FIXPY" "$PAPER2/scripts/$SELF"; do
  [ -f "$F" ] && echo "   $(md5sum "$F" | cut -c1-32)  $F"
done
echo "   OpenRAM route correction (E8_OPENRAM_FIX): on, scripts/e8_4c_openram_fix.py"
FREEGB=$(df -BG "$(dirname "$WORK")" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}')
MINFREE="${E8_MIN_FREE_GB:-10}"
[ -n "$FREEGB" ] && [ "$FREEGB" -lt "$MINFREE" ] && { echo "ERROR: less than $MINFREE GB free for the work folder $WORK" >&2; exit 1; }

rm -rf "${WORK:?}" "${OUT:?}"
mkdir -p "$WORK"/{configs,logs} "$MAC" "$OUT" || exit 1

hr "b. the macro"
echo "   submitted folder: $SUBDIR"
if [ -d "$SUBDIR" ]; then
  for f in "$SUBDIR"/*; do
    [ -f "$f" ] && printf "      %-48s %10s bytes  md5 %s\n" "${f##*/}" "$(stat -c %s "$f")" "$(md5sum "$f" | cut -c1-32)"
  done
else
  echo "      (not found)"
fi
SRC=""
if [ "$REGEN" = "0" ] && [ -s "$SUBDIR/$NAME.gds" ] && [ -s "$SUBDIR/$NAME.sp" ] && [ -s "$SUBDIR/$NAME.lvs.sp" ] && [ -s "$SUBDIR/$NAME.lef" ]; then
  for e in gds sp lvs.sp lef lib py; do
    [ -f "$SUBDIR/$NAME.$e" ] && cp "$SUBDIR/$NAME.$e" "$MAC/"
  done
  for f in "$SUBDIR/$NAME"_*.lib; do [ -f "$f" ] && cp "$f" "$MAC/"; done
  SRC="submitted"
  echo "   using the submitted macro (layout, both netlists and LEF are there)"
else
  echo "   generating the macro again ($( [ "$FIX" = "1" ] && echo "E8_OPENRAM_FIX=1: with the corrected route" || echo "the submitted folder lacks the layout, a netlist or the LEF, or E8_REGENERATE=1"))"
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
    echo "ERROR: the submitted folder has no $NAME.py; the 5 KB macro is generated only from its own configuration" >&2
    exit 1
  fi
  {
    echo "output_name = \"$NAME\""
    echo "output_path = \"$MAC/\""
    echo "netlist_only = False"
    echo "check_lvsdrc = False"
  } >> "$CFG"
  sed 's/^/      /' "$CFG"
  date +%s > "$MAC/gen_started"
  echo "   generation started at $(stamp) (KID's machine: the 4 KB macro 3,844 s in E8.4c, the 5 KB macro 77 min on 2026-05-13)"
  ( cd "$OPENRAM" && source ./setpaths.sh >/dev/null 2>&1 || exit 99
    [ -n "${E8_OPENRAM_PDK:-}" ] && export PDK_ROOT="$E8_OPENRAM_PDK"
    if [ "$FIX" = "1" ]; then "$PY" -u "$FIXPY" -v "$CFG"; else "$PY" -u sram_compiler.py -v "$CFG"; fi ) > "$WORK/logs/gen_$NAME.log" 2>&1
  echo "   OpenRAM exit $?, $(( $(date +%s) - $(cat "$MAC/gen_started") )) s"
  date +%s > "$MAC/gen_finished"
  grep -E "^\*\* " "$WORK/logs/gen_$NAME.log" | sed 's/^/      /' | tail -16
  grep -E "^E8FIX " "$WORK/logs/gen_$NAME.log" | cut -c1-260 | sed 's/^/      /'
  if [ "$FIX" = "1" ] && [ ! -s "$MAC/$NAME.e8fix.json" ]; then
    echo "ERROR: the corrected compiler did not write $NAME.e8fix.json" >&2; tail -20 "$WORK/logs/gen_$NAME.log" >&2; exit 1
  fi
  for e in gds sp lvs.sp lef; do
    [ -s "$MAC/$NAME.$e" ] || { echo "ERROR: the generation did not write $NAME.$e" >&2; tail -20 "$WORK/logs/gen_$NAME.log" >&2; exit 1; }
  done
  SRC=$( [ "$FIX" = "1" ] && echo "generated with the corrected route" || echo "generated" )
fi
echo "   files used ($SRC):"
for f in "$MAC"/*; do
  [ -f "$f" ] && printf "      %-48s md5 %s\n" "${f##*/}" "$(md5sum "$f" | cut -c1-32)"
done
LEFSIZE=$(grep -m1 -E "^\s*SIZE" "$MAC/$NAME.lef" | awk '{print $2" "$4}')
echo "   LEF size: ${LEFSIZE:-?} um; the submitted macro (E8.1b): $LEF_REF um"
G0L="FAIL"
python3 - "$LEFSIZE" "$LEF_REF" <<'PY' && G0L="PASS"
import sys
a = [float(x) for x in sys.argv[1].split()]; b = [float(x) for x in sys.argv[2].split()]
sys.exit(0 if len(a) == 2 and all(abs(x - y) < 0.0015 for x, y in zip(a, b)) else 1)
PY
G0N="SUBMITTED"
if [ "$SRC" != "submitted" ]; then
  # The generated macro must be the submitted one. OpenRAM writes the subcircuits in an order that changes from run to
  # run (sandbox: one configuration generated twice, different md5, the same lines), so the netlists are compared as
  # sets of subcircuits, comment lines left out.
  echo "   netlists generated again, against the submitted ones:"
  G0N=$(python3 - "$MAC" "$SUBDIR" "$NAME" <<'PY'
import collections, hashlib, os, sys
mac, sub, name = sys.argv[1:4]

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
    else:
        only_a, only_b = ca - cb, cb - ca
        print(f"{name}.{ext}: DIFFERENT: {sum(only_a.values())} blocks only in the generated netlist, "
              f"{sum(only_b.values())} only in the submitted one")
        for tag, c in (("generated", only_a), ("submitted", only_b)):
            names = sorted(label(k) for k in c)[:8]
            if names:
                print(f"   only in the {tag} one: " + ", ".join(names))
        verdicts.append("DIFFERENT")
print("DIFFERENT" if "DIFFERENT" in verdicts else "NOT COMPARED" if "NOT COMPARED" in verdicts else "SAME")
PY
)
  echo "$G0N" | sed '$d' | sed 's/^/      /'
  G0N=$(echo "$G0N" | tail -1)
  [ "$G0N" = "NOT COMPARED" ] && echo "   WARNING: the netlists could not be compared; G0 rests on the LEF size alone"
fi
G0="FAIL"
[ "$G0L" = "PASS" ] && case "$G0N" in SUBMITTED|SAME|"NOT COMPARED") true ;; *) false ;; esac && G0="PASS"
echo "   G0 (the macro of the manuscript): $G0 (LEF size equal: $G0L; netlists: $G0N)"
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
T2="$WORK/topcheck"
mkdir -p "$T2"
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
( cd "$T2" && PDK_ROOT="$PDK_ROOT_DIR" timeout "$TLIM" "$MAGIC" -dnull -noconsole -rcfile "$MAGICRC" < top.tcl > magic_top.log 2>&1 )
MX=$?
echo "   magic exit $MX, $(( $(date +%s) - t0 )) s$( [ "$MX" = "124" ] && echo " (cut by the time limit)")"
G1T="NOT JUDGED"
if [ -s "$T2/$NAME.ext" ]; then
  python3 "$STOOLS" topshort --ext "$T2/$NAME.ext" --json "$T2/topshort.json" | cut -c1-600 | sed 's/^/   /'
  G1T=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['verdict'])" "$T2/topshort.json" 2>/dev/null || echo "NOT JUDGED")
fi
if [ "$MX" != "0" ] && [ "$G1T" != "SHORT" ]; then
  echo "   magic did not finish (exit $MX): the .ext is incomplete, so only SHORT would count"
  G1T="NOT JUDGED (magic exit $MX)"
fi
echo "   G1t (no column-select line joined to a control signal at the top level): $G1T"
[ "$G1T" = "SHORT" ] && echo "   the macro generated with the corrected route still has the short: the correction did not work for it"


hr "results"
python3 - "$WORK" "$G0" "$G0L" "$G0N" "$G1T" "$MAC/$NAME.e8fix.json" "$LEFSIZE" "$LEF_REF" <<'PY'
import json, os, sys
work, g0, g0l, g0n, g1t, fixj, lef, lefref = sys.argv[1:9]
fix = json.load(open(fixj)) if os.path.isfile(fixj) else None
print()
print("P2R-E8.4c-5K summary")
print(f"   G0 the macro of the manuscript: {g0} (LEF size {lef} um against {lefref} um: {g0l}; netlists: {g0n})")
print(f"   G1t top-level check of the corrected macro: {g1t}")
if fix is not None:
    rec = fix if isinstance(fix, list) else fix.get("signals", fix)
    print("   route correction (e8fix.json): " + json.dumps(rec)[:900])
json.dump({"G0": g0, "G0_lef": g0l, "G0_netlists": g0n, "G1t": g1t, "lef_um": lef, "lef_submitted_um": lefref,
           "e8fix": fix}, open(os.path.join(work, "e8_4c5k_summary.json"), "w"), indent=1)
PY
for f in "$MAC"/*.lef "$MAC"/*.py "$MAC"/*.e8fix.json "$WORK"/logs/* "$T2/topshort.json" "$T2/magic_top.log" "$WORK/e8_4c5k_summary.json"; do
  [ -f "$f" ] && cp -f "$f" "$OUT/"
done
mkdir -p "$OUT/configs" && cp -f "$WORK"/configs/* "$OUT/configs/" 2>/dev/null
echo
echo "copied the logs and results to $OUT ($(du -sh "$OUT" 2>/dev/null | cut -f1)); work folder $WORK ($(du -sh "$WORK" 2>/dev/null | cut -f1))"
echo "finished $(stamp), $(( ($(date +%s) - T_START) / 60 )) min; send reports/e8_4c5k_sram_fixcheck.log"
