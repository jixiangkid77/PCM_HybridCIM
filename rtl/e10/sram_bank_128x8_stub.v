//============================================================
// sram_bank_128x8_stub.v   (P2R-E10: black box of one SRAM bank for synthesis)
//============================================================
(* blackbox *)
module sram_bank_128x8 #(
    parameter integer DEPTH = 128,
    parameter integer AW    = 7,
    parameter integer DW    = 8
)(
    input  wire          clk,
    input  wire          csb,
    input  wire [AW-1:0] addr,
    output wire [DW-1:0] dout
);
endmodule
