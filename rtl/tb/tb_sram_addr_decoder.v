//============================================================
// tb_sram_addr_decoder.v
// Unit tests for sram_addr_decoder.v
//
// Run:
//   iverilog -g2012 -o build/tb_sad \
//     rtl/src/sram_addr_decoder.v rtl/tb/tb_sram_addr_decoder.v
//   vvp build/tb_sad +DATA_DIR=data/rtl_inputs_A_v3
//
// Required tests (from KID's review of Step 3a plan):
//   T1. Normal hit (conv2 orig=4 → slot=0, pool=base+0)
//   T2. Sentinel miss (conv2 orig=0 → FFFF, hit=0, error=0)
//   T3. size_violation: force sram_size=0, valid orig → error=1
//   T4. global_violation: base+slot >= SRAM_TOTAL → error=1
//   T5. layer_id out of range → hit=0, error=0
//   T6. orig_addr past layer depth → hit=0, error=0
//
// Additional tests:
//   T0. Sentinel-only (no +DATA_DIR): every read returns miss
//   T7. All five layers' first-hit (Model A reference)
//   T8. End-to-end sweep: for each layer, count hits across the
//       entire orig_addr range and check against layer_config size
//============================================================

`timescale 1ns/1ps

module tb_sram_addr_decoder;

    // ---- plusargs handling (same pattern as Step 2) --------------
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

    // ---- DUT signals ---------------------------------------------
    reg  [2:0]  layer_id;
    reg  [15:0] orig_addr;
    reg  [15:0] sram_base;
    reg  [15:0] sram_size;
    wire        sram_hit;
    wire [15:0] sram_pool_addr;
    wire        sram_oor_error;

    // ---- Model-agnostic config loaded from layer_config.hex ------
    // Same 10-line {size[31:16], base[15:0]} format produced by
    // 03_split_protected_v3.py and used by layer_config_regfile.
    // Loading at testbench level (not via DUT) lets T7/T8 adapt
    // to whatever model's data is being checked.
    reg [31:0] cfg_words [0:9];

    // Convenience helpers -- index 0..4 = SRAM, 5..9 = PCM.
    function [15:0] sram_base_of(input [2:0] lid);
        sram_base_of = cfg_words[lid][15:0];
    endfunction
    function [15:0] sram_size_of(input [2:0] lid);
        sram_size_of = cfg_words[lid][31:16];
    endfunction

    sram_addr_decoder #(
        .ADDR_WIDTH(16),
        .SRAM_TOTAL(3074),
        .DATA_DIR("")
    ) DUT (
        .layer_id(layer_id),
        .orig_addr(orig_addr),
        .sram_base(sram_base),
        .sram_size(sram_size),
        .sram_hit(sram_hit),
        .sram_pool_addr(sram_pool_addr),
        .sram_oor_error(sram_oor_error)
    );

    integer pass_count = 0;
    integer fail_count = 0;
    integer i;          // generic loop counter for T7
    integer h0_conv2;   // first-hit orig in conv2 (slot=0)
    integer h1_conv2;   // second-hit orig in conv2 (slot=1)
    integer m0_conv2;   // first-miss orig in conv2 (FFFF in ROM)

    // ---- Check helper --------------------------------------------
    task check(input [255:0] name,
               input [2:0]  lid,    input [15:0] oaddr,
               input [15:0] base,   input [15:0] size,
               input        exp_hit, input [15:0] exp_pool,
               input        exp_err);
        begin
            layer_id  = lid;
            orig_addr = oaddr;
            sram_base = base;
            sram_size = size;
            #1;
            if ((sram_hit       === exp_hit ) &&
                (sram_pool_addr === exp_pool) &&
                (sram_oor_error === exp_err )) begin
                pass_count = pass_count + 1;
                $display("  [PASS] %0s  hit=%0b pool=%04x err=%0b",
                         name, sram_hit, sram_pool_addr, sram_oor_error);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] %0s", name);
                $display("         exp: hit=%0b pool=%04x err=%0b",
                         exp_hit, exp_pool, exp_err);
                $display("         got: hit=%0b pool=%04x err=%0b",
                         sram_hit, sram_pool_addr, sram_oor_error);
            end
        end
    endtask

    // ---- Find helper: search conv2 ROM for first two hits and ---
    //                   first miss, in ascending orig order.
    //   This lets T1/T2/T3 use model-discovered orig values instead
    //   of hardcoded ones, so both Model A and Model B can pass.
    //
    //   conv2 is chosen because it has both SRAM and PCM entries in
    //   both models (unlike conv1 which is 100% SRAM or fc3 in
    //   Model B which is 100% SRAM).
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
                sram_base = sram_base_of(3'd1);
                sram_size = sram_size_of(3'd1);
                #1;
                if (sram_hit) begin
                    if (count == 0) h0 = a;
                    if (count == 1) h1 = a;
                    count = count + 1;
                end else if (!sram_hit && !sram_oor_error && m0 < 0) begin
                    m0 = a;
                end
                if (h0 >= 0 && h1 >= 0 && m0 >= 0) a = 2400;  // break
            end
        end
    endtask
    // Returns the number of valid (hit) addresses for the given
    // layer, plus the number of errors encountered. Used for
    // end-to-end consistency vs split_summary_v3 sizes.
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
                sram_base = base;
                sram_size = size;
                #1;
                if (sram_oor_error) errs = errs + 1;
                if (sram_hit)       hits = hits + 1;
            end
        end
    endtask

    integer hits, errs;

    // ---- Test sequence -------------------------------------------
    initial begin
        $display("============================================================");

        // Load ROMs via plusargs + hierarchical $readmemh (Step 2 pattern)
        data_dir = {(8*512){1'b0}};
        have_data_dir = $value$plusargs("DATA_DIR=%s", data_dir);

        if (have_data_dir) begin
            // Load addr_to_slot ROMs into DUT via hierarchical ref.
            $readmemh({trim(data_dir), "/addr_to_slot_conv1_sram.hex"},
                      DUT.rom_conv1);
            $readmemh({trim(data_dir), "/addr_to_slot_conv2_sram.hex"},
                      DUT.rom_conv2);
            $readmemh({trim(data_dir), "/addr_to_slot_fc1_sram.hex"},
                      DUT.rom_fc1);
            $readmemh({trim(data_dir), "/addr_to_slot_fc2_sram.hex"},
                      DUT.rom_fc2);
            $readmemh({trim(data_dir), "/addr_to_slot_fc3_sram.hex"},
                      DUT.rom_fc3);
            // Load layer_config.hex at testbench level so T7/T8
            // adapt to whichever model is loaded.
            $readmemh({trim(data_dir), "/layer_config.hex"}, cfg_words);
            $display("tb_sram_addr_decoder  DATA_DIR=\"%0s\"",
                     trim(data_dir));
            $display("  loaded SRAM cfg: conv1(b=%0d,s=%0d) conv2(b=%0d,s=%0d) fc1(b=%0d,s=%0d) fc2(b=%0d,s=%0d) fc3(b=%0d,s=%0d)",
                     sram_base_of(3'd0), sram_size_of(3'd0),
                     sram_base_of(3'd1), sram_size_of(3'd1),
                     sram_base_of(3'd2), sram_size_of(3'd2),
                     sram_base_of(3'd3), sram_size_of(3'd3),
                     sram_base_of(3'd4), sram_size_of(3'd4));
        end else begin
            $display("tb_sram_addr_decoder  no +DATA_DIR (T1-T8 will skip)");
        end
        $display("============================================================");

        //--------------------------------------------------------
        // T0 — Sentinel/oob behavior (works without loaded data)
        //--------------------------------------------------------
        $display("");
        $display("T0  default-FFFF / oob behaviour (no data needed)");

        // T0.1: conv1 past its 150-entry depth → FFFF
        check("T0.1 conv1 orig=200 (past depth=150)",
              3'd0, 16'd200, 16'd0, 16'd150,
              1'b0, 16'd0, 1'b0);

        // T0.2: layer_id=5 (out of range 0..4)
        check("T0.2 layer_id=5 (oob)",
              3'd5, 16'd0, 16'd0, 16'd150,
              1'b0, 16'd0, 1'b0);

        // T0.3: layer_id=7 (max 3-bit value)
        check("T0.3 layer_id=7 (oob)",
              3'd7, 16'd0, 16'd0, 16'd150,
              1'b0, 16'd0, 1'b0);

        if (!have_data_dir) begin
            // T0.4: with no DATA_DIR all ROMs are FFFF, so any
            // in-range read returns miss with no error.
            check("T0.4 conv1 orig=0 (no data loaded)",
                  3'd0, 16'd0, 16'd0, 16'd150,
                  1'b0, 16'd0, 1'b0);
        end

        //--------------------------------------------------------
        // Tests that need Model A data loaded
        //--------------------------------------------------------
        if (have_data_dir) begin

            //----------------------------------------------------
            // Discover conv2 anchors for the current model
            //----------------------------------------------------
            // h0 = first orig with hit (slot=0)
            // h1 = second orig with hit (slot=1)
            // m0 = first orig with miss (FFFF)
            find_conv2_anchors(h0_conv2, h1_conv2, m0_conv2);
            $display("");
            $display("  conv2 anchors (this model): h0=%0d h1=%0d m0=%0d",
                     h0_conv2, h1_conv2, m0_conv2);

            //----------------------------------------------------
            // T1 — Normal hit (model-agnostic via discovered orig)
            //----------------------------------------------------
            $display("");
            $display("T1  Normal hit (model-agnostic anchors)");
            check("T1.1 conv2 first-hit orig -> slot=0 -> pool=base",
                  3'd1, h0_conv2[15:0],
                  sram_base_of(3'd1), sram_size_of(3'd1),
                  1'b1, sram_base_of(3'd1), 1'b0);
            check("T1.2 conv2 second-hit orig -> slot=1 -> pool=base+1",
                  3'd1, h1_conv2[15:0],
                  sram_base_of(3'd1), sram_size_of(3'd1),
                  1'b1, sram_base_of(3'd1) + 16'd1, 1'b0);

            //----------------------------------------------------
            // T2 — Sentinel miss (model-agnostic via discovered orig)
            //----------------------------------------------------
            $display("");
            $display("T2  Sentinel miss (model-agnostic)");
            check("T2.1 conv2 first-miss orig (FFFF in ROM)",
                  3'd1, m0_conv2[15:0],
                  sram_base_of(3'd1), sram_size_of(3'd1),
                  1'b0, 16'd0, 1'b0);

            //----------------------------------------------------
            // T3 — size_violation (model-agnostic)
            //----------------------------------------------------
            $display("");
            $display("T3  size_violation (config inconsistency)");
            // T3.1: drive the first-hit orig with size=0 -> 0 >= 0
            //       -> size_violation -> error=1, hit=0
            check("T3.1 conv2 first-hit orig BUT size=0",
                  3'd1, h0_conv2[15:0],
                  sram_base_of(3'd1), 16'd0,
                  1'b0, 16'd0, 1'b1);
            // T3.2: conv1 all 150 in SRAM. slot=149 with size=149
            //       -> 149 >= 149 -> error. This holds for both
            //       Model A and B because conv1 is 100% SRAM in
            //       both, with slot==orig_addr identity mapping.
            check("T3.2 conv1 orig=149 slot=149 BUT size=149",
                  3'd0, 16'd149, 16'd0, 16'd149,
                  1'b0, 16'd0, 1'b1);
            // T3.3: slot=0 with size=1 -> 0 < 1 -> OK boundary
            check("T3.3 conv1 orig=0 slot=0 size=1 (boundary OK)",
                  3'd0, 16'd0, 16'd0, 16'd1,
                  1'b1, 16'd0, 1'b0);

            //----------------------------------------------------
            // T4 — global_violation
            //----------------------------------------------------
            $display("");
            $display("T4  global_violation (base+slot >= SRAM_TOTAL=3074)");
            // T4.1: conv1 orig=149 -> slot=149. base=3000 ->
            //       pool_ext=3149 >= 3074 -> error
            check("T4.1 conv1 orig=149 slot=149 base=3000 -> 3149",
                  3'd0, 16'd149, 16'd3000, 16'd150,
                  1'b0, 16'd0, 1'b1);
            // T4.2: conv1 orig=0 -> slot=0. base=3074 ->
            //       pool_ext=3074 == SRAM_TOTAL -> error
            check("T4.2 conv1 orig=0 slot=0 base=3074 -> 3074",
                  3'd0, 16'd0, 16'd3074, 16'd150,
                  1'b0, 16'd0, 1'b1);
            // T4.3: conv1 orig=0 -> slot=0. base=3073 ->
            //       pool_ext=3073 < 3074 -> OK
            check("T4.3 conv1 orig=0 slot=0 base=3073 (boundary OK)",
                  3'd0, 16'd0, 16'd3073, 16'd150,
                  1'b1, 16'd3073, 1'b0);
            // T4.4: True 16-bit wrap-around. conv1 orig=1 has
            //       slot=1 (Model A 100% sram). base=0xFFFF ->
            //       17-bit sum=0x10000 -> global_violation via
            //       MSB carry, regardless of SRAM_TOTAL. This
            //       exercises the {1'b0, base} + {1'b0, slot}
            //       wrap-around catch.
            check("T4.4 conv1 orig=1 (slot=1) base=FFFF -> 17-bit sum=0x10000",
                  3'd0, 16'd1, 16'hFFFF, 16'd150,
                  1'b0, 16'd0, 1'b1);

            //----------------------------------------------------
            // T5 — layer_id oob
            //----------------------------------------------------
            $display("");
            $display("T5  layer_id out-of-range (silent miss)");
            check("T5.1 layer_id=5 with valid conv-style addr",
                  3'd5, 16'd0, 16'd0, 16'd150,
                  1'b0, 16'd0, 1'b0);
            check("T5.2 layer_id=6 ",
                  3'd6, 16'd4, 16'd150, 16'd1481,
                  1'b0, 16'd0, 1'b0);

            //----------------------------------------------------
            // T6 — orig_addr past per-layer depth
            //----------------------------------------------------
            $display("");
            $display("T6  orig_addr past layer depth (silent miss)");
            check("T6.1 conv1 orig=150 (=depth, just past)",
                  3'd0, 16'd150, 16'd0, 16'd150,
                  1'b0, 16'd0, 1'b0);
            check("T6.2 conv2 orig=2400 (=depth)",
                  3'd1, 16'd2400, 16'd150, 16'd1481,
                  1'b0, 16'd0, 1'b0);
            check("T6.3 fc3 orig=840 (=depth)",
                  3'd4, 16'd840, 16'd2280, 16'd794,
                  1'b0, 16'd0, 1'b0);
            check("T6.4 fc1 orig=50000 (way past)",
                  3'd2, 16'd50000, 16'd1631, 16'd335,
                  1'b0, 16'd0, 1'b0);

            //----------------------------------------------------
            // T7 — First-hit per layer (model-agnostic search)
            //----------------------------------------------------
            // For each layer, sweep orig_addr ascending until the
            // first hit is found. By construction (top-K |w|
            // ordering produces SRAM slots 0..size-1 in
            // ascending-orig order), this first hit MUST map to
            // slot=0, hence pool_addr == base. This holds for any
            // model whose split_protected_v3 output places
            // weights into the pool in canonical layer-then-
            // sorted-orig order.
            $display("");
            $display("T7  First-hit per layer (search, model-agnostic)");

            for (i = 0; i < 5; i = i + 1) begin : t7_loop
                integer found_at;
                reg     found_ok;
                integer depth_i;
                reg [15:0] expect_pool;

                case (i)
                    0: depth_i = 150;
                    1: depth_i = 2400;
                    2: depth_i = 48000;
                    3: depth_i = 10080;
                    4: depth_i = 840;
                    default: depth_i = 0;
                endcase

                // Skip layers with size=0 (e.g. Model B fc3 has
                // all SRAM, all 840 valid; Model A's PCM-only
                // edge case doesn't apply for SRAM side -- but
                // be defensive).
                if (sram_size_of(i[2:0]) == 16'd0) begin
                    $display("  [SKIP] T7.%0d layer=%0d size=0",
                             i+1, i);
                end else begin
                    found_at = -1;
                    found_ok = 1'b0;
                    expect_pool = sram_base_of(i[2:0]);

                    // Drive the decoder with each orig_addr and
                    // sample synchronously.
                    begin : search
                        integer a;
                        for (a = 0; a < depth_i; a = a + 1) begin
                            layer_id  = i[2:0];
                            orig_addr = a[15:0];
                            sram_base = sram_base_of(i[2:0]);
                            sram_size = sram_size_of(i[2:0]);
                            #1;
                            if (sram_hit) begin
                                found_at = a;
                                // slot=0 => pool_addr == base
                                found_ok = (sram_pool_addr === expect_pool) &&
                                           (sram_oor_error === 1'b0);
                                disable search;
                            end
                        end
                    end

                    if (found_at >= 0 && found_ok) begin
                        pass_count = pass_count + 1;
                        $display("  [PASS] T7.%0d layer=%0d first hit at orig=%0d pool=%04x (=base)",
                                 i+1, i, found_at, sram_pool_addr);
                    end else if (found_at < 0) begin
                        fail_count = fail_count + 1;
                        $display("  [FAIL] T7.%0d layer=%0d: no hit found in depth=%0d",
                                 i+1, i, depth_i);
                    end else begin
                        fail_count = fail_count + 1;
                        $display("  [FAIL] T7.%0d layer=%0d: first hit at orig=%0d pool=%04x (expected =base=%04x) err=%0b",
                                 i+1, i, found_at, sram_pool_addr,
                                 expect_pool, sram_oor_error);
                    end
                end
            end

            //----------------------------------------------------
            // T8 — End-to-end sweep (model-agnostic via cfg_words)
            //----------------------------------------------------
            // For each layer, sweep orig_addr 0..depth-1 with
            // base/size taken from the loaded layer_config.hex.
            // Verify hit count matches the layer's SRAM size and
            // no errors are reported. Equivalent in RTL to what
            // verify_split_v3.py does in Python.
            $display("");
            $display("T8  End-to-end sweep (model-agnostic)");

            sweep_layer(3'd0, sram_base_of(3'd0), sram_size_of(3'd0),
                        16'd150, hits, errs);
            if (hits == sram_size_of(3'd0) && errs == 0) begin
                pass_count = pass_count + 1;
                $display("  [PASS] T8.1 conv1 sweep: hits=%0d (=size) errs=%0d",
                         hits, errs);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T8.1 conv1 sweep: hits=%0d (exp %0d) errs=%0d (exp 0)",
                         hits, sram_size_of(3'd0), errs);
            end

            sweep_layer(3'd1, sram_base_of(3'd1), sram_size_of(3'd1),
                        16'd2400, hits, errs);
            if (hits == sram_size_of(3'd1) && errs == 0) begin
                pass_count = pass_count + 1;
                $display("  [PASS] T8.2 conv2 sweep: hits=%0d (=size) errs=%0d",
                         hits, errs);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T8.2 conv2 sweep: hits=%0d (exp %0d) errs=%0d (exp 0)",
                         hits, sram_size_of(3'd1), errs);
            end

            sweep_layer(3'd2, sram_base_of(3'd2), sram_size_of(3'd2),
                        16'd48000, hits, errs);
            if (hits == sram_size_of(3'd2) && errs == 0) begin
                pass_count = pass_count + 1;
                $display("  [PASS] T8.3 fc1 sweep: hits=%0d (=size) errs=%0d",
                         hits, errs);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T8.3 fc1 sweep: hits=%0d (exp %0d) errs=%0d (exp 0)",
                         hits, sram_size_of(3'd2), errs);
            end

            sweep_layer(3'd3, sram_base_of(3'd3), sram_size_of(3'd3),
                        16'd10080, hits, errs);
            if (hits == sram_size_of(3'd3) && errs == 0) begin
                pass_count = pass_count + 1;
                $display("  [PASS] T8.4 fc2 sweep: hits=%0d (=size) errs=%0d",
                         hits, errs);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T8.4 fc2 sweep: hits=%0d (exp %0d) errs=%0d (exp 0)",
                         hits, sram_size_of(3'd3), errs);
            end

            sweep_layer(3'd4, sram_base_of(3'd4), sram_size_of(3'd4),
                        16'd840, hits, errs);
            if (hits == sram_size_of(3'd4) && errs == 0) begin
                pass_count = pass_count + 1;
                $display("  [PASS] T8.5 fc3 sweep: hits=%0d (=size) errs=%0d",
                         hits, errs);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] T8.5 fc3 sweep: hits=%0d (exp %0d) errs=%0d (exp 0)",
                         hits, sram_size_of(3'd4), errs);
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

    // Watchdog
    initial begin
        #500000;  // 0.5 ms is plenty even with the 48000-entry fc1 sweep
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule
