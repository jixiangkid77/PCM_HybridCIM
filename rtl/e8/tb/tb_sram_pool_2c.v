//============================================================
// tb_sram_pool_2c.v   (P2R-E8.5c unit test)
//============================================================
// The two-cycle pool (rtl/e8/sram_pool_25lane_2c.v) against the
// unchanged one-cycle pool (rtl/src/sram_pool_25lane.v), both fed
// the same addresses and hits every cycle and holding the same
// memory contents (random, written into both before the test):
// the outputs of the new pool in cycle t must equal those of the
// unchanged pool in cycle t-1, in every cycle, for both outputs
// (weight_bus, hit_reg_bus), and both must be zero after a reset.
//
// Stimulus
//   sweep : every lane reads every one of the SRAM_TOTAL addresses
//           once (lane k reads (c + 123 k) mod SRAM_TOTAL in cycle c)
//   random: N_RAND cycles; per lane a random hit, and an address
//           that is in range (3/4) or out of range (1/4)
//   a reset in the middle of the random part
//
// Prints one line with the counts and "0 mismatches" when it
// passes.
//
// Place  : rtl/e8/tb/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

module tb_sram_pool_2c;

    localparam integer K          = 25;
    localparam integer DW         = 8;
    localparam integer AW         = 16;
    localparam integer TOTAL      = 3074;
    localparam integer N_RAND     = 200000;

    reg                 clk = 1'b0;
    reg                 rst_n = 1'b0;
    reg  [K*AW-1:0]     addr_bus = {K*AW{1'b0}};
    reg  [K-1:0]        hit_bus  = {K{1'b0}};
    wire [K*DW-1:0]     w_ref, w_new;
    wire [K-1:0]        h_ref, h_new;

    sram_pool_25lane    #(.K(K), .DATA_WIDTH(DW), .ADDR_WIDTH(AW), .SRAM_TOTAL(TOTAL), .DATA_DIR(""))
        U_REF (.clk(clk), .rst_n(rst_n), .addr_bus(addr_bus), .hit_bus(hit_bus), .weight_bus(w_ref), .hit_reg_bus(h_ref));
    sram_pool_25lane_2c #(.K(K), .DATA_WIDTH(DW), .ADDR_WIDTH(AW), .SRAM_TOTAL(TOTAL), .DATA_DIR(""))
        U_NEW (.clk(clk), .rst_n(rst_n), .addr_bus(addr_bus), .hit_bus(hit_bus), .weight_bus(w_new), .hit_reg_bus(h_new));

    always #5 clk = ~clk;

    integer i, k, c, seed;
    integer n_cmp, n_bad, n_hits_ref, n_rst_bad, n_lane_reads;
    reg  [K*DW-1:0] w_prev;
    reg  [K-1:0]    h_prev;
    reg             prev_valid;
    reg  [7:0]      v;

    // compare 1 ns after each rising edge (inputs change on the
    // falling edge): new(t) against ref(t-1)
    always @(posedge clk) begin
        #1;
        if (rst_n && prev_valid) begin
            n_cmp = n_cmp + 1;
            if (w_new !== w_prev || h_new !== h_prev) begin
                n_bad = n_bad + 1;
                if (n_bad <= 5)
                    $display("  [DIFF] t=%0t new w=%h h=%h, ref one cycle earlier w=%h h=%h", $time, w_new, h_new, w_prev, h_prev);
            end
            for (k = 0; k < K; k = k + 1) if (h_ref[k]) n_hits_ref = n_hits_ref + 1;
        end
        w_prev = w_ref;
        h_prev = h_ref;
        prev_valid = rst_n;
    end

    initial begin
        n_cmp = 0; n_bad = 0; n_hits_ref = 0; n_rst_bad = 0; n_lane_reads = 0;
        prev_valid = 1'b0;
        seed = 20261018;
        #1;
        for (i = 0; i < TOTAL; i = i + 1) begin
            v = $random(seed);
            U_REF.sram_pool_mem[i] = v;
            U_NEW.sram_pool_mem[i] = v;
        end
        @(negedge clk); @(negedge clk);
        rst_n = 1'b1;

        // sweep: every lane reads every address once
        for (c = 0; c < TOTAL; c = c + 1) begin
            @(negedge clk);
            for (k = 0; k < K; k = k + 1) begin
                addr_bus[k*AW +: AW] = (c + 123 * k) % TOTAL;
                hit_bus[k] = 1'b1;
            end
            n_lane_reads = n_lane_reads + K;
        end

        // random part, with a reset in the middle
        for (c = 0; c < N_RAND; c = c + 1) begin
            @(negedge clk);
            if (c == N_RAND / 2) begin
                rst_n = 1'b0;
                #1;
                if (w_new !== {K*DW{1'b0}} || h_new !== {K{1'b0}} || w_ref !== {K*DW{1'b0}} || h_ref !== {K{1'b0}})
                    n_rst_bad = n_rst_bad + 1;
                @(negedge clk);
                rst_n = 1'b1;
            end
            for (k = 0; k < K; k = k + 1) begin
                if (($random(seed) & 3) != 0)
                    addr_bus[k*AW +: AW] = {$random(seed)} % TOTAL;
                else
                    addr_bus[k*AW +: AW] = TOTAL + ({$random(seed)} % (65536 - TOTAL));
                hit_bus[k] = $random(seed);
            end
        end
        @(negedge clk); @(negedge clk); @(negedge clk);
        $display("sram_pool_25lane_2c against sram_pool_25lane one cycle earlier: %0d cycles compared, %0d lane hits, sweep %0d lane reads (every address on every lane), reset check %0d bad, %0d mismatches",
                 n_cmp, n_hits_ref, n_lane_reads, n_rst_bad, n_bad + n_rst_bad);
        $finish;
    end

endmodule
