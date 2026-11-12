//============================================================
// sram_bank_128x8.v   (P2R-E10: one bank of the banked SRAM pool)
//============================================================
// Behavioural model of a single-port 128-word x 8-bit SRAM macro
// read port, as the OpenRAM macro is used here (read only during
// inference; the contents are loaded at boot): the macro latches
// the address on the rising clock edge when its chip select is
// active (csb = 0) and drives the word on dout. As in E8.5c, the
// pool takes the word one cycle later (two-cycle read), so dout is
// modelled as registered on the edge of the read.
//
// Synthesis: replaced by a black box (rtl/e10/sram_bank_128x8_stub.v).
// Place  : rtl/e10/
// Status : NEW FILE.
//============================================================
`timescale 1ns/1ps

module sram_bank_128x8 #(
    parameter integer DEPTH = 128,
    parameter integer AW    = 7,
    parameter integer DW    = 8
)(
    input  wire          clk,
    input  wire          csb,          // active low: read in this cycle
    input  wire [AW-1:0] addr,
    output reg  [DW-1:0] dout
);
    reg [DW-1:0] mem [0:DEPTH-1];      // loaded by the pool (simulation)
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = {DW{1'b0}};
        dout = {DW{1'b0}};
    end
    always @(posedge clk) begin
        if (!csb) dout <= mem[addr];
    end
endmodule
