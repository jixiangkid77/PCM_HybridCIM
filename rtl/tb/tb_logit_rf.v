// ============================================================
// tb_logit_rf.v
// ------------------------------------------------------------
// Verifies logit_rf write/read, reset, boundary, and signed
// negative storage (key for fc3 logits).
// ============================================================

`timescale 1ns / 1ps

module tb_logit_rf;

    reg                   clk, rst_n;
    reg  [3:0]            write_addr;
    reg  signed [15:0]    write_data;
    reg                   write_en;
    reg  [3:0]            read_addr;
    wire signed [15:0]    read_data;

    logit_rf dut (
        .clk(clk), .rst_n(rst_n),
        .write_addr(write_addr), .write_data(write_data), .write_en(write_en),
        .read_addr(read_addr), .read_data(read_data)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    task check;
        input signed [15:0] expected;
        input [8*48-1:0]    label;
        begin
            if (read_data === expected) begin
                $display("  [PASS] %0s : %0d", label, read_data);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s : got %0d, expected %0d",
                         label, read_data, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task do_write;
        input [3:0]         addr;
        input signed [15:0] data;
        begin
            @(negedge clk);
            write_addr = addr;
            write_data = data;
            write_en   = 1'b1;
            @(posedge clk);
            @(negedge clk);
            write_en   = 1'b0;
        end
    endtask

    integer i;

    initial begin
        $dumpfile("tb_logit_rf.vcd");
        $dumpvars(0, tb_logit_rf);

        $display("============================================================");
        $display("  tb_logit_rf : 10x16-bit logit register file");
        $display("============================================================");

        rst_n      = 0;
        write_en   = 0;
        write_addr = 0;
        write_data = 0;
        read_addr  = 0;
        #23; rst_n = 1; #2;

        // ------------------------------------------------
        // T1: After reset, all entries should be 0
        // ------------------------------------------------
        $display("\n[T1] Reset clears all entries");
        for (i = 0; i < 10; i = i + 1) begin
            read_addr = i; #1;
            check(0, "after reset = 0");
        end

        // ------------------------------------------------
        // T2: Write a positive value, read back
        // ------------------------------------------------
        $display("\n[T2] Write positive value");
        do_write(4'd5, 16'sd1234);
        read_addr = 4'd5; #1;
        check(16'sd1234, "T2 entry 5 = 1234");

        // ------------------------------------------------
        // T3: Write a NEGATIVE value (critical for fc3 logits)
        // ------------------------------------------------
        $display("\n[T3] Write negative value (fc3 logit)");
        do_write(4'd3, -16'sd5678);
        read_addr = 4'd3; #1;
        check(-16'sd5678, "T3 entry 3 = -5678");

        // ------------------------------------------------
        // T4: Write all 10 entries with mix of values
        //     (simulates fc3 writing all logits)
        // ------------------------------------------------
        $display("\n[T4] Write all 10 entries");
        do_write(4'd0, 16'sd100);
        do_write(4'd1, -16'sd200);
        do_write(4'd2, 16'sd300);
        do_write(4'd3, -16'sd400);
        do_write(4'd4, 16'sd500);
        do_write(4'd5, -16'sd600);
        do_write(4'd6, 16'sd700);
        do_write(4'd7, 16'sd9999);    // max -- argmax should pick this
        do_write(4'd8, -16'sd800);
        do_write(4'd9, 16'sd900);

        $display("\n[T5] Read back all 10 entries");
        read_addr = 0; #1; check(16'sd100,   "T5 [0] = 100");
        read_addr = 1; #1; check(-16'sd200,  "T5 [1] = -200");
        read_addr = 2; #1; check(16'sd300,   "T5 [2] = 300");
        read_addr = 3; #1; check(-16'sd400,  "T5 [3] = -400");
        read_addr = 4; #1; check(16'sd500,   "T5 [4] = 500");
        read_addr = 5; #1; check(-16'sd600,  "T5 [5] = -600");
        read_addr = 6; #1; check(16'sd700,   "T5 [6] = 700");
        read_addr = 7; #1; check(16'sd9999,  "T5 [7] = 9999");
        read_addr = 8; #1; check(-16'sd800,  "T5 [8] = -800");
        read_addr = 9; #1; check(16'sd900,   "T5 [9] = 900");

        // ------------------------------------------------
        // T6: Boundary - 16-bit limits
        // ------------------------------------------------
        $display("\n[T6] 16-bit boundary values");
        do_write(4'd0, 16'sd32767);    // INT16 MAX
        read_addr = 4'd0; #1; check(16'sd32767, "T6 INT16_MAX = 32767");
        do_write(4'd1, -16'sd32768);   // INT16 MIN
        read_addr = 4'd1; #1; check(-16'sd32768, "T6 INT16_MIN = -32768");

        // ------------------------------------------------
        // T7: write_en = 0 should NOT update
        // ------------------------------------------------
        $display("\n[T7] write_en=0 holds value");
        @(negedge clk);
        write_addr = 4'd0;
        write_data = 16'sd9999;
        write_en   = 1'b0;          // disabled
        @(posedge clk);
        @(negedge clk);
        read_addr = 4'd0; #1;
        check(16'sd32767, "T7 entry 0 unchanged (still 32767)");

        $display("\n============================================================");
        $display("  Summary : %0d passed, %0d failed", pass_count, fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("  ALL TESTS PASSED");
        else                 $display("  SOME TESTS FAILED");

        $finish;
    end

endmodule
