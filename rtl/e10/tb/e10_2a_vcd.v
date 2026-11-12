//============================================================
// e10_2a_vcd.v   (P2R-E10.2a: waveform of the pool logic over one inference)
//============================================================
// Extra top module of the full-inference run (rtl/tb/
// tb_lenet5_full_inference_v3.v) in which U_SPOOL is the synthesised
// banked pool (the logic netlist "core" + the 25 bank models, written
// by scripts/e10_2a_pool_energy.sh). With +e10_vcd=<file> it dumps
// $dumpvars(2, ...U_SPOOL.core) -- the nets of the logic netlist and
// the ports of its cells, as E8.7 dumps DUT.core -- from the rising
// clock edge at which the start pulse is sampled (the first edge of
// the E8.7 window) to the end of the run: the testbench finishes at
// the falling edge after the one at which it sees done (done_seen),
// 5 ns after the edge at which done is first high. (E8.7 ended one
// clock later, 15 ns after that edge: one cycle of 617,575.)
// At the end of the run (final) it prints one line with the window and
// the done edge, which scripts/e10_2a_tools.py judge checks against
// the waveform. Only observes; drives nothing.
// Place  : rtl/e10/tb/
// Status : NEW FILE.
//============================================================
`timescale 1ns/1ps

module e10_2a_vcd;
    reg [8*512-1:0] fname;
    reg     want = 1'b0, on = 1'b0;
    real    t_on = -1.0, t_done = -1.0;
    integer n_on = -1, n_done = -1;
    initial want = $value$plusargs("e10_vcd=%s", fname);
    always @(posedge tb_lenet5_full_inference_v3.clk) begin
        if (want && !on && (tb_lenet5_full_inference_v3.start === 1'b1 ||
                            tb_lenet5_full_inference_v3.started_flag === 1'b1)) begin
            $dumpfile(fname);
            $dumpvars(2, tb_lenet5_full_inference_v3.DUT.u_imc.U_SPOOL.core);
            on   = 1'b1;
            t_on = $realtime;
            n_on = tb_lenet5_full_inference_v3.cycle_after_start;
        end
        // the edge at which the testbench sees done (same condition as its done capture)
        if (on && t_done < 0.0 && tb_lenet5_full_inference_v3.DUT.done === 1'b1 &&
            tb_lenet5_full_inference_v3.done_seen !== 1'b1) begin
            t_done = $realtime;
            n_done = tb_lenet5_full_inference_v3.cycle_after_start;
        end
    end
    final if (want)
        $display("E10.2a VCD: from %0.1f ns (cycle_after_start %0d) to %0.1f ns (end of the run); done seen at %0.1f ns (done_cycle %0d)",
                 t_on, n_on, $realtime, t_done, n_done);
endmodule
