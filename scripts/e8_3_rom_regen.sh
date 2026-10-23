#!/usr/bin/env bash
# =============================================================================
# e8_3_rom_regen.sh
#
# Experiment : P2R-E8.3. Regenerate the address-map ROM with the real map
#              contents, in the 16-bit organisation, and check every result.
#
# Why
#   The submitted area (3.984 mm2) came from paper2_addr_decoder_8x5120, which
#   was generated from an all-zero placeholder file. A mask ROM places its
#   transistors according to its data, so that netlist cannot give the read
#   energy of the real map. The macro was also 8 bits wide, so each 16-bit
#   lookup needed two reads; the 16-bit organisation reads an entry at once,
#   as the RTL does.
#
# What is generated (13 macros, all with real contents)
#   16 bit x 2,496 words, one per model (A, B), side (sram, pcm) and lane
#   (00, 12, 24): 12 macros. 2,496 = 13 words per row x 192 rows, the
#   smallest size the generator lays out without dropping a partial row.
#   8 bit x 5,120 words, Model A, sram, lane 00: 1 macro, the organisation of
#   the submitted area figure, to test whether the area depends on the data.
#
# Gates
#   G6  every macro is generated (sp, gds, lef, v present)
#   G7  every netlist stores exactly the map contents, bit by bit, in the data
#       array, and its dummy row is complete (e8_3_rom_tools.py check)
#   G8  the 8-bit macro with real data has the same LEF footprint (347.73 x
#       229.125 um) and the same drawn layout extent (362.690 x 244.085 um,
#       measured in E8.1) as the submitted all-zero macro, i.e. the area does
#       not depend on the data. The layout extent of every macro is measured
#       with scripts/e8_1b_macro_footprints.sh, because the ROM generator's
#       LEF leaves out the supply ring it draws (see that script).
#
# Environment (section 2 rewritten 2026-10-08, after the first run stopped
# there without generating anything)
#   The memory compiler needs numpy, scipy and scikit-learn whatever it
#   generates: init_openram() (compiler/globals.py) imports the characterizer
#   package, whose __init__.py imports linear_regression.py and
#   neural_network.py, which import sklearn.linear_model and
#   sklearn.neural_network; the layout code imports numpy. In the first run
#   no interpreter had all three: OpenRAM's virtual environment
#   (compiler/.venv, used by its Nix shell) had no numpy, and the system
#   Python 3.12.3 had numpy but no scipy. This version
#     1. records what OpenRAM's virtual environment holds;
#     2. tries, in this order: the repository's Nix shell (offline), the
#        virtual environment directly, every other python3 under $HOME
#        (virtual environments, conda environments; depth 7) and in /nix/store Python
#        environments, then the system python3. For each it logs which of
#        the three packages import, and uses the first that imports all;
#     3. if none does, it stops without changing anything, unless it is run
#        with E8_INSTALL=1. Then it installs numpy, scipy and scikit-learn
#        with pip into OpenRAM's own virtual environment, from inside the
#        repository's Nix shell (the shell sets LD_LIBRARY_PATH so that pip
#        wheels load, see flake.nix), and uses that shell. It installs only
#        if python3 inside the shell is that virtual environment. Nothing else
#        is installed or changed; compiler/.venv is listed in OpenRAM's
#        .gitignore. Needs internet access to PyPI (about 70 MB).
#
# Files  : scripts/e8_3_rom_regen.sh (this file; replaces the earlier version)
#          scripts/e8_3_rom_tools.py (unchanged)
#          uses scripts/e8_1b_macro_footprints.sh for the layout extents (G8)
# Writes : reports/e8_rom/bins, configs, macros, logs, e8_3_manifest.json
# Run    : cd /mnt/d/Project/hybrid_memory/paper2
#          E8_INSTALL=1 bash scripts/e8_3_rom_regen.sh 2>&1 | tee reports/e8_3_rom_regen.log
#          (without E8_INSTALL=1 the script only searches, and stops if
#           nothing works)
# Options: E8_PARALLEL (default 3) macros at a time. E8_PAPER2 and E8_OPENRAM
#          override the two paths below (used only for testing).
# Runtime: the submitted 8-bit macro took 255 s to generate; 13 macros, three
#          at a time, are expected to take 20 to 30 minutes.
# =============================================================================
set -uo pipefail

PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
OPENRAM="${E8_OPENRAM:-/home/kid/openram/OpenRAM}"
TOOLS="$PAPER2/scripts/e8_3_rom_tools.py"
ROOT="$PAPER2/reports/e8_rom"
LOGDIR="$ROOT/logs"
PARALLEL="${E8_PARALLEL:-3}"

echo "=============================================================="
echo "P2R-E8.3 ROM regeneration, started $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
for F in "$TOOLS" "$OPENRAM/rom_compiler.py" "$OPENRAM/setpaths.sh" "$OPENRAM/flake.nix"; do
  [ -f "$F" ] || { echo "ERROR: missing $F" >&2; exit 1; }
done
echo "OpenRAM  : $(cat "$OPENRAM/VERSION")  $(git -C "$OPENRAM" log -1 --format='%h %ad' --date=short 2>/dev/null)"
NIX=$(command -v nix 2>/dev/null || ls /nix/var/nix/profiles/default/bin/nix 2>/dev/null)
echo "nix      : ${NIX:-<not found>}"
VENV="$OPENRAM/compiler/.venv"
echo "venv     : $(ls -d "$VENV" 2>/dev/null || echo '<none>')"
echo "E8_INSTALL=${E8_INSTALL:-0}"

echo
echo "---- 1. build the binary files and the configurations ----"
python3 "$TOOLS" build --paper2 "$PAPER2" || { echo "BUILD FAILED" >&2; exit 1; }
mkdir -p "$LOGDIR"

echo
echo "---- 2. choose how to run the memory compiler ----"
echo "   needs numpy, scipy, scikit-learn (sklearn.linear_model, sklearn.neural_network)"
echo
echo "   2a. OpenRAM's virtual environment, as found"
if [ -f "$VENV/pyvenv.cfg" ]; then
  sed 's/^/      pyvenv.cfg: /' "$VENV/pyvenv.cfg"
  echo "      pyvenv.cfg written: $(stat -c '%y' "$VENV/pyvenv.cfg" | cut -c1-19)"
  found_sp=0
  for sp in "$VENV"/lib/python3*/site-packages; do
    [ -d "$sp" ] || continue
    found_sp=1
    pk=$(ls "$sp" | grep -E '\.dist-info$' | sed -E 's/-[0-9][^-]*\.dist-info$//' | tr '\n' ' ')
    echo "      $(basename "$(dirname "$sp")")/site-packages: ${pk:-<no packages>}"
  done
  [ "$found_sp" -eq 1 ] || echo "      no site-packages directory"
else
  echo "      <no pyvenv.cfg>"
fi
SYS_PY=$(command -v python3)
echo "      system python3 ($SYS_PY): numpy from $("$SYS_PY" -c 'import numpy; print(numpy.__file__)' 2>/dev/null || echo '<not importable>')"

# The probe imports what the compiler imports at start-up and prints one line.
PROBE_PY='
import sys, importlib
res, ok = [], True
def try_import(m):
    global ok
    try:
        mod = importlib.import_module(m)
        return getattr(mod, "__version__", "ok")
    except Exception as e:
        ok = False
        s = str(e).splitlines()[0][:70] if str(e) else ""
        return "MISSING(" + type(e).__name__ + (": " + s if s else "") + ")"
for m in ("numpy", "scipy", "sklearn"):
    res.append(m + "=" + try_import(m))
if ok:
    for m in ("sklearn.linear_model", "sklearn.neural_network"):
        v = try_import(m)
        if not ok:
            res.append(m + "=" + v)
print("PROBE", sys.executable, "python=" + sys.version.split()[0], " ".join(res), "OK" if ok else "INCOMPLETE")
'

# probe LABEL CMD...   runs CMD -c PROBE_PY in the OpenRAM directory after setpaths.sh
probe() {
  local label=$1; shift
  local out line
  out=$(cd "$OPENRAM" && source ./setpaths.sh >/dev/null 2>&1 && timeout 600 "$@" -c "$PROBE_PY" 2>&1)
  line=$(printf '%s\n' "$out" | grep '^PROBE ' | tail -1)
  if [ -n "$line" ]; then
    printf '      %-26s %s\n' "$label" "${line#PROBE }"
  else
    printf '      %-26s did not run: %s\n' "$label" "$(printf '%s\n' "$out" | tail -3 | tr '\n' ' ' | cut -c1-220)"
  fi
  [[ "$line" == *" OK" ]]
}

echo
echo "   2b. interpreters tried"
NIXDEV=()
[ -n "$NIX" ] && NIXDEV=("$NIX" --extra-experimental-features 'nix-command flakes' develop --offline --command)
RUNNER=""
RUNNER_PY=""
if [ -n "$NIX" ]; then
  probe "nix develop (offline)" "${NIXDEV[@]}" python3 && RUNNER=nix
fi
if [ -z "$RUNNER" ] && [ -x "$VENV/bin/python3" ]; then
  probe "venv, directly" "$VENV/bin/python3" && { RUNNER=py; RUNNER_PY="$VENV/bin/python3"; }
fi
if [ -z "$RUNNER" ]; then
  mapfile -t OTHERS < <( {
      timeout 120 find "$HOME" -maxdepth 7 \
        \( -name .cache -o -name node_modules -o -name .git -o -name site-packages \) -prune \
        -o -path '*/bin/python3' \( -type f -o -type l \) -print 2>/dev/null
      ls -d /nix/store/*-python3-*-env/bin/python3 2>/dev/null
    } | grep -vxF "$VENV/bin/python3" | sort -u | head -20 )
  echo "      other python3 found under \$HOME and in /nix/store: ${#OTHERS[@]}"
  for p in "${OTHERS[@]}"; do
    probe "${p/#$HOME/\~}" "$p" && { RUNNER=py; RUNNER_PY="$p"; break; }
  done
fi
if [ -z "$RUNNER" ]; then
  probe "system python3" "$SYS_PY" && { RUNNER=py; RUNNER_PY="$SYS_PY"; }
fi

if [ -z "$RUNNER" ] && [ "${E8_INSTALL:-0}" = "1" ]; then
  echo
  echo "   2c. E8_INSTALL=1: pip install numpy scipy scikit-learn into $VENV, inside the Nix shell"
  if [ -z "$NIX" ]; then
    echo "      nix not found; not installing"
  else
    INST=$(cd "$OPENRAM" && source ./setpaths.sh >/dev/null 2>&1 && \
      "${NIXDEV[@]}" bash -c '
        pfx=$(python3 -c "import sys; print(sys.prefix)" 2>/dev/null)
        echo "target python3: $(command -v python3), sys.prefix $pfx, VIRTUAL_ENV ${VIRTUAL_ENV:-<unset>}"
        if [ -z "${VIRTUAL_ENV:-}" ] || [ "$pfx" != "$VIRTUAL_ENV" ]; then
          echo "python3 in the shell is not the virtual environment; not installing"; exit 9
        fi
        python3 -m pip --version >/dev/null 2>&1 || python3 -m ensurepip --upgrade
        python3 -m pip install --disable-pip-version-check --no-input numpy scipy scikit-learn
      ' 2>&1)
    rc=$?
    printf '%s\n' "$INST" | grep -E "^target python3|not installing|Successfully installed|Requirement already satisfied: (numpy|scipy|scikit-learn)|ERROR|[Ee]rror:" \
      | tail -12 | sed 's/^/      /'
    echo "      pip exit $rc"
    probe "nix develop, after install" "${NIXDEV[@]}" python3 && RUNNER=nix
  fi
fi

if [ -z "$RUNNER" ]; then
  echo
  echo "STOPPED: no Python environment imports numpy, scipy and scikit-learn."
  echo "Nothing was generated; nothing outside reports/e8_rom (bins, configs) was written."
  if [ "${E8_INSTALL:-0}" != "1" ]; then
    echo "To install the three packages into OpenRAM's own virtual environment"
    echo "(compiler/.venv, git-ignored; nothing outside it changes; needs internet access"
    echo "to PyPI, about 70 MB), run:"
    echo "   E8_INSTALL=1 bash scripts/e8_3_rom_regen.sh 2>&1 | tee reports/e8_3_rom_regen.log"
  else
    echo "The installation did not give a working environment; see the lines above."
  fi
  exit 3
fi
echo
echo "   runner: $RUNNER ${RUNNER_PY}"

gen() {
  local cfg=$1 name log rc start
  name=$(basename "$cfg" .py)
  log="$LOGDIR/$name.log"
  start=$(date +%s)
  (
    cd "$OPENRAM" && source ./setpaths.sh || exit 99
    if [ "$RUNNER" = nix ]; then
      "$NIX" --extra-experimental-features 'nix-command flakes' develop --offline \
          --command python3 -u rom_compiler.py -v "$cfg"
    else
      "$RUNNER_PY" -u rom_compiler.py -v "$cfg"
    fi
  ) > "$log" 2>&1
  rc=$?
  echo "   $name: exit $rc, $(( $(date +%s) - start )) s"
}
export -f gen
export RUNNER RUNNER_PY NIX OPENRAM LOGDIR

echo
echo "---- 3. the 8-bit macro first, as a single test of the whole path ----"
gen "$ROOT/configs/e8rom_A_sram_l00_8x5120.py"
N8="$ROOT/macros/e8rom_A_sram_l00_8x5120/e8rom_A_sram_l00_8x5120"
if [ ! -f "$N8.sp" ]; then
  echo "The first macro was not produced. Its log ends with:"
  tail -40 "$LOGDIR/e8rom_A_sram_l00_8x5120.log"
  exit 1
fi
grep -h "Read rom data file" "$LOGDIR/e8rom_A_sram_l00_8x5120.log" | sed 's/^/   /'

echo
echo "---- 4. the twelve 16-bit macros, $PARALLEL at a time, started $(date '+%F %T') ----"
ls "$ROOT"/configs/*_16x2496.py | xargs -P "$PARALLEL" -I{} bash -c 'gen "$1"' _ {}
echo "   organisation reported by the compiler:"
for f in "$LOGDIR"/*_16x2496.log; do
  printf "   %-34s %s\n" "$(basename "$f" .log)" "$(grep -h 'Read rom data file' "$f" | sed 's/.*Read rom data file: //')"
done

echo
echo "---- 5. gate G6: every output present ----"
G6=1
for d in "$ROOT"/macros/*/; do
  n=$(basename "$d")
  for ext in sp gds lef v; do
    [ -f "$d$n.$ext" ] || { echo "   MISSING $n.$ext"; G6=0; }
  done
done
[ "$G6" -eq 1 ] && echo "   PASS  all 13 macros have sp, gds, lef and v" || echo "   FAIL  see above"

echo
echo "---- 6. gates G7 and G8: stored bits and footprint ----"
python3 "$TOOLS" check --paper2 "$PAPER2"
RC=$?
echo
grep -h "SIZE" "$ROOT/macros/e8rom_A_sram_l00_8x5120/e8rom_A_sram_l00_8x5120.lef" 2>/dev/null \
  | sed 's/^/   8-bit macro LEF: /'
echo "   G8 expects SIZE 347.73 BY 229.125 (the submitted, all-zero macro)"

echo
echo "---- 7. gate G8, second half: drawn layout extent of every generated macro ----"
if [ -f "$PAPER2/scripts/e8_1b_macro_footprints.sh" ]; then
  bash "$PAPER2/scripts/e8_1b_macro_footprints.sh" "$ROOT/macros"
  echo "   G8 expects the 8-bit macro at 362.690 x 244.085 um, as the submitted one"
else
  echo "   scripts/e8_1b_macro_footprints.sh not found; layout extents not measured"
fi

echo
echo "=============================================================="
echo "Finished $(date '+%Y-%m-%d %H:%M:%S'). runner $RUNNER ${RUNNER_PY}. check exit $RC."
echo "=============================================================="
