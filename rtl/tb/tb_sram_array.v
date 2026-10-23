// ============================================================
// tb_sram_array.v   (Paper 2 v2 — K-channel parallel)
// ------------------------------------------------------------
// Unit tests for sram_array.v (K=25 parallel channels) using
// SYNTHETIC pattern.
//
// Test pattern:
//   - Even orig_addr -> in SRAM, slot = orig_addr/2
//   - Odd  orig_addr -> NOT in SRAM
//   - SRAM value stored = (layer*1000 + slot) lower 8 bits
//
// 1-cycle read latency: query at cycle N, result valid at cycle N+1.
// ============================================================

`timescale 1ns / 1ps

module tb_sram_array;

    localparam K = 25;
    localparam DW = 8;
    localparam AW = 16;

    reg                       clk;
    reg                       rst_n;
    reg  [2:0]                layer_id;
    reg  [K*AW-1:0]           orig_addr_bus;
    wire [K*DW-1:0]           weight_bus;
    wire [K-1:0]              in_sram_bus;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task chk;
        input [127:0] name;
        input cond;
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("  [PASS] %0s", name);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    function signed [DW-1:0] expected_w;
        input integer layer;
        input integer slot;
        begin
            expected_w = (layer * 1000 + slot) & 8'hFF;
        end
    endfunction

    sram_array #(.K(K)) DUT (
        .clk(clk),
        .rst_n(rst_n),
        .layer_id(layer_id),
        .orig_addr_bus(orig_addr_bus),
        .weight_bus(weight_bus),
        .in_sram_bus(in_sram_bus)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // Helper: pack one channel's address
    task set_addr;
        input integer ch;
        input [AW-1:0] a;
        begin
            orig_addr_bus[ch*AW +: AW] = a;
        end
    endtask

    task clear_addrs;
        integer i;
        begin
            orig_addr_bus = 0;
        end
    endtask

    // Helper: get a channel's weight from output bus
    function signed [DW-1:0] get_weight;
        input integer ch;
        begin
            get_weight = weight_bus[ch*DW +: DW];
        end
    endfunction

    // Helper: get a channel's in_sram flag
    function get_in_sram;
        input integer ch;
        begin
            get_in_sram = in_sram_bus[ch];
        end
    endfunction

    // Issue a query and wait one cycle for the registered output
    task query;
        input [2:0] L;
        begin
            @(negedge clk);
            layer_id = L;
            @(posedge clk);
            #1;
        end
    endtask

    integer i;

    initial begin
        $dumpfile("sim/tb_sram_array.vcd");
        $dumpvars(0, tb_sram_array);

        $display("============================================================");
        $display("tb_sram_array (K=25 parallel channels)");
        $display("============================================================");

        rst_n = 0;
        layer_id = 0;
        clear_addrs();
        // Hold reset for 3 cycles to let registers initialize
        @(posedge clk); @(posedge clk); @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---- T1: conv1 mixed even/odd addrs ----
        $display("[T1] conv1 mixed addresses");
        clear_addrs();
        set_addr(0, 16'd0);   // even -> SRAM slot 0
        set_addr(1, 16'd1);   // odd  -> NOT in SRAM
        set_addr(2, 16'd2);   // even -> SRAM slot 1
        set_addr(3, 16'd148); // even -> SRAM slot 74
        set_addr(4, 16'd149); // odd  -> NOT in SRAM
        // ch 5..24: addr=0 (in SRAM, repeats)
        query(3'd0);
        chk("ch0: a=0  in", get_in_sram(0) == 1);
        chk("ch0: a=0  w", get_weight(0) == expected_w(0, 0));
        chk("ch1: a=1  not_in", get_in_sram(1) == 0);
        chk("ch2: a=2  in", get_in_sram(2) == 1);
        chk("ch2: a=2  w", get_weight(2) == expected_w(0, 1));
        chk("ch3: a=148 in", get_in_sram(3) == 1);
        chk("ch3: a=148 w", get_weight(3) == expected_w(0, 74));
        chk("ch4: a=149 not_in", get_in_sram(4) == 0);

        // ---- T2: conv2 boundaries on multiple channels ----
        $display("[T2] conv2 boundaries");
        clear_addrs();
        set_addr(0, 16'd0);     // even -> in
        set_addr(1, 16'd2398);  // even -> slot 1199
        set_addr(2, 16'd2399);  // odd  -> not in
        set_addr(3, 16'd3000);  // out of range
        query(3'd1);
        chk("ch0 a=0  conv2 in", get_in_sram(0) == 1);
        chk("ch1 a=2398 in", get_in_sram(1) == 1);
        chk("ch1 a=2398 w", get_weight(1) == expected_w(1, 1199));
        chk("ch2 a=2399 not_in", get_in_sram(2) == 0);
        chk("ch3 a=3000 not_in (oob)", get_in_sram(3) == 0);

        // ---- T3: fc1 within synthetic capacity (335 slots, even addr 0..668) ----
        $display("[T3] fc1 within synthetic capacity");
        clear_addrs();
        set_addr(0, 16'd668);  // slot 334, in
        set_addr(1, 16'd670);  // slot 335 >= cap, not in
        query(3'd2);
        chk("ch0 fc1 a=668 in", get_in_sram(0) == 1);
        chk("ch0 fc1 a=668 w", get_weight(0) == expected_w(2, 334));
        chk("ch1 fc1 a=670 not_in", get_in_sram(1) == 0);

        // ---- T4: invalid layer_id ----
        $display("[T4] invalid layer_id");
        clear_addrs();
        set_addr(0, 16'd0);
        set_addr(1, 16'd2);
        query(3'd5);
        chk("ch0 invalid layer not_in", get_in_sram(0) == 0);
        chk("ch1 invalid layer not_in", get_in_sram(1) == 0);

        // ---- T5: layer switching ----
        $display("[T5] layer switching");
        clear_addrs();
        set_addr(0, 16'd0);
        query(3'd0);
        chk("conv1 a=0 in", get_in_sram(0) == 1 && get_weight(0) == expected_w(0,0));
        query(3'd1);
        chk("conv2 a=0 in", get_in_sram(0) == 1 && get_weight(0) == expected_w(1,0));
        query(3'd2);
        chk("fc1 a=0 in",   get_in_sram(0) == 1 && get_weight(0) == expected_w(2,0));

        // ---- T6: all 25 channels active simultaneously ----
        $display("[T6] all 25 channels active");
        clear_addrs();
        for (i = 0; i < K; i = i + 1) begin
            set_addr(i, i * 2);   // all even, all in SRAM, slot = i
        end
        query(3'd0);
        for (i = 0; i < K; i = i + 1) begin
            if (i < 75) begin  // conv1 has 150 weights, slots 0..149/2=74
                chk("ch[i] all-channels active", get_in_sram(i) == 1);
            end
        end

        // ---- Summary ----
        $display("------------------------------------------------------------");
        $display("Summary: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $display("============================================================");
        if (fail_cnt == 0) $display("[OK] tb_sram_array PASSED");
        else               $display("[FAIL] tb_sram_array FAILED");
        $finish;
    end

    initial begin
        #100000;
        $display("[FAIL] Watchdog timeout");
        $finish;
    end

endmodule
