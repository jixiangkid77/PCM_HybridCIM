`timescale 1ns/1ps
//============================================================
// tb_amu_engines.v   (P2R-E8.5)
//============================================================
// The unchanged conv / fc engines run the whole LeNet-5 operation
// sequence (conv1 4,704, conv2 9,600, fc1 1,920, fc2 420, fc3 40
// MAC operations) against two IMC units fed with the same bus:
//   REF  rtl/src/pcm_imc_unit.v (50 behavioural decoders)
//   NEW  rtl/e8/pcm_imc_unit_e8.v (address-map unit, r48 ROM
//        models with the T1 timing)
// The engines take result_valid from USE_NEW ? NEW : REF.
// Checked:
//   - every operation: the 25 SRAM-side and 25 PCM-side hit,
//     out-of-range and pool addresses of NEW at its datapath
//     start equal those of REF at the engine's start pulse;
//   - the cycle count of the sequence (same as REF when NEW
//     never stalls), stall cycles, ROM reads and parks;
//   - the ROM protocol at every macro of every table: CS after
//     the clock edge, address held, valid word addresses, clock
//     low >= 90 ns before lookup reads, >= 50 ns before parks;
//   - the parking rule at every parking pulse of every table
//     (it reads its parking word exactly when the last word its
//     macro returned has a zero bit) and no macro left unparked;
//   - the error flags of the address-map unit.
// Data: DATA_DIR of the addr_to_slot hex files only (weights are
// not needed: the MAC results are not compared here). Compile
// with -DMODEL_B -DDATA_DIR_STR=\"data/rtl_inputs_B_v3\" for B.
//
// Place  : rtl/e8/tb/
// Status : NEW FILE.
//============================================================
module tb_amu_engines;
`ifndef DATA_DIR_STR
  `define DATA_DIR_STR "data/rtl_inputs_A_v3"
`endif
`ifndef USE_NEW
  `define USE_NEW 1
`endif
  localparam integer K = 25;
  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ---------------- engines ----------------
  reg  [2:0] step = 3'd7;               // 0 conv1, 1 conv2, 2 fc1, 3 fc2, 4 fc3, 7 none
  reg  st_c1 = 0, st_c2 = 0, st_f1 = 0, st_f2 = 0, st_f3 = 0;
  wire [25*8-1:0] v1, v2, v3, v4, v5;
  wire [25*16-1:0] a1, a2, a3, a4, a5;
  wire s1, s2, s3, s4, s5, d1, d2, d3, d4, d5, t1, t2, t3, t4, t5;
  wire [12:0] fa1, fa2, fa3, fa4, fa5, oa1, oa2, oa3, oa4, oa5;
  wire [7:0] ba1, ba2, ba3, ba4, ba5, od1, od2, od3, od4;
  wire [15:0] od5;
  wire oe1, oe2, oe3, oe4, oe5;
  wire rv;
  wire signed [23:0] mres;
  conv_engine #(.IN_H(28), .IN_W(28), .IN_CH(1), .OUT_CH(6), .KERNEL(5), .PADDING(2), .OUT_H(28), .OUT_W(28))
    UC1 (.clk(clk), .rst_n(rst_n), .start(st_c1), .layer_id(3'd0), .rshift_dyn(5'd0),
         .imc_v_bus(v1), .imc_addr_bus(a1), .imc_start(s1), .imc_mac_result(mres), .imc_result_valid(rv & (step == 0)),
         .fmap_addr(fa1), .fmap_in(8'sd1), .bias_addr(ba1), .bias_in(32'sd0),
         .out_addr(oa1), .out_data(od1), .out_en(oe1), .done(d1), .mac_timeout(t1));
  conv_engine #(.IN_H(14), .IN_W(14), .IN_CH(6), .OUT_CH(16), .KERNEL(5), .PADDING(0), .OUT_H(10), .OUT_W(10))
    UC2 (.clk(clk), .rst_n(rst_n), .start(st_c2), .layer_id(3'd1), .rshift_dyn(5'd0),
         .imc_v_bus(v2), .imc_addr_bus(a2), .imc_start(s2), .imc_mac_result(mres), .imc_result_valid(rv & (step == 1)),
         .fmap_addr(fa2), .fmap_in(8'sd1), .bias_addr(ba2), .bias_in(32'sd0),
         .out_addr(oa2), .out_data(od2), .out_en(oe2), .done(d2), .mac_timeout(t2));
  fc_engine #(.IN_DIM(400), .OUT_DIM(120))
    UF1 (.clk(clk), .rst_n(rst_n), .start(st_f1), .layer_id(3'd2), .rshift_dyn(5'd0),
         .imc_v_bus(v3), .imc_addr_bus(a3), .imc_start(s3), .imc_mac_result(mres), .imc_result_valid(rv & (step == 2)),
         .fmap_addr(fa3), .fmap_in(8'sd1), .bias_addr(ba3), .bias_in(32'sd0),
         .out_addr(oa3), .out_data(od3), .out_en(oe3), .done(d3), .mac_timeout(t3));
  fc_engine #(.IN_DIM(120), .OUT_DIM(84))
    UF2 (.clk(clk), .rst_n(rst_n), .start(st_f2), .layer_id(3'd3), .rshift_dyn(5'd0),
         .imc_v_bus(v4), .imc_addr_bus(a4), .imc_start(s4), .imc_mac_result(mres), .imc_result_valid(rv & (step == 3)),
         .fmap_addr(fa4), .fmap_in(8'sd1), .bias_addr(ba4), .bias_in(32'sd0),
         .out_addr(oa4), .out_data(od4), .out_en(oe4), .done(d4), .mac_timeout(t4));
  fc_engine #(.IN_DIM(84), .OUT_DIM(10), .USE_RELU(0), .OUT_W(16))
    UF3 (.clk(clk), .rst_n(rst_n), .start(st_f3), .layer_id(3'd4), .rshift_dyn(5'd0),
         .imc_v_bus(v5), .imc_addr_bus(a5), .imc_start(s5), .imc_mac_result(mres), .imc_result_valid(rv & (step == 4)),
         .fmap_addr(fa5), .fmap_in(8'sd1), .bias_addr(ba5), .bias_in(32'sd0),
         .out_addr(oa5), .out_data(od5), .out_en(oe5), .done(d5), .mac_timeout(t5));

  // the IMC bus as top_fsm muxes it (zeros and layer 0 when no engine runs)
  reg [25*8-1:0] vbus; reg [25*16-1:0] abus; reg imc_start; reg [2:0] lid;
  always @(*) begin
    vbus = 0; abus = 0; imc_start = 1'b0; lid = 3'd0;
    case (step)
      3'd0: begin vbus = v1; abus = a1; imc_start = s1; lid = 3'd0; end
      3'd1: begin vbus = v2; abus = a2; imc_start = s2; lid = 3'd1; end
      3'd2: begin vbus = v3; abus = a3; imc_start = s3; lid = 3'd2; end
      3'd3: begin vbus = v4; abus = a4; imc_start = s4; lid = 3'd3; end
      3'd4: begin vbus = v5; abus = a5; imc_start = s5; lid = 3'd4; end
      default: ;
    endcase
  end

  // ---------------- the two IMC units ----------------
  reg        wr_en = 0; reg [5:0] wr_addr = 0; reg [31:0] wr_data = 0;
  wire signed [23:0] mres_r, mres_n; wire rv_r, rv_n;
  wire [K-1:0] sh_r, ph_r, so_r, po_r, sh_n, ph_n, so_n, po_n;
  wire cfgv_r, cfgv_n, ed_r, ed_n; wire [15:0] dt_r, dt_n;
  wire stall_n; wire [31:0] nlook, npark, nstall, nstarts; wire [2:0] errs;
  pcm_imc_unit #(.DATA_DIR(`DATA_DIR_STR), .COMMON_DIR("")) REF (
    .clk(clk), .rst_n(rst_n), .start(imc_start), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
    .layer_id(lid), .v_bus(vbus), .orig_addr_bus(abus), .mac_result(mres_r), .result_valid(rv_r),
    .cfg_valid_dbg(cfgv_r), .enable_drift_dbg(ed_r), .drift_t_dbg(dt_r),
    .sram_hit_dbg(sh_r), .pcm_hit_dbg(ph_r), .sram_oor_dbg(so_r), .pcm_oor_dbg(po_r));
  pcm_imc_unit_e8 #(.DATA_DIR(`DATA_DIR_STR), .COMMON_DIR("")) NEW (
    .clk(clk), .rst_n(rst_n), .start(imc_start), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
    .layer_id(lid), .v_bus(vbus), .orig_addr_bus(abus), .mac_result(mres_n), .result_valid(rv_n),
    .cfg_valid_dbg(cfgv_n), .enable_drift_dbg(ed_n), .drift_t_dbg(dt_n),
    .sram_hit_dbg(sh_n), .pcm_hit_dbg(ph_n), .sram_oor_dbg(so_n), .pcm_oor_dbg(po_n),
    .amu_stall_dbg(stall_n), .amu_lookup_reads(nlook), .amu_park_reads(npark),
    .amu_stall_cycles(nstall), .amu_starts(nstarts), .amu_errors(errs));
  assign rv   = `USE_NEW ? rv_n : rv_r;
  assign mres = `USE_NEW ? mres_n : mres_r;

  // ---------------- per-operation comparison ----------------
  // REF outputs at the engine start, NEW outputs at its datapath start; matched by operation number
  reg [K*16-1:0] q_sp [0:20000]; reg [K*16-1:0] q_pp [0:20000];
  reg [K-1:0] q_sh [0:20000], q_ph [0:20000], q_so [0:20000], q_po [0:20000];
  integer n_ref = 0, n_new = 0, n_bad = 0, n_hit_s = 0, n_hit_p = 0, n_oor = 0;
  always @(posedge clk) if (rst_n) begin
    if (REF.start_internal) begin
      q_sp[n_ref] = REF.sram_pool_addr_bus; q_pp[n_ref] = REF.pcm_pool_addr_bus;
      q_sh[n_ref] = sh_r; q_ph[n_ref] = ph_r; q_so[n_ref] = so_r; q_po[n_ref] = po_r;
      n_ref = n_ref + 1;
    end
    if (NEW.start_internal) begin
      if (n_new >= n_ref) begin
        n_bad = n_bad + 1;
        if (n_bad < 5) $display("op %0d: NEW started before REF", n_new);
      end else if (q_sh[n_new] !== sh_n || q_ph[n_new] !== ph_n || q_so[n_new] !== so_n || q_po[n_new] !== po_n ||
                   q_sp[n_new] !== NEW.sram_pool_addr_bus || q_pp[n_new] !== NEW.pcm_pool_addr_bus) begin
        n_bad = n_bad + 1;
        if (n_bad < 5) $display("op %0d (layer %0d, cycle %0d): MISMATCH sram hit %h/%h pcm hit %h/%h", n_new, lid, cyc,
                                q_sh[n_new], sh_n, q_ph[n_new], ph_n);
      end
      n_hit_s = n_hit_s + $countones(sh_n); n_hit_p = n_hit_p + $countones(ph_n);
      n_oor = n_oor + $countones(so_n) + $countones(po_n);
      n_new = n_new + 1;
    end
  end

  // ---------------- ROM protocol at the core outputs ----------------
  real tf [0:3]; real low_look, low_park; integer m, n_rise_look, n_rise_park;
  reg [3:0] rc_q;
  initial begin
    for (m = 0; m < 4; m = m + 1) tf[m] = -1.0e9;
    low_look = 1.0e9; low_park = 1.0e9; n_rise_look = 0; n_rise_park = 0; rc_q = 0;
  end
  always @(NEW.U_AMU.rom_clk) begin
    for (m = 0; m < 4; m = m + 1) begin
      if (NEW.U_AMU.rom_clk[m] && !rc_q[m]) begin
        if (NEW.U_AMU.rom_park) begin n_rise_park = n_rise_park + 1; if ($realtime - tf[m] < low_park) low_park = $realtime - tf[m]; end
        else                  begin n_rise_look = n_rise_look + 1; if ($realtime - tf[m] < low_look) low_look = $realtime - tf[m]; end
      end
      if (!NEW.U_AMU.rom_clk[m] && rc_q[m]) tf[m] = $realtime;
    end
    rc_q = NEW.U_AMU.rom_clk;
  end

  // ---------------- the 200 ROM macro models and the parking rule ----------------
  wire [200*32-1:0] nr_b, ecs_b, ead_b, ewd_b; wire [200*64-1:0] low_b; wire [199:0] lz_b;
  wire [50*32-1:0]  epk_b;
  genvar g, h;
  generate
    for (g = 0; g < K; g = g + 1) begin : rs
      assign epk_b[(2*g)*32 +: 32]   = NEW.U_AMU.tab[g].U_STAB.n_err_park;
      assign epk_b[(2*g+1)*32 +: 32] = NEW.U_AMU.tab[g].U_PTAB.n_err_park;
      for (h = 0; h < 4; h = h + 1) begin : mm
        assign nr_b [((2*g)*4 + h)*32 +: 32]   = NEW.U_AMU.tab[g].U_STAB.mac[h].U_ROM.n_reads;
        assign nr_b [((2*g+1)*4 + h)*32 +: 32] = NEW.U_AMU.tab[g].U_PTAB.mac[h].U_ROM.n_reads;
        assign ecs_b[((2*g)*4 + h)*32 +: 32]   = NEW.U_AMU.tab[g].U_STAB.mac[h].U_ROM.n_err_cs;
        assign ecs_b[((2*g+1)*4 + h)*32 +: 32] = NEW.U_AMU.tab[g].U_PTAB.mac[h].U_ROM.n_err_cs;
        assign ead_b[((2*g)*4 + h)*32 +: 32]   = NEW.U_AMU.tab[g].U_STAB.mac[h].U_ROM.n_err_addr;
        assign ead_b[((2*g+1)*4 + h)*32 +: 32] = NEW.U_AMU.tab[g].U_PTAB.mac[h].U_ROM.n_err_addr;
        assign ewd_b[((2*g)*4 + h)*32 +: 32]   = NEW.U_AMU.tab[g].U_STAB.mac[h].U_ROM.n_err_word;
        assign ewd_b[((2*g+1)*4 + h)*32 +: 32] = NEW.U_AMU.tab[g].U_PTAB.mac[h].U_ROM.n_err_word;
        assign low_b[((2*g)*4 + h)*64 +: 64]   = $realtobits(NEW.U_AMU.tab[g].U_STAB.mac[h].U_ROM.low_min);
        assign low_b[((2*g+1)*4 + h)*64 +: 64] = $realtobits(NEW.U_AMU.tab[g].U_PTAB.mac[h].U_ROM.low_min);
        assign lz_b [(2*g)*4 + h]              = NEW.U_AMU.tab[g].U_STAB.lk_zero[h];
        assign lz_b [(2*g+1)*4 + h]            = NEW.U_AMU.tab[g].U_PTAB.lk_zero[h];
      end
    end
  endgenerate

  // ---------------- per-layer cycle marks ----------------
  integer c_start [0:4], c_end [0:4], ops [0:4];
  integer L, tot_reads, e_cs, e_addr, e_word, e_park, n_unparked, i; real lowmin_rom, lw;
  initial begin
    for (L = 0; L < 5; L = L + 1) ops[L] = 0;
  end
  always @(posedge clk) if (imc_start && step < 5) ops[step] = ops[step] + 1;

  task run_layer;
    input [2:0] s;
    begin
      @(negedge clk); step = s;
      repeat (3) @(negedge clk);
      c_start[s] = cyc;
      case (s) 0: st_c1 = 1; 1: st_c2 = 1; 2: st_f1 = 1; 3: st_f2 = 1; 4: st_f3 = 1; endcase
      @(negedge clk); st_c1 = 0; st_c2 = 0; st_f1 = 0; st_f2 = 0; st_f3 = 0;
      case (s)
        0: wait (d1); 1: wait (d2); 2: wait (d3); 3: wait (d4); 4: wait (d5);
      endcase
      c_end[s] = cyc;
      @(negedge clk); step = 7;
      repeat (20) @(negedge clk);       // the pool layers of top_fsm: bus zero, layer 0
    end
  endtask

  task cfg;
    input [5:0] ad; input [31:0] d;
    begin @(negedge clk); wr_en = 1; wr_addr = ad; wr_data = d; @(negedge clk); wr_en = 0; end
  endtask

  initial begin
    repeat (3) @(negedge clk); rst_n = 1;
    // layer configuration: SRAM {size, base}, PCM {size, base} (values chosen to exercise the range checks)
    cfg(6'h00, {16'd150,  16'd0});    cfg(6'h01, {16'd1200, 16'd150});  cfg(6'h02, {16'd1500, 16'd1350});
    cfg(6'h03, {16'd200,  16'd2850}); cfg(6'h04, {16'd24,   16'd3050});
    cfg(6'h05, {16'd0,    16'd0});    cfg(6'h06, {16'd2400, 16'd0});    cfg(6'h07, {16'd48000, 16'd2400});
    cfg(6'h08, {16'd8000, 16'd50400}); cfg(6'h09, {16'd700, 16'd58300});
    cfg(6'h20, 32'h2);
    repeat (5) @(negedge clk);
    for (L = 0; L < 5; L = L + 1) run_layer(L);
    repeat (50) @(negedge clk);
    // ROM models: protocol counters, parking rule
    tot_reads = 0; e_cs = 0; e_addr = 0; e_word = 0; lowmin_rom = 1.0e9; e_park = 0; n_unparked = 0;
    for (i = 0; i < 200; i = i + 1) begin
      tot_reads = tot_reads + nr_b[i*32 +: 32];
      e_cs = e_cs + ecs_b[i*32 +: 32]; e_addr = e_addr + ead_b[i*32 +: 32]; e_word = e_word + ewd_b[i*32 +: 32];
      lw = $bitstoreal(low_b[i*64 +: 64]);
      if (nr_b[i*32 +: 32] > 0 && lw < lowmin_rom) lowmin_rom = lw;
      if (lz_b[i]) n_unparked = n_unparked + 1;
    end
    for (i = 0; i < 50; i = i + 1) e_park = e_park + epk_b[i*32 +: 32];
    $display("==== P2R-E8.5 sandbox: engines + REF / NEW IMC units, data %s, result_valid from %s ====", `DATA_DIR_STR, `USE_NEW ? "NEW" : "REF");
    for (L = 0; L < 5; L = L + 1)
      $display("   layer %0d: %0d operations, cycles %0d-%0d (%0d)", L, ops[L], c_start[L], c_end[L], c_end[L] - c_start[L]);
    $display("   operations: REF %0d, NEW %0d, mismatches %0d; lane hits SRAM %0d PCM %0d, out of range %0d",
             n_ref, n_new, n_bad, n_hit_s, n_hit_p, n_oor);
    $display("   address-map unit: starts %0d, stall cycles %0d, lookup read pulses %0d, parking pulses %0d, errors {queue,lane0,mismatch} %b",
             nstarts, nstall, nlook, npark, errs);
    $display("   parking rule (a table parks a macro exactly when the last word it read there has a zero bit): %0d violations; macros left unparked at the end %0d",
             e_park, n_unparked);
    $display("   ROM clock low before a pulse (core): lookup >= %0.1f ns (%0d), park >= %0.1f ns (%0d)",
             low_look, n_rise_look, low_park, n_rise_park);
    $display("   ROM models (200): reads %0d, CS at the edge %0d, address changed while high %0d, invalid word %0d, shortest low before a read %0.1f ns",
             tot_reads, e_cs, e_addr, e_word, lowmin_rom);
    $display("   engine watchdogs: %b", {t1, t2, t3, t4, t5});
    $display("   total cycles %0d", cyc);
    $finish;
  end
  initial begin #50000000; $display("TIMEOUT at cycle %0d, step %0d", cyc, step); $finish; end
endmodule
