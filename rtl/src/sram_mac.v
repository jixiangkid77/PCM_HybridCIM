// ============================================================
// sram_mac.v   (Paper 2 v2)
// ------------------------------------------------------------
// K-channel parallel digital MAC for the SRAM path.
//
// For each channel i:
//   if in_sram_bus[i]:  contributes V[i] * W_sram[i]
//   else:               contributes 0
//
// The K products are summed combinationally and registered (1 cycle).
// Total SRAM-path latency from start = sram_array(1) + sram_mac(1) = 2.
// ============================================================

`timescale 1ns / 1ps

module sram_mac #(
    parameter integer K          = 25,
    parameter integer DATA_WIDTH = 8,
    parameter integer ACC_WIDTH  = 24
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire [K*DATA_WIDTH-1:0]    v_bus,
    input  wire [K*DATA_WIDTH-1:0]    weight_bus,
    input  wire [K-1:0]               in_sram_bus,
    output reg  signed [ACC_WIDTH-1:0] mac_partial
);

    integer i;
    reg signed [ACC_WIDTH-1:0] sum_comb;

    always @(*) begin
        sum_comb = 0;
        for (i = 0; i < K; i = i + 1) begin
            if (in_sram_bus[i]) begin
                sum_comb = sum_comb +
                           $signed(v_bus[i*DATA_WIDTH +: DATA_WIDTH]) *
                           $signed(weight_bus[i*DATA_WIDTH +: DATA_WIDTH]);
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n)
            mac_partial <= 0;
        else
            mac_partial <= sum_comb;
    end

endmodule
