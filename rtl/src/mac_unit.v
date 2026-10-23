// ============================================================
// mac_unit.v
// ------------------------------------------------------------
// Single signed multiply-accumulate unit.
//
// Computes:  acc <= (clear ? 0 : acc) + a*b     when en=1
//
// Timing: 1 cycle latency. Inputs at cycle N, result visible
// at cycle N+1.
//
// Parameters:
//   DATA_WIDTH - bit width of operands a and b  (default 8)
//   ACC_WIDTH  - bit width of accumulator       (default 32)
//
// Notes:
//   - a and b are SIGNED; declarations use `signed` so that
//     Verilog does proper sign extension during multiply/add.
//   - The multiplier is combinational; only the accumulator
//     is registered. This keeps the critical path short.
//   - Overflow: ACC_WIDTH=32 is chosen to safely hold any
//     LeNet-5 or small-CNN accumulation without overflow.
//     (Worst case fc1: 400 MACs of 8b*8b -> ~23 bits, 9 bits margin)
// ============================================================

`timescale 1ns / 1ps

module mac_unit #(
    parameter integer DATA_WIDTH = 8,
    parameter integer ACC_WIDTH  = 32
)(
    input  wire                            clk,
    input  wire                            rst_n,   // async, active-low
    input  wire                            en,      // enable this cycle
    input  wire                            clear,   // start new MAC sequence
    input  wire signed [DATA_WIDTH-1:0]    a,       // activation
    input  wire signed [DATA_WIDTH-1:0]    b,       // weight
    output reg  signed [ACC_WIDTH-1:0]     acc_out
);

    // ---------------------------------------------------------
    // Combinational multiplier: signed 8b * signed 8b -> 16b
    // ---------------------------------------------------------
    wire signed [2*DATA_WIDTH-1:0] product;
    assign product = a * b;

    // ---------------------------------------------------------
    // Accumulator register
    // Using async active-low reset (industry convention).
    // Non-blocking assignment (<=) for register updates.
    // ---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_out <= {ACC_WIDTH{1'b0}};
        end else if (en) begin
            if (clear)
                acc_out <= product;              // auto sign-extend 16b->32b
            else
                acc_out <= acc_out + product;    // auto sign-extend during add
        end
        // if !en: acc_out holds its value (implicit)
    end

endmodule
