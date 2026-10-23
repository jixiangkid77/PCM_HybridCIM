//============================================================
// amu_core.v   (P2R-E8.5, address-map unit)
//============================================================
// Shared control of the 50 address-map tables (25 lanes x SRAM /
// PCM side), each a set of four 48-row OpenRAM ROM macros
// (r48, 13 words per row). All tables are read at the same entry
// at the same time, so one controller drives every macro index.
//
// 1. Entry buffer (KID 2026-10-15). NSLOT recently read entries
//    (tags here; the words of all tables in amu_buf). An
//    entry already in the buffer is not read again: conv1 reads
//    each entry once per output channel, conv2 its 6 entries
//    once per output channel instead of once per output pixel.
//    Replacement: first in, first out.
// 2. Reading ahead (KID 2026-10-15), so that the external timing
//    of the original combinational decoders is kept:
//    - a lookup starts when (layer_id, lane 0 address) changes;
//      the conv engine updates lane 0 24 cycles before its start
//      pulse (sandbox simulation of the unchanged conv_engine);
//    - in an FC layer the next operation uses the next entry
//      (oc outer, sb inner), so it is read ahead as soon as an FC
//      entry becomes current.
//    A start pulse whose entry is not yet in the buffer is held
//    (start_go later); the engines wait for result_valid.
// 3. ROM read timing as verified in E8.4a-6/-7/-8 and E8.4b:
//    address set up one cycle (10 ns) before the ROM clock edge;
//    CS one cycle after the edge (T1); clock high T_HIGH cycles
//    (50 ns); dout captured T_CAP cycles (40 ns) after the edge
//    (access <= 21.3 ns at the verified conditions); clock low
//    >= T_PRE_LOOK cycles (90 ns) before a lookup read and
//    >= T_PRE_PARK cycles (50 ns) before a parking read.
// 4. Parking (GPp of E8.6a): after a lookup read a macro index is
//    parked (each table reads its parking word) once it has been
//    low 50 ns, unless its next read is expected (an FC entry
//    whose next entry lies in the same macro): then it is parked
//    only if that read has not started 200 ns after this one
//    (E8.6a: no parking when the macro is read again within
//    200 ns). A table parks only if the last word it read from
//    that macro has a zero bit and it has not parked since
//    (amu_pflags; a table that did not take part in the last
//    lookup keeps the state of its own last read).
// 5. The buffer slots of all 50 tables are written by one shared
//    one-hot enable (cap_en, amu_buf), so that clock gating groups
//    the 6,400 buffer flip-flops under a few gating cells; the
//    buffer has no reset. The tables show the current entry only
//    when out_ok (entry captured, cur_slot updated); otherwise
//    "no hit", so the outputs are never a stale or unwritten word.
//
// Cycle counts assume the 100 MHz system clock of the design.
//
// Place  : rtl/e8/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

module amu_core #(
    parameter integer K          = 25,
    parameter integer NSLOT      = 8,
    parameter integer T_HIGH     = 5,
    parameter integer T_CS       = 1,
    parameter integer T_CAP      = 4,
    parameter integer T_PRE_LOOK = 9,
    parameter integer T_PRE_PARK = 5,
    parameter integer T_EXPECT   = 15   // an expected read that has not come after this many low cycles: park
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire [2:0]    layer_id,
    input  wire [15:0]   a0,
    input  wire          v0,
    input  wire [11:0]   e0,
    input  wire          start_req,     // start & cfg_valid
    input  wire [K-1:0]  mismatch,      // from amu_lanes (sampled at a start)

    // ROM control, shared by all tables
    output reg  [3:0]    rom_clk,       // clock pulse per macro index
    output reg  [3:0]    rom_cs,
    output reg           rom_park,      // the current pulse is a parking read
    output reg  [9:0]    rom_addr,      // lookup address in the macro (row*16 + word)
    output reg  [K-1:0]  rom_lane_en,   // lanes whose tables take part in the lookup read
    output reg           cap,           // capture dout at the next clock edge
    output reg  [1:0]    cap_m,
    output reg  [2:0]    cap_slot,
    output wire [NSLOT-1:0] cap_en,     // one-hot write enable of the buffer slot (shared by all tables)
    output reg  [3:0]    park_end,      // a parking read of macro m has ended (one cycle)

    // current entry
    output reg  [2:0]    cur_slot,
    output wire          cur_ready,
    output wire          out_ok,        // the current entry is in the buffer and cur_slot points at it
    output wire          start_go,
    output wire          stall,

    // observability (counters only in simulation; 0 after synthesis)
    output reg  [31:0]   n_lookup_reads,
    output reg  [31:0]   n_park_reads,
    output reg  [31:0]   n_stall_cycles,
    output reg  [31:0]   n_starts,
    output reg           err_mismatch,  // a lane's address did not follow lane 0 at a start
    output reg           err_lane0,     // lane 0 had no valid entry at a start
    output reg           err_queue      // more read requests than the queue holds
);

    // ---------------- entry -> {macro, row*16 + word} ----------------
    function [11:0] map_entry;
        input [11:0] e;
        reg [22:0] p; reg [7:0] row; reg [11:0] w12; reg [15:0] q; reg [1:0] m; reg [7:0] mr;
        begin
            p    = e * 23'd2521;                 // e / 13 for e <= 2495
            row  = p[22:15];
            w12  = e - {4'd0, row} * 12'd13;
            q    = {8'd0, row} * 16'd171;        // row / 48 for row <= 191
            m    = q[14:13];
            mr   = row - {6'd0, m} * 8'd48;
            map_entry = {m, mr[5:0], w12[3:0]};
        end
    endfunction
    function [2:0] layer_of;
        input [11:0] e;
        layer_of = (e < 12'd6) ? 3'd0 : (e < 12'd102) ? 3'd1 : (e < 12'd2022) ? 3'd2 :
                   (e < 12'd2442) ? 3'd3 : (e < 12'd2482) ? 3'd4 : 3'd7;
    endfunction
    function [K-1:0] lanes_of;           // lanes that look up entry e (FC tail lanes do not)
        input [11:0] e;
        reg [11:0] c; reg [19:0] q5; reg [11:0] cq;
        begin
            lanes_of = {K{1'b1}};
            if (e >= 12'd2022 && e < 12'd2442) begin           // fc2, sb = c mod 5; lanes < 120 - 25*sb
                c  = e - 12'd2022;
                q5 = {8'd0, c} * 20'd205;                       // c / 5 for c <= 419: (c*205) >> 10
                cq = {2'd0, q5[19:10]};
                if (c - cq * 12'd5 == 12'd4) lanes_of = {{(K-20){1'b0}}, {20{1'b1}}};
            end else if (e >= 12'd2442 && e < 12'd2482) begin  // fc3, sb = c mod 4; lanes < 84 - 25*sb
                c = e - 12'd2442;
                if (c[1:0] == 2'd3) lanes_of = {{(K-9){1'b0}}, {9{1'b1}}};
            end
        end
    endfunction
    function [11:0] layer_end;
        input [2:0] l;
        case (l)
            3'd0: layer_end = 12'd6;    3'd1: layer_end = 12'd102;  3'd2: layer_end = 12'd2022;
            3'd3: layer_end = 12'd2442; 3'd4: layer_end = 12'd2482; default: layer_end = 12'd0;
        endcase
    endfunction

    // ---------------- buffer tags ----------------
    reg [11:0]      tag [0:NSLOT-1];
    reg [NSLOT-1:0] tv;                 // tag valid
    reg [NSLOT-1:0] dv;                 // data captured
    reg [2:0]       ptr;                // next slot to allocate (first in, first out)

    wire [11:0] e_next = e0 + 12'd1;
    reg  [2:0]  hit_idx;  reg hit;
    reg  [2:0]  nhit_idx; reg nhit;
    integer s;
    always @(*) begin
        hit = 1'b0; hit_idx = 3'd0; nhit = 1'b0; nhit_idx = 3'd0;
        for (s = NSLOT - 1; s >= 0; s = s - 1) begin
            if (tv[s] && tag[s] == e0)     begin hit  = 1'b1; hit_idx  = s; end
            if (tv[s] && tag[s] == e_next) begin nhit = 1'b1; nhit_idx = s; end
        end
    end

    // ---------------- current entry ----------------
    reg [18:0] key_q;
    reg        key_init;
    reg        cur_v;
    wire       change    = !key_init || ({layer_id, a0} != key_q);
    wire       fc_layer  = (layer_id == 3'd2) || (layer_id == 3'd3) || (layer_id == 3'd4);
    wire       want_next = v0 && fc_layer && (e_next < layer_end(layer_id));
    assign cur_ready = !cur_v || dv[cur_slot];

    // new requests of this cycle (demand, then read-ahead) and their slots
    wire       new_d   = change && v0 && !hit;
    wire       new_p   = change && want_next && !nhit;
    wire [2:0] slot_d  = ptr;
    wire [2:0] slot_p  = new_d ? ptr + 3'd1 : ptr;

    // ---------------- request queue (2 places) ----------------
    reg        rq_v [0:1];
    reg [11:0] rq_e [0:1];
    reg [2:0]  rq_s [0:1];

    // ---------------- ROM sequencer ----------------
    localparam [1:0] SQ_IDLE = 2'd0, SQ_SETUP = 2'd1, SQ_HIGH = 2'd2;
    reg [1:0]  sq;
    reg [2:0]  hc;
    reg [1:0]  op_m;
    reg        op_park;
    reg [2:0]  op_slot;
    reg [11:0] op_e;
    reg [4:0]  lowc [0:3];              // full cycles each macro clock has been low (saturating)
    reg [3:0]  needs_park;
    reg [3:0]  expect_more;
    genvar gs;
    generate for (gs = 0; gs < NSLOT; gs = gs + 1) begin : capen
        assign cap_en[gs] = cap && (cap_slot == gs);
    end endgenerate

    wire [11:0] q0_map = map_entry(rq_e[0]);
    wire [11:0] q1_map = map_entry(rq_e[1]);
    wire        q0_ok  = rq_v[0] && (lowc[q0_map[11:10]] >= T_PRE_LOOK - 2);
    reg  [1:0]  pk_m;  reg pk_ok;  integer mm;
    always @(*) begin
        pk_ok = 1'b0; pk_m = 2'd0;
        for (mm = 3; mm >= 0; mm = mm - 1)
            if (needs_park[mm] && (!expect_more[mm] || lowc[mm] >= T_EXPECT - 1) && (lowc[mm] >= T_PRE_PARK - 2) &&
                !(rq_v[0] && q0_map[11:10] == mm) && !(rq_v[1] && q1_map[11:10] == mm)) begin
                pk_ok = 1'b1; pk_m = mm;
            end
    end
    wire        pop     = (sq == SQ_IDLE) && q0_ok;
    wire [11:0] nxt_map = map_entry(op_e + 12'd1);

    // ---------------- start handling ----------------
    reg pend;
    assign out_ok   = cur_ready && !change;
    assign start_go = out_ok && (pend || start_req);
    assign stall    = (!cur_ready || change) && (pend || start_req);

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            tv <= 0; dv <= 0; ptr <= 0;
            for (i = 0; i < NSLOT; i = i + 1) tag[i] <= 12'd0;
            key_q <= 0; key_init <= 1'b0; cur_v <= 1'b0; cur_slot <= 3'd0;
            rq_v[0] <= 1'b0; rq_v[1] <= 1'b0;
            rq_e[0] <= 12'd0; rq_e[1] <= 12'd0; rq_s[0] <= 3'd0; rq_s[1] <= 3'd0;
            sq <= SQ_IDLE; hc <= 3'd0; op_m <= 2'd0; op_park <= 1'b0; op_slot <= 3'd0; op_e <= 12'd0;
            for (i = 0; i < 4; i = i + 1) lowc[i] <= 5'd31;
            needs_park <= 4'd0; expect_more <= 4'd0; park_end <= 4'd0;
            rom_clk <= 4'd0; rom_cs <= 4'd0; rom_park <= 1'b0; rom_addr <= 10'd0; rom_lane_en <= {K{1'b0}};
            cap <= 1'b0; cap_m <= 2'd0; cap_slot <= 3'd0;
            pend <= 1'b0;
            n_lookup_reads <= 0; n_park_reads <= 0; n_stall_cycles <= 0; n_starts <= 0;
            err_mismatch <= 1'b0; err_lane0 <= 1'b0; err_queue <= 1'b0;
        end else begin
            cap      <= 1'b0;
            park_end <= 4'd0;

            // low counters
            for (i = 0; i < 4; i = i + 1)
                if (!rom_clk[i] && lowc[i] != 5'd31) lowc[i] <= lowc[i] + 5'd1;

            // sequencer
            case (sq)
                SQ_IDLE: begin
                    if (q0_ok) begin                              // lookup read of the queue head
                        op_m <= q0_map[11:10]; op_park <= 1'b0; op_slot <= rq_s[0]; op_e <= rq_e[0];
                        rom_addr    <= q0_map[9:0];
                        rom_lane_en <= lanes_of(rq_e[0]);
                        rom_park    <= 1'b0;
                        sq <= SQ_SETUP;
                    end else if (pk_ok) begin                     // parking read
                        op_m <= pk_m; op_park <= 1'b1;
                        rom_park <= 1'b1;
                        sq <= SQ_SETUP;
                    end
                end
                SQ_SETUP: begin                                    // address stable for a cycle; clock rises
                    rom_clk[op_m] <= 1'b1;
                    hc <= 3'd0;
                    sq <= SQ_HIGH;
                end
                SQ_HIGH: begin
                    hc <= hc + 3'd1;
                    if (hc == T_CS - 1) rom_cs[op_m] <= 1'b1;
                    if (hc == T_CAP - 2 && !op_park) begin cap <= 1'b1; cap_m <= op_m; cap_slot <= op_slot; end
                    if (hc == T_CAP - 1 && !op_park) dv[op_slot] <= 1'b1;
                    if (hc == T_HIGH - 1) begin
                        rom_clk[op_m] <= 1'b0; rom_cs[op_m] <= 1'b0; lowc[op_m] <= 5'd0;
                        rom_park <= 1'b0;
                        sq <= SQ_IDLE;
                        if (op_park) begin
                            needs_park[op_m] <= 1'b0;
                            park_end[op_m]   <= 1'b1;
`ifndef SYNTHESIS
                            n_park_reads     <= n_park_reads + 1;
`endif
                        end else begin
                            needs_park[op_m]  <= 1'b1;
`ifndef SYNTHESIS
                            n_lookup_reads    <= n_lookup_reads + 1;
`endif
                            expect_more[op_m] <= (layer_of(op_e) >= 3'd2) && (layer_of(op_e) <= 3'd4) &&
                                                 (layer_of(op_e + 12'd1) == layer_of(op_e)) &&
                                                 (nxt_map[11:10] == op_m);
                        end
                    end
                end
                default: sq <= SQ_IDLE;
            endcase

            // request queue: pop the head, then append the new requests in order
            begin : qupd
                reg        v0n, v1n;  reg [11:0] e0n, e1n;  reg [2:0] s0n, s1n;
                v0n = rq_v[0]; e0n = rq_e[0]; s0n = rq_s[0];
                v1n = rq_v[1]; e1n = rq_e[1]; s1n = rq_s[1];
                if (pop) begin v0n = v1n; e0n = e1n; s0n = s1n; v1n = 1'b0; end
                if (new_d) begin
                    if (!v0n)      begin v0n = 1'b1; e0n = e0; s0n = slot_d; end
                    else if (!v1n) begin v1n = 1'b1; e1n = e0; s1n = slot_d; end
                    else err_queue <= 1'b1;
                end
                if (new_p) begin
                    if (!v0n)      begin v0n = 1'b1; e0n = e_next; s0n = slot_p; end
                    else if (!v1n) begin v1n = 1'b1; e1n = e_next; s1n = slot_p; end
                    else err_queue <= 1'b1;
                end
                rq_v[0] <= v0n; rq_e[0] <= e0n; rq_s[0] <= s0n;
                rq_v[1] <= v1n; rq_e[1] <= e1n; rq_s[1] <= s1n;
            end

            // a new operation entry
            key_q <= {layer_id, a0};
            key_init <= 1'b1;
            if (change) begin
                cur_v <= v0;
                if (v0) cur_slot <= hit ? hit_idx : slot_d;
            end
            if (new_d) begin tag[slot_d] <= e0;     tv[slot_d] <= 1'b1; dv[slot_d] <= 1'b0; end
            if (new_p) begin tag[slot_p] <= e_next; tv[slot_p] <= 1'b1; dv[slot_p] <= 1'b0; end
            ptr <= ptr + {2'd0, new_d} + {2'd0, new_p};

            // starts
            if (start_req) begin
`ifndef SYNTHESIS
                n_starts <= n_starts + 1;
`endif
                if (|mismatch) err_mismatch <= 1'b1;
                if (!cur_v)    err_lane0    <= 1'b1;
            end
`ifndef SYNTHESIS
            if (stall) n_stall_cycles <= n_stall_cycles + 1;
`endif
            pend <= stall;
        end
    end

endmodule
