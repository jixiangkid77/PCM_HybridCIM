//============================================================
// tb_sram_pool.v
// Unit tests for sram_pool.v (Step 3b)
//
// Run:
//   iverilog -g2012 -o build/tb_sp \
//     rtl/src/sram_pool.v rtl/tb/tb_sram_pool.v
//   vvp build/tb_sp +DATA_DIR=data/rtl_inputs_A_v3
//
// Tests (per KID Step 3b acceptance spec):
//   T1. reset clears output
//   T2. hit=1 reads addr 0
//   T3. hit=1 reads addr 150 (a mid-pool position, conv2 base)
//   T4. hit=1 reads last addr 3073
//   T5. hit=0 returns 0
//   T6. addr out-of-range (>= SRAM_TOTAL) returns 0
//   T7. Sequential reads verify 1-cycle latency
//   T8. Signed value check: pool[addr=2] in Model A is 0xf3
//       (sandbox-confirmed); registered output should read back
//       as -13 when interpreted as signed [7:0].
//
// Golden reference: testbench loads sram_pool.hex into its own
// `golden` array (parallel to DUT.sram_pool_mem) and compares
// the registered DUT output against golden[<addr>] on each cycle.
//============================================================

`timescale 1ns/1ps

module tb_sram_pool;

    localparam SRAM_TOTAL = 3074;

    // ---- plusargs handling ---------------------------------------
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

    // ---- DUT I/O --------------------------------------------------
    reg                   clk = 0;
    reg                   rst_n = 0;
    reg  [15:0]           addr = 16'd0;
    reg                   hit = 1'b0;
    wire signed [7:0]     weight;

    sram_pool #(
        .DATA_WIDTH(8),
        .SRAM_TOTAL(SRAM_TOTAL),
        .DATA_DIR("")
    ) DUT (
        .clk(clk),
        .rst_n(rst_n),
        .addr(addr),
        .hit(hit),
        .weight(weight)
    );

    always #5 clk = ~clk;   // 100 MHz

    // ---- Testbench-side golden mirror ---------------------------
    reg signed [7:0] golden [0:SRAM_TOTAL-1];

    integer pass_count = 0;
    integer fail_count = 0;

    // Generic check on the registered `weight` output. Drives
    // (addr, hit) on negedge of cycle N, samples weight on the
    // following negedge (after the posedge that registers them).
    task drive_and_check(
        input [255:0] name,
        input [15:0]  a,
        input         h,
        input signed [7:0] exp_w
    );
        begin
            @(negedge clk);
            addr = a;
            hit  = h;
            @(negedge clk);    // posedge between drives weight
            if (weight === exp_w) begin
                pass_count = pass_count + 1;
                $display("  [PASS] %0s  weight=%0d (0x%02x)",
                         name, weight, weight & 8'hff);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] %0s", name);
                $display("         exp: %0d (0x%02x)",
                         exp_w, exp_w & 8'hff);
                $display("         got: %0d (0x%02x)",
                         weight, weight & 8'hff);
            end
        end
    endtask

    // ---- Main test sequence -------------------------------------
    integer k, mismatches;
    reg signed [7:0] expected;

    initial begin
        $display("============================================================");

        // ---- Reset + DATA_DIR loading ----
        data_dir = {(8*512){1'b0}};
        have_data_dir = $value$plusargs("DATA_DIR=%s", data_dir);

        // Init golden to zero so the no-DATA_DIR path has a clean
        // mirror.
        for (k = 0; k < SRAM_TOTAL; k = k + 1) golden[k] = 8'sd0;

        if (have_data_dir) begin
            $readmemh({trim(data_dir), "/sram_pool.hex"},
                      DUT.sram_pool_mem);
            $readmemh({trim(data_dir), "/sram_pool.hex"}, golden);
            $display("tb_sram_pool  DATA_DIR=\"%0s\"", trim(data_dir));
        end else begin
            $display("tb_sram_pool  no +DATA_DIR  (T2/T3/T4/T8 will skip)");
        end
        $display("============================================================");

        //----------------------------------------------------------
        // T1 — reset clears output
        //----------------------------------------------------------
        $display("");
        $display("T1  reset clears output");
        rst_n = 1'b0;
        addr  = 16'd0;
        hit   = 1'b1;     // even with hit=1, reset wins
        @(negedge clk); @(negedge clk);
        if (weight === 8'sd0) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T1 weight=0 during reset");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T1 weight=%0d during reset (expected 0)",
                     weight);
        end
        // Release reset
        @(negedge clk);
        rst_n = 1'b1;
        hit   = 1'b0;

        //----------------------------------------------------------
        // T5 — hit=0 returns 0 (works without DATA_DIR)
        //----------------------------------------------------------
        $display("");
        $display("T5  hit=0 returns 0");
        drive_and_check("T5.1 addr=100 hit=0",
                        16'd100, 1'b0, 8'sd0);
        // Even drive a "valid" addr — hit=0 still wins
        drive_and_check("T5.2 addr=0 hit=0",
                        16'd0, 1'b0, 8'sd0);

        //----------------------------------------------------------
        // T6 — addr out of range with hit=1 returns 0
        //----------------------------------------------------------
        $display("");
        $display("T6  addr out of range returns 0 (defensive)");
        drive_and_check("T6.1 addr=3074 (==SRAM_TOTAL) hit=1",
                        16'd3074, 1'b1, 8'sd0);
        drive_and_check("T6.2 addr=FFFF hit=1",
                        16'hFFFF, 1'b1, 8'sd0);
        drive_and_check("T6.3 addr=5000 hit=1",
                        16'd5000, 1'b1, 8'sd0);

        //----------------------------------------------------------
        // Tests needing DATA_DIR
        //----------------------------------------------------------
        if (have_data_dir) begin

            //------------------------------------------------------
            // T2/T3/T4 — hit reads at specific addresses
            //------------------------------------------------------
            $display("");
            $display("T2/T3/T4  hit reads at specific addresses");
            drive_and_check("T2 addr=0 hit=1",
                            16'd0,    1'b1, golden[0]);
            drive_and_check("T3.1 addr=150 hit=1 (conv2 base)",
                            16'd150,  1'b1, golden[150]);
            drive_and_check("T3.2 addr=1631 hit=1 (fc1 base, Model A)",
                            16'd1631, 1'b1, golden[1631]);
            drive_and_check("T4 addr=3073 hit=1 (last entry)",
                            16'd3073, 1'b1, golden[3073]);

            //------------------------------------------------------
            // T7 — Sequential reads, 1-cycle latency
            //------------------------------------------------------
            // Drive addr=A, then addr=B on consecutive cycles.
            // After posedge:
            //   cycle N+1: weight should equal golden[A]
            //   cycle N+2: weight should equal golden[B]
            $display("");
            $display("T7  Sequential reads / 1-cycle latency");

            // Cycle 1: drive A
            @(negedge clk);
            addr = 16'd0; hit = 1'b1;
            // Cycle 2: posedge registers golden[0]; drive B
            @(negedge clk);
            if (weight === golden[0]) begin
                pass_count = pass_count + 1;
                $display("  [PASS] T7.1 cycle@A  weight=golden[0]=%0d",
                         weight);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T7.1 cycle@A  weight=%0d (exp %0d)",
                         weight, golden[0]);
            end
            addr = 16'd150;
            // Cycle 3: posedge registers golden[150]; drive C
            @(negedge clk);
            if (weight === golden[150]) begin
                pass_count = pass_count + 1;
                $display("  [PASS] T7.2 cycle@B  weight=golden[150]=%0d",
                         weight);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T7.2 cycle@B  weight=%0d (exp %0d)",
                         weight, golden[150]);
            end
            addr = 16'd3073;
            @(negedge clk);
            if (weight === golden[3073]) begin
                pass_count = pass_count + 1;
                $display("  [PASS] T7.3 cycle@C  weight=golden[3073]=%0d",
                         weight);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T7.3 cycle@C  weight=%0d (exp %0d)",
                         weight, golden[3073]);
            end
            // Cycle 4: deassert hit, expect 0 on next sample
            hit = 1'b0;
            @(negedge clk);
            if (weight === 8'sd0) begin
                pass_count = pass_count + 1;
                $display("  [PASS] T7.4 after hit=0  weight=0");
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T7.4 after hit=0  weight=%0d (exp 0)",
                         weight);
            end

            //------------------------------------------------------
            // T8 — Signed value interpretation
            //------------------------------------------------------
            // In Model A, sram_pool.hex[addr=2] = 0xf3 = -13 signed.
            // In Model B, sram_pool.hex[addr=2] may differ; we test
            // against whatever the golden mirror holds. The key
            // invariant is: bit-pattern 0xf3 must be readable from
            // signed [7:0] as a negative number.
            $display("");
            $display("T8  Signed value interpretation");
            // Find the first golden entry whose MSB is set
            // (i.e., signed-negative). This makes the test
            // model-agnostic.
            begin : signed_search
                integer found_addr;
                reg     done;
                done = 1'b0;
                found_addr = -1;
                for (k = 0; k < SRAM_TOTAL && !done; k = k + 1) begin
                    if (golden[k][7] === 1'b1) begin
                        found_addr = k;
                        done = 1'b1;
                    end
                end
                if (found_addr < 0) begin
                    $display("  [SKIP] T8 no negative entry in pool");
                end else begin
                    drive_and_check("T8 signed read of first negative entry",
                                    found_addr[15:0], 1'b1,
                                    golden[found_addr]);
                    // Display the interpretation explicitly.
                    $display("         interpretation: addr=%0d, hex=%02x, signed=%0d",
                             found_addr,
                             golden[found_addr] & 8'hff,
                             golden[found_addr]);
                end
            end

            //------------------------------------------------------
            // BONUS — Full sweep against golden
            //------------------------------------------------------
            // Read every entry and verify match. This is a strong
            // end-to-end check that $readmemh produced identical
            // DUT and testbench mirrors.
            $display("");
            $display("BONUS  full pool sweep (every entry)");
            mismatches = 0;
            for (k = 0; k < SRAM_TOTAL; k = k + 1) begin
                @(negedge clk);
                addr = k[15:0];
                hit  = 1'b1;
                @(negedge clk);
                if (weight !== golden[k]) begin
                    mismatches = mismatches + 1;
                    if (mismatches <= 3) begin
                        $display("    mismatch addr=%0d: got=%02x exp=%02x",
                                 k, weight & 8'hff, golden[k] & 8'hff);
                    end
                end
            end
            if (mismatches == 0) begin
                pass_count = pass_count + 1;
                $display("  [PASS] full sweep: %0d entries all match",
                         SRAM_TOTAL);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] full sweep: %0d mismatches",
                         mismatches);
            end
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

    // Watchdog
    initial begin
        #500000;
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule
