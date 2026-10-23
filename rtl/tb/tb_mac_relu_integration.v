// ============================================================
// tb_mac_relu_integration.v
// ------------------------------------------------------------
// Integration test: mac_unit + relu chained together.
//
// Scenario: compute one output pixel of a convolution, including
// the activation function. This is the smallest meaningful
// "convolution output" datapath in LeNet-5 style inference.
//
// Test cases (each does 5 MACs then ReLU):
//   C1  all positive products        -> MAC result positive, ReLU passes
//   C2  mix but net positive         -> MAC result positive, ReLU passes
//   C3  mix but net negative         -> MAC result negative, ReLU outputs 0
//   C4  all zero                     -> MAC result 0, ReLU outputs 0
//
// Python reference for each case is computed by hand and baked in.
// ============================================================

`timescale 1ns / 1ps

module tb_mac_relu_integration;

    // ---- clock / reset / control ----
    reg         clk;
    reg         rst_n;
    reg         en;
    reg         clear;
    reg  signed [7:0]  a;
    reg  signed [7:0]  b;

    // ---- MAC output feeds ReLU input ----
    wire signed [31:0] mac_out;
    wire signed [31:0] relu_out;

    mac_unit #(.DATA_WIDTH(8), .ACC_WIDTH(32)) u_mac (
        .clk(clk), .rst_n(rst_n),
        .en(en), .clear(clear),
        .a(a), .b(b),
        .acc_out(mac_out)
    );

    relu #(.WIDTH(32)) u_relu (
        .din (mac_out),
        .dout(relu_out)
    );

    // ---- clock ----
    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    // MAC step helper (same pattern as tb_mac_unit)
    task mac_step;
        input                clear_in;
        input signed [7:0]   a_in;
        input signed [7:0]   b_in;
        begin
            @(negedge clk);
            en    = 1;
            clear = clear_in;
            a     = a_in;
            b     = b_in;
            @(posedge clk);
            #1;
        end
    endtask

    // Check both MAC output and ReLU output at end of a sequence
    task check_case;
        input signed [31:0] expected_mac;
        input signed [31:0] expected_relu;
        input [255:0]       label;
        begin
            if (mac_out === expected_mac && relu_out === expected_relu) begin
                $display("  [PASS] %0s : mac=%0d relu=%0d",
                         label, mac_out, relu_out);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s : mac=%0d (exp %0d) relu=%0d (exp %0d)",
                         label, mac_out, expected_mac, relu_out, expected_relu);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_mac_relu_integration.vcd");
        $dumpvars(0, tb_mac_relu_integration);

        $display("============================================================");
        $display("  tb_mac_relu_integration : MAC -> ReLU datapath");
        $display("============================================================");

        // Init
        rst_n = 0; en = 0; clear = 0; a = 0; b = 0;
        #23; rst_n = 1; #2;

        // ========================================================
        // C1: all positive
        //   (3,4)+(5,6)+(2,7)+(1,8)+(9,2)
        //   = 12+30+14+8+18 = 82
        //   ReLU(82) = 82
        // ========================================================
        $display("\n[C1] all positive products -> net positive");
        mac_step(1, 8'sd3, 8'sd4);    // clear then 3*4
        mac_step(0, 8'sd5, 8'sd6);
        mac_step(0, 8'sd2, 8'sd7);
        mac_step(0, 8'sd1, 8'sd8);
        mac_step(0, 8'sd9, 8'sd2);
        check_case(32'sd82, 32'sd82, "C1 net positive");

        // ========================================================
        // C2: mixed but net positive
        //   ( 10,  5) + ( -3,  4) + (  2,  6) + ( -1,  8) + (  5, 10)
        //   =  50     +  -12      +   12      +   -8      +   50
        //   =  92
        //   ReLU(92) = 92
        // ========================================================
        $display("\n[C2] mixed products -> net positive");
        mac_step(1,  8'sd10,  8'sd5);
        mac_step(0, -8'sd3,   8'sd4);
        mac_step(0,  8'sd2,   8'sd6);
        mac_step(0, -8'sd1,   8'sd8);
        mac_step(0,  8'sd5,   8'sd10);
        check_case(32'sd92, 32'sd92, "C2 net positive");

        // ========================================================
        // C3: mixed but net NEGATIVE  (this is the key case for ReLU)
        //   ( -10, 10) + ( -5,  5) + (  3,  2) + ( -2,  8) + (  1,  3)
        //   = -100     +  -25      +    6      +  -16      +    3
        //   = -132
        //   ReLU(-132) = 0      <-- ReLU must clip this!
        // ========================================================
        $display("\n[C3] mixed products -> net negative (ReLU clips to 0)");
        mac_step(1, -8'sd10,  8'sd10);
        mac_step(0, -8'sd5,   8'sd5);
        mac_step(0,  8'sd3,   8'sd2);
        mac_step(0, -8'sd2,   8'sd8);
        mac_step(0,  8'sd1,   8'sd3);
        check_case(-32'sd132, 32'sd0, "C3 net negative clipped");

        // ========================================================
        // C4: all zero inputs -> MAC stays at 0
        // ========================================================
        $display("\n[C4] all zero -> zero");
        mac_step(1, 8'sd0, 8'sd0);
        mac_step(0, 8'sd0, 8'sd0);
        mac_step(0, 8'sd0, 8'sd0);
        check_case(32'sd0, 32'sd0, "C4 zero");

        // ========================================================
        // Summary
        // ========================================================
        $display("\n============================================================");
        $display("  Summary : %0d passed, %0d failed", pass_count, fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("  ALL TESTS PASSED");
        else                 $display("  SOME TESTS FAILED");

        #20;
        $finish;
    end

endmodule
