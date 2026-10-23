// ============================================================
// tb_conv_engine.v   (Paper 2 v2)
// ------------------------------------------------------------
// Integration test for conv_engine v2 + pcm_imc_unit + sram_array
// + pcm_crossbar + sram_mac + combiner + simple bias/feature mocks.
//
// Test setup (conv1-like, simplified):
//   IN_H = IN_W = 5, IN_CH = 1
//   OUT_H = OUT_W = 1, OUT_CH = 1
//   KERNEL = 5, PADDING = 0
//   So we have ONE output pixel, computed from a single 5×5 window.
//
// Synthetic data:
//   - All fmap pixels = 1
//   - All weights = 1 (for simplicity, but we can't easily control
//     real pcm_imc_unit weights, so we use the SYNTHETIC pattern
//     baked into sram_array.v / pcm_crossbar.v)
//   - bias = 0, RSHIFT = 0 (no quantization shift)
//
// With synthetic pattern (sram_array's weight values for layer 0 conv1):
//   - Even orig_addr (a=0,2,4..148) -> in SRAM, slot=a/2, w=(slot)
//   - Odd  orig_addr (a=1,3,5..149) -> in PCM,  slot=(a-1)/2, w=(slot)
//   But conv1 has ZERO PCM cells (synthetic pattern: map_conv1[A]=INV)
//   So we're testing that:
//     - All addrs return SRAM weights for conv1
//     - PCM contribution = 0
//
// For our test (IN_CH=1, KERNEL=5, OUT_CH=1):
//   K2=25, IC_KK=25
//   addr(oc, ic, kh, kw) = oc*25 + ic*25 + kh*5 + kw
//   For oc=0, ic=0: addrs = 0, 1, 2, ..., 24
//   - Even (0,2,4,...,24)  = 13 addrs in SRAM
//   - Odd  (1,3,5,...,23)  = 12 addrs not in SRAM (and not in PCM either
//     for conv1 - so contribute 0 to MAC)
//   SRAM weights for those slots:
//     slot=0 -> w=0, slot=1 -> w=1, slot=2 -> w=2, ..., slot=12 -> w=12
//   With V=1 for all 25 pixels:
//     MAC = 1*0 + 1*1 + 1*2 + ... + 1*12 = 0+1+...+12 = 78
//   bias=0, RSHIFT=0, ReLU(78) = 78, saturate -> 78
// ============================================================

`timescale 1ns / 1ps

module tb_conv_engine;

    localparam IN_H    = 5;
    localparam IN_W    = 5;
    localparam IN_CH   = 1;
    localparam OUT_CH  = 1;
    localparam KERNEL  = 5;
    localparam PADDING = 0;
    localparam OUT_H   = 1;
    localparam OUT_W   = 1;
    localparam DATA_W  = 8;
    localparam ACC_W   = 32;
    localparam K_PAR   = 25;
    localparam IMC_ACC_W = 24;

    reg                       clk;
    reg                       rst_n;
    reg                       start;
    reg  [2:0]                layer_id;
    reg  [4:0]                rshift_dyn;
    reg                       cfg_enable_drift;
    reg  [15:0]               cfg_drift_t;

    // conv_engine <-> pcm_imc_unit
    wire [K_PAR*DATA_W-1:0]    imc_v_bus;
    wire [K_PAR*16-1:0]        imc_addr_bus;
    wire                       imc_start;
    wire                       imc_enable_drift;
    wire [15:0]                imc_drift_t;
    wire signed [IMC_ACC_W-1:0] imc_mac_result;
    wire                       imc_result_valid;

    // conv_engine <-> feature_buffer (mock)
    wire [12:0]                fmap_addr;
    // fmap_in is now a wire

    // conv_engine <-> bias (mock)
    wire [7:0]                 bias_addr;
    // bias_in is now a wire

    // conv_engine -> ofmap (capture)
    wire [12:0]                out_addr;
    wire signed [DATA_W-1:0]   out_data;
    wire                       out_en;
    wire                       done;
    wire                       mac_timeout;

    // ----- Mock feature buffer: all pixels = 1 -----
    wire signed [DATA_W-1:0] fmap_in_w = 8'sd1;

    // ----- Mock bias: 0 -----
    wire signed [ACC_W-1:0] bias_in_w = 32'sd0;

    // ----- DUT -----
    conv_engine #(
        .IN_H(IN_H), .IN_W(IN_W), .IN_CH(IN_CH), .OUT_CH(OUT_CH),
        .KERNEL(KERNEL), .PADDING(PADDING),
        .OUT_H(OUT_H), .OUT_W(OUT_W),
        .RSHIFT(0)
    ) DUT (
        .clk(clk), .rst_n(rst_n), .start(start),
        .layer_id(layer_id), .rshift_dyn(rshift_dyn),

        .imc_v_bus(imc_v_bus), .imc_addr_bus(imc_addr_bus),
        .imc_start(imc_start),
        .imc_enable_drift(imc_enable_drift), .imc_drift_t(imc_drift_t),
        .imc_mac_result(imc_mac_result), .imc_result_valid(imc_result_valid),

        .fmap_addr(fmap_addr), .fmap_in(fmap_in_w),
        .bias_addr(bias_addr), .bias_in(bias_in_w),

        .out_addr(out_addr), .out_data(out_data), .out_en(out_en),
        .cfg_enable_drift(cfg_enable_drift), .cfg_drift_t(cfg_drift_t),
        .done(done), .mac_timeout(mac_timeout)
    );

    // ----- pcm_imc_unit (real DUT inside the integration) -----
    pcm_imc_unit #(
        .K(K_PAR),
        .DATA_WIDTH(DATA_W),
        .ADDR_WIDTH(16),
        .ACC_WIDTH(IMC_ACC_W),
        .PCM_LATENCY(8),
        .SRAM_LATENCY(2)
    ) U_IMC (
        .clk(clk), .rst_n(rst_n), .start(imc_start),
        .layer_id(layer_id),
        .v_bus(imc_v_bus), .addr_bus(imc_addr_bus),
        .enable_drift(imc_enable_drift), .drift_t(imc_drift_t),
        .mac_result(imc_mac_result), .result_valid(imc_result_valid)
    );

    // ----- Capture out_en pulses -----
    // Use combinational sampling: anytime we see out_en, latch the value
    reg signed [DATA_W-1:0] captured_out;
    reg                     captured_seen;
    reg [12:0]              captured_addr;
    initial begin
        captured_out  = 0;
        captured_seen = 0;
        captured_addr = 0;
    end
    // Sample on the falling edge so we see the registered values from
    // the just-completed posedge cycle. Use blocking with #1 delay to
    // avoid NBA race conditions.
    always @(negedge clk) begin
        #1;
        if (out_en) begin
            captured_out  = out_data;
            captured_addr = out_addr;
            captured_seen = 1;
        end
    end

    // ----- Clock -----
    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task chk;
        input [127:0] name;
        input cond;
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("  [PASS] %0s", name);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    initial begin
        $dumpfile("sim/tb_conv_engine.vcd");
        $dumpvars(0, tb_conv_engine);

        $display("============================================================");
        $display("tb_conv_engine - synthetic 5x5 single-pixel conv");
        $display("============================================================");
        $display("Setup: IN=5x5, OUT=1x1x1, KERNEL=5, PADDING=0");
        $display("All fmap=1, bias=0, RSHIFT=0, conv1 layer (synthetic)");
        $display("");
        $display("Expected MAC: only SRAM contributes (conv1 has no PCM)");
        $display("  addrs 0..24, even -> SRAM slots 0..12, w = slot");
        $display("  Sum = 0+1+2+...+12 = 78");
        $display("============================================================");

        rst_n           = 0;
        start           = 0;
        layer_id        = 3'd0;          // conv1
        rshift_dyn      = 5'b0;          // use parameter RSHIFT=0
        cfg_enable_drift = 0;
        cfg_drift_t     = 16'd1000;

        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;
        @(posedge clk);

        // Issue start
        @(negedge clk); start = 1;
        @(posedge clk);
        @(negedge clk); start = 0;

        // Wait for done (or timeout)
        begin: wait_done_loop
            integer wait_iter;
            for (wait_iter = 0; wait_iter < 1000; wait_iter = wait_iter + 1) begin
                @(posedge clk);
                if (done) disable wait_done_loop;
            end
        end

        if (!done) begin
            $display("[FAIL] watchdog: conv didn't finish");
            $finish;
        end
        $display("[INFO] conv done detected at time %0t", $time);

        @(posedge clk); #1;
        $display("");
        $display("============================================================");
        $display("Result: out_data=%0d, out_addr=%0d", $signed(captured_out), captured_addr);
        $display("Expected: out_data=78, out_addr=0");
        $display("============================================================");

        chk("captured_seen", captured_seen == 1);
        chk("out_addr == 0", captured_addr == 0);
        chk("out_data == 78", captured_out == 78);
        chk("no mac_timeout", mac_timeout == 0);

        $display("");
        $display("Summary: %0d passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("[OK] tb_conv_engine PASSED");
        else               $display("[FAIL] tb_conv_engine FAILED");
        $finish;
    end

endmodule
