// ============================================================
// tb_argmax_wrapper.v
// ------------------------------------------------------------
// Testbench for argmax_wrapper.
//
// Four scenarios:
//   T1: max at index 5 in the middle
//   T2: max at index 0 (boundary)
//   T3: max at index 9 (boundary)
//   T4: mix of positive and negative logits, real fc3-style
//       (proves the wrapper handles signed INT16 correctly)
// ============================================================

`timescale 1ns / 1ps

module tb_argmax_wrapper;

    localparam LOGIT_W = 16;

    reg  clk, rst_n, start;

    wire [3:0]                  logit_addr;
    reg  signed [LOGIT_W-1:0]   logit_in;

    wire [3:0] class_out;
    wire       done;

    // TB-side logit table (the "logit buffer")
    reg signed [LOGIT_W-1:0] tb_logits [0:15];

    always @(*) logit_in = tb_logits[logit_addr];

    argmax_wrapper #(.LOGIT_W(LOGIT_W)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .logit_addr(logit_addr),
        .logit_in(logit_in),
        .class_out(class_out),
        .done(done)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    task check_class;
        input [3:0]     expected;
        input [8*48-1:0] label;
        begin
            if (class_out === expected) begin
                $display("  [PASS] %0s : class=%0d", label, class_out);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s : class=%0d (expected %0d)",
                         label, class_out, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    integer i;
    integer cycle_count;

    task clear_logits;
        begin
            for (i = 0; i < 16; i = i + 1) tb_logits[i] = 0;
        end
    endtask

    task run_and_wait;
        begin
            @(negedge clk); start = 1;
            @(posedge clk); @(negedge clk); start = 0;
            cycle_count = 0;
            while (!done && cycle_count < 100) begin
                @(posedge clk); cycle_count = cycle_count + 1;
            end
            @(negedge clk);
        end
    endtask

    initial begin
        $dumpfile("tb_argmax_wrapper.vcd");
        $dumpvars(0, tb_argmax_wrapper);

        $display("============================================================");
        $display("  tb_argmax_wrapper : 10-way argmax via sequential read");
        $display("============================================================");

        rst_n = 0;
        start = 0;
        clear_logits;
        #23; rst_n = 1; #2;

        // --------------------------------------------------------
        // T1: max at index 5
        // --------------------------------------------------------
        $display("\n[T1] max at idx 5");
        tb_logits[0]=10; tb_logits[1]=20; tb_logits[2]=30; tb_logits[3]=40;
        tb_logits[4]=50; tb_logits[5]=500; tb_logits[6]=60; tb_logits[7]=70;
        tb_logits[8]=80; tb_logits[9]=90;
        run_and_wait;
        $display("  T1 cycles: %0d", cycle_count);
        check_class(4'd5, "T1 max at 5");

        // --------------------------------------------------------
        // T2: max at index 0 (boundary)
        // --------------------------------------------------------
        $display("\n[T2] max at idx 0");
        clear_logits;
        tb_logits[0]=1000; tb_logits[1]=1; tb_logits[2]=2; tb_logits[3]=3;
        tb_logits[4]=4;    tb_logits[5]=5; tb_logits[6]=6; tb_logits[7]=7;
        tb_logits[8]=8;    tb_logits[9]=9;
        run_and_wait;
        check_class(4'd0, "T2 max at 0");

        // --------------------------------------------------------
        // T3: max at index 9 (boundary)
        // --------------------------------------------------------
        $display("\n[T3] max at idx 9");
        clear_logits;
        tb_logits[0]=1; tb_logits[1]=2; tb_logits[2]=3; tb_logits[3]=4;
        tb_logits[4]=5; tb_logits[5]=6; tb_logits[6]=7; tb_logits[7]=8;
        tb_logits[8]=9; tb_logits[9]=1000;
        run_and_wait;
        check_class(4'd9, "T3 max at 9");

        // --------------------------------------------------------
        // T4: realistic fc3 logits with mix of +/- values
        //     max should be at index 7
        // --------------------------------------------------------
        $display("\n[T4] fc3-style mixed-sign logits");
        clear_logits;
        tb_logits[0]=-50;  tb_logits[1]=123;  tb_logits[2]=-200;
        tb_logits[3]=45;   tb_logits[4]=-10;  tb_logits[5]=89;
        tb_logits[6]=-500; tb_logits[7]=999;  tb_logits[8]=-32;
        tb_logits[9]=456;
        run_and_wait;
        check_class(4'd7, "T4 mixed-sign max at 7");

        // --------------------------------------------------------
        // T5: all negative, max is "least negative" at idx 3
        // --------------------------------------------------------
        $display("\n[T5] all negative");
        clear_logits;
        tb_logits[0]=-100; tb_logits[1]=-200; tb_logits[2]=-150;
        tb_logits[3]=-5;   tb_logits[4]=-80;  tb_logits[5]=-90;
        tb_logits[6]=-120; tb_logits[7]=-70;  tb_logits[8]=-60;
        tb_logits[9]=-50;
        run_and_wait;
        check_class(4'd3, "T5 all neg, max at 3");

        // --------------------------------------------------------
        // T6: tie at idx 2 and 5 -- lower wins (matches argmax10)
        // --------------------------------------------------------
        $display("\n[T6] tie, lower wins");
        clear_logits;
        tb_logits[0]=10; tb_logits[1]=10; tb_logits[2]=100;
        tb_logits[3]=10; tb_logits[4]=10; tb_logits[5]=100;
        tb_logits[6]=10; tb_logits[7]=10; tb_logits[8]=10; tb_logits[9]=10;
        run_and_wait;
        check_class(4'd2, "T6 tie 2 vs 5 -> 2");

        // --------------------------------------------------------
        // Summary
        // --------------------------------------------------------
        $display("\n============================================================");
        $display("  Summary : %0d passed, %0d failed", pass_count, fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("  ALL TESTS PASSED");
        else                 $display("  SOME TESTS FAILED");

        $finish;
    end

endmodule
