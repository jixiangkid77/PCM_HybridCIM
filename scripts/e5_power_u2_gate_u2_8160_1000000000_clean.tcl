# P2R-E5 power analysis. Same command sequence as the submitted version's
# vcd_power.tcl, with the netlist and the waveform pointed at one variant.
read_liberty /home/kid/sky130/orfs/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_verilog /mnt/d/Project/hybrid_memory/paper2/reports/lenet5_top_u2_sta_ok.v
link_design lenet5_top
create_clock -name clk -period 10 [get_ports clk]
puts "FLIPFLOP_COUNT [llength [all_registers -cells]]"
read_vcd -scope tb_lenet5_gate/DUT /home/kid/p2r_e4/u2/gate_u2_8160_1000000000_clean.vcd
report_power -digits 4
