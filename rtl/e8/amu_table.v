//============================================================
// amu_table.v   (P2R-E8.5, address-map unit)
//============================================================
// One address-map table (one lane, one side): its four r48 ROM
// macros (e8_rom_r48; a behavioural model in simulation, the
// OpenRAM macro in the layout), the selection of its words in
// the shared entry buffer (amu_buf; NSLOT x 16 bits per table),
// and the hit / out-of-range logic of the original decoder
// (rtl/src/sram_addr_decoder.v, pcm_addr_decoder.v), unchanged:
//   local_slot = buffer word of the current entry (lane valid),
//                0xFFFF otherwise
//   raw_hit    = local_slot != 0xFFFF
//   pool       = base + local_slot
//   oor        = raw_hit && (local_slot >= size || pool >= TOTAL)
//   hit        = raw_hit && !oor;  pool_addr = hit ? pool : 0
//
// Parking: when amu_core issues a parking pulse on macro m, the
// table reads its parking word (PARK_m: a word of 0xFFFF in the
// macro, chosen as in E8.6a-2) if its parking flag for m is set
// (amu_pflags: its last read of m returned a word with a zero
// bit); otherwise its clock stays gated.
// The buffer has no reset: amu_top clears valid until amu_core
// reports the current entry captured (out_ok). A table whose
// macro was not read (lane not taking part) captures 0xFFFF.
// This module has no flip-flops.
//
// Place  : rtl/e8/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

module amu_table #(
    parameter integer LANE   = 0,
    parameter integer SIDE   = 0,           // 0 = SRAM side, 1 = PCM side
    parameter integer TOTAL  = 3074,        // SRAM_TOTAL or PCM_TOTAL
    parameter integer NSLOT  = 8,
    parameter [9:0]   PARK0  = 10'd0,
    parameter [9:0]   PARK1  = 10'd0,
    parameter [9:0]   PARK2  = 10'd0,
    parameter [9:0]   PARK3  = 10'd0,
    parameter         DATA_DIR = ""
)(
    // ROM control from amu_core
    input  wire [3:0]  rom_clk,
    input  wire [3:0]  rom_cs,
    input  wire        rom_park,
    input  wire [9:0]  rom_addr,
    input  wire        lane_en,             // this lane takes part in the lookup read
    input  wire [1:0]  cap_m,
    input  wire [3:0]  pflag,               // macro m must read its parking word at its next parking pulse
    input  wire [2:0]  cur_slot,
    // this table's words in the entry buffer (amu_buf): slot s at [s*16 +: 16]
    input  wire [NSLOT*16-1:0] words,
    output wire [15:0] dsel,                // word to capture into the buffer
    // lookup of the current operation
    input  wire        valid,               // this lane looks up the current entry (and it is in the buffer)
    input  wire [15:0] base,
    input  wire [15:0] size,
    output wire        hit,
    output wire [15:0] pool_addr,
    output wire        oor_error
);

    // ---- four r48 macros ----
    wire [15:0] w_cur  = words[cur_slot*16 +: 16];
    wire [15:0] dout [0:3];
    genvar m;
    generate
        for (m = 0; m < 4; m = m + 1) begin : mac
            wire [9:0] park_a = (m == 0) ? PARK0 : (m == 1) ? PARK1 : (m == 2) ? PARK2 : PARK3;
            wire       en     = rom_park ? pflag[m] : lane_en;
            wire       clk_g  = rom_clk[m] & en;      // this macro's clock (gated)
            e8_rom_r48 #(
                .LANE(LANE), .SIDE(SIDE), .MACRO(m), .DATA_DIR(DATA_DIR)
            ) U_ROM (
                .clk0(clk_g),
                .cs0(rom_cs[m] & en),
                .addr0(rom_park ? park_a : rom_addr),
                .dout0(dout[m])
            );
        end
    endgenerate

`ifndef SYNTHESIS
    // simulation check of the parking rule, independent of amu_pflags: lk_zero[m] = the last
    // read of macro m was a lookup and the word the macro returned has a zero bit
    // (e8_rom_r48.last_zero); a parking read clears it. At every parking pulse of macro m
    // the table must read its parking word exactly when lk_zero[m] is set. A macro without
    // a word of 0xFFFF parks on its word with the fewest zero bits: after that read its
    // last_zero stays set but lk_zero is clear (it has been parked).
    integer   n_err_park = 0;
    reg [3:0] lk_zero = 4'd0;
    reg [3:0] was_park = 4'd0;
    genvar mc;
    generate
        for (mc = 0; mc < 4; mc = mc + 1) begin : pchk
            always @(posedge mac[mc].clk_g) was_park[mc] = rom_park;
            always @(negedge mac[mc].clk_g) lk_zero[mc] = was_park[mc] ? 1'b0 : mac[mc].U_ROM.last_zero;
            always @(posedge rom_clk[mc])
                if (rom_park && (pflag[mc] !== lk_zero[mc])) n_err_park = n_err_park + 1;
        end
    endgenerate
`endif

    // ---- word to capture (amu_buf writes all tables at once). A table that did not take
    //      part in the read (its macro clock gated) gives 0xFFFF ("no slot"), not the
    //      undefined output of its macro ----
    assign dsel = dout[cap_m] | {16{~lane_en}};

    // ---- the original decoder's hit / out-of-range logic ----
    wire [15:0] local_slot = valid ? w_cur : 16'hFFFF;
    wire        raw_hit    = (local_slot != 16'hFFFF);
    wire [16:0] pool_ext   = {1'b0, base} + {1'b0, local_slot};
    wire        size_v     = raw_hit && (local_slot >= size);
    wire        global_v   = raw_hit && (pool_ext >= TOTAL);
    assign oor_error = size_v | global_v;
    assign hit       = raw_hit & ~oor_error;
    assign pool_addr = hit ? pool_ext[15:0] : 16'd0;

endmodule
