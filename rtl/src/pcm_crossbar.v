//============================================================
// pcm_crossbar.v  (v3 — X' refactor)
// Paper 2 v3 — Behavioural PCM crossbar with pool-addressed storage
//============================================================
// Compared to v2, this module no longer carries any model-
// dependent address-translation logic:
//
//   - Removed: layer_id input
//   - Removed: addr_bus (original weight addresses)
//   - Removed: per-layer p_conv2/p_fc1/p_fc2/p_fc3 arrays
//   - Removed: per-layer nu_conv2/.../nu_fc3 arrays
//   - Removed: per-layer addr_to_slot maps (now owned by
//              pcm_addr_decoder.v)
//   - Removed: per-layer PCM-partition / addr-width / capacity
//              parameters and constants (now sourced from regfile)
//
//   - Added:   pcm_pool_addr_bus[K] (pool-indexed PCM addrs)
//   - Added:   pcm_hit_bus[K]       (per-lane valid flag)
//
//   - Unchanged (v2 behaviour to preserve):
//       * K = 25 parallel channels
//       * INT8 weights & activations
//       * log2_lut (1024-entry Q4.8) and exp2_lut (1024-entry Q1.7)
//       * Per-cell drift coefficient: nu (Q0.8) × log2(t) -> exp2
//       * Drift application: w' = (w * coef) >>> 7  with saturation
//       * 8-cycle MAC latency from `start` to `result_valid`
//       * mac_result is signed ACC_WIDTH = 24-bit accumulator
//
// Synthesis note: this is a behavioural model of an analog PCM
// crossbar (storage + drift + MAC pipeline). For synthesis it
// can be replaced by a black-box PCM macro stub with the same
// interface (pcm_crossbar_stub.v in a later step). The
// pcm_addr_decoder and other digital control logic OUTSIDE
// this module remain synthesizable and are accounted for in
// the digital synthesis report. Anything inside this module
// is part of the analog macro boundary.
//
// SRAM/PCM mutual exclusion:
//   For each (layer_id, orig_addr) seen by the system, exactly
//   one of sram_hit and pcm_hit is 1 in the same cycle (by
//   construction in the data generation). This module does not
//   enforce that invariant — it just trusts pcm_hit_bus and
//   ignores pcm_hit=0 lanes (their contribution to the MAC is 0).
//============================================================

`timescale 1ns/1ps

module pcm_crossbar #(
    parameter integer K                   = 25,        // window width (5x5)
    parameter integer DATA_WIDTH          = 8,         // INT8 weights/activations
    parameter integer ADDR_WIDTH          = 16,        // pool address width
    parameter integer ACC_WIDTH           = 24,        // sum of 25 INT16 products
    parameter integer PCM_TOTAL           = 58396,     // pool depth
    parameter integer MULTI_CYCLE_LATENCY = 8,         // PCM read + ADC delay (v2 value)
    parameter integer DRIFT_SHIFT         = 7,         // for Q1.7 coef
    parameter         DATA_DIR            = "",
    parameter         COMMON_DIR          = "../data/rtl_inputs_common"
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          start,

    input  wire [K*DATA_WIDTH-1:0]       v_bus,             // 25 INT8 activations
    input  wire [K*ADDR_WIDTH-1:0]       pcm_pool_addr_bus, // 25 pool addrs (from decoder)
    input  wire [K-1:0]                  pcm_hit_bus,       // 25 hit flags  (from decoder)

    input  wire                          enable_drift,
    input  wire [15:0]                   drift_t,           // time in seconds

    output reg  signed [ACC_WIDTH-1:0]   mac_result,
    output reg                           result_valid
);

    //--------------------------------------------------------
    // Storage — unified pool (v3)
    //--------------------------------------------------------
    reg signed [DATA_WIDTH-1:0] pcm_pool    [0:PCM_TOTAL-1];
    reg        [7:0]            nu_pcm_pool [0:PCM_TOTAL-1];

    //--------------------------------------------------------
    // Drift LUTs (model-invariant, shared across A and B)
    //--------------------------------------------------------
    reg [11:0] log2_lut [0:1023];
    reg [7:0]  exp2_lut [0:1023];

    integer A;
    initial begin
        for (A = 0; A < PCM_TOTAL; A = A + 1) begin
            pcm_pool[A]    = {DATA_WIDTH{1'b0}};
            nu_pcm_pool[A] = 8'h00;
        end
        for (A = 0; A < 1024; A = A + 1) begin
            log2_lut[A] = 12'd0;
            exp2_lut[A] = 8'd0;
        end

        // Always load drift LUTs (model-invariant). Guarded on
        // non-empty path so simulation testbenches that override
        // these via hierarchical $readmemh don't trigger an
        // "invalid string" warning when DUT's COMMON_DIR="".
        if (COMMON_DIR != "") begin
            $readmemh({COMMON_DIR, "/log2_lut.hex"}, log2_lut);
            $readmemh({COMMON_DIR, "/exp2_lut.hex"}, exp2_lut);
        end

        // Load pool data when DATA_DIR is set (model-dependent)
        if (DATA_DIR != "") begin
            $readmemh({DATA_DIR, "/pcm_pool.hex"},     pcm_pool);
            $readmemh({DATA_DIR, "/nu_pcm_pool.hex"},  nu_pcm_pool);
        end
    end

    //--------------------------------------------------------
    // Unpack buses
    //--------------------------------------------------------
    wire signed [DATA_WIDTH-1:0] v_in       [0:K-1];
    wire        [ADDR_WIDTH-1:0] pool_addr  [0:K-1];
    wire                         lane_hit   [0:K-1];
    wire                         lane_valid [0:K-1];  // hit AND in_range
    wire signed [DATA_WIDTH-1:0] w_pcm      [0:K-1];
    wire        [7:0]            nu_pcm     [0:K-1];
    wire signed [DATA_WIDTH-1:0] w_drifted  [0:K-1];

    genvar gi;
    generate
        for (gi = 0; gi < K; gi = gi + 1) begin: unpack
            assign v_in[gi]      = v_bus[gi*DATA_WIDTH +: DATA_WIDTH];
            assign pool_addr[gi] = pcm_pool_addr_bus[gi*ADDR_WIDTH +: ADDR_WIDTH];
            assign lane_hit[gi]  = pcm_hit_bus[gi];
            assign lane_valid[gi] = lane_hit[gi] &&
                                    (pool_addr[gi] < PCM_TOTAL[ADDR_WIDTH-1:0]);
        end
    endgenerate

    //--------------------------------------------------------
    // log2(drift_t) using log2_lut + shift compensation
    // (Unchanged from v2.)
    //--------------------------------------------------------
    wire [3:0] log_shift =
        (drift_t < 16'd1024)  ? 4'd0 :
        (drift_t < 16'd2048)  ? 4'd1 :
        (drift_t < 16'd4096)  ? 4'd2 :
        (drift_t < 16'd8192)  ? 4'd3 :
        (drift_t < 16'd16384) ? 4'd4 :
        (drift_t < 16'd32768) ? 4'd5 : 4'd6;

    wire [9:0]  log_idx       = drift_t >> log_shift;
    wire [11:0] log2_lut_val  = log2_lut[log_idx];
    wire [11:0] log2_t_q8     = log2_lut_val + ({4'b0, log_shift, 8'b0});

    //--------------------------------------------------------
    // Per-channel: read pool & nu, compute drifted weight
    //--------------------------------------------------------
    // Defense-in-depth: pcm_addr_decoder is supposed to keep
    // pool_addr < PCM_TOTAL on its hit path, but this module
    // independently guards via `lane_valid` (defined in the
    // unpack section). Mirrors the addr_in_range pattern in
    // sram_pool.v. The combined gate is used for both pool
    // reads and the MAC contribution.
    generate
        for (gi = 0; gi < K; gi = gi + 1) begin: lookup_ch
            // Safe address: 0 when not valid (keeps pool read
            // within bounds; output gated to 0 below regardless).
            wire [ADDR_WIDTH-1:0] safe_addr =
                lane_valid[gi] ? pool_addr[gi] : {ADDR_WIDTH{1'b0}};

            wire signed [DATA_WIDTH-1:0] w_raw  = pcm_pool[safe_addr];
            wire        [7:0]            nu_raw = nu_pcm_pool[safe_addr];

            // Gate by lane_valid so invalid lanes contribute 0
            assign w_pcm[gi]  = lane_valid[gi] ? w_raw  : {DATA_WIDTH{1'b0}};
            assign nu_pcm[gi] = lane_valid[gi] ? nu_raw : 8'h00;

            // Drift coefficient (unchanged from v2):
            //   nu (Q0.8) × log2_t (Q4.8) -> Q4.16 product (20-bit)
            //   To get exp2_lut Q2.8 input, shift right by 8.
            //   For exponents >= 1024 (Q2.8), saturate to 1023.
            wire [19:0] product_q16 = nu_pcm[gi] * log2_t_q8;
            wire [11:0] expo_q8     = product_q16[19:8];
            wire [9:0]  expo_idx    = (expo_q8 > 12'd1023) ? 10'd1023
                                                           : expo_q8[9:0];
            wire [7:0]  coef        = exp2_lut[expo_idx];

            // drifted_w = (w * coef) >>> DRIFT_SHIFT  with saturation
            wire signed [16:0] mul_full      = $signed(w_pcm[gi]) *
                                               $signed({1'b0, coef});
            wire signed [16:0] mul_shifted_f = mul_full >>> DRIFT_SHIFT;
            wire signed [DATA_WIDTH-1:0] mul_shifted =
                (mul_shifted_f >  17'sd127) ?  8'sd127 :
                (mul_shifted_f < -17'sd128) ? -8'sd128 :
                mul_shifted_f[DATA_WIDTH-1:0];

            // Apply drift only when (enable_drift && lane_valid);
            // otherwise pass through w_pcm (which is 0 if invalid).
            assign w_drifted[gi] = (enable_drift && lane_valid[gi]) ?
                                    mul_shifted : w_pcm[gi];
        end
    endgenerate

    //--------------------------------------------------------
    // K-way MAC: only sum channels where lane_valid=1
    //--------------------------------------------------------
    integer ki;
    reg signed [ACC_WIDTH-1:0] mac_sum_comb;
    always @(*) begin
        mac_sum_comb = {ACC_WIDTH{1'b0}};
        for (ki = 0; ki < K; ki = ki + 1) begin
            if (lane_valid[ki]) begin
                mac_sum_comb = mac_sum_comb +
                               $signed(v_in[ki]) * $signed(w_drifted[ki]);
            end
        end
    end

    //--------------------------------------------------------
    // Multi-cycle latency pipeline (unchanged from v2)
    //--------------------------------------------------------
    reg [7:0]                  cycle_cnt;
    reg signed [ACC_WIDTH-1:0] sum_pending;
    reg                        busy;

    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_cnt    <= 8'd0;
            sum_pending  <= {ACC_WIDTH{1'b0}};
            busy         <= 1'b0;
            mac_result   <= {ACC_WIDTH{1'b0}};
            result_valid <= 1'b0;
        end else begin
            result_valid <= 1'b0;
            if (start && !busy) begin
                sum_pending <= mac_sum_comb;
                cycle_cnt   <= 8'd1;
                busy        <= 1'b1;
            end else if (busy) begin
                if (cycle_cnt == MULTI_CYCLE_LATENCY[7:0]) begin
                    mac_result   <= sum_pending;
                    result_valid <= 1'b1;
                    cycle_cnt    <= 8'd0;
                    busy         <= 1'b0;
                end else begin
                    cycle_cnt <= cycle_cnt + 8'd1;
                end
            end
        end
    end

endmodule
