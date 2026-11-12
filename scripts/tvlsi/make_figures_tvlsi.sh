#!/bin/bash
# Figures 1 to 7 of the 9-page version into figures/tvlsi/, from the repository root:
#   bash scripts/tvlsi/make_figures_tvlsi.sh > figures/tvlsi/figure_scripts_output.txt
# Every figure is drawn at its printed size (one column 3.5 in, page width 7.16 in);
# most scripts print the numbers they draw; a header line is printed before each script.
set -e
run() { echo "== python3 scripts/tvlsi/$*"; python3 scripts/tvlsi/"$@"; }
run fig1_concept.py --out figures/tvlsi
run fig2_amu.py --out figures/tvlsi
run fig3_accuracy.py --paper2 . --out figures/tvlsi
run fig4_rom_race.py --paper2 . --out figures/tvlsi
run fig5_rom_margin.py --summary reports/e9/e9_5/e9_5_summary.json --out figures/tvlsi
run fig6_sram.py --paper2 . --out figures/tvlsi
run fig7_cost.py --summary reports/e9/e9_5/e9_5_summary.json --out figures/tvlsi
