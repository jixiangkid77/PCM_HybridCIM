// sram_pool_25lane_stub.v
// Step 12b-1 black-box stub for the 25-lane SRAM pool memory.
// Treats the SRAM weight pool as an external macro.

(* blackbox *)
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
    output wire [K*DATA_WIDTH-1:0]    weight_bus,
    output wire [K-1:0]               hit_reg_bus
);
endmodule
