// ============================================================
// weight_memory.v   (v2.1 -- per-layer sized arrays)
// ------------------------------------------------------------
// Same external interface and bitmap semantics as v2, but uses
// per-layer correctly-sized arrays instead of a single MAX_DEPTH
// 2D array. This dramatically reduces simulator memory and
// initialization time on Icarus Verilog.
//
// Total weight storage = 150 + 2400 + 48000 + 10080 + 840 = 61470
// Same for protected bitmap. (vs 240000 in the v2 single-array
// approach; the per-layer version is 4x smaller in storage and
// initialization cost.)
//
// External interface unchanged:
//   layer_id, local_addr  -> weight, is_protected
// ============================================================

`timescale 1ns / 1ps

module weight_memory #(
    parameter integer NUM_LAYERS = 5,
    parameter integer DATA_WIDTH = 8,
    parameter integer ADDR_WIDTH = 16,
    parameter         DATA_DIR   = "../data/rtl_inputs_A"
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire [2:0]                 layer_id,
    input  wire [ADDR_WIDTH-1:0]      local_addr,
    output wire signed [DATA_WIDTH-1:0] weight,
    output wire                       is_protected
);

    // Per-layer weight counts
    localparam integer N_CONV1 = 150;
    localparam integer N_CONV2 = 2400;
    localparam integer N_FC1   = 48000;
    localparam integer N_FC2   = 10080;
    localparam integer N_FC3   = 840;

    // ------------------------------------------------------
    // Per-layer storage arrays (correctly sized -- not MAX_DEPTH)
    // ------------------------------------------------------
    reg signed [DATA_WIDTH-1:0] w_conv1 [0:N_CONV1-1];
    reg signed [DATA_WIDTH-1:0] w_conv2 [0:N_CONV2-1];
    reg signed [DATA_WIDTH-1:0] w_fc1   [0:N_FC1-1];
    reg signed [DATA_WIDTH-1:0] w_fc2   [0:N_FC2-1];
    reg signed [DATA_WIDTH-1:0] w_fc3   [0:N_FC3-1];

    reg                         p_conv1 [0:N_CONV1-1];
    reg                         p_conv2 [0:N_CONV2-1];
    reg                         p_fc1   [0:N_FC1-1];
    reg                         p_fc2   [0:N_FC2-1];
    reg                         p_fc3   [0:N_FC3-1];

    // ------------------------------------------------------
    // Initialization
    // ------------------------------------------------------
    integer A;
    reg [15:0] syn_val;

    initial begin
        // Default everything to zero
        for (A = 0; A < N_CONV1; A = A + 1) begin
            w_conv1[A] = 0; p_conv1[A] = 0;
        end
        for (A = 0; A < N_CONV2; A = A + 1) begin
            w_conv2[A] = 0; p_conv2[A] = 0;
        end
        for (A = 0; A < N_FC1; A = A + 1) begin
            w_fc1[A] = 0; p_fc1[A] = 0;
        end
        for (A = 0; A < N_FC2; A = A + 1) begin
            w_fc2[A] = 0; p_fc2[A] = 0;
        end
        for (A = 0; A < N_FC3; A = A + 1) begin
            w_fc3[A] = 0; p_fc3[A] = 0;
        end

`ifdef LOAD_REAL_DATA
        $display("[weight_memory] Loading real weights from %s", DATA_DIR);
        $readmemh({DATA_DIR, "/weights_conv1.hex"}, w_conv1);
        $readmemh({DATA_DIR, "/weights_conv2.hex"}, w_conv2);
        $readmemh({DATA_DIR, "/weights_fc1.hex"},   w_fc1);
        $readmemh({DATA_DIR, "/weights_fc2.hex"},   w_fc2);
        $readmemh({DATA_DIR, "/weights_fc3.hex"},   w_fc3);
        $readmemh({DATA_DIR, "/protected_conv1.hex"}, p_conv1);
        $readmemh({DATA_DIR, "/protected_conv2.hex"}, p_conv2);
        $readmemh({DATA_DIR, "/protected_fc1.hex"},   p_fc1);
        $readmemh({DATA_DIR, "/protected_fc2.hex"},   p_fc2);
        $readmemh({DATA_DIR, "/protected_fc3.hex"},   p_fc3);
`else
        // Synthetic fallback (matches v2 behavior so existing tests pass)
        // Pattern: weights[L][A] = (L*1000 + A) & 0xFF
        // Protected: first N entries protected per Model A counts
        for (A = 0; A < N_CONV1; A = A + 1) begin
            syn_val = 0 * 1000 + A;
            w_conv1[A] = syn_val[DATA_WIDTH-1:0];
        end
        for (A = 0; A < N_CONV2; A = A + 1) begin
            syn_val = 1 * 1000 + A;
            w_conv2[A] = syn_val[DATA_WIDTH-1:0];
        end
        for (A = 0; A < N_FC1; A = A + 1) begin
            syn_val = 2 * 1000 + A;
            w_fc1[A] = syn_val[DATA_WIDTH-1:0];
        end
        for (A = 0; A < N_FC2; A = A + 1) begin
            syn_val = 3 * 1000 + A;
            w_fc2[A] = syn_val[DATA_WIDTH-1:0];
        end
        for (A = 0; A < N_FC3; A = A + 1) begin
            syn_val = 4 * 1000 + A;
            w_fc3[A] = syn_val[DATA_WIDTH-1:0];
        end
        // Protected bitmap: Model A counts
        for (A = 0; A < 150;  A = A + 1) p_conv1[A] = 1'b1;
        for (A = 0; A < 1481; A = A + 1) p_conv2[A] = 1'b1;
        for (A = 0; A < 334;  A = A + 1) p_fc1[A]   = 1'b1;
        for (A = 0; A < 313;  A = A + 1) p_fc2[A]   = 1'b1;
        for (A = 0; A < 793;  A = A + 1) p_fc3[A]   = 1'b1;
`endif
    end

    // ------------------------------------------------------
    // Read path: combinational mux on layer_id
    // ------------------------------------------------------
    wire [ADDR_WIDTH-1:0] a = local_addr;

    // Per-layer reads with bounds clamping
    wire signed [DATA_WIDTH-1:0] r0 = (a < N_CONV1) ? w_conv1[a] : {DATA_WIDTH{1'b0}};
    wire signed [DATA_WIDTH-1:0] r1 = (a < N_CONV2) ? w_conv2[a] : {DATA_WIDTH{1'b0}};
    wire signed [DATA_WIDTH-1:0] r2 = (a < N_FC1)   ? w_fc1[a]   : {DATA_WIDTH{1'b0}};
    wire signed [DATA_WIDTH-1:0] r3 = (a < N_FC2)   ? w_fc2[a]   : {DATA_WIDTH{1'b0}};
    wire signed [DATA_WIDTH-1:0] r4 = (a < N_FC3)   ? w_fc3[a]   : {DATA_WIDTH{1'b0}};

    wire q0 = (a < N_CONV1) ? p_conv1[a] : 1'b0;
    wire q1 = (a < N_CONV2) ? p_conv2[a] : 1'b0;
    wire q2 = (a < N_FC1)   ? p_fc1[a]   : 1'b0;
    wire q3 = (a < N_FC2)   ? p_fc2[a]   : 1'b0;
    wire q4 = (a < N_FC3)   ? p_fc3[a]   : 1'b0;

    reg signed [DATA_WIDTH-1:0] weight_r;
    reg                         prot_r;
    always @(*) begin
        case (layer_id)
            3'd0: begin weight_r = r0; prot_r = q0; end
            3'd1: begin weight_r = r1; prot_r = q1; end
            3'd2: begin weight_r = r2; prot_r = q2; end
            3'd3: begin weight_r = r3; prot_r = q3; end
            3'd4: begin weight_r = r4; prot_r = q4; end
            default: begin weight_r = 0; prot_r = 0; end
        endcase
    end

    assign weight       = weight_r;
    assign is_protected = prot_r;

    wire _unused = &{1'b0, clk, rst_n};

endmodule
