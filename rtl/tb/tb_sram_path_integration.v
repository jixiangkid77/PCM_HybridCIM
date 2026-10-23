//============================================================
// tb_sram_path_integration.v
// Step 3c: end-to-end SRAM path integration test
//
// Instantiates the three already-unit-tested modules and runs
// the full SRAM path:
//
//   layer_config_regfile.v   (Step 2)
//     → sram_addr_decoder.v  (Step 3a)
//       → sram_pool.v        (Step 3b)
//         → weight (registered, 1-cycle latency)
//
// Boot flow:
//   1. Reset
//   2. Hierarchical $readmemh loads addr_to_slot ROMs (decoder)
//      and sram_pool memory (pool) -- these have no runtime
//      write port; simulation models them as initialized ROMs /
//      memory macros.
//   3. Deassert reset
//   4. Write layer_config_regfile entries via the FORMAL write
//      port (wr_en / wr_addr / wr_data), iterating over the
//      10-entry config loaded from layer_config.hex.
//   5. Commit by writing 0x3 to address 0x20 (cfg_valid +
//      enable_drift).
//
// Sweep:
//   For each layer, for each orig_addr in 0..depth-1:
//     - drive (layer_id, orig_addr)
//     - wait 1 cycle (decoder combinational, pool registers)
//     - sample weight
//     - compare against expected:
//         a2s_<L>_sram[orig] == FFFF  →  expected = 0
//         else                        →  expected = weights_<L>[orig]
//     - count hits / misses / errors / mismatches
//
// Pass criteria (per layer):
//   errors == 0  AND  mismatches == 0
//   hits == n_sram (from split_summary_v3)
//   misses == n_total - n_sram
//
// Run:
//   iverilog -g2012 -o build/tb_int \
//     rtl/src/layer_config_regfile.v \
//     rtl/src/sram_addr_decoder.v \
//     rtl/src/sram_pool.v \
//     rtl/tb/tb_sram_path_integration.v
//   vvp build/tb_int \
//     +DATA_DIR=data/rtl_inputs_A_v3 \
//     +SRC_DIR=data/rtl_inputs_A
//============================================================

`timescale 1ns/1ps

module tb_sram_path_integration;

    // ---- plusargs ------------------------------------------------
    reg [8*512-1:0] data_dir, src_dir;
    integer         have_data_dir, have_src_dir;

    function [8*512-1:0] trim(input [8*512-1:0] s);
        integer k;
        reg     started;
        reg [7:0] ch;
        begin
            trim    = {(8*512){1'b0}};
            started = 1'b0;
            for (k = 8*512-1; k >= 0; k = k - 8) begin
                ch = s[k -: 8];
                if (!started && ch != 8'h00) started = 1'b1;
                if (started) begin
                    trim = trim << 8;
                    trim[7:0] = ch;
                end
            end
        end
    endfunction

    // ---- Clocking + DUT-facing signals --------------------------
    reg         clk   = 0;
    reg         rst_n = 0;

    // Regfile write port (testbench drives like a host CPU)
    reg         wr_en   = 0;
    reg [5:0]   wr_addr = 0;
    reg [31:0]  wr_data = 0;

    // Layer/orig drive (controlled by testbench in sweep phase)
    reg [2:0]   layer_id  = 0;
    reg [15:0]  orig_addr = 0;

    // Wires between the three modules
    wire [15:0] sram_base, sram_size, pcm_base_w, pcm_size_w;
    wire        cfg_valid_w, enable_drift_w;
    wire [15:0] drift_t_w;
    wire        sram_hit;
    wire [15:0] sram_pool_addr;
    wire        sram_oor_error;
    wire signed [7:0] weight;

    // ---- DUT instantiations (X' structure: 3 modules in series)--
    layer_config_regfile #(.DATA_DIR("")) U_REGFILE (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wr_en),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .rd_addr(6'h00),
        .rd_data(/* unused */),
        .layer_id(layer_id),
        .sram_base(sram_base),
        .sram_size(sram_size),
        .pcm_base(pcm_base_w),
        .pcm_size(pcm_size_w),
        .cfg_valid(cfg_valid_w),
        .enable_drift(enable_drift_w),
        .drift_t(drift_t_w)
    );

    sram_addr_decoder #(.DATA_DIR("")) U_DEC (
        .layer_id(layer_id),
        .orig_addr(orig_addr),
        .sram_base(sram_base),
        .sram_size(sram_size),
        .sram_hit(sram_hit),
        .sram_pool_addr(sram_pool_addr),
        .sram_oor_error(sram_oor_error)
    );

    sram_pool #(.DATA_DIR("")) U_POOL (
        .clk(clk),
        .rst_n(rst_n),
        .addr(sram_pool_addr),
        .hit(sram_hit),
        .weight(weight)
    );

    always #5 clk = ~clk;   // 100 MHz

    // ---- Testbench-side mirrors ---------------------------------
    reg [31:0]       cfg_words [0:9];
    reg [15:0]       a2s_conv1 [0:149];
    reg [15:0]       a2s_conv2 [0:2399];
    reg [15:0]       a2s_fc1   [0:47999];
    reg [15:0]       a2s_fc2   [0:10079];
    reg [15:0]       a2s_fc3   [0:839];
    reg signed [7:0] w_conv1   [0:149];
    reg signed [7:0] w_conv2   [0:2399];
    reg signed [7:0] w_fc1     [0:47999];
    reg signed [7:0] w_fc2     [0:10079];
    reg signed [7:0] w_fc3     [0:839];

    // ---- Expected totals (model-invariant) ----------------------
    // Pool sizes are model-independent constants set by Paper 1's
    // 5% protection budget on a 61,470-weight LeNet-5.
    localparam integer EXPECT_TOTAL_HITS   = 3074;
    localparam integer EXPECT_TOTAL_MISSES = 58396;

    // ---- Stats ---------------------------------------------------
    integer layers_passed = 0;
    integer layers_failed = 0;
    integer total_hits = 0;
    integer total_misses = 0;
    integer total_errors = 0;
    integer total_mismatches = 0;

    // ---- Helper: write to regfile via formal write port ---------
    task do_cfg_write(input [5:0] a, input [31:0] d);
        begin
            @(negedge clk);
            wr_en   = 1'b1;
            wr_addr = a;
            wr_data = d;
            @(negedge clk);
            wr_en   = 1'b0;
        end
    endtask

    // ---- Helper: layer name string ------------------------------
    function [8*6-1:0] layer_name(input integer lid);
        case (lid)
            0:       layer_name = "conv1 ";
            1:       layer_name = "conv2 ";
            2:       layer_name = "fc1   ";
            3:       layer_name = "fc2   ";
            4:       layer_name = "fc3   ";
            default: layer_name = "????? ";
        endcase
    endfunction

    // ---- Sweep one layer ----------------------------------------
    // Drives every orig_addr in 0..depth-1, compares output
    // against testbench mirror. Reports per-layer stats.
    integer h_cnt, m_cnt, e_cnt, mm_cnt;
    integer a, depth;
    integer a2s_val;
    reg signed [7:0] w_val, expected;

    task sweep_layer(input integer lid);
        begin
            case (lid)
                0: depth = 150;
                1: depth = 2400;
                2: depth = 48000;
                3: depth = 10080;
                4: depth = 840;
                default: depth = 0;
            endcase

            h_cnt = 0; m_cnt = 0; e_cnt = 0; mm_cnt = 0;

            for (a = 0; a < depth; a = a + 1) begin
                case (lid)
                    0: begin a2s_val = a2s_conv1[a]; w_val = w_conv1[a]; end
                    1: begin a2s_val = a2s_conv2[a]; w_val = w_conv2[a]; end
                    2: begin a2s_val = a2s_fc1[a];   w_val = w_fc1[a];   end
                    3: begin a2s_val = a2s_fc2[a];   w_val = w_fc2[a];   end
                    4: begin a2s_val = a2s_fc3[a];   w_val = w_fc3[a];   end
                    default: begin a2s_val = 16'hFFFF; w_val = 8'sd0; end
                endcase

                // Expected: 0 if not in SRAM, else original weight
                if (a2s_val == 16'hFFFF) expected = 8'sd0;
                else                     expected = w_val;

                @(negedge clk);
                layer_id  = lid[2:0];
                orig_addr = a[15:0];
                @(negedge clk);  // posedge in between registered pool

                if (sram_oor_error) e_cnt = e_cnt + 1;

                if (weight === expected) begin
                    if (a2s_val == 16'hFFFF) m_cnt = m_cnt + 1;
                    else                     h_cnt = h_cnt + 1;
                end else begin
                    mm_cnt = mm_cnt + 1;
                    if (mm_cnt <= 3) begin
                        $display("    [MISMATCH] layer=%0d orig=%0d  got=%0d (0x%02x)  exp=%0d (0x%02x)  a2s=%04x",
                                 lid, a, weight, weight & 8'hff,
                                 expected, expected & 8'hff, a2s_val);
                    end
                end
            end

            // Per-layer report
            $display("  %s : hits=%0d  misses=%0d  errors=%0d  mismatches=%0d",
                     layer_name(lid), h_cnt, m_cnt, e_cnt, mm_cnt);

            if (e_cnt == 0 && mm_cnt == 0) layers_passed = layers_passed + 1;
            else                            layers_failed = layers_failed + 1;

            total_hits       = total_hits       + h_cnt;
            total_misses     = total_misses     + m_cnt;
            total_errors     = total_errors     + e_cnt;
            total_mismatches = total_mismatches + mm_cnt;
        end
    endtask

    // ---- Main test sequence -------------------------------------
    integer i;

    initial begin
        $display("============================================================");

        // --- parse plusargs ---
        data_dir = {(8*512){1'b0}};
        src_dir  = {(8*512){1'b0}};
        have_data_dir = $value$plusargs("DATA_DIR=%s", data_dir);
        have_src_dir  = $value$plusargs("SRC_DIR=%s",  src_dir);

        if (!have_data_dir || !have_src_dir) begin
            $display("ERROR: both +DATA_DIR and +SRC_DIR must be provided.");
            $display("  +DATA_DIR -> v3 outputs (addr_to_slot, sram_pool, layer_config)");
            $display("  +SRC_DIR  -> original v2 weights (weights_<L>.hex)");
            $display("Example: vvp build/tb_int +DATA_DIR=data/rtl_inputs_A_v3 +SRC_DIR=data/rtl_inputs_A");
            $finish;
        end

        $display("tb_sram_path_integration");
        $display("  DATA_DIR=\"%0s\"  (v3 outputs)", trim(data_dir));
        $display("  SRC_DIR =\"%0s\"  (v2 weights)", trim(src_dir));
        $display("============================================================");

        // --- Hold reset, load all ROMs/memories via $readmemh ---
        rst_n     = 1'b0;
        wr_en     = 1'b0;
        layer_id  = 3'd0;
        orig_addr = 16'd0;

        // DUT-side: addr_to_slot ROMs (no write port) + sram_pool
        $readmemh({trim(data_dir), "/addr_to_slot_conv1_sram.hex"}, U_DEC.rom_conv1);
        $readmemh({trim(data_dir), "/addr_to_slot_conv2_sram.hex"}, U_DEC.rom_conv2);
        $readmemh({trim(data_dir), "/addr_to_slot_fc1_sram.hex"},   U_DEC.rom_fc1);
        $readmemh({trim(data_dir), "/addr_to_slot_fc2_sram.hex"},   U_DEC.rom_fc2);
        $readmemh({trim(data_dir), "/addr_to_slot_fc3_sram.hex"},   U_DEC.rom_fc3);
        $readmemh({trim(data_dir), "/sram_pool.hex"},               U_POOL.sram_pool_mem);

        // Testbench-side: same files mirrored for expected-value computation
        $readmemh({trim(data_dir), "/layer_config.hex"},            cfg_words);
        $readmemh({trim(data_dir), "/addr_to_slot_conv1_sram.hex"}, a2s_conv1);
        $readmemh({trim(data_dir), "/addr_to_slot_conv2_sram.hex"}, a2s_conv2);
        $readmemh({trim(data_dir), "/addr_to_slot_fc1_sram.hex"},   a2s_fc1);
        $readmemh({trim(data_dir), "/addr_to_slot_fc2_sram.hex"},   a2s_fc2);
        $readmemh({trim(data_dir), "/addr_to_slot_fc3_sram.hex"},   a2s_fc3);
        $readmemh({trim(src_dir),  "/weights_conv1.hex"},           w_conv1);
        $readmemh({trim(src_dir),  "/weights_conv2.hex"},           w_conv2);
        $readmemh({trim(src_dir),  "/weights_fc1.hex"},             w_fc1);
        $readmemh({trim(src_dir),  "/weights_fc2.hex"},             w_fc2);
        $readmemh({trim(src_dir),  "/weights_fc3.hex"},             w_fc3);

        $display("Boot: loaded ROMs/mirrors. Releasing reset.");
        @(negedge clk); @(negedge clk); @(negedge clk);
        rst_n = 1'b1;

        // --- Boot configuration via formal write port ---
        $display("");
        $display("Boot phase: writing layer_config_regfile via wr_en port");
        for (i = 0; i < 10; i = i + 1) begin
            do_cfg_write(i[5:0], cfg_words[i]);
        end
        // Commit: bit0=enable_drift, bit1=cfg_commit
        do_cfg_write(6'h20, 32'h0000_0003);
        $display("  wrote cfg[0x00..0x09] + commit 0x20=0x3");
        $display("  regfile sees: sram_base/size readout works -- verified by sweep");

        // Flush a couple cycles before sweep
        @(negedge clk); @(negedge clk);

        // --- Sweep phase ---
        $display("");
        $display("Sweep phase: full orig_addr scan");
        $display("  layer    : hits  misses errors mismatches");
        for (i = 0; i < 5; i = i + 1) begin
            sweep_layer(i);
        end

        // --- Summary ---
        $display("");
        $display("============================================================");
        $display("Totals: hits=%0d  misses=%0d  errors=%0d  mismatches=%0d",
                 total_hits, total_misses, total_errors, total_mismatches);
        $display("        layers_passed=%0d / 5", layers_passed);
        $display("        grand total weights tested = %0d",
                 total_hits + total_misses);
        $display("        expect: hits=%0d  misses=%0d",
                 EXPECT_TOTAL_HITS, EXPECT_TOTAL_MISSES);
        if (total_errors     == 0 &&
            total_mismatches == 0 &&
            layers_passed    == 5 &&
            total_hits       == EXPECT_TOTAL_HITS &&
            total_misses     == EXPECT_TOTAL_MISSES) begin
            $display("RESULT: ALL TESTS PASSED");
        end else begin
            $display("RESULT: FAILED");
        end
        $display("============================================================");

        $finish;
    end

    // Watchdog: 10 ms (sweep is ~615 us at 100 MHz, this is 16x margin)
    initial begin
        #10_000_000;
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule
