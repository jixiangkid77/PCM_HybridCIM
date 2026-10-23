//============================================================
// e8_5c_monitor.v   (P2R-E8.5c, passive monitor)
//============================================================
// Compiled as a further top-level module next to the unchanged
// testbench tb_lenet5_full_inference_v3, the unchanged E8.2
// monitor (rtl/tb/e8_lookup_monitor.v) and the E8.5 monitor
// (rtl/e8/tb/e8_5_amu_monitor.v). Used with both designs that
// E8.5c compares:
//   base : the E8.5 unit (rtl/e8/pcm_imc_unit_e8.v) with
//          rtl/src/sram_pool_25lane.v
//   new  : rtl/e8/pcm_imc_unit_e8s.v with
//          rtl/e8/sram_pool_25lane_2c.v (two-cycle SRAM read),
//          also with -DE85C_READ_ONCE (pool read only in the
//          cycle of the datapath start)
//   (both with the unchanged rtl/src/lenet5_top.v)
// It only reads signals through hierarchical references and
// drives nothing.
//
// Writes
//   +e85c_results=<path>  one line per result of the unit
//       (result_valid, sampled on the falling clock edge):
//         <cycle_after_start> <mac_result, signed decimal>
//   a summary at the end of the simulation (final block):
//     - SRAM_LATENCY of the unit and ALIGN_DELAY of its combiner
//     - results written; datapath starts (start_internal)
//     - SRAM reads = lanes with sram_hit at the datapath start
//     - shortest interval between two SRAM reads of one lane
//       (cycles; the two-cycle read needs at least 2) and the
//       number of intervals below 2
//     - cycles in which the pool sees a hit while the datapath
//       start is low (0 with -DE85C_READ_ONCE)
//
// Place  : rtl/e8/tb/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

`define E85C_TB  tb_lenet5_full_inference_v3
`define E85C_IMC tb_lenet5_full_inference_v3.DUT.u_imc

module e8_5c_monitor;

    localparam integer K = 25;

    integer fd, nres, nstart, nreads, k;
    integer last_read [0:K-1];
    integer min_gap, min_gap_lane, n_short, gap;
    integer hit_off_start;
    reg [8*256-1:0] fname;

    initial begin
        if (!$value$plusargs("e85c_results=%s", fname)) fname = "e85c_results.txt";
        fd = $fopen(fname, "w");
        if (fd == 0) begin
            $display("[E8.5c MONITOR] cannot open %0s", fname);
            $finish;
        end
        $fdisplay(fd, "# P2R-E8.5c results of the unit: cycle_after_start mac_result");
        nres = 0; nstart = 0; nreads = 0;
        min_gap = 32'h7fffffff; min_gap_lane = -1; n_short = 0;
        hit_off_start = 0;
        for (k = 0; k < K; k = k + 1) last_read[k] = -1;
    end

    always @(negedge `E85C_TB.clk) begin
        if (`E85C_TB.started_flag) begin
            if (`E85C_IMC.result_valid) begin
                $fdisplay(fd, "%0d %0d", `E85C_TB.cycle_after_start, $signed(`E85C_IMC.mac_result));
                nres = nres + 1;
            end
            if (`E85C_IMC.start_internal) begin
                nstart = nstart + 1;
                for (k = 0; k < K; k = k + 1) begin
                    if (`E85C_IMC.sram_hit_dbg[k]) begin
                        nreads = nreads + 1;
                        if (last_read[k] >= 0) begin
                            gap = `E85C_TB.cycle_after_start - last_read[k];
                            if (gap < min_gap) begin
                                min_gap = gap;
                                min_gap_lane = k;
                            end
                            if (gap < 2) n_short = n_short + 1;
                        end
                        last_read[k] = `E85C_TB.cycle_after_start;
                    end
                end
            end else if (|`E85C_IMC.U_SPOOL.hit_bus) begin
                hit_off_start = hit_off_start + 1;
            end
        end
    end

    final begin
        $fdisplay(fd, "# results %0d", nres);
        $fclose(fd);
        $display("[E8.5c MONITOR] SRAM_LATENCY %0d, ALIGN_DELAY %0d",
                 `E85C_IMC.SRAM_LATENCY, `E85C_IMC.U_COMB.ALIGN_DELAY);
        $display("[E8.5c MONITOR] results %0d -> %0s", nres, fname);
        $display("[E8.5c MONITOR] datapath starts %0d, SRAM reads %0d", nstart, nreads);
        $display("[E8.5c MONITOR] shortest interval between two SRAM reads of one lane %0d cycles (lane %0d); intervals below 2: %0d",
                 min_gap, min_gap_lane, n_short);
        $display("[E8.5c MONITOR] cycles with a pool hit while the datapath start is low: %0d", hit_off_start);
    end

endmodule
