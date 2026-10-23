//============================================================
// e8_lookup_monitor.v
// P2R-E8.2: passive monitor that records every address-map lookup
// of a full LeNet-5 inference.
//
// It is compiled as a second top-level module next to the
// unchanged testbench tb_lenet5_full_inference_v3 and only reads
// signals through hierarchical references. It drives nothing, so
// the design and the verified testbench behave exactly as before.
//
// What is recorded, once per MAC operation:
//   The testbench comment for its sram_reads_mac counter states
//   that the conv/fc engine issues one 25-lane MAC operation per
//   pulse on u_imc.start and holds the 25 weight addresses stable
//   while the operation runs. The 25 address-map lookups of an
//   operation therefore happen once, on that pulse. The monitor
//   samples on the same edge the testbench uses (negedge, with
//   started_flag set and u_imc.start high) and writes one line:
//
//     <cycle> <layer_id> <sb> <ss> <pb> <ps> <a0>:<s0><p0> ... <a24>:<s24><p24>
//
//   sb/ss and pb/ps are the SRAM and PCM partition base and size
//   that the configuration register file supplies for this layer
//   (hex), ak is the 16-bit original weight address of lane k in
//   hex, sk the SRAM-side hit and pk the PCM-side hit of lane k.
//
// The hit bits let the post-processing script check, lookup by
// lookup, that its replica of the decoder arithmetic selects the
// same ROM entry as the RTL. The address and layer are what the
// physical ROMs would be read with, and they are the stimulus for
// the gate-level power analysis of the decoder arithmetic.
//
// Output file: +e8_trace=<path> (default e8_lookup_trace.txt)
//
// Place  : D:\Project\hybrid_memory\paper2\rtl\tb\
// Status : NEW FILE. The existing testbench is not modified.
//============================================================

`timescale 1ns/1ps

module e8_lookup_monitor;

    localparam integer K      = 25;
    localparam integer AWIDTH = 16;

    integer fd;
    integer ops;
    integer k;
    reg [8*256-1:0] fname;

    initial begin
        if (!$value$plusargs("e8_trace=%s", fname))
            fname = "e8_lookup_trace.txt";
        fd = $fopen(fname, "w");
        if (fd == 0) begin
            $display("[E8 MONITOR] cannot open trace file %0s", fname);
            $finish;
        end
        ops = 0;
        $fdisplay(fd, "# P2R-E8.2 address-map lookup trace");
        $fdisplay(fd, "# fields: cycle_after_start layer_id sram_base sram_size pcm_base pcm_size then 25 x addr_hex:sram_hit pcm_hit");
    end

    always @(negedge tb_lenet5_full_inference_v3.clk) begin
        if (tb_lenet5_full_inference_v3.started_flag &&
            tb_lenet5_full_inference_v3.DUT.u_imc.start) begin
            $fwrite(fd, "%0d %0d %04h %04h %04h %04h",
                    tb_lenet5_full_inference_v3.cycle_after_start,
                    tb_lenet5_full_inference_v3.DUT.u_imc.layer_id,
                    tb_lenet5_full_inference_v3.DUT.u_imc.sram_base_w,
                    tb_lenet5_full_inference_v3.DUT.u_imc.sram_size_w,
                    tb_lenet5_full_inference_v3.DUT.u_imc.pcm_base_w,
                    tb_lenet5_full_inference_v3.DUT.u_imc.pcm_size_w);
            for (k = 0; k < K; k = k + 1)
                $fwrite(fd, " %04h:%0d%0d",
                        tb_lenet5_full_inference_v3.DUT.u_imc.orig_addr_bus[k*AWIDTH +: AWIDTH],
                        tb_lenet5_full_inference_v3.DUT.u_imc.sram_hit_dbg[k],
                        tb_lenet5_full_inference_v3.DUT.u_imc.pcm_hit_dbg[k]);
            $fwrite(fd, "\n");
            ops = ops + 1;
        end
    end

    // done_seen and done_cycle are updated on the same clock edge;
    // wait 1 ns so that done_cycle holds its final value.
    always @(posedge tb_lenet5_full_inference_v3.done_seen) begin
        #1;
        $fdisplay(fd, "# done_cycle %0d mac_operations %0d",
                  tb_lenet5_full_inference_v3.done_cycle, ops);
        $fflush(fd);
        $display("[E8 MONITOR] %0d MAC operations recorded to %0s", ops, fname);
    end

endmodule
