// pcm_crossbar_stub.v
// Synthesis black-box stub for PCM CIM macro.
// This file replaces rtl/src/pcm_crossbar.v ONLY in the synthesis flow.
// Do NOT use this file for RTL functional simulation.
//
// Yosys sees pcm_crossbar as an external macro and does not descend.
// Area/energy of the PCM crossbar is reported separately via NeuroSim
// (Steps 12f/12g).

(* blackbox *)
module pcm_crossbar #(
    parameter integer K                   = 25,
    parameter integer DATA_WIDTH          = 8,
    parameter integer ADDR_WIDTH          = 16,
    parameter integer ACC_WIDTH           = 24,
    parameter integer PCM_TOTAL           = 58396,
    parameter integer MULTI_CYCLE_LATENCY = 8,
    parameter         DATA_DIR            = "",
    parameter         COMMON_DIR          = ""
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          start,

    input  wire [K*DATA_WIDTH-1:0]       v_bus,
    input  wire [K*ADDR_WIDTH-1:0]       pcm_pool_addr_bus,
    input  wire [K-1:0]                  pcm_hit_bus,

    input  wire                          enable_drift,
    input  wire [15:0]                   drift_t,

    output wire signed [ACC_WIDTH-1:0]   mac_result,
    output wire                          result_valid
);
endmodule
