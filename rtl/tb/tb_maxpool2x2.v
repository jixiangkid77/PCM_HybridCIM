// ============================================================
// tb_maxpool2x2.v
// ------------------------------------------------------------
// Testbench for maxpool2x2 module.
//
// Coverage:
//   T1-T4  max at each of the 4 positions
//   T5     all zero
//   T6     all equal (tie handling: any one is fine since
//          we only care about the value, not the position)
//   T7     all negative (tests signed arithmetic)
//   T8     all positive (post-ReLU realistic case)
//   T9     mixed positive + negative
//   T10    boundary values: INT8_MAX and INT8_MIN
// ============================================================

`timescale 1ns / 1ps

module tb_maxpool2x2;

    reg  signed [7:0] a00, a01, a10, a11;
    wire signed [7:0] dout;

    maxpool2x2 #(.WIDTH(8)) dut (
        .a00(a00), .a01(a01), .a10(a10), .a11(a11),
        .dout(dout)
    );

    integer pass_count = 0;
    integer fail_count = 0;

    task check;
        input signed [7:0] expected;
        input [8*64-1:0]   label;
        begin
            #1;
            if (dout === expected) begin
                $display("  [PASS] %0s : (%0d,%0d,%0d,%0d) -> %0d",
                         label, a00, a01, a10, a11, dout);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s : (%0d,%0d,%0d,%0d) -> %0d (expected %0d)",
                         label, a00, a01, a10, a11, dout, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_maxpool2x2.vcd");
        $dumpvars(0, tb_maxpool2x2);

        $display("============================================================");
        $display("  tb_maxpool2x2 : 2x2 max pooling testbench");
        $display("============================================================");

        // ---------------- Position tests ----------------
        $display("\n[Position tests] max at each of the 4 corners");

        // T1: max at top-left
        a00 = 8'sd50;  a01 = 8'sd10; a10 = 8'sd20; a11 = 8'sd30;
        check(8'sd50, "T1 max at a00");

        // T2: max at top-right
        a00 = 8'sd10;  a01 = 8'sd50; a10 = 8'sd20; a11 = 8'sd30;
        check(8'sd50, "T2 max at a01");

        // T3: max at bottom-left
        a00 = 8'sd10;  a01 = 8'sd20; a10 = 8'sd50; a11 = 8'sd30;
        check(8'sd50, "T3 max at a10");

        // T4: max at bottom-right
        a00 = 8'sd10;  a01 = 8'sd20; a10 = 8'sd30; a11 = 8'sd50;
        check(8'sd50, "T4 max at a11");

        // ---------------- Edge cases ----------------
        $display("\n[Edge cases]");

        // T5: all zero
        a00 = 0; a01 = 0; a10 = 0; a11 = 0;
        check(8'sd0, "T5 all zero");

        // T6: all equal
        a00 = 8'sd42; a01 = 8'sd42; a10 = 8'sd42; a11 = 8'sd42;
        check(8'sd42, "T6 all equal");

        // T7: all negative (signed check) -- max of negatives is closest to 0
        a00 = -8'sd10; a01 = -8'sd50; a10 = -8'sd30; a11 = -8'sd5;
        check(-8'sd5, "T7 all negative, max = -5");

        // T8: all positive (post-ReLU realistic)
        a00 = 8'sd12; a01 = 8'sd45; a10 = 8'sd7; a11 = 8'sd23;
        check(8'sd45, "T8 all positive (post-ReLU)");

        // T9: mixed signs
        a00 = -8'sd20; a01 = 8'sd15; a10 = -8'sd5; a11 = 8'sd10;
        check(8'sd15, "T9 mixed signs");

        // ---------------- Boundary ----------------
        $display("\n[Boundary tests]");

        // T10a: INT8_MAX present
        a00 = 8'sd127; a01 = -8'sd50; a10 = 8'sd30; a11 = 8'sd100;
        check(8'sd127, "T10a INT8_MAX present");

        // T10b: INT8_MIN present, rest small positive
        a00 = -8'sd128; a01 = 8'sd1; a10 = 8'sd2; a11 = 8'sd3;
        check(8'sd3, "T10b INT8_MIN present");

        // T10c: all at INT8_MIN
        a00 = -8'sd128; a01 = -8'sd128; a10 = -8'sd128; a11 = -8'sd128;
        check(-8'sd128, "T10c all INT8_MIN");

        // ---------------- Realistic LeNet-5 pool1 case ----------------
        $display("\n[Realistic LeNet-5 pool case]");

        // Simulating values that might emerge from ReLU(conv1):
        // A typical 2x2 window: three small activations and one strong one
        a00 = 8'sd3; a01 = 8'sd87; a10 = 8'sd12; a11 = 8'sd45;
        check(8'sd87, "pool1 typical window");

        // All zeros from ReLU (conv1 output was all negative) -- common
        a00 = 8'sd0; a01 = 8'sd0; a10 = 8'sd0; a11 = 8'sd0;
        check(8'sd0, "pool1 dead-neuron window");

        // ---- Summary ----
        $display("\n============================================================");
        $display("  Summary : %0d passed, %0d failed", pass_count, fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("  ALL TESTS PASSED");
        else                 $display("  SOME TESTS FAILED");

        $finish;
    end

endmodule
