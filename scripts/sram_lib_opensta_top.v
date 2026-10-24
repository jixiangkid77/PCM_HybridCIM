// One instance of the 4-KB SRAM macro, for scripts/sram_lib_opensta.tcl
module sram_lib_check (clk0, csb0, web0, addr0, din0, dout0);
  input clk0, csb0, web0;
  input [12:0] addr0;
  input [7:0] din0;
  output [7:0] dout0;
  sky130_sram_4kbytes_1rw_8x4096_8 u_sram (.clk0(clk0), .csb0(csb0), .web0(web0), .addr0(addr0), .din0(din0), .dout0(dout0));
endmodule
