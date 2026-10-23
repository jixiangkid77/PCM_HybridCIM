//============================================================
// e8_5e_monitor.v   (P2R-E8.5e, passive monitor)
//============================================================
// Compiled as a further top-level module next to the unchanged
// testbench tb_lenet5_full_inference_v3, the E8.2, E8.5 and
// E8.5c monitors, with the unit rtl/e8/pcm_imc_unit_e8c.v (as
// pcm_imc_unit). It only reads signals through hierarchical
// references and drives nothing.
//
// Counts at every datapath start (start_internal), per lane with
// an SRAM-side hit (sram_hit_dbg):
//   - macro reads : the pool reads (U_SPOOL.hit_bus)
//   - cache reads : the conv1 cache serves the lane (cache_sel)
// Checks:
//   - every cache read: the cache entry (lane*6 + idx) equals the
//     pool word at the lane's pool address (the same data the
//     macro would have returned); mismatches must be 0
//   - cycles in which the pool sees a hit while layer_id is conv1
//     (the macros must not be clocked in conv1): must be 0
//   - cache reads outside conv1: must be 0
//
// Place  : rtl/e8/tb/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

`define E85E_TB  tb_lenet5_full_inference_v3
`define E85E_IMC tb_lenet5_full_inference_v3.DUT.u_imc

module e8_5e_monitor;

    localparam integer K = 25;

    integer k, nstart, nmacro, ncache, nmis, npool_conv1, ncache_other;
    integer nmacro_layer [0:4];
    integer ncache_lane [0:K-1];
    integer a, e, l;
    reg [7:0] cv, pv;

    initial begin
        nstart = 0; nmacro = 0; ncache = 0; nmis = 0; npool_conv1 = 0; ncache_other = 0;
        for (k = 0; k < 5; k = k + 1) nmacro_layer[k] = 0;
        for (k = 0; k < K; k = k + 1) ncache_lane[k] = 0;
    end

    always @(negedge `E85E_TB.clk) begin
        if (`E85E_TB.started_flag) begin
            if (`E85E_IMC.U_C1CACHE.is_conv1 && (|`E85E_IMC.U_SPOOL.hit_bus))
                npool_conv1 = npool_conv1 + 1;
            if (`E85E_IMC.start_internal) begin
                nstart = nstart + 1;
                l = `E85E_IMC.layer_id;
                for (k = 0; k < K; k = k + 1) begin
                    if (`E85E_IMC.U_SPOOL.hit_bus[k]) begin
                        nmacro = nmacro + 1;
                        if (l < 5) nmacro_layer[l] = nmacro_layer[l] + 1;
                    end
                    if (`E85E_IMC.U_C1CACHE.sel[k]) begin
                        ncache = ncache + 1;
                        ncache_lane[k] = ncache_lane[k] + 1;
                        if (l != 0) ncache_other = ncache_other + 1;
                        e  = k * 6 + `E85E_IMC.U_C1CACHE.idx[k*3 +: 3];
                        a  = `E85E_IMC.sram_pool_addr_bus[k*16 +: 16];
                        cv = `E85E_IMC.U_C1CACHE.mem[e];
                        pv = `E85E_IMC.U_SPOOL.sram_pool_mem[a];
                        if (cv !== pv) begin
                            nmis = nmis + 1;
                            if (nmis <= 5)
                                $display("[E8.5e MONITOR] MISMATCH lane %0d entry %0d: cache %02h, pool[%0d] %02h (cycle %0d)",
                                         k, e, cv, a, pv, `E85E_TB.cycle_after_start);
                        end
                    end
                end
            end
        end
    end

    final begin
        $display("[E8.5e MONITOR] datapath starts %0d; SRAM macro reads %0d (conv1 %0d, conv2 %0d, fc1 %0d, fc2 %0d, fc3 %0d); conv1 cache reads %0d",
                 nstart, nmacro, nmacro_layer[0], nmacro_layer[1], nmacro_layer[2], nmacro_layer[3], nmacro_layer[4], ncache);
        $display("[E8.5e MONITOR] cache reads per lane: min %0d max %0d", min_lane(0), min_lane(1));
        $display("[E8.5e MONITOR] cache entries different from the pool word: %0d; cache reads outside conv1: %0d; cycles with a pool hit in conv1: %0d",
                 nmis, ncache_other, npool_conv1);
    end

    function integer min_lane(input integer want_max);
        integer i, m;
        begin
            m = ncache_lane[0];
            for (i = 1; i < K; i = i + 1)
                if (want_max ? (ncache_lane[i] > m) : (ncache_lane[i] < m)) m = ncache_lane[i];
            min_lane = m;
        end
    endfunction

endmodule
