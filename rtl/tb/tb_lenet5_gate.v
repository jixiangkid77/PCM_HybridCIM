//============================================================
// tb_lenet5_gate.v
// Gate-level power-characterisation testbench for lenet5_top.
// Drives the SAME stimulus as the functional TB (image load,
// 10-entry config write + commit, start) but:
//   - instantiates the PARAM-LESS synthesized lenet5_top
//   - contains NO internal hierarchical probes (the gate netlist
//     has no RTL signal names); only top-level ports are used
//   - dumps a VCD window for OpenSTA power analysis
//
// Run from paper2/build/  so that "../data" resolves to
// paper2/data, matching the DATA_DIR baked into the netlist.
//
// RUNTIME controls (so one compile serves every run) via plusargs:
//   +max_cycles=<n>  stop after n post-start cycles (default 2000000)
//   +dump_from=<ns>  sim time (ns) to start VCD dump (default 0)
//   +dump_to=<ns>    sim time (ns) to stop  VCD dump (default 1e9)
// VCD is always written to "gate.vcd"; rename after a run to keep it.
//============================================================
`timescale 1ns/1ps

module tb_lenet5_gate;

    localparam integer DATA_W  = 8;
    localparam integer FADDR_W = 13;

    // Model A, paths relative to cwd = paper2/build  ->  paper2/data
    localparam IMG_FILE = "../data/rtl_inputs_A/images/img_001.hex";
    localparam CFG_FILE = "../data/rtl_inputs_A_v3/layer_config.hex";
    localparam [3:0] EXPECT_CLASS = 4'd7;

    // ---- runtime-tunable controls (read once at t=0) ------------
    integer max_cycles;
    integer dump_from;
    integer dump_to;
    initial begin
        if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 2000000;
        if (!$value$plusargs("dump_from=%d",  dump_from))  dump_from  = 0;
        if (!$value$plusargs("dump_to=%d",    dump_to))    dump_to    = 1000000000;
    end

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg                       start;
    reg                       image_we;
    reg  [FADDR_W-1:0]        image_addr;
    reg  signed [DATA_W-1:0]  image_data;
    reg                       cfg_wr_en;
    reg  [5:0]                cfg_wr_addr;
    reg  [31:0]               cfg_wr_data;
    wire                      done;
    wire [3:0]                predicted_class;

    // Param-less synthesized top; DATA_DIR is baked into the
    // netlist's macro instantiations, so nothing is passed here.
    lenet5_top DUT (
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

    reg signed [DATA_W-1:0] image_mirror [0:783];
    reg [31:0]              cfg_words    [0:9];

    // ---- VCD dump window control --------------------------------
    reg [1:0] dump_state = 0;
    initial begin
        $dumpfile("gate.vcd");
        $dumpvars(0, DUT);
        $dumpoff;
    end
    always @(posedge clk) begin
        case (dump_state)
            2'd0: if ($time >= dump_from) begin $dumpon;  dump_state <= 2'd1; end
            2'd1: if ($time >= dump_to)   begin $dumpoff; dump_state <= 2'd2; end
        endcase
    end

    // ---- done capture (top-level ports only) --------------------
    reg        done_seen = 0;
    reg [3:0]  captured_pred = 0;
    reg [31:0] cyc_cnt = 0;
    reg        started = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            done_seen <= 0; captured_pred <= 0; cyc_cnt <= 0;
        end else begin
            if (started) cyc_cnt <= cyc_cnt + 1;
            if (done && !done_seen) begin
                done_seen     <= 1;
                captured_pred <= predicted_class;
            end
        end
    end

    task do_cfg_write(input [5:0] a, input [31:0] d);
        begin
            @(negedge clk);
            cfg_wr_en = 1'b1; cfg_wr_addr = a; cfg_wr_data = d;
            @(negedge clk);
            cfg_wr_en = 1'b0;
        end
    endtask

    integer i;

    initial begin
        // small settle so the plusarg-reading initial has run
        #1;
        $display("==== gate-level power TB (Model A, img_001) ====");
        $display("  max_cycles=%0d  dump_from=%0d  dump_to=%0d  VCD=gate.vcd",
                 max_cycles, dump_from, dump_to);
        start=0; image_we=0; image_addr=0; image_data=0;
        cfg_wr_en=0; cfg_wr_addr=0; cfg_wr_data=0; rst_n=0;

        @(negedge clk); @(negedge clk); @(negedge clk);

        $readmemh(IMG_FILE, image_mirror);
        $readmemh(CFG_FILE, cfg_words);

        @(negedge clk); rst_n = 1;
        @(negedge clk); @(negedge clk);

        // config write + commit (same sequence as the functional TB)
        for (i = 0; i < 10; i = i + 1) do_cfg_write(i[5:0], cfg_words[i]);
        do_cfg_write(6'h21, 32'h0000_0000);   // enable_drift = 0
        do_cfg_write(6'h20, 32'h0000_0002);   // commit (cfg_valid)

        // image load: 784 pixels via image_we
        for (i = 0; i < 784; i = i + 1) begin
            @(negedge clk);
            image_we = 1'b1; image_addr = i[FADDR_W-1:0]; image_data = image_mirror[i];
        end
        @(negedge clk); image_we = 1'b0;

        // start inference
        @(negedge clk); start = 1'b1; started = 1'b1;
        @(negedge clk); start = 1'b0;

        // run until done or cycle cap
        while (!done_seen && cyc_cnt < max_cycles) @(negedge clk);

        if (done_seen) begin
            $display("  DONE at post-start cycle %0d, predicted_class=%0d (expect %0d)",
                     cyc_cnt, captured_pred, EXPECT_CLASS);
            if (captured_pred === EXPECT_CLASS)
                $display("  [PASS] gate netlist functional: predicted_class matches");
            else
                $display("  [FAIL] predicted_class mismatch");
        end else begin
            $display("  [STOP] reached max_cycles=%0d without done (smoke run)", max_cycles);
        end
        $finish;
    end

endmodule
