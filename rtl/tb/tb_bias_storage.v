// ============================================================
// tb_bias_storage.v
// ------------------------------------------------------------
// Verifies bias_storage produces the expected synthetic pattern
// for each layer and that out-of-range channels return safe 0.
// ============================================================

`timescale 1ns / 1ps

module tb_bias_storage;

    reg  [2:0]                 layer_id;
    reg  [7:0]                 channel;
    wire signed [31:0]         bias_out;

    bias_storage dut (
        .layer_id(layer_id),
        .channel(channel),
        .bias_out(bias_out)
    );

    integer pass_count = 0;
    integer fail_count = 0;

    task check;
        input signed [31:0] expected;
        input [8*48-1:0]    label;
        begin
            if (bias_out === expected) begin
                $display("  [PASS] %0s : %0d", label, bias_out);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s : got %0d, expected %0d",
                         label, bias_out, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_bias_storage.vcd");
        $dumpvars(0, tb_bias_storage);

        $display("============================================================");
        $display("  tb_bias_storage : per-layer per-channel bias ROM");
        $display("============================================================");

        // Settle initial block
        #1;

        // ------------------------------------------------
        // conv1 (layer 0): bias[0][c] = 0*100 + c - 50 = c - 50
        // ------------------------------------------------
        $display("\n[conv1 layer 0]");
        layer_id = 0; channel = 0;  #1; check(-50, "conv1 ch0 = -50");
        layer_id = 0; channel = 5;  #1; check(-45, "conv1 ch5 = -45");
        layer_id = 0; channel = 6;  #1; check(0,   "conv1 ch6 (out-of-range) = 0");

        // ------------------------------------------------
        // conv2 (layer 1): bias[1][c] = 100 + c - 50 = 50 + c
        // ------------------------------------------------
        $display("\n[conv2 layer 1]");
        layer_id = 1; channel = 0;  #1; check(50,  "conv2 ch0 = 50");
        layer_id = 1; channel = 15; #1; check(65,  "conv2 ch15 = 65");
        layer_id = 1; channel = 16; #1; check(0,   "conv2 ch16 (out-of-range) = 0");

        // ------------------------------------------------
        // fc1 (layer 2): bias[2][c] = 200 + c - 50 = 150 + c
        // ------------------------------------------------
        $display("\n[fc1 layer 2]");
        layer_id = 2; channel = 0;   #1; check(150, "fc1 ch0 = 150");
        layer_id = 2; channel = 100; #1; check(250, "fc1 ch100 = 250");
        layer_id = 2; channel = 119; #1; check(269, "fc1 ch119 = 269");

        // ------------------------------------------------
        // fc2 (layer 3): bias[3][c] = 300 + c - 50 = 250 + c
        // ------------------------------------------------
        $display("\n[fc2 layer 3]");
        layer_id = 3; channel = 0;  #1; check(250, "fc2 ch0 = 250");
        layer_id = 3; channel = 83; #1; check(333, "fc2 ch83 = 333");
        layer_id = 3; channel = 84; #1; check(0,   "fc2 ch84 (out-of-range) = 0");

        // ------------------------------------------------
        // fc3 (layer 4): bias[4][c] = 400 + c - 50 = 350 + c
        // ------------------------------------------------
        $display("\n[fc3 layer 4]");
        layer_id = 4; channel = 0; #1; check(350, "fc3 ch0 = 350");
        layer_id = 4; channel = 9; #1; check(359, "fc3 ch9 = 359");
        layer_id = 4; channel = 10; #1; check(0,  "fc3 ch10 (out-of-range) = 0");

        // ------------------------------------------------
        // Mix-sign confirmation: conv1 has both negative and pos ranges
        // ------------------------------------------------
        $display("\n[Sign mix]");
        layer_id = 0; channel = 0; #1; check(-50, "conv1 ch0 still negative");
        layer_id = 1; channel = 0; #1; check(50,  "conv2 ch0 still positive");

        $display("\n============================================================");
        $display("  Summary : %0d passed, %0d failed", pass_count, fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("  ALL TESTS PASSED");
        else                 $display("  SOME TESTS FAILED");

        $finish;
    end

endmodule
