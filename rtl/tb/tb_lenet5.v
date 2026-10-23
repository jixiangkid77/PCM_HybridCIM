// ============================================================
// tb_lenet5.v
// ------------------------------------------------------------
// END-TO-END test for the LeNet-5 inference accelerator.
//
// Scenario:
//   1. Reset
//   2. Preload a 28x28 input "image" (synthetic pattern) into
//      the feature buffer's A side via the image_we port
//   3. Pulse start
//   4. Wait for done
//   5. Verify done was asserted, predicted_class is in [0,9]
//   6. Run a SECOND image through the same accelerator (no
//      reset) to verify the design recovers and re-runs cleanly
//   7. Verify both inferences produced a valid class
//
// What this proves (with current synthetic weights/biases):
//   - The full pipeline works end-to-end with NO testbench
//     stubs: only real RTL modules driving each other
//   - The design is re-runnable (multiple inferences without
//     reset)
//   - The system completes in roughly the expected number of
//     cycles (~1.3M per image)
//
// What this DOES NOT yet prove:
//   - Numerical equivalence to PyTorch. That requires real
//     INT8 calibrated weights + biases from Python Step 2,
//     loaded via $readmemh into weight_memory and bias_storage.
// ============================================================

`timescale 1ns / 1ps

module tb_lenet5;

    localparam DATA_W   = 8;
    localparam FADDR_W  = 13;

    reg clk, rst_n;
    reg start;

    // Image loading port
    reg                          image_we;
    reg  [FADDR_W-1:0]           image_addr;
    reg  signed [DATA_W-1:0]     image_data;

    wire                         done;
    wire [3:0]                   predicted_class;

    lenet5_top dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .done(done), .predicted_class(predicted_class),
        .image_we(image_we),
        .image_addr(image_addr),
        .image_data(image_data)
    );

    // Clock
    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    task check;
        input [31:0] expected;
        input [31:0] actual;
        input [8*48-1:0] label;
        begin
            if (actual === expected) begin
                $display("  [PASS] %0s : %0d", label, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s : got %0d (expected %0d)",
                         label, actual, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task check_in_range;
        input [31:0] actual;
        input [31:0] lo, hi;
        input [8*48-1:0] label;
        begin
            if (actual >= lo && actual <= hi) begin
                $display("  [PASS] %0s : %0d (in [%0d, %0d])",
                         label, actual, lo, hi);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s : %0d (expected in [%0d, %0d])",
                         label, actual, lo, hi);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // =========================================================
    // Image loader: drives image_we/addr/data for 784 cycles
    // =========================================================
    task load_image;
        input integer pattern_seed;
        integer p;
        reg signed [DATA_W-1:0] pixel;
        begin
            $display("  [LOAD] preloading 28x28 image (seed=%0d)", pattern_seed);
            for (p = 0; p < 784; p = p + 1) begin
                @(negedge clk);
                pixel = (p + pattern_seed) & 8'h7F;   // 0..127, deterministic
                image_we   = 1'b1;
                image_addr = p[FADDR_W-1:0];
                image_data = pixel;
                @(posedge clk);
            end
            @(negedge clk);
            image_we   = 1'b0;
            image_addr = 0;
            image_data = 0;
            $display("  [LOAD] done loading 784 pixels");
        end
    endtask

    // =========================================================
    // Run one inference: pulse start, wait for done, capture
    // =========================================================
    task run_inference;
        input  [8*48-1:0]  scenario_label;
        output [3:0]       captured_class;
        output integer     captured_cycles;
        integer cyc;
        reg     observed_done;
        begin
            $display("  [RUN] %0s starting inference...", scenario_label);
            @(negedge clk); start = 1'b1;
            @(posedge clk); @(negedge clk); start = 1'b0;

            cyc = 0;
            while (!done && cyc < 5000000) begin
                @(posedge clk);
                cyc = cyc + 1;
                if ((cyc % 200000) == 0) begin
                    $display("    [heartbeat] cyc=%0d, fsm.step=%0d, fsm.state=%0d",
                             cyc, dut.u_fsm.step_id, dut.u_fsm.state);
                end
            end
            // Capture before deassertion
            observed_done   = done;
            captured_class  = predicted_class;
            captured_cycles = cyc;
            $display("  [DONE] %0s : cycles=%0d, class=%0d (done=%0d)",
                     scenario_label, cyc, captured_class, observed_done);
            @(negedge clk);
        end
    endtask

    // =========================================================
    // Main
    // =========================================================
    reg [3:0]    class1, class2;
    integer      cycles1, cycles2;

    initial begin
        $dumpfile("tb_lenet5.vcd");
        $dumpvars(0, tb_lenet5);

        $display("============================================================");
        $display("  tb_lenet5 : END-TO-END LeNet-5 inference");
        $display("============================================================");
        $display("  (synthetic weights/biases -- structural verification only)");

        rst_n      = 0;
        start      = 0;
        image_we   = 0;
        image_addr = 0;
        image_data = 0;
        #23; rst_n = 1; #2;

        // ========================================================
        // INFERENCE 1
        // ========================================================
        $display("\n--- Inference #1 ---");
        load_image(0);
        run_inference("infer 1", class1, cycles1);

        // ========================================================
        // INFERENCE 2 (no reset; design must be re-runnable)
        // ========================================================
        $display("\n--- Inference #2 ---");
        load_image(57);    // different pattern
        run_inference("infer 2", class2, cycles2);

        // ========================================================
        // VERIFICATIONS
        // ========================================================
        $display("\n[Checks]");
        // 1) predicted_class in valid range [0,9]
        check_in_range(class1, 0, 9, "infer 1: class in [0,9]");
        check_in_range(class2, 0, 9, "infer 2: class in [0,9]");

        // 2) cycle count is roughly the expected ~1.28M per inference
        //    Allow generous range [800k, 2M]
        check_in_range(cycles1, 800000, 2000000, "infer 1: cycles in expected range");
        check_in_range(cycles2, 800000, 2000000, "infer 2: cycles in expected range");

        // 3) Both inferences reached done (implicit -- if not, run_inference
        //    would have hit the 5M timeout). Just confirm here.
        check(1, (cycles1 < 5000000) ? 1 : 0, "infer 1 did not timeout");
        check(1, (cycles2 < 5000000) ? 1 : 0, "infer 2 did not timeout");

        // 4) Optional informational: did both produce the SAME class?
        //    (with synthetic weights this is possible, but if classes
        //    differ that's a stronger signal that data path is alive)
        $display("\n[Info]");
        if (class1 === class2) begin
            $display("  [INFO] both inferences produced class %0d (same)", class1);
            $display("         -- with synthetic weights this is plausible");
        end else begin
            $display("  [INFO] infer1=%0d, infer2=%0d (different classes)", class1, class2);
            $display("         -- confirms input affects output (data path alive)");
        end

        // ========================================================
        // SUMMARY
        // ========================================================
        $display("\n============================================================");
        $display("  Summary : %0d passed, %0d failed", pass_count, fail_count);
        $display("============================================================");
        if (fail_count == 0) begin
            $display("  ALL TESTS PASSED");
            $display("");
            $display("  =================================================");
            $display("  END-TO-END LeNet-5 INFERENCE WORKING IN HARDWARE");
            $display("  =================================================");
        end else begin
            $display("  SOME TESTS FAILED");
        end

        $finish;
    end

    // Hard timeout safety net
    initial begin
        #100000000;   // 100ms simulated time = ~10M cycles
        $display("\n[ERROR] Hard timeout!");
        $finish;
    end

endmodule
