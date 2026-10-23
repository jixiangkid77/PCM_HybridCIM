// e8_rom_r48_stub.v   (P2R-E8.5)
// Black box of one r48 address-map ROM macro (OpenRAM e16d9eb,
// 624 x 16 bit, 48 rows x 13 words) for synthesis; replaces
// rtl/e8/e8_rom_r48.v (simulation model) only in synthesis.
// Place : rtl/e8/   Status : NEW FILE.
(* blackbox *)
module e8_rom_r48 #(
    parameter integer LANE     = 0,
    parameter integer SIDE     = 0,
    parameter integer MACRO    = 0,
    parameter         DATA_DIR = ""
)(
    input  wire        clk0,
    input  wire        cs0,
    input  wire [9:0]  addr0,
    output wire [15:0] dout0
);
endmodule
