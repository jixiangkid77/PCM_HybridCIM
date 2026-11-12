//============================================================
// e9_rom_stub.v   (P2R-E9.1, synthesis only)
//============================================================
// Black box of the E9 address-map ROM macro (rtl/e9/e9_rom.v):
// ports only, so that synthesis of amu9_top keeps the 7 macros as
// instances and maps only the logic (as rtl/e8/e8_rom_r48_stub.v).
//
// Place  : rtl/e9/
// Status : NEW FILE.
//============================================================
(* blackbox *)
module e9_rom #(
    parameter integer MACRO  = 0,
    parameter integer NWORDS = 2688
)(
    input  wire        clk0,
    input  wire        cs0,
    input  wire [8:0]  addr0,
    output wire [39:0] dout0
);
endmodule
