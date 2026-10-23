//============================================================
// tb_elab_lenet5_v3.v
// Step 6 elaboration-only testbench.
//
// Purpose: verify v3 lenet5_top + top_fsm + conv/fc engines +
// pcm_imc_unit chain compiles and elaborates cleanly.
//
// Does NOT run inference. Step 7 owns functional testing.
//
// Run:
//   iverilog -g2012 -o build/tb_elab_lenet5_v3 \
//     rtl/src/layer_config_regfile.v \
//     rtl/src/sram_addr_decoder.v \
//     rtl/src/sram_pool_25lane.v \
//     rtl/src/sram_mac.v \
//     rtl/src/pcm_addr_decoder.v \
//     rtl/src/pcm_crossbar.v \
//     rtl/src/combiner.v \
//     rtl/src/pcm_imc_unit.v \
//     rtl/src/conv_engine.v \
//     rtl/src/fc_engine.v \
//     <other engines / buffers / wrappers> \
//     rtl/src/top_fsm.v \
//     rtl/src/lenet5_top.v \
//     rtl/tb/tb_elab_lenet5_v3.v
//   vvp build/tb_elab_lenet5_v3
//============================================================

`timescale 1ns/1ps

module tb_elab_lenet5_v3;

    // Tied inputs
    reg clk = 0;
    reg rst_n = 0;
    reg start = 0;
    reg image_we = 0;
    reg [12:0] image_addr = 0;
    reg signed [7:0] image_data = 0;
    reg cfg_wr_en = 0;
    reg [5:0] cfg_wr_addr = 0;
    reg [31:0] cfg_wr_data = 0;

    wire done;
    wire [3:0] predicted_class;

    always #5 clk = ~clk;

    lenet5_top #(
        .DATA_DIR("data/rtl_inputs_A_v3"),
        .COMMON_DIR("data/rtl_inputs_common")
    ) DUT (
        .clk(clk), .rst_n(rst_n),
        .start(start),
        .done(done),
        .predicted_class(predicted_class),
        .image_we(image_we),
        .image_addr(image_addr),
        .image_data(image_data),
        .cfg_wr_en(cfg_wr_en),
        .cfg_wr_addr(cfg_wr_addr),
        .cfg_wr_data(cfg_wr_data)
    );

    initial begin
        $display("============================================================");
        $display("tb_elab_lenet5_v3: elaboration-only smoke test");
        $display("============================================================");

        // Brief reset cycle
        rst_n = 0;
        @(negedge clk); @(negedge clk); @(negedge clk);
        rst_n = 1;
        @(negedge clk); @(negedge clk);

        // Verify done is sensible at idle
        if (done === 1'bx) begin
            $display("[FAIL] done is X after reset deassert");
        end else begin
            $display("[PASS] done = %0b at idle (well-defined)", done);
        end

        // No inference run; this is just an elaboration test.
        $display("[PASS] elaboration OK (no inference attempted)");
        $display("============================================================");
        $finish;
    end

    initial begin
        #100000;
        $display("[FAIL] timeout");
        $finish;
    end

endmodule
