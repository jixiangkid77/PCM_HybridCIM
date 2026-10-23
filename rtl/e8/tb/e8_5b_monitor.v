//============================================================
// e8_5b_monitor.v   (P2R-E8.5b, passive monitor)
//============================================================
// Compiled as a further top-level module next to the unchanged
// testbench tb_lenet5_full_inference_v3 and the unchanged E8.2
// monitor (rtl/tb/e8_lookup_monitor.v), with the E8.5 unit
// (rtl/e8/pcm_imc_unit_e8.v, -DE8_AS_PCM_IMC_UNIT) and the ROM
// model rtl/e8/e8_rom_r48_rec.v. The same monitor serves the RTL
// run and the gate-level run of the address-map unit: it reads only
// signals that exist in both (the ports of amu_top and signals of
// pcm_imc_unit and of the testbench), and the ROM models report
// their reads to it by the tasks below.
//
// Writes
//   +e85b_trace=<path>  one line per MAC operation at the datapath
//       start (amu_top.start_go), in the format of the E8.5 monitor
//       (rtl/e8/tb/e8_5_amu_monitor.v), so it can be compared with
//       E8.5's e85_trace_<M>.txt line by line
//   +e85b_reads=<path>  one line per ROM macro read:
//         R <phase> <cycle> <t_ps> <side> <lane> <macro> <addr_hex> <low_ps>
//       phase B / I / A = before the start pulse / during the
//       inference / after done; cycle = cycle_after_start of the
//       testbench; t_ps = simulation time of the read in ps (the RTL
//       run and the gate-level run are compared by the time: the
//       cycle number can differ by one between them, because the
//       order of events within one time step differs); side 0 =
//       SRAM, 1 = PCM; addr = row*16 + word; low_ps = clock-low time
//       of the macro before this read
//   +e85b_vcd=<path>    if given: a waveform of the address-map unit
//       from the first clock after the start pulse to the end of the
//       simulation (the testbench ends one clock after done), for the
//       power analysis. Gate-level run (compiled with -DE85B_GATE):
//       $dumpvars(2, ... U_AMU.U_GL), i.e. the nets of the flattened
//       netlist and the port nets of every cell instance one level
//       below (OpenSTA finds the activity of a pin by the name
//       <instance>/<pin>); not the nets inside the cell models.
//       Otherwise $dumpvars of U_AMU and below.
//   a summary at the end (final block).
//
// Place  : rtl/e8/tb/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

`define E85B_TB  tb_lenet5_full_inference_v3
`define E85B_IMC tb_lenet5_full_inference_v3.DUT.u_imc
`define E85B_AMU tb_lenet5_full_inference_v3.DUT.u_imc.U_AMU

module e8_5b_monitor;

    localparam integer K      = 25;
    localparam integer AWIDTH = 16;

    integer fd_t, fd_r, ops, k;
    reg [8*256-1:0] fname_t, fname_r, fname_v;
    reg     want_vcd, dumping, done_q;
    integer n_rd_b, n_rd_i, n_rd_a, n_err_cs, n_err_addr, n_err_word, n_nodata;
    integer n_rd_side [0:1];
    reg [63:0] low_min_ps;
    real    t_dump_ns;

    initial begin
        if (!$value$plusargs("e85b_trace=%s", fname_t)) fname_t = "e85b_trace.txt";
        if (!$value$plusargs("e85b_reads=%s", fname_r)) fname_r = "e85b_reads.txt";
        want_vcd = $value$plusargs("e85b_vcd=%s", fname_v);
        fd_t = $fopen(fname_t, "w");
        fd_r = $fopen(fname_r, "w");
        if (fd_t == 0 || fd_r == 0) begin
            $display("[E8.5b MONITOR] cannot open %0s or %0s", fname_t, fname_r);
            $finish;
        end
        ops = 0; dumping = 1'b0; done_q = 1'b0; t_dump_ns = -1.0;
        n_rd_b = 0; n_rd_i = 0; n_rd_a = 0; n_err_cs = 0; n_err_addr = 0; n_err_word = 0; n_nodata = 0;
        n_rd_side[0] = 0; n_rd_side[1] = 0;
        low_min_ps = 64'hFFFF_FFFF_FFFF_FFFF;
        $fdisplay(fd_t, "# P2R-E8.5 address-map lookup trace at the datapath start (amu start_go)");
        $fdisplay(fd_t, "# fields: cycle_after_start layer_id sram_base sram_size pcm_base pcm_size then 25 x addr_hex:sram_hit pcm_hit");
        $fdisplay(fd_r, "# P2R-E8.5b ROM macro reads: R phase cycle t_ps side lane macro addr_hex low_ps");
    end

    // ---------------- trace at the datapath start (as the E8.5 monitor) ----------------
    always @(negedge `E85B_TB.clk) begin
        if (`E85B_TB.started_flag && `E85B_AMU.start_go) begin
            $fwrite(fd_t, "%0d %0d %04h %04h %04h %04h",
                    `E85B_TB.cycle_after_start, `E85B_IMC.layer_id,
                    `E85B_IMC.sram_base_w, `E85B_IMC.sram_size_w,
                    `E85B_IMC.pcm_base_w,  `E85B_IMC.pcm_size_w);
            for (k = 0; k < K; k = k + 1)
                $fwrite(fd_t, " %04h:%0d%0d",
                        `E85B_IMC.orig_addr_bus[k*AWIDTH +: AWIDTH],
                        `E85B_IMC.sram_hit_dbg[k], `E85B_IMC.pcm_hit_dbg[k]);
            $fwrite(fd_t, "\n");
            ops = ops + 1;
        end
    end

    // ---------------- waveform of the unit, from the first clock after the start ----------------
    always @(negedge `E85B_TB.clk) begin
        if (`E85B_TB.done_seen) done_q = 1'b1;
        if (want_vcd && !dumping && `E85B_TB.started_flag) begin
            dumping   = 1'b1;
            t_dump_ns = $realtime;
            $dumpfile(fname_v);
`ifdef E85B_GATE
            $dumpvars(2, `E85B_AMU.U_GL);
`else
            $dumpvars(0, `E85B_AMU);
`endif
        end
    end

    // ---------------- reports of the ROM models ----------------
    task rom_read(input integer side, input integer lane, input integer macro, input [9:0] addr,
                  input [63:0] low_ps);
        reg [8*1-1:0] ph;
        reg [63:0]    t_ps;
        begin
            ph   = !`E85B_TB.started_flag ? "B" : (done_q ? "A" : "I");
            t_ps = $realtime * 1000.0;       // the module time unit is 1 ns
            $fwrite(fd_r, "R %0s %0d %0d %0d %0d %0d %03h %0d\n", ph, `E85B_TB.cycle_after_start, t_ps, side, lane,
                    macro, addr, low_ps);
            if (ph == "B") n_rd_b = n_rd_b + 1;
            else if (ph == "A") n_rd_a = n_rd_a + 1;
            else n_rd_i = n_rd_i + 1;
            n_rd_side[side] = n_rd_side[side] + 1;
            if (low_ps < low_min_ps) low_min_ps = low_ps;
        end
    endtask
    task rom_err(input integer side, input integer lane, input integer macro, input integer code);
        begin
            if (code == 0) n_err_cs = n_err_cs + 1;
            else if (code == 1) n_err_addr = n_err_addr + 1;
            else n_err_word = n_err_word + 1;
            $display("[E8.5b MONITOR] ROM protocol error %0d at side %0d lane %0d macro %0d, time %0t",
                     code, side, lane, macro, $time);
        end
    endtask
    task rom_nodata(input integer side, input integer lane, input integer macro);
        begin
            n_nodata = n_nodata + 1;
            $display("[E8.5b MONITOR] ROM model side %0d lane %0d macro %0d has no DATA_DIR (contents all 0xFFFF)",
                     side, lane, macro);
        end
    endtask

    final begin
        $fdisplay(fd_t, "# mac_operations %0d", ops);
        $fdisplay(fd_r, "# reads before start %0d, during inference %0d, after done %0d", n_rd_b, n_rd_i, n_rd_a);
        $fclose(fd_t);
        $fclose(fd_r);
        $display("");
        $display("[E8.5b MONITOR] ==== address-map unit (E8.5b) ====");
        $display("[E8.5b MONITOR] operations at the datapath start %0d -> trace %0s", ops, fname_t);
        $display("[E8.5b MONITOR] unit port counters: starts %0d, stall cycles %0d, lookup pulses %0d, parking pulses %0d; error flags {queue,lane0,mismatch} %b",
                 `E85B_AMU.n_starts, `E85B_AMU.n_stall_cycles, `E85B_AMU.n_lookup_reads, `E85B_AMU.n_park_reads,
                 `E85B_AMU.errors);
        $display("[E8.5b MONITOR] ROM macro reads: before start %0d, during inference %0d, after done %0d (SRAM side %0d, PCM side %0d) -> %0s",
                 n_rd_b, n_rd_i, n_rd_a, n_rd_side[0], n_rd_side[1], fname_r);
        $display("[E8.5b MONITOR] ROM protocol errors: CS at the clock edge %0d, address changed while high %0d, invalid word %0d; models without data %0d; shortest clock low before a read %0d ps",
                 n_err_cs, n_err_addr, n_err_word, n_nodata, low_min_ps);
        if (want_vcd)
            $display("[E8.5b MONITOR] waveform %0s: from %0.1f ns to %0.1f ns (%0.1f ns)", fname_v, t_dump_ns,
                     $realtime, $realtime - t_dump_ns);
        else
            $display("[E8.5b MONITOR] no waveform");
    end

endmodule
