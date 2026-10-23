//============================================================
// pcm_addr_decoder.v
// Paper 2 v3 — PCM-path address decoder (lane-sliced compact ROM)
//============================================================
// Mirror of sram_addr_decoder.v for the PCM partition.
// Translates (layer_id, orig_addr) plus runtime (pcm_base,
// pcm_size) into a flat pcm_pool_addr, with hit/error
// signalling. Pure combinational; outputs settle in the same
// cycle as inputs.
//
// LANE-SLICED ROM (v3 refactor, 2026-05-12):
//   See sram_addr_decoder.v header for the lane-mapping
//   convention and rationale. Per-decoder capacity is 2482
//   16-bit entries = 39.7 Kbit, reduced 25x from the previous
//   full-table-per-lane design.
//
// Empty PCM partition (pcm_size == 0):
//   Some layers have all weights in SRAM (e.g. Model A conv1,
//   Model B conv1 and fc3). For these, the lane-sliced PCM ROM
//   is all-FFFF, so every orig_addr yields local_slot = FFFF ->
//   raw_hit = 0, no error. This is a legitimate "empty
//   partition" condition, not a violation.
//
//   If the ROM is corrupted (a valid slot appears when
//   pcm_size = 0), size_violation fires:
//     raw_hit=1, local_slot >= 0 -> error=1, hit=0.
//
// Owned hex files (loaded via $readmemh when DATA_DIR != ""):
//   addr_to_slot_<L>_pcm_lane<KK>.hex  per-lane share of layer L
//   where <KK> = LANE_ID formatted as zero-padded 2-digit decimal.
//
// SRAM/PCM mutual exclusion (system-level invariant, not enforced
// here): for every (layer_id, orig_addr) pair routed to a lane,
// exactly one of sram_hit / pcm_hit is asserted (assuming the
// addr-to-slot tables for the two sides are complementary).
//============================================================

`timescale 1ns/1ps

module pcm_addr_decoder #(
    parameter integer ADDR_WIDTH = 16,
    parameter integer PCM_TOTAL  = 58396,
    parameter integer LANE_ID    = 0,        // 0..24
    parameter         DATA_DIR   = ""
)(
    input  wire [2:0]              layer_id,
    input  wire [ADDR_WIDTH-1:0]   orig_addr,
    input  wire [15:0]             pcm_base,
    input  wire [15:0]             pcm_size,

    output wire                    pcm_hit,
    output wire [15:0]             pcm_pool_addr,
    output wire                    pcm_oor_error
);

    // ---- Per-layer lane-sliced ROMs (PCM side) -------------------
    reg [15:0] rom_conv1 [0:5];
    reg [15:0] rom_conv2 [0:95];
    reg [15:0] rom_fc1   [0:1919];
    reg [15:0] rom_fc2   [0:419];
    reg [15:0] rom_fc3   [0:39];

    integer i;
    initial begin
        // Default fill: FFFF (empty-partition behaviour by default).
        for (i = 0; i < 6;    i = i + 1) rom_conv1[i] = 16'hFFFF;
        for (i = 0; i < 96;   i = i + 1) rom_conv2[i] = 16'hFFFF;
        for (i = 0; i < 1920; i = i + 1) rom_fc1[i]   = 16'hFFFF;
        for (i = 0; i < 420;  i = i + 1) rom_fc2[i]   = 16'hFFFF;
        for (i = 0; i < 40;   i = i + 1) rom_fc3[i]   = 16'hFFFF;

        if (DATA_DIR != "") begin
            $readmemh($sformatf("%s/addr_to_slot_conv1_pcm_lane%02d.hex",
                                DATA_DIR, LANE_ID), rom_conv1);
            $readmemh($sformatf("%s/addr_to_slot_conv2_pcm_lane%02d.hex",
                                DATA_DIR, LANE_ID), rom_conv2);
            $readmemh($sformatf("%s/addr_to_slot_fc1_pcm_lane%02d.hex",
                                DATA_DIR, LANE_ID), rom_fc1);
            $readmemh($sformatf("%s/addr_to_slot_fc2_pcm_lane%02d.hex",
                                DATA_DIR, LANE_ID), rom_fc2);
            $readmemh($sformatf("%s/addr_to_slot_fc3_pcm_lane%02d.hex",
                                DATA_DIR, LANE_ID), rom_fc3);
        end
    end

    // ---- Zero-extend orig_addr to 16-bit for layer math ----------
    wire [15:0] o16 = {{(16-ADDR_WIDTH){1'b0}}, orig_addr};

    // ---- Conv layer compact_idx and lane match -------------------
    wire [15:0] conv_compact = o16 / 16'd25;
    wire        conv_lane_ok = (o16 % 16'd25) == LANE_ID;

    // ---- FC layer compact_idx and lane match ---------------------
    // fc1: IN_DIM=400, sb_groups=16
    wire [15:0] fc1_oc       = o16 / 16'd400;
    wire [15:0] fc1_flat     = o16 - fc1_oc * 16'd400;
    wire [15:0] fc1_sb       = (fc1_flat >= LANE_ID)
                               ? (fc1_flat - LANE_ID) / 16'd25
                               : 16'd0;
    wire [15:0] fc1_compact  = (fc1_oc << 4) + fc1_sb;
    wire        fc1_lane_ok  = (fc1_flat % 16'd25) == LANE_ID;

    // fc2: IN_DIM=120, sb_groups=5
    wire [15:0] fc2_oc       = o16 / 16'd120;
    wire [15:0] fc2_flat     = o16 - fc2_oc * 16'd120;
    wire [15:0] fc2_sb       = (fc2_flat >= LANE_ID)
                               ? (fc2_flat - LANE_ID) / 16'd25
                               : 16'd0;
    wire [15:0] fc2_compact  = fc2_oc * 16'd5 + fc2_sb;
    wire        fc2_lane_ok  = (fc2_flat % 16'd25) == LANE_ID;

    // fc3: IN_DIM=84, sb_groups=4
    wire [15:0] fc3_oc       = o16 / 16'd84;
    wire [15:0] fc3_flat     = o16 - fc3_oc * 16'd84;
    wire [15:0] fc3_sb       = (fc3_flat >= LANE_ID)
                               ? (fc3_flat - LANE_ID) / 16'd25
                               : 16'd0;
    wire [15:0] fc3_compact  = (fc3_oc << 2) + fc3_sb;
    wire        fc3_lane_ok  = (fc3_flat % 16'd25) == LANE_ID;

    // ---- Per-layer bounded ROM read ------------------------------
    wire conv1_in_range = (o16 < 16'd150);
    wire conv2_in_range = (o16 < 16'd2400);
    wire fc1_in_range   = (o16 < 16'd48000);
    wire fc2_in_range   = (o16 < 16'd10080);
    wire fc3_in_range   = (o16 < 16'd840);

    wire [15:0] slot_conv1 = (conv1_in_range && conv_lane_ok &&
                              conv_compact < 16'd6)
                             ? rom_conv1[conv_compact[2:0]]  : 16'hFFFF;
    wire [15:0] slot_conv2 = (conv2_in_range && conv_lane_ok &&
                              conv_compact < 16'd96)
                             ? rom_conv2[conv_compact[6:0]]  : 16'hFFFF;
    wire [15:0] slot_fc1   = (fc1_in_range   && fc1_lane_ok  &&
                              fc1_compact   < 16'd1920)
                             ? rom_fc1[fc1_compact[10:0]]    : 16'hFFFF;
    wire [15:0] slot_fc2   = (fc2_in_range   && fc2_lane_ok  &&
                              fc2_compact   < 16'd420)
                             ? rom_fc2[fc2_compact[8:0]]     : 16'hFFFF;
    wire [15:0] slot_fc3   = (fc3_in_range   && fc3_lane_ok  &&
                              fc3_compact   < 16'd40)
                             ? rom_fc3[fc3_compact[5:0]]     : 16'hFFFF;

    // ---- Layer mux -----------------------------------------------
    reg [15:0] local_slot;
    always @(*) begin
        case (layer_id)
            3'd0:    local_slot = slot_conv1;
            3'd1:    local_slot = slot_conv2;
            3'd2:    local_slot = slot_fc1;
            3'd3:    local_slot = slot_fc2;
            3'd4:    local_slot = slot_fc3;
            default: local_slot = 16'hFFFF;
        endcase
    end

    // ---- Hit / OOR decode ----------------------------------------
    wire raw_hit = (local_slot != 16'hFFFF);

    wire [16:0] pool_addr_ext = {1'b0, pcm_base} + {1'b0, local_slot};

    wire size_violation   = raw_hit && (local_slot   >= pcm_size);
    wire global_violation = raw_hit && (pool_addr_ext >= PCM_TOTAL);

    assign pcm_oor_error = size_violation | global_violation;
    assign pcm_hit       = raw_hit & ~pcm_oor_error;
    assign pcm_pool_addr = pcm_hit ? pool_addr_ext[15:0] : 16'd0;

endmodule
