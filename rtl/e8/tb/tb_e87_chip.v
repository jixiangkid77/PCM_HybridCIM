//============================================================
// tb_e87_chip.v   (P2R-E8.7: one inference of the whole design)
//============================================================
// Drives lenet5_top through its ports only, as the host would:
// the 10 configuration words, drift off, commit, the 150 conv1
// cache entries (host write 0x22, rtl/e8/conv1_cache.v), the 784
// pixels, the start pulse; then waits for done. The same
// testbench runs two builds of lenet5_top:
//   RTL  : rtl/src with the E8.5e unit (rtl/e8/pcm_imc_unit_e8c.v,
//          -DE8_AS_PCM_IMC_UNIT), the reference;
//   GATE : -DE87_GATE, the wrapper written by scripts/e8_7_tools.py
//          (the synthesised netlist of the digital logic, instance
//          "core", and the simulation models of the memories it
//          connects to: u_fbuf, u_bias, u_spool, u_pcb and the 200
//          address-map ROM macros).
// Both builds use the ROM model rtl/e8/e8_rom_r48_rec.v, which
// reports every read to the module e8_5b_monitor below.
//
// The cache is written by the host here (in E8.5e the simulation
// preloaded it from a file); no +e85e_cache is given, so in the
// RTL build the cache starts at zero and only these writes fill it.
//
// Checks printed at the end (both builds):
//   every feature-buffer write after the start against the golden
//   files of the layer (conv1 4704, pool1 1176, conv2 1600, pool2
//   400, fc1 120, fc2 84 writes, in this order); fc3 by the class:
//   predicted_class against the signed strict argmax of golden fc3;
//   the cycle count from the start to done.
// Streams written for the comparison of the two builds (one line
// per event, "<cycle> <hex> ..."), with +e87_dir=<folder>:
//   fbuf.txt   feature-buffer writes after the start
//   spool.txt  SRAM pool requests (hit lanes and their addresses)
//   pcb.txt    PCM crossbar starts (hit lanes, addresses, inputs)
//   bias.txt   bias reads (layer, channel, value) when they change
//   rom.txt    ROM macro reads (e8_5b_monitor, time in ps)
// Waveform (GATE build only), +e87_vcd=<file>: $dumpvars(2, DUT.core)
// from the first rising clock edge after the start pulse to the end
// (one clock after done): the nets of the netlist and the ports of
// every cell (OpenSTA reads <instance>/<pin>), not the nets inside
// the cell models.
//
// Plusargs: +e87_cache=<150-line hex> (required), +e87_dir=<folder>,
//           +e87_vcd=<file>, +e87_max_cycles=<n> (default 700000)
// Defines : -DMODEL_B for model B (data paths as tb_lenet5_full_
//           inference_v3, relative to the paper2 folder), -DE87_GATE.
//
// Place  : rtl/e8/tb/
// Status : NEW FILE.
//============================================================
`timescale 1ns/1ps

`ifndef MODEL_B
  `define E87_DATA   "data/rtl_inputs_A_v3"
  `define E87_IMG    "data/rtl_inputs_A/images/img_001.hex"
  `define E87_TAG    "A"
`else
  `define E87_DATA   "data/rtl_inputs_B_v3"
  `define E87_IMG    "data/rtl_inputs_B/images/img_001.hex"
  `define E87_TAG    "B"
`endif
`define E87_COMMON "data/rtl_inputs_common"
`define E87_GOLDEN "data/golden"

`ifdef E87_GATE
  `define E87_SPOOL DUT.u_spool
  `define E87_PCB   DUT.u_pcb
`else
  `define E87_SPOOL DUT.u_imc.U_SPOOL
  `define E87_PCB   DUT.u_imc.U_PCB
`endif
// the netlist whose waveform is written: the logic of the GATE build (another scope can be
// given with -DE87_VCD_SCOPE=<path>)
`ifndef E87_VCD_SCOPE
  `ifdef E87_GATE
    `define E87_VCD_SCOPE DUT.core
  `endif
`endif

module tb_e87_chip;

    localparam integer DATA_W  = 8;
    localparam integer FADDR_W = 13;
    localparam integer K       = 25;
    localparam integer NL      = 6;          // layers written to the feature buffer
    // writes per layer, conv1 pool1 conv2 pool2 fc1 fc2
    localparam integer N0 = 4704, N1 = 1176, N2 = 1600, N3 = 400, N4 = 120, N5 = 84;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg                       start = 1'b0;
    reg                       image_we = 1'b0;
    reg  [FADDR_W-1:0]        image_addr = 0;
    reg  signed [DATA_W-1:0]  image_data = 0;
    reg                       cfg_wr_en = 1'b0;
    reg  [5:0]                cfg_wr_addr = 0;
    reg  [31:0]               cfg_wr_data = 0;
    wire                      done;
    wire [3:0]                predicted_class;

    lenet5_top #(
        .DATA_DIR(`E87_DATA),
        .COMMON_DIR(`E87_COMMON)
    ) DUT (
        .clk(clk), .rst_n(rst_n),
        .start(start), .done(done), .predicted_class(predicted_class),
        .image_we(image_we), .image_addr(image_addr), .image_data(image_data),
        .cfg_wr_en(cfg_wr_en), .cfg_wr_addr(cfg_wr_addr), .cfg_wr_data(cfg_wr_data)
    );

    // ---- inputs ----
    reg signed [DATA_W-1:0] image_mem [0:783];
    reg [31:0]              cfg_words [0:9];
    reg [7:0]               cache_mem [0:149];
    reg [7:0]               g_mem [0:(N0+N1+N2+N3+N4+N5)-1];   // golden, layers concatenated
    reg [7:0]               g_tmp [0:N0-1];
    reg signed [15:0]       g_fc3 [0:9];
    reg [8*512-1:0]         s_cache, s_dir, s_vcd, fname;
    integer max_cycles;
    integer have_golden;

    // ---- state ----
    reg        started = 1'b0, done_seen = 1'b0, vcd_on = 1'b0, want_vcd = 1'b0;
    integer    cycle_after_start = 0;        // read by e8_5b_monitor
    integer    done_cycle = -1;
    reg [3:0]  pred_at_done = 4'hx;
    integer    n_w [0:NL-1];
    integer    n_bad [0:NL-1];
    integer    n_wtot = 0, n_xw = 0, first_bad = -1;
    integer    fd_f, fd_s, fd_p, fd_b;
    integer    i, j, l, off, base;

    task cfg_write(input [5:0] a, input [31:0] d);
        begin
            @(negedge clk);
            cfg_wr_en = 1'b1; cfg_wr_addr = a; cfg_wr_data = d;
            @(negedge clk);
            cfg_wr_en = 1'b0;
        end
    endtask

    function integer layer_base(input integer ly);
        begin
            case (ly)
                0: layer_base = 0;
                1: layer_base = N0;
                2: layer_base = N0 + N1;
                3: layer_base = N0 + N1 + N2;
                4: layer_base = N0 + N1 + N2 + N3;
                default: layer_base = N0 + N1 + N2 + N3 + N4;
            endcase
        end
    endfunction
    function integer layer_n(input integer ly);
        begin
            case (ly)
                0: layer_n = N0; 1: layer_n = N1; 2: layer_n = N2;
                3: layer_n = N3; 4: layer_n = N4; default: layer_n = N5;
            endcase
        end
    endfunction

    // golden of one layer into g_mem (have_golden cleared if the file is missing)
    task load_golden(input integer ly, input [8*512-1:0] fn);
        integer fd, k, n;
        begin
            fname = fn;
            fd = $fopen(fname, "r");
            if (fd == 0) begin
                have_golden = 0;
            end else begin
                $fclose(fd);
                n = layer_n(ly);
                for (k = 0; k < N0; k = k + 1) g_tmp[k] = 8'hxx;
                $readmemh(fname, g_tmp, 0, n - 1);
                for (k = 0; k < n; k = k + 1) g_mem[layer_base(ly) + k] = g_tmp[k];
            end
        end
    endtask

    // ---- feature-buffer writes after the start ----
    // All blocks below sample at the rising edge; the cycle count and done_seen change by
    // nonblocking assignments, so every block sees the values of the cycle that ends there,
    // in the RTL build and in the GATE build alike.
    always @(posedge clk) begin
        if (started && !done_seen && DUT.u_fbuf.write_en === 1'b1) begin
            // layer by the running count
            l = 0;
            while (l < NL - 1 && n_wtot >= layer_base(l) + layer_n(l)) l = l + 1;
            if (n_wtot >= layer_base(NL - 1) + layer_n(NL - 1)) l = NL;   // more writes than expected
            if (^{DUT.u_fbuf.write_addr, DUT.u_fbuf.write_data} === 1'bx) n_xw = n_xw + 1;
            if (fd_f) $fwrite(fd_f, "%0d %04h %02h\n", cycle_after_start, DUT.u_fbuf.write_addr, DUT.u_fbuf.write_data);
            if (l < NL) begin
                n_w[l] = n_w[l] + 1;
                if (have_golden) begin
                    if (DUT.u_fbuf.write_addr >= layer_n(l) ||
                        g_mem[layer_base(l) + DUT.u_fbuf.write_addr] !== DUT.u_fbuf.write_data) begin
                        n_bad[l] = n_bad[l] + 1;
                        if (first_bad < 0) first_bad = cycle_after_start;
                    end
                end
            end
            n_wtot = n_wtot + 1;
        end
    end

    // ---- SRAM pool requests (when the hit lanes or their addresses change), PCM crossbar
    // ---- starts, bias reads (when the address or the value changes) ----
    reg [K*16+K-1:0] sp_q;
    reg [K*16-1:0]   sp_a;
    reg [31:0]       bias_q;
    reg [10:0]       bias_key_q;
    always @(posedge clk) begin
        if (started && !done_seen) begin
            for (j = 0; j < K; j = j + 1)
                sp_a[j*16 +: 16] = `E87_SPOOL.hit_bus[j] ? `E87_SPOOL.addr_bus[j*16 +: 16] : 16'h0000;
            if (fd_s && {`E87_SPOOL.hit_bus, sp_a} !== sp_q) begin
                $fwrite(fd_s, "%0d %07h", cycle_after_start, `E87_SPOOL.hit_bus);
                for (j = 0; j < K; j = j + 1)
                    if (`E87_SPOOL.hit_bus[j]) $fwrite(fd_s, " %0d:%04h", j, `E87_SPOOL.addr_bus[j*16 +: 16]);
                $fwrite(fd_s, "\n");
                sp_q = {`E87_SPOOL.hit_bus, sp_a};
            end
            if (fd_p && `E87_PCB.start === 1'b1) begin
                $fwrite(fd_p, "%0d %07h", cycle_after_start, `E87_PCB.pcm_hit_bus);
                for (j = 0; j < K; j = j + 1)
                    if (`E87_PCB.pcm_hit_bus[j])
                        $fwrite(fd_p, " %0d:%04h:%02h", j, `E87_PCB.pcm_pool_addr_bus[j*16 +: 16], `E87_PCB.v_bus[j*8 +: 8]);
                $fwrite(fd_p, "\n");
            end
            if (fd_b && ({DUT.u_bias.layer_id, DUT.u_bias.channel} !== bias_key_q || DUT.u_bias.bias_out !== bias_q)) begin
                $fwrite(fd_b, "%0d %0d %02h %08h\n", cycle_after_start, DUT.u_bias.layer_id, DUT.u_bias.channel,
                        DUT.u_bias.bias_out);
                bias_key_q = {DUT.u_bias.layer_id, DUT.u_bias.channel};
                bias_q     = DUT.u_bias.bias_out;
            end
        end
    end

    // ---- cycle count, done, waveform ----
    always @(posedge clk) begin
        if (started) begin
            if (want_vcd && !vcd_on) begin
`ifdef E87_VCD_SCOPE
                $dumpvars(2, `E87_VCD_SCOPE);
`endif
                vcd_on = 1'b1;
            end
            if (done === 1'b1 && !done_seen) begin
                done_seen    <= 1'b1;
                done_cycle   <= cycle_after_start;
                pred_at_done <= predicted_class;
            end
            cycle_after_start <= cycle_after_start + 1;
        end
    end

    // ---- the run ----
    integer pass_all, exp_class, k2;
    reg signed [15:0] best;
    initial begin
        for (i = 0; i < NL; i = i + 1) begin n_w[i] = 0; n_bad[i] = 0; end
        fd_f = 0; fd_s = 0; fd_p = 0; fd_b = 0; bias_q = 32'hxxxxxxxx; bias_key_q = 11'hxxx;
        sp_q = {(K*16+K){1'bx}};
        if (!$value$plusargs("e87_max_cycles=%d", max_cycles)) max_cycles = 700000;
        if (!$value$plusargs("e87_cache=%s", s_cache)) begin
            $display("[E8.7] ERROR: +e87_cache=<file> is required");
            $finish;
        end
        if ($value$plusargs("e87_dir=%s", s_dir)) begin
            fd_f = $fopen({s_dir, "/fbuf.txt"}, "w");
            fd_s = $fopen({s_dir, "/spool.txt"}, "w");
            fd_p = $fopen({s_dir, "/pcb.txt"}, "w");
            fd_b = $fopen({s_dir, "/bias.txt"}, "w");
        end
        want_vcd = $value$plusargs("e87_vcd=%s", s_vcd);
`ifdef E87_VCD_SCOPE
        if (want_vcd) begin
            $dumpfile(s_vcd);
        end
`else
        if (want_vcd) $display("[E8.7] note: +e87_vcd is used only in the GATE build");
        want_vcd = 1'b0;
`endif
        $readmemh(`E87_IMG, image_mem);
        $readmemh({`E87_DATA, "/layer_config.hex"}, cfg_words);
        $readmemh(s_cache, cache_mem);
        have_golden = 1;
        load_golden(0, {`E87_GOLDEN, "/golden_conv1_", `E87_TAG, "_img1.hex"});
        load_golden(1, {`E87_GOLDEN, "/golden_pool1_", `E87_TAG, "_img1.hex"});
        load_golden(2, {`E87_GOLDEN, "/golden_conv2_", `E87_TAG, "_img1.hex"});
        load_golden(3, {`E87_GOLDEN, "/golden_pool2_", `E87_TAG, "_img1.hex"});
        load_golden(4, {`E87_GOLDEN, "/golden_fc1_",   `E87_TAG, "_img1.hex"});
        load_golden(5, {`E87_GOLDEN, "/golden_fc2_",   `E87_TAG, "_img1.hex"});
        fname = {`E87_GOLDEN, "/golden_fc3_", `E87_TAG, "_img1.hex"};
        k2 = $fopen(fname, "r");
        if (k2 == 0) have_golden = 0; else begin $fclose(k2); $readmemh(fname, g_fc3); end
`ifdef E87_GATE
        $display("[E8.7] build GATE, model %0s", `E87_TAG);
`else
        $display("[E8.7] build RTL, model %0s", `E87_TAG);
`endif
        $display("[E8.7] golden files: %0s", have_golden ? "read" : "NOT FOUND (no comparison)");

        @(negedge clk); @(negedge clk); @(negedge clk);
        @(negedge clk); rst_n = 1'b1;
        @(negedge clk); @(negedge clk);
        // boot: configuration as tb_lenet5_full_inference_v3, then the conv1 cache
        for (i = 0; i < 10; i = i + 1) cfg_write(i[5:0], cfg_words[i]);
        cfg_write(6'h21, 32'h0000_0000);
        cfg_write(6'h20, 32'h0000_0002);
        for (i = 0; i < 150; i = i + 1) cfg_write(6'h22, {16'h0000, i[7:0], cache_mem[i]});
        // image
        for (i = 0; i < 784; i = i + 1) begin
            @(negedge clk);
            image_we = 1'b1; image_addr = i[FADDR_W-1:0]; image_data = image_mem[i];
        end
        @(negedge clk); image_we = 1'b0;
        // start
        @(negedge clk); start = 1'b1; started = 1'b1;
        $display("[E8.7] start pulse at %0.1f ns", $realtime);
        @(negedge clk); start = 1'b0;
        while (!done_seen && cycle_after_start < max_cycles) @(negedge clk);
        @(negedge clk);                       // one clock after done
        // ---- summary ----
        exp_class = 0; best = g_fc3[0];
        for (i = 1; i < 10; i = i + 1) if (g_fc3[i] > best) begin best = g_fc3[i]; exp_class = i; end
        pass_all = done_seen;
        $display("[E8.7] done %0s at cycle %0d after the start, predicted_class %0d, golden argmax %0d",
                 done_seen ? "seen" : "NOT SEEN", done_cycle, pred_at_done, have_golden ? exp_class : -1);
        for (i = 0; i < NL; i = i + 1) begin
            $display("[E8.7] layer %0d writes %0d (expected %0d), mismatches %0d", i, n_w[i], layer_n(i), n_bad[i]);
            if (n_w[i] != layer_n(i)) pass_all = 0;
            if (have_golden && n_bad[i] != 0) pass_all = 0;
        end
        $display("[E8.7] feature-buffer writes after the start %0d, with x or z bits %0d, first mismatch at cycle %0d",
                 n_wtot, n_xw, first_bad);
        if (n_xw != 0) pass_all = 0;
        if (have_golden && pred_at_done !== exp_class[3:0]) pass_all = 0;
        $display("[E8.7] RESULT %0s (golden %0s)", pass_all ? "PASS" : "FAIL", have_golden ? "used" : "not available");
        if (fd_f) $fclose(fd_f);
        if (fd_s) $fclose(fd_s);
        if (fd_p) $fclose(fd_p);
        if (fd_b) $fclose(fd_b);
        e8_5b_monitor.close_files;
        $finish;
    end

endmodule

//============================================================
// e8_5b_monitor (P2R-E8.7 version): the three tasks that the ROM
// model rtl/e8/e8_rom_r48_rec.v calls, with the same arguments as
// in rtl/e8/tb/e8_5b_monitor.v, here writing <e87_dir>/rom.txt:
//   R <phase> <cycle> <t_ps> <side> <lane> <macro> <addr_hex> <low_ps>
//   E <side> <lane> <macro> <code>          (protocol error)
//   N <side> <lane> <macro>                 (no table data)
// phase B / I / A = before the start / during the inference / after
// done. Only this file is compiled in E8.7 runs, never together
// with rtl/e8/tb/e8_5b_monitor.v.
//============================================================
module e8_5b_monitor;
    integer fd = 0, n_read = 0, n_err = 0, n_nodata = 0;
    reg [8*512-1:0] d;
    initial begin
        if ($value$plusargs("e87_dir=%s", d)) fd = $fopen({d, "/rom.txt"}, "w");
    end
    task rom_read(input integer side, input integer lane, input integer macro, input [9:0] addr,
                  input [63:0] low_ps);
        reg [63:0] t_ps;
        begin
            t_ps = $realtime * 1000.0;
            n_read = n_read + 1;
            if (fd) $fwrite(fd, "R %0s %0d %0d %0d %0d %0d %03h %0d\n",
                            !tb_e87_chip.started ? "B" : tb_e87_chip.done_seen ? "A" : "I",
                            tb_e87_chip.cycle_after_start, t_ps, side, lane, macro, addr, low_ps);
        end
    endtask
    task rom_err(input integer side, input integer lane, input integer macro, input integer code);
        begin
            n_err = n_err + 1;
            if (fd) $fwrite(fd, "E %0d %0d %0d %0d\n", side, lane, macro, code);
        end
    endtask
    task rom_nodata(input integer side, input integer lane, input integer macro);
        begin
            n_nodata = n_nodata + 1;
            if (fd) $fwrite(fd, "N %0d %0d %0d\n", side, lane, macro);
        end
    endtask
    task close_files;
        begin
            $display("[E8.7] ROM macro reads %0d, protocol errors %0d, macros without data %0d", n_read, n_err, n_nodata);
            if (fd) $fclose(fd);
        end
    endtask
endmodule
