// sram_pool_25lane_2c_stub.v   (P2R-E8.7)
// Black box of the SRAM weight pool with the two-cycle macro read of E8.5c
// (rtl/e8/sram_pool_25lane_2c.v, the simulation model) for synthesis; the
// same module name, parameters and ports. Like rtl/stub/sram_pool_25lane_stub.v
// for the pool of the original design, it replaces the model only in synthesis.
// Place : rtl/e8/   Status : NEW FILE.
(* blackbox *)
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
    output wire [K*DATA_WIDTH-1:0]    weight_bus,
    output wire [K-1:0]               hit_reg_bus
);
endmodule
