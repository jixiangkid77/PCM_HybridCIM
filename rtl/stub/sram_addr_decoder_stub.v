// sram_addr_decoder_stub.v
// Step 12b-1 black-box stub for the SRAM address decoder.
// This file replaces rtl/src/sram_addr_decoder.v ONLY in synthesis.
// Do NOT use this file for RTL functional simulation.
//
// Step 12b-1 (smoke): the wrapper logic (layer mux, range check,
// base+slot adder) is also stubbed away here, which underestimates
// digital periphery area. Step 12b-2 will refactor to extract
// only the address-to-slot ROM into a macro and keep the wrapper
// logic synthesized.

(* blackbox *)
module sram_addr_decoder #(
    parameter integer ADDR_WIDTH = 16,
    parameter integer SRAM_TOTAL = 3074,
    parameter integer LANE_ID    = 0,
    parameter         DATA_DIR   = ""
)(
    input  wire [2:0]              layer_id,
    input  wire [ADDR_WIDTH-1:0]   orig_addr,
    input  wire [15:0]             sram_base,
    input  wire [15:0]             sram_size,

    output wire                    sram_hit,
    output wire [15:0]             sram_pool_addr,
    output wire                    sram_oor_error
);
endmodule
