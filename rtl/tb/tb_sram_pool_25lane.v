//============================================================
// tb_sram_pool_25lane.v
// Step 5a: K-lane SRAM pool wrapper unit tests
//
// Tests:
//   T1 all lanes miss (hit=0) -> all weights=0, all hit_reg=0
//   T2 single lane hit -> only that lane gets weight
//   T3 25 lanes all hit, distinct addrs -> all weights correct
//   T4 mixed hit/miss -> only hit lanes contribute
//   T5 OOR defense: hit=1 with addr >= SRAM_TOTAL -> weight=0
//   T6 SHARED MEMORY VERIFICATION: hierarchical write to
//      DUT.sram_pool_mem[N], then multiple lanes read addr=N
//      -- proves single shared storage (NOT 25 replicas)
//   T7 1-cycle latency check (consecutive different inputs)
//   T8 reset clears outputs, preserves memory
//
// Run:
//   iverilog -g2012 -o build/tb_sp25 \
//     rtl/src/sram_pool_25lane.v rtl/tb/tb_sram_pool_25lane.v
//   vvp build/tb_sp25 +DATA_DIR=data/rtl_inputs_A_v3
//   vvp build/tb_sp25 +DATA_DIR=data/rtl_inputs_B_v3
//============================================================

`timescale 1ns/1ps

module tb_sram_pool_25lane;

    localparam integer K          = 25;
    localparam integer DATA_WIDTH = 8;
    localparam integer ADDR_WIDTH = 16;
    localparam integer SRAM_TOTAL = 3074;

    // ---- plusargs handling --------------------------------------
    reg [8*512-1:0] data_dir;
    integer         have_data_dir;

    function [8*512-1:0] trim(input [8*512-1:0] s);
        integer k;
        reg     started;
        reg [7:0] ch;
        begin
            trim    = {(8*512){1'b0}};
            started = 1'b0;
            for (k = 8*512-1; k >= 0; k = k - 8) begin
                ch = s[k -: 8];
                if (!started && ch != 8'h00) started = 1'b1;
                if (started) begin
                    trim = trim << 8;
                    trim[7:0] = ch;
                end
            end
        end
    endfunction

    // ---- Clock + reset -------------------------------------------
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    // ---- DUT I/O -------------------------------------------------
    reg  [K*ADDR_WIDTH-1:0]  addr_bus = 0;
    reg  [K-1:0]             hit_bus  = 0;
    wire [K*DATA_WIDTH-1:0]  weight_bus;
    wire [K-1:0]             hit_reg_bus;

    sram_pool_25lane #(
        .K(K),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .SRAM_TOTAL(SRAM_TOTAL),
        .DATA_DIR("")
    ) DUT (
        .clk(clk),
        .rst_n(rst_n),
        .addr_bus(addr_bus),
        .hit_bus(hit_bus),
        .weight_bus(weight_bus),
        .hit_reg_bus(hit_reg_bus)
    );

    // ---- Testbench-side pool mirror -----------------------------
    reg signed [DATA_WIDTH-1:0] pool_mirror [0:SRAM_TOTAL-1];

    // ---- Stats ---------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;

    //==========================================================
    // Helpers
    //==========================================================
    task clear_all_lanes;
        begin
            addr_bus = {(K*ADDR_WIDTH){1'b0}};
            hit_bus  = {K{1'b0}};
        end
    endtask

    task set_lane(input integer lane,
                  input [ADDR_WIDTH-1:0] addr,
                  input                  hit);
        begin
            addr_bus[lane*ADDR_WIDTH +: ADDR_WIDTH] = addr;
            hit_bus[lane]                           = hit;
        end
    endtask

    // Drive inputs at one negedge; after the next negedge (which
    // is past one posedge), outputs reflect the drive.
    task drive_and_advance;
        begin
            @(negedge clk);
            @(negedge clk);   // posedge in between has fired
        end
    endtask

    // Check helpers
    task expect_weight(input [255:0] name,
                       input integer lane,
                       input signed [DATA_WIDTH-1:0] exp_w);
        reg signed [DATA_WIDTH-1:0] got;
        begin
            got = weight_bus[lane*DATA_WIDTH +: DATA_WIDTH];
            if (got === exp_w) begin
                pass_count = pass_count + 1;
                $display("  [PASS] %0s  lane=%0d got=%0d", name, lane, got);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] %0s  lane=%0d got=%0d exp=%0d",
                         name, lane, got, exp_w);
            end
        end
    endtask

    task expect_hit_reg(input [255:0] name,
                        input integer lane,
                        input         exp_h);
        begin
            if (hit_reg_bus[lane] === exp_h) begin
                pass_count = pass_count + 1;
                $display("  [PASS] %0s  lane=%0d hit_reg=%0b",
                         name, lane, hit_reg_bus[lane]);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] %0s  lane=%0d hit_reg=%0b exp=%0b",
                         name, lane, hit_reg_bus[lane], exp_h);
            end
        end
    endtask

    task expect_all_zero(input [255:0] name);
        begin
            if (weight_bus === {(K*DATA_WIDTH){1'b0}}
                && hit_reg_bus === {K{1'b0}}) begin
                pass_count = pass_count + 1;
                $display("  [PASS] %0s  weight_bus=0 hit_reg=0",
                         name);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] %0s  weight_bus=%h hit_reg=%b",
                         name, weight_bus, hit_reg_bus);
            end
        end
    endtask

    //==========================================================
    // Main test sequence
    //==========================================================
    integer i;
    reg signed [DATA_WIDTH-1:0] expected_w;

    initial begin
        $display("============================================================");

        data_dir = {(8*512){1'b0}};
        have_data_dir = $value$plusargs("DATA_DIR=%s", data_dir);

        if (!have_data_dir) begin
            $display("WARNING: +DATA_DIR not set; tests T2-T5 will use default-zero pool. T6 always works (hier write).");
        end else begin
            // Load DUT memory + testbench mirror
            $readmemh({trim(data_dir), "/sram_pool.hex"}, DUT.sram_pool_mem);
            $readmemh({trim(data_dir), "/sram_pool.hex"}, pool_mirror);
            $display("tb_sram_pool_25lane  DATA_DIR=\"%0s\"",
                     trim(data_dir));
        end
        $display("============================================================");

        // Reset
        clear_all_lanes;
        rst_n = 0;
        @(negedge clk); @(negedge clk); @(negedge clk);
        rst_n = 1;

        //----------------------------------------------------------
        // T1 — all lanes miss
        //----------------------------------------------------------
        $display("");
        $display("T1  all lanes hit=0 -> all weights=0, hit_reg=0");
        clear_all_lanes;
        // Even with random addrs, hit=0 should yield 0
        for (i = 0; i < K; i = i + 1) begin
            addr_bus[i*ADDR_WIDTH +: ADDR_WIDTH] = i * 7;
        end
        // hit_bus stays 0
        drive_and_advance;
        expect_all_zero("T1.1 all-miss");

        //----------------------------------------------------------
        // T2 — single lane hit
        //----------------------------------------------------------
        $display("");
        $display("T2  single lane hit");
        clear_all_lanes;
        set_lane(0, 16'd100, 1'b1);
        drive_and_advance;
        expected_w = have_data_dir ? pool_mirror[100] : 8'sd0;
        expect_weight("T2.1 lane0 addr=100",   0,  expected_w);
        expect_hit_reg("T2.2 lane0 hit_reg=1", 0,  1'b1);
        // lane 5 should still be 0
        expect_weight("T2.3 lane5 weight=0",   5,  8'sd0);
        expect_hit_reg("T2.4 lane5 hit_reg=0", 5,  1'b0);

        //----------------------------------------------------------
        // T3 — 25 lanes all hit, distinct addrs
        //----------------------------------------------------------
        $display("");
        $display("T3  25 lanes all hit, distinct addrs");
        clear_all_lanes;
        for (i = 0; i < K; i = i + 1) begin
            set_lane(i, i * 50, 1'b1);   // addrs 0, 50, 100, ... 1200
        end
        drive_and_advance;
        // Spot check 3 lanes
        if (have_data_dir) begin
            expect_weight("T3.1 lane0 addr=0",      0,  pool_mirror[0]);
            expect_weight("T3.2 lane12 addr=600", 12,  pool_mirror[600]);
            expect_weight("T3.3 lane24 addr=1200",24, pool_mirror[1200]);
        end else begin
            expect_weight("T3.1 lane0 (no data)",  0, 8'sd0);
            expect_weight("T3.2 lane12 (no data)",12, 8'sd0);
            expect_weight("T3.3 lane24 (no data)",24, 8'sd0);
        end
        // All hit_reg should be 1
        for (i = 0; i < K; i = i + 1) begin
            if (hit_reg_bus[i] !== 1'b1) begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T3.4 lane=%0d hit_reg=0 (expected 1)", i);
            end
        end
        if (hit_reg_bus === {K{1'b1}}) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T3.4 all 25 hit_reg=1");
        end

        //----------------------------------------------------------
        // T4 — mixed hit/miss
        //----------------------------------------------------------
        $display("");
        $display("T4  mixed hit/miss");
        clear_all_lanes;
        set_lane(0,  16'd200, 1'b1);
        set_lane(7,  16'd500, 1'b0);   // miss with non-zero addr
        set_lane(12, 16'd800, 1'b1);
        set_lane(20, 16'd2000,1'b0);
        drive_and_advance;

        if (have_data_dir) begin
            expect_weight("T4.1 lane0 hit addr=200",   0, pool_mirror[200]);
            expect_weight("T4.2 lane12 hit addr=800", 12, pool_mirror[800]);
        end
        expect_weight("T4.3 lane7 miss -> 0",    7, 8'sd0);
        expect_weight("T4.4 lane20 miss -> 0",  20, 8'sd0);
        expect_hit_reg("T4.5 lane0 hit_reg=1",   0, 1'b1);
        expect_hit_reg("T4.6 lane7 hit_reg=0",   7, 1'b0);

        //----------------------------------------------------------
        // T5 — OOR defense
        //----------------------------------------------------------
        $display("");
        $display("T5  OOR defense (addr >= SRAM_TOTAL=3074)");
        clear_all_lanes;
        set_lane(0,  16'd3074, 1'b1);   // == SRAM_TOTAL
        set_lane(5,  16'd5000, 1'b1);
        set_lane(10, 16'hFFFF, 1'b1);   // max 16-bit
        // Valid lanes alongside OOR
        set_lane(15, 16'd1000, 1'b1);
        drive_and_advance;

        expect_weight("T5.1 lane0 addr=3074 -> 0",    0, 8'sd0);
        expect_hit_reg("T5.2 lane0 hit_reg=0",        0, 1'b0);
        expect_weight("T5.3 lane5 addr=5000 -> 0",    5, 8'sd0);
        expect_hit_reg("T5.4 lane5 hit_reg=0",        5, 1'b0);
        expect_weight("T5.5 lane10 addr=FFFF -> 0",  10, 8'sd0);
        expect_hit_reg("T5.6 lane10 hit_reg=0",      10, 1'b0);
        if (have_data_dir) begin
            expect_weight("T5.7 lane15 valid OOR-mixed",
                          15, pool_mirror[1000]);
        end
        expect_hit_reg("T5.8 lane15 hit_reg=1",      15, 1'b1);

        //----------------------------------------------------------
        // T6 — SHARED MEMORY VERIFICATION
        //----------------------------------------------------------
        // Hierarchically write specific cells in DUT.sram_pool_mem,
        // then drive multiple lanes to read those addresses. If
        // the lanes return the written values (regardless of what
        // sram_pool.hex contained), it proves all lanes see the
        // same shared storage. If implementation were 25 replicas,
        // hier-write to a single instance would only affect that
        // one lane.
        $display("");
        $display("T6  shared memory verification (hier-write)");

        // Inject test values directly into DUT memory
        DUT.sram_pool_mem[100] = 8'sd42;
        DUT.sram_pool_mem[101] = -8'sd17;
        DUT.sram_pool_mem[200] = 8'sd99;

        clear_all_lanes;
        // Multiple lanes read the same addr=100
        set_lane(0,  16'd100, 1'b1);
        set_lane(12, 16'd100, 1'b1);
        set_lane(7,  16'd101, 1'b1);    // signed-negative test
        set_lane(24, 16'd200, 1'b1);    // unique addr
        drive_and_advance;

        expect_weight("T6.1 lane0  addr=100 -> 42",  0,   8'sd42);
        expect_weight("T6.2 lane12 addr=100 -> 42",  12,  8'sd42);
        expect_weight("T6.3 lane7  addr=101 -> -17", 7,  -8'sd17);
        expect_weight("T6.4 lane24 addr=200 -> 99",  24,  8'sd99);

        // Verify all hit_reg bits set
        if (hit_reg_bus[0]  === 1'b1 &&
            hit_reg_bus[12] === 1'b1 &&
            hit_reg_bus[7]  === 1'b1 &&
            hit_reg_bus[24] === 1'b1) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T6.5 all four active lanes' hit_reg=1");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T6.5 hit_reg bits inconsistent");
        end

        //----------------------------------------------------------
        // T7 — 1-cycle latency (consecutive different inputs)
        //----------------------------------------------------------
        // Drive addr=A at negedge T, then addr=B at negedge T+1.
        // After negedge T+1, weight should reflect addr=A (the
        // value driven at T).
        // After negedge T+2, weight should reflect addr=B.
        $display("");
        $display("T7  1-cycle latency timing");
        // Use distinct hier-written addrs to make timing observable
        DUT.sram_pool_mem[500] = 8'sd55;
        DUT.sram_pool_mem[501] = -8'sd33;

        clear_all_lanes;
        @(negedge clk);
        set_lane(0, 16'd500, 1'b1);     // drive addr=500 at T

        @(negedge clk);                  // T+1: posedge has fired,
                                         // weight reflects addr=500
        if (weight_bus[0*DATA_WIDTH +: DATA_WIDTH] === 8'sd55) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T7.1 after 1 cycle, weight=55 (addr=500)");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T7.1 weight=%0d (expected 55)",
                     $signed(weight_bus[0*DATA_WIDTH +: DATA_WIDTH]));
        end

        set_lane(0, 16'd501, 1'b1);     // drive addr=501 at T+1
        @(negedge clk);                  // T+2: weight=-33
        if (weight_bus[0*DATA_WIDTH +: DATA_WIDTH] === -8'sd33) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T7.2 after another cycle, weight=-33 (addr=501)");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T7.2 weight=%0d (expected -33)",
                     $signed(weight_bus[0*DATA_WIDTH +: DATA_WIDTH]));
        end

        //----------------------------------------------------------
        // T8 — reset clears outputs, preserves memory
        //----------------------------------------------------------
        // After T7 the memory still has hier-written values.
        // Reset should clear weight_bus and hit_reg_bus but NOT
        // the memory. After deasserting reset and reading
        // addr=500 again, we should get 55 back.
        $display("");
        $display("T8  reset clears outputs but preserves memory");
        clear_all_lanes;
        rst_n = 0;
        @(negedge clk); @(negedge clk);

        if (weight_bus === {(K*DATA_WIDTH){1'b0}}
            && hit_reg_bus === {K{1'b0}}) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T8.1 reset cleared weight_bus and hit_reg_bus");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T8.1 reset did not clear outputs");
        end

        rst_n = 1;
        @(negedge clk);
        set_lane(0, 16'd500, 1'b1);
        @(negedge clk);
        if (weight_bus[0*DATA_WIDTH +: DATA_WIDTH] === 8'sd55) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T8.2 memory preserved across reset (addr=500 -> 55)");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T8.2 memory NOT preserved after reset");
        end

        //----------------------------------------------------------
        // Summary
        //----------------------------------------------------------
        $display("");
        $display("============================================================");
        $display("Total: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count == 0) begin
            $display("RESULT: ALL TESTS PASSED");
        end else begin
            $display("RESULT: FAILED");
        end
        $display("============================================================");

        $finish;
    end

    initial begin
        #500000;
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule
