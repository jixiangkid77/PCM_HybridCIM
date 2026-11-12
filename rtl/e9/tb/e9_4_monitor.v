//============================================================
// e9_4_monitor.v   (P2R-E9.4: gate-level run of the address-map unit of E9)
//============================================================
// Extra top module of the full-inference run (rtl/tb/
// tb_lenet5_full_inference_v3.v) in which U_AMU is the synthesised
// address-map unit of E9.1 (the logic netlist "core" + the 7 ROM
// models, written by scripts/e9_4_amu_energy.sh). Only observes;
// drives nothing. It uses only ports of U_AMU and signals of the unit,
// which exist at gate level as in RTL (rtl/e9/tb/e9_1_amu_monitor.v
// also reads signals inside the unit and cannot be used here).
//   1. +e85_trace=<file>: the E8.5 trace at the datapath start, line
//      for line as rtl/e9/tb/e9_1_amu_monitor.v writes it (header, one
//      line per start_go, "# mac_operations" at the end); compared
//      byte for byte with E8.5c.
//   2. +e9_vcd=<file>: $dumpvars(2, ...U_AMU.core) -- the nets of the
//      logic netlist and the ports of its cells, as E8.7 dumps DUT.core
//      and E10.2a U_SPOOL.core -- from the rising clock edge at which
//      the start pulse is sampled to the end of the run (the testbench
//      finishes at the falling edge after the one at which it sees
//      done, 5 ns after that edge); the window of rtl/e10/tb/
//      e10_2a_vcd.v. At the end (final) one line with the window and
//      the done edge, which scripts/e9_4_tools.py judge checks against
//      the power.
// Place  : rtl/e9/tb/
// Status : NEW FILE.
//============================================================
`timescale 1ns/1ps
`define E94_TB  tb_lenet5_full_inference_v3
`define E94_IMC tb_lenet5_full_inference_v3.DUT.u_imc

module e9_4_monitor;
    localparam integer K      = 25;
    localparam integer AWIDTH = 16;

    // ---------------- 1. trace at the datapath start (as E8.5 and E9.1) ----------------
    integer fd_t = 0, ops = 0, k;
    reg [8*256-1:0] fname_t;
    initial begin
        if ($value$plusargs("e85_trace=%s", fname_t)) begin
            fd_t = $fopen(fname_t, "w");
            if (fd_t == 0) begin
                $display("[E9.4 MONITOR] cannot open %0s", fname_t);
                $finish;
            end
            $fdisplay(fd_t, "# P2R-E8.5 address-map lookup trace at the datapath start (amu start_go)");
            $fdisplay(fd_t, "# fields: cycle_after_start layer_id sram_base sram_size pcm_base pcm_size then 25 x addr_hex:sram_hit pcm_hit");
        end
    end
    always @(negedge `E94_TB.clk) begin
        if (fd_t != 0 && `E94_TB.started_flag && `E94_IMC.U_AMU.start_go) begin
            $fwrite(fd_t, "%0d %0d %04h %04h %04h %04h",
                    `E94_TB.cycle_after_start, `E94_IMC.layer_id,
                    `E94_IMC.sram_base_w, `E94_IMC.sram_size_w,
                    `E94_IMC.pcm_base_w,  `E94_IMC.pcm_size_w);
            for (k = 0; k < K; k = k + 1)
                $fwrite(fd_t, " %04h:%0d%0d",
                        `E94_IMC.orig_addr_bus[k*AWIDTH +: AWIDTH],
                        `E94_IMC.sram_hit_dbg[k], `E94_IMC.pcm_hit_dbg[k]);
            $fwrite(fd_t, "\n");
            ops = ops + 1;
        end
    end

    // ---------------- 2. waveform of the logic netlist ----------------
    reg [8*512-1:0] fname_v;
    reg     want = 1'b0, on = 1'b0;
    real    t_on = -1.0, t_done = -1.0;
    integer n_on = -1, n_done = -1;
    initial want = $value$plusargs("e9_vcd=%s", fname_v);
    always @(posedge `E94_TB.clk) begin
        if (want && !on && (`E94_TB.start === 1'b1 || `E94_TB.started_flag === 1'b1)) begin
            $dumpfile(fname_v);
            $dumpvars(2, tb_lenet5_full_inference_v3.DUT.u_imc.U_AMU.core);
            on   = 1'b1;
            t_on = $realtime;
            n_on = `E94_TB.cycle_after_start;
        end
        // the edge at which the testbench sees done (same condition as its done capture)
        if (on && t_done < 0.0 && `E94_TB.DUT.done === 1'b1 && `E94_TB.done_seen !== 1'b1) begin
            t_done = $realtime;
            n_done = `E94_TB.cycle_after_start;
        end
    end

    final begin
        if (fd_t != 0) begin
            $fdisplay(fd_t, "# mac_operations %0d", ops);
            $fclose(fd_t);
        end
        if (want)
            $display("E9.4 VCD: from %0.1f ns (cycle_after_start %0d) to %0.1f ns (end of the run); done seen at %0.1f ns (done_cycle %0d)",
                     t_on, n_on, $realtime, t_done, n_done);
        $display("E9.4 MONITOR: operations at the datapath start %0d", ops);
    end
endmodule
