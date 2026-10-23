//============================================================
// amu_lanes.v   (P2R-E8.5, address-map unit)
//============================================================
// Per-lane check that lane k looks up the same entry as lane 0.
// The engines issue, in one MAC operation,
//   conv:  a_k = (oc*IC + ic)*25 + k            (all 25 lanes)
//   fc  :  a_k = oc*IN_DIM + sb*25 + k  if sb*25 + k < IN_DIM,
//          a_k = 0 (dummy, V = 0) otherwise
// so lane k uses lane 0's entry exactly when a_k == a0 + k and,
// in an FC layer, flat0 + k < IN_DIM. For these addresses the
// original per-lane decoder (LANE_ID = k) returns lane 0's entry;
// for a_k == 0 (k >= 1) it returns a miss. Any other address is
// reported on mismatch[k] and treated as a miss (KID 2026-10-15:
// one shared entry computation, each lane compares its own
// address, an error is raised when they disagree).
//
// Place  : rtl/e8/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

module amu_lanes #(
    parameter integer K          = 25,
    parameter integer ADDR_WIDTH = 16
)(
    input  wire [K*ADDR_WIDTH-1:0] addr_bus,
    input  wire                    v0,
    input  wire [8:0]              flat0,
    input  wire [8:0]              in_dim,
    input  wire                    is_fc,
    output wire [K-1:0]            valid,
    output wire [K-1:0]            mismatch
);
    wire [15:0] a0 = addr_bus[15:0];
    assign valid[0]    = v0;
    assign mismatch[0] = 1'b0;

    genvar k;
    generate
        for (k = 1; k < K; k = k + 1) begin : lane
            localparam [15:0] KK = k;
            wire [15:0] ak    = addr_bus[k*ADDR_WIDTH +: 16];
            wire        same  = (ak == a0 + KK);
            wire [9:0]  fk    = {1'b0, flat0} + KK[9:0];
            wire        in_vec = !is_fc || (fk < {1'b0, in_dim});
            assign valid[k]    = v0 && same && in_vec;
            assign mismatch[k] = !same && (ak != 16'd0);
        end
    endgenerate

endmodule
