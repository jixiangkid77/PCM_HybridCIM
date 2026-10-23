// layer_config_regfile_stub.v
// Step 12b-1 smoke-flow blackbox.

(* blackbox *)
module layer_config_regfile #(
    parameter DATA_DIR = ""
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        wr_en,
    input  wire [5:0]  wr_addr,
    input  wire [31:0] wr_data,
    input  wire [5:0]  rd_addr,
    output wire [31:0] rd_data,
    input  wire [2:0]  layer_id,
    output wire [15:0] sram_base,
    output wire [15:0] sram_size,
    output wire [15:0] pcm_base,
    output wire [15:0] pcm_size,
    output wire        cfg_valid,
    output wire        enable_drift,
    output wire [15:0] drift_t
);
endmodule
