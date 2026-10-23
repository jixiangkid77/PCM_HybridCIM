//============================================================
// amu_top_gl_wrap.v   (P2R-E8.5b, gate-level simulation only)
//============================================================
// Stands in for rtl/e8/amu_top.v in the gate-level run: the same
// module name, parameters and ports, so rtl/e8/pcm_imc_unit_e8.v is
// compiled unchanged. Inside is the synthesised netlist of E8.5
// (reports/e8_rom/e8_5/amu_top_<M>_sta.v), flattened by Yosys into one
// module with single-bit nets and plain names (same cells, same
// connections; scripts/e8_5b_check.py netlists checks this), whose top
// module the script renames to amu_top_gl and whose 200 ROM black
// boxes get the data folder of the model (the netlist has no DATA_DIR).
// The parameters are not used: the netlist is for K = 25,
// ADDR_WIDTH = 16 and the totals of the design.
// The instance U_GL is the scope of the waveform for the power
// analysis (tb_lenet5_full_inference_v3/DUT/u_imc/U_AMU/U_GL).
//
// Place  : rtl/e8/tb/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

module amu_top #(
    parameter integer K          = 25,
    parameter integer ADDR_WIDTH = 16,
    parameter integer SRAM_TOTAL = 3074,
    parameter integer PCM_TOTAL  = 58396,
    parameter         DATA_DIR   = ""
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire [2:0]              layer_id,
    input  wire [K*ADDR_WIDTH-1:0] orig_addr_bus,
    input  wire                    start_req,
    input  wire [15:0]             sram_base,
    input  wire [15:0]             sram_size,
    input  wire [15:0]             pcm_base,
    input  wire [15:0]             pcm_size,
    output wire [K-1:0]            sram_hit,
    output wire [K-1:0]            sram_oor,
    output wire [K*ADDR_WIDTH-1:0] sram_pool_addr_bus,
    output wire [K-1:0]            pcm_hit,
    output wire [K-1:0]            pcm_oor,
    output wire [K*ADDR_WIDTH-1:0] pcm_pool_addr_bus,
    output wire                    start_go,
    output wire                    stall,
    output wire [31:0]             n_lookup_reads,
    output wire [31:0]             n_park_reads,
    output wire [31:0]             n_stall_cycles,
    output wire [31:0]             n_starts,
    output wire [2:0]              errors
);

    amu_top_gl U_GL (
        .clk(clk), .rst_n(rst_n), .layer_id(layer_id), .orig_addr_bus(orig_addr_bus), .start_req(start_req),
        .sram_base(sram_base), .sram_size(sram_size), .pcm_base(pcm_base), .pcm_size(pcm_size),
        .sram_hit(sram_hit), .sram_oor(sram_oor), .sram_pool_addr_bus(sram_pool_addr_bus),
        .pcm_hit(pcm_hit), .pcm_oor(pcm_oor), .pcm_pool_addr_bus(pcm_pool_addr_bus),
        .start_go(start_go), .stall(stall),
        .n_lookup_reads(n_lookup_reads), .n_park_reads(n_park_reads),
        .n_stall_cycles(n_stall_cycles), .n_starts(n_starts), .errors(errors)
    );

endmodule
