//============================================================
// e9_rom.v   (P2R-E9.1, simulation model; not synthesised)
//============================================================
// Behavioural model of one address-map ROM macro of E9 (OpenRAM
// e16d9eb, 48 rows x 8 words of 40 bit, 320 columns; the
// organisation of the E9.0 probe), read with the T1 protocol of
// rtl/e8/e8_rom_r48.v:
//   - the address is held while the clock is high;
//   - CS rises after the clock edge (T1: one system cycle) and
//     falls with the clock;
//   - dout is valid T_ACC after the clock edge (E9.0: at most
//     22.48 ns at the verified conditions, CS one cycle late
//     included; 23 ns here) and X after the clock falls.
// It checks the protocol, keeps the shortest clock-low time before
// a read and whether the last word it returned has a zero bit
// (last_zero: the macro then needs parking).
//
// Contents: words MACRO*384 .. MACRO*384+383 of the image written
// by scripts/e9_1_tables.py (e9rom_<M>.hex, one 40-bit word per
// line), given by the plusarg +e9_rom=<path>; address 383 is the
// parking word (all ones).
//
// Place  : rtl/e9/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

module e9_rom #(
    parameter integer MACRO  = 0,
    parameter integer NWORDS = 2688,          // words of the whole image (7 macros x 384)
    parameter real    T_ACC  = 23.0
)(
    input  wire        clk0,
    input  wire        cs0,
    input  wire [8:0]  addr0,
    output reg  [39:0] dout0
);
    reg [39:0] img [0:NWORDS-1];
    reg [8*512-1:0] fname;
    integer i;
    initial begin
        for (i = 0; i < NWORDS; i = i + 1) img[i] = 40'hxx_xxxx_xxxx;
        if ($value$plusargs("e9_rom=%s", fname)) $readmemh(fname, img);
        else $display("[E9 ROM] macro %0d: no +e9_rom=<image>; the macro reads X", MACRO);
        dout0 = 40'hxx_xxxx_xxxx;
    end

    real    t_rise, t_fall;
    real    low_min;
    integer n_reads, n_park_reads, n_err_cs, n_err_addr, n_err_word;
    reg     cs_seen;
    reg     last_zero;
    reg [8:0] a_lat;
    initial begin
        t_rise = 0.0; t_fall = -1.0e9; low_min = 1.0e9;
        n_reads = 0; n_park_reads = 0; n_err_cs = 0; n_err_addr = 0; n_err_word = 0;
        cs_seen = 1'b0; last_zero = 1'b0;
    end
    function [39:0] word_at;
        input [8:0] a;
        begin
            if (a > 9'd383) word_at = 40'hxx_xxxx_xxxx;
            else word_at = img[MACRO * 384 + a];
        end
    endfunction
    always @(posedge clk0) begin
        t_rise = $realtime;
        a_lat  = addr0;
        cs_seen = 1'b0;
        if (cs0 === 1'b1) n_err_cs = n_err_cs + 1;
        if (addr0 > 9'd383) n_err_word = n_err_word + 1;
        #1 dout0 = 40'hxx_xxxx_xxxx;
    end
    always @(posedge cs0) if (clk0 === 1'b1) begin
        if (!cs_seen) begin
            cs_seen = 1'b1;
            n_reads = n_reads + 1;
            if (a_lat == 9'd383) n_park_reads = n_park_reads + 1;
            if (t_rise - t_fall < low_min) low_min = t_rise - t_fall;
        end
    end
    always @(addr0) if (clk0 === 1'b1) n_err_addr = n_err_addr + 1;
    always @(posedge clk0) begin : acc
        real tr;
        tr = $realtime;
        #(T_ACC);
        if (clk0 === 1'b1 && cs0 === 1'b1 && t_rise == tr) begin
            dout0     = word_at(a_lat);
            last_zero = (dout0 !== {40{1'b1}});
        end
    end
    always @(negedge clk0) begin
        t_fall = $realtime;
        #1 dout0 = 40'hxx_xxxx_xxxx;
    end
endmodule
