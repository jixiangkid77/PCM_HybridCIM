// ============================================================
// bias_storage.v   (v2 -- hex-file loadable)
// ------------------------------------------------------------
// Per-layer, per-output-channel bias ROM for LeNet-5.
//
// Holds 32-bit signed bias values for all 5 weighted layers:
//   conv1: 6 biases, conv2: 16, fc1: 120, fc2: 84, fc3: 10
//   (total 236 biases)
//
// DATA LOADING
// ------------
// If LOAD_REAL_DATA is defined at compile time, biases are
// loaded from biases_all.hex via $readmemh. The hex file is a
// flat sequence of 236 INT32 values (produced by Python Step 2)
// ordered conv1 -> conv2 -> fc1 -> fc2 -> fc3.
//
// Because Verilog's $readmemh loads into a 1-D array, we load
// into a flat 256-entry staging array, then distribute into the
// 2-D biases[layer][channel] map at time 0.
//
// If LOAD_REAL_DATA is NOT defined, the module falls back to a
// deterministic synthetic pattern (matches v1 behavior): the
// same 17 tests in tb_bias_storage.v keep passing without Python
// outputs.
//
// Path to the hex file comes from DATA_DIR parameter (same as
// weight_memory).
// ============================================================

`timescale 1ns / 1ps

module bias_storage #(
    parameter integer NUM_LAYERS = 5,
    parameter integer ACC_W      = 32,
    parameter integer BADDR_W    = 8,     // up to 256 channels per layer
    parameter integer MAX_CH     = 120,   // largest bias count (fc1 = 120)
    parameter         DATA_DIR   = "../data/rtl_inputs_A"
)(
    input  wire [2:0]                 layer_id,
    input  wire [BADDR_W-1:0]         channel,
    output wire signed [ACC_W-1:0]    bias_out
);

    // 2D bias array: [layer][channel]
    reg signed [ACC_W-1:0] biases [0:NUM_LAYERS-1][0:MAX_CH-1];

    // Staging array for flat hex loading.
    // Size is EXACTLY the total bias count (not rounded up) to keep
    // $readmemh silent -- iverilog warns if the file has fewer words
    // than the array, even when that's intentional.
    // Total: conv1(6) + conv2(16) + fc1(120) + fc2(84) + fc3(10) = 236
    localparam integer TOTAL_BIASES = 236;
    reg signed [ACC_W-1:0] flat_biases [0:TOTAL_BIASES-1];

    // Per-layer counts -- fixed by LeNet-5 architecture
    integer L, C;
    integer per_layer_count [0:4];

    // Where each layer's biases start in the flat file
    //   conv1 -> 0
    //   conv2 -> 6
    //   fc1   -> 22
    //   fc2   -> 142
    //   fc3   -> 226
    integer layer_offset [0:4];

    initial begin
        per_layer_count[0] = 6;     // conv1
        per_layer_count[1] = 16;    // conv2
        per_layer_count[2] = 120;   // fc1
        per_layer_count[3] = 84;    // fc2
        per_layer_count[4] = 10;    // fc3

        layer_offset[0] = 0;
        layer_offset[1] = 6;
        layer_offset[2] = 22;
        layer_offset[3] = 142;
        layer_offset[4] = 226;

        // Default everything to zero
        for (L = 0; L < NUM_LAYERS; L = L + 1) begin
            for (C = 0; C < MAX_CH; C = C + 1) begin
                biases[L][C] = 0;
            end
        end

`ifdef LOAD_REAL_DATA
        // --------------------------------------------------------
        // Real biases from Python Step 2
        // --------------------------------------------------------
        $display("[bias_storage] Loading real biases from %s", DATA_DIR);

        for (C = 0; C < TOTAL_BIASES; C = C + 1) flat_biases[C] = 0;
        $readmemh({DATA_DIR, "/biases_all.hex"}, flat_biases);

        // Distribute flat -> 2D
        for (L = 0; L < NUM_LAYERS; L = L + 1) begin
            for (C = 0; C < per_layer_count[L]; C = C + 1) begin
                biases[L][C] = flat_biases[layer_offset[L] + C];
            end
        end
`else
        // --------------------------------------------------------
        // Synthetic fallback: bias[L][c] = L*100 + c - 50
        // --------------------------------------------------------
        for (L = 0; L < NUM_LAYERS; L = L + 1) begin
            for (C = 0; C < per_layer_count[L]; C = C + 1) begin
                biases[L][C] = (L * 100) + C - 50;
            end
        end
`endif
    end

    // Combinational read
    assign bias_out = biases[layer_id][channel];

endmodule
