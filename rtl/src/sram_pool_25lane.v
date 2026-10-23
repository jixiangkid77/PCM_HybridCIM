//============================================================
// sram_pool_25lane.v
// Paper 2 v3 (X' refactor) — K-lane parallel read wrapper
// for the SRAM-resident protected weights.
//============================================================
//
// Functional model:
//   ONE shared SRAM_TOTAL-entry storage memory; K=25 parallel
//   read lanes; each lane is 1-cycle registered.
//
//   Per lane i:
//     if hit_bus[i] && addr_in_range(addr_bus[i]):
//         weight_bus[i]  <= sram_pool_mem[addr_bus[i]]
//         hit_reg_bus[i] <= 1
//     else:
//         weight_bus[i]  <= 0
//         hit_reg_bus[i] <= 0
//
//   hit_reg_bus is the 1-cycle delayed copy of hit_bus, gated
//   by addr-in-range. Timing aligned with weight_bus so that
//   downstream sram_mac.v can consume (weight_bus, in_sram_bus)
//   on the same cycle without further pipelining.
//
//   This module replaces the "25 instances of sram_pool"
//   alternative that would have implied 25x storage area in
//   physical interpretation. By design it has one logical
//   storage block and K read ports; physical realisation by
//   the SRAM compiler may use banking, replication, or a
//   true K-port macro depending on technology.
//
// Synthesis note:
//   The memory portion is intended to be replaced by an SRAM
//   macro stub at synthesis time. The lane-decode and
//   registered-output logic synthesizes as ordinary digital.
//
// Address-out-of-range defense:
//   Mirrors the in_range guard in sram_pool.v (Step 3b) and
//   pcm_crossbar.v (Step 4b). Even though sram_addr_decoder
//   should never emit an out-of-range address on its hit
//   path, this wrapper independently bounds the read.
//
// Reset:
//   Clears weight_bus and hit_reg_bus only.
//   sram_pool_mem is intentionally NOT reset (boot-config
//   semantics — same as sram_pool.v).
//
// Memory init:
//   When DATA_DIR != "", an initial-block $readmemh loads
//   sram_pool.hex. In simulation tests the testbench may also
//   override individual cells via hierarchical assignment to
//   sram_pool_mem; this verifies that all K lanes see the
//   same underlying storage (the "single shared memory" test).
//============================================================

`timescale 1ns/1ps

module sram_pool_25lane #(
    parameter integer K          = 25,
    parameter integer DATA_WIDTH = 8,
    parameter integer ADDR_WIDTH = 16,
    parameter integer SRAM_TOTAL = 3074,
    parameter         DATA_DIR   = ""
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire [K*ADDR_WIDTH-1:0]    addr_bus,
    input  wire [K-1:0]               hit_bus,
    output reg  [K*DATA_WIDTH-1:0]    weight_bus,
    output reg  [K-1:0]               hit_reg_bus
);

    //--------------------------------------------------------
    // Single shared storage
    //--------------------------------------------------------
    reg signed [DATA_WIDTH-1:0] sram_pool_mem [0:SRAM_TOTAL-1];

    integer i;
    initial begin
        for (i = 0; i < SRAM_TOTAL; i = i + 1) begin
            sram_pool_mem[i] = {DATA_WIDTH{1'b0}};
        end
        if (DATA_DIR != "") begin
            $readmemh({DATA_DIR, "/sram_pool.hex"}, sram_pool_mem);
        end
    end

    //--------------------------------------------------------
    // Per-lane combinational lookup (K parallel reads from
    // one shared storage). Each lane independently bounds-
    // checks its address.
    //--------------------------------------------------------
    wire [ADDR_WIDTH-1:0]        addr_lane     [0:K-1];
    wire                         hit_lane      [0:K-1];
    wire [ADDR_WIDTH:0]          addr_ext_lane [0:K-1];   // 17-bit
    wire                         in_range_lane [0:K-1];
    wire                         valid_lane    [0:K-1];
    wire signed [DATA_WIDTH-1:0] read_lane     [0:K-1];

    // Extended SRAM_TOTAL for safe bounds comparison without
    // parameter-slice-width gotchas. localparam form makes the
    // width explicit at elaboration time.
    localparam [ADDR_WIDTH:0] SRAM_TOTAL_EXT = SRAM_TOTAL[ADDR_WIDTH:0];

    genvar gi;
    generate
        for (gi = 0; gi < K; gi = gi + 1) begin: lane
            assign addr_lane[gi]     = addr_bus[gi*ADDR_WIDTH +: ADDR_WIDTH];
            assign hit_lane[gi]      = hit_bus[gi];
            assign addr_ext_lane[gi] = {1'b0, addr_lane[gi]};
            assign in_range_lane[gi] = (addr_ext_lane[gi] < SRAM_TOTAL_EXT);
            assign valid_lane[gi]    = hit_lane[gi] & in_range_lane[gi];

            // Safe-address read: when not valid, force addr=0 to
            // keep the read pattern within bounds. Output gets
            // gated to 0 below anyway.
            assign read_lane[gi] =
                sram_pool_mem[valid_lane[gi] ? addr_lane[gi]
                                             : {ADDR_WIDTH{1'b0}}];
        end
    endgenerate

    //--------------------------------------------------------
    // K parallel registered outputs (1-cycle latency)
    //--------------------------------------------------------
    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_bus  <= {(K*DATA_WIDTH){1'b0}};
            hit_reg_bus <= {K{1'b0}};
        end else begin
            for (j = 0; j < K; j = j + 1) begin
                if (valid_lane[j]) begin
                    weight_bus[j*DATA_WIDTH +: DATA_WIDTH] <= read_lane[j];
                    hit_reg_bus[j]                         <= 1'b1;
                end else begin
                    weight_bus[j*DATA_WIDTH +: DATA_WIDTH] <= {DATA_WIDTH{1'b0}};
                    hit_reg_bus[j]                         <= 1'b0;
                end
            end
        end
    end

endmodule
