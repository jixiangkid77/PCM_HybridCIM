//============================================================
// sram_pool_25lane_2c.v   (P2R-E8.5c: two-cycle macro read)
//============================================================
// rtl/src/sram_pool_25lane.v with one more output stage: the
// read data reach weight_bus / hit_reg_bus two cycles after the
// address instead of one. Everything else (ports, parameters,
// storage, bounds check, reset, memory init) is unchanged.
//
// Why: E8.4c resume3 (2026-10-18, post-layout, tt 25 C 1.80 V)
// of the 4 KB OpenRAM macro sky130_sram_4kbytes_1rw_8x4096_8:
// with a 100 MHz clock a read is NOT complete within one cycle
// (F2: 4 of 17 reads correct at the end of the cycle), but it is
// complete when the macro's clock stays low for the next system
// cycle (F2b: 9 of 9 correct; data 10.61-10.63 ns after the read
// edge). Decision KID 2026-10-18 11:47: model the macro read as
// two cycles; SRAM_LATENCY, the combiner and lenet5_top unchanged.
//
// Timing (cycle s = datapath start; addresses and hits valid):
//   edge s+1 : the macro of each hit lane gets its one clock
//              pulse and latches the address    -> stage 1 (as before)
//   edge s+2 : no clock at that macro (clock held low); its data
//              output becomes valid ~0.6 ns after this edge
//                                                -> stage 2 (new)
//   edge s+3 : sram_mac registers the sum of the 25 lanes
//   The combiner takes the SRAM sum of cycle s+3: pcm_crossbar
//   asserts result_valid in cycle s+9 (it starts counting at edge
//   s+1) and ALIGN_DELAY = PCM_LATENCY - SRAM_LATENCY = 6 picks
//   sram_partial of cycle s+9-6 = s+3; result_valid of the unit in
//   cycle s+10. (The comments of rtl/src say 2 + 8 cycles; the
//   actual times are one cycle later on both paths, so the
//   difference of 6, and with it the combiner, stays right.)
//   The next read of the same lane must come at least 2 cycles
//   later (the case measured in F2b); E8.2: at least 14.
//
// Module name sram_pool_25lane_2c; instantiated by
// rtl/e8/pcm_imc_unit_e8s.v. The synthesis stub of the pool
// (rtl/stub/sram_pool_25lane_stub.v, a black box for the macro)
// is not affected: both stages belong to the macro model.
//
// Place  : rtl/e8/  (rtl/src/sram_pool_25lane.v is not changed)
// Status : NEW FILE.
//============================================================
// Original header of rtl/src/sram_pool_25lane.v follows.
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

module sram_pool_25lane_2c #(
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
    // K parallel registered outputs, stage 1 (1-cycle latency;
    // E8.5c: the former outputs weight_bus / hit_reg_bus,
    // renamed weight_s1 / hit_s1, logic unchanged)
    //--------------------------------------------------------
    reg [K*DATA_WIDTH-1:0] weight_s1;
    reg [K-1:0]            hit_s1;

    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_s1  <= {(K*DATA_WIDTH){1'b0}};
            hit_s1     <= {K{1'b0}};
        end else begin
            for (j = 0; j < K; j = j + 1) begin
                if (valid_lane[j]) begin
                    weight_s1[j*DATA_WIDTH +: DATA_WIDTH] <= read_lane[j];
                    hit_s1[j]                             <= 1'b1;
                end else begin
                    weight_s1[j*DATA_WIDTH +: DATA_WIDTH] <= {DATA_WIDTH{1'b0}};
                    hit_s1[j]                             <= 1'b0;
                end
            end
        end
    end

    //--------------------------------------------------------
    // E8.5c stage 2: the macro's data output, valid one cycle
    // after stage 1 (two-cycle read; see the header)
    //--------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_bus  <= {(K*DATA_WIDTH){1'b0}};
            hit_reg_bus <= {K{1'b0}};
        end else begin
            weight_bus  <= weight_s1;
            hit_reg_bus <= hit_s1;
        end
    end

endmodule
