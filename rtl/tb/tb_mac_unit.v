// ============================================================
// tb_mac_unit.v
// ------------------------------------------------------------
// Testbench for mac_unit.
// Covers 5 scenarios:
//   T1  reset            -> acc_out == 0
//   T2  clear + compute  -> acc_out == a*b
//   T3  accumulate       -> acc_out == prev + a*b
//   T4  hold (en=0)      -> acc_out unchanged
//   T5  negative numbers -> signed arithmetic correct
//   T6  long sequence    -> 25 accumulations, matches Python reference
// ============================================================

`timescale 1ns / 1ps

module tb_mac_unit;

    // Test signals
    reg                         clk;
    reg                         rst_n;
    reg                         en;
    reg                         clear;
    reg  signed [7:0]           a;
    reg  signed [7:0]           b;
    wire signed [31:0]          acc_out;

    // DUT
    mac_unit #(
        .DATA_WIDTH(8),
        .ACC_WIDTH (32)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (en),
        .clear   (clear),
        .a       (a),
        .b       (b),
        .acc_out (acc_out)
    );

    // Clock: 100 MHz (10 ns period)
    initial clk = 0;
    always #5 clk = ~clk;

    // Test statistics
    integer pass_count = 0;
    integer fail_count = 0;

    // Check task: compare acc_out against expected value
    task check;
        input signed [31:0] expected;
        input [255:0]       label;
        begin
            if (acc_out === expected) begin
                $display("  [PASS] %0s : acc_out = %0d (expected %0d)",
                         label, acc_out, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s : acc_out = %0d (expected %0d)",
                         label, acc_out, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // MAC step: drive inputs on negedge, wait for posedge to update
    task mac_step;
        input                en_in;
        input                clear_in;
        input signed [7:0]   a_in;
        input signed [7:0]   b_in;
        begin
            @(negedge clk);
            en    = en_in;
            clear = clear_in;
            a     = a_in;
            b     = b_in;
            @(posedge clk);
            #1;
        end
    endtask

    // Variables used in loops
    integer i;
    integer expected_acc;

    initial begin
        // Waveform dump
        $dumpfile("tb_mac_unit.vcd");
        $dumpvars(0, tb_mac_unit);

        $display("============================================================");
        $display("  tb_mac_unit : MAC unit testbench");
        $display("============================================================");

        // Initial state
        rst_n = 0;
        en    = 0;
        clear = 0;
        a     = 0;
        b     = 0;
        #23;
        rst_n = 1;
        #2;

        // ----------------------------------------
        // T1: After reset, acc_out should be 0
        // ----------------------------------------
        $display("\n[T1] after reset");
        check(32'sd0, "reset");

        // ----------------------------------------
        // T2: clear + compute 3 * 4 = 12
        // ----------------------------------------
        $display("\n[T2] clear + compute 3 * 4");
        mac_step(1, 1, 8'sd3, 8'sd4);
        check(32'sd12, "3 * 4");

        // ----------------------------------------
        // T3: accumulate 5 * 6 = 30, total = 12 + 30 = 42
        // ----------------------------------------
        $display("\n[T3] accumulate 5 * 6");
        mac_step(1, 0, 8'sd5, 8'sd6);
        check(32'sd42, "12 + 30");

        // Add another: 2 * 7 = 14, total = 42 + 14 = 56
        mac_step(1, 0, 8'sd2, 8'sd7);
        check(32'sd56, "42 + 14");

        // ----------------------------------------
        // T4: hold (en=0) - acc_out should NOT change
        // ----------------------------------------
        $display("\n[T4] hold (en=0)");
        mac_step(0, 0, 8'sd99, 8'sd99);   // inputs are garbage but en=0
        check(32'sd56, "hold after en=0");

        // ----------------------------------------
        // T5: negative numbers
        //   clear + (-5) * 4 = -20
        //   then accumulate 3 * (-6) = -18, total = -38
        //   then accumulate (-2) * (-7) = 14, total = -24
        // ----------------------------------------
        $display("\n[T5] signed arithmetic");
        mac_step(1, 1, -8'sd5,  8'sd4);
        check(-32'sd20, "clear with -5 * 4");

        mac_step(1, 0,  8'sd3, -8'sd6);
        check(-32'sd38, "-20 + (3 * -6)");

        mac_step(1, 0, -8'sd2, -8'sd7);
        check(-32'sd24, "-38 + (-2 * -7)");

        // ----------------------------------------
        // T6: long sequence - 25 MACs
        //   simulates one output element of a 5x5 conv
        //   activations: 1, 2, 3, ..., 25
        //   weights:     all = 2
        //   expected:    2 * (1+2+...+25) = 2 * 325 = 650
        // ----------------------------------------
        $display("\n[T6] 25-step accumulation (simulates 5x5 conv window)");
        expected_acc = 0;
        for (i = 1; i <= 25; i = i + 1) begin
            mac_step(1, (i == 1) ? 1 : 0, i[7:0], 8'sd2);
            expected_acc = expected_acc + i * 2;
        end
        check(expected_acc, "sum 2*i for i=1..25");

        // ----------------------------------------
        // Summary
        // ----------------------------------------
        $display("\n============================================================");
        $display("  Summary : %0d passed, %0d failed",
                 pass_count, fail_count);
        $display("============================================================");

        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  SOME TESTS FAILED");

        #20;
        $finish;
    end

endmodule
