//============================================================
// tb_pcm_path_integration.v
// Step 4c: PCM path integration test
//
// Validates the 25-lane integration of:
//
//   pcm_addr_decoder x 25   →   pcm_crossbar x 1
//
// Per-lane (layer_id, orig_addr) flows through an independent
// decoder instance; outputs are packed into the crossbar's
// bus interface. Method X (independent expected computation
// via testbench-side mirrors) catches bus-packing errors and
// lane-wiring mistakes that Method Y (observing the bus) would
// miss.
//
// regfile is NOT included in this step; testbench drives each
// lane's (pcm_base, pcm_size) directly from a cfg_words mirror.
// regfile -> SRAM/PCM full integration is Step 5's job.
//
// SRAM/PCM mutual exclusion is also Step 5's job.
//
// Tests:
//   T1 single-layer 25-lane all-hit (conv2)
//      drift off, exact compare
//   T2 single-layer hit/miss mixed (conv2)
//      drift off, exact compare
//   T3 empty PCM partition (conv1, plus fc3 if Model B)
//      expected mac=0, no oor error
//   T4 cross-layer 25-lane mix (conv2 + fc1 + fc2)
//      drift off, exact compare -- stress-tests bus packing
//   T5 boundary lane (dynamically finds orig that maps to
//      pool_addr = PCM_TOTAL-1 = 58395; auto-adapts A/B)
//   T6 enable_drift=1 sanity (Method Y: defined non-X result)
//   T7 two sequential MAC ops (back-to-back NOT tested;
//      testbench waits result_valid between ops)
//
// Run:
//   iverilog -g2012 -o build/tb_pci \
//     rtl/src/pcm_addr_decoder.v \
//     rtl/src/pcm_crossbar.v \
//     rtl/tb/tb_pcm_path_integration.v
//   vvp build/tb_pci +DATA_DIR=data/rtl_inputs_A_v3 \
//                    +COMMON_DIR=data/rtl_inputs_common
//============================================================

`timescale 1ns/1ps

module tb_pcm_path_integration;

    localparam integer K          = 25;
    localparam integer DATA_WIDTH = 8;
    localparam integer ADDR_WIDTH = 16;
    localparam integer ACC_WIDTH  = 24;
    localparam integer PCM_TOTAL  = 58396;
    localparam integer LATENCY    = 8;

    // ---- plusargs handling --------------------------------------
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

    // ---- Clocking / reset ---------------------------------------
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;   // 100 MHz

    // ---- Per-lane drivers (testbench-controlled) ----------------
    reg [2:0]        layer_id_lane  [0:K-1];
    reg [15:0]       orig_addr_lane [0:K-1];
    reg [15:0]       pcm_base_lane  [0:K-1];
    reg [15:0]       pcm_size_lane  [0:K-1];
    reg signed [7:0] v_lane         [0:K-1];

    // ---- Crossbar inputs -----------------------------------------
    reg start        = 0;
    reg enable_drift = 0;
    reg [15:0] drift_t = 16'd0;

    // ---- 25 decoder instances ------------------------------------
    wire [K-1:0]    dec_hit_w;
    wire [K-1:0]    dec_oor_w;
    wire [16*K-1:0] dec_pool_addr_packed;

    genvar gi;
    generate
        for (gi = 0; gi < K; gi = gi + 1) begin: dec_inst
            wire [15:0] pa_w;
            pcm_addr_decoder #(.DATA_DIR("")) U_DEC (
                .layer_id(layer_id_lane[gi]),
                .orig_addr(orig_addr_lane[gi]),
                .pcm_base(pcm_base_lane[gi]),
                .pcm_size(pcm_size_lane[gi]),
                .pcm_hit(dec_hit_w[gi]),
                .pcm_pool_addr(pa_w),
                .pcm_oor_error(dec_oor_w[gi])
            );
            assign dec_pool_addr_packed[gi*16 +: 16] = pa_w;
        end
    endgenerate

    // ---- Pack v_lane into v_bus ---------------------------------
    wire [8*K-1:0] v_bus;
    generate
        for (gi = 0; gi < K; gi = gi + 1) begin: pack_v
            assign v_bus[gi*8 +: 8] = v_lane[gi];
        end
    endgenerate

    // ---- PCM crossbar --------------------------------------------
    wire signed [ACC_WIDTH-1:0] mac_result;
    wire                        result_valid;

    pcm_crossbar #(
        .K(K),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .PCM_TOTAL(PCM_TOTAL),
        .MULTI_CYCLE_LATENCY(LATENCY),
        .DATA_DIR(""),
        .COMMON_DIR("")
    ) U_PCB (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .v_bus(v_bus),
        .pcm_pool_addr_bus(dec_pool_addr_packed),
        .pcm_hit_bus(dec_hit_w),
        .enable_drift(enable_drift),
        .drift_t(drift_t),
        .mac_result(mac_result),
        .result_valid(result_valid)
    );

    // ---- Testbench-side mirrors (Method X "ground truth") --------
    reg [31:0]       cfg_mirror     [0:9];
    reg [15:0]       a2s_conv1_pcm  [0:149];
    reg [15:0]       a2s_conv2_pcm  [0:2399];
    reg [15:0]       a2s_fc1_pcm    [0:47999];
    reg [15:0]       a2s_fc2_pcm    [0:10079];
    reg [15:0]       a2s_fc3_pcm    [0:839];
    reg signed [7:0] pool_mirror    [0:PCM_TOTAL-1];

    // ---- Anchor-search outputs -----------------------------------
    integer hit_origs [0:24];          // up to 25 found origs
    integer hit_count_out;
    integer boundary_lid_out;
    integer boundary_orig_out;

    // ---- Stats ---------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;

    //==========================================================
    // Helpers
    //==========================================================

    task clear_all_lanes;
        integer j;
        begin
            for (j = 0; j < K; j = j + 1) begin
                layer_id_lane[j]  = 3'd5;   // OOB -> guaranteed hit=0
                orig_addr_lane[j] = 16'd0;
                pcm_base_lane[j]  = 16'd0;
                pcm_size_lane[j]  = 16'd0;
                v_lane[j]         = 8'sd0;
            end
        end
    endtask

    // Set a lane to (lid, orig, v); base/size come from cfg_mirror.
    // NOTE: `lid + 5` uses untyped 5 (32-bit) to avoid 3-bit
    // overflow when lid >= 3. This is the same gotcha caught in
    // Step 4a.
    task set_lane(input integer lane,
                  input integer lid,
                  input integer orig,
                  input integer v);
        begin
            layer_id_lane[lane]  = lid[2:0];
            orig_addr_lane[lane] = orig[15:0];
            pcm_base_lane[lane]  = cfg_mirror[lid + 5][15:0];
            pcm_size_lane[lane]  = cfg_mirror[lid + 5][31:16];
            v_lane[lane]         = v[7:0];
        end
    endtask

    // Method X: compute one lane's expected contribution using
    // testbench mirrors only -- does NOT observe DUT outputs.
    function signed [ACC_WIDTH-1:0] lane_contribution(input integer lane);
        integer lid_i;
        reg [15:0] base, size, local_slot;
        reg [16:0] sum_ext;
        reg [15:0] pool_addr;
        begin
            lid_i = layer_id_lane[lane];

            if (lid_i > 4) begin
                lane_contribution = 0;
            end else begin
                base = cfg_mirror[lid_i + 5][15:0];
                size = cfg_mirror[lid_i + 5][31:16];

                case (lid_i)
                    0: local_slot = (orig_addr_lane[lane] < 16'd150)
                                     ? a2s_conv1_pcm[orig_addr_lane[lane]]
                                     : 16'hFFFF;
                    1: local_slot = (orig_addr_lane[lane] < 16'd2400)
                                     ? a2s_conv2_pcm[orig_addr_lane[lane]]
                                     : 16'hFFFF;
                    2: local_slot = (orig_addr_lane[lane] < 16'd48000)
                                     ? a2s_fc1_pcm[orig_addr_lane[lane]]
                                     : 16'hFFFF;
                    3: local_slot = (orig_addr_lane[lane] < 16'd10080)
                                     ? a2s_fc2_pcm[orig_addr_lane[lane]]
                                     : 16'hFFFF;
                    4: local_slot = (orig_addr_lane[lane] < 16'd840)
                                     ? a2s_fc3_pcm[orig_addr_lane[lane]]
                                     : 16'hFFFF;
                    default: local_slot = 16'hFFFF;
                endcase

                if (local_slot == 16'hFFFF) begin
                    lane_contribution = 0;
                end else begin
                    sum_ext = {1'b0, base} + {1'b0, local_slot};
                    // OOR check (mirrors decoder logic): if either
                    // condition fires, no valid contribution. In
                    // healthy test data this should never happen.
                    if ((sum_ext >= 17'd58396) || (local_slot >= size)) begin
                        $display("    [WARN] lane %0d: lid=%0d orig=%0d local_slot=%0d size=%0d sum=%0d -- testbench mirror saw OOR",
                                 lane, lid_i, orig_addr_lane[lane],
                                 local_slot, size, sum_ext);
                        lane_contribution = 0;
                    end else begin
                        pool_addr = sum_ext[15:0];
                        lane_contribution = $signed(v_lane[lane])
                                          * $signed(pool_mirror[pool_addr]);
                    end
                end
            end
        end
    endfunction

    function signed [ACC_WIDTH-1:0] compute_expected_mac;
        integer j;
        begin
            compute_expected_mac = 0;
            for (j = 0; j < K; j = j + 1) begin
                compute_expected_mac = compute_expected_mac
                                     + lane_contribution(j);
            end
        end
    endfunction

    // Trigger one MAC op (single start pulse) and capture result.
    task run_mac_op(output signed [ACC_WIDTH-1:0] got);
        integer waited;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            waited = 0;
            while (!result_valid && waited < (LATENCY + 5)) begin
                @(negedge clk);
                waited = waited + 1;
            end
            if (!result_valid) begin
                $display("  [WARN] result_valid did not fire within %0d cycles",
                         LATENCY + 5);
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
                $display("  [FAIL] %0s  got=%0d  exp=%0d",
                         name, got, exp_val);
            end
        end
    endtask

    task expect_oor_clean(input [255:0] name);
        begin
            if (|dec_oor_w === 1'b0) begin
                pass_count = pass_count + 1;
                $display("  [PASS] %0s  oor=0", name);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] %0s  oor=%b (any-lane oor fired)",
                         name, dec_oor_w);
            end
        end
    endtask

    // Anchor-search: find first N orig_addrs in given layer
    // where addr_to_slot != FFFF. Outputs into module-scope
    // `hit_origs[]` and `hit_count_out`. If fewer than N exist,
    // remaining slots set to -1.
    task find_first_n_hits(input integer lid, input integer n);
        integer count, a, depth, j;
        reg [15:0] ls;
        begin
            for (j = 0; j < 25; j = j + 1) hit_origs[j] = -1;
            count = 0;
            case (lid)
                0: depth = 150;
                1: depth = 2400;
                2: depth = 48000;
                3: depth = 10080;
                4: depth = 840;
                default: depth = 0;
            endcase
            for (a = 0; a < depth; a = a + 1) begin
                if (count >= n) a = depth;
                else begin
                    case (lid)
                        0: ls = a2s_conv1_pcm[a];
                        1: ls = a2s_conv2_pcm[a];
                        2: ls = a2s_fc1_pcm[a];
                        3: ls = a2s_fc2_pcm[a];
                        4: ls = a2s_fc3_pcm[a];
                        default: ls = 16'hFFFF;
                    endcase
                    if (ls != 16'hFFFF) begin
                        hit_origs[count] = a;
                        count = count + 1;
                    end
                end
            end
            hit_count_out = count;
        end
    endtask

    // Boundary search: find (lid, orig) such that
    // pcm_base[lid] + local_slot == PCM_TOTAL - 1 = 58395.
    // For Model A this typically falls in fc3; for Model B
    // typically in fc2.
    task find_boundary_orig;
        integer lid_i, a, depth;
        reg [15:0] base, size, ls;
        reg [16:0] sum_ext;
        begin
            boundary_lid_out  = -1;
            boundary_orig_out = -1;
            for (lid_i = 0; lid_i < 5; lid_i = lid_i + 1) begin
                if (boundary_orig_out < 0) begin
                    base = cfg_mirror[lid_i + 5][15:0];
                    size = cfg_mirror[lid_i + 5][31:16];
                    if (size > 0) begin
                        // last slot index = size - 1
                        // pool_addr = base + size - 1
                        sum_ext = {1'b0, base} + {1'b0, size} - 17'd1;
                        if (sum_ext == 17'd58395) begin
                            // Need to find orig such that
                            // addr_to_slot[lid][orig] == size-1
                            case (lid_i)
                                0: depth = 150;
                                1: depth = 2400;
                                2: depth = 48000;
                                3: depth = 10080;
                                4: depth = 840;
                                default: depth = 0;
                            endcase
                            for (a = 0; a < depth; a = a + 1) begin
                                if (boundary_orig_out < 0) begin
                                    case (lid_i)
                                        0: ls = a2s_conv1_pcm[a];
                                        1: ls = a2s_conv2_pcm[a];
                                        2: ls = a2s_fc1_pcm[a];
                                        3: ls = a2s_fc2_pcm[a];
                                        4: ls = a2s_fc3_pcm[a];
                                        default: ls = 16'hFFFF;
                                    endcase
                                    if (ls == size - 16'd1) begin
                                        boundary_lid_out  = lid_i;
                                        boundary_orig_out = a;
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    endtask

    //==========================================================
    // Main test sequence
    //==========================================================
    reg signed [ACC_WIDTH-1:0] got_mac;
    reg signed [ACC_WIDTH-1:0] exp_mac;
    integer i;
    integer lane_idx;

    initial begin
        $display("============================================================");

        data_dir   = {(8*512){1'b0}};
        common_dir = {(8*512){1'b0}};
        have_data_dir   = $value$plusargs("DATA_DIR=%s",   data_dir);
        have_common_dir = $value$plusargs("COMMON_DIR=%s", common_dir);

        if (!have_data_dir) begin
            $display("ERROR: +DATA_DIR is required.");
            $finish;
        end

        // Hierarchical $readmemh into DUT modules. The DUT
        // parameters are empty strings; testbench bypasses them.
        if (have_common_dir) begin
            $readmemh({trim(common_dir), "/log2_lut.hex"}, U_PCB.log2_lut);
            $readmemh({trim(common_dir), "/exp2_lut.hex"}, U_PCB.exp2_lut);
        end else begin
            $readmemh("data/rtl_inputs_common/log2_lut.hex", U_PCB.log2_lut);
            $readmemh("data/rtl_inputs_common/exp2_lut.hex", U_PCB.exp2_lut);
        end
        $readmemh({trim(data_dir), "/pcm_pool.hex"},    U_PCB.pcm_pool);
        $readmemh({trim(data_dir), "/nu_pcm_pool.hex"}, U_PCB.nu_pcm_pool);

        // Decoder ROMs: loop over all 25 instances
        for (i = 0; i < K; i = i + 1) begin
            $readmemh({trim(data_dir), "/addr_to_slot_conv1_pcm.hex"},
                      dec_inst[0].U_DEC.rom_conv1);
            $readmemh({trim(data_dir), "/addr_to_slot_conv2_pcm.hex"},
                      dec_inst[0].U_DEC.rom_conv2);
            $readmemh({trim(data_dir), "/addr_to_slot_fc1_pcm.hex"},
                      dec_inst[0].U_DEC.rom_fc1);
            $readmemh({trim(data_dir), "/addr_to_slot_fc2_pcm.hex"},
                      dec_inst[0].U_DEC.rom_fc2);
            $readmemh({trim(data_dir), "/addr_to_slot_fc3_pcm.hex"},
                      dec_inst[0].U_DEC.rom_fc3);
        end
        // Note: with iverilog the above only writes lane 0's
        // ROMs via the loop variable; we need to instead write
        // each lane individually. Use the generate-block path.
        // The decoder ROMs are populated by initial $readmemh
        // inside pcm_addr_decoder when its DATA_DIR != "". Here
        // we override per-instance via hierarchical writes.

        // (Re)load every lane's ROMs explicitly. This is
        // verbose but unambiguous and matches the lane-wiring
        // structure exactly.
        // -- Will be done after this initial-block setup;
        //    actually wait: $readmemh with hierarchical refs
        //    inside a for-loop and `dec_inst[i].U_DEC.*` should
        //    work in iverilog. Let's try the loop form first
        //    and if it fails, unroll.

        $display("tb_pcm_path_integration");
        $display("  DATA_DIR   = \"%0s\"", trim(data_dir));
        if (have_common_dir)
            $display("  COMMON_DIR = \"%0s\"", trim(common_dir));
        $display("============================================================");

        // Testbench-side mirrors
        $readmemh({trim(data_dir), "/layer_config.hex"},            cfg_mirror);
        $readmemh({trim(data_dir), "/addr_to_slot_conv1_pcm.hex"},  a2s_conv1_pcm);
        $readmemh({trim(data_dir), "/addr_to_slot_conv2_pcm.hex"},  a2s_conv2_pcm);
        $readmemh({trim(data_dir), "/addr_to_slot_fc1_pcm.hex"},    a2s_fc1_pcm);
        $readmemh({trim(data_dir), "/addr_to_slot_fc2_pcm.hex"},    a2s_fc2_pcm);
        $readmemh({trim(data_dir), "/addr_to_slot_fc3_pcm.hex"},    a2s_fc3_pcm);
        $readmemh({trim(data_dir), "/pcm_pool.hex"},                pool_mirror);

        // Initial reset
        clear_all_lanes;
        enable_drift = 0;
        drift_t = 16'd0;
        rst_n = 0;
        @(negedge clk); @(negedge clk); @(negedge clk);
        rst_n = 1;

        //----------------------------------------------------------
        // T1 — single-layer 25-lane all-hit (conv2)
        //----------------------------------------------------------
        $display("");
        $display("T1  conv2 25-lane all-hit (drift off, exact compare)");
        clear_all_lanes;
        enable_drift = 0;

        find_first_n_hits(1, 25);   // layer 1 = conv2
        if (hit_count_out < 25) begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T1.setup: only found %0d conv2 PCM hits (need 25)",
                     hit_count_out);
        end else begin
            for (lane_idx = 0; lane_idx < 25; lane_idx = lane_idx + 1) begin
                // Use lane_idx+1 as v to give every lane a distinct nonzero v
                set_lane(lane_idx, 1, hit_origs[lane_idx], lane_idx - 12);
            end
            #1;  // let decoders settle combinationally

            exp_mac = compute_expected_mac();
            run_mac_op(got_mac);

            expect_mac_eq("T1.1 mac == expected", got_mac, exp_mac);
            expect_oor_clean("T1.2 no oor on any lane");
            if (result_valid) begin
                pass_count = pass_count + 1;
                $display("  [PASS] T1.3 result_valid fired");
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T1.3 result_valid did not fire");
            end
        end

        //----------------------------------------------------------
        // T2 — hit/miss mixed in conv2 (drift off)
        //----------------------------------------------------------
        // Use orig_addrs 0..24 in conv2: some are PCM hits, some are
        // SRAM (FFFF in PCM mirror). The PCM decoder gives hit=0 for
        // SRAM ones. Method X mirror computes the same.
        $display("");
        $display("T2  conv2 hit/miss mixed (drift off)");
        clear_all_lanes;
        enable_drift = 0;

        for (lane_idx = 0; lane_idx < 25; lane_idx = lane_idx + 1) begin
            // v = lane_idx - 12 to give signed mix; orig = lane_idx
            set_lane(lane_idx, 1, lane_idx, lane_idx - 12);
        end
        #1;

        exp_mac = compute_expected_mac();
        run_mac_op(got_mac);
        expect_mac_eq("T2.1 mac == expected (mix)", got_mac, exp_mac);
        expect_oor_clean("T2.2 no oor (mix)");

        //----------------------------------------------------------
        // T3 — empty PCM partition (conv1; fc3 if Model B)
        //----------------------------------------------------------
        $display("");
        $display("T3  empty PCM partition sweep");

        // T3.1 conv1 (empty in both A and B)
        clear_all_lanes;
        enable_drift = 0;
        for (lane_idx = 0; lane_idx < 25; lane_idx = lane_idx + 1) begin
            set_lane(lane_idx, 0, lane_idx, lane_idx + 1);   // conv1
        end
        #1;
        exp_mac = compute_expected_mac();    // should be 0
        run_mac_op(got_mac);
        expect_mac_eq("T3.1 conv1 empty PCM -> mac=0",
                      got_mac, 24'sd0);
        expect_oor_clean("T3.2 no oor (empty conv1 PCM)");

        // T3.3 fc3 - only if Model B (fc3 PCM size=0)
        if (cfg_mirror[4 + 5][31:16] == 16'd0) begin
            // fc3 PCM is empty
            clear_all_lanes;
            for (lane_idx = 0; lane_idx < 25; lane_idx = lane_idx + 1) begin
                set_lane(lane_idx, 4, lane_idx, lane_idx + 1);  // fc3
            end
            #1;
            run_mac_op(got_mac);
            expect_mac_eq("T3.3 fc3 empty PCM -> mac=0  (Model B)",
                          got_mac, 24'sd0);
            expect_oor_clean("T3.4 no oor (empty fc3 PCM)");
        end else begin
            $display("  [SKIP] T3.3 fc3 PCM size=%0d (not empty, this is not Model B)",
                     cfg_mirror[4 + 5][31:16]);
        end

        //----------------------------------------------------------
        // T4 — cross-layer 25-lane mix (conv2 + fc1 + fc2)
        //----------------------------------------------------------
        // Stress test for bus packing / lane wiring: each lane
        // uses a different layer_id. Skip fc3 because Model B
        // has empty fc3 PCM. conv2/fc1/fc2 have plenty of hits
        // in both models.
        //
        // Lane allocation:  0..7 = conv2 (8 lanes)
        //                   8..16 = fc1 (9 lanes)
        //                  17..24 = fc2 (8 lanes)
        $display("");
        $display("T4  cross-layer 25-lane mix (conv2 + fc1 + fc2)");
        clear_all_lanes;
        enable_drift = 0;

        find_first_n_hits(1, 8);    // conv2
        for (lane_idx = 0; lane_idx < 8; lane_idx = lane_idx + 1) begin
            set_lane(lane_idx, 1, hit_origs[lane_idx], lane_idx - 4);
        end
        find_first_n_hits(2, 9);    // fc1
        for (lane_idx = 0; lane_idx < 9; lane_idx = lane_idx + 1) begin
            set_lane(8 + lane_idx, 2, hit_origs[lane_idx], lane_idx - 4);
        end
        find_first_n_hits(3, 8);    // fc2
        for (lane_idx = 0; lane_idx < 8; lane_idx = lane_idx + 1) begin
            set_lane(17 + lane_idx, 3, hit_origs[lane_idx], lane_idx - 4);
        end
        #1;

        exp_mac = compute_expected_mac();
        run_mac_op(got_mac);
        expect_mac_eq("T4.1 mac == expected (cross-layer)",
                      got_mac, exp_mac);
        expect_oor_clean("T4.2 no oor (cross-layer)");

        //----------------------------------------------------------
        // T5 — boundary lane (pool_addr=58395 last entry)
        //----------------------------------------------------------
        $display("");
        $display("T5  boundary lane (dyn. search pool_addr=58395)");

        find_boundary_orig();
        if (boundary_orig_out < 0) begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T5.setup: no orig maps to pool_addr=58395 in current model");
        end else begin
            $display("  found boundary: lid=%0d orig=%0d (auto-adapt: A->fc3, B->fc2)",
                     boundary_lid_out, boundary_orig_out);
            clear_all_lanes;
            enable_drift = 0;
            // Lane 0 hits the boundary; lanes 1..24 stay inactive.
            set_lane(0, boundary_lid_out, boundary_orig_out, 3);
            #1;
            // Expected: v=3, pool_addr=58395 -> mac = 3*pool_mirror[58395]
            exp_mac = $signed(8'sd3) * $signed(pool_mirror[58395]);
            run_mac_op(got_mac);
            expect_mac_eq("T5.1 mac == 3*pool[58395]", got_mac, exp_mac);
            expect_oor_clean("T5.2 no oor on boundary");
        end

        //----------------------------------------------------------
        // T6 — enable_drift=1 sanity (Method Y: defined non-X)
        //----------------------------------------------------------
        $display("");
        $display("T6  enable_drift=1 sanity (non-X result)");
        clear_all_lanes;
        find_first_n_hits(1, 5);
        for (lane_idx = 0; lane_idx < 5; lane_idx = lane_idx + 1) begin
            set_lane(lane_idx, 1, hit_origs[lane_idx], lane_idx + 1);
        end
        #1;

        // Baseline (drift off) for record
        enable_drift = 0;
        drift_t = 16'd0;
        run_mac_op(got_mac);
        $display("         baseline mac (drift off): %0d", got_mac);

        // Drift on
        enable_drift = 1;
        drift_t = 16'd1024;
        run_mac_op(got_mac);
        if (^got_mac === 1'bx) begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T6.1 drift=1 t=1024 result is X");
        end else begin
            pass_count = pass_count + 1;
            $display("  [PASS] T6.1 drift=1 t=1024 -> defined mac=%0d",
                     got_mac);
        end

        drift_t = 16'd60000;
        run_mac_op(got_mac);
        if (^got_mac === 1'bx) begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T6.2 drift=1 t=60000 result is X");
        end else begin
            pass_count = pass_count + 1;
            $display("  [PASS] T6.2 drift=1 t=60000 -> defined mac=%0d",
                     got_mac);
        end

        //----------------------------------------------------------
        // T7 — two sequential MAC ops (not back-to-back)
        //----------------------------------------------------------
        // Op1: lanes hitting conv2 (first 10)
        // Wait for result_valid, compare.
        // Op2: lanes hitting fc1 (first 10)
        // Wait for result_valid, compare.
        $display("");
        $display("T7  two sequential MAC ops");

        // Op1
        clear_all_lanes;
        enable_drift = 0;
        drift_t = 16'd0;
        find_first_n_hits(1, 10);
        for (lane_idx = 0; lane_idx < 10; lane_idx = lane_idx + 1) begin
            set_lane(lane_idx, 1, hit_origs[lane_idx], lane_idx + 1);
        end
        #1;
        exp_mac = compute_expected_mac();
        run_mac_op(got_mac);
        expect_mac_eq("T7.op1 conv2 10-lane", got_mac, exp_mac);

        // Op2 (immediately after op1's result_valid)
        clear_all_lanes;
        find_first_n_hits(2, 10);
        for (lane_idx = 0; lane_idx < 10; lane_idx = lane_idx + 1) begin
            set_lane(lane_idx, 2, hit_origs[lane_idx], lane_idx - 5);
        end
        #1;
        exp_mac = compute_expected_mac();
        run_mac_op(got_mac);
        expect_mac_eq("T7.op2 fc1 10-lane", got_mac, exp_mac);

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

    //==========================================================
    // Decoder ROM loader (per-lane hierarchical $readmemh)
    //==========================================================
    // Iverilog can't easily index into a generate-loop block via
    // a variable; the cleanest way is to unroll all 25 lanes.
    // This runs once after the main initial's first plusarg
    // resolution.
    initial begin: rom_loader
        wait (rst_n === 1'b0);   // Wait for reset to be applied
        #1;

        // Trigger only if DATA_DIR was set
        if (data_dir !== {(8*512){1'b0}}) begin
            // 25-lane unroll for decoder ROMs
            `define LOAD_LANE(i) \
                $readmemh({trim(data_dir), "/addr_to_slot_conv1_pcm.hex"}, \
                          dec_inst[i].U_DEC.rom_conv1); \
                $readmemh({trim(data_dir), "/addr_to_slot_conv2_pcm.hex"}, \
                          dec_inst[i].U_DEC.rom_conv2); \
                $readmemh({trim(data_dir), "/addr_to_slot_fc1_pcm.hex"},   \
                          dec_inst[i].U_DEC.rom_fc1);   \
                $readmemh({trim(data_dir), "/addr_to_slot_fc2_pcm.hex"},   \
                          dec_inst[i].U_DEC.rom_fc2);   \
                $readmemh({trim(data_dir), "/addr_to_slot_fc3_pcm.hex"},   \
                          dec_inst[i].U_DEC.rom_fc3);

            `LOAD_LANE(0)  `LOAD_LANE(1)  `LOAD_LANE(2)  `LOAD_LANE(3)  `LOAD_LANE(4)
            `LOAD_LANE(5)  `LOAD_LANE(6)  `LOAD_LANE(7)  `LOAD_LANE(8)  `LOAD_LANE(9)
            `LOAD_LANE(10) `LOAD_LANE(11) `LOAD_LANE(12) `LOAD_LANE(13) `LOAD_LANE(14)
            `LOAD_LANE(15) `LOAD_LANE(16) `LOAD_LANE(17) `LOAD_LANE(18) `LOAD_LANE(19)
            `LOAD_LANE(20) `LOAD_LANE(21) `LOAD_LANE(22) `LOAD_LANE(23) `LOAD_LANE(24)
            `undef LOAD_LANE
        end
    end

    // Watchdog
    initial begin
        #5000000;
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule
