# What a gate-level power analysis charges for the SRAM macro from its timing library (OpenSTA).
# From the repository root:  sta -no_init -no_splash -exit scripts/sram_lib_opensta.tcl
# The macro clock toggles once per period, one rising and one falling transition as in one access, and no other
# input switches; the levels of csb0 and web0 select the access condition of the clk0 internal_power entries.
# Internal power x period = energy per clock cycle.
read_liberty reports/12e_openram/lib_20260608/sky130_sram_4kbytes_1rw_8x4096_8_TT_1p8V_25C.lib
read_verilog scripts/sram_lib_opensta_top.v
link_design sram_lib_check
create_clock -name clk -period 10 [get_ports clk0]
set_power_activity -input -activity 0 -duty 0
set_power_activity -input_ports [get_ports web0] -activity 0 -duty 1
puts "read (csb0 low, web0 high), clock period 10 ns"
report_power -instances [get_cells u_sram] -digits 6
create_clock -name clk -period 40 [get_ports clk0]
puts "read (csb0 low, web0 high), clock period 40 ns"
report_power -instances [get_cells u_sram] -digits 6
create_clock -name clk -period 10 [get_ports clk0]
set_power_activity -input_ports [get_ports web0] -activity 0 -duty 0
puts "write (csb0 low, web0 low), clock period 10 ns"
report_power -instances [get_cells u_sram] -digits 6
set_power_activity -input_ports [get_ports csb0] -activity 0 -duty 1
puts "port deselected (csb0 high, web0 low), clock period 10 ns"
report_power -instances [get_cells u_sram] -digits 6
