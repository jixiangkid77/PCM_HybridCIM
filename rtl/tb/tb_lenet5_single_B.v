// ============================================================
// tb_lenet5_single_B.v   (Paper 2 v2 — Model B variant)
// ------------------------------------------------------------
// Same as tb_lenet5_single.v but loads Model B data
// (../data/rtl_inputs_B/) AND passes Model B's SLOTS_*/PSLOT_*
// partition sizes to lenet5_top.
//
// Model B partitioning (from 03_split_protected.py output, Model B):
//   SLOTS:  conv1=150, conv2=860,  fc1=479, fc2=745, fc3=840
//   PSLOT:  conv1=0,   conv2=1540, fc1=47521, fc2=9335, fc3=0
//
// IMPORTANT: must compile with -DLOAD_REAL_DATA flag.
// ============================================================

`timescale 1ns / 1ps

module tb_lenet5_single_B;

    parameter DATA_DIR = "../data/rtl_inputs_B";
    parameter integer IMG_IDX = 1;

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

    // Pass Model B's partition sizes to lenet5_top
    // (matches 03_split_protected.py output for Model B)
    lenet5_top #(
        .DATA_DIR(DATA_DIR),
        .SLOTS_CONV1(150),
        .SLOTS_CONV2(860),
        .SLOTS_FC1(479),
        .SLOTS_FC2(745),
        .SLOTS_FC3(840),
        .PSLOT_CONV1(0),
        .PSLOT_CONV2(1540),
        .PSLOT_FC1(47521),
        .PSLOT_FC2(9335),
        .PSLOT_FC3(0)
    ) dut (
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
    integer px;
    integer cyc;

    task load_image;
        input integer img_idx;
        begin
            $sformat(filename, "%0s/images/img_%03d.hex", DATA_DIR, img_idx);
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
            image_addr = 0;
            image_data = 0;
        end
    endtask

    initial begin
        rst_n            = 1'b0;
        start            = 1'b0;
        image_we         = 1'b0;
        image_addr       = 0;
        image_data       = 0;
        cfg_enable_drift = 1'b0;
        cfg_drift_t      = 16'd0;

        $display("============================================================");
        $display("tb_lenet5_single_B  - Model B single-image test");
        $display("  DATA_DIR = %0s", DATA_DIR);
        $display("  IMG_IDX  = %0d", IMG_IDX);
        $display("  Partitioning: SLOTS=150/860/479/745/840  PSLOT=0/1540/47521/9335/0");
        $display("  drift    = OFF (baseline)");
        $display("============================================================");

        $sformat(filename, "%0s/image_labels.hex", DATA_DIR);
        $readmemh(filename, true_labels);
        $display("[LOAD] ground truth label for img_%03d = %0d",
                 IMG_IDX, true_labels[IMG_IDX-1]);

        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (3) @(posedge clk);

        load_image(IMG_IDX);

        $display("");
        $display("[RUN] starting inference...");
        @(negedge clk); start = 1'b1;
        @(posedge clk);
        @(negedge clk); start = 1'b0;

        cyc = 0;
        while (!done && cyc < 3000000) begin
            @(posedge clk);
            cyc = cyc + 1;
            if (cyc % 100000 == 0)
                $display("  ... %0d cycles, still running", cyc);
        end

        if (!done) begin
            $display("[FAIL] timeout: inference did not complete in 3M cycles");
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
            $display("[NOTE] prediction differs (Model B is known to be weaker)");
        $display("============================================================");

        $finish;
    end

    initial begin
        #50000000;
        $display("[FAIL] global watchdog");
        $finish;
    end

endmodule
