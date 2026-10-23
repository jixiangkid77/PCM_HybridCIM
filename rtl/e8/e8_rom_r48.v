//============================================================
// e8_rom_r48.v   (P2R-E8.5, simulation model; not synthesised)
//============================================================
// Behavioural model of one 48-row address-map ROM macro (OpenRAM
// e16d9eb, 13 words per row, 16 bit), read with the T1 protocol
// that E8.4a-6/-7/-8 and E8.4b verified after layout:
//   - the address is held while the clock is high;
//   - CS rises after the clock edge (T1: one system cycle) and
//     falls with the clock;
//   - dout is valid T_ACC after the clock edge (21.3 ns is the
//     longest correct read time of E8.4a-7/-8; 22 ns used here)
//     and is not guaranteed after the clock falls (X here).
// The model also checks the protocol and keeps the shortest
// clock-low time before a read, so the testbench can confirm the
// 90 ns / 50 ns precharge of E8.4a-7 and E8.4b, and whether the
// last word it returned has a zero bit (last_zero: the macro then
// draws the static current of E8.4b until it is read again).
//
// Contents: the table of this lane and side, built from the same
// hex files as the original decoders (addr_to_slot_<layer>_<side>
// _lane<KK>.hex, unloaded words 0xFFFF), layer offsets 0, 6, 102,
// 2022, 2442, 2,496 words; macro m holds entries 624m..624m+623;
// address = row*16 + word (row 0..47, word 0..12).
//
// The OpenRAM model written with each macro (<name>.v) samples CS
// at the clock edge and drives dout after the falling edge; it
// does not model T1, so it is not used here.
//
// Place  : rtl/e8/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

module e8_rom_r48 #(
    parameter integer LANE     = 0,
    parameter integer SIDE     = 0,          // 0 = SRAM side, 1 = PCM side
    parameter integer MACRO    = 0,
    parameter         DATA_DIR = "",
    parameter real    T_ACC    = 22.0        // ns after the clock edge
)(
    input  wire        clk0,
    input  wire        cs0,
    input  wire [9:0]  addr0,
    output reg  [15:0] dout0
);
    reg [15:0] tab [0:2495];
    reg [15:0] c1 [0:5];  reg [15:0] c2 [0:95];  reg [15:0] f1 [0:1919];
    reg [15:0] f2 [0:419]; reg [15:0] f3 [0:39];
    integer i;
    initial begin
        for (i = 0; i < 6;    i = i + 1) c1[i] = 16'hFFFF;
        for (i = 0; i < 96;   i = i + 1) c2[i] = 16'hFFFF;
        for (i = 0; i < 1920; i = i + 1) f1[i] = 16'hFFFF;
        for (i = 0; i < 420;  i = i + 1) f2[i] = 16'hFFFF;
        for (i = 0; i < 40;   i = i + 1) f3[i] = 16'hFFFF;
        if (DATA_DIR != "") begin
            if (SIDE == 0) begin
                $readmemh($sformatf("%s/addr_to_slot_conv1_sram_lane%02d.hex", DATA_DIR, LANE), c1);
                $readmemh($sformatf("%s/addr_to_slot_conv2_sram_lane%02d.hex", DATA_DIR, LANE), c2);
                $readmemh($sformatf("%s/addr_to_slot_fc1_sram_lane%02d.hex",   DATA_DIR, LANE), f1);
                $readmemh($sformatf("%s/addr_to_slot_fc2_sram_lane%02d.hex",   DATA_DIR, LANE), f2);
                $readmemh($sformatf("%s/addr_to_slot_fc3_sram_lane%02d.hex",   DATA_DIR, LANE), f3);
            end else begin
                $readmemh($sformatf("%s/addr_to_slot_conv1_pcm_lane%02d.hex", DATA_DIR, LANE), c1);
                $readmemh($sformatf("%s/addr_to_slot_conv2_pcm_lane%02d.hex", DATA_DIR, LANE), c2);
                $readmemh($sformatf("%s/addr_to_slot_fc1_pcm_lane%02d.hex",   DATA_DIR, LANE), f1);
                $readmemh($sformatf("%s/addr_to_slot_fc2_pcm_lane%02d.hex",   DATA_DIR, LANE), f2);
                $readmemh($sformatf("%s/addr_to_slot_fc3_pcm_lane%02d.hex",   DATA_DIR, LANE), f3);
            end
        end
        for (i = 0; i < 2496; i = i + 1) tab[i] = 16'hFFFF;
        for (i = 0; i < 6;    i = i + 1) tab[i]        = c1[i];
        for (i = 0; i < 96;   i = i + 1) tab[6 + i]    = c2[i];
        for (i = 0; i < 1920; i = i + 1) tab[102 + i]  = f1[i];
        for (i = 0; i < 420;  i = i + 1) tab[2022 + i] = f2[i];
        for (i = 0; i < 40;   i = i + 1) tab[2442 + i] = f3[i];
        dout0 = 16'hxxxx;
    end

    // ---- protocol and statistics ----
    real    t_rise, t_fall, t_cs;
    real    low_min;                 // shortest clock-low time before a read with CS (ns)
    integer n_reads, n_err_cs, n_err_addr, n_err_word;
    reg     cs_seen;
    reg     last_zero;               // the last word read has a zero bit (the macro then needs parking)
    reg [9:0] a_lat;
    initial begin
        t_rise = 0.0; t_fall = -1.0e9; t_cs = 0.0; low_min = 1.0e9;
        n_reads = 0; n_err_cs = 0; n_err_addr = 0; n_err_word = 0; cs_seen = 1'b0; last_zero = 1'b0;
    end

    function [15:0] word_at;
        input [9:0] a;
        begin
            if (a[3:0] > 4'd12 || a[9:4] > 6'd47) word_at = 16'hxxxx;
            else word_at = tab[MACRO * 624 + a[9:4] * 13 + a[3:0]];
        end
    endfunction

    always @(posedge clk0) begin
        t_rise = $realtime;
        a_lat  = addr0;
        cs_seen = 1'b0;
        if (cs0 === 1'b1) n_err_cs = n_err_cs + 1;            // CS must rise after the edge (T1)
        if (addr0[3:0] > 4'd12 || addr0[9:4] > 6'd47) n_err_word = n_err_word + 1;
        #1 dout0 = 16'hxxxx;
    end
    always @(posedge cs0) if (clk0 === 1'b1) begin
        t_cs = $realtime;
        if (!cs_seen) begin
            cs_seen = 1'b1;
            n_reads = n_reads + 1;
            if (t_rise - t_fall < low_min) low_min = t_rise - t_fall;
        end
    end
    always @(addr0) if (clk0 === 1'b1) n_err_addr = n_err_addr + 1;   // address must hold while high
    // data valid T_ACC after the edge, if CS is high by then
    always @(posedge clk0) begin : acc
        real tr;
        tr = $realtime;
        #(T_ACC);
        if (clk0 === 1'b1 && cs0 === 1'b1 && t_rise == tr) begin
            dout0     = word_at(a_lat);
            last_zero = (dout0 !== 16'hFFFF);
        end
    end
    always @(negedge clk0) begin
        t_fall = $realtime;
        #1 dout0 = 16'hxxxx;
    end

endmodule
