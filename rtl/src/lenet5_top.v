// ============================================================
// lenet5_top.v
// ------------------------------------------------------------
// Top-level integration of the LeNet-5 inference accelerator.
//
// Wires together:
//   - top_fsm           : sequencing FSM and per-layer engines
//   - feature_buffer    : ping-pong activation SRAM
//   - weight_memory     : layer-aware DRAM/PCM hybrid (Paper 1 novelty)
//   - bias_storage      : per-layer per-channel bias ROM
//   - logit_rf          : 10x16-bit register file for fc3 -> argmax
//
// External interface:
//   inputs:
//     clk, rst_n
//     start                                : pulse to begin inference
//     image_we, image_addr, image_data     : preload 28x28 input image
//   outputs:
//     done                                 : pulse when inference complete
//     predicted_class [3:0]                : 0..9 classification result
//
// Image loading protocol:
//   Before pulsing `start`, the testbench writes the 784 input
//   pixels (28x28x1) into the feature buffer's A side. We expose
//   a dedicated image-load port that drives feature_buffer's
//   write port when image_we is asserted, otherwise the FSM has
//   write access. (Simple mux, see below.)
//
// Note on weights/biases:
//   weight_memory and bias_storage currently hold synthetic
//   patterns. End-to-end numerical accuracy versus PyTorch
//   requires Python Step 2 (real INT8-calibrated weights) loaded
//   via $readmemh. Until then, this top module is verified for
//   "structurally correct end-to-end inference" only -- it
//   produces a deterministic predicted_class but not necessarily
//   the same one PyTorch would produce on real weights.
// ============================================================

`timescale 1ns / 1ps

module lenet5_top #(
    parameter integer DATA_W   = 8,
    parameter integer LOGIT_W  = 16,
    parameter integer ACC_W    = 32,
    parameter integer FADDR_W  = 13,
    parameter integer OADDR_W  = 13,
    parameter integer WADDR_W  = 16,
    parameter integer BADDR_W  = 8,
    // DATA_DIR is forwarded to all submodules that load hex files
    // (pcm_imc_unit, bias_storage, layer_desc_rom). Pass via -P or
    // override at instantiation to switch Model A / B at simulation
    // time. v3: Model A/B differ ONLY through the hex files; there
    // are no longer per-model RTL parameters (per-layer partition
    // sizes now live in layer_config.hex inside DATA_DIR).
    parameter         DATA_DIR   = "../data/rtl_inputs_A_v3",
    parameter         COMMON_DIR = "../data/rtl_inputs_common"
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // ---- Inference control ----
    input  wire                       start,
    output wire                       done,
    output wire [3:0]                 predicted_class,

    // ---- Image loading port (testbench-facing) ----
    input  wire                       image_we,
    input  wire [FADDR_W-1:0]         image_addr,
    input  wire signed [DATA_W-1:0]   image_data,

    // ---- Host CPU boot config (v3 ABI to pcm_imc_unit regfile) ----
    // Boot protocol (MUST follow before pulsing `start`):
    //   1. Write 0x00..0x09 layer_config (10 words)
    //   2. (optional) Write 0x21 = drift_t
    //   3. Write 0x20 = bit1 (commit) | bit0 (enable_drift)
    //   4. NOW pulse `start`
    // If `start` is pulsed before commit, pcm_imc_unit gates it
    // internally (cfg_valid=0) and top_fsm will hang awaiting
    // imc_result_valid. This is by-design, not a bug.
    input  wire                       cfg_wr_en,
    input  wire [5:0]                 cfg_wr_addr,
    input  wire [31:0]                cfg_wr_data
);

    // =========================================================
    // Wires between top_fsm and external memories
    // =========================================================

    // feature_buffer interface
    wire [FADDR_W-1:0]         fbuf_read_addr;
    wire signed [DATA_W-1:0]   fbuf_read_data;
    wire [OADDR_W-1:0]         fbuf_write_addr_fsm;
    wire signed [DATA_W-1:0]   fbuf_write_data_fsm;
    wire                       fbuf_write_en_fsm;
    wire                       fbuf_swap;

    // Muxed write port (image_we from TB takes priority during loading)
    wire [OADDR_W-1:0]         fbuf_write_addr;
    wire signed [DATA_W-1:0]   fbuf_write_data;
    wire                       fbuf_write_en;

    assign fbuf_write_addr  = image_we ? image_addr : fbuf_write_addr_fsm;
    assign fbuf_write_data  = image_we ? image_data : fbuf_write_data_fsm;
    assign fbuf_write_en    = image_we | fbuf_write_en_fsm;

    // pcm_imc_unit interface (v3 — no enable_drift/drift_t)
    wire                       imc_start;
    wire [2:0]                 imc_layer_id;
    wire [25*DATA_W-1:0]       imc_v_bus;
    wire [25*WADDR_W-1:0]      imc_addr_bus;
    wire signed [23:0]         imc_mac_result;
    wire                       imc_result_valid;

    // bias_storage interface
    wire [BADDR_W-1:0]         bias_addr;
    wire signed [ACC_W-1:0]    bias_in;

    // logit_rf interface
    wire [3:0]                 logit_write_addr;
    wire signed [LOGIT_W-1:0]  logit_write_data;
    wire                       logit_write_en;
    wire [3:0]                 logit_read_addr;
    wire signed [LOGIT_W-1:0]  logit_read_data;

    // =========================================================
    // top_fsm
    // =========================================================
    top_fsm #(
        .DATA_W(DATA_W), .LOGIT_W(LOGIT_W), .ACC_W(ACC_W),
        .FADDR_W(FADDR_W), .OADDR_W(OADDR_W),
        .WADDR_W(WADDR_W), .BADDR_W(BADDR_W),
        .DATA_DIR(DATA_DIR)
    ) u_fsm (
        .clk(clk), .rst_n(rst_n), .start(start),
        .done(done), .predicted_class(predicted_class),

        .fbuf_read_addr(fbuf_read_addr),
        .fbuf_read_data(fbuf_read_data),
        .fbuf_write_addr(fbuf_write_addr_fsm),
        .fbuf_write_data(fbuf_write_data_fsm),
        .fbuf_write_en(fbuf_write_en_fsm),
        .fbuf_swap(fbuf_swap),

        // v3: regfile is now sole config source; cfg signals removed
        .imc_start(imc_start),
        .imc_layer_id(imc_layer_id),
        .imc_v_bus(imc_v_bus),
        .imc_addr_bus(imc_addr_bus),
        .imc_mac_result(imc_mac_result),
        .imc_result_valid(imc_result_valid),

        .bias_addr(bias_addr),
        .bias_in(bias_in),

        .logit_write_addr(logit_write_addr),
        .logit_write_data(logit_write_data),
        .logit_write_en(logit_write_en),
        .logit_read_addr(logit_read_addr),
        .logit_read_data(logit_read_data)
    );

    // =========================================================
    // feature_buffer (ping-pong)
    //   During image loading, TB drives writes via image_we mux.
    //   During inference, top_fsm drives writes and reads.
    //   swap is driven by top_fsm only.
    // =========================================================
    feature_buffer #(
        .DATA_WIDTH(DATA_W), .DEPTH(4704), .ADDR_WIDTH(FADDR_W)
    ) u_fbuf (
        .clk(clk), .rst_n(rst_n),
        .write_addr(fbuf_write_addr),
        .write_data(fbuf_write_data),
        .write_en(fbuf_write_en),
        .read_addr(fbuf_read_addr),
        .read_data(fbuf_read_data),
        .swap(fbuf_swap),
        .which_is_write()    // unused observability signal
    );

    // =========================================================
    // pcm_imc_unit (v3 — X' refactor)
    //   - K=25 parallel channels
    //   - Internal layer_config_regfile (host CPU writes via
    //     cfg_wr_en/cfg_wr_addr/cfg_wr_data → 0x00..0x09, 0x20, 0x21)
    //   - start gated internally by cfg_valid (single source of truth)
    //   - No per-model RTL parameters; partitions live in
    //     data/rtl_inputs_*_v3/layer_config.hex
    // =========================================================
    pcm_imc_unit #(
        .K(25),
        .DATA_WIDTH(DATA_W),
        .ADDR_WIDTH(WADDR_W),
        .ACC_WIDTH(24),
        .SRAM_TOTAL(3074),
        .PCM_TOTAL(58396),
        .PCM_LATENCY(8),
        .SRAM_LATENCY(2),
        .DATA_DIR(DATA_DIR),
        .COMMON_DIR(COMMON_DIR)
    ) u_imc (
        .clk(clk), .rst_n(rst_n),
        .start(imc_start),
        .wr_en(cfg_wr_en),
        .wr_addr(cfg_wr_addr),
        .wr_data(cfg_wr_data),
        .layer_id(imc_layer_id),
        .v_bus(imc_v_bus),
        .orig_addr_bus(imc_addr_bus),
        .mac_result(imc_mac_result),
        .result_valid(imc_result_valid),
        // debug observability (unused at this level)
        .cfg_valid_dbg(),
        .enable_drift_dbg(),
        .drift_t_dbg(),
        .sram_hit_dbg(),
        .pcm_hit_dbg(),
        .sram_oor_dbg(),
        .pcm_oor_dbg()
    );

    // =========================================================
    // bias_storage
    // =========================================================
    bias_storage #(
        .NUM_LAYERS(5), .ACC_W(ACC_W), .BADDR_W(BADDR_W),
        .DATA_DIR(DATA_DIR)
    ) u_bias (
        .layer_id(imc_layer_id),    // SAME layer_id as IMC weights
        .channel(bias_addr),
        .bias_out(bias_in)
    );

    // =========================================================
    // logit_rf  (between fc3 and argmax_wrapper)
    // =========================================================
    logit_rf #(
        .LOGIT_W(LOGIT_W), .NUM(10)
    ) u_logit_rf (
        .clk(clk), .rst_n(rst_n),
        .write_addr(logit_write_addr),
        .write_data(logit_write_data),
        .write_en(logit_write_en),
        .read_addr(logit_read_addr),
        .read_data(logit_read_data)
    );

endmodule
