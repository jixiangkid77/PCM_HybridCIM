// ============================================================
// layer_desc_rom.v
// ------------------------------------------------------------
// Per-step configuration ROM for the LeNet-5 top-level FSM.
//
// LeNet-5 inference is decomposed into 8 sequential steps:
//
//   step   kind     shape transformation              weight layer
//   ----   ------   ------------------------------    ------------
//    0     CONV     28x28x1  -> 28x28x6  K=5 P=2      0  (conv1)
//    1     POOL     28x28x6  -> 14x14x6
//    2     CONV     14x14x6  -> 10x10x16 K=5 P=0      1  (conv2)
//    3     POOL     10x10x16 -> 5x5x16
//    4     FC       400      -> 120      relu         2  (fc1)
//    5     FC       120      -> 84       relu         3  (fc2)
//    6     FC       84       -> 10       NO relu      4  (fc3)
//    7     ARGMAX   10       -> 1 class index
//
// The top FSM walks step_id from 0 to NUM_STEPS-1; at each
// step it dispatches the right engine based on layer_kind.
//
// layer_kind encoding:
//   2'b00 = CONV
//   2'b01 = POOL
//   2'b10 = FC
//   2'b11 = ARGMAX
//
// This ROM is combinational: given step_id, all fields appear
// on the same cycle. The top FSM captures what it needs.
//
// Fields that do not apply to a given step (e.g. KERNEL for
// FC, RSHIFT for ARGMAX) are still driven to a safe default
// value so downstream logic does not need to care.
// ============================================================

`timescale 1ns / 1ps

module layer_desc_rom #(
    parameter integer NUM_STEPS = 8,
    parameter         DATA_DIR  = "../data/rtl_inputs_A"
)(
    input  wire [3:0]  step_id,

    // Layer type
    output reg  [1:0]  layer_kind,     // 00=CONV, 01=POOL, 10=FC, 11=ARGMAX

    // Spatial dimensions (used by CONV and POOL)
    output reg  [7:0]  in_h,
    output reg  [7:0]  in_w,
    output reg  [7:0]  in_ch,
    output reg  [7:0]  out_h,
    output reg  [7:0]  out_w,
    output reg  [7:0]  out_ch,

    // Conv-specific
    output reg  [3:0]  kernel,
    output reg  [3:0]  padding,

    // FC-specific (in_dim, out_dim = 16-bit because fc1 has 400)
    output reg  [15:0] in_dim,
    output reg  [15:0] out_dim,

    // Quantization / activation
    output reg  [3:0]  rshift,
    output reg         use_relu,       // 1 = apply ReLU, 0 = plain (fc3)

    // Which weight_memory layer to index (CONV and FC only)
    output reg  [2:0]  weight_layer,

    // Last-step flag (convenience)
    output reg         is_last_step
);

    // Layer kind values (match the encoding doc'd above)
    localparam [1:0] KIND_CONV   = 2'b00;
    localparam [1:0] KIND_POOL   = 2'b01;
    localparam [1:0] KIND_FC     = 2'b10;
    localparam [1:0] KIND_ARGMAX = 2'b11;

    // -----------------------------------------------------------
    // Per-layer requantization shift (RSHIFT) table
    //
    // Loaded from rshift.hex (one value per line, 5 entries) when
    // LOAD_REAL_DATA is defined. Produced by Python Step 2.
    // Otherwise falls back to a reasonable default (8).
    // -----------------------------------------------------------
    // 8-bit storage to match Python's 2-hex-digit output format,
    // but only the low 4 bits are used (RSHIFT range 0..15)
    reg [7:0] rshift_table [0:4];
    integer k;
    initial begin
        // Default: 8 for every layer (matches v1 synthetic behavior)
        for (k = 0; k < 5; k = k + 1) begin
            rshift_table[k] = 4'd8;
        end
`ifdef LOAD_REAL_DATA
        $display("[layer_desc_rom] Loading rshift table from %s", DATA_DIR);
        $readmemh({DATA_DIR, "/rshift_per_layer.hex"}, rshift_table);
        $display("[layer_desc_rom] rshift = %0d %0d %0d %0d %0d",
                 rshift_table[0], rshift_table[1], rshift_table[2],
                 rshift_table[3], rshift_table[4]);
`endif
    end

    always @(*) begin
        // Defaults: everything zero, use_relu=1 for weighted layers
        layer_kind   = KIND_CONV;
        in_h         = 8'd0;
        in_w         = 8'd0;
        in_ch        = 8'd0;
        out_h        = 8'd0;
        out_w        = 8'd0;
        out_ch       = 8'd0;
        kernel       = 4'd0;
        padding      = 4'd0;
        in_dim       = 16'd0;
        out_dim      = 16'd0;
        rshift       = 4'd8;
        use_relu     = 1'b1;
        weight_layer = 3'd0;
        is_last_step = 1'b0;

        case (step_id)
            // ------------------------------------------------
            // STEP 0: conv1
            //   28x28x1 -> 28x28x6, K=5, P=2
            // ------------------------------------------------
            4'd0: begin
                layer_kind   = KIND_CONV;
                in_h         = 8'd28;
                in_w         = 8'd28;
                in_ch        = 8'd1;
                out_h        = 8'd28;
                out_w        = 8'd28;
                out_ch       = 8'd6;
                kernel       = 4'd5;
                padding      = 4'd2;
                rshift       = rshift_table[0];
                use_relu     = 1'b1;
                weight_layer = 3'd0;   // conv1 weights in layer 0 of weight_memory
            end

            // ------------------------------------------------
            // STEP 1: pool1
            //   28x28x6 -> 14x14x6, 2x2 max pooling, stride 2
            // ------------------------------------------------
            4'd1: begin
                layer_kind = KIND_POOL;
                in_h       = 8'd28;
                in_w       = 8'd28;
                in_ch      = 8'd6;
                out_h      = 8'd14;
                out_w      = 8'd14;
                out_ch     = 8'd6;
                kernel     = 4'd2;
                // pool has no learnable weights
                use_relu   = 1'b0;     // pool doesn't apply ReLU (already done in conv)
            end

            // ------------------------------------------------
            // STEP 2: conv2
            //   14x14x6 -> 10x10x16, K=5, P=0
            // ------------------------------------------------
            4'd2: begin
                layer_kind   = KIND_CONV;
                in_h         = 8'd14;
                in_w         = 8'd14;
                in_ch        = 8'd6;
                out_h        = 8'd10;
                out_w        = 8'd10;
                out_ch       = 8'd16;
                kernel       = 4'd5;
                padding      = 4'd0;
                rshift       = rshift_table[1];
                use_relu     = 1'b1;
                weight_layer = 3'd1;   // conv2 weights in layer 1
            end

            // ------------------------------------------------
            // STEP 3: pool2
            //   10x10x16 -> 5x5x16, 2x2 max pooling, stride 2
            // ------------------------------------------------
            4'd3: begin
                layer_kind = KIND_POOL;
                in_h       = 8'd10;
                in_w       = 8'd10;
                in_ch      = 8'd16;
                out_h      = 8'd5;
                out_w      = 8'd5;
                out_ch     = 8'd16;
                kernel     = 4'd2;
                use_relu   = 1'b0;
            end

            // ------------------------------------------------
            // STEP 4: fc1
            //   400 -> 120, ReLU
            //   (400 = 16 * 5 * 5, flattened from pool2 output)
            // ------------------------------------------------
            4'd4: begin
                layer_kind   = KIND_FC;
                in_dim       = 16'd400;
                out_dim      = 16'd120;
                rshift       = rshift_table[2];
                use_relu     = 1'b1;
                weight_layer = 3'd2;   // fc1 weights in layer 2
            end

            // ------------------------------------------------
            // STEP 5: fc2
            //   120 -> 84, ReLU
            // ------------------------------------------------
            4'd5: begin
                layer_kind   = KIND_FC;
                in_dim       = 16'd120;
                out_dim      = 16'd84;
                rshift       = rshift_table[3];
                use_relu     = 1'b1;
                weight_layer = 3'd3;   // fc2 weights in layer 3
            end

            // ------------------------------------------------
            // STEP 6: fc3
            //   84 -> 10, NO ReLU (logits go to argmax)
            // ------------------------------------------------
            4'd6: begin
                layer_kind   = KIND_FC;
                in_dim       = 16'd84;
                out_dim      = 16'd10;
                rshift       = rshift_table[4];
                use_relu     = 1'b0;   // critical: keep negative logits
                weight_layer = 3'd4;   // fc3 weights in layer 4
            end

            // ------------------------------------------------
            // STEP 7: argmax (final)
            //   10 logits -> 1 class index
            // ------------------------------------------------
            4'd7: begin
                layer_kind   = KIND_ARGMAX;
                in_dim       = 16'd10;   // 10 input logits
                out_dim      = 16'd1;    // 1 scalar index
                use_relu     = 1'b0;
                is_last_step = 1'b1;
            end

            // ------------------------------------------------
            // Any out-of-range step: safe default (no-op CONV with
            // zero size; downstream FSM should never query this)
            // ------------------------------------------------
            default: begin
                // already zeroed above
            end
        endcase
    end

endmodule
