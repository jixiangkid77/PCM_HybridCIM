//============================================================
// sram_pool.v
// Paper 2 v3 — Unified SRAM weight pool (X' "pure memory")
//============================================================
// A single flat SRAM array holding the protected partition of
// every layer concatenated in canonical order
// (conv1 + conv2 + fc1 + fc2 + fc3 = 3074 INT8 weights for
// Model A and Model B at 5% protection budget).
//
// This module is intentionally minimal: it has no knowledge of
// layers, partitions, or original weight addresses. All address
// translation happens upstream in sram_addr_decoder. Here we
// have just:
//
//       addr  ──>│  weight (1-cycle registered)
//       hit   ──>│
//        clk  ──>│
//      rst_n  ──>│
//
// This mirrors how a real foundry-compiled SRAM macro presents
// itself to the surrounding RTL, which keeps the synthesis
// boundary clean.
//
// Timing:
//   cycle N    : addr, hit driven (by sram_addr_decoder, comb)
//   cycle N+1  : weight registered output valid
//
// Total path latency (decoder + pool) = 1 cycle, identical to
// v2 sram_array. This is required for v3 functional equivalence
// with v2 (Step 9).
//
// On miss (hit=0)   : weight <= 0
// On reset (rst_n=0): weight <= 0
// On addr out of range when hit=1 (should never happen if
//   decoder is correct): weight <= 0 as a defensive fallback.
//
// Storage init:
//   When DATA_DIR != "", $readmemh loads sram_pool.hex at time 0.
//   For synthesis, the memory should be implemented as an
//   initialized SRAM macro / ROM / boot-loaded RAM depending on
//   target flow.
//============================================================

`timescale 1ns/1ps

module sram_pool #(
    parameter integer DATA_WIDTH = 8,
    parameter integer SRAM_TOTAL = 3074,
    parameter         DATA_DIR   = ""
)(
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire [15:0]                       addr,
    input  wire                              hit,
    output reg  signed [DATA_WIDTH-1:0]      weight
);

    // ---- Storage -------------------------------------------------
    // Signed INT8 by default. $readmemh treats lines as raw bytes,
    // and the signed declaration makes subsequent arithmetic use
    // two's-complement semantics (e.g. 0xf0 -> -16).
    reg signed [DATA_WIDTH-1:0] sram_pool_mem [0:SRAM_TOTAL-1];

    integer i;
    initial begin
        // Default-init to 0 so that an un-loaded pool behaves
        // identically to a fully-miss scenario.
        for (i = 0; i < SRAM_TOTAL; i = i + 1) begin
            sram_pool_mem[i] = {DATA_WIDTH{1'b0}};
        end
        if (DATA_DIR != "") begin
            $readmemh({DATA_DIR, "/sram_pool.hex"}, sram_pool_mem);
        end
    end

    // ---- Defensive range check ----------------------------------
    // sram_addr_decoder already enforces addr < SRAM_TOTAL on its
    // hit path, but the pool guards independently. Belt + braces.
    wire addr_in_range = (addr < SRAM_TOTAL[15:0]);

    // ---- 1-cycle registered output ------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight <= {DATA_WIDTH{1'b0}};
        end else begin
            if (hit && addr_in_range) begin
                weight <= sram_pool_mem[addr];
            end else begin
                weight <= {DATA_WIDTH{1'b0}};
            end
        end
    end

endmodule
