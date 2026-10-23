// pcm_addr_decoder_stub.v
// Step 12b-1 black-box stub for the PCM address decoder.
// See sram_addr_decoder_stub.v for the same caveat about Step 12b-2
// surgical ROM/wrapper split.

(* blackbox *)
module pcm_addr_decoder #(
    parameter integer ADDR_WIDTH = 16,
    parameter integer PCM_TOTAL  = 58396,
    parameter integer LANE_ID    = 0,
    parameter         DATA_DIR   = ""
)(
    input  wire [2:0]              layer_id,
    input  wire [ADDR_WIDTH-1:0]   orig_addr,
    input  wire [15:0]             pcm_base,
    input  wire [15:0]             pcm_size,

    output wire                    pcm_hit,
    output wire [15:0]             pcm_pool_addr,
    output wire                    pcm_oor_error
);
endmodule
