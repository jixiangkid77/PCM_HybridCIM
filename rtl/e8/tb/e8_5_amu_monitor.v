//============================================================
// e8_5_amu_monitor.v   (P2R-E8.5, passive monitor)
//============================================================
// Compiled as a further top-level module next to the unchanged
// testbench tb_lenet5_full_inference_v3 and the unchanged E8.2
// monitor (rtl/tb/e8_lookup_monitor.v), when pcm_imc_unit is the
// E8.5 version (rtl/e8/pcm_imc_unit_e8.v, -DE8_AS_PCM_IMC_UNIT).
// It only reads signals through hierarchical references and
// drives nothing.
//
// Writes
//   +e85_trace=<path>   one line per MAC operation, sampled when
//       the operation reaches the datapath (amu_top.start_go), in
//       the format of the E8.2 monitor:
//         <cycle> <layer_id> <sb> <ss> <pb> <ps> <a0>:<s0><p0> ...
//       With no stall it equals the E8.2 monitor's line, which is
//       taken at the engine's start pulse.
//   +e85_events=<path>  one line per ROM clock pulse of the unit:
//         L <phase> <cycle> <m> <addr> <entry> <slot> <lanes>
//         P <phase> <cycle> <m> <park_sram> <park_pcm>
//       phase B / I / A = before the start pulse / during the
//       inference / after done; cycle = cycle_after_start of the
//       testbench at the rising edge of the ROM clock (0 before
//       the start); m = macro index 0-3; addr = row*16 + word
//       (hex); entry = table entry 0-2481; slot = buffer slot;
//       lanes = lanes whose two tables read (hex, bit k = lane k);
//       park_sram / park_pcm = tables that read their parking word.
//   a summary at the end of the simulation (final block): the
//       unit's counters and error flags, the reads counted by the
//       200 ROM macro models against those implied by the events,
//       the ROM protocol checks of the models, the parking rule
//       (a table reads its parking word exactly when the last
//       word its macro returned has a zero bit; checked at every
//       parking pulse) and the macros left unparked at the end.
//
// Place  : rtl/e8/tb/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

`define E85_TB  tb_lenet5_full_inference_v3
`define E85_IMC tb_lenet5_full_inference_v3.DUT.u_imc
`define E85_AMU tb_lenet5_full_inference_v3.DUT.u_imc.U_AMU

module e8_5_amu_monitor;

    localparam integer K      = 25;
    localparam integer AWIDTH = 16;

    integer fd_t, fd_e, ops, k, m;
    reg [8*256-1:0] fname_t, fname_e;

    initial begin
        if (!$value$plusargs("e85_trace=%s", fname_t))  fname_t = "e85_trace.txt";
        if (!$value$plusargs("e85_events=%s", fname_e)) fname_e = "e85_rom_events.txt";
        fd_t = $fopen(fname_t, "w");
        fd_e = $fopen(fname_e, "w");
        if (fd_t == 0 || fd_e == 0) begin
            $display("[E8.5 MONITOR] cannot open %0s or %0s", fname_t, fname_e);
            $finish;
        end
        ops = 0;
        $fdisplay(fd_t, "# P2R-E8.5 address-map lookup trace at the datapath start (amu start_go)");
        $fdisplay(fd_t, "# fields: cycle_after_start layer_id sram_base sram_size pcm_base pcm_size then 25 x addr_hex:sram_hit pcm_hit");
        $fdisplay(fd_e, "# P2R-E8.5 ROM clock pulses of the address-map unit");
        $fdisplay(fd_e, "# L phase cycle macro addr_hex entry slot lanes_hex   (lookup read: the SRAM and PCM tables of these lanes)");
        $fdisplay(fd_e, "# P phase cycle macro park_sram_hex park_pcm_hex      (parking read of these tables)");
    end

    // ---------------- trace at the datapath start ----------------
    always @(negedge `E85_TB.clk) begin
        if (`E85_TB.started_flag && `E85_AMU.start_go) begin
            $fwrite(fd_t, "%0d %0d %04h %04h %04h %04h",
                    `E85_TB.cycle_after_start, `E85_IMC.layer_id,
                    `E85_IMC.sram_base_w, `E85_IMC.sram_size_w,
                    `E85_IMC.pcm_base_w,  `E85_IMC.pcm_size_w);
            for (k = 0; k < K; k = k + 1)
                $fwrite(fd_t, " %04h:%0d%0d",
                        `E85_IMC.orig_addr_bus[k*AWIDTH +: AWIDTH],
                        `E85_IMC.sram_hit_dbg[k], `E85_IMC.pcm_hit_dbg[k]);
            $fwrite(fd_t, "\n");
            ops = ops + 1;
        end
    end

    // ---------------- ROM clock pulses ----------------
    reg  [K-1:0] pk_s, pk_p;                 // tables that read their parking word in this pulse
    genvar g, h;

    reg  [3:0] rc_q = 4'd0;
    reg        done_q = 1'b0;
    integer    n_ev_look = 0, n_ev_park = 0, rd_look = 0, rd_park = 0;
    integer    n_ev_before = 0, n_ev_after = 0, n_starts_ext = 0;
    reg [8*1-1:0] ph;
    always @(negedge `E85_TB.clk) begin
        if (`E85_TB.done_seen) done_q = 1'b1;
        if (`E85_TB.started_flag && `E85_IMC.start) n_starts_ext = n_starts_ext + 1;
        ph = !`E85_TB.started_flag ? "B" : (done_q ? "A" : "I");
        for (m = 0; m < 4; m = m + 1) begin
            if (`E85_AMU.rom_clk[m] && !rc_q[m]) begin
                if (ph == "B") n_ev_before = n_ev_before + 1;
                if (ph == "A") n_ev_after  = n_ev_after + 1;
                if (`E85_AMU.rom_park) begin
                    pk_s = `E85_AMU.pflags[m*2*K +: K];
                    pk_p = `E85_AMU.pflags[m*2*K + K +: K];
                    $fwrite(fd_e, "P %0s %0d %0d %07h %07h\n", ph, `E85_TB.cycle_after_start, m, pk_s, pk_p);
                    n_ev_park = n_ev_park + 1;
                    rd_park   = rd_park + $countones(pk_s) + $countones(pk_p);
                end else begin
                    $fwrite(fd_e, "L %0s %0d %0d %03h %0d %0d %07h\n", ph, `E85_TB.cycle_after_start, m,
                            `E85_AMU.rom_addr, `E85_AMU.U_CORE.op_e, `E85_AMU.U_CORE.op_slot, `E85_AMU.lane_en);
                    n_ev_look = n_ev_look + 1;
                    rd_look   = rd_look + 2 * $countones(`E85_AMU.lane_en);
                end
            end
        end
        rc_q = `E85_AMU.rom_clk;
    end

    // ---------------- the 200 ROM macro models ----------------
    wire [200*32-1:0] nr_b, ecs_b, ead_b, ewd_b;
    wire [200*64-1:0] low_b;
    wire [199:0]      lz_b;
    wire [50*32-1:0]  epk_b;
    generate
        for (g = 0; g < K; g = g + 1) begin : rs
            assign epk_b[(2*g)*32 +: 32]   = `E85_AMU.tab[g].U_STAB.n_err_park;
            assign epk_b[(2*g+1)*32 +: 32] = `E85_AMU.tab[g].U_PTAB.n_err_park;
            for (h = 0; h < 4; h = h + 1) begin : mm
                assign lz_b[(2*g)*4 + h]   = `E85_AMU.tab[g].U_STAB.lk_zero[h];
                assign lz_b[(2*g+1)*4 + h] = `E85_AMU.tab[g].U_PTAB.lk_zero[h];
                assign nr_b [((2*g)*4 + h)*32 +: 32]   = `E85_AMU.tab[g].U_STAB.mac[h].U_ROM.n_reads;
                assign nr_b [((2*g+1)*4 + h)*32 +: 32] = `E85_AMU.tab[g].U_PTAB.mac[h].U_ROM.n_reads;
                assign ecs_b[((2*g)*4 + h)*32 +: 32]   = `E85_AMU.tab[g].U_STAB.mac[h].U_ROM.n_err_cs;
                assign ecs_b[((2*g+1)*4 + h)*32 +: 32] = `E85_AMU.tab[g].U_PTAB.mac[h].U_ROM.n_err_cs;
                assign ead_b[((2*g)*4 + h)*32 +: 32]   = `E85_AMU.tab[g].U_STAB.mac[h].U_ROM.n_err_addr;
                assign ead_b[((2*g+1)*4 + h)*32 +: 32] = `E85_AMU.tab[g].U_PTAB.mac[h].U_ROM.n_err_addr;
                assign ewd_b[((2*g)*4 + h)*32 +: 32]   = `E85_AMU.tab[g].U_STAB.mac[h].U_ROM.n_err_word;
                assign ewd_b[((2*g+1)*4 + h)*32 +: 32] = `E85_AMU.tab[g].U_PTAB.mac[h].U_ROM.n_err_word;
                assign low_b[((2*g)*4 + h)*64 +: 64]   = $realtobits(`E85_AMU.tab[g].U_STAB.mac[h].U_ROM.low_min);
                assign low_b[((2*g+1)*4 + h)*64 +: 64] = $realtobits(`E85_AMU.tab[g].U_PTAB.mac[h].U_ROM.low_min);
            end
        end
    endgenerate

    integer i, tot_reads, e_cs, e_addr, e_word, n_unread, e_park, n_unparked;
    real    lowmin, lw;
    final begin
        tot_reads = 0; e_cs = 0; e_addr = 0; e_word = 0; n_unread = 0; lowmin = 1.0e9; e_park = 0; n_unparked = 0;
        for (i = 0; i < 50; i = i + 1) e_park = e_park + epk_b[i*32 +: 32];
        for (i = 0; i < 200; i = i + 1) begin
            if (lz_b[i]) n_unparked = n_unparked + 1;
            tot_reads = tot_reads + nr_b[i*32 +: 32];
            e_cs      = e_cs      + ecs_b[i*32 +: 32];
            e_addr    = e_addr    + ead_b[i*32 +: 32];
            e_word    = e_word    + ewd_b[i*32 +: 32];
            lw        = $bitstoreal(low_b[i*64 +: 64]);
            if (nr_b[i*32 +: 32] == 0) n_unread = n_unread + 1;
            else if (lw < lowmin) lowmin = lw;
        end
        $fdisplay(fd_t, "# mac_operations %0d", ops);
        $fdisplay(fd_e, "# lookup pulses %0d, parking pulses %0d", n_ev_look, n_ev_park);
        $fclose(fd_t);
        $fclose(fd_e);
        $display("");
        $display("[E8.5 MONITOR] ==== address-map unit (E8.5) ====");
        $display("[E8.5 MONITOR] operations at the datapath start %0d, engine start pulses %0d -> trace %0s",
                 ops, n_starts_ext, fname_t);
        $display("[E8.5 MONITOR] unit counters: starts %0d, stall cycles %0d, lookup pulses %0d, parking pulses %0d",
                 `E85_AMU.n_starts, `E85_AMU.n_stall_cycles, `E85_AMU.n_lookup_reads, `E85_AMU.n_park_reads);
        $display("[E8.5 MONITOR] error flags {queue,lane0,mismatch} %b; parking rule violations %0d; macros unparked at the end %0d",
                 `E85_AMU.errors, e_park, n_unparked);
        $display("[E8.5 MONITOR] ROM pulses in the event list: lookup %0d, parking %0d (before start %0d, after done %0d) -> %0s",
                 n_ev_look, n_ev_park, n_ev_before, n_ev_after, fname_e);
        $display("[E8.5 MONITOR] macro reads implied by the events: lookup %0d + parking %0d = %0d",
                 rd_look, rd_park, rd_look + rd_park);
        $display("[E8.5 MONITOR] macro reads counted by the 200 models: %0d (%0s); models never read %0d",
                 tot_reads, (tot_reads == rd_look + rd_park) ? "equal" : "DIFFERENT", n_unread);
        $display("[E8.5 MONITOR] ROM protocol at the models: CS at the clock edge %0d, address changed while high %0d, invalid word %0d, shortest clock low before a read %0.1f ns",
                 e_cs, e_addr, e_word, lowmin);
    end

endmodule
