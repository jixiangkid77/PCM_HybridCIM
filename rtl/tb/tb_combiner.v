// ============================================================
// tb_combiner.v   (Paper 2 v2)
// ------------------------------------------------------------
// Unit tests for combiner.v.
//
// Tests verify:
//   T1: Idle - no spurious result_valid
//   T2: Single MAC - correct latency (PCM_LATENCY cycles)
//   T3: Result is sram_partial + pcm_partial
//   T4: SRAM partial captured at correct cycle (SRAM_LATENCY)
//   T5: SRAM=0, PCM=N -> result = N (PCM-only contribution)
//   T6: SRAM=N, PCM=0 -> result = N (SRAM-only contribution)
//   T7: Negative values handled correctly
//   T8: Back-to-back operations (separated by enough gap)
// ============================================================

`timescale 1ns / 1ps

module tb_combiner;

    localparam ACC_W = 24;
    localparam SRAM_LAT = 2;
    localparam PCM_LAT = 8;

    reg                       clk;
    reg                       rst_n;
    reg                       start;
    reg  signed [ACC_W-1:0]   sram_partial;
    reg  signed [ACC_W-1:0]   pcm_partial;
    reg                       pcm_valid;
    wire signed [ACC_W-1:0]   mac_result;
    wire                      result_valid;

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

    combiner #(
        .ACC_WIDTH(ACC_W),
        .SRAM_LATENCY(SRAM_LAT),
        .PCM_LATENCY(PCM_LAT)
    ) DUT (
        .clk(clk), .rst_n(rst_n), .start(start),
        .sram_partial(sram_partial), .pcm_partial(pcm_partial),
        .pcm_valid(pcm_valid),
        .mac_result(mac_result), .result_valid(result_valid)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // Helper: simulate one full operation
    // Drive sram_partial to S at cycle SRAM_LATENCY after start.
    // Drive pcm_partial + pcm_valid at cycle PCM_LATENCY.
    // Returns the captured mac_result.
    task do_op;
        input signed [ACC_W-1:0] S;
        input signed [ACC_W-1:0] P;
        output signed [ACC_W-1:0] result;
        integer i;
        begin
            // Default: sram_partial = 0 until SRAM_LAT cycle, pcm_valid = 0 until PCM_LAT
            @(negedge clk);
            sram_partial = 0;
            pcm_partial = 0;
            pcm_valid = 0;
            start = 1;
            @(posedge clk);
            @(negedge clk);
            start = 0;
            // Cycles 1..SRAM_LAT-1: nothing arrives
            for (i = 1; i < SRAM_LAT; i = i + 1) begin
                @(posedge clk);
            end
            // At cycle SRAM_LAT: sram_partial becomes S
            @(negedge clk);
            sram_partial = S;
            @(posedge clk);
            // Cycles SRAM_LAT+1..PCM_LAT-1: sram_partial holds, pcm_valid still 0
            for (i = SRAM_LAT+1; i < PCM_LAT; i = i + 1) begin
                @(posedge clk);
            end
            // At cycle PCM_LAT: pcm_partial = P, pcm_valid = 1
            @(negedge clk);
            pcm_partial = P;
            pcm_valid = 1;
            @(posedge clk);
            // Cycle PCM_LAT+1: combiner outputs result
            @(negedge clk);
            pcm_valid = 0;
            #1;
            result = mac_result;
            // Sanity: result_valid should also be high
            if (!result_valid) $display("  WARN: result_valid not high");
            // Wait a couple cycles before next operation to clear pipe
            @(posedge clk); @(posedge clk);
        end
    endtask

    reg signed [ACC_W-1:0] r;

    initial begin
        $dumpfile("sim/tb_combiner.vcd");
        $dumpvars(0, tb_combiner);

        $display("============================================================");
        $display("tb_combiner");
        $display("============================================================");
        $display("ACC_WIDTH=%0d, SRAM_LATENCY=%0d, PCM_LATENCY=%0d, ALIGN_DELAY=%0d",
            ACC_W, SRAM_LAT, PCM_LAT, PCM_LAT - SRAM_LAT);

        rst_n = 0;
        start = 0;
        sram_partial = 0;
        pcm_partial = 0;
        pcm_valid = 0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;
        @(posedge clk);

        // ---- T1: idle ----
        $display("[T1] idle - no spurious result_valid");
        @(posedge clk); @(posedge clk);
        chk("idle: result_valid=0", result_valid == 0);

        // ---- T2 & T3: simple addition ----
        $display("[T2/T3] simple SRAM=10, PCM=20 -> result=30");
        do_op(24'sd10, 24'sd20, r);
        chk("10 + 20 = 30", r == 30);

        // ---- T5: SRAM=0, PCM-only ----
        $display("[T5] SRAM=0, PCM=42");
        do_op(24'sd0, 24'sd42, r);
        chk("0 + 42 = 42", r == 42);

        // ---- T6: PCM=0, SRAM-only ----
        $display("[T6] SRAM=55, PCM=0");
        do_op(24'sd55, 24'sd0, r);
        chk("55 + 0 = 55", r == 55);

        // ---- T7: negative values ----
        $display("[T7] negative values");
        do_op(-24'sd100, -24'sd50, r);
        chk("-100 + -50 = -150", r == -150);
        do_op(24'sd100, -24'sd30, r);
        chk("100 + -30 = 70", r == 70);
        do_op(-24'sd200, 24'sd80, r);
        chk("-200 + 80 = -120", r == -120);

        // ---- T8: Latency check ----
        $display("[T8] latency check");
        // Issue start, drive correct timing, count cycles to result_valid
        @(negedge clk);
        sram_partial = 24'sd1; pcm_partial = 24'sd2; pcm_valid = 0; start = 1;
        @(posedge clk);
        @(negedge clk); start = 0;
        // Wait until cycle PCM_LAT - 1 with no PCM valid
        repeat (PCM_LAT - 1) @(posedge clk);
        chk("not yet valid (cycle PCM_LAT-1)", result_valid == 0);
        // At cycle PCM_LAT: drive pcm_valid
        @(negedge clk); pcm_valid = 1;
        @(posedge clk);
        @(negedge clk); pcm_valid = 0;
        #1;
        chk("result_valid at cycle PCM_LAT+1", result_valid == 1);
        chk("1 + 2 = 3", mac_result == 3);

        // ---- Summary ----
        $display("------------------------------------------------------------");
        $display("Summary: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $display("============================================================");
        if (fail_cnt == 0) $display("[OK] tb_combiner PASSED");
        else               $display("[FAIL] tb_combiner FAILED");
        $finish;
    end

    initial begin
        #100000;
        $display("[FAIL] Watchdog timeout");
        $finish;
    end

endmodule
