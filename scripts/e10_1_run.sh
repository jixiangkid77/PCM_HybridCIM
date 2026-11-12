#!/usr/bin/env bash
# =============================================================================
# e10_1_run.sh
#
# Experiment : P2R-E10.1 in one command. The SRAM bank of the banked pool of
#              E10.0 (128 words of 8 bit) as an OpenRAM macro, by the method of
#              the 4-KB macro:
#   1. variant F, the route correction only
#      (scripts/e10_1_bank_char.sh; log reports/e10_1f_bank_char.log)
#   2. variant S, the route correction and the sense-side precharge in the layout
#      (E8_OPENRAM_SPC=1 scripts/e10_1_bank_char.sh; log reports/e10_1s_bank_char.log)
#   3. the five further conditions of E8.4e and tt 25 C for the chosen variant
#      (scripts/e10_1c_bank_corners.sh; log reports/e10_1c_<f|s>_bank_corners.log)
#   4. reports/e10_1_results.tar.gz: the logs and the small result files
#
# Rule (written before the run, protocol P2R-E10.1 of 2026-11-10): the bank
#   is variant F if F passes G0, G1t (no short of this kind), G1, G1b, G2, G3 and
#   F2b (every gated read of r10 correct at the end of its stop, the read of the
#   system); otherwise variant S if S passes them; otherwise neither, and step 3 is
#   not run. Variant S is run in every case, as the measured effect of the sense
#   precharge on the bank.
#
# Files      : scripts/e10_1_run.sh, scripts/e10_1_bank_char.sh,
#              scripts/e10_1c_bank_corners.sh, scripts/e10_1_manifest.md5 (all NEW);
#              used unchanged: scripts/e8_4c_openram_fix.py, e8_4f_openram_spc.py,
#              e8_4c_sram_bench.py, e8_4c_sram_tools.py, e8_4e_sram_tools.py,
#              e8_4_rom_bench.py, reports/e8_rom/e8_4f/configs/sky130_sram_common.py
# Writes     : /home/kid/p2r_e10/e10_1f, e10_1s, e10_1c_<f|s> (work folders) and
#              reports/e10/e10_1f, e10_1s, e10_1c_<f|s>, the three logs above,
#              reports/e10_1_results.tar.gz
# Run        : cd /mnt/d/Project/hybrid_memory/paper2
#              bash scripts/e10_1_run.sh 2>&1 | tee reports/e10_1_run.log
#              Keep the terminal open and the computer awake. Not at the same
#              time as another simulation run (E9.0): start it when E9.0 has ended.
# Runtime    : estimated 1.5 to 2.5 hours in all (two variants of 30-60 min, the
#              conditions 15-30 min; see the two scripts).
# =============================================================================
set -uo pipefail

PAPER2="${E8_PAPER2:-/mnt/d/Project/hybrid_memory/paper2}"
stamp() { date '+%Y-%m-%d %H:%M:%S'; }
cd "$PAPER2" || { echo "ERROR: no folder $PAPER2" >&2; exit 1; }
T0=$(date +%s)
echo "=============================================================="
echo "P2R-E10.1 SRAM bank macro, started $(stamp)"
echo "=============================================================="
echo "---- delivered files against the manifest ----"
md5sum -c scripts/e10_1_manifest.md5 || { echo "ERROR: a delivered file differs from the manifest (see above)" >&2; exit 1; }
echo "---- files used unchanged ----"
for f in scripts/e8_4c_openram_fix.py scripts/e8_4f_openram_spc.py scripts/e8_4c_sram_bench.py scripts/e8_4c_sram_tools.py \
         scripts/e8_4e_sram_tools.py scripts/e8_4_rom_bench.py reports/e8_rom/e8_4f/configs/sky130_sram_common.py; do
  [ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 1; }
  echo "   $(md5sum "$f" | cut -c1-32)  $f"
done
mkdir -p reports/e10 || exit 1

verdict() {   # verdict SUMMARY.json: PASS, or the gates that fail
  python3 - "$1" <<'PY'
import json, os, sys
p = sys.argv[1]
if not os.path.isfile(p):
    print("NO SUMMARY (the run stopped before its results; see its log)")
    sys.exit()
s = json.load(open(p))
bad = [k for k in ("G0", "G1", "G1b", "G2", "G3") if s.get(k) != "PASS"]
if s.get("G1t") != "NO SHORT OF THIS KIND":
    bad.append("G1t")
if s.get("F2b_gated_reads_ok_within_two_cycles") != "yes":
    bad.append("F2b")
print("PASS" if not bad else "FAIL: " + ", ".join(bad))
PY
}
summary_of() {   # the summary section of a log of e10_1_bank_char.sh
  sed -n '/^P2R-E10.1 summary/,/^copied the logs/p' "$1" | sed '$d' | sed 's/^/   /'
}

echo
echo "==== 1. variant F, started $(stamp) ===="
rm -f reports/e10/e10_1f/e10_1_summary.json
bash scripts/e10_1_bank_char.sh > reports/e10_1f_bank_char.log 2>&1
echo "   exit $?; log reports/e10_1f_bank_char.log"
VF=$(verdict reports/e10/e10_1f/e10_1_summary.json)
summary_of reports/e10_1f_bank_char.log
echo "   variant F: $VF"

echo
echo "==== 2. variant S, started $(stamp) ===="
rm -f reports/e10/e10_1s/e10_1_summary.json
E8_OPENRAM_SPC=1 bash scripts/e10_1_bank_char.sh > reports/e10_1s_bank_char.log 2>&1
echo "   exit $?; log reports/e10_1s_bank_char.log"
VS=$(verdict reports/e10/e10_1s/e10_1_summary.json)
summary_of reports/e10_1s_bank_char.log
echo "   variant S: $VS"

CH=""
[ "$VF" = "PASS" ] && CH=f
[ -z "$CH" ] && [ "$VS" = "PASS" ] && CH=s
echo
echo "   the bank (rule): $( [ -n "$CH" ] && echo "variant $(echo "$CH" | tr fs FS)" || echo "neither variant passes; no condition runs")"

if [ -n "$CH" ]; then
  echo
  echo "==== 3. conditions, variant $CH, started $(stamp) ===="
  E10_VARIANT=$CH bash scripts/e10_1c_bank_corners.sh > "reports/e10_1c_${CH}_bank_corners.log" 2>&1
  echo "   exit $?; log reports/e10_1c_${CH}_bank_corners.log"
  sed -n '/^########## 4. gates and results/,/^==============/p' "reports/e10_1c_${CH}_bank_corners.log" | sed 's/^/   /'
fi

echo
echo "==== 4. results to check ===="
LIST=$(ls -d reports/e10_1f_bank_char.log reports/e10_1s_bank_char.log reports/e10_1c_*_bank_corners.log \
         reports/e10/e10_1f reports/e10/e10_1s reports/e10/e10_1c_* 2>/dev/null)
[ -f reports/e10_1_run.log ] && LIST="reports/e10_1_run.log $LIST"
tar czf reports/e10_1_results.tar.gz --exclude='tb_out.txt' --exclude='tb_out.txt.gz' --exclude='*.gds' $LIST
echo "   reports/e10_1_results.tar.gz: $(du -h reports/e10_1_results.tar.gz | cut -f1), md5 $(md5sum reports/e10_1_results.tar.gz | cut -c1-32)"
echo "   (reports/e10_1_run.log is in it up to this line; send the tar.gz)"
echo
echo "=============================================================="
echo "Finished $(stamp), $(( ($(date +%s) - T0) / 60 )) min. F: $VF; S: $VS; bank: ${CH:-none}"
echo "=============================================================="
