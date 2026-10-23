#!/usr/bin/env bash
# =============================================================================
# e4_preflight.sh
#
# Purpose : Gather every fact P2R-E4 needs before the first long simulation is
#           started. Read-only: nothing is compiled, run, created or modified.
#           All output is raw, to be read rather than parsed.
#
# Why     : Three things are still unknown and each of them can silently ruin a
#           run that takes hours.
#           1. Which of the three sky130 cell-model directories the earlier
#              gate-level simulation used. A different one changes the models
#              behind every cell in the netlist.
#           2. Which behavioural models stand in for the six black-box macros.
#              The synthesis stubs are empty, so the simulation needs a separate
#              set of files, and the earlier command referred to them through a
#              shell variable whose value was never recorded.
#           3. Whether the testbench reaches into the netlist hierarchy. If it
#              references internal instance names, those names have to survive
#              in the four new netlists, which came from a different Yosys.
#
# Place   : D:\Project\hybrid_memory\paper2\scripts\   (WSL: /mnt/d/Project/hybrid_memory/paper2/scripts/)
# Status  : NEW FILE.
# Runtime : seconds.
# =============================================================================
set -uo pipefail

PAPER2=/mnt/d/Project/hybrid_memory/paper2
cd "$PAPER2" || { echo "ERROR: cannot enter $PAPER2" >&2; exit 1; }

echo "##################################################################"
echo "# 1. The testbench, in full. Hierarchical references and the file"
echo "#    paths it opens both matter."
echo "##################################################################"
cat -n rtl/tb/tb_lenet5_gate.v

echo
echo "##################################################################"
echo "# 2. Every reference the testbench makes below the DUT instance"
echo "##################################################################"
grep -n "DUT\." rtl/tb/tb_lenet5_gate.v

echo
echo "##################################################################"
echo "# 3. The recorded iverilog command lines, which name the model"
echo "#    directory and the behavioural sources"
echo "##################################################################"
grep -n "iverilog\|vvp\|SKY=\|SRC=" ~/.bash_history 2>/dev/null | tail -30

echo
echo "##################################################################"
echo "# 4. The candidate sky130 model directories"
echo "##################################################################"
find /home/kid -name "sky130_fd_sc_hd.v" 2>/dev/null | while read -r F; do
    D=$(dirname "$F")
    echo "-- $D"
    ls -la "$D" | head -8
    echo "   primitives.v present: $([ -f "$D/primitives.v" ] && echo yes || echo NO)"
    echo "   dlclkp occurrences  : $(grep -c "dlclkp" "$F")"
    echo "   edfxtp occurrences  : $(grep -c "edfxtp" "$F")"
done

echo
echo "##################################################################"
echo "# 5. Candidate behavioural models for the six black-box macros"
echo "##################################################################"
for M in pcm_crossbar sram_pool_25lane pcm_addr_decoder sram_addr_decoder bias_storage feature_buffer; do
    echo "-- module $M is defined in:"
    grep -rln "^[[:space:]]*module[[:space:]]\+$M\b" --include=*.v . 2>/dev/null
done

echo
echo "##################################################################"
echo "# 6. Directory layout of the RTL tree"
echo "##################################################################"
ls -la rtl/
echo "---- rtl/sim ----"; ls -la rtl/sim/ 2>&1 | head -30
echo "---- rtl/tb ----";  ls -la rtl/tb/  2>&1 | head -30

echo
echo "##################################################################"
echo "# 7. The data files the testbench opens"
echo "##################################################################"
ls -la data/rtl_inputs_A/images/img_001.hex data/rtl_inputs_A_v3/layer_config.hex 2>&1
ls -la data/ 2>&1 | head -15

echo
echo "##################################################################"
echo "# 8. Top module and port declaration of each new netlist"
echo "##################################################################"
for V in ungated gated u2 b; do
    echo "-- $V"
    grep -n "^module \\\\lenet5_top\|^module lenet5_top" reports/lenet5_top_${V}_netlist.v | head -2
    ls -la reports/lenet5_top_${V}_netlist.v
    md5sum reports/lenet5_top_${V}_netlist.v reports/lenet5_top_${V}_sta.v
done

echo
echo "##################################################################"
echo "# 9. The netlist used by the submitted version, for comparison"
echo "##################################################################"
grep -n "^module \\\\lenet5_top\|^module lenet5_top" reports/lenet5_top_sky130_netlist.v | head -2

echo
echo "##################################################################"
echo "# 10. Simulator, and room for the full-inference waveforms"
echo "##################################################################"
iverilog -V 2>&1 | head -3
echo "---- free space on the Linux filesystem (waveforms go here) ----"
df -h /home/kid | tail -1
echo "---- free space on the Windows drive ----"
df -h /mnt/d | tail -1
echo "---- size of the earlier windowed waveform, for scale ----"
ls -la build/gate.vcd build/gate_clean.vcd 2>&1
echo "---- the earlier compile log ----"
ls -la build/compile_gate.log 2>&1
tail -12 build/compile_gate.log 2>&1
