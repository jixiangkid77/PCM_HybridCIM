#!/bin/bash
# Figures 1 to 14 into figures/, from the repository root:
#   bash scripts/make_figures.sh > figures/figure_scripts_output.txt
# Most scripts print the numbers they draw; a header line is printed before each script.
set -e
run() { echo "== python3 scripts/$*"; python3 scripts/"$@"; }
run fig01_concept.py --out figures
run fig_diagrams.py --out figures
run fig06_accuracy.py --paper2 . --out figures
run fig07_latency.py --paper2 . --out figures
run fig08_rom_race.py --paper2 . --out figures
run fig09_rom_margin.py --paper2 . --out figures
run fig10_rom_static.py --paper2 . --out figures
run fig11_conditions.py --paper2 . --out figures
run fig12_sram.py --paper2 . --out figures
run e8_6_figures.py --out figures
