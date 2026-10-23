//============================================================
// amu_entry.v   (P2R-E8.5, address-map unit)
//============================================================
// Shared entry arithmetic of the address map. In every MAC
// operation all 25 lanes look up the same table entry (E8.6a-2:
// 0 of 16,684 operations differ), so the division and modulo of
// the original per-lane decoders (rtl/src/sram_addr_decoder.v,
// pcm_addr_decoder.v; 50 copies) is done once, on lane 0.
//
// For LANE_ID = 0 the outputs equal the original decoder's:
//   v0  = in_range && lane_ok && compact < depth   (raw lookup
//         validity; the ROM word itself decides hit or miss)
//   e0  = table entry = layer offset + compact
// Layer offsets: conv1 0, conv2 6, fc1 102, fc2 2022, fc3 2442
// (depths 6, 96, 1920, 420, 40; 2,482 entries + 14 padding words).
//
// Divisions by constants are written as multiply and shift; the
// constants are exact over the range each layer accepts (checked
// exhaustively, P2R-E8.5 sandbox):
//   x / 25  (x <= 2399)  = (x * 1311)  >> 15
//   x / 400 (x <= 47999) = (x * 83887) >> 25
//   x / 120 (x <= 10079) = (x * 8739)  >> 20
//   x / 84  (x <= 839)   = (x * 781)   >> 16
//   x / 25  (x <= 399)   = (x * 41)    >> 10
// Out of range, the original decoder returns a miss whatever the
// quotient is, so the quotient is not needed there.
//
// Place  : rtl/e8/ (new folder; no existing file is changed)
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

module amu_entry (
    input  wire [2:0]  layer_id,
    input  wire [15:0] a0,          // lane 0 original weight address
    output reg         v0,          // lane 0 looks up an entry
    output reg  [11:0] e0,          // its table entry
    output reg  [8:0]  flat0,       // FC: lane 0 index in the input vector (sb*25)
    output reg  [8:0]  in_dim,      // FC: input length (0 for conv)
    output reg         is_fc
);

    // ---- conv: compact = a0 / 25, lane 0 needs a0 % 25 == 0 ----------
    wire [11:0] ca   = a0[11:0];
    wire [22:0] cprd = ca * 23'd1311;
    wire [6:0]  cq   = cprd[21:15];                 // a0/25 for a0 <= 2399
    wire [11:0] cq25 = {5'd0, cq} * 12'd25;
    wire        c_ok = (ca == cq25);

    // ---- fc1: oc = a0/400, flat = a0 - 400*oc ------------------------
    wire [32:0] f1p  = a0 * 33'd83887;
    wire [6:0]  f1oc = f1p[31:25];                  // <= 119 in range
    wire [15:0] f1fl = a0 - {9'd0, f1oc} * 16'd400;
    // ---- fc2: oc = a0/120 ---------------------------------------------
    wire [13:0] a14  = a0[13:0];
    wire [27:0] f2p  = a14 * 28'd8739;
    wire [6:0]  f2oc = f2p[26:20];                  // <= 83 in range
    wire [15:0] f2fl = a0 - {9'd0, f2oc} * 16'd120;
    // ---- fc3: oc = a0/84 ----------------------------------------------
    wire [9:0]  a10  = a0[9:0];
    wire [19:0] f3p  = a10 * 20'd781;
    wire [3:0]  f3oc = f3p[19:16];                  // <= 9 in range
    wire [15:0] f3fl = a0 - {12'd0, f3oc} * 16'd84;

    reg  [8:0]  fl;          // flat index of the selected FC layer
    reg  [6:0]  oc;
    wire [14:0] sbp  = fl * 15'd41;
    wire [4:0]  sb   = sbp[14:10];                  // fl / 25 for fl <= 399
    wire [8:0]  sb25 = {4'd0, sb} * 9'd25;
    wire        f_ok = (fl == sb25);

    always @(*) begin
        v0     = 1'b0;
        e0     = 12'd0;
        flat0  = 9'd0;
        in_dim = 9'd0;
        is_fc  = 1'b0;
        fl     = 9'd0;
        oc     = 7'd0;
        case (layer_id)
            3'd0: begin   // conv1: a0 < 150, 6 entries
                v0 = (a0 < 16'd150) && c_ok;
                e0 = {5'd0, cq};
            end
            3'd1: begin   // conv2: a0 < 2400, 96 entries
                v0 = (a0 < 16'd2400) && c_ok;
                e0 = 12'd6 + {5'd0, cq};
            end
            3'd2: begin   // fc1: IN_DIM 400, 16 sub-banks, 1920 entries
                is_fc = 1'b1; in_dim = 9'd400;
                oc = f1oc; fl = f1fl[8:0];
                v0 = (a0 < 16'd48000) && f_ok;
                e0 = 12'd102 + {1'b0, oc, 4'd0} + {7'd0, sb};
                flat0 = fl;
            end
            3'd3: begin   // fc2: IN_DIM 120, 5 sub-banks, 420 entries
                is_fc = 1'b1; in_dim = 9'd120;
                oc = f2oc; fl = f2fl[8:0];
                v0 = (a0 < 16'd10080) && f_ok;
                e0 = 12'd2022 + {5'd0, oc} * 12'd5 + {7'd0, sb};
                flat0 = fl;
            end
            3'd4: begin   // fc3: IN_DIM 84, 4 sub-banks, 40 entries
                is_fc = 1'b1; in_dim = 9'd84;
                oc = {3'd0, f3oc}; fl = f3fl[8:0];
                v0 = (a0 < 16'd840) && f_ok;
                e0 = 12'd2442 + {3'd0, oc, 2'd0} + {7'd0, sb};
                flat0 = fl;
            end
            default: ;
        endcase
    end

endmodule
