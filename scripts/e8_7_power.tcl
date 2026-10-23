# =============================================================================
# e8_7_power.tcl   (P2R-E8.7: power of the digital logic over one inference, OpenROAD's OpenSTA)
#
# Run by scripts/e8_7_gate_energy.sh as  openroad -exit -no_init scripts/e8_7_power.tcl  with
#   E87_PLAT   platform folder (tech LEF, cell LEF, tt library)
#   E87_NET    the logic netlist (core.v)
#   E87_TOP    <top>_core
#   E87_VCD    waveform of the gate-level run (rtl/e8/tb/tb_e87_chip.v, -DE87_GATE)
#   E87_SCOPE  tb_e87_chip/DUT/core
#   E87_REP    prefix of the report files
# The method of E5: tt library, 10 ns clock, the activity of every annotated pin from the waveform.
# =============================================================================
set P     $::env(E87_PLAT)
set REP   $::env(E87_REP)
puts "E87P: read [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
read_lef $P/lef/sky130_fd_sc_hd.tlef
read_lef $P/lef/sky130_fd_sc_hd_merged.lef
read_liberty $P/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_verilog $::env(E87_NET)
link_design $::env(E87_TOP)
create_clock -name clk -period 10.0 [get_ports clk]
puts "E87P: cells [llength [get_cells *]]"
puts "E87P: read_vcd [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
read_vcd -scope $::env(E87_SCOPE) $::env(E87_VCD)
puts "E87P: report [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
report_activity_annotation -report_unannotated > ${REP}_annotation.rpt
report_power -digits 6 > ${REP}_power.rpt
report_power -digits 6
report_power -instances [get_cells *] -digits 6 > ${REP}_instances.rpt
puts "E87P: done [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
