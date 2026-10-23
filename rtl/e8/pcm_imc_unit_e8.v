//============================================================
// pcm_imc_unit_e8.v   (P2R-E8.5: pcm_imc_unit with the address-map unit)
//============================================================
// rtl/src/pcm_imc_unit.v (Paper 2 v3, X' refactor) with its 50
// address decoders (25 lanes x SRAM / PCM side; behavioural ROM
// arrays read combinationally) replaced by the address-map unit
// of E8.5 (rtl/e8/amu_top.v): one shared entry computation
// (amu_entry), a per-lane check (amu_lanes), the shared
// controller with the buffer tags, the reading ahead and the
// ROM read and parking sequence (amu_core), the entry buffer of
// all tables (amu_buf), their parking flags (amu_pflags), and per
// table its four r48 ROM macros and the unchanged hit /
// out-of-range logic (amu_table). The start pulse to the
// datapath is held only if its entry is not yet in the buffer
// (amu_top.start_go); everything else is unchanged.
//
// Decisions (KID 2026-10-15): read ahead, engines unchanged;
// an entry buffer of 8 entries; one shared entry computation,
// each lane compares its own address and an error is raised
// on disagreement.
//
// Parking words: rtl/e8/amu_park_A.vh / amu_park_B.vh (generated
// by scripts/e8_5_park_words.py); compile with -DMODEL_B for B.
// With -DE8_AS_PCM_IMC_UNIT the module is named pcm_imc_unit and
// replaces rtl/src/pcm_imc_unit.v in a compile (lenet5_top and
// the testbenches unchanged).
//
// Place  : rtl/e8/  (rtl/src/pcm_imc_unit.v is not changed)
// Status : NEW FILE.
//============================================================
// Original header of rtl/src/pcm_imc_unit.v follows.
//============================================================
// pcm_imc_unit.v   (Paper 2 v3 — X' refactor)
//============================================================
// Top-level hybrid SRAM/PCM IMC unit.
//
// Internal brick inventory:
//   layer_config_regfile  ×1   single source of truth for config
//   sram_addr_decoder     ×25  per-lane SRAM address translation
//   sram_pool_25lane      ×1   single shared SRAM storage, K read ports
//   sram_mac              ×1   K-channel SRAM MAC (v2, unchanged)
//   pcm_addr_decoder      ×25  per-lane PCM address translation
//   pcm_crossbar          ×1   behavioural PCM macro with drift
//   combiner              ×1   latency-aligned SRAM+PCM sum (v2)
//
// Latency budget:
//   SRAM path  : decoder (comb) + sram_pool_25lane (1) + sram_mac (1) = 2 cycles
//   PCM  path  : decoder (comb) + pcm_crossbar (8)                    = 8 cycles
//   combiner   : ALIGN_DELAY = 8 - 2 = 6 stages of sram-side shift register
//   Total      : start -> result_valid in 8 cycles
//
// Host-side configuration ABI (single source of truth):
//   0x00..0x09  : layer_config (5 SRAM + 5 PCM partition entries)
//   0x20 write  : bit[0] enable_drift, bit[1] cfg_commit pulse
//   0x20 read   : bit[0] enable_drift status, bit[1] cfg_valid status
//   0x21        : drift_t[15:0]
//
// start gating:
//   start_internal = start & cfg_valid
//   PCM crossbar and combiner only act on start_internal, so a
//   MAC op cannot fire before the host has issued cfg_commit.
//
// SRAM/PCM mutual exclusion:
//   By data construction, for every (layer_id, orig_addr) in
//   the valid range, exactly one of sram_hit[i] and pcm_hit[i]
//   is asserted at lane i. This module exposes sram_hit_dbg and
//   pcm_hit_dbg for the testbench to assert this invariant.
//
// Synthesis note:
//   sram_pool_25lane wraps an SRAM macro (single logical pool,
//   K read ports). pcm_crossbar wraps a PCM analog macro
//   (single pool with drift). Both can be replaced with stubs
//   at synthesis time. Everything else (regfile, decoders,
//   sram_mac, combiner) is ordinary synthesizable digital.
//============================================================

`timescale 1ns/1ps

`ifdef E8_AS_PCM_IMC_UNIT
module pcm_imc_unit #(          // compiled in place of rtl/src/pcm_imc_unit.v (E8.5 equivalence runs)
`else
module pcm_imc_unit_e8 #(
`endif
    parameter integer K            = 25,
    parameter integer DATA_WIDTH   = 8,
    parameter integer ADDR_WIDTH   = 16,
    parameter integer ACC_WIDTH    = 24,
    parameter integer SRAM_TOTAL   = 3074,
    parameter integer PCM_TOTAL    = 58396,
    parameter integer SRAM_LATENCY = 2,    // for combiner align
    parameter integer PCM_LATENCY  = 8,
    parameter         DATA_DIR     = "",
    parameter         COMMON_DIR   = ""
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          start,

    // host CPU boot configuration (single source of truth)
    input  wire                          wr_en,
    input  wire [5:0]                    wr_addr,
    input  wire [31:0]                   wr_data,

    // K-lane MAC inputs
    input  wire [2:0]                    layer_id,
    input  wire [K*DATA_WIDTH-1:0]       v_bus,
    input  wire [K*ADDR_WIDTH-1:0]       orig_addr_bus,

    // primary outputs
    output wire signed [ACC_WIDTH-1:0]   mac_result,
    output wire                          result_valid,

    // debug / observability outputs
    output wire                          cfg_valid_dbg,
    output wire                          enable_drift_dbg,
    output wire [15:0]                   drift_t_dbg,
    output wire [K-1:0]                  sram_hit_dbg,
    output wire [K-1:0]                  pcm_hit_dbg,
    output wire [K-1:0]                  sram_oor_dbg,
    output wire [K-1:0]                  pcm_oor_dbg,

    // E8.5 address-map unit observability
    output wire                          amu_stall_dbg,
    output wire [31:0]                   amu_lookup_reads,
    output wire [31:0]                   amu_park_reads,
    output wire [31:0]                   amu_stall_cycles,
    output wire [31:0]                   amu_starts,
    output wire [2:0]                    amu_errors      // {queue, lane 0, mismatch}
);


    //--------------------------------------------------------
    // 1. layer_config_regfile (single source of truth)
    //--------------------------------------------------------
    wire [15:0] sram_base_w, sram_size_w;
    wire [15:0] pcm_base_w,  pcm_size_w;
    wire        cfg_valid_w;
    wire        enable_drift_w;
    wire [15:0] drift_t_w;

    layer_config_regfile #(
        .DATA_DIR(DATA_DIR)
    ) U_REGFILE (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wr_en),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .rd_addr(6'h00),       // not used at top level
        .rd_data(/* nc */),
        .layer_id(layer_id),
        .sram_base(sram_base_w),
        .sram_size(sram_size_w),
        .pcm_base(pcm_base_w),
        .pcm_size(pcm_size_w),
        .cfg_valid(cfg_valid_w),
        .enable_drift(enable_drift_w),
        .drift_t(drift_t_w)
    );

    assign cfg_valid_dbg    = cfg_valid_w;
    assign enable_drift_dbg = enable_drift_w;
    assign drift_t_dbg      = drift_t_w;

    //--------------------------------------------------------
    // 2. start gating (cfg_valid required)
    //--------------------------------------------------------
    // E8.5: the start pulse reaches the datapath when its entry is in the
    // address-map buffer (at once in the engines' timing; held otherwise)
    wire start_req = start & cfg_valid_w;
    wire start_internal;

    //--------------------------------------------------------
    // 3. Per-lane unpacked signals (used by decoder instances)
    //--------------------------------------------------------
    wire [ADDR_WIDTH-1:0] orig_addr_lane [0:K-1];

    genvar gi;
    generate
        for (gi = 0; gi < K; gi = gi + 1) begin: unpack_orig
            assign orig_addr_lane[gi] =
                orig_addr_bus[gi*ADDR_WIDTH +: ADDR_WIDTH];
        end
    endgenerate

    //--------------------------------------------------------
    // 4. E8.5 address-map unit (replaces sections 4 and 7 of
    //    rtl/src/pcm_imc_unit.v: 25 SRAM + 25 PCM decoders)
    //--------------------------------------------------------
    wire [K-1:0]            sram_hit_w;
    wire [K-1:0]            sram_oor_w;
    wire [K*ADDR_WIDTH-1:0] sram_pool_addr_bus;
    wire [K-1:0]            pcm_hit_w;
    wire [K-1:0]            pcm_oor_w;
    wire [K*ADDR_WIDTH-1:0] pcm_pool_addr_bus;

    amu_top #(
        .K(K), .ADDR_WIDTH(ADDR_WIDTH), .SRAM_TOTAL(SRAM_TOTAL), .PCM_TOTAL(PCM_TOTAL), .DATA_DIR(DATA_DIR)
    ) U_AMU (
        .clk(clk), .rst_n(rst_n),
        .layer_id(layer_id), .orig_addr_bus(orig_addr_bus), .start_req(start_req),
        .sram_base(sram_base_w), .sram_size(sram_size_w), .pcm_base(pcm_base_w), .pcm_size(pcm_size_w),
        .sram_hit(sram_hit_w), .sram_oor(sram_oor_w), .sram_pool_addr_bus(sram_pool_addr_bus),
        .pcm_hit(pcm_hit_w), .pcm_oor(pcm_oor_w), .pcm_pool_addr_bus(pcm_pool_addr_bus),
        .start_go(start_internal), .stall(amu_stall_dbg),
        .n_lookup_reads(amu_lookup_reads), .n_park_reads(amu_park_reads),
        .n_stall_cycles(amu_stall_cycles), .n_starts(amu_starts), .errors(amu_errors)
    );

    assign sram_hit_dbg = sram_hit_w;
    assign sram_oor_dbg = sram_oor_w;
    assign pcm_hit_dbg  = pcm_hit_w;
    assign pcm_oor_dbg  = pcm_oor_w;

    //--------------------------------------------------------
    // 5. SRAM pool (single shared storage, K read ports)
    //--------------------------------------------------------
    wire [K*DATA_WIDTH-1:0] sram_weight_bus;
    wire [K-1:0]            sram_in_reg_bus;   // 1-cycle delayed hit

    sram_pool_25lane #(
        .K(K),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .SRAM_TOTAL(SRAM_TOTAL),
        .DATA_DIR(DATA_DIR)
    ) U_SPOOL (
        .clk(clk),
        .rst_n(rst_n),
        .addr_bus(sram_pool_addr_bus),
        .hit_bus(sram_hit_w),
        .weight_bus(sram_weight_bus),
        .hit_reg_bus(sram_in_reg_bus)
    );

    //--------------------------------------------------------
    // 6. SRAM MAC (v2 unchanged)
    //--------------------------------------------------------
    // v_bus is taken directly from the top-level input. By
    // design contract, the host holds v_bus stable for the
    // full duration of the MAC operation (>= PCM_LATENCY
    // cycles). Same contract as v2.
    //--------------------------------------------------------
    wire signed [ACC_WIDTH-1:0] sram_partial_w;

    sram_mac #(
        .K(K),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) U_SMAC (
        .clk(clk),
        .rst_n(rst_n),
        .v_bus(v_bus),
        .weight_bus(sram_weight_bus),
        .in_sram_bus(sram_in_reg_bus),
        .mac_partial(sram_partial_w)
    );

    //--------------------------------------------------------
    // 8. PCM crossbar (v3 from Step 4b)
    //--------------------------------------------------------
    wire signed [ACC_WIDTH-1:0] pcm_partial_w;
    wire                        pcm_valid_w;

    pcm_crossbar #(
        .K(K),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .PCM_TOTAL(PCM_TOTAL),
        .MULTI_CYCLE_LATENCY(PCM_LATENCY),
        .DATA_DIR(DATA_DIR),
        .COMMON_DIR(COMMON_DIR)
    ) U_PCB (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_internal),            // gated on cfg_valid
        .v_bus(v_bus),
        .pcm_pool_addr_bus(pcm_pool_addr_bus),
        .pcm_hit_bus(pcm_hit_w),
        .enable_drift(enable_drift_w),     // from regfile (single source)
        .drift_t(drift_t_w),
        .mac_result(pcm_partial_w),
        .result_valid(pcm_valid_w)
    );

    //--------------------------------------------------------
    // 9. Combiner (v2 unchanged): aligns timing, sums partials
    //--------------------------------------------------------
    combiner #(
        .ACC_WIDTH(ACC_WIDTH),
        .SRAM_LATENCY(SRAM_LATENCY),
        .PCM_LATENCY(PCM_LATENCY)
    ) U_COMB (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_internal),
        .sram_partial(sram_partial_w),
        .pcm_partial(pcm_partial_w),
        .pcm_valid(pcm_valid_w),
        .mac_result(mac_result),
        .result_valid(result_valid)
    );

endmodule
