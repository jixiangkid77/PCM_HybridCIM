// feature_buffer_stub.v
// Step 12b-1 black-box stub for the activation feature buffer
// (dual-bank ping-pong SRAM with role_sel control).

(* blackbox *)
module feature_buffer #(
    parameter integer DATA_WIDTH = 8,
    parameter integer DEPTH      = 4704,
    parameter integer ADDR_WIDTH = 13
)(
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire [ADDR_WIDTH-1:0]        write_addr,
    input  wire signed [DATA_WIDTH-1:0] write_data,
    input  wire                         write_en,

    input  wire [ADDR_WIDTH-1:0]        read_addr,
    output wire signed [DATA_WIDTH-1:0] read_data,

    input  wire                         swap,
    output wire                         which_is_write
);
endmodule
