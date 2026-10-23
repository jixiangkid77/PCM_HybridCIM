// ============================================================
// fc_engine.v   (Paper 2 v2 — IMC architecture, Style A)
// ------------------------------------------------------------
// Fully-connected layer engine for LeNet-5 fc1/fc2/fc3, redesigned
// to use pcm_imc_unit instead of v1 weight_memory.
//
// Operation per FC layer:
//   1. Pre-load entire input vector (length IN_DIM) into input_vec
//      register (one element per cycle; takes IN_DIM cycles).
//   2. For each output neuron oc in [0, OUT_DIM):
//        acc <= bias[oc]
//        for each sub-bank sb in [0, ceil(IN_DIM/25)):
//            pack 25 V values from input_vec[sb*25 .. sb*25+24]
//            (zero-pad if past IN_DIM)
//            compute 25 weight addresses oc*IN_DIM + sb*25 + k
//            send to pcm_imc_unit, wait for result
//            acc += partial
//        apply RSHIFT + ReLU + saturate
//        write ofmap[oc]
//
// Layer dimensions:
//   fc1: IN=400, OUT=120, 16 sub-banks (no remainder)
//   fc2: IN=120, OUT=84,  5 sub-banks (last has only 20 valid)
//   fc3: IN=84,  OUT=10,  4 sub-banks (last has only 9 valid)
//
// FSM (similar to conv_engine):
//   S_IDLE         - wait for start
//   S_LOAD_INPUT   - IN_DIM cycles, fill input_vec
//   S_SETUP_NEURON - acc <= bias[oc], sb_cnt <= 0
//   S_PACK_BANK    - 1 cycle, build v_bus + addr_bus from input_vec
//   S_IMC_START    - assert imc_start
//   S_IMC_WAIT     - wait for result_valid
//   S_ACCUMULATE   - acc += result, advance sb or oc
//   S_POSTPROC     - apply RSHIFT, ReLU, saturate
//   S_WRITEBACK    - drive out_addr/out_data/out_en, advance oc
//
// Address formula:
//   weight_addr(oc, ic) = oc * IN_DIM + ic   (PyTorch Linear weight (OUT, IN))
//   ofmap_addr(oc)      = oc                 (1D output)
// ============================================================

`timescale 1ns / 1ps

module fc_engine #(
    parameter integer IN_DIM   = 400,
    parameter integer OUT_DIM  = 120,
    parameter integer USE_RELU = 1,                // 1=ReLU+8bit, 0=raw 16-bit logit
    parameter integer RSHIFT   = 8,
    parameter integer DATA_W   = 8,                // input activation width
    parameter integer OUT_W    = 8,                // output width (8 for fc1/fc2, 16 for fc3)
    parameter integer ACC_W    = 32,
    parameter integer WADDR_W  = 16,
    parameter integer FADDR_W  = 13,
    parameter integer OADDR_W  = 13,
    parameter integer BADDR_W  = 8,
    parameter integer K_PAR    = 25,
    parameter integer IMC_ACC_W = 24,
    parameter integer MAX_IN_DIM = 400  // for sizing input_vec register
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       start,
    input  wire [2:0]                 layer_id,
    input  wire [4:0]                 rshift_dyn,

    // ---- pcm_imc_unit interface (v3) ----
    // Note: enable_drift / drift_t removed; pcm_imc_unit sources
    // them from its internal layer_config_regfile (v3 X' refactor).
    output reg  [K_PAR*DATA_W-1:0]    imc_v_bus,
    output reg  [K_PAR*WADDR_W-1:0]   imc_addr_bus,
    output reg                        imc_start,
    input  wire signed [IMC_ACC_W-1:0] imc_mac_result,
    input  wire                       imc_result_valid,

    // ---- feature_buffer read-side (sync read, 1 cycle) ----
    output reg  [FADDR_W-1:0]         fmap_addr,
    input  wire signed [DATA_W-1:0]   fmap_in,

    // ---- bias interface ----
    output reg  [BADDR_W-1:0]         bias_addr,
    input  wire signed [ACC_W-1:0]    bias_in,

    // ---- feature_buffer write-side ----
    output reg  [OADDR_W-1:0]         out_addr,
    output reg  signed [OUT_W-1:0]    out_data,
    output reg                        out_en,

    // ---- control ----
    output reg                        done,
    output reg                        mac_timeout
);

    // ----------------------------------------------------------
    // Local params
    // ----------------------------------------------------------
    // Number of sub-banks: ceil(IN_DIM / K_PAR)
    localparam integer NUM_BANKS = (IN_DIM + K_PAR - 1) / K_PAR;

    // Effective rshift: bit[4]=1 means use rshift_dyn[3:0]
    wire [4:0] rshift_eff = rshift_dyn[4] ? {1'b0, rshift_dyn[3:0]} : RSHIFT[4:0];

    // ----------------------------------------------------------
    // FSM
    // ----------------------------------------------------------
    localparam [3:0] S_IDLE         = 4'd0,
                     S_LOAD_INPUT   = 4'd1,
                     S_LOAD_WAIT    = 4'd2,    // 1-cycle wait for last fmap_in
                     S_SETUP_NEURON = 4'd3,
                     S_PACK_BANK    = 4'd4,
                     S_IMC_START    = 4'd5,
                     S_IMC_WAIT     = 4'd6,
                     S_ACCUMULATE   = 4'd7,
                     S_POSTPROC     = 4'd8,
                     S_WRITEBACK    = 4'd9,
                     S_DONE         = 4'd10;

    reg [3:0] state;

    // Counters
    reg [15:0] in_cnt;        // S_LOAD_INPUT: 0..IN_DIM-1 (issuing addr)
    reg [15:0] capture_cnt;   // S_LOAD_INPUT: 0..IN_DIM-1 (capturing data, 1 cycle later)
    reg        capture_valid;
    reg [15:0] oc_cnt;        // 0..OUT_DIM-1
    reg [15:0] sb_cnt;        // 0..NUM_BANKS-1
    reg [7:0]  wait_cnt;

    // Per-neuron accumulator
    reg signed [ACC_W-1:0] acc;
    reg signed [OUT_W-1:0] acc_out;

    // Input vector register: holds the entire FC layer's input
    // Stored as a flat bit vector for indexed slicing.
    // Size: MAX_IN_DIM * DATA_W bits (e.g. 400*8 = 3200 bit for fc1).
    reg [MAX_IN_DIM*DATA_W-1:0] input_vec;

    // ----------------------------------------------------------
    // Combinational outputs
    // ----------------------------------------------------------
    always @(*) begin
        // Default
        fmap_addr = 0;
        bias_addr = oc_cnt[BADDR_W-1:0];

        if (state == S_LOAD_INPUT) begin
            fmap_addr = in_cnt[FADDR_W-1:0];
        end
    end

    // ----------------------------------------------------------
    // Main FSM + datapath
    // ----------------------------------------------------------
    integer ki;
    reg [31:0] addr_calc;
    reg [15:0] flat_idx;       // sb_cnt*K_PAR + ki
    reg signed [DATA_W-1:0] v_byte;

    always @(posedge clk) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            in_cnt        <= 0;
            capture_cnt   <= 0;
            capture_valid <= 1'b0;
            oc_cnt        <= 0;
            sb_cnt        <= 0;
            wait_cnt      <= 0;
            acc           <= 0;
            acc_out       <= 0;
            input_vec     <= 0;
            imc_v_bus     <= 0;
            imc_addr_bus  <= 0;
            imc_start     <= 1'b0;
            out_addr      <= 0;
            out_data      <= 0;
            out_en        <= 1'b0;
            done          <= 1'b0;
            mac_timeout   <= 1'b0;
        end else begin
            // Default per-cycle: clear pulses
            imc_start <= 1'b0;
            out_en    <= 1'b0;
            done      <= 1'b0;

            // (v3) drift config now sourced internally by pcm_imc_unit
            // from layer_config_regfile -- no per-engine latching needed.

            // Capture fmap_in (1 cycle delayed from fmap_addr issue)
            if (capture_valid) begin
                input_vec[capture_cnt*DATA_W +: DATA_W] <= fmap_in;
            end
            capture_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        in_cnt        <= 0;
                        capture_cnt   <= 0;
                        oc_cnt        <= 0;
                        state         <= S_LOAD_INPUT;
                    end
                end

                S_LOAD_INPUT: begin
                    // Issue fmap_addr (combinational), capture next cycle
                    capture_valid <= 1'b1;
                    capture_cnt   <= in_cnt;
                    if (in_cnt == IN_DIM - 1) begin
                        // Last addr issued; need 1 more cycle to capture
                        state <= S_LOAD_WAIT;
                    end else begin
                        in_cnt <= in_cnt + 1;
                    end
                end

                S_LOAD_WAIT: begin
                    // capture_valid was set last cycle; the fmap_in for the
                    // last address arrives now and gets latched into input_vec.
                    state <= S_SETUP_NEURON;
                end

                S_SETUP_NEURON: begin
                    acc    <= bias_in;
                    sb_cnt <= 0;
                    state  <= S_PACK_BANK;
                end

                S_PACK_BANK: begin
                    // Build v_bus and addr_bus combinationally from input_vec.
                    for (ki = 0; ki < K_PAR; ki = ki + 1) begin
                        flat_idx = sb_cnt * K_PAR + ki[15:0];
                        if (flat_idx < IN_DIM) begin
                            v_byte = input_vec[flat_idx*DATA_W +: DATA_W];
                            addr_calc = oc_cnt * IN_DIM + flat_idx;
                            imc_v_bus[ki*DATA_W +: DATA_W]    <= v_byte;
                            imc_addr_bus[ki*WADDR_W +: WADDR_W] <= addr_calc[WADDR_W-1:0];
                        end else begin
                            // Pad past IN_DIM with zero V (and dummy addr)
                            imc_v_bus[ki*DATA_W +: DATA_W]    <= {DATA_W{1'b0}};
                            imc_addr_bus[ki*WADDR_W +: WADDR_W] <= {WADDR_W{1'b0}};
                        end
                    end
                    state <= S_IMC_START;
                end

                S_IMC_START: begin
                    imc_start <= 1'b1;
                    wait_cnt  <= 0;
                    state     <= S_IMC_WAIT;
                end

                S_IMC_WAIT: begin
                    if (imc_result_valid) begin
                        state <= S_ACCUMULATE;
                    end else if (wait_cnt >= 8'd64) begin
                        mac_timeout <= 1'b1;
                        state       <= S_DONE;
                    end else begin
                        wait_cnt <= wait_cnt + 1;
                    end
                end

                S_ACCUMULATE: begin
                    acc <= acc + $signed({{(ACC_W-IMC_ACC_W){imc_mac_result[IMC_ACC_W-1]}},
                                          imc_mac_result});
                    if (sb_cnt == NUM_BANKS - 1) begin
                        state <= S_POSTPROC;
                    end else begin
                        sb_cnt <= sb_cnt + 1;
                        state  <= S_PACK_BANK;
                    end
                end

                S_POSTPROC: begin
                    // RSHIFT first (with sign-preserving arithmetic shift),
                    // then either ReLU+saturate-to-8bit or raw saturate-to-16bit.
                    if (USE_RELU == 1) begin
                        // Mode 1 (fc1, fc2): ReLU + INT8 saturate
                        if (acc <= 0) begin
                            acc_out <= {OUT_W{1'b0}};
                        end else begin
                            if ((acc >>> rshift_eff) > 32'sd127)
                                acc_out <= 8'sd127;  // saturate to INT8 max
                            else
                                acc_out <= (acc >>> rshift_eff);
                        end
                    end else begin
                        // Mode 0 (fc3): no ReLU, saturate to OUT_W signed range
                        if ((acc >>> rshift_eff) > $signed({1'b0, {(OUT_W-1){1'b1}}}))
                            acc_out <= {1'b0, {(OUT_W-1){1'b1}}};   // +max
                        else if ((acc >>> rshift_eff) < -$signed({1'b0, {(OUT_W-1){1'b1}}, 1'b1}))
                            acc_out <= {1'b1, {(OUT_W-1){1'b0}}};   // -min
                        else
                            acc_out <= (acc >>> rshift_eff);
                    end
                    state <= S_WRITEBACK;
                end

                S_WRITEBACK: begin
                    out_addr <= oc_cnt[OADDR_W-1:0];
                    out_data <= acc_out;
                    out_en   <= 1'b1;

                    if (oc_cnt == OUT_DIM - 1) begin
                        state <= S_DONE;
                    end else begin
                        oc_cnt <= oc_cnt + 1;
                        state  <= S_SETUP_NEURON;
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
