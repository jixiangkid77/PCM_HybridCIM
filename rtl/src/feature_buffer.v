// ============================================================
// feature_buffer.v
// ------------------------------------------------------------
// Ping-pong feature map buffer for LeNet-5 inference.
//
// Two on-chip SRAM arrays (A and B) take turns acting as the
// "read" and "write" partner. While the compute engine writes
// layer N's output to one buffer, it simultaneously reads
// layer N-1's output from the other -- no read/write contention.
//
// At the end of each layer the top FSM asserts `swap` for one
// cycle, flipping the roles.
//
// Interface contract:
//   write side : addr, data, en      (clock-synchronous write)
//   read side  : addr --> data       (1-cycle latency, synchronous read)
//   swap       : 1-cycle pulse       (flips A/B roles)
//
// Buffer sizing (LeNet-5):
//   Largest intermediate feature map is conv1 output: 6*28*28 = 4704
//   elements, each 8 bits. DEPTH defaults to 4704 accordingly.
//   DATA_WIDTH=8 matches the activation precision throughout.
//
// External behaviour (example):
//   cycle N   : write_addr=5, write_data=0x2A, write_en=1  (queued)
//   cycle N+1 : <write completes into the write-side buffer>
//   cycle M   : read_addr=5                                 (queued)
//   cycle M+1 : read_data = value stored at addr 5 of the
//               read-side buffer
//
// Implementation:
//   - role_sel flip-flop: 0 = A is write-side, B is read-side
//                         1 = B is write-side, A is read-side
//   - Each SRAM is a simple clocked memory array.
//   - A side-channel `which_is_write` exposes role_sel for
//     debugging/testbench verification.
// ============================================================

`timescale 1ns / 1ps

module feature_buffer #(
    parameter integer DATA_WIDTH = 8,
    parameter integer DEPTH      = 4704,
    parameter integer ADDR_WIDTH = 13    // ceil(log2(4704)) = 13
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Write port
    input  wire [ADDR_WIDTH-1:0]        write_addr,
    input  wire signed [DATA_WIDTH-1:0] write_data,
    input  wire                         write_en,

    // Read port  (1-cycle latency: data appears in cycle after addr)
    input  wire [ADDR_WIDTH-1:0]        read_addr,
    output reg  signed [DATA_WIDTH-1:0] read_data,

    // Role control
    input  wire                         swap,
    output wire                         which_is_write    // 0=A, 1=B (observability)
);

    // ---------------------------------------------------------
    // Role register
    //   0 -> A is the write side, B is the read side
    //   1 -> B is the write side, A is the read side
    // Swap pulse flips this.
    // ---------------------------------------------------------
    reg role_sel;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) role_sel <= 1'b0;
        else if (swap) role_sel <= ~role_sel;
    end

    assign which_is_write = role_sel;

    // ---------------------------------------------------------
    // Two SRAM-like memory arrays
    // ---------------------------------------------------------
    reg signed [DATA_WIDTH-1:0] mem_A [0:DEPTH-1];
    reg signed [DATA_WIDTH-1:0] mem_B [0:DEPTH-1];

    // ---------------------------------------------------------
    // Write path
    //   role_sel=0 : write goes to A
    //   role_sel=1 : write goes to B
    // Only the selected buffer updates; the other holds.
    // ---------------------------------------------------------
    always @(posedge clk) begin
        if (write_en) begin
            if (role_sel == 1'b0)
                mem_A[write_addr] <= write_data;
            else
                mem_B[write_addr] <= write_data;
        end
    end

    // ---------------------------------------------------------
    // Read path (synchronous, 1-cycle latency)
    //   role_sel=0 : read from B
    //   role_sel=1 : read from A
    // ---------------------------------------------------------
    always @(posedge clk) begin
        if (role_sel == 1'b0)
            read_data <= mem_B[read_addr];
        else
            read_data <= mem_A[read_addr];
    end

    // ---------------------------------------------------------
    // Initialization: zero both buffers (avoids X propagation
    // in simulation; synthesis tools typically ignore initial
    // on SRAM arrays)
    // ---------------------------------------------------------
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) begin
            mem_A[i] = {DATA_WIDTH{1'b0}};
            mem_B[i] = {DATA_WIDTH{1'b0}};
        end
        read_data = {DATA_WIDTH{1'b0}};
    end

endmodule
