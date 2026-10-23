// ============================================================
// tb_pcm_imc_real_smoke.v   (Paper 2 v2 ¡ª auto-generated)
// ------------------------------------------------------------
// Real-data smoke test: load weights_conv2_*.hex and
// addr_to_slot_conv2_*.hex via $readmemh, then verify that
// pcm_imc_unit produces the same MAC as the Python reference.
//
// Test vector: V = [1..25], orig_addr = [0..24], layer = conv2
// Expected MAC = -556
//   (SRAM contribution = -564, PCM contribution = 8)
// ============================================================

`timescale 1ns / 1ps

module tb_pcm_imc_real_smoke;

    localparam K = 25;
    localparam DW = 8;
    localparam AW = 16;
    localparam ACC = 24;

    reg                       clk;
    reg                       rst_n;
    reg                       start;
    reg  [2:0]                layer_id;
    reg  [K*DW-1:0]           v_bus;
    reg  [K*AW-1:0]           addr_bus;
    reg                       enable_drift;
    reg  [15:0]               drift_t;
    wire signed [ACC-1:0]     mac_result;
    wire                      result_valid;

    pcm_imc_unit #(.DATA_DIR("../data/rtl_inputs_A")) DUT (
        .clk(clk), .rst_n(rst_n), .start(start),
        .layer_id(layer_id), .v_bus(v_bus), .addr_bus(addr_bus),
        .enable_drift(enable_drift), .drift_t(drift_t),
        .mac_result(mac_result), .result_valid(result_valid)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer wait_cnt;

    initial begin
        $dumpfile("sim/tb_pcm_imc_real_smoke.vcd");
        $dumpvars(0, tb_pcm_imc_real_smoke);

        $display("============================================================");
        $display("tb_pcm_imc_real_smoke");
        $display("  V = [1, 2, 3, ..., 25]");
        $display("  addr = [0, 1, 2, ..., 24], layer = conv2");
        $display("  expected MAC = -556  (SRAM=-564 + PCM=8)");
        $display("============================================================");

        rst_n = 0;
        start = 0;
        layer_id = 3'd1;  // conv2
        enable_drift = 0;
        drift_t = 16'd1000;
        // Pack V and addrs (channel 0 in low bits)
        v_bus    = { 8'd25, 8'd24, 8'd23, 8'd22, 8'd21, 8'd20, 8'd19, 8'd18, 8'd17, 8'd16, 8'd15, 8'd14, 8'd13, 8'd12, 8'd11, 8'd10, 8'd9, 8'd8, 8'd7, 8'd6, 8'd5, 8'd4, 8'd3, 8'd2, 8'd1 };
        addr_bus = { 16'd24, 16'd23, 16'd22, 16'd21, 16'd20, 16'd19, 16'd18, 16'd17, 16'd16, 16'd15, 16'd14, 16'd13, 16'd12, 16'd11, 16'd10, 16'd9, 16'd8, 16'd7, 16'd6, 16'd5, 16'd4, 16'd3, 16'd2, 16'd1, 16'd0 };
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;
        @(posedge clk);

        @(negedge clk); start = 1;
        @(posedge clk);
        @(negedge clk); start = 0;

        wait_cnt = 0;
        while (!result_valid && wait_cnt < 50) begin
            @(posedge clk);
            wait_cnt = wait_cnt + 1;
        end
        #1;

        $display("");
        $display("RTL mac_result = %0d", $signed(mac_result));
        $display("Python ref     = -556");

        if ($signed(mac_result) == -556) begin
            $display("[OK] real-data smoke test PASSED");
        end else begin
            $display("[FAIL] mismatch! diff = %0d", $signed(mac_result) - -556);
        end
        $finish;
    end

    initial begin
        #50000;
        $display("[FAIL] watchdog timeout");
        $finish;
    end

endmodule
