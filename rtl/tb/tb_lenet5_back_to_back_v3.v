//============================================================
// tb_lenet5_back_to_back_v3.v
// Step 10a: Verify back-to-back inference WITHOUT reset.
//
// Critical for Step 10b/11 batch testing: does the RTL return
// to a clean state after `done` so a second `start` produces
// the same result?
//
// Sequence:
//   1. reset
//   2. boot config ONCE  (commit cfg_valid)
//   3. load img_001 via image_we
//   4. pulse start → wait done → capture (pred1, done_cycle1)
//   5. [no reset, no re-boot]
//   6. snapshot inter-inference state for diagnostics
//   7. load img_001 again via image_we
//   8. pulse start → wait done → capture (pred2, done_cycle2)
//
// Pass conditions (6 checks):
//   T_boot cfg_valid_dbg == 1 after commit
//   T_a    pred1 == golden_pred_img001 (= 7)
//   T_b    done_cycle1 == 617573 (Step 9 baseline)
//   T_c    pred2 == golden_pred_img001
//   T_d    done_cycle2 == done_cycle1 (timing invariance)
//   T_e    pred1 == pred2 (consistency, implied by T_a∧T_c)
//
// If T_d fails → some internal state was not cleaned up between
// inferences. Even if pred is correct, timing drift would
// accumulate in N-image batch. → investigate state snapshot,
// possibly add boot-only-no-reset between inferences (fallback A)
// or full reset+boot (fallback B).
//============================================================

`timescale 1ns/1ps

`ifndef MODEL_B
  `define DATA_DIR_STR  "data/rtl_inputs_A_v3"
  `define IMG_FILE_STR  "data/rtl_inputs_A/images/img_001.hex"
  `define MODEL_TAG     "A"
  `define MODEL_NAME    "Model A"
  `define EXPECTED_PRED 4'd7
`else
  `define DATA_DIR_STR  "data/rtl_inputs_B_v3"
  `define IMG_FILE_STR  "data/rtl_inputs_B/images/img_001.hex"
  `define MODEL_TAG     "B"
  `define MODEL_NAME    "Model B"
  `define EXPECTED_PRED 4'd7
`endif
`define COMMON_DIR_STR  "data/rtl_inputs_common"
// EXPECTED_CYCLES intentionally locks the Step 9 baseline latency.
// If the scheduling FSM is intentionally changed (e.g. pipeline
// optimization), update this constant to the new measured value.
// A cycle mismatch with the same image+model+protection map
// indicates either timing drift between inferences or a
// scheduling regression — both worth surfacing as FAIL.
`define EXPECTED_CYCLES 32'd617573

module tb_lenet5_back_to_back_v3;

    localparam integer DATA_W  = 8;
    localparam integer FADDR_W = 13;

    // ---- Clock + reset ----
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

    // ---- Mirrors ----
    reg signed [DATA_W-1:0] image_mirror [0:783];
    reg [31:0]              cfg_words    [0:9];

    // ---- Cycle counter from start ----
    reg [31:0] cycle_after_start = 0;
    reg        cycle_counting    = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_after_start <= 0;
            cycle_counting    <= 1'b0;
        end else begin
            if (start)         cycle_counting    <= 1'b1;
            if (cycle_counting) cycle_after_start <= cycle_after_start + 1;
        end
    end

    // ---- Done capture (latches on EACH new done pulse) ----
    reg        done_pulse_seen = 1'b0;
    reg [3:0]  captured_pred   = 4'd0;
    reg [31:0] done_cycle      = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            done_pulse_seen <= 1'b0;
            captured_pred   <= 4'd0;
            done_cycle      <= 0;
        end else if (DUT.done) begin
            done_pulse_seen <= 1'b1;
            captured_pred   <= DUT.predicted_class;
            done_cycle      <= cycle_after_start;
        end
    end

    integer pass_count = 0;
    integer fail_count = 0;

    task do_cfg_write(input [5:0] a, input [31:0] d);
        begin
            @(negedge clk);
            cfg_wr_en = 1'b1; cfg_wr_addr = a; cfg_wr_data = d;
            @(negedge clk);
            cfg_wr_en = 1'b0;
        end
    endtask

    task load_image;
        integer i;
        begin
            for (i = 0; i < 784; i = i + 1) begin
                @(negedge clk);
                image_we   = 1'b1;
                image_addr = i[FADDR_W-1:0];
                image_data = image_mirror[i];
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
            done_pulse_seen = 1'b0;
            wc = 0;
            while (!done_pulse_seen && wc < timeout) begin
                @(negedge clk);
                wc = wc + 1;
            end
            cycles_waited = wc;
        end
    endtask

    task snapshot_state(input [255:0] label);
        begin
            $display("  --- %s ---", label);
            $display("    top_fsm.state           = %0d", DUT.u_fsm.state);
            $display("    top_fsm.step_id         = %0d", DUT.u_fsm.step_id);
            $display("    argmax_wrapper.state    = %0d", DUT.u_fsm.u_argmax.state);
            $display("    argmax_wrapper.read_cnt = %0d", DUT.u_fsm.u_argmax.read_cnt);
            $display("    pcm_imc_unit.cfg_valid  = %b",  DUT.u_imc.cfg_valid_dbg);
            $display("    feature_buffer.role_sel = %0d", DUT.u_fbuf.role_sel);
            $display("    DUT.done                = %b",  DUT.done);
            $display("    DUT.predicted_class     = %0d", DUT.predicted_class);
        end
    endtask

    integer i;
    reg [31:0] cycles_waited;
    reg [3:0]  pred1, pred2;
    reg [31:0] done_cycle1, done_cycle2;

    initial begin
        $display("============================================================");
        $display("tb_lenet5_back_to_back_v3   (Step 10a back-to-back sanity)");
        $display("============================================================");
        $display("  %s", `MODEL_NAME);
        $display("  image    : %s", `IMG_FILE_STR);
        $display("  expected : pred=%0d, cycles=%0d (from Step 9 baseline)",
                 `EXPECTED_PRED, `EXPECTED_CYCLES);
        $display("");

        start       = 0;
        image_we    = 0;
        image_addr  = 0;
        image_data  = 0;
        cfg_wr_en   = 0;
        cfg_wr_addr = 0;
        cfg_wr_data = 0;
        rst_n       = 0;

        @(negedge clk); @(negedge clk); @(negedge clk);

        $readmemh(`IMG_FILE_STR, image_mirror);
        $readmemh({`DATA_DIR_STR, "/layer_config.hex"}, cfg_words);

        @(negedge clk);
        rst_n = 1;
        @(negedge clk); @(negedge clk);

        //----- Boot ONCE -----
        $display("Boot config (only happens once)");
        for (i = 0; i < 10; i = i + 1) do_cfg_write(i[5:0], cfg_words[i]);
        do_cfg_write(6'h21, 32'h0000_0000);
        do_cfg_write(6'h20, 32'h0000_0002);

        if (DUT.u_imc.cfg_valid_dbg === 1'b1) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T_boot cfg_valid_dbg = 1 after commit");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T_boot cfg_valid_dbg = %b (expected 1)",
                     DUT.u_imc.cfg_valid_dbg);
        end
        $display("");

        //=================== INFERENCE 1 ===================
        $display("=== Inference 1 ===");
        load_image();
        // Reset our cycle counter
        cycle_counting    = 1'b0;
        cycle_after_start = 0;
        pulse_start();
        wait_for_done(32'd2000000, cycles_waited);
        pred1       = captured_pred;
        done_cycle1 = done_cycle;
        $display("  pred1 = %0d", pred1);
        $display("  done_cycle1 = %0d", done_cycle1);
        $display("");

        //----- Inter-inference state snapshot -----
        @(negedge clk); @(negedge clk);  // settle 2 cycles after done
        snapshot_state("State BEFORE inference 2 (after inference 1 done)");
        $display("");

        //=================== INFERENCE 2 ===================
        $display("=== Inference 2 (no reset, no re-boot, same image) ===");
        load_image();
        cycle_counting    = 1'b0;
        cycle_after_start = 0;
        pulse_start();
        wait_for_done(32'd2000000, cycles_waited);
        pred2       = captured_pred;
        done_cycle2 = done_cycle;
        $display("  pred2 = %0d", pred2);
        $display("  done_cycle2 = %0d", done_cycle2);
        $display("");

        //=================== ASSERTIONS ===================
        $display("============================================================");
        $display("Sanity assertions:");

        if (pred1 == `EXPECTED_PRED) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T_a pred1 = %0d (== expected golden %0d)",
                     pred1, `EXPECTED_PRED);
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T_a pred1 = %0d (expected %0d)",
                     pred1, `EXPECTED_PRED);
        end

        if (done_cycle1 == `EXPECTED_CYCLES) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T_b done_cycle1 = %0d (== Step 9 baseline)",
                     done_cycle1);
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T_b done_cycle1 = %0d (expected %0d)",
                     done_cycle1, `EXPECTED_CYCLES);
        end

        if (pred2 == `EXPECTED_PRED) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T_c pred2 = %0d (== expected golden %0d)",
                     pred2, `EXPECTED_PRED);
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T_c pred2 = %0d (expected %0d) *** BATCH-READY BROKEN ***",
                     pred2, `EXPECTED_PRED);
        end

        if (done_cycle2 == done_cycle1) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T_d done_cycle2 = done_cycle1 = %0d (timing invariance)",
                     done_cycle2);
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T_d done_cycle2 = %0d != done_cycle1 = %0d (timing drift between inferences)",
                     done_cycle2, done_cycle1);
        end

        if (pred1 == pred2) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T_e pred1 == pred2");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T_e pred1 != pred2");
        end

        $display("");
        $display("============================================================");
        $display("Total: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count == 0)
            $display("RESULT: BATCH-READY  (back-to-back inference works without reset)");
        else
            $display("RESULT: NOT BATCH-READY  (need fallback A: re-boot, or fallback B: full reset)");
        $display("============================================================");

        $finish;
    end

    initial begin
        #500000000;
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule
