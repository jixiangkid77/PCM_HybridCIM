//============================================================
// tb_sram_pool_bank.v   (P2R-E10 unit test U1)
//============================================================
// sram_pool_25bank_2c (new) against sram_pool_25lane_2c (E8.5c, the
// reference), same random pool contents, cycle by cycle. Stimulus as
// in operation: in each cycle a random first address a0 and a random
// set of hit lanes, which get the consecutive addresses a0, a0+1, ...
// in lane order (as the pools of both models are laid out); addresses
// past the pool are out of range in both. Lanes without a hit carry
// random addresses. Also 2% of cycles with no hit at all.
// Pass: 0 mismatches of weight_bus and hit_reg_bus, 0 conflicts and 0
// address errors of the new pool (its summary line), >= 100,000 lane
// reads.
//============================================================
`timescale 1ns/1ps
module tb_sram_pool_bank;
    localparam integer K = 25, DW = 8, AW = 16, TOTAL = 3074;
    localparam integer NCYC = 200000;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg  [K*AW-1:0] addr_bus;
    reg  [K-1:0]    hit_bus;
    wire [K*DW-1:0] w_ref, w_new;
    wire [K-1:0]    h_ref, h_new;
    sram_pool_25lane_2c #(.K(K), .DATA_WIDTH(DW), .ADDR_WIDTH(AW), .SRAM_TOTAL(TOTAL)) U_REF (
        .clk(clk), .rst_n(rst_n), .addr_bus(addr_bus), .hit_bus(hit_bus), .weight_bus(w_ref), .hit_reg_bus(h_ref));
    sram_pool_25bank_2c #(.K(K), .DATA_WIDTH(DW), .ADDR_WIDTH(AW), .SRAM_TOTAL(TOTAL)) U_NEW (
        .clk(clk), .rst_n(rst_n), .addr_bus(addr_bus), .hit_bus(hit_bus), .weight_bus(w_new), .hit_reg_bus(h_new));
    integer i, k, c, a0, nxt, seed, mism, lane_hits;
    reg [7:0] v;
    initial begin
        seed = 20261110;
        #0.5;
        for (i = 0; i < TOTAL; i = i + 1) begin
            v = $random(seed);
            U_REF.sram_pool_mem[i] = v;
            U_NEW.sram_pool_mem[i] = v;
        end
    end
    initial begin
        addr_bus = 0; hit_bus = 0; mism = 0; lane_hits = 0;
        repeat (4) @(posedge clk);
        #1 rst_n = 1;
        for (c = 0; c < NCYC; c = c + 1) begin
            @(negedge clk);
            a0 = {$random(seed)} % (TOTAL + 30);
            nxt = a0;
            for (k = 0; k < K; k = k + 1) begin
                if (({$random(seed)} % 100) < 2 || (c % 50) == 0) begin
                    hit_bus[k] = 1'b0;
                    addr_bus[k*AW +: AW] = $random(seed);
                end else if (({$random(seed)} % 100) < 55) begin
                    hit_bus[k] = 1'b1;
                    addr_bus[k*AW +: AW] = nxt;
                    nxt = nxt + 1;
                end else begin
                    hit_bus[k] = 1'b0;
                    addr_bus[k*AW +: AW] = $random(seed);
                end
            end
            if (({$random(seed)} % 100) < 2) hit_bus = 0;
            for (k = 0; k < K; k = k + 1)
                if (hit_bus[k] && addr_bus[k*AW +: AW] < TOTAL) lane_hits = lane_hits + 1;
        end
        @(negedge clk); hit_bus = 0;
        repeat (4) @(posedge clk);
        $display("U1: cycles %0d, lane hits in range %0d, output mismatches %0d", NCYC, lane_hits, mism);
        if (mism == 0 && lane_hits >= 100000) $display("U1 PASS"); else $display("U1 FAIL");
        $finish;
    end
    always @(posedge clk) begin
        #2;
        if (rst_n && (w_ref !== w_new || h_ref !== h_new)) begin
            mism = mism + 1;
            if (mism <= 5) $display("U1 mismatch at %0t: ref %h/%h new %h/%h", $time, h_ref, w_ref, h_new, w_new);
        end
    end
endmodule
