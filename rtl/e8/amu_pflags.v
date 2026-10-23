//============================================================
// amu_pflags.v   (P2R-E8.5, address-map unit)
//============================================================
// Parking flags of all NT address-map tables (25 lanes x SRAM /
// PCM side = 50), one per table and macro index (4 x 50 bits).
// Flag (m, t) is set when table t last read macro m with a word
// that has a zero bit and has not read its parking word since;
// the table reads its parking word at the next parking pulse of
// macro m only if the flag is set (amu_table). E8.4b: after a
// read the macro draws a static current that depends on the
// word read, and reading a word of 0xFFFF removes it.
//   cap_upd[m] : a lookup read of macro m is captured: tables
//                that took part (part) take zero_t (their word
//                has a zero bit); the others keep their flag
//                (their own last read of macro m is older)
//   clr[m]     : a parking read of macro m has ended: all clear
// The four groups are written by four shared enables (one
// clock-gating cell each).
//
// Place  : rtl/e8/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

module amu_pflags #(
    parameter integer NT = 50
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [3:0]        cap_upd,
    input  wire [3:0]        clr,
    input  wire [NT-1:0]     part,
    input  wire [NT-1:0]     zero,
    output wire [4*NT-1:0]   flags          // flags[m*NT + t]
);
    genvar m;
    generate
        for (m = 0; m < 4; m = m + 1) begin : mf
            reg [NT-1:0] f;
            always @(posedge clk)
                if (!rst_n)          f <= {NT{1'b0}};
                else if (clr[m])     f <= {NT{1'b0}};
                else if (cap_upd[m]) f <= (part & zero) | (~part & f);
            assign flags[m*NT +: NT] = f;
        end
    endgenerate
endmodule
