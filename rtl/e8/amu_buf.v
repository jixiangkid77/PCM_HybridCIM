//============================================================
// amu_buf.v   (P2R-E8.5, address-map unit)
//============================================================
// The entry buffer of all NT address-map tables (25 lanes x
// SRAM / PCM side = 50): NSLOT slots, each one register of
// NT x 16 bits holding the word every table read for the
// slot's entry. A slot is written by its bit of the one-hot
// enable cap_en (amu_core), all tables at once, so that clock
// gating needs one gating cell per slot (8 for 6,400 bits)
// instead of one per slot and table. No reset: amu_core marks
// a slot captured before any table output uses it.
//
// Ports: din[t*16 +: 16] = word to capture from table t
//        (t = side*25 + lane); q[(s*NT + t)*16 +: 16] = slot s
//        of table t.
//
// Place  : rtl/e8/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

module amu_buf #(
    parameter integer NT    = 50,
    parameter integer NSLOT = 8
)(
    input  wire                      clk,
    input  wire [NSLOT-1:0]          cap_en,
    input  wire [NT*16-1:0]          din,
    output wire [NSLOT*NT*16-1:0]    q
);
    genvar s;
    generate
        for (s = 0; s < NSLOT; s = s + 1) begin : slot
            reg [NT*16-1:0] r;
            always @(posedge clk)
                if (cap_en[s]) r <= din;
            assign q[s*NT*16 +: NT*16] = r;
        end
    endgenerate
endmodule
