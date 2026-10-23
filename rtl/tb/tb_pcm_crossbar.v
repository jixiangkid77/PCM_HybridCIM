//============================================================
// tb_pcm_crossbar.v
// Step 4b: PCM crossbar (v3 X' refactor) unit tests
//
// Validates:
//   T1 hit=0 all lanes -> mac_result=0
//   T2 single lane hit (enable_drift=0) -> result = v * raw_weight
//   T3 multiple lanes hit (enable_drift=0) -> result = sum
//   T4 mixed hit mask: hit=0 lanes contribute nothing
//   T5 enable_drift=1 path produces valid result (not X), drift_t > 0
//   T6 latency: result_valid fires after MULTI_CYCLE_LATENCY cycles
//      from `start`
//   T7 boundary addr: last PCM pool entry (addr=58395) readable
//
// Run:
//   iverilog -g2012 -o build/tb_pcb \
//     rtl/src/pcm_crossbar.v rtl/tb/tb_pcm_crossbar.v
//   vvp build/tb_pcb +DATA_DIR=data/rtl_inputs_A_v3 \
//                    +COMMON_DIR=data/rtl_inputs_common
//============================================================

`timescale 1ns/1ps

module tb_pcm_crossbar;

    localparam integer K           = 25;
    localparam integer DATA_WIDTH  = 8;
    localparam integer ADDR_WIDTH  = 16;
    localparam integer ACC_WIDTH   = 24;
    localparam integer PCM_TOTAL   = 58396;
    localparam integer LATENCY     = 8;

    // ---- plusargs handling --------------------------------------
    reg [8*512-1:0] data_dir;
    reg [8*512-1:0] common_dir;
    integer         have_data_dir, have_common_dir;

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

    // ---- DUT I/O --------------------------------------------------
    reg clk = 0;
    reg rst_n = 0;
    reg start = 0;

    reg  [K*DATA_WIDTH-1:0]  v_bus = 0;
    reg  [K*ADDR_WIDTH-1:0]  pcm_pool_addr_bus = 0;
    reg  [K-1:0]             pcm_hit_bus = 0;

    reg                      enable_drift = 0;
    reg  [15:0]              drift_t = 16'd0;

    wire signed [ACC_WIDTH-1:0] mac_result;
    wire                        result_valid;

    pcm_crossbar #(
        .K(K),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .PCM_TOTAL(PCM_TOTAL),
        .MULTI_CYCLE_LATENCY(LATENCY),
        .DATA_DIR(""),
        .COMMON_DIR("")
    ) DUT (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .v_bus(v_bus),
        .pcm_pool_addr_bus(pcm_pool_addr_bus),
        .pcm_hit_bus(pcm_hit_bus),
        .enable_drift(enable_drift),
        .drift_t(drift_t),
        .mac_result(mac_result),
        .result_valid(result_valid)
    );

    always #5 clk = ~clk;

    // ---- Testbench-side pool mirror ------------------------------
    reg signed [DATA_WIDTH-1:0] pool_mirror [0:PCM_TOTAL-1];

    integer pass_count = 0;
    integer fail_count = 0;
    integer i;

    // ---- Lane helper ---------------------------------------------
    task set_lane(input integer lane,
                  input [DATA_WIDTH-1:0] v,
                  input [ADDR_WIDTH-1:0] addr,
                  input                  hit);
        begin
            v_bus[lane*DATA_WIDTH +: DATA_WIDTH]             = v;
            pcm_pool_addr_bus[lane*ADDR_WIDTH +: ADDR_WIDTH] = addr;
            pcm_hit_bus[lane]                                = hit;
        end
    endtask

    task clear_all_lanes;
        begin
            v_bus = {(K*DATA_WIDTH){1'b0}};
            pcm_pool_addr_bus = {(K*ADDR_WIDTH){1'b0}};
            pcm_hit_bus = {K{1'b0}};
        end
    endtask

    // ---- Trigger one MAC op and capture result -------------------
    task run_mac_op(input [255:0] name,
                    output signed [ACC_WIDTH-1:0] got);
        integer waited;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            waited = 0;
            while (!result_valid && waited < (LATENCY + 5)) begin
                @(negedge clk);
                waited = waited + 1;
            end

            if (!result_valid) begin
                $display("  [FAIL] %0s: result_valid did not fire", name);
                fail_count = fail_count + 1;
                got = 0;
            end else begin
                got = mac_result;
            end
        end
    endtask

    task expect_eq(input [255:0] name,
                   input signed [ACC_WIDTH-1:0] got,
                   input signed [ACC_WIDTH-1:0] exp_val);
        begin
            if (got === exp_val) begin
                pass_count = pass_count + 1;
                $display("  [PASS] %0s  got=%0d", name, got);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] %0s  got=%0d  exp=%0d", name, got, exp_val);
            end
        end
    endtask

    // ---- Main sequence -------------------------------------------
    integer waited_cycles;
    reg signed [ACC_WIDTH-1:0] got_result;
    reg signed [ACC_WIDTH-1:0] expected;

    initial begin
        $display("============================================================");

        data_dir   = {(8*512){1'b0}};
        common_dir = {(8*512){1'b0}};
        have_data_dir   = $value$plusargs("DATA_DIR=%s",   data_dir);
        have_common_dir = $value$plusargs("COMMON_DIR=%s", common_dir);

        if (!have_data_dir) begin
            $display("ERROR: +DATA_DIR is required.");
            $finish;
        end

        // Load LUTs and pool into DUT via hierarchical $readmemh
        if (have_common_dir) begin
            $readmemh({trim(common_dir), "/log2_lut.hex"}, DUT.log2_lut);
            $readmemh({trim(common_dir), "/exp2_lut.hex"}, DUT.exp2_lut);
        end else begin
            $readmemh("data/rtl_inputs_common/log2_lut.hex", DUT.log2_lut);
            $readmemh("data/rtl_inputs_common/exp2_lut.hex", DUT.exp2_lut);
        end
        $readmemh({trim(data_dir), "/pcm_pool.hex"},     DUT.pcm_pool);
        $readmemh({trim(data_dir), "/nu_pcm_pool.hex"},  DUT.nu_pcm_pool);

        // Mirror the pool for expected-value computation
        $readmemh({trim(data_dir), "/pcm_pool.hex"}, pool_mirror);

        $display("tb_pcm_crossbar");
        $display("  DATA_DIR  = \"%0s\"", trim(data_dir));
        if (have_common_dir)
            $display("  COMMON_DIR= \"%0s\"", trim(common_dir));
        else
            $display("  COMMON_DIR= data/rtl_inputs_common (default)");
        $display("============================================================");

        // Initial reset
        clear_all_lanes;
        enable_drift = 0;
        drift_t = 16'd0;
        rst_n = 0;
        @(negedge clk); @(negedge clk); @(negedge clk);
        rst_n = 1;

        //----------------------------------------------------------
        // T1 — all lanes miss
        //----------------------------------------------------------
        $display("");
        $display("T1  all lanes miss -> mac_result = 0");
        clear_all_lanes;
        enable_drift = 0;
        for (i = 0; i < K; i = i + 1) begin
            v_bus[i*DATA_WIDTH +: DATA_WIDTH] = 8'h7F;
        end
        run_mac_op("T1.1 all hit=0, all v=127", got_result);
        expect_eq("T1.1 mac=0", got_result, 24'sd0);

        //----------------------------------------------------------
        // T2 — single lane hit
        //----------------------------------------------------------
        $display("");
        $display("T2  single lane hit (enable_drift=0)");
        clear_all_lanes;
        enable_drift = 0;
        set_lane(0, 8'sd3, 16'd0, 1'b1);
        expected = $signed(8'sd3) * $signed(pool_mirror[0]);
        run_mac_op("T2.1 lane0 v=3 addr=0", got_result);
        expect_eq("T2.1 mac = 3*pool[0]", got_result, expected);

        clear_all_lanes;
        set_lane(12, -8'sd5, 16'd1631, 1'b1);
        expected = $signed(-8'sd5) * $signed(pool_mirror[1631]);
        run_mac_op("T2.2 lane12 v=-5 addr=1631", got_result);
        expect_eq("T2.2 mac = (-5)*pool[1631]", got_result, expected);

        //----------------------------------------------------------
        // T3 — multiple lanes hit
        //----------------------------------------------------------
        $display("");
        $display("T3  multiple lanes hit (enable_drift=0)");
        clear_all_lanes;
        enable_drift = 0;
        set_lane(0,   8'sd2,  16'd0,    1'b1);
        set_lane(5,   8'sd7,  16'd100,  1'b1);
        set_lane(12, -8'sd3,  16'd1000, 1'b1);
        set_lane(18,  8'sd11, 16'd1631, 1'b1);
        set_lane(24, -8'sd1,  16'd3073, 1'b1);

        expected = $signed( 8'sd2)  * $signed(pool_mirror[0])
                 + $signed( 8'sd7)  * $signed(pool_mirror[100])
                 + $signed(-8'sd3)  * $signed(pool_mirror[1000])
                 + $signed( 8'sd11) * $signed(pool_mirror[1631])
                 + $signed(-8'sd1)  * $signed(pool_mirror[3073]);
        run_mac_op("T3.1 5 lanes hit", got_result);
        expect_eq("T3.1 mac = sum(v_i * pool[addr_i])",
                  got_result, expected);

        //----------------------------------------------------------
        // T4 — mixed hit mask
        //----------------------------------------------------------
        $display("");
        $display("T4  mixed hit mask (hit=0 lanes ignored)");
        clear_all_lanes;
        enable_drift = 0;
        set_lane(0, 8'sd4, 16'd50,  1'b1);
        set_lane(5, 8'sd6, 16'd200, 1'b1);
        // bogus content for miss lanes
        set_lane(1, 8'sd127, 16'd58395, 1'b0);
        set_lane(7, 8'sd99,  16'd3000,  1'b0);

        expected = $signed(8'sd4) * $signed(pool_mirror[50])
                 + $signed(8'sd6) * $signed(pool_mirror[200]);
        run_mac_op("T4.1 mixed hit, miss-lane garbage", got_result);
        expect_eq("T4.1 mac unaffected by hit=0 lanes",
                  got_result, expected);

        //----------------------------------------------------------
        // T5 — enable_drift=1 path produces defined result
        //----------------------------------------------------------
        $display("");
        $display("T5  enable_drift=1 produces valid non-X result");
        clear_all_lanes;
        set_lane(0,  8'sd5,  16'd0,    1'b1);
        set_lane(4,  8'sd9,  16'd1631, 1'b1);
        set_lane(11, 8'sd2,  16'd3000, 1'b1);

        enable_drift = 0;
        drift_t = 16'd0;
        run_mac_op("T5.prep drift=0 baseline", got_result);
        $display("         baseline mac (drift off): %0d", got_result);

        enable_drift = 1;
        drift_t = 16'd1024;
        run_mac_op("T5.1 drift=1 t=1024", got_result);
        if (^got_result === 1'bx) begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T5.1 result is X (undefined)");
        end else begin
            pass_count = pass_count + 1;
            $display("  [PASS] T5.1 drift=1 t=1024 -> defined mac=%0d",
                     got_result);
        end

        drift_t = 16'd60000;
        run_mac_op("T5.2 drift=1 t=60000", got_result);
        if (^got_result === 1'bx) begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T5.2 result is X");
        end else begin
            pass_count = pass_count + 1;
            $display("  [PASS] T5.2 drift=1 t=60000 -> defined mac=%0d",
                     got_result);
        end

        //----------------------------------------------------------
        // T6 — latency
        //----------------------------------------------------------
        $display("");
        $display("T6  start -> result_valid latency");

        enable_drift = 0;
        drift_t = 16'd0;
        clear_all_lanes;
        set_lane(0, 8'sd2, 16'd0, 1'b1);

        // First flush any pending busy state from previous T5 op
        @(negedge clk); @(negedge clk);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        waited_cycles = 0;
        while (!result_valid && waited_cycles < (LATENCY + 5)) begin
            @(negedge clk);
            waited_cycles = waited_cycles + 1;
        end

        // Expected: from `start=0` negedge to `result_valid=1`
        // observed at negedge -> waited_cycles approximately equals
        // LATENCY-1 (because start was sampled at the posedge that
        // came right after the negedge where start was set high).
        // Allow +/-1 tolerance.
        if (result_valid && waited_cycles <= LATENCY+1 && waited_cycles >= LATENCY-2) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T6 valid after %0d cycles (expected ~%0d)",
                     waited_cycles, LATENCY);
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T6 valid timing: waited %0d cycles (expected ~%0d)",
                     waited_cycles, LATENCY);
        end

        //----------------------------------------------------------
        // T7 — boundary addr (last pool entry)
        //----------------------------------------------------------
        $display("");
        $display("T7  boundary addr (last pool entry, addr=58395)");
        clear_all_lanes;
        enable_drift = 0;
        set_lane(0, 8'sd3, 16'd58395, 1'b1);
        expected = $signed(8'sd3) * $signed(pool_mirror[58395]);
        run_mac_op("T7.1 lane0 v=3 addr=58395", got_result);
        expect_eq("T7.1 mac = 3*pool[58395]", got_result, expected);

        //----------------------------------------------------------
        // T8 — OOR defense: lane_hit=1 but addr >= PCM_TOTAL
        //----------------------------------------------------------
        // Normally pcm_addr_decoder prevents this combination, but
        // pcm_crossbar must independently neutralise it (lane_valid
        // = lane_hit && addr_in_range gate).
        $display("");
        $display("T8  OOR defense: lane_hit=1 with addr >= PCM_TOTAL");

        // T8.1: single OOR lane, addr=58396 (== PCM_TOTAL)
        clear_all_lanes;
        enable_drift = 0;
        set_lane(0, 8'sd5, 16'd58396, 1'b1);
        run_mac_op("T8.1 single OOR lane addr=58396", got_result);
        expect_eq("T8.1 mac=0 (OOR suppressed)", got_result, 24'sd0);
        if (^got_result === 1'bx) begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T8.1 result is X (undefined)");
        end

        // T8.2: single OOR lane, addr=FFFF (max 16-bit)
        clear_all_lanes;
        set_lane(0, 8'sd9, 16'hFFFF, 1'b1);
        run_mac_op("T8.2 single OOR lane addr=FFFF", got_result);
        expect_eq("T8.2 mac=0 (OOR suppressed)", got_result, 24'sd0);

        // T8.3: mixed OOR + valid - only valid lane contributes
        clear_all_lanes;
        set_lane(0, 8'sd9,   16'hFFFF, 1'b1);  // OOR lane
        set_lane(7, 8'sd4,   16'd100,  1'b1);  // valid lane
        set_lane(13, 8'sd11, 16'd58400, 1'b1); // OOR lane
        expected = $signed(8'sd4) * $signed(pool_mirror[100]);
        run_mac_op("T8.3 mixed OOR + valid", got_result);
        expect_eq("T8.3 mac unaffected by OOR lanes",
                  got_result, expected);

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
        #1000000;
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule
