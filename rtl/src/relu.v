// ============================================================
// relu.v
// ------------------------------------------------------------
// Rectified Linear Unit: output = max(input, 0)
//
// Signed arithmetic. Pure combinational (zero cycle latency).
// Input and output have the same bit width.
//
// Parameter:
//   WIDTH - bit width of input and output (default 32, suitable
//           for the output of mac_unit's accumulator)
//
// Implementation note:
//   For a signed two's-complement number, the MSB is the sign
//   bit: 1 = negative, 0 = non-negative. So:
//     ReLU(x) = x[MSB] ? 0 : x
//   This synthesizes to a single mux.
//
// Typical usage (LeNet-5 pipeline):
//   mac_unit (32b acc) -> quantize_saturate (to 8b) -> relu (8b)
//   -> feature_buffer write
// We chose to keep relu itself agnostic about quantization so
// that the same module works at any width (32b after MAC, or
// 8b after quantization, or any future ResNet-18 bit width).
// ============================================================

`timescale 1ns / 1ps

module relu #(
    parameter integer WIDTH = 32
)(
    input  wire signed [WIDTH-1:0] din,
    output wire signed [WIDTH-1:0] dout
);

    // If sign bit is 1 (negative), output 0; otherwise pass through.
    assign dout = din[WIDTH-1] ? {WIDTH{1'b0}} : din;

endmodule
