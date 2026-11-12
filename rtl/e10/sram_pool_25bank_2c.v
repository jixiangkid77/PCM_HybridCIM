//============================================================
// sram_pool_25bank_2c.v   (P2R-E10: the SRAM pool as 25 single-port banks)
//============================================================
// Drop-in replacement of rtl/e8/sram_pool_25lane_2c.v (same ports,
// parameters and two-cycle timing). The 25 lanes of a datapath step
// read the protected weights of one entry; their pool addresses
// (layer base + slot) are consecutive in lane order, because each
// pool holds its weights in weight-index order and an entry is 25
// consecutive weights (checked for every entry of both models,
// scripts/e10_0_tables_check.py). Pool address a is therefore kept in
// bank a mod 25, row a div 25: the at most 25 addresses of a step fall
// into 25 different banks, so every bank is read at most once per
// cycle and a single-port macro per bank suffices (no replication).
//
// Address path, cycle s (combinational, from the address-map unit):
//   a0  = address of the lowest hit lane (the smallest address)
//   q0  = a0 div 25 = (a0 * 1311) >> 15   (exact for a0 < 4096)
//   r0  = a0 - 25 q0
//   lane k: j = (a_k - a0) mod 32  (< 25),  t = r0 + j,
//           bank = t < 25 ? t : t - 25
//   bank b: read when a hit lane maps to it; row = q0 + (b < r0)
// Data path: edge s+1 each read bank latches its word (macro read);
// edge s+2 lane k takes the word of the bank registered for it at
// s+1 -> weight_bus / hit_reg_bus two cycles after the address, as
// sram_pool_25lane_2c.
//
// Simulation only (not SYNTHESIS): sram_pool_mem holds the pool image
// as before (loaded from DATA_DIR, copied into the banks at 1 ns; the
// monitors of E8.5e read it), and every cycle the bank and row of each
// hit lane are checked against a mod 25 and a div 25, and two hit lanes
// in one bank are counted as a conflict; a summary line is printed at
// the end ("E10 POOL").
//
// Place  : rtl/e10/
// Status : NEW FILE.
//============================================================
`timescale 1ns/1ps

module sram_pool_25bank_2c #(
    parameter integer K          = 25,
    parameter integer DATA_WIDTH = 8,
    parameter integer ADDR_WIDTH = 16,
    parameter integer SRAM_TOTAL = 3074,
    parameter         DATA_DIR   = ""
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire [K*ADDR_WIDTH-1:0]    addr_bus,
    input  wire [K-1:0]               hit_bus,
    output reg  [K*DATA_WIDTH-1:0]    weight_bus,
    output reg  [K-1:0]               hit_reg_bus
);
    localparam integer NB = 25;     // banks
    localparam integer BD = 128;    // words per bank (>= ceil(SRAM_TOTAL / 25))
    localparam integer RW = 7;      // row address width
    localparam integer BW = 5;      // bank index width

`ifndef SYNTHESIS
    // simulation: image of the pool (loaded from DATA_DIR; copied into the banks at 1 ns)
    reg signed [DATA_WIDTH-1:0] sram_pool_mem [0:SRAM_TOTAL-1];
`endif

    //--------------------------------------------------------
    // lanes: address, hit within the pool
    //--------------------------------------------------------
    wire [ADDR_WIDTH-1:0] addr_l [0:K-1];
    wire [K-1:0]          valid;
    genvar g, b;
    generate
        for (g = 0; g < K; g = g + 1) begin : LN
            assign addr_l[g] = addr_bus[g*ADDR_WIDTH +: ADDR_WIDTH];
            assign valid[g]  = hit_bus[g] & ({1'b0, addr_l[g]} < SRAM_TOTAL);
        end
    endgenerate

    //--------------------------------------------------------
    // first hit lane, its address, div / mod 25
    //--------------------------------------------------------
    reg [ADDR_WIDTH-1:0] a0;
    integer i;
    always @(*) begin
        a0 = {ADDR_WIDTH{1'b0}};
        for (i = K - 1; i >= 0; i = i - 1)
            if (valid[i]) a0 = addr_l[i];
    end
    wire [22:0] prod = a0[11:0] * 11'd1311;
    wire [7:0]  q0   = prod[22:15];
    wire [12:0] q25  = {q0, 4'b0000} + {1'b0, q0, 3'b000} + {5'b00000, q0};
    wire [11:0] rem  = a0[11:0] - q25[11:0];
    wire [BW-1:0] r0 = rem[BW-1:0];

    //--------------------------------------------------------
    // bank of each lane
    //--------------------------------------------------------
    wire [BW-1:0] bank_l [0:K-1];
    wire [K-1:0]  wrap_l;
    generate
        for (g = 0; g < K; g = g + 1) begin : BK
            wire [BW-1:0] j = addr_l[g][BW-1:0] - a0[BW-1:0];
            wire [BW:0]   t = {1'b0, r0} + {1'b0, j};
            assign wrap_l[g] = (t >= 6'd25);
            wire [BW:0]   tw = t - 6'd25;
            assign bank_l[g] = wrap_l[g] ? tw[BW-1:0] : t[BW-1:0];
        end
    endgenerate

    //--------------------------------------------------------
    // banks: request, row, macro
    //--------------------------------------------------------
    wire [NB-1:0]            req;
    wire [NB*DATA_WIDTH-1:0] bq;
    generate
        for (b = 0; b < NB; b = b + 1) begin : BANK
            wire [K-1:0] m;
            for (g = 0; g < K; g = g + 1) begin : MAP
                assign m[g] = valid[g] & (bank_l[g] == b);
            end
            assign req[b] = |m;
            wire [7:0] row = q0 + ((b < r0) ? 8'd1 : 8'd0);
            sram_bank_128x8 #(.DEPTH(BD), .AW(RW), .DW(DATA_WIDTH)) U_BANK (
                .clk(clk), .csb(~req[b]), .addr(row[RW-1:0]), .dout(bq[b*DATA_WIDTH +: DATA_WIDTH])
            );
`ifndef SYNTHESIS
            integer r;
            initial begin
                #1;
                for (r = 0; r < BD; r = r + 1)
                    if (r * NB + b < SRAM_TOTAL) U_BANK.mem[r] = sram_pool_mem[r * NB + b];
            end
`endif
        end
    endgenerate

    //--------------------------------------------------------
    // stage 1: bank of each lane, hit; stage 2: the word
    //--------------------------------------------------------
    reg [BW-1:0] sel_s1 [0:K-1];
    reg [K-1:0]  hit_s1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hit_s1 <= {K{1'b0}};
            for (i = 0; i < K; i = i + 1) sel_s1[i] <= {BW{1'b0}};
        end else begin
            hit_s1 <= valid;
            for (i = 0; i < K; i = i + 1) sel_s1[i] <= bank_l[i];
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_bus  <= {(K*DATA_WIDTH){1'b0}};
            hit_reg_bus <= {K{1'b0}};
        end else begin
            for (i = 0; i < K; i = i + 1)
                weight_bus[i*DATA_WIDTH +: DATA_WIDTH] <=
                    hit_s1[i] ? bq[sel_s1[i]*DATA_WIDTH +: DATA_WIDTH] : {DATA_WIDTH{1'b0}};
            hit_reg_bus <= hit_s1;
        end
    end

`ifndef SYNTHESIS
    //--------------------------------------------------------
    // simulation: checks, summary (the pool image is declared above)
    //--------------------------------------------------------
    integer p;
    initial begin
        for (p = 0; p < SRAM_TOTAL; p = p + 1) sram_pool_mem[p] = {DATA_WIDTH{1'b0}};
        if (DATA_DIR != "") $readmemh({DATA_DIR, "/sram_pool.hex"}, sram_pool_mem);
        if (K != NB) $display("E10 POOL ERROR: K = %0d lanes, the bank mapping needs 25", K);
        if (SRAM_TOTAL > NB * BD) $display("E10 POOL ERROR: SRAM_TOTAL %0d > %0d", SRAM_TOTAL, NB * BD);
    end
    integer n_lane_reads = 0, n_bank_reads = 0, n_conflict_cycles = 0, n_addr_err = 0, deepest = -1;
    integer bank_reads [0:NB-1];
    integer x, y, cflag, dr;
    initial for (x = 0; x < NB; x = x + 1) bank_reads[x] = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            cflag = 0;
            for (x = 0; x < K; x = x + 1) begin
                if (valid[x]) begin
                    n_lane_reads = n_lane_reads + 1;
                    if (bank_l[x] != (addr_l[x] % NB) || (q0 + wrap_l[x]) != (addr_l[x] / NB))
                        n_addr_err = n_addr_err + 1;
                    dr = addr_l[x] / NB;          // integer: compared as signed with deepest
                    if (dr > deepest) deepest = dr;
                    for (y = x + 1; y < K; y = y + 1)
                        if (valid[y] && bank_l[y] == bank_l[x]) cflag = 1;
                end
            end
            if (cflag) n_conflict_cycles = n_conflict_cycles + 1;
            for (x = 0; x < NB; x = x + 1)
                if (req[x]) begin
                    n_bank_reads = n_bank_reads + 1;
                    bank_reads[x] = bank_reads[x] + 1;
                end
        end
    end
    integer bmin, bmax;
    final begin
        bmin = bank_reads[0]; bmax = bank_reads[0];
        for (x = 1; x < NB; x = x + 1) begin
            if (bank_reads[x] < bmin) bmin = bank_reads[x];
            if (bank_reads[x] > bmax) bmax = bank_reads[x];
        end
        $display("E10 POOL: lane reads %0d, bank reads %0d (per bank %0d to %0d), conflict cycles %0d, address errors %0d, deepest row %0d",
                 n_lane_reads, n_bank_reads, bmin, bmax, n_conflict_cycles, n_addr_err, deepest);
    end
`endif
endmodule
