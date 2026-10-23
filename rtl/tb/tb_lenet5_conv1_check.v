// ============================================================
// tb_lenet5_conv1_check.v   (Paper 2 v2 — Stage 3 verification)
// ------------------------------------------------------------
// Runs single image (img_001) through lenet5_top, then dumps
// the conv1 output from feature_buffer and compares against
// Python ground truth (conv1_out_img1_ref.hex).
//
// IMPORTANT: must be compiled with -DLOAD_REAL_DATA flag,
// otherwise weights/biases load synthetic patterns.
// ============================================================

`timescale 1ns / 1ps

module tb_lenet5_conv1_check;

    parameter DATA_DIR = "../data/rtl_inputs_A";
    parameter integer IMG_IDX = 1;

    localparam DATA_W  = 8;
    localparam FADDR_W = 13;
    localparam CONV1_OUT_SIZE = 4704;  // 6 * 28 * 28

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

    reg [7:0] img_pixels [0:783];
    reg [7:0] conv1_ref  [0:CONV1_OUT_SIZE-1];
    reg [7:0] conv1_rtl  [0:CONV1_OUT_SIZE-1];
    reg [1023:0] filename;
    integer px, i;
    integer cyc;
    integer mismatch_cnt;

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
        $display("tb_lenet5_conv1_check  - dump conv1 output for verification");
        $display("============================================================");

        $sformat(filename, "%0s/conv1_out_img1_ref.hex", DATA_DIR);
        $readmemh(filename, conv1_ref);
        $display("[LOAD] Python ref conv1_out: first 5 = %0d %0d %0d %0d %0d, last = %0d",
            $signed(conv1_ref[0]), $signed(conv1_ref[1]), $signed(conv1_ref[2]),
            $signed(conv1_ref[3]), $signed(conv1_ref[4]), $signed(conv1_ref[CONV1_OUT_SIZE-1]));

        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (3) @(posedge clk);
        load_image(IMG_IDX);

        $display("[RUN] starting inference...");
        @(negedge clk); start = 1'b1;
        @(posedge clk);
        @(negedge clk); start = 1'b0;

        // Wait until step_id advances past 0 (conv1 done)
        cyc = 0;
        while (dut.u_fsm.step_id == 4'd0 && cyc < 1000000) begin
            @(posedge clk);
            cyc = cyc + 1;
        end
        $display("[INFO] conv1 finished at cycle %0d (step_id is now %0d)",
            cyc, dut.u_fsm.step_id);
        $display("[INFO] feature_buffer.role_sel = %b", dut.u_fbuf.role_sel);

        // After conv1 done + fbuf_swap, conv1 output is on the "read" side.
        if (dut.u_fbuf.role_sel == 1'b0) begin
            $display("[DUMP] conv1 output is in mem_B");
            for (i = 0; i < CONV1_OUT_SIZE; i = i + 1)
                conv1_rtl[i] = dut.u_fbuf.mem_B[i];
        end else begin
            $display("[DUMP] conv1 output is in mem_A");
            for (i = 0; i < CONV1_OUT_SIZE; i = i + 1)
                conv1_rtl[i] = dut.u_fbuf.mem_A[i];
        end

        $display("[DUMP] RTL conv1_out: first 5 = %0d %0d %0d %0d %0d, last = %0d",
            $signed(conv1_rtl[0]), $signed(conv1_rtl[1]), $signed(conv1_rtl[2]),
            $signed(conv1_rtl[3]), $signed(conv1_rtl[4]), $signed(conv1_rtl[CONV1_OUT_SIZE-1]));

        // Compare
        mismatch_cnt = 0;
        for (i = 0; i < CONV1_OUT_SIZE; i = i + 1) begin
            if (conv1_rtl[i] !== conv1_ref[i]) begin
                if (mismatch_cnt < 20) begin
                    $display("  [DIFF] addr=%0d (oc=%0d, oh=%0d, ow=%0d): RTL=%0d  REF=%0d",
                        i, i/784, (i%784)/28, i%28,
                        $signed(conv1_rtl[i]), $signed(conv1_ref[i]));
                end
                mismatch_cnt = mismatch_cnt + 1;
            end
        end

        $display("");
        $display("============================================================");
        if (mismatch_cnt == 0) begin
            $display("[PASS] conv1 output matches Python reference EXACTLY");
            $display("       v2 RTL conv_engine + IMC working correctly.");
        end else begin
            $display("[FAIL] %0d / %0d entries differ between RTL and Python ref",
                mismatch_cnt, CONV1_OUT_SIZE);
            $display("       (Did you compile with -DLOAD_REAL_DATA?)");
        end
        $display("============================================================");
        $finish;
    end

    initial begin
        #100000000;
        $display("[FAIL] watchdog timeout");
        $finish;
    end

endmodule
