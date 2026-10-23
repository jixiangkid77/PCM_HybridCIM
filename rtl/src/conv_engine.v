// ============================================================
// conv_engine.v   (Paper 2 v2 — IMC architecture, Style A)
// ------------------------------------------------------------
// Convolution engine for LeNet-5 conv1/conv2 layers, redesigned
// to use pcm_imc_unit instead of the v1 weight_memory single-port
// MAC pipeline.
//
// Style A: per output pixel and ic, collect all 25 (kh,kw) values
// into a 200-bit V bus, send to pcm_imc_unit, wait for the 25-MAC
// result, then accumulate into per-pixel accumulator.
//
// FSM (8 states):
//   S_IDLE         - wait for start
//   S_SETUP_PIXEL  - acc <= bias[oc], ic_cnt <= 0
//   S_COLLECT      - 25-cycle serial fmap read (k_cnt = 0..24)
//   S_IMC_START    - assert imc_start for 1 cycle
//   S_IMC_WAIT     - wait for result_valid (PCM_LATENCY cycles)
//   S_ACCUMULATE   - acc <= acc + mac_result; advance ic or proceed
//   S_POSTPROC     - apply RSHIFT + ReLU + saturate to INT8
//   S_WRITEBACK    - drive out_addr/out_data/out_en, advance pixel
//
// Address formulas (PyTorch row-major flatten):
//   weight_addr(oc, ic, kh, kw) = oc*(IN_CH*K*K) + ic*(K*K) + kh*K + kw
//   fmap_addr(ic, h, w)         = ic*(IN_H*IN_W) + h*IN_W + w
//   out_addr(oc, oh, ow)        = oc*(OUT_H*OUT_W) + oh*OUT_W + ow
//
// Padding: zero-pad. When (h,w) is outside [0,IN_H)×[0,IN_W),
// V[k] = 0 (and addr[k] is still set, but the V=0 makes the
// product contribute 0 to the MAC).
//
// Watchdog: if S_IMC_WAIT exceeds 64 cycles without result_valid,
// raise mac_timeout (a debug signal).
// ============================================================

`timescale 1ns / 1ps

module conv_engine #(
    parameter integer IN_H     = 28,
    parameter integer IN_W     = 28,
    parameter integer IN_CH    = 1,
    parameter integer OUT_CH   = 6,
    parameter integer KERNEL   = 5,
    parameter integer PADDING  = 2,
    parameter integer OUT_H    = 28,
    parameter integer OUT_W    = 28,
    parameter integer RSHIFT   = 8,
    parameter integer DATA_W   = 8,
    parameter integer ACC_W    = 32,
    parameter integer WADDR_W  = 16,
    parameter integer FADDR_W  = 13,
    parameter integer OADDR_W  = 13,
    parameter integer BADDR_W  = 8,
    parameter integer K_PAR    = 25,            // KERNEL*KERNEL
    parameter integer IMC_ACC_W = 24            // pcm_imc_unit output width
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       start,
    input  wire [2:0]                 layer_id,
    input  wire [4:0]                 rshift_dyn,

    // ---- pcm_imc_unit interface (v3) ----
    // Note: enable_drift / drift_t no longer exposed; pcm_imc_unit
    // sources them from its internal layer_config_regfile (single
    // source of truth, ABI-controlled via wr_en/wr_addr/wr_data on
    // lenet5_top). Removed in v3 X' refactor.
    output reg  [K_PAR*DATA_W-1:0]    imc_v_bus,
    output reg  [K_PAR*WADDR_W-1:0]   imc_addr_bus,
    output reg                        imc_start,
    input  wire signed [IMC_ACC_W-1:0] imc_mac_result,
    input  wire                       imc_result_valid,

    // ---- feature_buffer read-side (sync read, 1 cycle) ----
    output reg  [FADDR_W-1:0]         fmap_addr,
    input  wire signed [DATA_W-1:0]   fmap_in,

    // ---- bias interface (combinational read) ----
    output reg  [BADDR_W-1:0]         bias_addr,
    input  wire signed [ACC_W-1:0]    bias_in,

    // ---- feature_buffer write-side ----
    output reg  [OADDR_W-1:0]         out_addr,
    output reg  signed [DATA_W-1:0]   out_data,
    output reg                        out_en,

    // ---- control / debug ----
    output reg                        done,
    output reg                        mac_timeout
);

    // ----------------------------------------------------------
    // Local params and helpers
    // ----------------------------------------------------------
    localparam integer K2 = KERNEL * KERNEL;
    localparam integer IC_KK = IN_CH * KERNEL * KERNEL;

    // Effective rshift: bit[4]=1 means use rshift_dyn[3:0]
    wire [4:0] rshift_eff = rshift_dyn[4] ? {1'b0, rshift_dyn[3:0]} : RSHIFT[4:0];

    // ----------------------------------------------------------
    // FSM
    // ----------------------------------------------------------
    localparam [3:0] S_IDLE         = 4'd0,
                     S_SETUP_PIXEL  = 4'd1,
                     S_COLLECT      = 4'd2,
                     S_IMC_START    = 4'd3,
                     S_IMC_WAIT     = 4'd4,
                     S_ACCUMULATE   = 4'd5,
                     S_POSTPROC     = 4'd6,
                     S_WRITEBACK    = 4'd7,
                     S_DONE         = 4'd8;

    reg [3:0] state;

    // Pixel counters
    reg [15:0] oc_cnt;
    reg [15:0] or_cnt;
    reg [15:0] oc_col_cnt;
    reg [15:0] ic_cnt;
    reg [5:0]  k_cnt;             // 0..24 during S_COLLECT
    reg [7:0]  wait_cnt;          // S_IMC_WAIT cycle counter

    // Per-pixel accumulator
    reg signed [ACC_W-1:0] acc;

    // Post-processed INT8 result
    reg signed [DATA_W-1:0] acc_int8;

    // ----------------------------------------------------------
    // S_COLLECT cycle k: compute the (kh, kw) for this k and
    // the corresponding fmap (row, col), then issue fmap_addr.
    // ----------------------------------------------------------
    wire [2:0] kh_w = k_cnt / KERNEL;
    wire [2:0] kw_w = k_cnt - kh_w * KERNEL;

    wire signed [15:0] in_row_s = $signed({1'b0, or_cnt}) +
                                   $signed({1'b0, kh_w}) - PADDING;
    wire signed [15:0] in_col_s = $signed({1'b0, oc_col_cnt}) +
                                   $signed({1'b0, kw_w}) - PADDING;

    wire oob = (in_row_s < 0) || (in_row_s >= IN_H) ||
               (in_col_s < 0) || (in_col_s >= IN_W);

    wire [31:0] f_addr_full = (ic_cnt * IN_H * IN_W) +
                              ($unsigned(in_row_s[14:0]) * IN_W) +
                              $unsigned(in_col_s[14:0]);

    // Weight address formula
    wire [31:0] w_addr_full = (oc_cnt * IC_KK) +
                              (ic_cnt * K2) +
                              (kh_w * KERNEL) +
                              kw_w;

    // Out addr
    wire [31:0] o_addr_full = (oc_cnt * OUT_H * OUT_W) +
                              (or_cnt * OUT_W) +
                              oc_col_cnt;

    // ----------------------------------------------------------
    // Combinational outputs (driven each state)
    // ----------------------------------------------------------
    always @(*) begin
        // Defaults
        fmap_addr = 0;
        bias_addr = oc_cnt[BADDR_W-1:0];

        if (state == S_COLLECT && !oob) begin
            fmap_addr = f_addr_full[FADDR_W-1:0];
        end
    end

    // ----------------------------------------------------------
    // Track which k-th read is "in flight" (sync read = 1 cycle delay).
    // When we issue fmap_addr at cycle k, fmap_in arrives at cycle k+1.
    // We capture it into v_bus and addr_bus at that cycle, indexed by
    // a 1-cycle-delayed version of the "k that we issued".
    // ----------------------------------------------------------
    reg [5:0]  k_capture;          // delayed k for the current capture
    reg        capture_valid;       // 1 when we should capture this cycle
    reg        capture_oob;         // 1 if the captured V should be 0 (padding)
    reg [WADDR_W-1:0] capture_waddr; // weight addr for the captured slot

    // ----------------------------------------------------------
    // Main FSM + datapath
    // ----------------------------------------------------------
    integer ki;
    always @(posedge clk) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            oc_cnt        <= 0;
            or_cnt        <= 0;
            oc_col_cnt    <= 0;
            ic_cnt        <= 0;
            k_cnt         <= 0;
            wait_cnt      <= 0;
            acc           <= 0;
            imc_v_bus     <= 0;
            imc_addr_bus  <= 0;
            imc_start     <= 1'b0;
            out_addr      <= 0;
            out_data      <= 0;
            out_en        <= 1'b0;
            done          <= 1'b0;
            mac_timeout   <= 1'b0;
            acc_int8      <= 0;
            k_capture     <= 0;
            capture_valid <= 1'b0;
            capture_oob   <= 1'b0;
            capture_waddr <= 0;
        end else begin
            // Default per-cycle: clear pulses
            imc_start <= 1'b0;
            out_en    <= 1'b0;
            done      <= 1'b0;

            // (v3) drift config now sourced internally by pcm_imc_unit
            // from layer_config_regfile -- no per-engine latching needed.

            // Capture from previous-cycle fmap read
            if (capture_valid) begin
                imc_v_bus[k_capture*DATA_W +: DATA_W] <=
                    capture_oob ? {DATA_W{1'b0}} : fmap_in;
                imc_addr_bus[k_capture*WADDR_W +: WADDR_W] <= capture_waddr;
            end
            // Clear capture flag for default
            capture_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        oc_cnt     <= 0;
                        or_cnt     <= 0;
                        oc_col_cnt <= 0;
                        ic_cnt     <= 0;
                        state      <= S_SETUP_PIXEL;
                    end
                end

                S_SETUP_PIXEL: begin
                    // Load bias into accumulator (bias is INT32 already)
                    acc    <= bias_in;
                    ic_cnt <= 0;
                    k_cnt  <= 0;
                    state  <= S_COLLECT;
                end

                S_COLLECT: begin
                    // We issue fmap_addr at cycle k via combinational logic
                    // (through f_addr_full). Latch the metadata so we can
                    // capture fmap_in next cycle into the right v_bus slot.
                    k_capture     <= k_cnt;
                    capture_valid <= 1'b1;
                    capture_oob   <= oob;
                    capture_waddr <= w_addr_full[WADDR_W-1:0];

                    if (k_cnt == K_PAR - 1) begin
                        k_cnt <= 0;
                        state <= S_IMC_START;
                    end else begin
                        k_cnt <= k_cnt + 1;
                    end
                end

                S_IMC_START: begin
                    // The very last fmap read (k=24) happens 1 cycle
                    // after S_COLLECT exits. We need one extra cycle
                    // here to let the capture above land. But we
                    // already DO the capture this cycle (capture_valid
                    // was set in the last S_COLLECT cycle). So we can
                    // safely assert imc_start now.
                    imc_start <= 1'b1;
                    wait_cnt  <= 0;
                    state     <= S_IMC_WAIT;
                end

                S_IMC_WAIT: begin
                    if (imc_result_valid) begin
                        state <= S_ACCUMULATE;
                    end else if (wait_cnt >= 8'd64) begin
                        // Watchdog: should never happen
                        mac_timeout <= 1'b1;
                        state       <= S_DONE;
                    end else begin
                        wait_cnt <= wait_cnt + 1;
                    end
                end

                S_ACCUMULATE: begin
                    acc <= acc + $signed({{(ACC_W-IMC_ACC_W){imc_mac_result[IMC_ACC_W-1]}},
                                          imc_mac_result});
                    if (ic_cnt == IN_CH - 1) begin
                        // All ic done -> postproc
                        state <= S_POSTPROC;
                    end else begin
                        ic_cnt <= ic_cnt + 1;
                        k_cnt  <= 0;
                        state  <= S_COLLECT;
                    end
                end

                S_POSTPROC: begin
                    // Apply RSHIFT + ReLU + saturate to INT8.
                    // Sign-extending arithmetic right shift (>>>).
                    // After shift, ReLU clamps to [0, 127] and outputs
                    // INT8 saturated.
                    if (acc <= 0) begin
                        acc_int8 <= 8'd0;
                    end else begin
                        // Positive: shift then saturate to [0, 127]
                        // (output is post-ReLU INT8 unsigned, but we still
                        //  send as signed so mac_unit downstream treats it
                        //  as INT8 signed [0..127])
                        if ((acc >>> rshift_eff) > 32'sd127)
                            acc_int8 <= 8'sd127;
                        else
                            acc_int8 <= (acc >>> rshift_eff);
                    end
                    state <= S_WRITEBACK;
                end

                S_WRITEBACK: begin
                    out_addr <= o_addr_full[OADDR_W-1:0];
                    out_data <= acc_int8;
                    out_en   <= 1'b1;

                    // Advance pixel counters: oc_col -> or -> oc
                    if (oc_col_cnt == OUT_W - 1) begin
                        oc_col_cnt <= 0;
                        if (or_cnt == OUT_H - 1) begin
                            or_cnt <= 0;
                            if (oc_cnt == OUT_CH - 1) begin
                                state <= S_DONE;
                            end else begin
                                oc_cnt <= oc_cnt + 1;
                                state  <= S_SETUP_PIXEL;
                            end
                        end else begin
                            or_cnt <= or_cnt + 1;
                            state  <= S_SETUP_PIXEL;
                        end
                    end else begin
                        oc_col_cnt <= oc_col_cnt + 1;
                        state      <= S_SETUP_PIXEL;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
