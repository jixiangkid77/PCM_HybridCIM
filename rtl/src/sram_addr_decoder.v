//============================================================
// sram_addr_decoder.v
// Paper 2 v3 — SRAM-path address decoder (lane-sliced compact ROM)
//============================================================
// Translates (layer_id, orig_addr) plus runtime (sram_base,
// sram_size) into a flat sram_pool_addr, with hit/error
// signalling. Pure combinational; outputs settle in the same
// cycle as inputs.
//
// LANE-SLICED ROM (v3 refactor, 2026-05-12):
//   Each decoder instance stores ONLY its lane's 1/25 share of
//   each layer's addr_to_slot table. Per-decoder capacity:
//
//     conv1 lane-rom   6 entries
//     conv2 lane-rom  96 entries
//     fc1   lane-rom 1920 entries
//     fc2   lane-rom  420 entries
//     fc3   lane-rom   40 entries
//     ----------------------------
//     Total           2482 entries x 16 bit = 39.7 Kbit per decoder
//
//   Replaces previous full-table-per-lane design which stored
//   61,470 entries per decoder = 983 Kbit each, totalling
//   49.2 Mbit across 25 lanes x 2 decoder types. The lane-sliced
//   design reduces this to ~1.94 Mbit, a 25x reduction, with no
//   change to functional behaviour.
//
// LANE-MAPPING CONVENTION (must match conv_engine / fc_engine FSMs):
//   Conv layers (KK=25, k_cnt=0..24 is kernel position):
//     orig_addr = (oc*IC + ic)*25 + lane     where lane = k_cnt
//     compact   = oc*IC + ic                 = orig_addr / 25
//     valid     = (orig_addr % 25) == LANE_ID
//
//   FC layers (sb_groups = ceil(IN_DIM/25), ki=0..24 is lane):
//     orig_addr = oc*IN_DIM + sb*25 + lane
//     compact   = oc*sb_groups + sb
//     valid     = (orig_addr % IN_DIM) % 25 == LANE_ID
//
//   Out-of-range or wrong-lane orig_addr -> slot = FFFF (clean miss).
//
// Three-state decoding (unchanged from v2):
//   local_slot == FFFF                          -> miss, no error
//   local_slot in [0, size) AND base+slot < TOT -> clean hit
//   any other valid-looking local_slot          -> error, hit=0
//
// Owned hex files (loaded via $readmemh when DATA_DIR != ""):
//   addr_to_slot_conv1_sram_lane<KK>.hex   6 entries each
//   addr_to_slot_conv2_sram_lane<KK>.hex  96 entries each
//   addr_to_slot_fc1_sram_lane<KK>.hex   1920 entries each
//   addr_to_slot_fc2_sram_lane<KK>.hex    420 entries each
//   addr_to_slot_fc3_sram_lane<KK>.hex     40 entries each
//   where <KK> = LANE_ID formatted as zero-padded 2-digit decimal
//   (e.g. 00, 01, ..., 24).
//
// Synthesis note: $readmemh is ignored during synthesis. For
// physical realisation the per-lane compact ROMs may be
// implemented as small initialised ROM macros or boot-loaded
// memories.
//============================================================

`timescale 1ns/1ps

module sram_addr_decoder #(
    parameter integer ADDR_WIDTH = 16,
    parameter integer SRAM_TOTAL = 3074,
    parameter integer LANE_ID    = 0,        // 0..24
    parameter         DATA_DIR   = ""
)(
    input  wire [2:0]              layer_id,
    input  wire [ADDR_WIDTH-1:0]   orig_addr,
    input  wire [15:0]             sram_base,
    input  wire [15:0]             sram_size,

    output wire                    sram_hit,
    output wire [15:0]             sram_pool_addr,
    output wire                    sram_oor_error
);

    // ---- Per-layer lane-sliced ROMs (sized to per-lane share) -----
    reg [15:0] rom_conv1 [0:5];
    reg [15:0] rom_conv2 [0:95];
    reg [15:0] rom_fc1   [0:1919];
    reg [15:0] rom_fc2   [0:419];
    reg [15:0] rom_fc3   [0:39];

    integer i;
    initial begin
        // Default fill: FFFF (clean miss for any unloaded entry).
        for (i = 0; i < 6;    i = i + 1) rom_conv1[i] = 16'hFFFF;
        for (i = 0; i < 96;   i = i + 1) rom_conv2[i] = 16'hFFFF;
        for (i = 0; i < 1920; i = i + 1) rom_fc1[i]   = 16'hFFFF;
        for (i = 0; i < 420;  i = i + 1) rom_fc2[i]   = 16'hFFFF;
        for (i = 0; i < 40;   i = i + 1) rom_fc3[i]   = 16'hFFFF;

        if (DATA_DIR != "") begin
            // SystemVerilog $sformatf is supported by iverilog -g2012.
            $readmemh($sformatf("%s/addr_to_slot_conv1_sram_lane%02d.hex",
                                DATA_DIR, LANE_ID), rom_conv1);
            $readmemh($sformatf("%s/addr_to_slot_conv2_sram_lane%02d.hex",
                                DATA_DIR, LANE_ID), rom_conv2);
            $readmemh($sformatf("%s/addr_to_slot_fc1_sram_lane%02d.hex",
                                DATA_DIR, LANE_ID), rom_fc1);
            $readmemh($sformatf("%s/addr_to_slot_fc2_sram_lane%02d.hex",
                                DATA_DIR, LANE_ID), rom_fc2);
            $readmemh($sformatf("%s/addr_to_slot_fc3_sram_lane%02d.hex",
                                DATA_DIR, LANE_ID), rom_fc3);
        end
    end

    // ---- Zero-extend orig_addr to 16-bit for layer math ----------
    wire [15:0] o16 = {{(16-ADDR_WIDTH){1'b0}}, orig_addr};

    // ---- Conv layer compact_idx and lane match -------------------
    // For conv: compact = orig / 25, valid = (orig % 25) == LANE_ID
    wire [15:0] conv_compact = o16 / 16'd25;
    wire        conv_lane_ok = (o16 % 16'd25) == LANE_ID;

    // ---- FC layer compact_idx and lane match ---------------------
    // Generic FC formula:
    //   oc       = o16 / IN_DIM
    //   flat_idx = o16 % IN_DIM
    //   sb       = (flat_idx - LANE_ID) / 25
    //   compact  = oc * sb_groups + sb
    //   valid    = (flat_idx % 25) == LANE_ID
    // We compute these explicitly per-layer because the divisor
    // IN_DIM differs (400/120/84).

    // fc1: IN_DIM=400, sb_groups=16
    wire [15:0] fc1_oc       = o16 / 16'd400;
    wire [15:0] fc1_flat     = o16 - fc1_oc * 16'd400;
    wire [15:0] fc1_sb       = (fc1_flat >= LANE_ID)
                               ? (fc1_flat - LANE_ID) / 16'd25
                               : 16'd0;
    wire [15:0] fc1_compact  = (fc1_oc << 4) + fc1_sb;          // x16
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
    wire [15:0] fc3_compact  = (fc3_oc << 2) + fc3_sb;          // x4
    wire        fc3_lane_ok  = (fc3_flat % 16'd25) == LANE_ID;

    // ---- Per-layer bounded ROM read -----------------------------
    // Each lookup is guarded by:
    //   1) orig_addr within the layer's global range
    //   2) (orig % stride) == LANE_ID (this lane handles this addr)
    //   3) compact_idx within the lane-sliced ROM depth
    // Any failure returns FFFF (clean miss).

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

    // ---- Layer mux (unchanged) -----------------------------------
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

    // ---- Hit / OOR decode (unchanged from v2) --------------------
    wire raw_hit = (local_slot != 16'hFFFF);

    wire [16:0] pool_addr_ext = {1'b0, sram_base} + {1'b0, local_slot};

    wire size_violation   = raw_hit && (local_slot   >= sram_size);
    wire global_violation = raw_hit && (pool_addr_ext >= SRAM_TOTAL);

    assign sram_oor_error = size_violation | global_violation;
    assign sram_hit       = raw_hit & ~sram_oor_error;
    assign sram_pool_addr = sram_hit ? pool_addr_ext[15:0] : 16'd0;

endmodule
