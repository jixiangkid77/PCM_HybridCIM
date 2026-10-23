// ============================================================
// tb_lenet5_100images.v   (Paper 2 v2 — Stage 4)
// ------------------------------------------------------------
// Runs 100 MNIST test images through the v2 lenet5_top pipeline,
// compares each predicted_class against the ground truth label
// from image_labels.hex, and reports overall accuracy.
//
// IMPORTANT: must compile with -DLOAD_REAL_DATA flag.
//
// Configurable parameters:
//   NUM_IMAGES:  how many images to test (1..100)
//   START_IMAGE: first image index (default 1)
//   ENABLE_DRIFT: 0 = baseline (no drift), 1 = with drift
//   DRIFT_T:     time elapsed (used only if ENABLE_DRIFT=1)
// ============================================================

`timescale 1ns / 1ps

module tb_lenet5_100images;

    parameter DATA_DIR     = "../data/rtl_inputs_A";
    parameter MODEL_NAME   = "A";
    parameter integer NUM_IMAGES   = 100;
    parameter integer START_IMAGE  = 1;
    parameter integer ENABLE_DRIFT = 0;
    parameter [15:0]  DRIFT_T      = 16'd1000;

    localparam DATA_W  = 8;
    localparam FADDR_W = 13;

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

    reg [7:0] true_labels [0:99];
    reg [7:0] img_pixels  [0:783];
    reg [1023:0] filename;

    integer correct;
    integer total;
    integer img_idx;
    integer px;
    integer cyc;
    integer total_cycles;
    reg [3:0] captured_class;

    // Per-class breakdown
    integer pred_count [0:9];
    integer true_count [0:9];
    integer correct_per_class [0:9];

    // ==========================================================
    // Load image
    // ==========================================================
    task load_image;
        input integer idx;
        begin
            $sformat(filename, "%0s/images/img_%03d.hex", DATA_DIR, idx);
            for (px = 0; px < 784; px = px + 1) img_pixels[px] = 8'd0;
            $readmemh(filename, img_pixels);
            for (px = 0; px < 784; px = px + 1) begin
                @(negedge clk);
                image_we   = 1'b1;
                image_addr = px[FADDR_W-1:0];
                image_data = $signed(img_pixels[px]);
                @(posedge clk);
            end
            @(negedge clk);
            image_we   = 1'b0;
        end
    endtask

    // ==========================================================
    // Run one inference
    // ==========================================================
    task run_one_inference;
        output [3:0]   class_out;
        output integer cycles_out;
        integer        local_cyc;
        begin
            @(negedge clk); start = 1'b1;
            @(posedge clk); @(negedge clk); start = 1'b0;

            local_cyc = 0;
            while (!done && local_cyc < 3000000) begin
                @(posedge clk);
                local_cyc = local_cyc + 1;
            end

            class_out  = predicted_class;
            cycles_out = local_cyc;
            @(negedge clk);  // Drain done pulse
        end
    endtask

    // ==========================================================
    // Main
    // ==========================================================
    integer i;
    initial begin
        rst_n            = 1'b0;
        start            = 1'b0;
        image_we         = 1'b0;
        image_addr       = 0;
        image_data       = 0;
        cfg_enable_drift = ENABLE_DRIFT[0];
        cfg_drift_t      = DRIFT_T;

        $display("============================================================");
        $display(" tb_lenet5_100images : v2 RTL end-to-end MNIST accuracy");
        $display("============================================================");
        $display("  DATA_DIR      = %0s", DATA_DIR);
        $display("  MODEL         = %0s", MODEL_NAME);
        $display("  NUM_IMAGES    = %0d", NUM_IMAGES);
        $display("  START_IMAGE   = %0d", START_IMAGE);
        $display("  ENABLE_DRIFT  = %0d", ENABLE_DRIFT);
        if (ENABLE_DRIFT) $display("  DRIFT_T       = %0d", DRIFT_T);
        $display("============================================================");

        // Load ground truth labels
        $sformat(filename, "%0s/image_labels.hex", DATA_DIR);
        $readmemh(filename, true_labels);

        // Reset counters
        correct      = 0;
        total        = 0;
        total_cycles = 0;
        for (i = 0; i < 10; i = i + 1) begin
            pred_count[i]        = 0;
            true_count[i]        = 0;
            correct_per_class[i] = 0;
        end

        // Reset DUT
        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // Loop over images
        for (img_idx = START_IMAGE;
             img_idx < START_IMAGE + NUM_IMAGES;
             img_idx = img_idx + 1)
        begin
            load_image(img_idx);
            run_one_inference(captured_class, cyc);

            total            = total + 1;
            total_cycles     = total_cycles + cyc;
            true_count[true_labels[img_idx-1]]   = true_count[true_labels[img_idx-1]] + 1;
            pred_count[captured_class]            = pred_count[captured_class] + 1;

            if (captured_class == true_labels[img_idx-1]) begin
                correct = correct + 1;
                correct_per_class[true_labels[img_idx-1]] = correct_per_class[true_labels[img_idx-1]] + 1;
                $display("  img_%03d: pred=%0d true=%0d  [PASS]  (%0d cyc)",
                    img_idx, captured_class, true_labels[img_idx-1], cyc);
            end else begin
                $display("  img_%03d: pred=%0d true=%0d  [FAIL]  (%0d cyc)",
                    img_idx, captured_class, true_labels[img_idx-1], cyc);
            end
        end

        // Final summary
        $display("");
        $display("============================================================");
        $display(" RESULTS  (Model %0s, drift=%0d)", MODEL_NAME, ENABLE_DRIFT);
        $display("============================================================");
        $display("  Accuracy : %0d / %0d = %0d.%02d %%",
            correct, total,
            (100*correct) / total,
            ((10000*correct) / total) % 100);
        $display("  Avg cycles per image: %0d", total_cycles / total);
        $display("");
        $display("  Per-class breakdown:");
        $display("    class    true   pred   correct");
        for (i = 0; i < 10; i = i + 1) begin
            $display("    %4d   %5d  %5d   %5d",
                i, true_count[i], pred_count[i], correct_per_class[i]);
        end
        $display("============================================================");
        $finish;
    end

    initial begin
        #100000000000;  // 100 sec sim time global timeout
        $display("[FAIL] global watchdog");
        $finish;
    end

endmodule
