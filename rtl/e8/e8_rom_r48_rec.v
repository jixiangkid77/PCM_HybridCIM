//============================================================
// e8_rom_r48_rec.v   (P2R-E8.5b, simulation model; not synthesised)
//============================================================
// The behavioural model of one r48 address-map ROM macro of
// rtl/e8/e8_rom_r48.v (same module name, ports, parameters,
// contents, T1 protocol and timing), changed only so that a
// gate-level run of the address-map unit can be checked against
// the RTL run:
//   - every read (the first CS rise in a clock-high phase) and
//     every protocol error is reported to the top-level module
//     e8_5b_monitor (rtl/e8/tb/e8_5b_monitor.v) by a task call,
//     because the instance names of a gate-level netlist cannot be
//     reached by the hierarchical names of the RTL;
//   - no real, integer or time variables and no named blocks, so a
//     waveform of the unit holds only wire and reg values (the
//     simulation of the unit's power reads the waveform);
//   - T_ACC_PS is an integer number of ps (e8_rom_r48.v: 22.0 ns);
//   - the address-hold check looks at the settled address (1 ps after
//     a change), not at every change within a time step (see below).
// last_zero (the last word read has a zero bit) is kept: the simulation
// check of the parking rule in rtl/e8/amu_table.v reads it in the RTL run.
// Used by scripts/e8_5b_amu_power.sh in place of e8_rom_r48.v, in
// the RTL run and in the gate-level run alike.
//
// Place  : rtl/e8/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

module e8_rom_r48 #(
    parameter integer LANE     = 0,
    parameter integer SIDE     = 0,          // 0 = SRAM side, 1 = PCM side
    parameter integer MACRO    = 0,
    parameter         DATA_DIR = "",
    parameter integer T_ACC_PS = 22000       // ps after the clock edge
)(
    input  wire        clk0,
    input  wire        cs0,
    input  wire [9:0]  addr0,
    output reg  [15:0] dout0
);
    reg [15:0] tab [0:2495];
    reg [15:0] c1 [0:5];  reg [15:0] c2 [0:95];  reg [15:0] f1 [0:1919];
    reg [15:0] f2 [0:419]; reg [15:0] f3 [0:39];
    reg [12:0] i;
    initial begin
        for (i = 0; i < 6;    i = i + 1) c1[i] = 16'hFFFF;
        for (i = 0; i < 96;   i = i + 1) c2[i] = 16'hFFFF;
        for (i = 0; i < 1920; i = i + 1) f1[i] = 16'hFFFF;
        for (i = 0; i < 420;  i = i + 1) f2[i] = 16'hFFFF;
        for (i = 0; i < 40;   i = i + 1) f3[i] = 16'hFFFF;
        if (DATA_DIR != "") begin
            if (SIDE == 0) begin
                $readmemh($sformatf("%s/addr_to_slot_conv1_sram_lane%02d.hex", DATA_DIR, LANE), c1);
                $readmemh($sformatf("%s/addr_to_slot_conv2_sram_lane%02d.hex", DATA_DIR, LANE), c2);
                $readmemh($sformatf("%s/addr_to_slot_fc1_sram_lane%02d.hex",   DATA_DIR, LANE), f1);
                $readmemh($sformatf("%s/addr_to_slot_fc2_sram_lane%02d.hex",   DATA_DIR, LANE), f2);
                $readmemh($sformatf("%s/addr_to_slot_fc3_sram_lane%02d.hex",   DATA_DIR, LANE), f3);
            end else begin
                $readmemh($sformatf("%s/addr_to_slot_conv1_pcm_lane%02d.hex", DATA_DIR, LANE), c1);
                $readmemh($sformatf("%s/addr_to_slot_conv2_pcm_lane%02d.hex", DATA_DIR, LANE), c2);
                $readmemh($sformatf("%s/addr_to_slot_fc1_pcm_lane%02d.hex",   DATA_DIR, LANE), f1);
                $readmemh($sformatf("%s/addr_to_slot_fc2_pcm_lane%02d.hex",   DATA_DIR, LANE), f2);
                $readmemh($sformatf("%s/addr_to_slot_fc3_pcm_lane%02d.hex",   DATA_DIR, LANE), f3);
            end
        end else
            e8_5b_monitor.rom_nodata(SIDE, LANE, MACRO);
        for (i = 0; i < 2496; i = i + 1) tab[i] = 16'hFFFF;
        for (i = 0; i < 6;    i = i + 1) tab[i]        = c1[i];
        for (i = 0; i < 96;   i = i + 1) tab[6 + i]    = c2[i];
        for (i = 0; i < 1920; i = i + 1) tab[102 + i]  = f1[i];
        for (i = 0; i < 420;  i = i + 1) tab[2022 + i] = f2[i];
        for (i = 0; i < 40;   i = i + 1) tab[2442 + i] = f3[i];
        dout0 = 16'hxxxx;
    end

    // ---- protocol: times in ps (64-bit regs) ----
    reg [63:0] t_rise_ps, t_fall_ps, t_acc_edge;
    reg        cs_seen;
    reg        last_zero;            // the last word read has a zero bit (read by amu_table's parking check)
    reg [9:0]  a_lat;
    initial begin
        t_rise_ps = 64'd0; t_fall_ps = 64'd0; t_acc_edge = 64'd0; cs_seen = 1'b0; last_zero = 1'b0;
    end

    function [15:0] word_at;
        input [9:0] a;
        begin
            if (a[3:0] > 4'd12 || a[9:4] > 6'd47) word_at = 16'hxxxx;
            else word_at = tab[MACRO * 624 + a[9:4] * 13 + a[3:0]];
        end
    endfunction

    always @(posedge clk0) begin
        t_rise_ps = $realtime * 1000.0;          // the module time unit is 1 ns
        a_lat     = addr0;
        cs_seen   = 1'b0;
        if (cs0 === 1'b1) e8_5b_monitor.rom_err(SIDE, LANE, MACRO, 0);             // CS must rise after the edge (T1)
        if (addr0[3:0] > 4'd12 || addr0[9:4] > 6'd47) e8_5b_monitor.rom_err(SIDE, LANE, MACRO, 2);
        #1 dout0 = 16'hxxxx;
    end
    always @(posedge cs0) if (clk0 === 1'b1) begin
        if (!cs_seen) begin
            cs_seen = 1'b1;
            e8_5b_monitor.rom_read(SIDE, LANE, MACRO, a_lat, t_rise_ps - t_fall_ps);
        end
    end
    // The address must hold while the clock is high. Checked on the settled value, 1 ps after a change
    // (the end of that time step): in a zero-delay gate-level run the address bits can change and change
    // back within one time step when the flip-flops update at the edge of the system clock; a value that
    // stays different from the address latched at the rising edge is an error, in either run.
    always @(addr0) if (clk0 === 1'b1) begin
        #0.001;
        if (clk0 === 1'b1 && addr0 !== a_lat) e8_5b_monitor.rom_err(SIDE, LANE, MACRO, 1);
    end
    // data valid T_ACC after the edge, if CS is high by then
    always @(posedge clk0) begin
        t_acc_edge = $realtime * 1000.0;          // this edge (not t_rise_ps: the two blocks run in either order)
        #(T_ACC_PS / 1000.0);
        if (clk0 === 1'b1 && cs0 === 1'b1 && t_rise_ps == t_acc_edge) begin
            dout0     = word_at(a_lat);
            last_zero = (dout0 !== 16'hFFFF);
        end
    end
    always @(negedge clk0) begin
        t_fall_ps = $realtime * 1000.0;
        #1 dout0 = 16'hxxxx;
    end

endmodule
