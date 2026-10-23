//============================================================
// tb_lenet5_batch_inference_v3.v
// Step 10b: Batch inference over N images, boot-once-loop-N.
//
// Step 10a proved the RTL is BATCH-READY (no reset between
// inferences). Step 10b exercises that capability across
// multiple distinct images.
//
// Dual-tier assertions:
//   HARD (golden match)
//     T_boot           cfg_valid_dbg == 1 after commit
//     T_pred_match[i]  rtl_pred[i] == golden_pred[i]  (Python golden)
//     T_cycle_inv[i]   done_cycle[i] == 617573        (Step 9 baseline)
//
//   SOFT (paper-accuracy report, never fails the TB)
//     T_label_match[i] rtl_pred[i] == true_label[i]
//
// Output:
//   Per-image: rtl_pred / golden_pred / true_label / done_cycle
//   Summary  : golden-match X/N, accuracy Y/N, cycle invariance Z/N
//   Final    : PASS only if HARD checks all pass (T_label is SOFT)
//
// Verilog style:
//   All reg signals updated in their own single `always @(posedge clk)`
//   block. Inter-inference state reset is requested by a tb_reset_pulse
//   signal driven only from initial/task blocks; no reg has multiple
//   drivers across processes (synthesis-style hygiene).
//
// Compile-time params:
//   N_IMAGES  default 10 (Step 10b). Use -DN_IMAGES=100 for Step 11.
//   MODEL_B   if defined, select Model B.
//============================================================

`timescale 1ns/1ps

`ifndef N_IMAGES
  `define N_IMAGES 10
`endif

`ifndef MODEL_B
  `define DATA_DIR_STR    "data/rtl_inputs_A_v3"
  `define IMAGE_DIR_STR   "data/rtl_inputs_A/images"
  `define MODEL_TAG       "A"
  `define MODEL_NAME      "Model A"
  `define LABEL_FILE_STR  "data/rtl_inputs_A/image_labels.hex"
`else
  `define DATA_DIR_STR    "data/rtl_inputs_B_v3"
  `define IMAGE_DIR_STR   "data/rtl_inputs_B/images"
  `define MODEL_TAG       "B"
  `define MODEL_NAME      "Model B"
  `define LABEL_FILE_STR  "data/rtl_inputs_B/image_labels.hex"
`endif
`define COMMON_DIR_STR    "data/rtl_inputs_common"

// Step 9 baseline. Hard-checked per image. If RTL FSM scheduling
// is intentionally changed, update this constant.
`define EXPECTED_CYCLES 32'd617573

module tb_lenet5_batch_inference_v3;

    localparam integer DATA_W  = 8;
    localparam integer FADDR_W = 13;
    localparam integer N       = `N_IMAGES;

    // ---- Clock + DUT reset ----
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    // ---- DUT I/O ----
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

    // ============================================================
    // Single-driver counter / done-capture (synthesis-style hygiene)
    // ============================================================
    reg        tb_reset_pulse    = 1'b0;   // driven by initial; sampled here
    reg [31:0] cycle_after_start = 32'd0;
    reg        cycle_counting    = 1'b0;
    reg        done_pulse_seen   = 1'b0;
    reg [3:0]  captured_pred     = 4'd0;
    reg [31:0] done_cycle        = 32'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_after_start <= 0;
            cycle_counting    <= 1'b0;
            done_pulse_seen   <= 1'b0;
            captured_pred     <= 4'd0;
            done_cycle        <= 0;
        end else if (tb_reset_pulse) begin
            cycle_after_start <= 0;
            cycle_counting    <= 1'b0;
            done_pulse_seen   <= 1'b0;
            // NOTE: captured_pred and done_cycle deliberately NOT
            // cleared here. The TB has already captured them into
            // arrays by the time it pulses tb_reset_pulse, and
            // leaving them untouched is harmless.
        end else begin
            if (start)          cycle_counting    <= 1'b1;
            if (cycle_counting) cycle_after_start <= cycle_after_start + 1;
            if (DUT.done && !done_pulse_seen) begin
                done_pulse_seen <= 1'b1;
                captured_pred   <= DUT.predicted_class;
                done_cycle      <= cycle_after_start;
            end
        end
    end

    // ---- TB-side data ----
    reg signed [DATA_W-1:0] image_mirror   [0:783];
    reg [31:0]              cfg_words      [0:9];
    reg [7:0]               golden_preds   [0:N-1];
    // image_labels.hex always has 100 entries; declare full size to
    // avoid $readmemh "too many words" warning when N < 100.
    reg [7:0]               true_labels    [0:99];

    // Per-image capture arrays
    reg [3:0]  rtl_pred_arr [0:N-1];
    reg [31:0] rtl_cycle_arr [0:N-1];

    integer pass_count = 0;
    integer fail_count = 0;

    //==========================================================
    // Helper tasks
    //==========================================================
    task do_cfg_write(input [5:0] a, input [31:0] d);
        begin
            @(negedge clk);
            cfg_wr_en = 1'b1; cfg_wr_addr = a; cfg_wr_data = d;
            @(negedge clk);
            cfg_wr_en = 1'b0;
        end
    endtask

    task reset_inference_counters;
        begin
            @(negedge clk);
            tb_reset_pulse = 1'b1;
            @(negedge clk);
            tb_reset_pulse = 1'b0;
        end
    endtask

    task load_image_from_mirror;
        integer k;
        begin
            for (k = 0; k < 784; k = k + 1) begin
                @(negedge clk);
                image_we   = 1'b1;
                image_addr = k[FADDR_W-1:0];
                image_data = image_mirror[k];
            end
            @(negedge clk);
            image_we = 1'b0;
        end
    endtask

    task pulse_start;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task wait_for_done(input [31:0] timeout, output [31:0] cycles_waited);
        integer wc;
        begin
            wc = 0;
            while (!done_pulse_seen && wc < timeout) begin
                @(negedge clk);
                wc = wc + 1;
            end
            cycles_waited = wc;
        end
    endtask

    //==========================================================
    // Main
    //==========================================================
    integer i;
    integer golden_match_count;
    integer accuracy_count;
    integer cycle_invariance_count;
    integer accuracy_miss_count;
    reg [31:0] cycles_waited;
    reg [255*8-1:0] img_path;   // 255-char buffer

    initial begin
        $display("============================================================");
        $display("tb_lenet5_batch_inference_v3   (Step 10b batch inference)");
        $display("============================================================");
        $display("  %s, N=%0d images", `MODEL_NAME, N);
        $display("  DATA_DIR  : %s", `DATA_DIR_STR);
        $display("  IMAGE_DIR : %s", `IMAGE_DIR_STR);
        $display("  golden    : data/golden/golden_preds_%s_imgs1-%0d.hex",
                 `MODEL_TAG, N);
        $display("  expected cycles per image : %0d", `EXPECTED_CYCLES);
        $display("");

        start          = 0;
        image_we       = 0;
        image_addr     = 0;
        image_data     = 0;
        cfg_wr_en      = 0;
        cfg_wr_addr    = 0;
        cfg_wr_data    = 0;
        tb_reset_pulse = 0;
        rst_n          = 0;

        @(negedge clk); @(negedge clk); @(negedge clk);

        // Load static references (cfg, goldens, labels)
        $readmemh({`DATA_DIR_STR, "/layer_config.hex"}, cfg_words);
        $sformat(img_path, "data/golden/golden_preds_%s_imgs1-%0d.hex",
                 `MODEL_TAG, N);
        $readmemh(img_path, golden_preds);
        $readmemh(`LABEL_FILE_STR, true_labels);

        @(negedge clk);
        rst_n = 1;
        @(negedge clk); @(negedge clk);

        //----- Boot ONCE -----
        $display("Boot config");
        for (i = 0; i < 10; i = i + 1) do_cfg_write(i[5:0], cfg_words[i]);
        do_cfg_write(6'h21, 32'h0000_0000);
        do_cfg_write(6'h20, 32'h0000_0002);

        if (DUT.u_imc.cfg_valid_dbg === 1'b1) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T_boot cfg_valid_dbg = 1");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T_boot cfg_valid_dbg = %b", DUT.u_imc.cfg_valid_dbg);
            $display("RESULT: boot failed, aborting");
            $finish;
        end
        $display("");

        //----- Loop over N images -----
        $display("Running %0d inferences...", N);
        for (i = 0; i < N; i = i + 1) begin
            // Reset cycle counter + done flag (synthesis-style: via pulse)
            reset_inference_counters();

            // Load image_<i+1>
            $sformat(img_path, "%s/img_%03d.hex", `IMAGE_DIR_STR, i + 1);
            $readmemh(img_path, image_mirror);
            load_image_from_mirror();

            // Pulse start, wait for done
            pulse_start();
            wait_for_done(32'd2000000, cycles_waited);

            // Capture
            rtl_pred_arr[i]  = captured_pred;
            rtl_cycle_arr[i] = done_cycle;

            $display("  img_%03d : rtl_pred=%0d  golden=%0d  true=%0d  cycle=%0d  %s%s%s",
                     i + 1,
                     rtl_pred_arr[i],
                     golden_preds[i][3:0],
                     true_labels[i][3:0],
                     rtl_cycle_arr[i],
                     (rtl_pred_arr[i] == golden_preds[i][3:0]) ? "[golden OK]" : "[GOLDEN FAIL]",
                     (rtl_cycle_arr[i] == `EXPECTED_CYCLES)    ? "[cyc OK]"    : "[CYC FAIL]",
                     (rtl_pred_arr[i] == true_labels[i][3:0])  ? "[acc OK]"    : "[acc miss]");
        end

        //----- Aggregate results -----
        golden_match_count     = 0;
        accuracy_count         = 0;
        cycle_invariance_count = 0;
        accuracy_miss_count    = 0;
        for (i = 0; i < N; i = i + 1) begin
            if (rtl_pred_arr[i]  == golden_preds[i][3:0]) golden_match_count     = golden_match_count + 1;
            if (rtl_pred_arr[i]  == true_labels[i][3:0])  accuracy_count         = accuracy_count + 1;
            else                                          accuracy_miss_count    = accuracy_miss_count + 1;
            if (rtl_cycle_arr[i] == `EXPECTED_CYCLES)     cycle_invariance_count = cycle_invariance_count + 1;
        end

        //----- HARD checks -----
        $display("");
        $display("============================================================");
        $display("HARD assertions:");
        if (golden_match_count == N) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T_pred_match  RTL == golden : %0d/%0d", golden_match_count, N);
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T_pred_match  RTL == golden : %0d/%0d", golden_match_count, N);
        end

        if (cycle_invariance_count == N) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T_cycle_inv   all done_cycle == %0d : %0d/%0d",
                     `EXPECTED_CYCLES, cycle_invariance_count, N);
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T_cycle_inv   cycle invariance broke : %0d/%0d (expected all = %0d)",
                     cycle_invariance_count, N, `EXPECTED_CYCLES);
        end

        //----- SOFT report (paper accuracy) -----
        $display("");
        $display("SOFT report (paper-grade, not pass/fail):");
        $display("  Accuracy (vs true labels) : %0d/%0d (%0d.%0d%%)",
                 accuracy_count, N,
                 (accuracy_count * 100) / N,
                 ((accuracy_count * 1000) / N) % 10);
        $display("  Misclassifications        : %0d/%0d", accuracy_miss_count, N);

        //----- Final summary -----
        $display("");
        $display("============================================================");
        $display("Total HARD: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count == 0)
            $display("RESULT: ALL HARD TESTS PASSED  (RTL == Python golden, cycle invariant)");
        else
            $display("RESULT: FAILED");
        $display("============================================================");

        $finish;
    end

    initial begin
        // Sim watchdog: N images × ~6.2 ms simulated = N × 6,200,000,000 ps.
        // For N=10:  62 ms simulated;  for N=100: 620 ms.
        // Allow 5× margin.
        #5000000000;
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule
