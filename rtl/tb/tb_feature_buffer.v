// ============================================================
// tb_feature_buffer.v
// ------------------------------------------------------------
// Testbench for feature_buffer module (ping-pong SRAM).
//
// Coverage:
//   T1  Basic write-then-read
//       Write 3 values to the write-side, swap, then read them
//       back from the read-side.
//
//   T2  Ping-pong correctness
//       Write pattern X to write-side, swap, write pattern Y to
//       new write-side (the old read-side), swap again, read
//       pattern X back, swap, read pattern Y.
//
//   T3  No contamination of read side
//       While writing to the write-side, read the same address
//       on the read-side (which should reflect whatever was
//       there before, NOT the newly written data).
//
//   T4  Repeated swaps
//       Swap 6 times (full LeNet-5 layer transition chain) and
//       verify data consistency.
//
//   T5  Realistic LeNet-5 layer transition
//       Simulate one conv-then-pool pipeline step.
// ============================================================

`timescale 1ns / 1ps

module tb_feature_buffer;

    // Parameters (smaller depth for faster simulation)
    localparam DATA_WIDTH = 8;
    localparam DEPTH      = 32;
    localparam ADDR_WIDTH = 5;

    reg                              clk;
    reg                              rst_n;
    reg  [ADDR_WIDTH-1:0]            write_addr;
    reg  signed [DATA_WIDTH-1:0]     write_data;
    reg                              write_en;
    reg  [ADDR_WIDTH-1:0]            read_addr;
    wire signed [DATA_WIDTH-1:0]     read_data;
    reg                              swap;
    wire                             which_is_write;

    feature_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(DEPTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .write_addr(write_addr), .write_data(write_data), .write_en(write_en),
        .read_addr(read_addr), .read_data(read_data),
        .swap(swap),
        .which_is_write(which_is_write)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    task check_read;
        input signed [DATA_WIDTH-1:0] expected;
        input [8*64-1:0]              label;
        begin
            // read_data is registered; allow 1 cycle to settle
            if (read_data === expected) begin
                $display("  [PASS] %0s : read_data=%0d (expected %0d)",
                         label, read_data, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s : read_data=%0d (expected %0d)",
                         label, read_data, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Write one value (addr+data in same cycle, completes next posedge)
    task do_write;
        input [ADDR_WIDTH-1:0]         a;
        input signed [DATA_WIDTH-1:0]  d;
        begin
            @(negedge clk);
            write_addr = a;
            write_data = d;
            write_en   = 1;
            @(posedge clk);
            #1;
            @(negedge clk);
            write_en = 0;
        end
    endtask

    // Issue a read (data appears 1 cycle later)
    task do_read;
        input [ADDR_WIDTH-1:0] a;
        begin
            @(negedge clk);
            read_addr = a;
            @(posedge clk);
            #1;
        end
    endtask

    // Trigger a swap
    task do_swap;
        begin
            @(negedge clk);
            swap = 1;
            @(posedge clk);
            #1;
            @(negedge clk);
            swap = 0;
        end
    endtask

    initial begin
        $dumpfile("tb_feature_buffer.vcd");
        $dumpvars(0, tb_feature_buffer);

        $display("============================================================");
        $display("  tb_feature_buffer : ping-pong buffer testbench");
        $display("============================================================");

        // Init
        rst_n = 0;
        write_addr = 0; write_data = 0; write_en = 0;
        read_addr = 0;
        swap = 0;
        #23; rst_n = 1; #2;

        // ==================================================
        // T1: Basic write -> swap -> read
        // After reset, role_sel=0 (A=write, B=read)
        //   Step 1: write 3 values into A
        //   Step 2: swap (A becomes read, B becomes write)
        //   Step 3: read those 3 values
        // ==================================================
        $display("\n[T1] Basic write -> swap -> read");
        $display("  (role_sel=%0d, so writing to %0s)",
                 which_is_write, which_is_write ? "B" : "A");

        do_write(5'd0, 8'sd11);
        do_write(5'd1, 8'sd22);
        do_write(5'd2, 8'sd33);

        do_swap;
        $display("  (after swap, role_sel=%0d, reading from what was the write side)",
                 which_is_write);

        do_read(5'd0); check_read(8'sd11, "T1 addr=0 -> 11");
        do_read(5'd1); check_read(8'sd22, "T1 addr=1 -> 22");
        do_read(5'd2); check_read(8'sd33, "T1 addr=2 -> 33");

        // ==================================================
        // T2: Ping-pong correctness
        // Currently B is write-side (after T1's swap).
        //   Write pattern Y to B at addresses 10..12
        //   Swap again -> A is write-side, B is read-side
        //   Read Y back from B
        //   Swap -> A read, B write
        //   Read X (from T1, stored in A) back
        // ==================================================
        $display("\n[T2] Ping-pong correctness");

        do_write(5'd10, 8'sd44);
        do_write(5'd11, 8'sd55);
        do_write(5'd12, 8'sd66);

        do_swap;
        // Now reading from B (which we just wrote Y into)
        do_read(5'd10); check_read(8'sd44, "T2 Y @10 -> 44");
        do_read(5'd11); check_read(8'sd55, "T2 Y @11 -> 55");
        do_read(5'd12); check_read(8'sd66, "T2 Y @12 -> 66");

        do_swap;
        // Now reading from A (which holds X from T1)
        do_read(5'd0); check_read(8'sd11, "T2 X @0 still 11");
        do_read(5'd1); check_read(8'sd22, "T2 X @1 still 22");
        do_read(5'd2); check_read(8'sd33, "T2 X @2 still 33");

        // ==================================================
        // T3: No contamination of read side during write
        //   While writing new data to addr=7 of write-side,
        //   read-side addr=7 should NOT see the new data.
        //
        // After T2 we are: A=read(X), B=write(empty @7)
        // Read from A addr=0 should always give 11, no matter
        // what we do on write side.
        // ==================================================
        $display("\n[T3] Isolation: writes don't pollute read side");

        @(negedge clk);
        write_addr = 5'd0;
        write_data = 8'sd99;       // try to contaminate A addr=0
        write_en   = 1;
        read_addr  = 5'd0;
        @(posedge clk);
        #1;
        @(negedge clk);
        write_en = 0;
        @(posedge clk);
        #1;
        // Read-side is A (which_is_write==1 means A is READ side? Let me check)
        // After two swaps in T2: role flipped 0->1->0. So role=0, A=write, B=read... wait
        // Let me just check: after T1 swap role=1, after T2's 2 swaps role=1.
        // Wait, T1 did 1 swap (role 0->1), T2 did 2 swaps (role 1->0->1). So role=1 means B=write, A=read.
        // So writing to addr=0 goes to B, and reading addr=0 from A gives original 11.
        check_read(8'sd11, "T3 write didn't pollute read side");

        // ==================================================
        // T4: Rapid repeated swaps (6 layer transitions)
        // Before we start, let's re-establish known state.
        // ==================================================
        $display("\n[T4] Six consecutive swaps, data preserved");

        // Clear knowledge: start by writing 0xA to addr=20 on write side.
        do_write(5'd20, 8'sd77);
        do_swap;
        // Now addr=20 on current read side holds 77
        // Write 0xB to addr=21 on new write side
        do_write(5'd21, 8'sd88);
        // Do a few swaps and read back - pattern should alternate
        do_swap;        // read-side is now where 21->88 lives
        do_read(5'd21); check_read(8'sd88, "T4 after 1 extra swap");

        do_swap;        // flip back
        do_read(5'd20); check_read(8'sd77, "T4 after 2 extra swaps");

        do_swap;
        do_read(5'd21); check_read(8'sd88, "T4 after 3 extra swaps");

        do_swap;
        do_read(5'd20); check_read(8'sd77, "T4 after 4 extra swaps");

        // ==================================================
        // T5: Realistic LeNet-5 layer transition scenario
        //   conv_engine writes 6 output values (e.g. conv1 first
        //   row of first filter), then swap, then pool_engine
        //   reads them as input.
        // ==================================================
        $display("\n[T5] Realistic conv -> swap -> pool data flow");

        // conv writes 6 feature values to addresses 0..5
        do_write(5'd0, 8'sd12);
        do_write(5'd1, 8'sd34);
        do_write(5'd2, 8'sd56);
        do_write(5'd3, 8'sd78);
        do_write(5'd4, 8'sd90);
        do_write(5'd5, 8'sd11);

        // Layer transition
        do_swap;

        // Pool reads them back
        do_read(5'd0); check_read(8'sd12, "T5 pool reads conv[0]");
        do_read(5'd1); check_read(8'sd34, "T5 pool reads conv[1]");
        do_read(5'd2); check_read(8'sd56, "T5 pool reads conv[2]");
        do_read(5'd3); check_read(8'sd78, "T5 pool reads conv[3]");
        do_read(5'd4); check_read(8'sd90, "T5 pool reads conv[4]");
        do_read(5'd5); check_read(8'sd11, "T5 pool reads conv[5]");

        // ==================================================
        // Summary
        // ==================================================
        $display("\n============================================================");
        $display("  Summary : %0d passed, %0d failed", pass_count, fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("  ALL TESTS PASSED");
        else                 $display("  SOME TESTS FAILED");

        $finish;
    end

endmodule
