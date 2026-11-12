#!/usr/bin/env bash
# P2R-E9.5: energy and area of the manuscript with the address map of E9, on top of E10.2b.
# Run in the paper2 folder:   bash scripts/e9_5_recost.sh
#   0. the files of this step against rtl/e9/e9_5_manifest.md5
#   1. reports/e8_6/e8_6_summary.json, which E10.2b reads, copied from the GitHub working copy if it is missing
#   2. scripts/e10_2b_recost.py -> reports/e10/e10_2b   (25 SRAM banks, no conv1 cache)
#   3. scripts/e9_5_recost.py   -> reports/e9/e9_5      (the address map of E9: D_ROM, AMU, areas, figure data)
#   4. reports/e9_5_results.tar.gz: both outputs and this log, to send back
# Nothing is simulated; a few seconds. Stops at the first step that fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
GH=${E9_5_GITHUB:-/mnt/d/GitHub/PCM_HybridCIM}
E86_MD5=50cf171966b689d80212482a2e6be463
LOG=reports/e9_5_recost.log
mkdir -p reports
exec > >(tee "$LOG") 2>&1

echo "P2R-E9.5 recost, $(date '+%Y-%m-%d %H:%M:%S'), in $(pwd)"
echo "python: $(python3 --version 2>&1)"

echo "==== 0. files of this step"
if ! md5sum -c rtl/e9/e9_5_manifest.md5; then
  echo "STOP: a file of this step differs from rtl/e9/e9_5_manifest.md5"
  exit 1
fi

echo "==== 1. reports/e8_6/e8_6_summary.json"
if [ ! -f reports/e8_6/e8_6_summary.json ]; then
  if [ ! -f "$GH/reports/e8_6/e8_6_summary.json" ]; then
    echo "STOP: neither reports/e8_6/e8_6_summary.json nor $GH/reports/e8_6/e8_6_summary.json exists"
    exit 1
  fi
  mkdir -p reports/e8_6
  cp "$GH/reports/e8_6/e8_6_summary.json" reports/e8_6/
  echo "copied from $GH/reports/e8_6/"
fi
got=$(md5sum reports/e8_6/e8_6_summary.json | cut -d' ' -f1)
echo "e8_6_summary.json $got (expected $E86_MD5)"
if [ "$got" != "$E86_MD5" ]; then
  echo "STOP: reports/e8_6/e8_6_summary.json is not the summary of E8.6"
  exit 1
fi

echo "==== 2. E10.2b: 25 SRAM banks, no conv1 cache"
if ! python3 scripts/e10_2b_recost.py --paper2 . --out reports/e10/e10_2b; then
  echo "STOP: E10.2b did not pass its checks"
  exit 1
fi

echo "==== 3. E9.5: the address map of E9"
if ! python3 scripts/e9_5_recost.py --paper2 . --out reports/e9/e9_5; then
  echo "STOP: E9.5 did not pass its checks"
  exit 1
fi

echo "==== 4. results"
echo "E9.5: all checks pass; packing reports/e9_5_results.tar.gz"
tar czf reports/e9_5_results.tar.gz reports/e10/e10_2b reports/e9/e9_5 "$LOG"
ls -l reports/e9_5_results.tar.gz
md5sum reports/e9_5_results.tar.gz
