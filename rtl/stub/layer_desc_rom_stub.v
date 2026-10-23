// layer_desc_rom_stub.v
// Step 12b-1 smoke-flow blackbox for layer_desc_rom.
// Internal size is trivial (5×8-bit rshift_table + combinational
// layer descriptor logic). Stubbed only to avoid $display elaboration
// in Yosys; Step 12b-2 will keep this synthesized via a $display-free
// build flow.

(* blackbox *)
module layer_desc_rom #(
    parameter integer NUM_STEPS = 8,
    parameter         DATA_DIR  = ""
)(
    input  wire [3:0]  step_id,
    output wire [1:0]  layer_kind,
    output wire [7:0]  in_h,
    output wire [7:0]  in_w,
    output wire [7:0]  in_ch,
    output wire [7:0]  out_h,
    output wire [7:0]  out_w,
    output wire [7:0]  out_ch,
    output wire [3:0]  kernel,
    output wire [3:0]  padding,
    output wire [15:0] in_dim,
    output wire [15:0] out_dim,
    output wire [3:0]  rshift,
    output wire        use_relu,
    output wire [2:0]  weight_layer,
    output wire        is_last_step
);
endmodule
