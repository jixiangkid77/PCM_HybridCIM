//============================================================
// e9_1_amu_monitor.v   (P2R-E9.1, passive monitor)
//============================================================
// rtl/e8/tb/e8_5_amu_monitor.v for the address map of E9
// (rtl/e9/amu9_top.v). Compiled as a further top-level module next
// to the unchanged testbench tb_lenet5_full_inference_v3 and the
// unchanged monitors (rtl/tb/e8_lookup_monitor.v,
// rtl/e8/tb/e8_5c_monitor.v), with the unit rtl/e9/pcm_imc_unit_e9.v
// (-DE8_AS_PCM_IMC_UNIT). It only reads signals through hierarchical
// references and drives nothing.
//
// Writes
//   +e85_trace=<path>   one line per MAC operation at the datapath
//       start (amu start_go), the format and header of the E8.5
//       monitor, so that it can be compared with the E8.5c trace
//       byte for byte;
//   +e9_events=<path>   one line per ROM clock pulse of the unit:
//         L <phase> <cycle> <m> <addr_hex> <entry> <slot> <low>
//         P <phase> <cycle> <m> <low>
//       phase B / I / A = before the start pulse / during the
//       inference / after done; cycle = cycle_after_start of the
//       testbench at the rising edge of the ROM clock (0 before the
//       start); m = macro 0-6; addr = address in the macro (hex);
//       entry = table entry 0-2481; slot = buffer slot; low = full
//       system cycles the macro clock was low before this pulse
//       (99999 before its first read). This is the ROM read sequence
//       of the energy calculation (E9.3).
//   a check of the decoding at every operation (amu start_go): the
//       SRAM and PCM slots that amu9_decode gives each lane against the
//       E8.5 slot tables of the same entry (data/rtl_inputs_<M>_v3,
//       addr_to_slot_<layer>_<side>_lane<KK>.hex, the contents of the
//       E8.5 ROM macros; 0xFFFF on both sides for a lane that does not
//       look up the entry);
//   a summary at the end of the simulation: the unit's counters and
//       error flags; pulses per macro; the reads counted by the 7 ROM
//       models against those of the events; the ROM protocol checks
//       of the models; the shortest clock-low time before a lookup
//       and before a parking read; the parking rule (a macro reads
//       its parking word only after a lookup whose word has a zero
//       bit, and only once) and the macros left unparked at the end.
//
// Place  : rtl/e9/tb/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps
`define E9_TB  tb_lenet5_full_inference_v3
`define E9_IMC tb_lenet5_full_inference_v3.DUT.u_imc
`define E9_AMU tb_lenet5_full_inference_v3.DUT.u_imc.U_AMU

module e9_1_amu_monitor;
    localparam integer K      = 25;
    localparam integer AWIDTH = 16;
    localparam integer NM     = 7;
    integer fd_t, fd_e, ops, k, m;
    reg [8*256-1:0] fname_t, fname_e;
    initial begin
        if (!$value$plusargs("e85_trace=%s", fname_t)) fname_t = "e85_trace.txt";
        if (!$value$plusargs("e9_events=%s", fname_e)) fname_e = "e9_rom_events.txt";
        fd_t = $fopen(fname_t, "w");
        fd_e = $fopen(fname_e, "w");
        if (fd_t == 0 || fd_e == 0) begin
            $display("[E9 MONITOR] cannot open %0s or %0s", fname_t, fname_e);
            $finish;
        end
        ops = 0;
        $fdisplay(fd_t, "# P2R-E8.5 address-map lookup trace at the datapath start (amu start_go)");
        $fdisplay(fd_t, "# fields: cycle_after_start layer_id sram_base sram_size pcm_base pcm_size then 25 x addr_hex:sram_hit pcm_hit");
        $fdisplay(fd_e, "# P2R-E9.1 ROM clock pulses of the address-map unit (7 macros of 48 rows x 8 words of 40 bit)");
        $fdisplay(fd_e, "# L phase cycle macro addr_hex entry slot low_cycles   (lookup read)");
        $fdisplay(fd_e, "# P phase cycle macro low_cycles                       (parking read of address 383)");
    end

    // ---------------- trace at the datapath start (as E8.5) ----------------
    always @(negedge `E9_TB.clk) begin
        if (`E9_TB.started_flag && `E9_AMU.start_go) begin
            $fwrite(fd_t, "%0d %0d %04h %04h %04h %04h",
                    `E9_TB.cycle_after_start, `E9_IMC.layer_id,
                    `E9_IMC.sram_base_w, `E9_IMC.sram_size_w,
                    `E9_IMC.pcm_base_w,  `E9_IMC.pcm_size_w);
            for (k = 0; k < K; k = k + 1)
                $fwrite(fd_t, " %04h:%0d%0d",
                        `E9_IMC.orig_addr_bus[k*AWIDTH +: AWIDTH],
                        `E9_IMC.sram_hit_dbg[k], `E9_IMC.pcm_hit_dbg[k]);
            $fwrite(fd_t, "\n");
            ops = ops + 1;
        end
    end

    // ---------------- slot check against the E8.5 tables ----------------
`ifdef MODEL_B
    localparam DDIR = "data/rtl_inputs_B_v3";
`else
    localparam DDIR = "data/rtl_inputs_A_v3";
`endif
    reg [15:0] tabs [0:2*K*2496-1];          // [(side*K + lane)*2496 + entry]
    reg [15:0] c1 [0:5];  reg [15:0] c2 [0:95];  reg [15:0] f1 [0:1919];
    reg [15:0] f2 [0:419]; reg [15:0] f3 [0:39];
    integer sd, ln, j, base_t;
    initial begin
        for (j = 0; j < 2*K*2496; j = j + 1) tabs[j] = 16'hFFFF;
        for (sd = 0; sd < 2; sd = sd + 1)
            for (ln = 0; ln < K; ln = ln + 1) begin
                for (j = 0; j < 6;    j = j + 1) c1[j] = 16'hFFFF;
                for (j = 0; j < 96;   j = j + 1) c2[j] = 16'hFFFF;
                for (j = 0; j < 1920; j = j + 1) f1[j] = 16'hFFFF;
                for (j = 0; j < 420;  j = j + 1) f2[j] = 16'hFFFF;
                for (j = 0; j < 40;   j = j + 1) f3[j] = 16'hFFFF;
                if (sd == 0) begin
                    $readmemh($sformatf("%s/addr_to_slot_conv1_sram_lane%02d.hex", DDIR, ln), c1);
                    $readmemh($sformatf("%s/addr_to_slot_conv2_sram_lane%02d.hex", DDIR, ln), c2);
                    $readmemh($sformatf("%s/addr_to_slot_fc1_sram_lane%02d.hex",   DDIR, ln), f1);
                    $readmemh($sformatf("%s/addr_to_slot_fc2_sram_lane%02d.hex",   DDIR, ln), f2);
                    $readmemh($sformatf("%s/addr_to_slot_fc3_sram_lane%02d.hex",   DDIR, ln), f3);
                end else begin
                    $readmemh($sformatf("%s/addr_to_slot_conv1_pcm_lane%02d.hex", DDIR, ln), c1);
                    $readmemh($sformatf("%s/addr_to_slot_conv2_pcm_lane%02d.hex", DDIR, ln), c2);
                    $readmemh($sformatf("%s/addr_to_slot_fc1_pcm_lane%02d.hex",   DDIR, ln), f1);
                    $readmemh($sformatf("%s/addr_to_slot_fc2_pcm_lane%02d.hex",   DDIR, ln), f2);
                    $readmemh($sformatf("%s/addr_to_slot_fc3_pcm_lane%02d.hex",   DDIR, ln), f3);
                end
                base_t = (sd * K + ln) * 2496;
                for (j = 0; j < 6;    j = j + 1) tabs[base_t + j]        = c1[j];
                for (j = 0; j < 96;   j = j + 1) tabs[base_t + 6 + j]    = c2[j];
                for (j = 0; j < 1920; j = j + 1) tabs[base_t + 102 + j]  = f1[j];
                for (j = 0; j < 420;  j = j + 1) tabs[base_t + 2022 + j] = f2[j];
                for (j = 0; j < 40;   j = j + 1) tabs[base_t + 2442 + j] = f3[j];
            end
    end
    wire [K*16-1:0] s_slot_b, p_slot_b;
    wire [K-1:0]    valid_b = `E9_AMU.valid;
    genvar gl;
    generate
        for (gl = 0; gl < K; gl = gl + 1) begin : sl
            assign s_slot_b[gl*16 +: 16] = `E9_AMU.U_DEC.lane[gl].s_slot;
            assign p_slot_b[gl*16 +: 16] = `E9_AMU.U_DEC.lane[gl].p_slot;
        end
    endgenerate
    integer n_chk_ops = 0, n_chk_lanes = 0, n_chk_sram = 0, n_chk_pcm = 0, n_bad_s = 0, n_bad_p = 0;
    reg [15:0] xs, xp;
    always @(negedge `E9_TB.clk) begin
        if (`E9_TB.started_flag && `E9_AMU.start_go) begin
            n_chk_ops = n_chk_ops + 1;
            for (k = 0; k < K; k = k + 1) begin
                xs = valid_b[k] ? tabs[k * 2496 + `E9_AMU.e0]       : 16'hFFFF;
                xp = valid_b[k] ? tabs[(K + k) * 2496 + `E9_AMU.e0] : 16'hFFFF;
                if (valid_b[k]) n_chk_lanes = n_chk_lanes + 1;
                if (xs != 16'hFFFF) n_chk_sram = n_chk_sram + 1;
                if (xp != 16'hFFFF) n_chk_pcm  = n_chk_pcm + 1;
                if (s_slot_b[k*16 +: 16] !== xs) n_bad_s = n_bad_s + 1;
                if (p_slot_b[k*16 +: 16] !== xp) n_bad_p = n_bad_p + 1;
            end
        end
    end

    // ---------------- ROM clock pulses ----------------
    wire [NM-1:0] lz_b;                     // last_zero of the 7 ROM models
    genvar gz;
    generate for (gz = 0; gz < NM; gz = gz + 1) begin : lzb
        assign lz_b[gz] = `E9_AMU.mac[gz].U_ROM.last_zero;
    end endgenerate
    reg  [NM-1:0] rc_q = {NM{1'b0}};
    reg  [NM-1:0] lk_zero = {NM{1'b0}};     // last read of the macro was a lookup of a word with a zero bit
    reg  [NM-1:0] was_park = {NM{1'b0}};
    reg           done_q = 1'b0;
    integer    cyc = 0;
    integer    lastfall [0:NM-1];
    integer    nlook [0:NM-1];
    integer    npark [0:NM-1];
    integer    n_ev_look = 0, n_ev_park = 0, n_ev_before = 0, n_ev_after = 0, n_starts_ext = 0;
    integer    low, min_low_look = 99999, min_low_park = 99999, e_park_nozero = 0;
    reg [8*1-1:0] ph;
    initial for (m = 0; m < NM; m = m + 1) begin lastfall[m] = -1; nlook[m] = 0; npark[m] = 0; end
    always @(negedge `E9_TB.clk) begin
        cyc = cyc + 1;
        if (`E9_TB.done_seen) done_q = 1'b1;
        if (`E9_TB.started_flag && `E9_IMC.start) n_starts_ext = n_starts_ext + 1;
        ph = !`E9_TB.started_flag ? "B" : (done_q ? "A" : "I");
        for (m = 0; m < NM; m = m + 1) begin
            if (`E9_AMU.rom_clk[m] && !rc_q[m]) begin                 // rising edge of macro m's clock
                low = (lastfall[m] < 0) ? 99999 : cyc - lastfall[m];
                if (ph == "B") n_ev_before = n_ev_before + 1;
                if (ph == "A") n_ev_after  = n_ev_after + 1;
                if (`E9_AMU.rom_park) begin
                    $fwrite(fd_e, "P %0s %0d %0d %0d\n", ph, `E9_TB.cycle_after_start, m, low);
                    n_ev_park = n_ev_park + 1;
                    npark[m]  = npark[m] + 1;
                    if (low < min_low_park) min_low_park = low;
                    if (!lk_zero[m]) e_park_nozero = e_park_nozero + 1;
                    was_park[m] = 1'b1;
                end else begin
                    $fwrite(fd_e, "L %0s %0d %0d %03h %0d %0d %0d\n", ph, `E9_TB.cycle_after_start, m,
                            `E9_AMU.rom_addr, `E9_AMU.U_CORE.op_e, `E9_AMU.U_CORE.op_slot, low);
                    n_ev_look = n_ev_look + 1;
                    nlook[m]  = nlook[m] + 1;
                    if (low < min_low_look) min_low_look = low;
                    was_park[m] = 1'b0;
                end
            end
            if (!`E9_AMU.rom_clk[m] && rc_q[m]) begin                 // falling edge: the read has ended
                lastfall[m] = cyc;
                lk_zero[m]  = was_park[m] ? 1'b0 : lz_b[m];
            end
        end
        rc_q = `E9_AMU.rom_clk;
    end

    // ---------------- the 7 ROM macro models ----------------
    wire [NM*32-1:0] nr_b, np_b, ecs_b, ead_b, ewd_b;
    wire [NM*64-1:0] low_b;
    genvar g;
    generate
        for (g = 0; g < NM; g = g + 1) begin : rs
            assign nr_b [g*32 +: 32] = `E9_AMU.mac[g].U_ROM.n_reads;
            assign np_b [g*32 +: 32] = `E9_AMU.mac[g].U_ROM.n_park_reads;
            assign ecs_b[g*32 +: 32] = `E9_AMU.mac[g].U_ROM.n_err_cs;
            assign ead_b[g*32 +: 32] = `E9_AMU.mac[g].U_ROM.n_err_addr;
            assign ewd_b[g*32 +: 32] = `E9_AMU.mac[g].U_ROM.n_err_word;
            assign low_b[g*64 +: 64] = $realtobits(`E9_AMU.mac[g].U_ROM.low_min);
        end
    endgenerate

    integer i, tot_reads, tot_park_m, e_cs, e_addr, e_word, n_unparked;
    real    lowmin, lw;
    final begin
        tot_reads = 0; tot_park_m = 0; e_cs = 0; e_addr = 0; e_word = 0; lowmin = 1.0e9; n_unparked = 0;
        for (i = 0; i < NM; i = i + 1) begin
            if (lk_zero[i]) n_unparked = n_unparked + 1;
            tot_reads  = tot_reads  + nr_b[i*32 +: 32];
            tot_park_m = tot_park_m + np_b[i*32 +: 32];
            e_cs       = e_cs       + ecs_b[i*32 +: 32];
            e_addr     = e_addr     + ead_b[i*32 +: 32];
            e_word     = e_word     + ewd_b[i*32 +: 32];
            lw         = $bitstoreal(low_b[i*64 +: 64]);
            if (nr_b[i*32 +: 32] != 0 && lw < lowmin) lowmin = lw;
        end
        $fdisplay(fd_t, "# mac_operations %0d", ops);
        $fdisplay(fd_e, "# lookup pulses %0d, parking pulses %0d", n_ev_look, n_ev_park);
        $fclose(fd_t);
        $fclose(fd_e);
        $display("");
        $display("[E9 MONITOR] ==== address-map unit (E9.1) ====");
        $display("[E9 MONITOR] operations at the datapath start %0d, engine start pulses %0d -> trace %0s",
                 ops, n_starts_ext, fname_t);
        $display("[E9 MONITOR] unit counters: starts %0d, stall cycles %0d, lookup pulses %0d, parking pulses %0d",
                 `E9_AMU.n_starts, `E9_AMU.n_stall_cycles, `E9_AMU.n_lookup_reads, `E9_AMU.n_park_reads);
        $display("[E9 MONITOR] error flags {queue,lane0,mismatch} %b; parking reads without a zero bit to park %0d; macros unparked at the end %0d",
                 `E9_AMU.errors, e_park_nozero, n_unparked);
        $display("[E9 MONITOR] ROM pulses in the event list: lookup %0d, parking %0d (before start %0d, after done %0d) -> %0s",
                 n_ev_look, n_ev_park, n_ev_before, n_ev_after, fname_e);
        for (i = 0; i < NM; i = i + 1)
            $display("[E9 MONITOR]    macro %0d: lookup %0d, parking %0d; model reads %0d (parking word %0d)",
                     i, nlook[i], npark[i], nr_b[i*32 +: 32], np_b[i*32 +: 32]);
        $display("[E9 MONITOR] macro reads counted by the 7 models: %0d (%0s), of them the parking word %0d (%0s)",
                 tot_reads, (tot_reads == n_ev_look + n_ev_park) ? "equal to the events" : "DIFFERENT from the events",
                 tot_park_m, (tot_park_m == n_ev_park) ? "equal" : "DIFFERENT");
        $display("[E9 MONITOR] ROM protocol at the models: CS at the clock edge %0d, address changed while high %0d, invalid word %0d, shortest clock low before a read %0.1f ns",
                 e_cs, e_addr, e_word, lowmin);
        $display("[E9 MONITOR] shortest clock low before a lookup %0d cycles, before a parking read %0d cycles",
                 min_low_look, min_low_park);
        $display("[E9 MONITOR] slot check at %0d operations: %0d lane lookups (SRAM %0d, PCM %0d); slots different from the E8.5 tables: SRAM %0d, PCM %0d",
                 n_chk_ops, n_chk_lanes, n_chk_sram, n_chk_pcm, n_bad_s, n_bad_p);
    end

endmodule
