// ============================================================
// tb_argmax10.v
// ------------------------------------------------------------
// Testbench for argmax10 module (combinational).
//
// Coverage:
//   T1  max at index 0
//   T2  max at index 9
//   T3  max at index 4 (middle)
//   T4  all negative (realistic for wrong-class logits)
//   T5  tie at indices 2 and 5 -> lower wins (idx 2)
//   T6  tie at 0 and 9         -> idx 0 wins
//   T7  all equal              -> idx 0 wins
//   T8  REAL golden data from img_001: should predict class 8
//   T9  REAL golden data variant: shift max to index 3
// ============================================================

`timescale 1ns / 1ps

module tb_argmax10;

    reg  signed [15:0] v [0:9];
    wire [3:0]         idx_out;

    argmax10 #(.WIDTH(16)) dut (
        .in0(v[0]), .in1(v[1]), .in2(v[2]), .in3(v[3]), .in4(v[4]),
        .in5(v[5]), .in6(v[6]), .in7(v[7]), .in8(v[8]), .in9(v[9]),
        .idx_out(idx_out)
    );

    integer pass_count = 0;
    integer fail_count = 0;

    task check;
        input [3:0]   expected;
        input [255:0] label;
        begin
            #1;
            if (idx_out === expected) begin
                $display("  [PASS] %0s : idx=%0d (expected %0d)",
                         label, idx_out, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s : idx=%0d (expected %0d)",
                         label, idx_out, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task set_all;
        input signed [15:0] val;
        integer k;
        begin
            for (k = 0; k < 10; k = k + 1) v[k] = val;
        end
    endtask

    initial begin
        $dumpfile("tb_argmax10.vcd");
        $dumpvars(0, tb_argmax10);

        $display("============================================================");
        $display("  tb_argmax10 : 10-way argmax testbench");
        $display("============================================================");

        // ---------------------------------------------------------
        // T1: max at index 0
        // ---------------------------------------------------------
        $display("\n[T1] max at index 0");
        set_all(16'sd0);
        v[0] = 16'sd100;
        check(4'd0, "max at idx 0");

        // ---------------------------------------------------------
        // T2: max at index 9
        // ---------------------------------------------------------
        $display("\n[T2] max at index 9");
        set_all(16'sd0);
        v[9] = 16'sd100;
        check(4'd9, "max at idx 9");

        // ---------------------------------------------------------
        // T3: max in middle
        // ---------------------------------------------------------
        $display("\n[T3] max at index 4");
        v[0] = 16'sd10;  v[1] = 16'sd20;  v[2] = 16'sd30;  v[3] = 16'sd40;
        v[4] = 16'sd999; v[5] = 16'sd50;  v[6] = 16'sd60;  v[7] = 16'sd70;
        v[8] = 16'sd80;  v[9] = 16'sd90;
        check(4'd4, "max at idx 4");

        // ---------------------------------------------------------
        // T4: all negative (realistic "wrong class" pattern)
        // Max = -5 at idx 7
        // ---------------------------------------------------------
        $display("\n[T4] all negative, max -5 at idx 7");
        v[0] = -16'sd100; v[1] = -16'sd200; v[2] = -16'sd50;  v[3] = -16'sd80;
        v[4] = -16'sd60;  v[5] = -16'sd30;  v[6] = -16'sd200; v[7] = -16'sd5;
        v[8] = -16'sd40;  v[9] = -16'sd25;
        check(4'd7, "all-negative max");

        // ---------------------------------------------------------
        // T5: tie between idx 2 and idx 5 -> lower wins (idx 2)
        // ---------------------------------------------------------
        $display("\n[T5] tie at idx 2 and 5 -> idx 2 wins");
        set_all(16'sd10);
        v[2] = 16'sd500;
        v[5] = 16'sd500;
        check(4'd2, "tie 2 vs 5");

        // ---------------------------------------------------------
        // T6: tie at idx 0 and 9 -> idx 0 wins
        // ---------------------------------------------------------
        $display("\n[T6] tie at idx 0 and 9 -> idx 0 wins");
        set_all(16'sd10);
        v[0] = 16'sd300;
        v[9] = 16'sd300;
        check(4'd0, "tie 0 vs 9");

        // ---------------------------------------------------------
        // T7: all equal -> idx 0 wins
        // ---------------------------------------------------------
        $display("\n[T7] all equal -> idx 0 wins");
        set_all(16'sd42);
        check(4'd0, "all equal");

        // ---------------------------------------------------------
        // T8: REAL GOLDEN DATA from data/golden/img_001/fc3_out.dec.txt
        //   logits = [-58, -96, -47, -12, -60, 13, -87, -69, 127, -24]
        //   PyTorch predicts class 8 (value 127 is max)
        //   RTL must agree.
        // ---------------------------------------------------------
        $display("\n[T8] REAL golden data img_001 -> predict 8");
        v[0] = -16'sd58;  v[1] = -16'sd96;  v[2] = -16'sd47;  v[3] = -16'sd12;
        v[4] = -16'sd60;  v[5] =  16'sd13;  v[6] = -16'sd87;  v[7] = -16'sd69;
        v[8] =  16'sd127; v[9] = -16'sd24;
        check(4'd8, "img_001 predict class 8");

        // ---------------------------------------------------------
        // T9: golden-data variant with max moved to idx 3
        //   Verifies we can match PyTorch on any class, not just 8
        // ---------------------------------------------------------
        $display("\n[T9] golden-style data, max at idx 3");
        v[0] = -16'sd58;  v[1] = -16'sd96;  v[2] = -16'sd47;  v[3] =  16'sd200;
        v[4] = -16'sd60;  v[5] =  16'sd13;  v[6] = -16'sd87;  v[7] = -16'sd69;
        v[8] =  16'sd127; v[9] = -16'sd24;
        check(4'd3, "max moved to idx 3");

        // ---- Summary ----
        $display("\n============================================================");
        $display("  Summary : %0d passed, %0d failed", pass_count, fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("  ALL TESTS PASSED");
        else                 $display("  SOME TESTS FAILED");

        $finish;
    end

endmodule
