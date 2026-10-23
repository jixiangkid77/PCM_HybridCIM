// ============================================================
// tb_layer_desc_rom.v
// ------------------------------------------------------------
// Testbench for layer_desc_rom.
//
// Verifies that every one of the 8 LeNet-5 steps produces the
// expected configuration, exactly matching the published
// LeNet-5 architecture:
//
//   Yann LeCun et al., "Gradient-Based Learning Applied to
//   Document Recognition," Proc. IEEE, 1998.
//
// with the contemporary simplifications used by most modern
// PyTorch implementations (single input channel, ReLU instead
// of tanh, per-layer biases, plain 2x2 max pooling).
// ============================================================

`timescale 1ns / 1ps

module tb_layer_desc_rom;

    reg  [3:0]  step_id;

    wire [1:0]  layer_kind;
    wire [7:0]  in_h, in_w, in_ch;
    wire [7:0]  out_h, out_w, out_ch;
    wire [3:0]  kernel, padding;
    wire [15:0] in_dim, out_dim;
    wire [3:0]  rshift;
    wire        use_relu;
    wire [2:0]  weight_layer;
    wire        is_last_step;

    layer_desc_rom dut (
        .step_id(step_id),
        .layer_kind(layer_kind),
        .in_h(in_h), .in_w(in_w), .in_ch(in_ch),
        .out_h(out_h), .out_w(out_w), .out_ch(out_ch),
        .kernel(kernel), .padding(padding),
        .in_dim(in_dim), .out_dim(out_dim),
        .rshift(rshift),
        .use_relu(use_relu),
        .weight_layer(weight_layer),
        .is_last_step(is_last_step)
    );

    // Kind constants mirror DUT
    localparam [1:0] KIND_CONV   = 2'b00;
    localparam [1:0] KIND_POOL   = 2'b01;
    localparam [1:0] KIND_FC     = 2'b10;
    localparam [1:0] KIND_ARGMAX = 2'b11;

    integer pass_count = 0;
    integer fail_count = 0;

    // Generic field checker
    task check_field;
        input [31:0]     expected;
        input [31:0]     actual;
        input [8*48-1:0] label;
        begin
            if (actual === expected) begin
                pass_count = pass_count + 1;
            end else begin
                $display("    [FAIL] %0s : got %0d, expected %0d",
                         label, actual, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Convert 2-bit kind to display name
    function [8*8-1:0] kind_name;
        input [1:0] k;
        case (k)
            KIND_CONV:   kind_name = "CONV    ";
            KIND_POOL:   kind_name = "POOL    ";
            KIND_FC:     kind_name = "FC      ";
            KIND_ARGMAX: kind_name = "ARGMAX  ";
            default:     kind_name = "???     ";
        endcase
    endfunction

    initial begin
        $dumpfile("tb_layer_desc_rom.vcd");
        $dumpvars(0, tb_layer_desc_rom);

        $display("============================================================");
        $display("  tb_layer_desc_rom : 8-step LeNet-5 configuration ROM");
        $display("============================================================");

        // ----------------------------------------------------------
        // STEP 0: conv1 28x28x1 -> 28x28x6, K=5, P=2
        // ----------------------------------------------------------
        step_id = 4'd0; #1;
        $display("\n[step 0] conv1  : %0s  %0dx%0dx%0d -> %0dx%0dx%0d  K=%0d P=%0d  wl=%0d  relu=%0d",
                 kind_name(layer_kind), in_h, in_w, in_ch, out_h, out_w, out_ch,
                 kernel, padding, weight_layer, use_relu);
        check_field(KIND_CONV, layer_kind,   "step0 kind");
        check_field(28, in_h,                "step0 in_h");
        check_field(28, in_w,                "step0 in_w");
        check_field(1,  in_ch,               "step0 in_ch");
        check_field(28, out_h,               "step0 out_h");
        check_field(28, out_w,               "step0 out_w");
        check_field(6,  out_ch,              "step0 out_ch");
        check_field(5,  kernel,              "step0 kernel");
        check_field(2,  padding,             "step0 padding");
        check_field(1,  use_relu,            "step0 use_relu");
        check_field(0,  weight_layer,        "step0 weight_layer");
        check_field(0,  is_last_step,        "step0 is_last_step");

        // ----------------------------------------------------------
        // STEP 1: pool1 28x28x6 -> 14x14x6
        // ----------------------------------------------------------
        step_id = 4'd1; #1;
        $display("\n[step 1] pool1  : %0s  %0dx%0dx%0d -> %0dx%0dx%0d  K=%0d",
                 kind_name(layer_kind), in_h, in_w, in_ch, out_h, out_w, out_ch, kernel);
        check_field(KIND_POOL, layer_kind,   "step1 kind");
        check_field(28, in_h,                "step1 in_h");
        check_field(6,  in_ch,               "step1 in_ch");
        check_field(14, out_h,               "step1 out_h");
        check_field(14, out_w,               "step1 out_w");
        check_field(6,  out_ch,              "step1 out_ch");
        check_field(2,  kernel,              "step1 kernel");
        check_field(0,  use_relu,            "step1 use_relu (pool no relu)");

        // ----------------------------------------------------------
        // STEP 2: conv2 14x14x6 -> 10x10x16, K=5, P=0
        // ----------------------------------------------------------
        step_id = 4'd2; #1;
        $display("\n[step 2] conv2  : %0s  %0dx%0dx%0d -> %0dx%0dx%0d  K=%0d P=%0d  wl=%0d  relu=%0d",
                 kind_name(layer_kind), in_h, in_w, in_ch, out_h, out_w, out_ch,
                 kernel, padding, weight_layer, use_relu);
        check_field(KIND_CONV, layer_kind,   "step2 kind");
        check_field(14, in_h,                "step2 in_h");
        check_field(6,  in_ch,               "step2 in_ch");
        check_field(10, out_h,               "step2 out_h");
        check_field(16, out_ch,              "step2 out_ch");
        check_field(5,  kernel,              "step2 kernel");
        check_field(0,  padding,             "step2 padding (no pad)");
        check_field(1,  use_relu,            "step2 use_relu");
        check_field(1,  weight_layer,        "step2 weight_layer");

        // ----------------------------------------------------------
        // STEP 3: pool2 10x10x16 -> 5x5x16
        // ----------------------------------------------------------
        step_id = 4'd3; #1;
        $display("\n[step 3] pool2  : %0s  %0dx%0dx%0d -> %0dx%0dx%0d",
                 kind_name(layer_kind), in_h, in_w, in_ch, out_h, out_w, out_ch);
        check_field(KIND_POOL, layer_kind,   "step3 kind");
        check_field(10, in_h,                "step3 in_h");
        check_field(16, in_ch,               "step3 in_ch");
        check_field(5,  out_h,               "step3 out_h");
        check_field(5,  out_w,               "step3 out_w");
        check_field(16, out_ch,              "step3 out_ch");

        // ----------------------------------------------------------
        // STEP 4: fc1 400 -> 120, ReLU
        // ----------------------------------------------------------
        step_id = 4'd4; #1;
        $display("\n[step 4] fc1    : %0s  %0d -> %0d  relu=%0d  wl=%0d",
                 kind_name(layer_kind), in_dim, out_dim, use_relu, weight_layer);
        check_field(KIND_FC, layer_kind,     "step4 kind");
        check_field(400, in_dim,             "step4 in_dim");
        check_field(120, out_dim,            "step4 out_dim");
        check_field(1,   use_relu,           "step4 use_relu");
        check_field(2,   weight_layer,       "step4 weight_layer");

        // ----------------------------------------------------------
        // STEP 5: fc2 120 -> 84, ReLU
        // ----------------------------------------------------------
        step_id = 4'd5; #1;
        $display("\n[step 5] fc2    : %0s  %0d -> %0d  relu=%0d  wl=%0d",
                 kind_name(layer_kind), in_dim, out_dim, use_relu, weight_layer);
        check_field(KIND_FC, layer_kind,     "step5 kind");
        check_field(120, in_dim,             "step5 in_dim");
        check_field(84,  out_dim,            "step5 out_dim");
        check_field(1,   use_relu,           "step5 use_relu");
        check_field(3,   weight_layer,       "step5 weight_layer");

        // ----------------------------------------------------------
        // STEP 6: fc3 84 -> 10, NO ReLU
        // ----------------------------------------------------------
        step_id = 4'd6; #1;
        $display("\n[step 6] fc3    : %0s  %0d -> %0d  relu=%0d  wl=%0d",
                 kind_name(layer_kind), in_dim, out_dim, use_relu, weight_layer);
        check_field(KIND_FC, layer_kind,     "step6 kind");
        check_field(84,  in_dim,             "step6 in_dim");
        check_field(10,  out_dim,            "step6 out_dim");
        check_field(0,   use_relu,           "step6 use_relu (MUST be 0 for logits)");
        check_field(4,   weight_layer,       "step6 weight_layer");

        // ----------------------------------------------------------
        // STEP 7: argmax 10 logits -> 1 class index, is_last_step
        // ----------------------------------------------------------
        step_id = 4'd7; #1;
        $display("\n[step 7] argmax : %0s  %0d -> %0d  last=%0d",
                 kind_name(layer_kind), in_dim, out_dim, is_last_step);
        check_field(KIND_ARGMAX, layer_kind, "step7 kind");
        check_field(10, in_dim,              "step7 in_dim (10 logits)");
        check_field(1,  out_dim,             "step7 out_dim (1 class)");
        check_field(1,  is_last_step,        "step7 is_last_step");

        // ----------------------------------------------------------
        // OUT-OF-RANGE: step_id = 8 or 15 should give zero values
        // (safe defaults, but not the last step)
        // ----------------------------------------------------------
        step_id = 4'd8; #1;
        $display("\n[step 8] out-of-range : kind=%0s in_h=%0d last=%0d",
                 kind_name(layer_kind), in_h, is_last_step);
        check_field(0, in_h,                 "step8 in_h (default 0)");
        check_field(0, is_last_step,         "step8 is_last_step (not last)");

        step_id = 4'd15; #1;
        check_field(0, in_h,                 "step15 in_h (default 0)");

        // ----------------------------------------------------------
        // SHAPE CONSISTENCY CHECKS
        // Verify that step N's output shape matches step N+1's
        // input shape (the data pipeline must be contiguous).
        // ----------------------------------------------------------
        $display("\n[Pipeline consistency] step N out == step N+1 in");
        begin : consistency_check
            reg [7:0] prev_out_h, prev_out_w, prev_out_ch;
            integer s;
            prev_out_h = 0; prev_out_w = 0; prev_out_ch = 0;
            for (s = 0; s < 4; s = s + 1) begin   // conv/pool steps only
                step_id = s[3:0]; #1;
                if (s > 0) begin
                    if (in_h === prev_out_h && in_w === prev_out_w && in_ch === prev_out_ch) begin
                        $display("  [PASS] step %0d in (%0dx%0dx%0d) matches prev out",
                                 s, in_h, in_w, in_ch);
                        pass_count = pass_count + 1;
                    end else begin
                        $display("  [FAIL] step %0d in (%0dx%0dx%0d) != prev out (%0dx%0dx%0d)",
                                 s, in_h, in_w, in_ch,
                                 prev_out_h, prev_out_w, prev_out_ch);
                        fail_count = fail_count + 1;
                    end
                end
                prev_out_h = out_h; prev_out_w = out_w; prev_out_ch = out_ch;
            end

            // fc1 in_dim should equal pool2 out_h * out_w * out_ch = 5*5*16 = 400
            step_id = 4'd3; #1;
            begin : fc1_check
                reg [15:0] expected_flat;
                expected_flat = out_h * out_w * out_ch;  // 5*5*16 = 400
                step_id = 4'd4; #1;
                if (in_dim === expected_flat) begin
                    $display("  [PASS] fc1 in_dim %0d = pool2 flat 5*5*16", in_dim);
                    pass_count = pass_count + 1;
                end else begin
                    $display("  [FAIL] fc1 in_dim %0d != pool2 flat %0d",
                             in_dim, expected_flat);
                    fail_count = fail_count + 1;
                end
            end

            // fc2 in_dim should equal fc1 out_dim = 120
            step_id = 4'd4; #1;
            begin : fc2_check
                reg [15:0] fc1_out;
                fc1_out = out_dim;
                step_id = 4'd5; #1;
                if (in_dim === fc1_out) begin
                    $display("  [PASS] fc2 in_dim (%0d) = fc1 out_dim", in_dim);
                    pass_count = pass_count + 1;
                end else begin
                    $display("  [FAIL] fc2 in_dim (%0d) != fc1 out_dim (%0d)", in_dim, fc1_out);
                    fail_count = fail_count + 1;
                end
            end

            // fc3 in_dim should equal fc2 out_dim = 84
            step_id = 4'd5; #1;
            begin : fc3_check
                reg [15:0] fc2_out;
                fc2_out = out_dim;
                step_id = 4'd6; #1;
                if (in_dim === fc2_out) begin
                    $display("  [PASS] fc3 in_dim (%0d) = fc2 out_dim", in_dim);
                    pass_count = pass_count + 1;
                end else begin
                    $display("  [FAIL] fc3 in_dim (%0d) != fc2 out_dim (%0d)", in_dim, fc2_out);
                    fail_count = fail_count + 1;
                end
            end

            // argmax in_dim should equal fc3 out_dim = 10
            step_id = 4'd6; #1;
            begin : argmax_check
                reg [15:0] fc3_out;
                fc3_out = out_dim;
                step_id = 4'd7; #1;
                if (in_dim === fc3_out) begin
                    $display("  [PASS] argmax in_dim (%0d) = fc3 out_dim", in_dim);
                    pass_count = pass_count + 1;
                end else begin
                    $display("  [FAIL] argmax in_dim (%0d) != fc3 out_dim (%0d)",
                             in_dim, fc3_out);
                    fail_count = fail_count + 1;
                end
            end
        end

        // ----------------------------------------------------------
        // Summary
        // ----------------------------------------------------------
        $display("\n============================================================");
        $display("  Summary : %0d passed, %0d failed", pass_count, fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("  ALL TESTS PASSED");
        else                 $display("  SOME TESTS FAILED");

        $finish;
    end

endmodule
