// bias_storage_stub.v
// Step 12b-1 smoke-flow blackbox for bias_storage.
// Internal: 236-entry × 32-bit signed bias ROM + (layer_id, channel)
// addressing logic. Stubbed only to avoid $display elaboration during
// Yosys read; Step 12b-2 will keep this synthesized.

(* blackbox *)
module bias_storage #(
    parameter integer NUM_LAYERS = 5,
    parameter integer ACC_W      = 32,
    parameter integer BADDR_W    = 8,
    parameter integer MAX_CH     = 120,
    parameter         DATA_DIR   = ""
)(
    input  wire [2:0]                 layer_id,
    input  wire [BADDR_W-1:0]         channel,
    output wire signed [ACC_W-1:0]    bias_out
);
endmodule
