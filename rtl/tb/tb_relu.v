// ============================================================
// tb_relu.v
// ------------------------------------------------------------
// Testbench for relu module.
// Covers:
//   T1  positive value       -> pass through
//   T2  negative value       -> output 0
//   T3  zero                 -> output 0
//   T4  max positive         -> pass through unchanged
//   T5  max negative         -> output 0
//   T6  barely negative (-1) -> output 0
//   T7  barely positive (+1) -> pass through
//   T8  8-bit parameterized  -> different WIDTH works
// ============================================================

`timescale 1ns / 1ps

module tb_relu;

    // 32-bit instance (for post-MAC use)
    reg  signed [31:0] din32;
    wire signed [31:0] dout32;

    relu #(.WIDTH(32)) dut32 (.din(din32), .dout(dout32));

    // 8-bit instance (for post-quantize use; also proves WIDTH parameter works)
    reg  signed [7:0] din8;
    wire signed [7:0] dout8;

    relu #(.WIDTH(8)) dut8 (.din(din8), .dout(dout8));

    integer pass_count = 0;
    integer fail_count = 0;

    task check32;
        input signed [31:0] expected;
        input [255:0]       label;
        begin
            #1;  // wait combinational logic to settle
            if (dout32 === expected) begin
                $display("  [PASS] %0s : din=%0d -> dout=%0d", label, din32, dout32);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s : din=%0d -> dout=%0d (expected %0d)",
                         label, din32, dout32, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task check8;
        input signed [7:0] expected;
        input [255:0]      label;
        begin
            #1;
            if (dout8 === expected) begin
                $display("  [PASS] %0s : din=%0d -> dout=%0d", label, din8, dout8);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s : din=%0d -> dout=%0d (expected %0d)",
                         label, din8, dout8, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_relu.vcd");
        $dumpvars(0, tb_relu);

        $display("============================================================");
        $display("  tb_relu : ReLU testbench (combinational)");
        $display("============================================================");

        // ---- 32-bit tests ----
        $display("\n[32-bit instance]");

        din32 = 32'sd100;            check32(32'sd100,          "T1  positive 100");
        din32 = -32'sd100;           check32(32'sd0,            "T2  negative -100");
        din32 = 32'sd0;              check32(32'sd0,            "T3  zero");
        din32 = 32'sh7FFF_FFFF;      check32(32'sh7FFF_FFFF,    "T4  max positive");
        din32 = 32'sh8000_0000;      check32(32'sd0,            "T5  max negative");
        din32 = -32'sd1;             check32(32'sd0,            "T6  barely negative -1");
        din32 = 32'sd1;              check32(32'sd1,            "T7  barely positive +1");
        din32 = 32'sd650;            check32(32'sd650,          "    realistic MAC sum +650");
        din32 = -32'sd12345;         check32(32'sd0,            "    realistic neg -12345");

        // ---- 8-bit tests (parameterization proof) ----
        $display("\n[8-bit instance]");
        din8 = 8'sd50;               check8(8'sd50,             "T8a 8b positive 50");
        din8 = -8'sd50;              check8(8'sd0,              "T8b 8b negative -50");
        din8 = 8'sd127;              check8(8'sd127,            "T8c 8b INT8_MAX +127");
        din8 = -8'sd128;             check8(8'sd0,              "T8d 8b INT8_MIN -128");

        // ---- Summary ----
        $display("\n============================================================");
        $display("  Summary : %0d passed, %0d failed", pass_count, fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("  ALL TESTS PASSED");
        else                 $display("  SOME TESTS FAILED");

        $finish;
    end

endmodule
