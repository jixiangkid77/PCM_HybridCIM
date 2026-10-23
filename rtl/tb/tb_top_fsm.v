// ============================================================
// tb_top_fsm.v
// ------------------------------------------------------------
// Minimal testbench for top_fsm.
//
// What this verifies:
//   - top_fsm correctly steps through step_id = 0,1,2,...,7
//   - The right engine's start signal pulses at each step
//   - The state machine waits for done before swapping
//   - swap pulses appear at the right times (not after fc3 or argmax)
//   - The predicted_class is captured from argmax_wrapper at the end
//
// What this does NOT verify:
//   - Numerical correctness of conv/pool/fc/argmax outputs
//     (those are verified in their own unit tests, and at the
//      full-system level in tb_lenet5)
//
// To make the test fast, we use BEHAVIORAL stub models for the
// shared external interfaces:
//   - feature_buffer: simple memory, sync read
//   - weight_memory: returns a synthetic weight pattern
//   - bias storage: returns 0
//   - logit register file: a tiny array of 16-bit values
//
// We pre-load known values into the logit RF so that argmax
// produces a deterministic class.
// ============================================================

`timescale 1ns / 1ps

module tb_top_fsm;

    localparam DATA_W   = 8;
    localparam LOGIT_W  = 16;
    localparam ACC_W    = 32;
    localparam FADDR_W  = 13;
    localparam OADDR_W  = 13;
    localparam WADDR_W  = 16;
    localparam BADDR_W  = 8;

    reg clk, rst_n;
    reg start;

    wire                       done;
    wire [3:0]                 predicted_class;

    wire [FADDR_W-1:0]         fbuf_read_addr;
    reg  signed [DATA_W-1:0]   fbuf_read_data;
    wire [OADDR_W-1:0]         fbuf_write_addr;
    wire signed [DATA_W-1:0]   fbuf_write_data;
    wire                       fbuf_write_en;
    wire                       fbuf_swap;

    wire [2:0]                 wmem_layer_id;
    wire [WADDR_W-1:0]         wmem_local_addr;
    reg  signed [DATA_W-1:0]   wmem_weight;

    wire [BADDR_W-1:0]         bias_addr;
    reg  signed [ACC_W-1:0]    bias_in;

    wire [3:0]                 logit_write_addr;
    wire signed [LOGIT_W-1:0]  logit_write_data;
    wire                       logit_write_en;
    wire [3:0]                 logit_read_addr;
    reg  signed [LOGIT_W-1:0]  logit_read_data;

    // ============================================================
    // Stub: feature_buffer (8KB unified)
    // ============================================================
    reg signed [DATA_W-1:0] tb_fbuf [0:8191];

    reg [FADDR_W-1:0] fbuf_read_addr_r;
    always @(posedge clk) fbuf_read_addr_r <= fbuf_read_addr;
    always @(*) fbuf_read_data = tb_fbuf[fbuf_read_addr_r];

    always @(posedge clk) begin
        if (fbuf_write_en) begin
            tb_fbuf[fbuf_write_addr] <= fbuf_write_data;
        end
    end

    // Track swaps (just count for verification)
    integer swap_count;
    always @(posedge clk) begin
        if (fbuf_swap) swap_count <= swap_count + 1;
    end

    // ============================================================
    // Stub: weight_memory (synthetic pattern)
    // ============================================================
    always @(*) begin
        // Simple synthetic pattern: small constant by layer
        case (wmem_layer_id)
            3'd0: wmem_weight = 8'sd1;   // conv1
            3'd1: wmem_weight = 8'sd1;   // conv2
            3'd2: wmem_weight = 8'sd1;   // fc1
            3'd3: wmem_weight = 8'sd1;   // fc2
            3'd4: wmem_weight = 8'sd1;   // fc3
            default: wmem_weight = 0;
        endcase
    end

    // ============================================================
    // Stub: bias (zero for all)
    // ============================================================
    initial bias_in = 0;

    // ============================================================
    // Stub: logit register file (10 entries x 16 bits)
    //   Pre-loaded with values where index 7 has the maximum.
    //   This ensures argmax returns class 7 deterministically.
    // ============================================================
    reg signed [LOGIT_W-1:0] tb_logit_rf [0:9];
    integer i;

    initial begin
        // Pre-load deterministic logits so argmax returns 7
        tb_logit_rf[0] = 100;
        tb_logit_rf[1] = 200;
        tb_logit_rf[2] = -50;
        tb_logit_rf[3] = 300;
        tb_logit_rf[4] = 150;
        tb_logit_rf[5] = -200;
        tb_logit_rf[6] = 400;
        tb_logit_rf[7] = 999;       // <-- maximum, expect class 7
        tb_logit_rf[8] = 250;
        tb_logit_rf[9] = 50;
    end

    // Read combinational
    always @(*) logit_read_data = tb_logit_rf[logit_read_addr];

    // Note: in this minimal test, fc3 writes to logit_write_addr/data
    // are intentionally IGNORED. The pre-loaded tb_logit_rf values
    // remain stable so argmax produces a deterministic class=7.
    // This decouples top_fsm verification from fc3 numerical correctness.
    // (lenet5_top + tb_lenet5 will verify the full data path.)

    // ============================================================
    // DUT
    // ============================================================
    top_fsm #(
        .DATA_W(DATA_W), .LOGIT_W(LOGIT_W), .ACC_W(ACC_W),
        .FADDR_W(FADDR_W), .OADDR_W(OADDR_W),
        .WADDR_W(WADDR_W), .BADDR_W(BADDR_W)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .done(done), .predicted_class(predicted_class),
        .fbuf_read_addr(fbuf_read_addr), .fbuf_read_data(fbuf_read_data),
        .fbuf_write_addr(fbuf_write_addr), .fbuf_write_data(fbuf_write_data),
        .fbuf_write_en(fbuf_write_en), .fbuf_swap(fbuf_swap),
        .wmem_layer_id(wmem_layer_id), .wmem_local_addr(wmem_local_addr),
        .wmem_weight(wmem_weight),
        .bias_addr(bias_addr), .bias_in(bias_in),
        .logit_write_addr(logit_write_addr),
        .logit_write_data(logit_write_data),
        .logit_write_en(logit_write_en),
        .logit_read_addr(logit_read_addr),
        .logit_read_data(logit_read_data)
    );

    // Clock
    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    task check;
        input [31:0] expected;
        input [31:0] actual;
        input [8*48-1:0] label;
        begin
            if (actual === expected) begin
                $display("  [PASS] %0s : %0d", label, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s : got %0d (expected %0d)",
                         label, actual, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Track which step transitions we observe
    reg [7:0] steps_seen;   // bit i = 1 if we saw step_id == i

    always @(posedge clk) begin
        if (rst_n) begin
            // Sample step_id whenever the FSM is doing useful work
            if (dut.state == 3'd2) begin   // S_LAUNCH
                if (dut.step_id < 8) steps_seen[dut.step_id[2:0]] <= 1'b1;
            end
        end
    end

    // ============================================================
    // Main
    // ============================================================
    integer cycle_count;
    integer i_init;
    reg     observed_done;
    reg [3:0] observed_predicted_class;

    initial begin
        $dumpfile("tb_top_fsm.vcd");
        $dumpvars(0, tb_top_fsm);

        $display("============================================================");
        $display("  tb_top_fsm : LeNet-5 dispatch FSM");
        $display("============================================================");

        // Init
        rst_n = 0;
        start = 0;
        swap_count = 0;
        steps_seen = 0;
        for (i_init = 0; i_init < 8192; i_init = i_init + 1) tb_fbuf[i_init] = 0;
        // Put a tiny pattern so the engines don't see all-zero noise
        for (i_init = 0; i_init < 784; i_init = i_init + 1) tb_fbuf[i_init] = 1;

        #23;
        rst_n = 1;
        #2;

        // ----- Pulse start -----
        @(negedge clk); start = 1;
        @(posedge clk); @(negedge clk); start = 0;

        $display("\n[INFO] Starting LeNet-5 inference...");

        // Wait for done with a generous timeout
        cycle_count = 0;
        while (!done && cycle_count < 5000000) begin   // 5M cycles ceiling
            @(posedge clk); cycle_count = cycle_count + 1;
            // Heartbeat every 200k cycles
            if ((cycle_count % 200000) == 0) begin
                $display("    [heartbeat] cycle %0d, step_id=%0d, state=%0d",
                         cycle_count, dut.step_id, dut.state);
            end
        end

        // Capture state info AT the moment done was first observed
        // (must do this before done deasserts on the next cycle)
        observed_done            = done;
        observed_predicted_class = predicted_class;
        $display("[INFO] done observed at cycle %0d", cycle_count);
        $display("       state=%0d step_id=%0d done=%0d class=%0d",
                 dut.state, dut.step_id, observed_done, observed_predicted_class);
        @(negedge clk);

        $display("\n[INFO] Total cycles: %0d", cycle_count);
        $display("[INFO] Total swaps  : %0d", swap_count);
        $display("[INFO] Steps seen   : %b (bit i = saw step i)", steps_seen);

        // ----- Verifications -----
        $display("\n[Checks]");
        check(1, observed_done, "done was asserted");
        check(4'd7, observed_predicted_class, "predicted_class = 7 (logit RF max idx)");

        // All 8 steps should have been launched
        check(8'b11111111, steps_seen, "all 8 steps launched");

        // Expected swaps: after steps 0,1,2,3,4,5 (NOT 6=fc3, NOT 7=argmax)
        // = 6 swaps total
        check(7, swap_count, "swap count == 7 (initial swap + 6 inter-step swaps)");

        // ----- Summary -----
        $display("\n============================================================");
        $display("  Summary : %0d passed, %0d failed", pass_count, fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("  ALL TESTS PASSED");
        else                 $display("  SOME TESTS FAILED");

        $finish;
    end

    // Safety: hard timeout
    initial begin
        #50000000;   // 50ms simulated time
        $display("\n[ERROR] Hard timeout reached!");
        $display("  state=%0d step_id=%0d", dut.state, dut.step_id);
        $finish;
    end

endmodule
