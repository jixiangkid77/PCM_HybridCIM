//============================================================
// tb_pcm_imc_unit.v
// Step 5b: pcm_imc_unit v3 top-level integration tests
//
// Validates the full hybrid SRAM/PCM IMC unit:
//   layer_config_regfile
//   sram_addr_decoder ×25
//   sram_pool_25lane
//   sram_mac
//   pcm_addr_decoder ×25
//   pcm_crossbar (v3)
//   combiner
//
// Tests (Method X for exact, Method Y for drift):
//   T1 SRAM-only MAC  (25 lanes all SRAM-hit in conv2)
//   T2 PCM-only MAC   (25 lanes all PCM-hit in conv2)
//   T3 Hybrid mixed
//   T4 SRAM/PCM mutex + XOR completeness check
//   T5 Latency: start -> result_valid in ~8 cycles
//   T6 cfg_valid gating (no commit -> no MAC)
//   T7 enable_drift=1 sanity (non-X)
//   T8 Two sequential MAC ops
//============================================================

`timescale 1ns/1ps

module tb_pcm_imc_unit;

    localparam integer K           = 25;
    localparam integer DATA_WIDTH  = 8;
    localparam integer ADDR_WIDTH  = 16;
    localparam integer ACC_WIDTH   = 24;
    localparam integer SRAM_TOTAL  = 3074;
    localparam integer PCM_TOTAL   = 58396;
    localparam integer SRAM_LATENCY = 2;
    localparam integer PCM_LATENCY  = 8;

    // ---- plusargs ------------------------------------------------
    reg [8*512-1:0] data_dir;
    reg [8*512-1:0] common_dir;
    integer         have_data_dir, have_common_dir;

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

    // ---- Clock + reset -------------------------------------------
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    // ---- DUT I/O -------------------------------------------------
    reg                       start;
    reg                       wr_en;
    reg  [5:0]                wr_addr;
    reg  [31:0]               wr_data;
    reg  [2:0]                layer_id;
    reg  [K*DATA_WIDTH-1:0]   v_bus;
    reg  [K*ADDR_WIDTH-1:0]   orig_addr_bus;

    wire signed [ACC_WIDTH-1:0] mac_result;
    wire                        result_valid;
    wire                        cfg_valid_dbg;
    wire                        enable_drift_dbg;
    wire [15:0]                 drift_t_dbg;
    wire [K-1:0]                sram_hit_dbg;
    wire [K-1:0]                pcm_hit_dbg;
    wire [K-1:0]                sram_oor_dbg;
    wire [K-1:0]                pcm_oor_dbg;

    pcm_imc_unit #(
        .K(K),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .SRAM_TOTAL(SRAM_TOTAL),
        .PCM_TOTAL(PCM_TOTAL),
        .SRAM_LATENCY(SRAM_LATENCY),
        .PCM_LATENCY(PCM_LATENCY),
        .DATA_DIR(""),
        .COMMON_DIR("")
    ) DUT (
        .clk(clk), .rst_n(rst_n), .start(start),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .layer_id(layer_id),
        .v_bus(v_bus),
        .orig_addr_bus(orig_addr_bus),
        .mac_result(mac_result),
        .result_valid(result_valid),
        .cfg_valid_dbg(cfg_valid_dbg),
        .enable_drift_dbg(enable_drift_dbg),
        .drift_t_dbg(drift_t_dbg),
        .sram_hit_dbg(sram_hit_dbg),
        .pcm_hit_dbg(pcm_hit_dbg),
        .sram_oor_dbg(sram_oor_dbg),
        .pcm_oor_dbg(pcm_oor_dbg)
    );

    // ---- Mirrors -------------------------------------------------
    reg [31:0]       cfg_mirror     [0:9];
    reg [15:0]       a2s_conv1_sram [0:149];
    reg [15:0]       a2s_conv2_sram [0:2399];
    reg [15:0]       a2s_fc1_sram   [0:47999];
    reg [15:0]       a2s_fc2_sram   [0:10079];
    reg [15:0]       a2s_fc3_sram   [0:839];
    reg [15:0]       a2s_conv1_pcm  [0:149];
    reg [15:0]       a2s_conv2_pcm  [0:2399];
    reg [15:0]       a2s_fc1_pcm    [0:47999];
    reg [15:0]       a2s_fc2_pcm    [0:10079];
    reg [15:0]       a2s_fc3_pcm    [0:839];
    reg signed [7:0] sram_pool_mirror [0:SRAM_TOTAL-1];
    reg signed [7:0] pcm_pool_mirror  [0:PCM_TOTAL-1];

    // Per-lane testbench state
    reg [15:0]       orig_lane_tb [0:K-1];
    reg signed [7:0] v_lane_tb    [0:K-1];

    integer hit_origs [0:24];
    integer hit_count_out;

    integer pass_count = 0;
    integer fail_count = 0;

    //==========================================================
    // Helpers
    //==========================================================
    task clear_all_lanes;
        integer j;
        begin
            v_bus         = {(K*DATA_WIDTH){1'b0}};
            orig_addr_bus = {(K*ADDR_WIDTH){1'b0}};
            for (j = 0; j < K; j = j + 1) begin
                orig_lane_tb[j] = 16'd0;
                v_lane_tb[j]    = 8'sd0;
            end
        end
    endtask

    task set_lane(input integer lane,
                  input integer orig,
                  input integer v);
        begin
            orig_addr_bus[lane*ADDR_WIDTH +: ADDR_WIDTH] = orig[15:0];
            v_bus[lane*DATA_WIDTH +: DATA_WIDTH]         = v[7:0];
            orig_lane_tb[lane] = orig[15:0];
            v_lane_tb[lane]    = v[7:0];
        end
    endtask

    function signed [ACC_WIDTH-1:0] lane_sram_contribution(input integer lane);
        integer lid_i;
        reg [15:0] base, size, local_slot;
        reg [16:0] sum_ext;
        reg [15:0] pool_addr;
        begin
            lid_i = layer_id;
            if (lid_i > 4) begin
                lane_sram_contribution = 0;
            end else begin
                base = cfg_mirror[lid_i][15:0];
                size = cfg_mirror[lid_i][31:16];
                case (lid_i)
                    0: local_slot = (orig_lane_tb[lane] < 16'd150)
                                     ? a2s_conv1_sram[orig_lane_tb[lane]] : 16'hFFFF;
                    1: local_slot = (orig_lane_tb[lane] < 16'd2400)
                                     ? a2s_conv2_sram[orig_lane_tb[lane]] : 16'hFFFF;
                    2: local_slot = (orig_lane_tb[lane] < 16'd48000)
                                     ? a2s_fc1_sram[orig_lane_tb[lane]]   : 16'hFFFF;
                    3: local_slot = (orig_lane_tb[lane] < 16'd10080)
                                     ? a2s_fc2_sram[orig_lane_tb[lane]]   : 16'hFFFF;
                    4: local_slot = (orig_lane_tb[lane] < 16'd840)
                                     ? a2s_fc3_sram[orig_lane_tb[lane]]   : 16'hFFFF;
                    default: local_slot = 16'hFFFF;
                endcase
                if (local_slot == 16'hFFFF) begin
                    lane_sram_contribution = 0;
                end else begin
                    sum_ext = {1'b0, base} + {1'b0, local_slot};
                    if (sum_ext >= 17'd3074 || local_slot >= size) begin
                        lane_sram_contribution = 0;
                    end else begin
                        pool_addr = sum_ext[15:0];
                        lane_sram_contribution = $signed(v_lane_tb[lane])
                                              * $signed(sram_pool_mirror[pool_addr]);
                    end
                end
            end
        end
    endfunction

    function signed [ACC_WIDTH-1:0] lane_pcm_contribution(input integer lane);
        integer lid_i;
        reg [15:0] base, size, local_slot;
        reg [16:0] sum_ext;
        reg [15:0] pool_addr;
        begin
            lid_i = layer_id;
            if (lid_i > 4) begin
                lane_pcm_contribution = 0;
            end else begin
                base = cfg_mirror[lid_i + 5][15:0];
                size = cfg_mirror[lid_i + 5][31:16];
                case (lid_i)
                    0: local_slot = (orig_lane_tb[lane] < 16'd150)
                                     ? a2s_conv1_pcm[orig_lane_tb[lane]] : 16'hFFFF;
                    1: local_slot = (orig_lane_tb[lane] < 16'd2400)
                                     ? a2s_conv2_pcm[orig_lane_tb[lane]] : 16'hFFFF;
                    2: local_slot = (orig_lane_tb[lane] < 16'd48000)
                                     ? a2s_fc1_pcm[orig_lane_tb[lane]]   : 16'hFFFF;
                    3: local_slot = (orig_lane_tb[lane] < 16'd10080)
                                     ? a2s_fc2_pcm[orig_lane_tb[lane]]   : 16'hFFFF;
                    4: local_slot = (orig_lane_tb[lane] < 16'd840)
                                     ? a2s_fc3_pcm[orig_lane_tb[lane]]   : 16'hFFFF;
                    default: local_slot = 16'hFFFF;
                endcase
                if (local_slot == 16'hFFFF) begin
                    lane_pcm_contribution = 0;
                end else begin
                    sum_ext = {1'b0, base} + {1'b0, local_slot};
                    if (sum_ext >= 17'd58396 || local_slot >= size) begin
                        lane_pcm_contribution = 0;
                    end else begin
                        pool_addr = sum_ext[15:0];
                        lane_pcm_contribution = $signed(v_lane_tb[lane])
                                              * $signed(pcm_pool_mirror[pool_addr]);
                    end
                end
            end
        end
    endfunction

    function signed [ACC_WIDTH-1:0] compute_expected_sram_partial;
        integer j;
        begin
            compute_expected_sram_partial = 0;
            for (j = 0; j < K; j = j + 1) begin
                compute_expected_sram_partial =
                    compute_expected_sram_partial + lane_sram_contribution(j);
            end
        end
    endfunction

    function signed [ACC_WIDTH-1:0] compute_expected_pcm_partial;
        integer j;
        begin
            compute_expected_pcm_partial = 0;
            for (j = 0; j < K; j = j + 1) begin
                compute_expected_pcm_partial =
                    compute_expected_pcm_partial + lane_pcm_contribution(j);
            end
        end
    endfunction

    function signed [ACC_WIDTH-1:0] compute_expected_total;
        begin
            compute_expected_total =
                compute_expected_sram_partial() + compute_expected_pcm_partial();
        end
    endfunction

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

    task run_mac_op(output signed [ACC_WIDTH-1:0] got);
        integer waited;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            waited = 0;
            while (!result_valid && waited < (PCM_LATENCY + 8)) begin
                @(negedge clk);
                waited = waited + 1;
            end
            if (!result_valid) begin
                $display("  [WARN] result_valid did not fire");
                got = 0;
            end else begin
                got = mac_result;
            end
        end
    endtask

    task expect_mac_eq(input [255:0] name,
                       input signed [ACC_WIDTH-1:0] got,
                       input signed [ACC_WIDTH-1:0] exp_val);
        begin
            if (got === exp_val) begin
                pass_count = pass_count + 1;
                $display("  [PASS] %0s  got=%0d", name, got);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] %0s  got=%0d  exp=%0d", name, got, exp_val);
            end
        end
    endtask

    task check_mutex_xor(input [255:0] name, input [K-1:0] valid_mask);
        integer j;
        integer mutex_fails, complete_fails;
        begin
            mutex_fails = 0; complete_fails = 0;
            for (j = 0; j < K; j = j + 1) begin
                if (valid_mask[j]) begin
                    if (sram_hit_dbg[j] === 1'b1 && pcm_hit_dbg[j] === 1'b1) begin
                        mutex_fails = mutex_fails + 1;
                        $display("    lane %0d: MUTEX violation", j);
                    end
                    if (sram_hit_dbg[j] === 1'b0 && pcm_hit_dbg[j] === 1'b0) begin
                        complete_fails = complete_fails + 1;
                        $display("    lane %0d: COMPLETE violation", j);
                    end
                end
            end
            if (mutex_fails == 0 && complete_fails == 0) begin
                pass_count = pass_count + 1;
                $display("  [PASS] %0s", name);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] %0s  mutex=%0d complete=%0d",
                         name, mutex_fails, complete_fails);
            end
        end
    endtask

    task find_first_n_sram_hits_conv2(input integer n);
        integer count, a, j;
        begin
            for (j = 0; j < 25; j = j + 1) hit_origs[j] = -1;
            count = 0;
            for (a = 0; a < 2400; a = a + 1) begin
                if (count >= n) a = 2400;
                else if (a2s_conv2_sram[a] != 16'hFFFF) begin
                    hit_origs[count] = a;
                    count = count + 1;
                end
            end
            hit_count_out = count;
        end
    endtask

    task find_first_n_pcm_hits_conv2(input integer n);
        integer count, a, j;
        begin
            for (j = 0; j < 25; j = j + 1) hit_origs[j] = -1;
            count = 0;
            for (a = 0; a < 2400; a = a + 1) begin
                if (count >= n) a = 2400;
                else if (a2s_conv2_pcm[a] != 16'hFFFF) begin
                    hit_origs[count] = a;
                    count = count + 1;
                end
            end
            hit_count_out = count;
        end
    endtask

    //==========================================================
    // Hierarchical $readmemh macros
    //==========================================================
    `define LOAD_SRAM_DEC_LANE(I) \
        $readmemh({trim(data_dir), "/addr_to_slot_conv1_sram.hex"}, DUT.sram_dec[I].U_SDEC.rom_conv1); \
        $readmemh({trim(data_dir), "/addr_to_slot_conv2_sram.hex"}, DUT.sram_dec[I].U_SDEC.rom_conv2); \
        $readmemh({trim(data_dir), "/addr_to_slot_fc1_sram.hex"},   DUT.sram_dec[I].U_SDEC.rom_fc1);   \
        $readmemh({trim(data_dir), "/addr_to_slot_fc2_sram.hex"},   DUT.sram_dec[I].U_SDEC.rom_fc2);   \
        $readmemh({trim(data_dir), "/addr_to_slot_fc3_sram.hex"},   DUT.sram_dec[I].U_SDEC.rom_fc3);

    `define LOAD_PCM_DEC_LANE(I) \
        $readmemh({trim(data_dir), "/addr_to_slot_conv1_pcm.hex"}, DUT.pcm_dec[I].U_PDEC.rom_conv1); \
        $readmemh({trim(data_dir), "/addr_to_slot_conv2_pcm.hex"}, DUT.pcm_dec[I].U_PDEC.rom_conv2); \
        $readmemh({trim(data_dir), "/addr_to_slot_fc1_pcm.hex"},   DUT.pcm_dec[I].U_PDEC.rom_fc1);   \
        $readmemh({trim(data_dir), "/addr_to_slot_fc2_pcm.hex"},   DUT.pcm_dec[I].U_PDEC.rom_fc2);   \
        $readmemh({trim(data_dir), "/addr_to_slot_fc3_pcm.hex"},   DUT.pcm_dec[I].U_PDEC.rom_fc3);

    task load_all_dut_memories;
        begin
            if (have_common_dir) begin
                $readmemh({trim(common_dir), "/log2_lut.hex"}, DUT.U_PCB.log2_lut);
                $readmemh({trim(common_dir), "/exp2_lut.hex"}, DUT.U_PCB.exp2_lut);
            end else begin
                $readmemh("data/rtl_inputs_common/log2_lut.hex", DUT.U_PCB.log2_lut);
                $readmemh("data/rtl_inputs_common/exp2_lut.hex", DUT.U_PCB.exp2_lut);
            end
            $readmemh({trim(data_dir), "/sram_pool.hex"},   DUT.U_SPOOL.sram_pool_mem);
            $readmemh({trim(data_dir), "/pcm_pool.hex"},    DUT.U_PCB.pcm_pool);
            $readmemh({trim(data_dir), "/nu_pcm_pool.hex"}, DUT.U_PCB.nu_pcm_pool);
            $readmemh({trim(data_dir), "/layer_config.hex"}, DUT.U_REGFILE.cfg_mem);

            `LOAD_SRAM_DEC_LANE(0)  `LOAD_SRAM_DEC_LANE(1)  `LOAD_SRAM_DEC_LANE(2)
            `LOAD_SRAM_DEC_LANE(3)  `LOAD_SRAM_DEC_LANE(4)  `LOAD_SRAM_DEC_LANE(5)
            `LOAD_SRAM_DEC_LANE(6)  `LOAD_SRAM_DEC_LANE(7)  `LOAD_SRAM_DEC_LANE(8)
            `LOAD_SRAM_DEC_LANE(9)  `LOAD_SRAM_DEC_LANE(10) `LOAD_SRAM_DEC_LANE(11)
            `LOAD_SRAM_DEC_LANE(12) `LOAD_SRAM_DEC_LANE(13) `LOAD_SRAM_DEC_LANE(14)
            `LOAD_SRAM_DEC_LANE(15) `LOAD_SRAM_DEC_LANE(16) `LOAD_SRAM_DEC_LANE(17)
            `LOAD_SRAM_DEC_LANE(18) `LOAD_SRAM_DEC_LANE(19) `LOAD_SRAM_DEC_LANE(20)
            `LOAD_SRAM_DEC_LANE(21) `LOAD_SRAM_DEC_LANE(22) `LOAD_SRAM_DEC_LANE(23)
            `LOAD_SRAM_DEC_LANE(24)

            `LOAD_PCM_DEC_LANE(0)  `LOAD_PCM_DEC_LANE(1)  `LOAD_PCM_DEC_LANE(2)
            `LOAD_PCM_DEC_LANE(3)  `LOAD_PCM_DEC_LANE(4)  `LOAD_PCM_DEC_LANE(5)
            `LOAD_PCM_DEC_LANE(6)  `LOAD_PCM_DEC_LANE(7)  `LOAD_PCM_DEC_LANE(8)
            `LOAD_PCM_DEC_LANE(9)  `LOAD_PCM_DEC_LANE(10) `LOAD_PCM_DEC_LANE(11)
            `LOAD_PCM_DEC_LANE(12) `LOAD_PCM_DEC_LANE(13) `LOAD_PCM_DEC_LANE(14)
            `LOAD_PCM_DEC_LANE(15) `LOAD_PCM_DEC_LANE(16) `LOAD_PCM_DEC_LANE(17)
            `LOAD_PCM_DEC_LANE(18) `LOAD_PCM_DEC_LANE(19) `LOAD_PCM_DEC_LANE(20)
            `LOAD_PCM_DEC_LANE(21) `LOAD_PCM_DEC_LANE(22) `LOAD_PCM_DEC_LANE(23)
            `LOAD_PCM_DEC_LANE(24)
        end
    endtask

    //==========================================================
    // Main test sequence
    //==========================================================
    integer i;
    reg signed [ACC_WIDTH-1:0] got_mac, exp_mac;
    reg signed [ACC_WIDTH-1:0] exp_sram, exp_pcm;
    reg [K-1:0] valid_mask;

    initial begin
        $display("============================================================");

        data_dir   = {(8*512){1'b0}};
        common_dir = {(8*512){1'b0}};
        have_data_dir   = $value$plusargs("DATA_DIR=%s",   data_dir);
        have_common_dir = $value$plusargs("COMMON_DIR=%s", common_dir);

        if (!have_data_dir) begin
            $display("ERROR: +DATA_DIR required.");
            $finish;
        end

        // Reset
        start    = 0;
        wr_en    = 0;
        wr_addr  = 0;
        wr_data  = 0;
        layer_id = 0;
        clear_all_lanes;
        rst_n = 0;
        @(negedge clk); @(negedge clk); @(negedge clk);

        load_all_dut_memories();

        // Load testbench mirrors
        $readmemh({trim(data_dir), "/layer_config.hex"},            cfg_mirror);
        $readmemh({trim(data_dir), "/sram_pool.hex"},               sram_pool_mirror);
        $readmemh({trim(data_dir), "/pcm_pool.hex"},                pcm_pool_mirror);
        $readmemh({trim(data_dir), "/addr_to_slot_conv1_sram.hex"}, a2s_conv1_sram);
        $readmemh({trim(data_dir), "/addr_to_slot_conv2_sram.hex"}, a2s_conv2_sram);
        $readmemh({trim(data_dir), "/addr_to_slot_fc1_sram.hex"},   a2s_fc1_sram);
        $readmemh({trim(data_dir), "/addr_to_slot_fc2_sram.hex"},   a2s_fc2_sram);
        $readmemh({trim(data_dir), "/addr_to_slot_fc3_sram.hex"},   a2s_fc3_sram);
        $readmemh({trim(data_dir), "/addr_to_slot_conv1_pcm.hex"},  a2s_conv1_pcm);
        $readmemh({trim(data_dir), "/addr_to_slot_conv2_pcm.hex"},  a2s_conv2_pcm);
        $readmemh({trim(data_dir), "/addr_to_slot_fc1_pcm.hex"},    a2s_fc1_pcm);
        $readmemh({trim(data_dir), "/addr_to_slot_fc2_pcm.hex"},    a2s_fc2_pcm);
        $readmemh({trim(data_dir), "/addr_to_slot_fc3_pcm.hex"},    a2s_fc3_pcm);

        $display("tb_pcm_imc_unit");
        $display("  DATA_DIR  = \"%0s\"", trim(data_dir));
        $display("============================================================");

        // Deassert reset
        rst_n = 1;
        @(negedge clk); @(negedge clk);

        // Commit cfg_valid (bit1) with enable_drift=0 (bit0)
        do_cfg_write(6'h20, 32'h0000_0002);
        $display("");
        $display("Boot: cfg_commit pulsed -> cfg_valid=%b enable_drift=%b drift_t=%0d",
                 cfg_valid_dbg, enable_drift_dbg, drift_t_dbg);

        //----------------------------------------------------------
        // T1 — SRAM-only MAC
        //----------------------------------------------------------
        $display("");
        $display("T1  SRAM-only MAC (25 lanes all SRAM-hit conv2)");
        clear_all_lanes;
        layer_id = 3'd1;
        find_first_n_sram_hits_conv2(25);
        if (hit_count_out < 25) begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T1.setup: only %0d SRAM hits", hit_count_out);
        end else begin
            for (i = 0; i < 25; i = i + 1) begin
                set_lane(i, hit_origs[i], i - 12);
            end
            #1;
            if (sram_hit_dbg === 25'h1FFFFFF && pcm_hit_dbg === 25'd0) begin
                pass_count = pass_count + 1;
                $display("  [PASS] T1.1 hit mask: all sram, no pcm");
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T1.1 sram=%h pcm=%h", sram_hit_dbg, pcm_hit_dbg);
            end
            exp_mac = compute_expected_total();
            run_mac_op(got_mac);
            expect_mac_eq("T1.2 mac (SRAM only)", got_mac, exp_mac);
        end

        //----------------------------------------------------------
        // T2 — PCM-only MAC
        //----------------------------------------------------------
        $display("");
        $display("T2  PCM-only MAC (25 lanes all PCM-hit conv2, drift off)");
        clear_all_lanes;
        layer_id = 3'd1;
        find_first_n_pcm_hits_conv2(25);
        if (hit_count_out < 25) begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T2.setup");
        end else begin
            for (i = 0; i < 25; i = i + 1) begin
                set_lane(i, hit_origs[i], i - 12);
            end
            #1;
            if (pcm_hit_dbg === 25'h1FFFFFF && sram_hit_dbg === 25'd0) begin
                pass_count = pass_count + 1;
                $display("  [PASS] T2.1 hit mask: all pcm, no sram");
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T2.1 sram=%h pcm=%h", sram_hit_dbg, pcm_hit_dbg);
            end
            exp_mac = compute_expected_total();
            run_mac_op(got_mac);
            expect_mac_eq("T2.2 mac (PCM only)", got_mac, exp_mac);
        end

        //----------------------------------------------------------
        // T3 — Hybrid SRAM+PCM mixed
        //----------------------------------------------------------
        $display("");
        $display("T3  Hybrid SRAM+PCM mixed (conv2 origs 0-24)");
        clear_all_lanes;
        layer_id = 3'd1;
        for (i = 0; i < 25; i = i + 1) set_lane(i, i, i - 12);
        #1;
        exp_sram = compute_expected_sram_partial();
        exp_pcm  = compute_expected_pcm_partial();
        exp_mac  = exp_sram + exp_pcm;
        run_mac_op(got_mac);
        expect_mac_eq("T3.1 mac (hybrid)", got_mac, exp_mac);
        $display("         exp_sram=%0d exp_pcm=%0d exp_total=%0d",
                 exp_sram, exp_pcm, exp_mac);

        //----------------------------------------------------------
        // T4 — Mutex + XOR completeness
        //----------------------------------------------------------
        $display("");
        $display("T4  SRAM/PCM mutex + XOR completeness");
        // Using T3's setup (all 25 lanes valid in conv2 0..24)
        valid_mask = 25'h1FFFFFF;
        check_mutex_xor("T4.1 conv2 origs 0-24 valid", valid_mask);

        // Stress: some lanes intentionally out-of-depth
        clear_all_lanes;
        layer_id = 3'd1;
        for (i = 0; i < 20; i = i + 1) set_lane(i, i, i - 10);
        for (i = 20; i < 25; i = i + 1) set_lane(i, 2400, i - 12);
        #1;
        valid_mask = 25'h00FFFFF;
        check_mutex_xor("T4.2 lanes 0-19 valid", valid_mask);
        if (sram_hit_dbg[24:20] === 5'd0 && pcm_hit_dbg[24:20] === 5'd0) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T4.3 out-of-depth lanes 20-24 both hits=0");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T4.3 OOD lanes sram=%b pcm=%b",
                     sram_hit_dbg[24:20], pcm_hit_dbg[24:20]);
        end

        //----------------------------------------------------------
        // T5 — Latency
        //----------------------------------------------------------
        $display("");
        $display("T5  Latency check (start -> result_valid)");
        clear_all_lanes;
        layer_id = 3'd1;
        for (i = 0; i < 25; i = i + 1) set_lane(i, i, i - 12);
        #1;
        begin: latency_check
            integer cycles;
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            cycles = 0;
            while (!result_valid && cycles < PCM_LATENCY + 3) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (result_valid && cycles >= PCM_LATENCY - 2 && cycles <= PCM_LATENCY + 1) begin
                pass_count = pass_count + 1;
                $display("  [PASS] T5.1 result_valid at ~PCM_LATENCY=%0d (waited %0d)",
                         PCM_LATENCY, cycles);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T5.1 cycles=%0d (expected ~%0d)",
                         cycles, PCM_LATENCY);
            end
        end

        //----------------------------------------------------------
        // T6 — cfg_valid gating
        //----------------------------------------------------------
        $display("");
        $display("T6  cfg_valid gating");
        rst_n = 0;
        @(negedge clk); @(negedge clk);
        rst_n = 1;
        // cfg_mem is preserved across reset
        @(negedge clk);
        if (cfg_valid_dbg === 1'b0) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T6.1 cfg_valid=0 after reset");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T6.1 cfg_valid=%b", cfg_valid_dbg);
        end

        // Try MAC without commit
        clear_all_lanes;
        layer_id = 3'd1;
        for (i = 0; i < 25; i = i + 1) set_lane(i, i, i - 12);
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        begin: gating_check
            integer waited;
            waited = 0;
            while (waited < PCM_LATENCY + 5 && !result_valid) begin
                @(negedge clk);
                waited = waited + 1;
            end
            if (!result_valid) begin
                pass_count = pass_count + 1;
                $display("  [PASS] T6.2 no result_valid in %0d cycles (gated)",
                         PCM_LATENCY + 5);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T6.2 result_valid fired without commit");
            end
        end

        // Commit now
        do_cfg_write(6'h20, 32'h0000_0002);
        if (cfg_valid_dbg === 1'b1) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T6.3 cfg_valid=1 after commit");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T6.3 cfg_valid=%b", cfg_valid_dbg);
        end

        // Re-run MAC, should work
        clear_all_lanes;
        layer_id = 3'd1;
        for (i = 0; i < 25; i = i + 1) set_lane(i, i, i - 12);
        #1;
        exp_mac = compute_expected_total();
        run_mac_op(got_mac);
        expect_mac_eq("T6.4 MAC works after commit", got_mac, exp_mac);

        //----------------------------------------------------------
        // T7 — enable_drift=1 sanity
        //----------------------------------------------------------
        $display("");
        $display("T7  enable_drift=1 sanity (non-X)");
        clear_all_lanes;
        layer_id = 3'd1;
        find_first_n_pcm_hits_conv2(10);
        for (i = 0; i < 10; i = i + 1) set_lane(i, hit_origs[i], i + 1);
        #1;
        run_mac_op(got_mac);
        $display("         baseline (drift off): %0d", got_mac);

        do_cfg_write(6'h21, 32'h0000_0400);   // drift_t = 1024
        do_cfg_write(6'h20, 32'h0000_0003);   // enable_drift=1, commit again

        if (enable_drift_dbg === 1'b1 && drift_t_dbg === 16'd1024) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T7.1 enable_drift=1, drift_t=1024");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T7.1 drift=%b t=%0d", enable_drift_dbg, drift_t_dbg);
        end

        run_mac_op(got_mac);
        if (^got_mac === 1'bx) begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T7.2 drift on result is X");
        end else begin
            pass_count = pass_count + 1;
            $display("  [PASS] T7.2 drift on -> mac=%0d (defined)", got_mac);
        end

        // Drift off for T8
        do_cfg_write(6'h20, 32'h0000_0000);

        //----------------------------------------------------------
        // T8 — Two sequential MAC ops
        //----------------------------------------------------------
        $display("");
        $display("T8  Two sequential MAC ops");
        clear_all_lanes;
        layer_id = 3'd1;
        for (i = 0; i < 25; i = i + 1) set_lane(i, i, i - 12);
        #1;
        exp_mac = compute_expected_total();
        run_mac_op(got_mac);
        expect_mac_eq("T8.1 op1 conv2 origs 0-24", got_mac, exp_mac);

        clear_all_lanes;
        layer_id = 3'd1;
        for (i = 0; i < 25; i = i + 1) set_lane(i, 100 + i, i - 12);
        #1;
        exp_mac = compute_expected_total();
        run_mac_op(got_mac);
        expect_mac_eq("T8.2 op2 conv2 origs 100-124", got_mac, exp_mac);

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
        #10000000;
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule
