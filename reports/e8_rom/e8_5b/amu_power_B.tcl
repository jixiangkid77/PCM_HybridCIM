# P2R-E8.5b power of the address-map unit, model B (the command sequence of E5's
# power script, with the unit's netlist, scope and waveform)
read_liberty /home/kid/sky130/orfs/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_verilog /home/kid/p2r_e8/e8_5b/amu_top_B_sta_ok.v
link_design amu_top
create_clock -name clk -period 10 [get_ports clk]
puts "FLIPFLOP_COUNT [llength [all_registers -cells]]"
read_vcd -scope tb_lenet5_full_inference_v3/DUT/u_imc/U_AMU/U_GL /home/kid/p2r_e8/e8_5b/amu_gate_B_sta.vcd
if {[catch {report_activity_annotation} msg]} { puts "report_activity_annotation: not available in this version" }
report_power -digits 6
if {[catch {report_power -instances [get_cells *] -digits 6} msg]} { puts "report_power -instances: $msg" }
