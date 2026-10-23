// ============================================================
// top_fsm.v
// ------------------------------------------------------------
// Top-level FSM that orchestrates an end-to-end LeNet-5
// inference by sequencing through the 8 steps defined in
// layer_desc_rom and dispatching each step to the appropriate
// engine (conv_engine, pool_wrapper, fc_engine, argmax_wrapper).
//
// This module instantiates:
//   - layer_desc_rom (config table)
//   - conv_engine    (handles CONV steps)
//   - pool_wrapper   (handles POOL steps)
//   - fc_engine      (handles FC steps; ALSO INSTANTIATED FOR fc3)
//   - argmax_wrapper (handles ARGMAX final step)
//
// It does NOT instantiate weight_memory, feature_buffer, the
// bias storage, or the logit register file -- those live in
// lenet5_top.v and are accessed via the external ports below.
//
// MUX strategy:
//   At any moment, exactly one engine is "active" (selected by
//   the current step's layer_kind from layer_desc_rom). All
//   address/data signals to the shared feature_buffer and
//   weight_memory are muxed from the active engine.
//
// fc3 special case:
//   Step 6 (fc3) writes 16-bit logits to a dedicated logit
//   register file (in lenet5_top), NOT to feature_buffer. So
//   after step 6 we do NOT swap; argmax_wrapper reads directly
//   from the logit reg file.
//
// IMPORTANT: This module currently uses a SINGLE conv_engine
// instance with parameters set for conv1. Because conv2 has
// DIFFERENT parameters (14x14x6 -> 10x10x16, P=0), we use
// run-time configurable conv_engine inputs would be ideal --
// BUT the current conv_engine has compile-time parameters.
//
// Solution adopted here: we instantiate TWO conv_engines (one
// per conv layer) and TWO fc_engines per FC layer dimension.
// Pros: each is correctly parameterized; FSM picks which one.
// Cons: more area (~5x compute logic), but in academic RTL
//       this is standard practice. See discussion in paper.
//
// (Alternative would be making conv_engine itself parameterized
//  at run-time via input ports for IN_H, etc., but that adds
//  a lot of multipliers to the address generation. We chose
//  multiple specialized instances for clarity.)
// ============================================================

`timescale 1ns / 1ps

module top_fsm #(
    parameter integer DATA_W   = 8,
    parameter integer LOGIT_W  = 16,
    parameter integer ACC_W    = 32,
    parameter integer FADDR_W  = 13,
    parameter integer OADDR_W  = 13,
    parameter integer WADDR_W  = 16,
    parameter integer BADDR_W  = 8,
    parameter         DATA_DIR = "../data/rtl_inputs_A"
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       start,

    // ---- Final outputs ----
    output reg                        done,
    output reg  [3:0]                 predicted_class,

    // ---- feature_buffer interface (shared) ----
    output reg  [FADDR_W-1:0]         fbuf_read_addr,
    input  wire signed [DATA_W-1:0]   fbuf_read_data,
    output reg  [OADDR_W-1:0]         fbuf_write_addr,
    output reg  signed [DATA_W-1:0]   fbuf_write_data,
    output reg                        fbuf_write_en,
    output reg                        fbuf_swap,

    // ---- pcm_imc_unit interface (shared, v3) ----
    // K=25 parallel channels. enable_drift / drift_t removed in v3:
    // pcm_imc_unit reads them from its internal regfile (single
    // source of truth via host wr_en/wr_addr/wr_data bus).
    output reg                        imc_start,
    output reg  [2:0]                 imc_layer_id,
    output reg  [25*DATA_W-1:0]       imc_v_bus,
    output reg  [25*WADDR_W-1:0]      imc_addr_bus,
    input  wire signed [23:0]         imc_mac_result,
    input  wire                       imc_result_valid,

    // ---- bias storage interface (shared) ----
    output reg  [BADDR_W-1:0]         bias_addr,
    input  wire signed [ACC_W-1:0]    bias_in,

    // ---- logit register file interface (fc3 -> argmax) ----
    output reg  [3:0]                 logit_write_addr,
    output reg  signed [LOGIT_W-1:0]  logit_write_data,
    output reg                        logit_write_en,
    output reg  [3:0]                 logit_read_addr,
    input  wire signed [LOGIT_W-1:0]  logit_read_data
);

    // =========================================================
    // FSM states
    // =========================================================
    localparam S_IDLE    = 3'd0;
    localparam S_DECODE  = 3'd1;
    localparam S_LAUNCH  = 3'd2;
    localparam S_WAIT    = 3'd3;
    localparam S_SWAP    = 3'd4;
    localparam S_DONE    = 3'd5;

    reg [2:0] state, next_state;

    // =========================================================
    // Step counter (0..7)
    // =========================================================
    reg [3:0] step_id;

    // =========================================================
    // layer_desc_rom outputs
    // =========================================================
    wire [1:0]  layer_kind;
    wire [7:0]  cfg_in_h, cfg_in_w, cfg_in_ch;
    wire [7:0]  cfg_out_h, cfg_out_w, cfg_out_ch;
    wire [3:0]  cfg_kernel, cfg_padding;
    wire [15:0] cfg_in_dim, cfg_out_dim;
    wire [3:0]  cfg_rshift;
    wire        cfg_use_relu;
    wire [2:0]  cfg_weight_layer;
    wire        cfg_is_last_step;

    layer_desc_rom #(.DATA_DIR(DATA_DIR)) u_rom (
        .step_id(step_id),
        .layer_kind(layer_kind),
        .in_h(cfg_in_h), .in_w(cfg_in_w), .in_ch(cfg_in_ch),
        .out_h(cfg_out_h), .out_w(cfg_out_w), .out_ch(cfg_out_ch),
        .kernel(cfg_kernel), .padding(cfg_padding),
        .in_dim(cfg_in_dim), .out_dim(cfg_out_dim),
        .rshift(cfg_rshift),
        .use_relu(cfg_use_relu),
        .weight_layer(cfg_weight_layer),
        .is_last_step(cfg_is_last_step)
    );

    // Layer kind constants
    localparam [1:0] KIND_CONV   = 2'b00;
    localparam [1:0] KIND_POOL   = 2'b01;
    localparam [1:0] KIND_FC     = 2'b10;
    localparam [1:0] KIND_ARGMAX = 2'b11;

    // =========================================================
    // Engine start signals
    // =========================================================
    wire conv1_start  = (state == S_LAUNCH) && (layer_kind == KIND_CONV)
                                            && (step_id == 4'd0);
    wire conv2_start  = (state == S_LAUNCH) && (layer_kind == KIND_CONV)
                                            && (step_id == 4'd2);
    wire pool_start_w = (state == S_LAUNCH) && (layer_kind == KIND_POOL);
    wire fc1_start    = (state == S_LAUNCH) && (layer_kind == KIND_FC)
                                            && (step_id == 4'd4);
    wire fc2_start    = (state == S_LAUNCH) && (layer_kind == KIND_FC)
                                            && (step_id == 4'd5);
    wire fc3_start    = (state == S_LAUNCH) && (layer_kind == KIND_FC)
                                            && (step_id == 4'd6);
    wire argmax_start = (state == S_LAUNCH) && (layer_kind == KIND_ARGMAX);

    // =========================================================
    // CONV ENGINE INSTANCES (one per conv layer, v2 IMC interface)
    // =========================================================
    // ---- conv1: 28x28x1 -> 28x28x6, K=5, P=2 ----
    wire [25*DATA_W-1:0]  c1_imc_v_bus;
    wire [25*WADDR_W-1:0] c1_imc_addr_bus;
    wire                  c1_imc_start;
    wire [FADDR_W-1:0]    c1_f_addr;
    wire [BADDR_W-1:0]    c1_b_addr;
    wire [OADDR_W-1:0]    c1_o_addr;
    wire signed [DATA_W-1:0] c1_o_data;
    wire                  c1_o_en, c1_done, c1_to;

    conv_engine #(
        .IN_H(28), .IN_W(28), .IN_CH(1), .OUT_CH(6),
        .KERNEL(5), .PADDING(2), .OUT_H(28), .OUT_W(28),
        .RSHIFT(8), .DATA_W(DATA_W), .ACC_W(ACC_W),
        .WADDR_W(WADDR_W), .FADDR_W(FADDR_W),
        .OADDR_W(OADDR_W), .BADDR_W(BADDR_W)
    ) u_conv1 (
        .clk(clk), .rst_n(rst_n),
        .start(conv1_start), .layer_id(3'd0),
        .rshift_dyn({1'b1, cfg_rshift}),
        .imc_v_bus(c1_imc_v_bus), .imc_addr_bus(c1_imc_addr_bus),
        .imc_start(c1_imc_start),
        .imc_mac_result(imc_mac_result), .imc_result_valid(imc_result_valid),
        .fmap_addr(c1_f_addr), .fmap_in(fbuf_read_data),
        .bias_addr(c1_b_addr), .bias_in(bias_in),
        .out_addr(c1_o_addr), .out_data(c1_o_data), .out_en(c1_o_en),
        .done(c1_done), .mac_timeout(c1_to)
    );

    // ---- conv2: 14x14x6 -> 10x10x16, K=5, P=0 ----
    wire [25*DATA_W-1:0]  c2_imc_v_bus;
    wire [25*WADDR_W-1:0] c2_imc_addr_bus;
    wire                  c2_imc_start;
    wire [FADDR_W-1:0]    c2_f_addr;
    wire [BADDR_W-1:0]    c2_b_addr;
    wire [OADDR_W-1:0]    c2_o_addr;
    wire signed [DATA_W-1:0] c2_o_data;
    wire                  c2_o_en, c2_done, c2_to;

    conv_engine #(
        .IN_H(14), .IN_W(14), .IN_CH(6), .OUT_CH(16),
        .KERNEL(5), .PADDING(0), .OUT_H(10), .OUT_W(10),
        .RSHIFT(8), .DATA_W(DATA_W), .ACC_W(ACC_W),
        .WADDR_W(WADDR_W), .FADDR_W(FADDR_W),
        .OADDR_W(OADDR_W), .BADDR_W(BADDR_W)
    ) u_conv2 (
        .clk(clk), .rst_n(rst_n),
        .start(conv2_start), .layer_id(3'd1),
        .rshift_dyn({1'b1, cfg_rshift}),
        .imc_v_bus(c2_imc_v_bus), .imc_addr_bus(c2_imc_addr_bus),
        .imc_start(c2_imc_start),
        .imc_mac_result(imc_mac_result), .imc_result_valid(imc_result_valid),
        .fmap_addr(c2_f_addr), .fmap_in(fbuf_read_data),
        .bias_addr(c2_b_addr), .bias_in(bias_in),
        .out_addr(c2_o_addr), .out_data(c2_o_data), .out_en(c2_o_en),
        .done(c2_done), .mac_timeout(c2_to)
    );

    // =========================================================
    // POOL WRAPPER INSTANCES (one per pool layer)
    // =========================================================
    // We need different shapes for pool1 (28->14x6) and pool2 (10->5x16).

    // ---- pool1: 28x28x6 -> 14x14x6 ----
    wire [FADDR_W-1:0] p1_f_addr;
    wire [OADDR_W-1:0] p1_o_addr;
    wire signed [DATA_W-1:0] p1_o_data;
    wire p1_o_en, p1_done;
    wire pool1_start = pool_start_w && (step_id == 4'd1);

    pool_wrapper #(
        .IN_H(28), .IN_W(28), .IN_CH(6),
        .OUT_H(14), .OUT_W(14),
        .DATA_W(DATA_W), .FADDR_W(FADDR_W), .OADDR_W(OADDR_W)
    ) u_pool1 (
        .clk(clk), .rst_n(rst_n), .start(pool1_start),
        .fmap_addr(p1_f_addr), .fmap_in(fbuf_read_data),
        .out_addr(p1_o_addr), .out_data(p1_o_data), .out_en(p1_o_en),
        .done(p1_done)
    );

    // ---- pool2: 10x10x16 -> 5x5x16 ----
    wire [FADDR_W-1:0] p2_f_addr;
    wire [OADDR_W-1:0] p2_o_addr;
    wire signed [DATA_W-1:0] p2_o_data;
    wire p2_o_en, p2_done;
    wire pool2_start = pool_start_w && (step_id == 4'd3);

    pool_wrapper #(
        .IN_H(10), .IN_W(10), .IN_CH(16),
        .OUT_H(5), .OUT_W(5),
        .DATA_W(DATA_W), .FADDR_W(FADDR_W), .OADDR_W(OADDR_W)
    ) u_pool2 (
        .clk(clk), .rst_n(rst_n), .start(pool2_start),
        .fmap_addr(p2_f_addr), .fmap_in(fbuf_read_data),
        .out_addr(p2_o_addr), .out_data(p2_o_data), .out_en(p2_o_en),
        .done(p2_done)
    );

    // =========================================================
    // FC ENGINE INSTANCES (three: fc1, fc2, fc3)
    // =========================================================
    // Note OUT_W differs: fc1/fc2 are 8-bit (post-ReLU INT8),
    // fc3 is 16-bit (raw logits).

    // ---- fc1: 400 -> 120, ReLU, 8-bit out ----
    wire [25*DATA_W-1:0]  f1_imc_v_bus;
    wire [25*WADDR_W-1:0] f1_imc_addr_bus;
    wire                  f1_imc_start;
    wire [FADDR_W-1:0]    f1_f_addr;
    wire [BADDR_W-1:0]    f1_b_addr;
    wire [OADDR_W-1:0]    f1_o_addr;
    wire signed [DATA_W-1:0] f1_o_data;
    wire                  f1_o_en, f1_done, f1_to;

    fc_engine #(
        .IN_DIM(400), .OUT_DIM(120),
        .USE_RELU(1), .RSHIFT(8),
        .DATA_W(DATA_W), .OUT_W(DATA_W),
        .ACC_W(ACC_W), .WADDR_W(WADDR_W),
        .FADDR_W(FADDR_W), .OADDR_W(OADDR_W), .BADDR_W(BADDR_W),
        .MAX_IN_DIM(400)
    ) u_fc1 (
        .clk(clk), .rst_n(rst_n),
        .start(fc1_start), .layer_id(3'd2),
        .rshift_dyn({1'b1, cfg_rshift}),
        .imc_v_bus(f1_imc_v_bus), .imc_addr_bus(f1_imc_addr_bus),
        .imc_start(f1_imc_start),
        .imc_mac_result(imc_mac_result), .imc_result_valid(imc_result_valid),
        .fmap_addr(f1_f_addr), .fmap_in(fbuf_read_data),
        .bias_addr(f1_b_addr), .bias_in(bias_in),
        .out_addr(f1_o_addr), .out_data(f1_o_data), .out_en(f1_o_en),
        .done(f1_done), .mac_timeout(f1_to)
    );

    // ---- fc2: 120 -> 84, ReLU, 8-bit out ----
    wire [25*DATA_W-1:0]  f2_imc_v_bus;
    wire [25*WADDR_W-1:0] f2_imc_addr_bus;
    wire                  f2_imc_start;
    wire [FADDR_W-1:0]    f2_f_addr;
    wire [BADDR_W-1:0]    f2_b_addr;
    wire [OADDR_W-1:0]    f2_o_addr;
    wire signed [DATA_W-1:0] f2_o_data;
    wire                  f2_o_en, f2_done, f2_to;

    fc_engine #(
        .IN_DIM(120), .OUT_DIM(84),
        .USE_RELU(1), .RSHIFT(8),
        .DATA_W(DATA_W), .OUT_W(DATA_W),
        .ACC_W(ACC_W), .WADDR_W(WADDR_W),
        .FADDR_W(FADDR_W), .OADDR_W(OADDR_W), .BADDR_W(BADDR_W),
        .MAX_IN_DIM(400)
    ) u_fc2 (
        .clk(clk), .rst_n(rst_n),
        .start(fc2_start), .layer_id(3'd3),
        .rshift_dyn({1'b1, cfg_rshift}),
        .imc_v_bus(f2_imc_v_bus), .imc_addr_bus(f2_imc_addr_bus),
        .imc_start(f2_imc_start),
        .imc_mac_result(imc_mac_result), .imc_result_valid(imc_result_valid),
        .fmap_addr(f2_f_addr), .fmap_in(fbuf_read_data),
        .bias_addr(f2_b_addr), .bias_in(bias_in),
        .out_addr(f2_o_addr), .out_data(f2_o_data), .out_en(f2_o_en),
        .done(f2_done), .mac_timeout(f2_to)
    );

    // ---- fc3: 84 -> 10, NO ReLU, 16-bit out (logits) ----
    wire [25*DATA_W-1:0]  f3_imc_v_bus;
    wire [25*WADDR_W-1:0] f3_imc_addr_bus;
    wire                  f3_imc_start;
    wire [FADDR_W-1:0]    f3_f_addr;
    wire [BADDR_W-1:0]    f3_b_addr;
    wire [OADDR_W-1:0]    f3_o_addr;
    wire signed [LOGIT_W-1:0] f3_o_data;
    wire                  f3_o_en, f3_done, f3_to;

    fc_engine #(
        .IN_DIM(84), .OUT_DIM(10),
        .USE_RELU(0), .RSHIFT(8),
        .DATA_W(DATA_W), .OUT_W(LOGIT_W),
        .ACC_W(ACC_W), .WADDR_W(WADDR_W),
        .FADDR_W(FADDR_W), .OADDR_W(OADDR_W), .BADDR_W(BADDR_W),
        .MAX_IN_DIM(400)
    ) u_fc3 (
        .clk(clk), .rst_n(rst_n),
        .start(fc3_start), .layer_id(3'd4),
        .rshift_dyn({1'b1, cfg_rshift}),
        .imc_v_bus(f3_imc_v_bus), .imc_addr_bus(f3_imc_addr_bus),
        .imc_start(f3_imc_start),
        .imc_mac_result(imc_mac_result), .imc_result_valid(imc_result_valid),
        .fmap_addr(f3_f_addr), .fmap_in(fbuf_read_data),
        .bias_addr(f3_b_addr), .bias_in(bias_in),
        .out_addr(f3_o_addr), .out_data(f3_o_data), .out_en(f3_o_en),
        .done(f3_done), .mac_timeout(f3_to)
    );

    // =========================================================
    // ARGMAX WRAPPER (single instance, always reads logit RF)
    // =========================================================
    wire [3:0] am_logit_addr;
    wire [3:0] am_class_out;
    wire am_done;

    argmax_wrapper #(.LOGIT_W(LOGIT_W)) u_argmax (
        .clk(clk), .rst_n(rst_n),
        .start(argmax_start),
        .logit_addr(am_logit_addr),
        .logit_in(logit_read_data),
        .class_out(am_class_out),
        .done(am_done)
    );

    // =========================================================
    // Active engine done aggregation
    // =========================================================
    reg current_done;
    always @(*) begin
        case (layer_kind)
            KIND_CONV:   current_done = (step_id == 4'd0) ? c1_done : c2_done;
            KIND_POOL:   current_done = (step_id == 4'd1) ? p1_done : p2_done;
            KIND_FC: begin
                case (step_id)
                    4'd4:    current_done = f1_done;
                    4'd5:    current_done = f2_done;
                    4'd6:    current_done = f3_done;
                    default: current_done = 1'b0;
                endcase
            end
            KIND_ARGMAX: current_done = am_done;
            default:     current_done = 1'b0;
        endcase
    end

    // =========================================================
    // Mux: drive shared external interfaces from active engine
    // (v2: weight_memory replaced by pcm_imc_unit)
    // =========================================================
    always @(*) begin
        // Defaults (safe zero -- nothing happens)
        fbuf_read_addr   = 0;
        fbuf_write_addr  = 0;
        fbuf_write_data  = 0;
        fbuf_write_en    = 1'b0;
        bias_addr        = 0;
        logit_write_addr = 4'd0;
        logit_write_data = 0;
        logit_write_en   = 1'b0;
        logit_read_addr  = am_logit_addr;   // argmax always wired to RF read

        // IMC defaults
        imc_v_bus        = {(25*DATA_W){1'b0}};
        imc_addr_bus     = {(25*WADDR_W){1'b0}};
        imc_start        = 1'b0;
        imc_layer_id     = 3'd0;

        case (layer_kind)
            KIND_CONV: begin
                if (step_id == 4'd0) begin
                    fbuf_read_addr   = c1_f_addr;
                    fbuf_write_addr  = c1_o_addr;
                    fbuf_write_data  = c1_o_data;
                    fbuf_write_en    = c1_o_en;
                    bias_addr        = c1_b_addr;
                    imc_v_bus        = c1_imc_v_bus;
                    imc_addr_bus     = c1_imc_addr_bus;
                    imc_start        = c1_imc_start;
                    imc_layer_id     = 3'd0;
                end else begin   // step_id == 2 (conv2)
                    fbuf_read_addr   = c2_f_addr;
                    fbuf_write_addr  = c2_o_addr;
                    fbuf_write_data  = c2_o_data;
                    fbuf_write_en    = c2_o_en;
                    bias_addr        = c2_b_addr;
                    imc_v_bus        = c2_imc_v_bus;
                    imc_addr_bus     = c2_imc_addr_bus;
                    imc_start        = c2_imc_start;
                    imc_layer_id     = 3'd1;
                end
            end
            KIND_POOL: begin
                if (step_id == 4'd1) begin
                    fbuf_read_addr  = p1_f_addr;
                    fbuf_write_addr = p1_o_addr;
                    fbuf_write_data = p1_o_data;
                    fbuf_write_en   = p1_o_en;
                end else begin   // step_id == 3 (pool2)
                    fbuf_read_addr  = p2_f_addr;
                    fbuf_write_addr = p2_o_addr;
                    fbuf_write_data = p2_o_data;
                    fbuf_write_en   = p2_o_en;
                end
            end
            KIND_FC: begin
                case (step_id)
                    4'd4: begin   // fc1
                        fbuf_read_addr   = f1_f_addr;
                        fbuf_write_addr  = f1_o_addr;
                        fbuf_write_data  = f1_o_data;
                        fbuf_write_en    = f1_o_en;
                        bias_addr        = f1_b_addr;
                        imc_v_bus        = f1_imc_v_bus;
                        imc_addr_bus     = f1_imc_addr_bus;
                        imc_start        = f1_imc_start;
                        imc_layer_id     = 3'd2;
                    end
                    4'd5: begin   // fc2
                        fbuf_read_addr   = f2_f_addr;
                        fbuf_write_addr  = f2_o_addr;
                        fbuf_write_data  = f2_o_data;
                        fbuf_write_en    = f2_o_en;
                        bias_addr        = f2_b_addr;
                        imc_v_bus        = f2_imc_v_bus;
                        imc_addr_bus     = f2_imc_addr_bus;
                        imc_start        = f2_imc_start;
                        imc_layer_id     = 3'd3;
                    end
                    4'd6: begin   // fc3 -- writes go to LOGIT REG FILE
                        fbuf_read_addr   = f3_f_addr;
                        // fbuf_write_*   stay 0 (no fbuf write)
                        bias_addr        = f3_b_addr;
                        imc_v_bus        = f3_imc_v_bus;
                        imc_addr_bus     = f3_imc_addr_bus;
                        imc_start        = f3_imc_start;
                        imc_layer_id     = 3'd4;
                        // Route fc3 output to logit RF
                        logit_write_addr = f3_o_addr[3:0];
                        logit_write_data = f3_o_data;
                        logit_write_en   = f3_o_en;
                    end
                    default: ;  // unused FC step ids
                endcase
            end
            KIND_ARGMAX: begin
                logit_read_addr = am_logit_addr;
                // No fbuf or imc activity during argmax
            end
            default: ;
        endcase
    end

    // =========================================================
    // FSM next-state logic
    // =========================================================
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:    if (start) next_state = S_DECODE;
            S_DECODE:             next_state = S_LAUNCH;
            S_LAUNCH:             next_state = S_WAIT;
            S_WAIT:    if (current_done) next_state = S_SWAP;
            S_SWAP: begin
                if (cfg_is_last_step) next_state = S_DONE;
                else                  next_state = S_DECODE;
            end
            S_DONE: next_state = S_IDLE;
            default: next_state = S_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    // =========================================================
    // step_id update (advance in S_SWAP if not last)
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            step_id <= 0;
        end else begin
            if (state == S_IDLE && start) begin
                step_id <= 0;
            end else if (state == S_SWAP && !cfg_is_last_step) begin
                step_id <= step_id + 1;
            end
        end
    end

    // =========================================================
    // fbuf swap pulse: assert during S_SWAP for one cycle
    //   EXCEPT after fc3 (step_id==6) -- fc3 didn't write to
    //   fbuf so no swap is needed.
    //   ALSO no swap after argmax (step_id==7), but we also
    //   exit to S_DONE right away so it doesn't matter.
    //
    // ALSO: swap once when leaving S_IDLE (start pulse). The TB
    // loads the image into the "write side" (mem_A when role_sel=0).
    // Conv1 then needs to READ that side, which means role_sel must
    // flip to 1 so mem_A becomes the read side.
    // =========================================================
    always @(*) begin
        if (state == S_IDLE && start) begin
            fbuf_swap = 1'b1;   // initial swap to make image-side readable
        end else if (state == S_SWAP && step_id != 4'd6 && step_id != 4'd7) begin
            fbuf_swap = 1'b1;
        end else begin
            fbuf_swap = 1'b0;
        end
    end

    // =========================================================
    // Output: done pulse and predicted_class
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done            <= 1'b0;
            predicted_class <= 0;
        end else begin
            if (state == S_DONE) begin
                done            <= 1'b1;
                predicted_class <= am_class_out;
            end else begin
                done <= 1'b0;
            end
        end
    end

endmodule
