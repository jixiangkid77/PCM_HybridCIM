//============================================================
// tb_pcm_addr_decoder.v
// Unit tests for pcm_addr_decoder.v (Step 4a)
//
// Mirrors tb_sram_addr_decoder.v structure, adapted for the
// PCM side. Key differences:
//   - PCM_TOTAL = 58396 (vs SRAM 3074)
//   - cfg_words indices 5..9 hold PCM {size, base}
//   - T7 is the PCM-specific "empty partition" sweep test
//   - Expected sweep totals: hits=58396, misses=3074 (the
//     inverse of the SRAM-side totals)
//
// Run:
//   iverilog -g2012 -o build/tb_pad \
//     rtl/src/pcm_addr_decoder.v rtl/tb/tb_pcm_addr_decoder.v
//   vvp build/tb_pad +DATA_DIR=data/rtl_inputs_A_v3
//   vvp build/tb_pad +DATA_DIR=data/rtl_inputs_B_v3
//
// Tests:
//   T0. Default-FFFF / OOB (no DATA_DIR needed)
//   T1. Normal hit (model-agnostic via discovered anchors)
//   T2. Sentinel miss (model-agnostic)
//   T3. size_violation (force pcm_size=0 with valid slot)
//   T4. global_violation including 16-bit wrap-around
//   T5. layer_id out-of-range silent miss
//   T6. orig_addr past per-layer depth silent miss
//   T7. Empty PCM partition sweep -- the key PCM-specific test:
//         conv1 PCM is empty in BOTH Model A and Model B
//         fc3   PCM is empty in Model B only
//       Expected: hits=0, errors=0, all orig_addrs miss cleanly.
//   T8. End-to-end sweep over all 5 layers (model-agnostic via
//       cfg_words), expecting hits=58396, misses=3074, errors=0.
//============================================================

`timescale 1ns/1ps

module tb_pcm_addr_decoder;

    localparam integer PCM_TOTAL          = 58396;
    localparam integer EXPECT_TOTAL_HITS  = 58396;  // PCM perspective
    localparam integer EXPECT_TOTAL_MISS  = 3074;

    // ---- plusargs handling --------------------------------------
    reg [8*512-1:0] data_dir;
    integer         have_data_dir;

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

    // ---- DUT signals --------------------------------------------
    reg  [2:0]  layer_id;
    reg  [15:0] orig_addr;
    reg  [15:0] pcm_base;
    reg  [15:0] pcm_size;
    wire        pcm_hit;
    wire [15:0] pcm_pool_addr;
    wire        pcm_oor_error;

    // ---- Model-agnostic config loaded from layer_config.hex -----
    // 10-line {size[31:16], base[15:0]} format. PCM partitions
    // are entries 5..9 (conv1..fc3).
    reg [31:0] cfg_words [0:9];

    function [15:0] pcm_base_of(input [2:0] lid);
        // Use untyped literal 5 (32-bit) to avoid 3-bit overflow
        // when lid >= 3 (e.g., lid=3 + 3'd5 wraps to 3'd0 in
        // 3-bit width, returning the wrong cfg_words entry).
        pcm_base_of = cfg_words[lid + 5][15:0];
    endfunction
    function [15:0] pcm_size_of(input [2:0] lid);
        pcm_size_of = cfg_words[lid + 5][31:16];
    endfunction

    pcm_addr_decoder #(
        .ADDR_WIDTH(16),
        .PCM_TOTAL(PCM_TOTAL),
        .DATA_DIR("")
    ) DUT (
        .layer_id(layer_id),
        .orig_addr(orig_addr),
        .pcm_base(pcm_base),
        .pcm_size(pcm_size),
        .pcm_hit(pcm_hit),
        .pcm_pool_addr(pcm_pool_addr),
        .pcm_oor_error(pcm_oor_error)
    );

    integer pass_count = 0;
    integer fail_count = 0;
    integer i;             // generic loop counter
    integer h0_conv2;      // first PCM-hit orig in conv2
    integer h1_conv2;      // second PCM-hit orig in conv2
    integer m0_conv2;      // first PCM-miss orig in conv2

    // ---- Check helper -------------------------------------------
    task check(input [255:0] name,
               input [2:0]  lid,    input [15:0] oaddr,
               input [15:0] base,   input [15:0] size,
               input        exp_hit, input [15:0] exp_pool,
               input        exp_err);
        begin
            layer_id  = lid;
            orig_addr = oaddr;
            pcm_base  = base;
            pcm_size  = size;
            #1;
            if ((pcm_hit       === exp_hit ) &&
                (pcm_pool_addr === exp_pool) &&
                (pcm_oor_error === exp_err )) begin
                pass_count = pass_count + 1;
                $display("  [PASS] %0s  hit=%0b pool=%04x err=%0b",
                         name, pcm_hit, pcm_pool_addr, pcm_oor_error);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] %0s", name);
                $display("         exp: hit=%0b pool=%04x err=%0b",
                         exp_hit, exp_pool, exp_err);
                $display("         got: hit=%0b pool=%04x err=%0b",
                         pcm_hit, pcm_pool_addr, pcm_oor_error);
            end
        end
    endtask

    // ---- Sweep helper -------------------------------------------
    task sweep_layer(input [2:0]  lid,
                     input [15:0] base,
                     input [15:0] size,
                     input [15:0] depth,
                     output integer hits,
                     output integer errs);
        integer a;
        begin
            hits = 0;
            errs = 0;
            for (a = 0; a < depth; a = a + 1) begin
                layer_id  = lid;
                orig_addr = a[15:0];
                pcm_base  = base;
                pcm_size  = size;
                #1;
                if (pcm_oor_error) errs = errs + 1;
                if (pcm_hit)       hits = hits + 1;
            end
        end
    endtask

    // ---- conv2-PCM anchor discovery -----------------------------
    // h0 = first orig with PCM hit (slot=0)
    // h1 = second orig with PCM hit (slot=1)
    // m0 = first orig with PCM miss (FFFF in ROM)
    // conv2 is chosen because both models have non-empty PCM for
    // conv2 (Model A: 919, Model B: 1540).
    task find_conv2_anchors(output integer h0,
                            output integer h1,
                            output integer m0);
        integer a, count;
        begin
            h0 = -1; h1 = -1; m0 = -1;
            count = 0;
            for (a = 0; a < 2400; a = a + 1) begin
                layer_id  = 3'd1;
                orig_addr = a[15:0];
                pcm_base  = pcm_base_of(3'd1);
                pcm_size  = pcm_size_of(3'd1);
                #1;
                if (pcm_hit) begin
                    if (count == 0) h0 = a;
                    if (count == 1) h1 = a;
                    count = count + 1;
                end else if (!pcm_hit && !pcm_oor_error && m0 < 0) begin
                    m0 = a;
                end
                if (h0 >= 0 && h1 >= 0 && m0 >= 0) a = 2400;
            end
        end
    endtask

    integer hits, errs;

    // ---- Main test sequence -------------------------------------
    initial begin
        $display("============================================================");

        data_dir = {(8*512){1'b0}};
        have_data_dir = $value$plusargs("DATA_DIR=%s", data_dir);

        if (have_data_dir) begin
            $readmemh({trim(data_dir), "/addr_to_slot_conv1_pcm.hex"},
                      DUT.rom_conv1);
            $readmemh({trim(data_dir), "/addr_to_slot_conv2_pcm.hex"},
                      DUT.rom_conv2);
            $readmemh({trim(data_dir), "/addr_to_slot_fc1_pcm.hex"},
                      DUT.rom_fc1);
            $readmemh({trim(data_dir), "/addr_to_slot_fc2_pcm.hex"},
                      DUT.rom_fc2);
            $readmemh({trim(data_dir), "/addr_to_slot_fc3_pcm.hex"},
                      DUT.rom_fc3);
            $readmemh({trim(data_dir), "/layer_config.hex"}, cfg_words);
            $display("tb_pcm_addr_decoder  DATA_DIR=\"%0s\"",
                     trim(data_dir));
            $display("  loaded PCM cfg: conv1(b=%0d,s=%0d) conv2(b=%0d,s=%0d) fc1(b=%0d,s=%0d) fc2(b=%0d,s=%0d) fc3(b=%0d,s=%0d)",
                     pcm_base_of(3'd0), pcm_size_of(3'd0),
                     pcm_base_of(3'd1), pcm_size_of(3'd1),
                     pcm_base_of(3'd2), pcm_size_of(3'd2),
                     pcm_base_of(3'd3), pcm_size_of(3'd3),
                     pcm_base_of(3'd4), pcm_size_of(3'd4));
        end else begin
            $display("tb_pcm_addr_decoder  no +DATA_DIR (T1-T8 will skip)");
        end
        $display("============================================================");

        //--------------------------------------------------------
        // T0 — Default-FFFF / OOB behaviour
        //--------------------------------------------------------
        $display("");
        $display("T0  default-FFFF / oob behaviour (no data needed)");

        check("T0.1 conv1 orig=200 (past depth=150)",
              3'd0, 16'd200, 16'd0, 16'd0,
              1'b0, 16'd0, 1'b0);
        check("T0.2 layer_id=5 (oob)",
              3'd5, 16'd0, 16'd0, 16'd0,
              1'b0, 16'd0, 1'b0);
        check("T0.3 layer_id=7 (oob)",
              3'd7, 16'd0, 16'd0, 16'd0,
              1'b0, 16'd0, 1'b0);

        if (!have_data_dir) begin
            // Without data: all FFFF -> miss for any in-range
            check("T0.4 conv2 orig=0 (no data loaded)",
                  3'd1, 16'd0, 16'd0, 16'd1000,
                  1'b0, 16'd0, 1'b0);
        end

        //--------------------------------------------------------
        // Tests needing DATA_DIR
        //--------------------------------------------------------
        if (have_data_dir) begin

            // Discover conv2-PCM anchors for the current model
            find_conv2_anchors(h0_conv2, h1_conv2, m0_conv2);
            $display("");
            $display("  conv2 PCM anchors: h0=%0d h1=%0d m0=%0d",
                     h0_conv2, h1_conv2, m0_conv2);

            //----------------------------------------------------
            // T1 — Normal hit (model-agnostic)
            //----------------------------------------------------
            $display("");
            $display("T1  Normal hit (model-agnostic anchors)");
            check("T1.1 conv2 first-hit orig -> slot=0 -> pool=base",
                  3'd1, h0_conv2[15:0],
                  pcm_base_of(3'd1), pcm_size_of(3'd1),
                  1'b1, pcm_base_of(3'd1), 1'b0);
            check("T1.2 conv2 second-hit orig -> slot=1 -> pool=base+1",
                  3'd1, h1_conv2[15:0],
                  pcm_base_of(3'd1), pcm_size_of(3'd1),
                  1'b1, pcm_base_of(3'd1) + 16'd1, 1'b0);

            //----------------------------------------------------
            // T2 — Sentinel miss
            //----------------------------------------------------
            $display("");
            $display("T2  Sentinel miss (model-agnostic)");
            check("T2.1 conv2 first-miss orig (FFFF in ROM)",
                  3'd1, m0_conv2[15:0],
                  pcm_base_of(3'd1), pcm_size_of(3'd1),
                  1'b0, 16'd0, 1'b0);

            //----------------------------------------------------
            // T3 — size_violation
            //----------------------------------------------------
            $display("");
            $display("T3  size_violation (config inconsistency)");
            // T3.1: valid first-hit orig with forced size=0 -> error
            check("T3.1 conv2 first-hit orig BUT size=0",
                  3'd1, h0_conv2[15:0],
                  pcm_base_of(3'd1), 16'd0,
                  1'b0, 16'd0, 1'b1);
            // T3.2: ditto with size=1 (slot=0 fits, slot=1 doesn't)
            check("T3.2 conv2 second-hit orig (slot=1) BUT size=1",
                  3'd1, h1_conv2[15:0],
                  pcm_base_of(3'd1), 16'd1,
                  1'b0, 16'd0, 1'b1);
            // T3.3: boundary OK (slot=0 with size=1)
            check("T3.3 conv2 first-hit orig with size=1 (boundary OK)",
                  3'd1, h0_conv2[15:0],
                  pcm_base_of(3'd1), 16'd1,
                  1'b1, pcm_base_of(3'd1), 1'b0);

            //----------------------------------------------------
            // T4 — global_violation
            //----------------------------------------------------
            $display("");
            $display("T4  global_violation (base+slot >= PCM_TOTAL=58396)");
            // T4.1: take known first-hit (slot=0), force huge base
            check("T4.1 conv2 first-hit slot=0 base=58396 -> ==TOTAL",
                  3'd1, h0_conv2[15:0],
                  16'd58396, pcm_size_of(3'd1),
                  1'b0, 16'd0, 1'b1);
            // T4.2: boundary OK (one below)
            check("T4.2 conv2 first-hit slot=0 base=58395 (boundary OK)",
                  3'd1, h0_conv2[15:0],
                  16'd58395, pcm_size_of(3'd1),
                  1'b1, 16'd58395, 1'b0);
            // T4.3: wrap-around with second-hit (slot=1) base=FFFF
            //       0xFFFF + 1 = 0x10000 -> 17-bit MSB catches it
            check("T4.3 conv2 second-hit (slot=1) base=FFFF -> 0x10000",
                  3'd1, h1_conv2[15:0],
                  16'hFFFF, pcm_size_of(3'd1),
                  1'b0, 16'd0, 1'b1);

            //----------------------------------------------------
            // T5 — layer_id oob
            //----------------------------------------------------
            $display("");
            $display("T5  layer_id out-of-range (silent miss)");
            check("T5.1 layer_id=5 with valid PCM addr",
                  3'd5, h0_conv2[15:0],
                  pcm_base_of(3'd1), pcm_size_of(3'd1),
                  1'b0, 16'd0, 1'b0);
            check("T5.2 layer_id=6",
                  3'd6, 16'd0, 16'd0, 16'd0,
                  1'b0, 16'd0, 1'b0);

            //----------------------------------------------------
            // T6 — orig_addr past per-layer depth
            //----------------------------------------------------
            $display("");
            $display("T6  orig_addr past layer depth (silent miss)");
            check("T6.1 conv1 orig=150 (=depth)",
                  3'd0, 16'd150,
                  pcm_base_of(3'd0), pcm_size_of(3'd0),
                  1'b0, 16'd0, 1'b0);
            check("T6.2 conv2 orig=2400 (=depth)",
                  3'd1, 16'd2400,
                  pcm_base_of(3'd1), pcm_size_of(3'd1),
                  1'b0, 16'd0, 1'b0);
            check("T6.3 fc3 orig=840 (=depth)",
                  3'd4, 16'd840,
                  pcm_base_of(3'd4), pcm_size_of(3'd4),
                  1'b0, 16'd0, 1'b0);
            check("T6.4 fc1 orig=50000 (way past)",
                  3'd2, 16'd50000,
                  pcm_base_of(3'd2), pcm_size_of(3'd2),
                  1'b0, 16'd0, 1'b0);

            //----------------------------------------------------
            // T7 — Empty PCM partition sweep
            //----------------------------------------------------
            // The PCM-specific test that has no SRAM analogue.
            //
            // conv1's PCM partition is empty in BOTH models
            // (Paper 1 layer-aware ratios always place conv1
            // fully in SRAM because the layer is small enough
            // that 100% protection fits within the 5% budget).
            //
            // Model B additionally has fc3 fully in SRAM.
            //
            // Verification: sweep the layer's orig_addr range
            // with its actual (size=0) cfg, expect hits=0,
            // errors=0. Every orig_addr is a clean miss.
            $display("");
            $display("T7  Empty PCM partition sweep");

            // Always-empty layers: conv1
            if (pcm_size_of(3'd0) == 16'd0) begin
                sweep_layer(3'd0, pcm_base_of(3'd0), pcm_size_of(3'd0),
                            16'd150, hits, errs);
                if (hits == 0 && errs == 0) begin
                    pass_count = pass_count + 1;
                    $display("  [PASS] T7.1 conv1 PCM empty sweep: hits=%0d errs=%0d (size=0)",
                             hits, errs);
                end else begin
                    fail_count = fail_count + 1;
                    $display("  [FAIL] T7.1 conv1 PCM empty sweep: hits=%0d (exp 0) errs=%0d (exp 0)",
                             hits, errs);
                end
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T7.1 conv1 PCM size=%0d (expected 0)",
                         pcm_size_of(3'd0));
            end

            // Conditionally-empty layer: fc3 (only in Model B)
            if (pcm_size_of(3'd4) == 16'd0) begin
                sweep_layer(3'd4, pcm_base_of(3'd4), pcm_size_of(3'd4),
                            16'd840, hits, errs);
                if (hits == 0 && errs == 0) begin
                    pass_count = pass_count + 1;
                    $display("  [PASS] T7.2 fc3 PCM empty sweep: hits=%0d errs=%0d (size=0)",
                             hits, errs);
                end else begin
                    fail_count = fail_count + 1;
                    $display("  [FAIL] T7.2 fc3 PCM empty sweep: hits=%0d (exp 0) errs=%0d (exp 0)",
                             hits, errs);
                end
            end else begin
                $display("  [SKIP] T7.2 fc3 PCM size=%0d (not empty in this model)",
                         pcm_size_of(3'd4));
            end

            //----------------------------------------------------
            // T8 — End-to-end sweep (model-agnostic via cfg_words)
            //----------------------------------------------------
            $display("");
            $display("T8  End-to-end sweep (all 5 layers, model-agnostic)");

            // Reset totals for the grand-sum check
            begin : grand_sum
                integer total_hits, total_miss, total_errs;
                integer depths [0:4];
                depths[0] = 150;
                depths[1] = 2400;
                depths[2] = 48000;
                depths[3] = 10080;
                depths[4] = 840;

                total_hits = 0; total_miss = 0; total_errs = 0;

                for (i = 0; i < 5; i = i + 1) begin
                    sweep_layer(i[2:0], pcm_base_of(i[2:0]),
                                pcm_size_of(i[2:0]),
                                depths[i][15:0], hits, errs);
                    // Per-layer report
                    if (hits == pcm_size_of(i[2:0]) && errs == 0) begin
                        pass_count = pass_count + 1;
                        $display("  [PASS] T8.%0d layer=%0d sweep: hits=%0d (=size) errs=%0d",
                                 i+1, i, hits, errs);
                    end else begin
                        fail_count = fail_count + 1;
                        $display("  [FAIL] T8.%0d layer=%0d sweep: hits=%0d (exp %0d) errs=%0d (exp 0)",
                                 i+1, i, hits, pcm_size_of(i[2:0]), errs);
                    end
                    total_hits = total_hits + hits;
                    total_miss = total_miss + (depths[i] - hits);
                    total_errs = total_errs + errs;
                end

                $display("");
                $display("  Grand totals: hits=%0d (exp %0d)  misses=%0d (exp %0d)  errors=%0d (exp 0)",
                         total_hits, EXPECT_TOTAL_HITS,
                         total_miss, EXPECT_TOTAL_MISS,
                         total_errs);
                if (total_hits == EXPECT_TOTAL_HITS &&
                    total_miss == EXPECT_TOTAL_MISS &&
                    total_errs == 0) begin
                    pass_count = pass_count + 1;
                    $display("  [PASS] T8 grand-total check");
                end else begin
                    fail_count = fail_count + 1;
                    $display("  [FAIL] T8 grand-total check");
                end
            end
        end

        //--------------------------------------------------------
        // Summary
        //--------------------------------------------------------
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
        #2000000;   // 2 ms watchdog (longer because fc1 sweep is 48000)
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule
