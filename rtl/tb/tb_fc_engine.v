// ============================================================
// tb_fc_engine.v   (Paper 2 v2)
// ------------------------------------------------------------
// Integration test for fc_engine v2 + pcm_imc_unit + sram_array
// + pcm_crossbar + sram_mac + combiner.
//
// Test setup: small fc layer to keep simulation fast
//   IN_DIM = 25, OUT_DIM = 2     (reuses synthetic pattern weights)
//   layer_id = 0 (conv1) - synthetic pattern: even addrs in SRAM
//
// fc1 layer in real LeNet-5 has IN=400, OUT=120; fc2: 120->84;
// fc3: 84->10. We use a tiny synthetic config to verify FSM
// correctness without long simulation runs.
//
// Synthetic data:
//   - fmap[i] = i+1 (so fmap = [1, 2, ..., 25])
//   - layer_id = 0 (conv1 synthetic): even addrs in SRAM, slot=addr/2,
//     w_sram = (slot) lower 8 bits
//   - bias = 0, RSHIFT = 0
//
// For oc=0, IN=25:
//   addrs = 0..24 (sub-bank 0 only)
//   - even addrs (0,2,4,...,24) in SRAM, slots 0..12, w = 0,1,...,12
//   - odd addrs not in conv1 PCM either → contribute 0
//   sum = sum_{k=0..12} v[2k]*w[k] = sum_{k=0..12} (2k+1)*k
//        = 1*0 + 3*1 + 5*2 + 7*3 + 9*4 + 11*5 + 13*6 + 15*7
//          + 17*8 + 19*9 + 21*10 + 23*11 + 25*12
//        = 0 + 3 + 10 + 21 + 36 + 55 + 78 + 105 + 136 + 171 + 210 + 253 + 300
//        = 1378
//   But wait, we set fmap[i] = i+1, so:
//     fmap[0]=1, fmap[1]=2, fmap[2]=3, ..., fmap[24]=25
//   For SRAM (addr=0,2,4..24): V indices = 0,2,4..24
//     V[0]=1, V[2]=3, V[4]=5, V[6]=7, V[8]=9, ..., V[24]=25
//     W (slot=0..12) = 0,1,2,...,12
//   Products: 1*0, 3*1, 5*2, 7*3, 9*4, 11*5, 13*6, 15*7, 17*8, 19*9, 21*10, 23*11, 25*12
//          = 0, 3, 10, 21, 36, 55, 78, 105, 136, 171, 210, 253, 300
//   Sum = 1378. But we saturate to INT8 = 127.
//
// For oc=1, IN=25:
//   addrs = 25..49
//   - even (26, 28, 30..48) in SRAM
//     But in conv1 synthetic, even addrs map to slot=addr/2.
//     map_conv1 has size N_CONV1=150, so addrs 25..49 are valid range.
//     SLOTS_CONV1=150, slot=addr/2 → 13, 14, 15..24
//   - even addrs 26, 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48 (12 addrs)
//   - odd: 25, 27, 29, 31, 33, 35, 37, 39, 41, 43, 45, 47, 49 (13 addrs)
//   For each even k in [26..48], slot = k/2, V = fmap[k - 25] (index into bank)
//     Hmm, V index in the V_bus is k - sb*K_PAR = k - 25 (for sb=1 of fc).
//     But we're testing oc=0 and oc=1 with IN_DIM=25 → just one sb=0.
//     So oc=1 still uses sb=0, V[i] = fmap[i] for i=0..24, but addr = 25..49.
//   Products: V_i * W_slot for even (k - 25) with slot=k/2
//     k=26 (V_idx=1, V=2)  slot=13, W=13  -> 2*13 = 26
//     k=28 (V_idx=3, V=4)  slot=14, W=14  -> 4*14 = 56
//     ... and so on for all 12 even.
//   Easier: in tb, just verify oc=0 and skip oc=1 detailed math.
//   oc=1 expected MAC = sum of V[i] * (i/2 + 13) for even i in [1..23] (i = k-25, k=26..48)
//     i=1, V=2, w=13: 26
//     i=3, V=4, w=14: 56
//     i=5, V=6, w=15: 90
//     i=7, V=8, w=16: 128
//     i=9, V=10, w=17: 170
//     i=11, V=12, w=18: 216
//     i=13, V=14, w=19: 266
//     i=15, V=16, w=20: 320
//     i=17, V=18, w=21: 378
//     i=19, V=20, w=22: 440
//     i=21, V=22, w=23: 506
//     i=23, V=24, w=24: 576
//   Sum = 26+56+90+128+170+216+266+320+378+440+506+576 = 3172, saturated to 127.
//
// So with RSHIFT=0, both outputs saturate to 127.
// To get different outputs, we use RSHIFT to bring values into INT8 range.
//
// With RSHIFT=4 (divide by 16):
//   oc=0: 1378 / 16 = 86 (truncated)
//   oc=1: 3172 / 16 = 198 → saturated to 127
//
// With RSHIFT=5 (divide by 32):
//   oc=0: 1378 / 32 = 43
//   oc=1: 3172 / 32 = 99
//
// We use RSHIFT=5 in this test.
// ============================================================

`timescale 1ns / 1ps

module tb_fc_engine;

    localparam IN_DIM    = 25;
    localparam OUT_DIM   = 2;
    localparam DATA_W    = 8;
    localparam ACC_W     = 32;
    localparam K_PAR     = 25;
    localparam IMC_ACC_W = 24;

    reg                       clk;
    reg                       rst_n;
    reg                       start;
    reg  [2:0]                layer_id;
    reg  [4:0]                rshift_dyn;
    reg                       cfg_enable_drift;
    reg  [15:0]               cfg_drift_t;

    // fc_engine <-> pcm_imc_unit
    wire [K_PAR*DATA_W-1:0]    imc_v_bus;
    wire [K_PAR*16-1:0]        imc_addr_bus;
    wire                       imc_start;
    wire                       imc_enable_drift;
    wire [15:0]                imc_drift_t;
    wire signed [IMC_ACC_W-1:0] imc_mac_result;
    wire                       imc_result_valid;

    // fc_engine <-> feature_buffer (mock with sync read)
    // v1 feature_buffer is a sync read: address issued at cycle N,
    // data returned at cycle N+1. We model that with a 1-cycle delay register.
    wire [12:0]                fmap_addr;
    reg signed [DATA_W-1:0]    fmap_in_reg;
    always @(posedge clk) begin
        if (!rst_n) fmap_in_reg <= 0;
        else        fmap_in_reg <= $signed(fmap_addr[DATA_W-1:0]) + 8'sd1;
    end
    wire signed [DATA_W-1:0]   fmap_in_w = fmap_in_reg;

    // fc_engine <-> bias (mock = 0)
    wire [7:0]                 bias_addr;
    wire signed [ACC_W-1:0]    bias_in_w = 32'sd0;

    // fc_engine -> ofmap (capture)
    wire [12:0]                out_addr;
    wire signed [DATA_W-1:0]   out_data;
    wire                       out_en;
    wire                       done;
    wire                       mac_timeout;

    // ----- DUT -----
    fc_engine #(
        .IN_DIM(IN_DIM),
        .OUT_DIM(OUT_DIM),
        .RSHIFT(0),
        .MAX_IN_DIM(IN_DIM)
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

    // ----- pcm_imc_unit -----
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

    // ----- Capture all out_en pulses -----
    reg signed [DATA_W-1:0] captured_out [0:7];
    reg [12:0]              captured_addr [0:7];
    integer                 captured_count;
    initial begin
        captured_count = 0;
    end
    always @(negedge clk) begin
        #1;
        if (out_en) begin
            captured_out[captured_count]  = out_data;
            captured_addr[captured_count] = out_addr;
            captured_count                = captured_count + 1;
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

    integer i;

    initial begin
        $dumpfile("sim/tb_fc_engine.vcd");
        $dumpvars(0, tb_fc_engine);

        $display("============================================================");
        $display("tb_fc_engine - synthetic IN=25 OUT=2 fc layer");
        $display("============================================================");
        $display("Setup: IN_DIM=25, OUT_DIM=2");
        $display("fmap[i] = i+1, bias = 0, RSHIFT_dyn = 5 (divide by 32)");
        $display("layer = 0 (conv1 synthetic: even addr in SRAM)");
        $display("");
        $display("Expected:");
        $display("  oc=0 sum = 1378, /32 = 43");
        $display("  oc=1 sum = 3172, /32 = 99");
        $display("============================================================");

        rst_n           = 0;
        start           = 0;
        layer_id        = 3'd0;
        rshift_dyn      = 5'b1_0101;       // dyn enabled, value=5
        cfg_enable_drift = 0;
        cfg_drift_t     = 16'd1000;

        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;
        @(posedge clk);

        @(negedge clk); start = 1;
        @(posedge clk);
        @(negedge clk); start = 0;

        // Wait for done
        begin: wait_done_loop
            integer wait_iter;
            for (wait_iter = 0; wait_iter < 2000; wait_iter = wait_iter + 1) begin
                @(posedge clk);
                if (done) disable wait_done_loop;
            end
        end

        if (!done) begin
            $display("[FAIL] watchdog: fc didn't finish");
            $finish;
        end
        $display("[INFO] fc done detected at time %0t", $time);

        @(posedge clk); #1;

        $display("");
        $display("============================================================");
        $display("Captured %0d outputs:", captured_count);
        for (i = 0; i < captured_count; i = i + 1) begin
            $display("  oc=%0d  out_addr=%0d  out_data=%0d",
                i, captured_addr[i], $signed(captured_out[i]));
        end
        $display("============================================================");

        chk("captured 2 outputs", captured_count == 2);
        chk("oc=0 addr == 0", captured_addr[0] == 0);
        chk("oc=0 data == 43 (1378/32)", captured_out[0] == 43);
        chk("oc=1 addr == 1", captured_addr[1] == 1);
        chk("oc=1 data == 99 (3172/32)", captured_out[1] == 99);
        chk("no mac_timeout", mac_timeout == 0);

        $display("");
        $display("Summary: %0d passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("[OK] tb_fc_engine PASSED");
        else               $display("[FAIL] tb_fc_engine FAILED");
        $finish;
    end

endmodule
