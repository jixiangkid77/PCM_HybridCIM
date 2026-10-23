//============================================================
// tb_conv1_cache.v   (P2R-E8.5e, unit test U1 of rtl/e8/conv1_cache.v)
//============================================================
// Random stimulus against a reference written independently in
// the testbench (behavioural, per lane):
//   - host writes (wr_addr 0x22 and other addresses, which must
//     be ignored), random entries and values
//   - random layer_id (0..4), hits, orig_addr (conv1: oc*25 + l
//     with oc 0..5, otherwise any value), pool outputs
//   - expected: sram_hit_macro = hit & ~(layer 0 & hit) in the same
//     cycle; two cycles after a conv1 hit of lane l with oc, the
//     lane's weight = the reference storage at l*6 + oc and its hit
//     = 1; otherwise the pool's weight and hit
//   - a reset in the middle (stages cleared)
// Prints "U1 PASS" or "U1 FAIL" with the counts.
//
// Place  : rtl/e8/tb/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

module tb_conv1_cache;

    localparam integer K = 25, DW = 8, AW = 16, NOC = 6;
    localparam integer NCYC = 200000;

    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    reg              wr_en;
    reg  [5:0]       wr_addr;
    reg  [31:0]      wr_data;
    reg  [2:0]       layer_id;
    reg  [K*AW-1:0]  orig_addr_bus;
    reg  [K-1:0]     sram_hit_pool;
    reg  [K*DW-1:0]  pool_weight_bus;
    reg  [K-1:0]     pool_hit_reg_bus;
    wire [K-1:0]     sram_hit_macro;
    wire [K*DW-1:0]  weight_bus;
    wire [K-1:0]     hit_reg_bus;

    conv1_cache #(.K(K), .DATA_WIDTH(DW), .ADDR_WIDTH(AW)) dut (
        .clk(clk), .rst_n(rst_n), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .layer_id(layer_id), .orig_addr_bus(orig_addr_bus), .sram_hit_pool(sram_hit_pool),
        .sram_hit_macro(sram_hit_macro), .pool_weight_bus(pool_weight_bus), .pool_hit_reg_bus(pool_hit_reg_bus),
        .weight_bus(weight_bus), .hit_reg_bus(hit_reg_bus));

    // reference
    reg [DW-1:0] ref_mem [0:K*NOC-1];
    reg [K-1:0]  rsel1, rsel2;
    reg [2:0]    roc1 [0:K-1];
    reg [2:0]    roc2 [0:K-1];
    integer i, l, cyc, nerr, nchk, nconv, ncached, nwr, nign, oc;
    reg [K-1:0] rsel_now;
    reg [2:0]   roc_now [0:K-1];

    task automatic randomize_inputs;
        integer q, o;
        begin
            wr_en   = ($random & 7) == 0;
            wr_addr = (($random & 3) == 0) ? ($random & 6'h3f) : 6'h22;
            wr_data = {$random} ;
            wr_data[15:8] = {$random} % (K*NOC + 10);   // some out of range
            layer_id = (($random & 1) == 0) ? 3'd0 : ({$random} % 5);
            sram_hit_pool = $random;
            for (q = 0; q < K; q = q + 1) begin
                if (layer_id == 3'd0) begin
                    o = ({$random} % NOC) * 25 + q;
                    orig_addr_bus[q*AW +: AW] = o;
                end else begin
                    orig_addr_bus[q*AW +: AW] = $random;
                end
            end
            pool_weight_bus = {$random, $random, $random, $random, $random, $random, $random};
            pool_hit_reg_bus = $random;
        end
    endtask

    initial begin
        for (i = 0; i < K*NOC; i = i + 1) ref_mem[i] = 0;
        rsel1 = 0; rsel2 = 0;
        for (i = 0; i < K; i = i + 1) begin roc1[i] = 0; roc2[i] = 0; end
        nerr = 0; nchk = 0; nconv = 0; ncached = 0; nwr = 0; nign = 0;
        wr_en = 0; wr_addr = 0; wr_data = 0; layer_id = 0; orig_addr_bus = 0; sram_hit_pool = 0;
        pool_weight_bus = 0; pool_hit_reg_bus = 0;
        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
        for (cyc = 0; cyc < NCYC; cyc = cyc + 1) begin
            // inputs of this cycle (set after the rising edge)
            randomize_inputs;
            if (cyc == NCYC / 2) begin
                rst_n = 1'b0;          // asynchronous: the stages clear now
                rsel1 = 0; rsel2 = 0;
            end else if (cyc == NCYC / 2 + 2) begin
                rst_n = 1'b1;
            end
            #2;
            // combinational checks of this cycle
            for (l = 0; l < K; l = l + 1) begin
                rsel_now[l] = sram_hit_pool[l] && (layer_id == 3'd0);
                roc_now[l]  = orig_addr_bus[l*AW +: AW] / 25;
                if (sram_hit_macro[l] !== (sram_hit_pool[l] & ~rsel_now[l])) nerr = nerr + 1;
                if (rsel2[l]) begin
                    ncached = ncached + 1;
                    if (weight_bus[l*DW +: DW] !== ref_mem[l*NOC + roc2[l]] || hit_reg_bus[l] !== 1'b1) begin
                        nerr = nerr + 1;
                        if (nerr <= 5) $display("U1 mismatch cycle %0d lane %0d: cache %02h, expected %02h", cyc, l,
                                                weight_bus[l*DW +: DW], ref_mem[l*NOC + roc2[l]]);
                    end
                end else begin
                    if (weight_bus[l*DW +: DW] !== pool_weight_bus[l*DW +: DW] || hit_reg_bus[l] !== pool_hit_reg_bus[l]) begin
                        nerr = nerr + 1;
                        if (nerr <= 5) $display("U1 mismatch cycle %0d lane %0d: pool path", cyc, l);
                    end
                end
                nchk = nchk + 1;
            end
            if (layer_id == 3'd0) nconv = nconv + 1;
            // next rising edge: reference update
            @(posedge clk);
            if (!rst_n) begin
                rsel1 = 0; rsel2 = 0;
            end else begin
                rsel2 = rsel1;
                for (l = 0; l < K; l = l + 1) roc2[l] = roc1[l];
                rsel1 = rsel_now;
                for (l = 0; l < K; l = l + 1) roc1[l] = roc_now[l];
            end
            if (wr_en && wr_addr == 6'h22 && wr_data[15:8] < K*NOC) begin
                ref_mem[wr_data[15:8]] = wr_data[7:0];
                nwr = nwr + 1;
            end else if (wr_en) begin
                nign = nign + 1;
            end
            #1;
        end
        $display("U1 cycles %0d, lane checks %0d, conv1 cycles %0d, cached lane outputs %0d, cache writes %0d, ignored writes %0d, errors %0d",
                 NCYC, nchk, nconv, ncached, nwr, nign, nerr);
        if (nerr == 0 && ncached > 100000 && nwr > 1000) $display("U1 PASS"); else $display("U1 FAIL");
        $finish;
    end

endmodule
