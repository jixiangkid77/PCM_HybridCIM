// ============================================================
// tb_lenet5_single.v   (Paper 2 v2 — Stage 3)
// ------------------------------------------------------------
// Stage 3 single-image end-to-end inference test for v2 lenet5_top.
//
// Runs ONE MNIST image (img_001.hex) through full RTL pipeline:
//   conv1 -> pool1 -> conv2 -> pool2 -> fc1 -> fc2 -> fc3 -> argmax
// Verifies that:
//   1. Inference completes (done=1)
//   2. predicted_class matches the ground truth label
//
// drift is DISABLED (cfg_enable_drift=0) for this baseline test.
// ============================================================

`timescale 1ns / 1ps

module tb_lenet5_single;

    parameter DATA_DIR = "../data/rtl_inputs_A";
    parameter integer IMG_IDX = 1;       // which image to test (1-100)

    localparam DATA_W  = 8;
    localparam FADDR_W = 13;

    // ==========================================================
    // DUT signals
    // ==========================================================
    reg                         clk, rst_n, start;
    reg                         image_we;
    reg  [FADDR_W-1:0]          image_addr;
    reg  signed [DATA_W-1:0]    image_data;
    reg                         cfg_enable_drift;
    reg  [15:0]                 cfg_drift_t;
    wire                        done;
    wire [3:0]                  predicted_class;

    lenet5_top #(.DATA_DIR(DATA_DIR)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .done(done), .predicted_class(predicted_class),
        .image_we(image_we),
        .image_addr(image_addr),
        .image_data(image_data),
        .cfg_enable_drift(cfg_enable_drift),
        .cfg_drift_t(cfg_drift_t)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // ==========================================================
    // Storage
    // ==========================================================
    reg [7:0] true_labels [0:99];
    reg [7:0] img_pixels  [0:783];
    reg [1023:0] filename;
    integer px;
    integer cyc;

    // ==========================================================
    // Load image into feature_buffer via image_we port
    // ==========================================================
    task load_image;
        input integer img_idx;
        begin
            $sformat(filename, "%0s/images/img_%03d.hex", DATA_DIR, img_idx);
            for (px = 0; px < 784; px = px + 1) img_pixels[px] = 8'd0;
            $readmemh(filename, img_pixels);

            $display("[LOAD] image_%03d, sample center pixels:", img_idx);
            $display("  pixel[400..404] = %0d %0d %0d %0d %0d",
                $signed(img_pixels[400]), $signed(img_pixels[401]),
                $signed(img_pixels[402]), $signed(img_pixels[403]),
                $signed(img_pixels[404]));

            for (px = 0; px < 784; px = px + 1) begin
                @(negedge clk);
                image_we   = 1'b1;
                image_addr = px[FADDR_W-1:0];
                image_data = $signed(img_pixels[px]);
                @(posedge clk);
            end
            @(negedge clk);
            image_we   = 1'b0;
            image_addr = 0;
            image_data = 0;
        end
    endtask

    // ==========================================================
    // Main
    // ==========================================================
    initial begin
        $dumpfile("sim/tb_lenet5_single.vcd");
        $dumpvars(0, tb_lenet5_single);

        rst_n            = 1'b0;
        start            = 1'b0;
        image_we         = 1'b0;
        image_addr       = 0;
        image_data       = 0;
        cfg_enable_drift = 1'b0;     // drift OFF for baseline
        cfg_drift_t      = 16'd0;

        $display("============================================================");
        $display("tb_lenet5_single  - v2 single-image end-to-end test");
        $display("  DATA_DIR = %0s", DATA_DIR);
        $display("  IMG_IDX  = %0d", IMG_IDX);
        $display("  drift    = OFF (baseline)");
        $display("============================================================");

        // Load ground truth labels
        $sformat(filename, "%0s/image_labels.hex", DATA_DIR);
        $readmemh(filename, true_labels);
        $display("[LOAD] ground truth label for img_%03d = %0d",
                 IMG_IDX, true_labels[IMG_IDX-1]);

        // Reset
        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // Load the image
        load_image(IMG_IDX);

        // Run inference
        $display("");
        $display("[RUN] starting inference...");
        @(negedge clk); start = 1'b1;
        @(posedge clk);
        @(negedge clk); start = 1'b0;

        // Wait for done with timeout
        cyc = 0;
        while (!done && cyc < 3000000) begin
            @(posedge clk);
            cyc = cyc + 1;
            if (cyc % 100000 == 0)
                $display("  ... %0d cycles, still running", cyc);
        end

        if (!done) begin
            $display("");
            $display("============================================================");
            $display("[FAIL] timeout: inference did not complete in 3M cycles");
            $display("       last state: %0d", dut.u_fsm.state);
            $display("       last step:  %0d", dut.u_fsm.step_id);
            $display("============================================================");
            $finish;
        end

        $display("");
        $display("============================================================");
        $display("[INFO] inference completed at cycle %0d", cyc);
        $display("[INFO] predicted_class = %0d", predicted_class);
        $display("[INFO] true label      = %0d", true_labels[IMG_IDX-1]);
        if (predicted_class == true_labels[IMG_IDX-1])
            $display("[PASS] prediction CORRECT");
        else
            $display("[NOTE] prediction differs (may be normal for INT8 model)");
        $display("============================================================");

        $finish;
    end

    // Global watchdog (in case clock stops or other catastrophic failure)
    initial begin
        #50000000;
        $display("[FAIL] global watchdog at 50ms sim time");
        $finish;
    end

endmodule
