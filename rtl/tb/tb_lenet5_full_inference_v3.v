//============================================================
// tb_lenet5_full_inference_v3.v
// Step 9: FULL LeNet-5 inference + per-layer assertions
//         + per-layer cycle metrics for Paper 2 V-F table.
//
// Method X approach:
//   For every layer, capture the entire output stream into a
//   per-layer array indexed BY ADDRESS (not by count), then
//   compare against the corresponding Python golden file.
//
// Capture gate table:
//   step_id | layer  | output entries | gate signal       | array width
//   ---------------------------------------------------------------------
//     0    | conv1  |  4704          | fbuf_write_en_fsm | 8-bit unsigned
//     1    | pool1  |  1176          | fbuf_write_en_fsm | 8-bit unsigned
//     2    | conv2  |  1600          | fbuf_write_en_fsm | 8-bit unsigned
//     3    | pool2  |   400          | fbuf_write_en_fsm | 8-bit unsigned
//     4    | fc1    |   120          | fbuf_write_en_fsm | 8-bit unsigned
//     5    | fc2    |    84          | fbuf_write_en_fsm | 8-bit unsigned
//     6    | fc3    |    10          | logit_write_en    | 16-bit SIGNED
//   argmax wrapper produces predicted_class; done pulses on completion.
//
// Per-layer "writeback window" = (last writeback cycle) - (first
// writeback cycle) + 1.  This is NOT pure compute latency: it
// includes FSM transitions, input-vector preload (for fc layers),
// setup, and writeback timing.
//
// Pass conditions (all must hold):
//   T1.x  boot protocol (3 sub-checks)
//   T2.1  784-pixel image load
//   T3    inference reaches done within timeout
//   T3.c  every layer's capture count == expected N
//   T3.0..T3.6  every layer's full output matches golden
//   T4    predicted_class == signed strict-argmax of golden_fc3
//         (this verifies the RTL argmax10 module on top of fc3
//          equivalence; golden_pred_<M>_img1.txt is generated
//          for external reporting only, not consumed by this TB)
//
// Per-layer nonzero counts are reported alongside each compare
// for auditability; they are not separately asserted because the
// full-array exact compare already subsumes any non-zero check.
//
// Compile / run (compile-time model switch):
//   Model A:  iverilog -DLOAD_REAL_DATA ...
//   Model B:  iverilog -DLOAD_REAL_DATA -DMODEL_B ...
//============================================================

`timescale 1ns/1ps

`ifndef MODEL_B
  `define DATA_DIR_STR  "data/rtl_inputs_A_v3"
  `define IMG_FILE_STR  "data/rtl_inputs_A/images/img_001.hex"
  `define GOLDEN_DIR    "data/golden"
  `define MODEL_TAG     "A"
  `define MODEL_NAME    "Model A"
`else
  `define DATA_DIR_STR  "data/rtl_inputs_B_v3"
  `define IMG_FILE_STR  "data/rtl_inputs_B/images/img_001.hex"
  `define GOLDEN_DIR    "data/golden"
  `define MODEL_TAG     "B"
  `define MODEL_NAME    "Model B"
`endif
`define COMMON_DIR_STR  "data/rtl_inputs_common"

module tb_lenet5_full_inference_v3;

    localparam integer DATA_W  = 8;
    localparam integer LOGIT_W = 16;
    localparam integer FADDR_W = 13;
    localparam integer OADDR_W = 13;

    // Output sizes per layer
    localparam integer CONV1_N = 6 * 28 * 28;   // 4704
    localparam integer POOL1_N = 6 * 14 * 14;   // 1176
    localparam integer CONV2_N = 16 * 10 * 10;  // 1600
    localparam integer POOL2_N = 16 * 5 * 5;    // 400
    localparam integer FC1_N   = 120;
    localparam integer FC2_N   = 84;
    localparam integer FC3_N   = 10;

    // ---- Clock + reset -------------------------------------------
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    // ---- DUT I/O -------------------------------------------------
    reg                       start;
    reg                       image_we;
    reg  [FADDR_W-1:0]        image_addr;
    reg  signed [DATA_W-1:0]  image_data;
    reg                       cfg_wr_en;
    reg  [5:0]                cfg_wr_addr;
    reg  [31:0]               cfg_wr_data;
    wire                      done;
    wire [3:0]                predicted_class;

    lenet5_top #(
        .DATA_DIR(`DATA_DIR_STR),
        .COMMON_DIR(`COMMON_DIR_STR)
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

    // ---- Test mirrors (loaded from disk) ------------------------
    reg signed [DATA_W-1:0]  image_mirror   [0:783];
    reg [31:0]               cfg_words      [0:9];

    reg [7:0]  conv1_mirror [0:CONV1_N-1];
    reg [7:0]  pool1_mirror [0:POOL1_N-1];
    reg [7:0]  conv2_mirror [0:CONV2_N-1];
    reg [7:0]  pool2_mirror [0:POOL2_N-1];
    reg [7:0]  fc1_mirror   [0:FC1_N-1];
    reg [7:0]  fc2_mirror   [0:FC2_N-1];
    reg signed [LOGIT_W-1:0] fc3_mirror [0:FC3_N-1];

    // ---- Capture arrays (indexed by ADDR for robustness) --------
    reg [7:0]  conv1_cap [0:CONV1_N-1];
    reg [7:0]  pool1_cap [0:POOL1_N-1];
    reg [7:0]  conv2_cap [0:CONV2_N-1];
    reg [7:0]  pool2_cap [0:POOL2_N-1];
    reg [7:0]  fc1_cap   [0:FC1_N-1];
    reg [7:0]  fc2_cap   [0:FC2_N-1];
    reg signed [LOGIT_W-1:0] fc3_cap [0:FC3_N-1];

    // ---- Per-layer counters + cycle markers ---------------------
    integer    conv1_count = 0,  pool1_count = 0,  conv2_count = 0;
    integer    pool2_count = 0,  fc1_count   = 0,  fc2_count   = 0;
    integer    fc3_count   = 0;

    reg [31:0] conv1_first = 32'hFFFF_FFFF, conv1_last = 0;
    reg [31:0] pool1_first = 32'hFFFF_FFFF, pool1_last = 0;
    reg [31:0] conv2_first = 32'hFFFF_FFFF, conv2_last = 0;
    reg [31:0] pool2_first = 32'hFFFF_FFFF, pool2_last = 0;
    reg [31:0] fc1_first   = 32'hFFFF_FFFF, fc1_last   = 0;
    reg [31:0] fc2_first   = 32'hFFFF_FFFF, fc2_last   = 0;
    reg [31:0] fc3_first   = 32'hFFFF_FFFF, fc3_last   = 0;

    // ---- Cycle counter (from `start` pulse onwards) -------------
    reg [31:0] cycle_after_start = 0;
    reg        started_flag      = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_after_start <= 0;
            started_flag      <= 1'b0;
        end else begin
            if (start) started_flag <= 1'b1;
            if (started_flag) cycle_after_start <= cycle_after_start + 1;
        end
    end

    // ---- Done capture -------------------------------------------
    reg        done_seen        = 1'b0;
    reg [3:0]  captured_pred    = 4'd0;
    reg [31:0] done_cycle       = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            done_seen     <= 1'b0;
            captured_pred <= 4'd0;
            done_cycle    <= 0;
        end else if (DUT.done && !done_seen) begin
            done_seen     <= 1'b1;
            captured_pred <= DUT.predicted_class;
            done_cycle    <= cycle_after_start;
        end
    end

    // ---- SRAM read counters (passive monitors, energy characterisation) ----
    // Two counts, because they measure different things:
    //
    // (1) sram_reads_mac : the ENERGY-relevant count. The conv/fc engine
    //     issues one K-wide MAC operation per imc_start pulse, then HOLDS the
    //     25 weight addresses stable while the IMC computes (~8-cycle PCM
    //     wait). A real SRAM reads each weight ONCE per operation and holds
    //     the output; it does not re-read every cycle. So we count the
    //     protected (sram_hit) lanes ONCE, on the imc_start cycle, where the
    //     address bus is fully assembled and stable. Summed over all MAC
    //     operations this is the number of protected-weight reads, which
    //     times the OpenRAM per-access energy is the SRAM dynamic read energy.
    //
    // (2) sram_lane_cycles : raw "lane-cycles with a registered in-range hit".
    //     This counts the held cycles too, so it over-states the read count by
    //     roughly the number of cycles each address sits on the bus per MAC
    //     operation (~40x here). Kept ONLY to show the contrast; it is NOT the
    //     energy count.
    //
    // Both blocks only OBSERVE existing signals; neither drives the DUT.
    // DUT.u_imc.start and DUT.u_imc.sram_hit_dbg are ports of pcm_imc_unit
    // (start = MAC-issue pulse; sram_hit_dbg = per-lane protected-weight hit).
    integer sram_reads_mac   = 0;
    integer sram_lane_cycles = 0;
    integer kk;
    integer hits_this_op;
    integer cyc_lanes;
    always @(negedge clk) begin
        if (!rst_n) begin
            sram_reads_mac   <= 0;
            sram_lane_cycles <= 0;
        end else if (started_flag) begin
            // (1) energy-relevant: protected lanes counted once per MAC issue
            if (DUT.u_imc.start) begin
                hits_this_op = 0;
                for (kk = 0; kk < 25; kk = kk + 1)
                    if (DUT.u_imc.sram_hit_dbg[kk]) hits_this_op = hits_this_op + 1;
                sram_reads_mac <= sram_reads_mac + hits_this_op;
            end
            // (2) raw lane-cycles (registered hit asserted), for contrast only
            cyc_lanes = 0;
            for (kk = 0; kk < 25; kk = kk + 1)
                if (DUT.u_imc.U_SPOOL.hit_reg_bus[kk]) cyc_lanes = cyc_lanes + 1;
            sram_lane_cycles <= sram_lane_cycles + cyc_lanes;
        end
    end

    // ---- Capture conv1 (step_id==0, fbuf write) -----------------
    always @(posedge clk) begin
        if (!rst_n) begin
            conv1_count <= 0; conv1_first <= 32'hFFFF_FFFF; conv1_last <= 0;
        end else if (DUT.fbuf_write_en_fsm && (DUT.u_fsm.step_id == 4'd0)) begin
            conv1_cap[DUT.fbuf_write_addr_fsm] <= DUT.fbuf_write_data_fsm;
            if (conv1_count == 0) conv1_first <= cycle_after_start;
            conv1_last  <= cycle_after_start;
            conv1_count <= conv1_count + 1;
        end
    end

    // ---- Capture pool1 (step_id==1) -----------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            pool1_count <= 0; pool1_first <= 32'hFFFF_FFFF; pool1_last <= 0;
        end else if (DUT.fbuf_write_en_fsm && (DUT.u_fsm.step_id == 4'd1)) begin
            pool1_cap[DUT.fbuf_write_addr_fsm] <= DUT.fbuf_write_data_fsm;
            if (pool1_count == 0) pool1_first <= cycle_after_start;
            pool1_last  <= cycle_after_start;
            pool1_count <= pool1_count + 1;
        end
    end

    // ---- Capture conv2 (step_id==2) -----------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            conv2_count <= 0; conv2_first <= 32'hFFFF_FFFF; conv2_last <= 0;
        end else if (DUT.fbuf_write_en_fsm && (DUT.u_fsm.step_id == 4'd2)) begin
            conv2_cap[DUT.fbuf_write_addr_fsm] <= DUT.fbuf_write_data_fsm;
            if (conv2_count == 0) conv2_first <= cycle_after_start;
            conv2_last  <= cycle_after_start;
            conv2_count <= conv2_count + 1;
        end
    end

    // ---- Capture pool2 (step_id==3) -----------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            pool2_count <= 0; pool2_first <= 32'hFFFF_FFFF; pool2_last <= 0;
        end else if (DUT.fbuf_write_en_fsm && (DUT.u_fsm.step_id == 4'd3)) begin
            pool2_cap[DUT.fbuf_write_addr_fsm] <= DUT.fbuf_write_data_fsm;
            if (pool2_count == 0) pool2_first <= cycle_after_start;
            pool2_last  <= cycle_after_start;
            pool2_count <= pool2_count + 1;
        end
    end

    // ---- Capture fc1 (step_id==4) -------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            fc1_count <= 0; fc1_first <= 32'hFFFF_FFFF; fc1_last <= 0;
        end else if (DUT.fbuf_write_en_fsm && (DUT.u_fsm.step_id == 4'd4)) begin
            fc1_cap[DUT.fbuf_write_addr_fsm] <= DUT.fbuf_write_data_fsm;
            if (fc1_count == 0) fc1_first <= cycle_after_start;
            fc1_last  <= cycle_after_start;
            fc1_count <= fc1_count + 1;
        end
    end

    // ---- Capture fc2 (step_id==5) -------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            fc2_count <= 0; fc2_first <= 32'hFFFF_FFFF; fc2_last <= 0;
        end else if (DUT.fbuf_write_en_fsm && (DUT.u_fsm.step_id == 4'd5)) begin
            fc2_cap[DUT.fbuf_write_addr_fsm] <= DUT.fbuf_write_data_fsm;
            if (fc2_count == 0) fc2_first <= cycle_after_start;
            fc2_last  <= cycle_after_start;
            fc2_count <= fc2_count + 1;
        end
    end

    // ---- Capture fc3 (logit_write_en) — INT16 signed ------------
    always @(posedge clk) begin
        if (!rst_n) begin
            fc3_count <= 0; fc3_first <= 32'hFFFF_FFFF; fc3_last <= 0;
        end else if (DUT.logit_write_en) begin
            fc3_cap[DUT.logit_write_addr] <= DUT.logit_write_data;
            if (fc3_count == 0) fc3_first <= cycle_after_start;
            fc3_last  <= cycle_after_start;
            fc3_count <= fc3_count + 1;
        end
    end

    // ---- Stats ---------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;

    //==========================================================
    // Boot helper
    //==========================================================
    task do_cfg_write(input [5:0] a, input [31:0] d);
        begin
            @(negedge clk);
            cfg_wr_en   = 1'b1;
            cfg_wr_addr = a;
            cfg_wr_data = d;
            @(negedge clk);
            cfg_wr_en   = 1'b0;
        end
    endtask

    //==========================================================
    // Generic layer compare task — uses MAGIC parameter passing
    // via a string label. iverilog compiles individual blocks
    // rather than templates, so we inline per-layer.
    //==========================================================
    `define COMPARE_LAYER_U8(NAME, N, CAP, MIRROR) \
        begin: NAME``_compare_block \
            integer i, mis, nz, fm; \
            mis = 0; nz = 0; fm = -1; \
            for (i = 0; i < N; i = i + 1) begin \
                if (MIRROR[i] != 0) nz = nz + 1; \
                if (CAP[i] !== MIRROR[i]) begin \
                    if (mis < 3) \
                        $display("    [DIFF] %s[%0d] got=%0d exp=%0d", \
                                 `"NAME`", i, CAP[i], MIRROR[i]); \
                    if (fm < 0) fm = i; \
                    mis = mis + 1; \
                end \
            end \
            if (mis == 0) begin \
                pass_count = pass_count + 1; \
                $display("  [PASS] %s all %0d match golden (nonzero=%0d)", \
                         `"NAME`", N, nz); \
            end else begin \
                fail_count = fail_count + 1; \
                $display("  [FAIL] %s %0d/%0d mismatches (first at idx=%0d)", \
                         `"NAME`", mis, N, fm); \
            end \
        end

    //==========================================================
    // Main
    //==========================================================
    integer i;
    integer wait_count;

    initial begin
        $display("============================================================");
        $display("tb_lenet5_full_inference_v3   (Step 9 full LeNet inference)");
        $display("============================================================");
        $display("  %s", `MODEL_NAME);
        $display("  DATA_DIR   = %s", `DATA_DIR_STR);
        $display("  IMG        = %s", `IMG_FILE_STR);
        $display("  GOLDEN_DIR = %s", `GOLDEN_DIR);
        $display("");

        start       = 0;
        image_we    = 0;
        image_addr  = 0;
        image_data  = 0;
        cfg_wr_en   = 0;
        cfg_wr_addr = 0;
        cfg_wr_data = 0;
        rst_n       = 0;

        @(negedge clk); @(negedge clk); @(negedge clk);

        // Load all testbench mirrors
        $readmemh(`IMG_FILE_STR, image_mirror);
        $readmemh({`DATA_DIR_STR, "/layer_config.hex"}, cfg_words);
        $readmemh({`GOLDEN_DIR, "/golden_conv1_", `MODEL_TAG, "_img1.hex"}, conv1_mirror);
        $readmemh({`GOLDEN_DIR, "/golden_pool1_", `MODEL_TAG, "_img1.hex"}, pool1_mirror);
        $readmemh({`GOLDEN_DIR, "/golden_conv2_", `MODEL_TAG, "_img1.hex"}, conv2_mirror);
        $readmemh({`GOLDEN_DIR, "/golden_pool2_", `MODEL_TAG, "_img1.hex"}, pool2_mirror);
        $readmemh({`GOLDEN_DIR, "/golden_fc1_",   `MODEL_TAG, "_img1.hex"}, fc1_mirror);
        $readmemh({`GOLDEN_DIR, "/golden_fc2_",   `MODEL_TAG, "_img1.hex"}, fc2_mirror);
        $readmemh({`GOLDEN_DIR, "/golden_fc3_",   `MODEL_TAG, "_img1.hex"}, fc3_mirror);

        $display("  Loaded all goldens (conv1=%0d, pool1=%0d, conv2=%0d, pool2=%0d, fc1=%0d, fc2=%0d, fc3=%0d)",
                 CONV1_N, POOL1_N, CONV2_N, POOL2_N, FC1_N, FC2_N, FC3_N);
        $display("");

        @(negedge clk);
        rst_n = 1;
        @(negedge clk); @(negedge clk);

        //----------------------------------------------------------
        // T1 — Boot protocol
        //----------------------------------------------------------
        $display("T1  Boot protocol (full host wr_* sequence)");
        if (DUT.u_imc.cfg_valid_dbg === 1'b0) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T1.1 cfg_valid_dbg=0 after reset");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T1.1 cfg_valid_dbg=%b (expected 0)",
                     DUT.u_imc.cfg_valid_dbg);
        end

        for (i = 0; i < 10; i = i + 1) begin
            do_cfg_write(i[5:0], cfg_words[i]);
        end
        do_cfg_write(6'h21, 32'h0000_0000);
        do_cfg_write(6'h20, 32'h0000_0002);

        if (DUT.u_imc.cfg_valid_dbg === 1'b1 &&
            DUT.u_imc.enable_drift_dbg === 1'b0) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T1.2 after commit: cfg_valid=1, enable_drift=0");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T1.2 cfg_valid=%b drift=%b",
                     DUT.u_imc.cfg_valid_dbg, DUT.u_imc.enable_drift_dbg);
        end

        begin: cfg_verify
            integer cfg_idx, cfg_diffs;
            cfg_diffs = 0;
            for (cfg_idx = 0; cfg_idx < 10; cfg_idx = cfg_idx + 1) begin
                if (DUT.u_imc.U_REGFILE.cfg_mem[cfg_idx] !== cfg_words[cfg_idx])
                    cfg_diffs = cfg_diffs + 1;
            end
            if (cfg_diffs == 0) begin
                pass_count = pass_count + 1;
                $display("  [PASS] T1.3 all 10 cfg_mem entries match");
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T1.3 %0d cfg_mem mismatches", cfg_diffs);
            end
        end

        //----------------------------------------------------------
        // T2 — Image load
        //----------------------------------------------------------
        $display("");
        $display("T2  Image loading (28x28 = 784 pixels via image_we)");
        for (i = 0; i < 784; i = i + 1) begin
            @(negedge clk);
            image_we   = 1'b1;
            image_addr = i[FADDR_W-1:0];
            image_data = image_mirror[i];
        end
        @(negedge clk);
        image_we = 1'b0;
        pass_count = pass_count + 1;
        $display("  [PASS] T2.1 784 pixels written");

        //----------------------------------------------------------
        // T3 — Start inference and wait for done
        //----------------------------------------------------------
        $display("");
        $display("T3  Starting full inference + capturing 7 layer streams");

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // Wait for done==1.
        // Full inference cycle estimate: ~660K cycles + safety margin.
        wait_count = 0;
        while (!done_seen && wait_count < 2000000) begin
            @(negedge clk);
            wait_count = wait_count + 1;
        end

        if (!done_seen) begin
            fail_count = fail_count + 1;
            $display("  [FAIL] inference did not finish in %0d cycles", wait_count);
            $display("    captures so far: conv1=%0d pool1=%0d conv2=%0d pool2=%0d fc1=%0d fc2=%0d fc3=%0d",
                     conv1_count, pool1_count, conv2_count, pool2_count,
                     fc1_count, fc2_count, fc3_count);
            $display("    current step_id = %0d", DUT.u_fsm.step_id);
        end else begin
            pass_count = pass_count + 1;
            $display("  [PASS] inference complete at cycle %0d", done_cycle);
            $display("    captured counts: conv1=%0d pool1=%0d conv2=%0d pool2=%0d fc1=%0d fc2=%0d fc3=%0d",
                     conv1_count, pool1_count, conv2_count, pool2_count,
                     fc1_count, fc2_count, fc3_count);
        end

        //----------------------------------------------------------
        // T3.c — Capture-count hard check
        // Catches the case where a gate signal misses some
        // writebacks: count != expected would leave cap[i] at its
        // initial value (0 in iverilog), which would only be
        // detected by compare if golden[i] != 0 at that index.
        //----------------------------------------------------------
        $display("");
        if (conv1_count == CONV1_N && pool1_count == POOL1_N &&
            conv2_count == CONV2_N && pool2_count == POOL2_N &&
            fc1_count   == FC1_N   && fc2_count   == FC2_N   &&
            fc3_count   == FC3_N) begin
            pass_count = pass_count + 1;
            $display("T3.c [PASS] all layer capture counts match expected N");
        end else begin
            fail_count = fail_count + 1;
            $display("T3.c [FAIL] capture count mismatch:");
            $display("  conv1=%0d/%0d  pool1=%0d/%0d  conv2=%0d/%0d  pool2=%0d/%0d",
                     conv1_count, CONV1_N, pool1_count, POOL1_N,
                     conv2_count, CONV2_N, pool2_count, POOL2_N);
            $display("  fc1=%0d/%0d  fc2=%0d/%0d  fc3=%0d/%0d",
                     fc1_count, FC1_N, fc2_count, FC2_N,
                     fc3_count, FC3_N);
        end

        //----------------------------------------------------------
        // T3.0..T3.6 — Per-layer compare
        //----------------------------------------------------------
        $display("");
        $display("T3.x  Per-layer exact compare:");
        `COMPARE_LAYER_U8(conv1, CONV1_N, conv1_cap, conv1_mirror)
        `COMPARE_LAYER_U8(pool1, POOL1_N, pool1_cap, pool1_mirror)
        `COMPARE_LAYER_U8(conv2, CONV2_N, conv2_cap, conv2_mirror)
        `COMPARE_LAYER_U8(pool2, POOL2_N, pool2_cap, pool2_mirror)
        `COMPARE_LAYER_U8(fc1,   FC1_N,   fc1_cap,   fc1_mirror)
        `COMPARE_LAYER_U8(fc2,   FC2_N,   fc2_cap,   fc2_mirror)

        // fc3 is INT16 signed — separate compare block
        begin: fc3_compare_block
            integer i_fc3, mis, nz, fm;
            mis = 0; nz = 0; fm = -1;
            for (i_fc3 = 0; i_fc3 < FC3_N; i_fc3 = i_fc3 + 1) begin
                if (fc3_mirror[i_fc3] != 0) nz = nz + 1;
                if (fc3_cap[i_fc3] !== fc3_mirror[i_fc3]) begin
                    if (mis < 3)
                        $display("    [DIFF] fc3[%0d] got=%0d exp=%0d",
                                 i_fc3, fc3_cap[i_fc3], fc3_mirror[i_fc3]);
                    if (fm < 0) fm = i_fc3;
                    mis = mis + 1;
                end
            end
            if (mis == 0) begin
                pass_count = pass_count + 1;
                $display("  [PASS] fc3 all %0d INT16 logits match (nonzero=%0d)", FC3_N, nz);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] fc3 %0d/%0d INT16 mismatches (first at idx=%0d)",
                         mis, FC3_N, fm);
            end
        end

        //----------------------------------------------------------
        // T4 — predicted_class
        //----------------------------------------------------------
        $display("");
        begin: pred_compare
            integer expected_pred;
            // Recover expected predicted_class as the argmax of fc3_mirror
            // (signed strict-greater, ties → lowest)
            integer p, j;
            expected_pred = 0;
            for (j = 1; j < FC3_N; j = j + 1) begin
                if (fc3_mirror[j] > fc3_mirror[expected_pred]) expected_pred = j;
            end

            if (captured_pred == expected_pred[3:0]) begin
                pass_count = pass_count + 1;
                $display("T4  [PASS] predicted_class = %0d  (matches argmax of fc3 mirror)",
                         captured_pred);
            end else begin
                fail_count = fail_count + 1;
                $display("T4  [FAIL] predicted_class = %0d, expected = %0d",
                         captured_pred, expected_pred);
            end
            // Echo the 10 logits for verification
            $display("    fc3 mirror logits = [%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d]",
                     $signed(fc3_mirror[0]), $signed(fc3_mirror[1]), $signed(fc3_mirror[2]),
                     $signed(fc3_mirror[3]), $signed(fc3_mirror[4]), $signed(fc3_mirror[5]),
                     $signed(fc3_mirror[6]), $signed(fc3_mirror[7]), $signed(fc3_mirror[8]),
                     $signed(fc3_mirror[9]));
        end

        //----------------------------------------------------------
        // Per-layer cycle metrics
        //----------------------------------------------------------
        $display("");
        $display("============================================================");
        $display("Per-layer writeback windows (NOT pure compute latency):");
        $display("  conv1 : first=%0d last=%0d  window=%0d cycles (%0d outputs)",
                 conv1_first, conv1_last, (conv1_last - conv1_first + 1), CONV1_N);
        $display("  pool1 : first=%0d last=%0d  window=%0d cycles (%0d outputs)",
                 pool1_first, pool1_last, (pool1_last - pool1_first + 1), POOL1_N);
        $display("  conv2 : first=%0d last=%0d  window=%0d cycles (%0d outputs)",
                 conv2_first, conv2_last, (conv2_last - conv2_first + 1), CONV2_N);
        $display("  pool2 : first=%0d last=%0d  window=%0d cycles (%0d outputs)",
                 pool2_first, pool2_last, (pool2_last - pool2_first + 1), POOL2_N);
        $display("  fc1   : first=%0d last=%0d  window=%0d cycles (%0d outputs)",
                 fc1_first, fc1_last, (fc1_last - fc1_first + 1), FC1_N);
        $display("  fc2   : first=%0d last=%0d  window=%0d cycles (%0d outputs)",
                 fc2_first, fc2_last, (fc2_last - fc2_first + 1), FC2_N);
        $display("  fc3   : first=%0d last=%0d  window=%0d cycles (%0d outputs)",
                 fc3_first, fc3_last, (fc3_last - fc3_first + 1), FC3_N);
        $display("  argmax/finish : fc3_last=%0d done=%0d  window=%0d cycles",
                 fc3_last, done_cycle, (done_cycle - fc3_last));
        $display("");
        $display("Total inference cycles (start -> done) : %0d", done_cycle);
        $display("------------------------------------------------------------");
        $display("SRAM protected-weight reads (per MAC op): %0d", sram_reads_mac);
        $display("    x OpenRAM per-access energy = SRAM dynamic read energy");
        $display("    [raw lane-cycles, NOT the energy count: %0d]", sram_lane_cycles);
        $display("    (SRAM writes during inference = 0; pool loaded once at boot)");
        $display("============================================================");

        //----------------------------------------------------------
        // Summary
        //----------------------------------------------------------
        $display("");
        $display("============================================================");
        $display("Total: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count == 0) begin
            $display("RESULT: ALL TESTS PASSED");
        end else begin
            $display("RESULT: FAILED");
        end
        $display("============================================================");

        $finish;
    end

    initial begin
        #500000000;
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule
