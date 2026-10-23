//============================================================
// tb_lenet5_full_conv2_v3.v
// Step 8c: FULL conv2 layer (1600 outputs) exact-compare
//          + per-layer cycle measurement for paper metrics.
//
// Extends Step 8b (tb_lenet5_conv2_v3.v, 200 captures) to all
// 16 output channels × 10 × 10 spatial positions of conv2.
//
// Same DATA_DIR refactor mechanism as Step 8b (compile-time
// `define MODEL_B` switch). No hierarchical preload or
// bias_redistribute workaround.
//
// Cycle measurements reported at end:
//   * cycles from start pulse to first conv2 writeback
//       (= conv1 + pool1 inference latency + boot overhead)
//   * conv2 layer window (last - first + 1)
//       (= pure conv2 layer execution time)
//   * cycles from start pulse to last conv2 writeback
//       (= conv1 + pool1 + conv2 total latency)
//
// These numbers feed Paper 2 V-F hardware performance table.
//
// Tests:
//   T1 boot protocol (full host wr_* sequence)
//   T2 image load
//   T3 inference + ALL 1600 conv2 writebacks exact-compare
//      Gate signal: DUT.u_fsm.step_id == 4'd2
//      T3.1 1600 writebacks captured
//      T3.2 all 1600 match golden_conv2
//      T3.3 non-zero arithmetic exercised
//
// Expected non-zero counts (full conv2):
//   Model A: 258 / 1600
//   Model B: 906 / 1600
//============================================================

`timescale 1ns/1ps

// ---- Compile-time Model selection -----------------------------
`ifndef MODEL_B
  `define DATA_DIR_STR  "data/rtl_inputs_A_v3"
  `define IMG_FILE_STR  "data/rtl_inputs_A/images/img_001.hex"
  `define GOLDEN_STR    "data/golden/golden_conv2_A_img1.hex"
  `define MODEL_NAME    "Model A"
`else
  `define DATA_DIR_STR  "data/rtl_inputs_B_v3"
  `define IMG_FILE_STR  "data/rtl_inputs_B/images/img_001.hex"
  `define GOLDEN_STR    "data/golden/golden_conv2_B_img1.hex"
  `define MODEL_NAME    "Model B"
`endif
`define COMMON_DIR_STR  "data/rtl_inputs_common"

module tb_lenet5_full_conv2_v3;

    localparam integer DATA_W      = 8;
    localparam integer FADDR_W     = 13;
    localparam integer OADDR_W     = 13;
    localparam integer WADDR_W     = 16;

    // Conv2 output sizing
    localparam integer CONV2_OUT_CH = 16;
    localparam integer CONV2_OUT_H  = 10;
    localparam integer CONV2_OUT_W  = 10;
    localparam integer CONV2_OUT_N  = CONV2_OUT_CH * CONV2_OUT_H * CONV2_OUT_W; // 1600

    localparam integer N_CAPTURE = 1600; // FULL conv2 layer (all 16 channels)

    // ---- Clock + reset -------------------------------------------
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    // ---- DUT I/O -------------------------------------------------
    reg                       start;
    reg                       image_we;
    reg  [FADDR_W-1:0]        image_addr;
    reg  signed [DATA_W-1:0]  image_data;
    reg                       cfg_wr_en;
    reg  [5:0]                cfg_wr_addr;
    reg  [31:0]               cfg_wr_data;
    wire                      done;
    wire [3:0]                predicted_class;

    lenet5_top #(
        .DATA_DIR(`DATA_DIR_STR),
        .COMMON_DIR(`COMMON_DIR_STR)
    ) DUT (
        .clk(clk), .rst_n(rst_n),
        .start(start),
        .done(done),
        .predicted_class(predicted_class),
        .image_we(image_we),
        .image_addr(image_addr),
        .image_data(image_data),
        .cfg_wr_en(cfg_wr_en),
        .cfg_wr_addr(cfg_wr_addr),
        .cfg_wr_data(cfg_wr_data)
    );

    // ---- Mirrors -------------------------------------------------
    reg signed [DATA_W-1:0] image_mirror  [0:783];
    reg          [7:0]      golden_mirror [0:CONV2_OUT_N-1];
    reg          [31:0]     cfg_words     [0:9];

    // ---- Cycle counter (from `start` pulse onwards) --------------
    reg [31:0] cycle_after_start = 0;
    reg        started_flag      = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_after_start <= 0;
            started_flag      <= 1'b0;
        end else begin
            if (start) started_flag <= 1'b1;
            if (started_flag) cycle_after_start <= cycle_after_start + 1;
        end
    end

    // ---- Conv2 writeback capture (gated on step_id==2) -----------
    reg            capture_done   = 1'b0;
    integer        cap_count      = 0;
    reg [31:0]     first_cap_cycle = 32'hFFFF_FFFF;
    reg [31:0]     last_cap_cycle  = 0;
    reg [OADDR_W-1:0] cap_addr [0:N_CAPTURE-1];
    reg signed [DATA_W-1:0] cap_data [0:N_CAPTURE-1];

    always @(posedge clk) begin
        if (!rst_n) begin
            capture_done    <= 1'b0;
            cap_count       <= 0;
            first_cap_cycle <= 32'hFFFF_FFFF;
            last_cap_cycle  <= 0;
        end else if (DUT.fbuf_write_en_fsm &&
                     (DUT.u_fsm.step_id == 4'd2) &&
                     !capture_done) begin
            cap_addr[cap_count] <= DUT.fbuf_write_addr_fsm;
            cap_data[cap_count] <= DUT.fbuf_write_data_fsm;
            if (cap_count == 0) first_cap_cycle <= cycle_after_start;
            last_cap_cycle <= cycle_after_start;
            if (cap_count == N_CAPTURE - 1) begin
                capture_done <= 1'b1;
            end
            cap_count <= cap_count + 1;
        end
    end

    // ---- Stats ---------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;

    //==========================================================
    // Boot helper
    //==========================================================
    task do_cfg_write(input [5:0] a, input [31:0] d);
        begin
            @(negedge clk);
            cfg_wr_en   = 1'b1;
            cfg_wr_addr = a;
            cfg_wr_data = d;
            @(negedge clk);
            cfg_wr_en   = 1'b0;
        end
    endtask

    //==========================================================
    // Main
    //==========================================================
    integer i;
    integer wait_count;

    initial begin
        $display("============================================================");
        $display("tb_lenet5_full_conv2_v3  (Step 8c FULL conv2 %0d outputs)",
                 N_CAPTURE);
        $display("============================================================");
        $display("  %s", `MODEL_NAME);
        $display("  DATA_DIR   = %s", `DATA_DIR_STR);
        $display("  COMMON_DIR = %s", `COMMON_DIR_STR);
        $display("  IMG        = %s", `IMG_FILE_STR);
        $display("  GOLDEN     = %s", `GOLDEN_STR);
        $display("");

        // ---- Initialize signals ----
        start       = 0;
        image_we    = 0;
        image_addr  = 0;
        image_data  = 0;
        cfg_wr_en   = 0;
        cfg_wr_addr = 0;
        cfg_wr_data = 0;
        rst_n       = 0;

        // Hold reset for a few cycles
        @(negedge clk); @(negedge clk); @(negedge clk);

        // Load testbench mirrors (NO hierarchical $readmemh of DUT internals)
        $readmemh(`IMG_FILE_STR,    image_mirror);
        $readmemh(`GOLDEN_STR,      golden_mirror);
        $readmemh({`DATA_DIR_STR, "/layer_config.hex"}, cfg_words);

        $display("  Loaded image (784 pixels), golden_conv2 (%0d entries), cfg_words (10)",
                 CONV2_OUT_N);
        $display("  image first byte = %0d", $signed(image_mirror[0]));
        $display("");

        // Deassert reset
        @(negedge clk);
        rst_n = 1;
        @(negedge clk); @(negedge clk);

        //----------------------------------------------------------
        // T1 — Boot protocol
        //----------------------------------------------------------
        $display("T1  Boot protocol (full host wr_* sequence)");
        if (DUT.u_imc.cfg_valid_dbg === 1'b0) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T1.1 cfg_valid_dbg=0 after reset (no commit yet)");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T1.1 cfg_valid_dbg=%b (expected 0)",
                     DUT.u_imc.cfg_valid_dbg);
        end

        for (i = 0; i < 10; i = i + 1) begin
            do_cfg_write(i[5:0], cfg_words[i]);
        end
        do_cfg_write(6'h21, 32'h0000_0000);
        do_cfg_write(6'h20, 32'h0000_0002);

        if (DUT.u_imc.cfg_valid_dbg === 1'b1 &&
            DUT.u_imc.enable_drift_dbg === 1'b0 &&
            DUT.u_imc.drift_t_dbg === 16'd0) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T1.2 after commit: cfg_valid=1, enable_drift=0, drift_t=0");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T1.2 cfg_valid=%b enable_drift=%b drift_t=%0d",
                     DUT.u_imc.cfg_valid_dbg,
                     DUT.u_imc.enable_drift_dbg,
                     DUT.u_imc.drift_t_dbg);
        end

        begin: cfg_verify
            integer cfg_idx;
            integer cfg_diffs;
            cfg_diffs = 0;
            for (cfg_idx = 0; cfg_idx < 10; cfg_idx = cfg_idx + 1) begin
                if (DUT.u_imc.U_REGFILE.cfg_mem[cfg_idx] !== cfg_words[cfg_idx]) begin
                    cfg_diffs = cfg_diffs + 1;
                    $display("    [DIFF] cfg_mem[%0d]=%h  expected=%h",
                             cfg_idx,
                             DUT.u_imc.U_REGFILE.cfg_mem[cfg_idx],
                             cfg_words[cfg_idx]);
                end
            end
            if (cfg_diffs == 0) begin
                pass_count = pass_count + 1;
                $display("  [PASS] T1.3 all 10 cfg_mem entries match (wr port + auto-load consistent)");
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T1.3 %0d / 10 cfg_mem mismatches", cfg_diffs);
            end
        end

        //----------------------------------------------------------
        // T2 — Image load
        //----------------------------------------------------------
        $display("");
        $display("T2  Image loading (28x28 = 784 pixels via image_we)");
        for (i = 0; i < 784; i = i + 1) begin
            @(negedge clk);
            image_we   = 1'b1;
            image_addr = i[FADDR_W-1:0];
            image_data = image_mirror[i];
        end
        @(negedge clk);
        image_we   = 1'b0;
        image_addr = 0;
        image_data = 0;
        pass_count = pass_count + 1;
        $display("  [PASS] T2.1 784 pixels written");

        //----------------------------------------------------------
        // T3 — Inference + first N=200 conv2 writebacks
        //----------------------------------------------------------
        $display("");
        $display("T3  Inference start + ALL %0d conv2 writebacks (gated on step_id==2)",
                 N_CAPTURE);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // Wait through conv1 + pool1 + full conv2 (all 1600 outputs).
        // Estimate: conv1 ~193K + pool1 ~6K + conv2 1600*275 ~440K = ~640K.
        // Allow 1,000,000 cycles for margin.
        wait_count = 0;
        while (!capture_done && wait_count < 1000000) begin
            @(negedge clk);
            wait_count = wait_count + 1;
        end

        if (!capture_done) begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T3.1 only %0d / %0d conv2 writebacks captured in %0d cycles",
                     cap_count, N_CAPTURE, wait_count);
            $display("           current step_id = %0d", DUT.u_fsm.step_id);
        end else begin
            pass_count = pass_count + 1;
            $display("  [PASS] T3.1 %0d conv2 writebacks captured in %0d cycles",
                     N_CAPTURE, wait_count);

            // Compare every capture against golden_conv2
            begin: compare_block
                integer mismatches;
                integer nonzero_count;
                integer first_mismatch;
                integer cap_idx;
                integer abs_diff;
                integer max_abs_diff;
                reg [7:0] exp_val;
                reg [OADDR_W-1:0] addr;
                mismatches     = 0;
                nonzero_count  = 0;
                first_mismatch = -1;
                max_abs_diff   = 0;
                for (cap_idx = 0; cap_idx < N_CAPTURE; cap_idx = cap_idx + 1) begin
                    addr    = cap_addr[cap_idx];
                    exp_val = golden_mirror[addr];
                    if (exp_val != 0) nonzero_count = nonzero_count + 1;
                    if (cap_data[cap_idx] !== $signed({1'b0, exp_val})) begin
                        if (cap_data[cap_idx] > $signed({1'b0, exp_val}))
                            abs_diff = cap_data[cap_idx] - $signed({1'b0, exp_val});
                        else
                            abs_diff = $signed({1'b0, exp_val}) - cap_data[cap_idx];
                        if (abs_diff > max_abs_diff) max_abs_diff = abs_diff;
                        if (mismatches < 5) begin
                            $display("    [DIFF] cap[%0d] addr=%0d got=%0d exp=%0d (oc=%0d y=%0d x=%0d)",
                                     cap_idx, addr,
                                     cap_data[cap_idx], exp_val,
                                     addr / (CONV2_OUT_H * CONV2_OUT_W),
                                     (addr / CONV2_OUT_W) % CONV2_OUT_H,
                                     addr % CONV2_OUT_W);
                        end
                        if (first_mismatch < 0) first_mismatch = cap_idx;
                        mismatches = mismatches + 1;
                    end
                end

                if (mismatches == 0) begin
                    pass_count = pass_count + 1;
                    $display("  [PASS] T3.2 all %0d conv2 writebacks match golden",
                             N_CAPTURE);
                end else begin
                    fail_count = fail_count + 1;
                    $display("  [FAIL] T3.2 %0d / %0d mismatches (first at idx=%0d, max_abs_diff=%0d)",
                             mismatches, N_CAPTURE, first_mismatch, max_abs_diff);
                end

                if (nonzero_count == 0) begin
                    fail_count = fail_count + 1;
                    $display("  [FAIL] T3.3 all %0d captured golden entries are zero",
                             N_CAPTURE);
                end else begin
                    pass_count = pass_count + 1;
                    $display("  [PASS] T3.3 %0d non-zero golden compares (arithmetic exercised)",
                             nonzero_count);
                end

                // Explicit summary line for experiment-table extraction
                $display("");
                $display("  Summary: mismatches=%0d / %0d   nonzero_count=%0d",
                         mismatches, N_CAPTURE, nonzero_count);

                $display("");
                $display("  Sample captures (spread across 1600 conv2 outputs):");
                $display("    cap[0]:    addr=%0d  got=%0d  exp=%0d   (oc=%0d y=%0d x=%0d)",
                         cap_addr[0],   cap_data[0],   golden_mirror[cap_addr[0]],
                         cap_addr[0] / (CONV2_OUT_H * CONV2_OUT_W),
                         (cap_addr[0] / CONV2_OUT_W) % CONV2_OUT_H,
                         cap_addr[0] % CONV2_OUT_W);
                $display("    cap[50]:   addr=%0d  got=%0d  exp=%0d   (oc=%0d y=%0d x=%0d)",
                         cap_addr[50],  cap_data[50],  golden_mirror[cap_addr[50]],
                         cap_addr[50] / (CONV2_OUT_H * CONV2_OUT_W),
                         (cap_addr[50] / CONV2_OUT_W) % CONV2_OUT_H,
                         cap_addr[50] % CONV2_OUT_W);
                $display("    cap[199]:  addr=%0d  got=%0d  exp=%0d   (oc=%0d y=%0d x=%0d)",
                         cap_addr[199], cap_data[199], golden_mirror[cap_addr[199]],
                         cap_addr[199] / (CONV2_OUT_H * CONV2_OUT_W),
                         (cap_addr[199] / CONV2_OUT_W) % CONV2_OUT_H,
                         cap_addr[199] % CONV2_OUT_W);
                $display("    cap[800]:  addr=%0d  got=%0d  exp=%0d   (oc=%0d y=%0d x=%0d)",
                         cap_addr[800], cap_data[800], golden_mirror[cap_addr[800]],
                         cap_addr[800] / (CONV2_OUT_H * CONV2_OUT_W),
                         (cap_addr[800] / CONV2_OUT_W) % CONV2_OUT_H,
                         cap_addr[800] % CONV2_OUT_W);
                $display("    cap[%0d]: addr=%0d  got=%0d  exp=%0d   (oc=%0d y=%0d x=%0d)",
                         N_CAPTURE-1,
                         cap_addr[N_CAPTURE-1],
                         cap_data[N_CAPTURE-1],
                         golden_mirror[cap_addr[N_CAPTURE-1]],
                         cap_addr[N_CAPTURE-1] / (CONV2_OUT_H * CONV2_OUT_W),
                         (cap_addr[N_CAPTURE-1] / CONV2_OUT_W) % CONV2_OUT_H,
                         cap_addr[N_CAPTURE-1] % CONV2_OUT_W);

                // ---- Cycle metrics (for Paper 2 V-F table) -----
                $display("");
                $display("  Cycle measurements (from `start` pulse):");
                $display("    cycles to FIRST conv2 writeback : %0d  (= conv1 + pool1 + boot overhead)",
                         first_cap_cycle);
                $display("    cycles to LAST  conv2 writeback : %0d  (= conv1 + pool1 + conv2 total)",
                         last_cap_cycle);
                $display("    conv2 layer window cycles       : %0d  (last - first + 1)",
                         last_cap_cycle - first_cap_cycle + 1);
            end
        end

        //----------------------------------------------------------
        // Summary
        //----------------------------------------------------------
        $display("");
        $display("============================================================");
        $display("Total: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count == 0) begin
            $display("RESULT: ALL TESTS PASSED");
        end else begin
            $display("RESULT: FAILED");
        end
        $display("============================================================");

        $finish;
    end

    initial begin
        #200000000;
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule
