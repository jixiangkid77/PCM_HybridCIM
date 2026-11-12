//============================================================
// amu9_top.v   (P2R-E9.1, address-map unit with one word per entry)
//============================================================
// The address map of E9 in place of rtl/e8/amu_top.v (E8.5), with
// the same ports, parameters and outputs: the shared entry
// computation and the per-lane check of E8.5 (rtl/e8/amu_entry.v,
// amu_lanes.v, unchanged), the controller (amu9_core: buffer tags,
// reading ahead, ROM read and parking sequence), NM ROM macros of
// 40-bit words (e9_rom in simulation, the OpenRAM macros in the
// layout; black boxes in synthesis), the entry buffer (NSLOT words
// of 37 bit: the 25 assignment bits and the 12-bit count; the three
// constant bits are not kept) and the decoding of the 25 lanes'
// slots (amu9_decode) with the hit / out-of-range logic of the
// original decoders.
//
// E8.5 kept 50 tables of 16-bit slots (25 lanes x SRAM / PCM side,
// 200 macros, a buffer of 8 x 800 bits); here one word of an entry
// gives every lane's medium and slot.
//
// Place  : rtl/e9/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

module amu9_top #(
    parameter integer K          = 25,
    parameter integer ADDR_WIDTH = 16,
    parameter integer SRAM_TOTAL = 3074,
    parameter integer PCM_TOTAL  = 58396,
    parameter         DATA_DIR   = ""            // not used (E8.5 port); the ROM image is +e9_rom=<path>
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire [2:0]              layer_id,
    input  wire [K*ADDR_WIDTH-1:0] orig_addr_bus,
    input  wire                    start_req,
    input  wire [15:0]             sram_base,
    input  wire [15:0]             sram_size,
    input  wire [15:0]             pcm_base,
    input  wire [15:0]             pcm_size,
    output wire [K-1:0]            sram_hit,
    output wire [K-1:0]            sram_oor,
    output wire [K*ADDR_WIDTH-1:0] sram_pool_addr_bus,
    output wire [K-1:0]            pcm_hit,
    output wire [K-1:0]            pcm_oor,
    output wire [K*ADDR_WIDTH-1:0] pcm_pool_addr_bus,
    output wire                    start_go,
    output wire                    stall,
    output wire [31:0]             n_lookup_reads,
    output wire [31:0]             n_park_reads,
    output wire [31:0]             n_stall_cycles,
    output wire [31:0]             n_starts,
    output wire [2:0]              errors          // {queue, lane 0, mismatch}
);
    localparam integer NM    = 7;
    localparam integer NSLOT = 8;

    wire        v0, is_fc;
    wire [11:0] e0;
    wire [8:0]  flat0, in_dim;
    wire [K-1:0] valid, mismatch;

    amu_entry U_ENTRY (
        .layer_id(layer_id), .a0(orig_addr_bus[15:0]),
        .v0(v0), .e0(e0), .flat0(flat0), .in_dim(in_dim), .is_fc(is_fc)
    );
    amu_lanes #(.K(K), .ADDR_WIDTH(ADDR_WIDTH)) U_LANES (
        .addr_bus(orig_addr_bus), .v0(v0), .flat0(flat0), .in_dim(in_dim),
        .is_fc(is_fc), .valid(valid), .mismatch(mismatch)
    );

    wire [NM-1:0]    rom_clk, rom_cs, park_end;
    wire             rom_park, cap, ready, out_ok;
    wire [8:0]       rom_addr;
    wire [2:0]       cap_m, cap_slot, cur_slot;
    wire [NSLOT-1:0] cap_en;
    wire             err_mismatch, err_lane0, err_queue;
    wire [39:0]      dout [0:NM-1];
    wire [39:0]      dsel = dout[cap_m];

    amu9_core #(.K(K), .NSLOT(NSLOT), .NM(NM)) U_CORE (
        .clk(clk), .rst_n(rst_n),
        .layer_id(layer_id), .a0(orig_addr_bus[15:0]), .v0(v0), .e0(e0),
        .start_req(start_req), .mismatch(mismatch), .cap_zero(~&dsel),
        .rom_clk(rom_clk), .rom_cs(rom_cs), .rom_park(rom_park), .rom_addr(rom_addr),
        .cap(cap), .cap_m(cap_m), .cap_slot(cap_slot), .cap_en(cap_en), .park_end(park_end),
        .cur_slot(cur_slot), .cur_ready(ready), .out_ok(out_ok),
        .start_go(start_go), .stall(stall),
        .n_lookup_reads(n_lookup_reads), .n_park_reads(n_park_reads),
        .n_stall_cycles(n_stall_cycles), .n_starts(n_starts),
        .err_mismatch(err_mismatch), .err_lane0(err_lane0), .err_queue(err_queue)
    );
    assign errors = {err_queue, err_lane0, err_mismatch};

    // ---- the ROM macros ----
    genvar gm;
    generate
        for (gm = 0; gm < NM; gm = gm + 1) begin : mac
            e9_rom #(.MACRO(gm)) U_ROM (
                .clk0(rom_clk[gm]), .cs0(rom_cs[gm]), .addr0(rom_addr), .dout0(dout[gm])
            );
        end
    endgenerate

    // ---- entry buffer: NSLOT words of 37 bits, one-hot write enable, no reset ----
    reg  [36:0] buf_w [0:NSLOT-1];
    genvar gs;
    generate
        for (gs = 0; gs < NSLOT; gs = gs + 1) begin : slot
            always @(posedge clk)
                if (cap_en[gs]) buf_w[gs] <= dsel[36:0];
        end
    endgenerate
    wire [36:0] w_cur = buf_w[cur_slot];

    // ---- the slots of the current entry (valid only when it is in the buffer) ----
    amu9_decode #(.K(K), .ADDR_WIDTH(ADDR_WIDTH), .SRAM_TOTAL(SRAM_TOTAL), .PCM_TOTAL(PCM_TOTAL)) U_DEC (
        .word(w_cur), .addr_bus(orig_addr_bus), .valid(valid & {K{out_ok}}),
        .sram_base(sram_base), .sram_size(sram_size), .pcm_base(pcm_base), .pcm_size(pcm_size),
        .sram_hit(sram_hit), .sram_oor(sram_oor), .sram_pool_addr_bus(sram_pool_addr_bus),
        .pcm_hit(pcm_hit), .pcm_oor(pcm_oor), .pcm_pool_addr_bus(pcm_pool_addr_bus)
    );
endmodule
