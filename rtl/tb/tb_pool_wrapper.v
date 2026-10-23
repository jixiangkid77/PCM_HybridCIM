// ============================================================
// tb_pool_wrapper.v
// ------------------------------------------------------------
// Testbench for pool_wrapper.
//
// Two scenarios:
//   S1: Hand-crafted 4x4 single channel, verified per output
//   S2: Real LeNet-5 pool1 shape (28x28x6 -> 14x14x6)
//       verified against software golden reference
// ============================================================

`timescale 1ns / 1ps

module tb_pool_wrapper;

    localparam DATA_W  = 8;
    localparam FADDR_W = 13;
    localparam OADDR_W = 13;

    reg                       clk;
    reg                       rst_n;
    reg                       start;

    wire [FADDR_W-1:0]        fmap_addr;
    reg  signed [DATA_W-1:0]  fmap_in;

    wire [OADDR_W-1:0]        out_addr;
    wire signed [DATA_W-1:0]  out_data;
    wire                      out_en;
    wire                      done;

    // ----- Test memory -----
    reg signed [DATA_W-1:0] tb_fmap   [0:8191];
    reg signed [DATA_W-1:0] tb_output [0:8191];
    reg signed [DATA_W-1:0] tb_golden [0:8191];

    // 1-cycle sync read model
    reg [FADDR_W-1:0] fmap_addr_r;
    always @(posedge clk) fmap_addr_r <= fmap_addr;
    always @(*) fmap_in = tb_fmap[fmap_addr_r];

    always @(posedge clk) begin
        if (out_en) tb_output[out_addr] <= out_data;
    end

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    task check;
        input signed [DATA_W-1:0] expected;
        input integer              addr;
        input [8*64-1:0]           label;
        begin
            if (tb_output[addr] === expected) begin
                $display("  [PASS] %0s @%0d : %0d", label, addr, tb_output[addr]);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s @%0d : %0d (expected %0d)",
                         label, addr, tb_output[addr], expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    integer mi;
    task clear_memories;
        begin
            for (mi = 0; mi < 8192; mi = mi + 1) begin
                tb_fmap[mi]   = 0;
                tb_output[mi] = 0;
                tb_golden[mi] = 0;
            end
        end
    endtask

    // ============================================================
    // Two DUT instances
    // ============================================================

    // DUT 1: 4x4x1 -> 2x2x1
    wire [FADDR_W-1:0] f1;
    wire [OADDR_W-1:0] o1;
    wire signed [DATA_W-1:0] d1;
    wire e1, dn1;
    reg  start_1;

    pool_wrapper #(
        .IN_H(4), .IN_W(4), .IN_CH(1),
        .OUT_H(2), .OUT_W(2),
        .DATA_W(DATA_W), .FADDR_W(FADDR_W), .OADDR_W(OADDR_W)
    ) dut1 (
        .clk(clk), .rst_n(rst_n), .start(start_1),
        .fmap_addr(f1), .fmap_in(fmap_in),
        .out_addr(o1), .out_data(d1), .out_en(e1),
        .done(dn1)
    );

    // DUT 2: 28x28x6 -> 14x14x6
    wire [FADDR_W-1:0] f2;
    wire [OADDR_W-1:0] o2;
    wire signed [DATA_W-1:0] d2;
    wire e2, dn2;
    reg  start_2;

    pool_wrapper #(
        .IN_H(28), .IN_W(28), .IN_CH(6),
        .OUT_H(14), .OUT_W(14),
        .DATA_W(DATA_W), .FADDR_W(FADDR_W), .OADDR_W(OADDR_W)
    ) dut2 (
        .clk(clk), .rst_n(rst_n), .start(start_2),
        .fmap_addr(f2), .fmap_in(fmap_in),
        .out_addr(o2), .out_data(d2), .out_en(e2),
        .done(dn2)
    );

    reg active_dut;
    assign fmap_addr = active_dut ? f2 : f1;
    assign out_addr  = active_dut ? o2 : o1;
    assign out_data  = active_dut ? d2 : d1;
    assign out_en    = active_dut ? e2 : e1;
    assign done      = active_dut ? dn2 : dn1;

    // ============================================================
    // Software golden reference
    // ============================================================
    integer ic, orow, ocol;
    integer ir_tl, ic_tl;
    reg signed [DATA_W-1:0] v00, v01, v10, v11, vmax;

    task compute_golden_2d;
        input integer P_IN_H, P_IN_W, P_IN_CH, P_OUT_H, P_OUT_W;
        begin
            for (ic = 0; ic < P_IN_CH; ic = ic + 1) begin
                for (orow = 0; orow < P_OUT_H; orow = orow + 1) begin
                    for (ocol = 0; ocol < P_OUT_W; ocol = ocol + 1) begin
                        ir_tl = orow * 2;
                        ic_tl = ocol * 2;
                        v00 = tb_fmap[ic * P_IN_H * P_IN_W + ir_tl * P_IN_W + ic_tl];
                        v01 = tb_fmap[ic * P_IN_H * P_IN_W + ir_tl * P_IN_W + ic_tl + 1];
                        v10 = tb_fmap[ic * P_IN_H * P_IN_W + (ir_tl + 1) * P_IN_W + ic_tl];
                        v11 = tb_fmap[ic * P_IN_H * P_IN_W + (ir_tl + 1) * P_IN_W + ic_tl + 1];
                        vmax = v00;
                        if (v01 > vmax) vmax = v01;
                        if (v10 > vmax) vmax = v10;
                        if (v11 > vmax) vmax = v11;
                        tb_golden[ic * P_OUT_H * P_OUT_W + orow * P_OUT_W + ocol] = vmax;
                    end
                end
            end
        end
    endtask

    task compare_all;
        input [8*32-1:0] label;
        input integer    total;
        integer k, local_fail;
        begin
            local_fail = 0;
            for (k = 0; k < total; k = k + 1) begin
                if (tb_output[k] !== tb_golden[k]) begin
                    $display("    diff @%0d : dut=%0d golden=%0d",
                             k, tb_output[k], tb_golden[k]);
                    local_fail = local_fail + 1;
                end
            end
            if (local_fail == 0) begin
                $display("  [PASS] %0s : all %0d outputs match golden", label, total);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s : %0d differ", label, local_fail);
                fail_count = fail_count + 1;
            end
        end
    endtask

    integer cycle_count;
    integer i;

    initial begin
        $dumpfile("tb_pool_wrapper.vcd");
        $dumpvars(0, tb_pool_wrapper);

        $display("============================================================");
        $display("  tb_pool_wrapper : 2x2 max-pool scanner");
        $display("============================================================");

        rst_n = 0;
        start_1 = 0;
        start_2 = 0;
        active_dut = 0;
        clear_memories;
        #23; rst_n = 1; #2;

        // ========================================================
        // SCENARIO 1: 4x4x1 -> 2x2x1
        //
        // input:   1   2   5   6
        //          3   4   7   8
        //          9  10  13  14
        //         11  12  15  16
        //
        // expected output (2x2 windows):
        //   max(1,2,3,4)       = 4
        //   max(5,6,7,8)       = 8
        //   max(9,10,11,12)    = 12
        //   max(13,14,15,16)   = 16
        // ========================================================
        $display("\n[Scenario 1] 4x4 -> 2x2 hand-computed");

        tb_fmap[0]=1;  tb_fmap[1]=2;  tb_fmap[2]=5;  tb_fmap[3]=6;
        tb_fmap[4]=3;  tb_fmap[5]=4;  tb_fmap[6]=7;  tb_fmap[7]=8;
        tb_fmap[8]=9;  tb_fmap[9]=10; tb_fmap[10]=13;tb_fmap[11]=14;
        tb_fmap[12]=11;tb_fmap[13]=12;tb_fmap[14]=15;tb_fmap[15]=16;

        active_dut = 0;

        @(negedge clk); start_1 = 1;
        @(posedge clk); @(negedge clk); start_1 = 0;

        cycle_count = 0;
        while (!done && cycle_count < 500) begin
            @(posedge clk); cycle_count = cycle_count + 1;
        end
        $display("  S1 cycles: %0d", cycle_count);
        @(negedge clk);

        check(4,  0, "S1 out[0][0]");
        check(8,  1, "S1 out[0][1]");
        check(12, 2, "S1 out[1][0]");
        check(16, 3, "S1 out[1][1]");

        compute_golden_2d(4, 4, 1, 2, 2);
        compare_all("S1 golden diff", 4);

        // ========================================================
        // SCENARIO 2: Real LeNet-5 pool1 shape
        //   28x28x6 -> 14x14x6
        //   Fill with a pattern that makes each window's max
        //   predictable: tb_fmap[i] = (i % 256) - 128
        // ========================================================
        $display("\n[Scenario 2] 28x28x6 -> 14x14x6 pool1 shape");

        clear_memories;
        for (i = 0; i < 28 * 28 * 6; i = i + 1) begin
            tb_fmap[i] = (i % 256) - 128;
        end

        active_dut = 1;

        @(negedge clk); start_2 = 1;
        @(posedge clk); @(negedge clk); start_2 = 0;

        cycle_count = 0;
        while (!done && cycle_count < 50000) begin
            @(posedge clk); cycle_count = cycle_count + 1;
        end
        $display("  S2 cycles: %0d", cycle_count);
        @(negedge clk);

        compute_golden_2d(28, 28, 6, 14, 14);
        compare_all("S2 golden diff", 14 * 14 * 6);

        // ========================================================
        // Summary
        // ========================================================
        $display("\n============================================================");
        $display("  Summary : %0d passed, %0d failed", pass_count, fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("  ALL TESTS PASSED");
        else                 $display("  SOME TESTS FAILED");

        $finish;
    end

endmodule
