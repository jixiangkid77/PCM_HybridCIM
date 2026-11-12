//============================================================
// amu9_core.v   (P2R-E9.1, address-map unit with one word per entry)
//============================================================
// rtl/e8/amu_core.v (E8.5) for the address map of E9: one 40-bit
// word per table entry (25 assignment bits and the count of the
// protected weights before the entry in its layer), held in NM
// ROM macros of 48 rows x 8 words (OpenRAM, the organisation of
// the E9.0 probe); entry e is in macro e div 383 at address
// e mod 383, address 383 of every macro is its parking word (all
// ones). A lookup reads one macro (E8.5: one macro index in all
// 50 tables). Everything else is amu_core unchanged:
//   - entry buffer of NSLOT entries (tags here, words in amu9_top),
//     first in, first out; an entry in the buffer is not read again;
//   - reading ahead: a lookup starts when (layer_id, lane 0
//     address) changes; in an FC layer the next entry is read as
//     soon as an FC entry becomes current; a start pulse whose
//     entry is not in the buffer is held (start_go later);
//   - ROM read timing of E8.4a-6/-7/-8, E8.4b and E9.0: address
//     set up one cycle before the clock edge; CS one cycle after
//     the edge (T1); clock high T_HIGH cycles; dout captured T_CAP
//     cycles after the edge (E9.0: access <= 22.48 ns at the
//     verified conditions, captured at 40 ns); clock low >=
//     T_PRE_LOOK cycles before a lookup read and >= T_PRE_PARK
//     cycles before a parking read;
//   - parking: after a lookup the macro reads its parking word once
//     it has been low 50 ns, unless its next read is expected (FC,
//     next entry in the same macro): then only if that read has not
//     started T_EXPECT low cycles later.
// Changes against amu_core, nothing else:
//   - NM macro indices (4 in E8.5) and the entry -> {macro, address}
//     map of the new organisation; rom_addr is 9 bits and is set to
//     PARK_ADDR for a parking read (E8.5: each table muxed its own
//     parking address);
//   - no lane enables: the one word holds all lanes;
//   - a macro needs parking only if the word of its last lookup has
//     a zero bit (cap_zero at the capture; E8.5: amu_pflags per
//     table); a word of all ones leaves the macro parked.
//
// Place  : rtl/e9/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

module amu9_core #(
    parameter integer K          = 25,
    parameter integer NSLOT      = 8,
    parameter integer NM         = 7,
    parameter integer EPM        = 383,       // entries per macro
    parameter [8:0]   PARK_ADDR  = 9'd383,
    parameter integer T_HIGH     = 5,
    parameter integer T_CS       = 1,
    parameter integer T_CAP      = 4,
    parameter integer T_PRE_LOOK = 9,
    parameter integer T_PRE_PARK = 5,
    parameter integer T_EXPECT   = 15
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire [2:0]    layer_id,
    input  wire [15:0]   a0,
    input  wire          v0,
    input  wire [11:0]   e0,
    input  wire          start_req,
    input  wire [K-1:0]  mismatch,
    input  wire          cap_zero,      // the word being captured has a zero bit

    // ROM control
    output reg  [NM-1:0] rom_clk,
    output reg  [NM-1:0] rom_cs,
    output reg           rom_park,
    output reg  [8:0]    rom_addr,
    output reg           cap,
    output reg  [2:0]    cap_m,
    output reg  [2:0]    cap_slot,
    output wire [NSLOT-1:0] cap_en,
    output reg  [NM-1:0] park_end,

    // current entry
    output reg  [2:0]    cur_slot,
    output wire          cur_ready,
    output wire          out_ok,
    output wire          start_go,
    output wire          stall,

    // observability (counters only in simulation; 0 after synthesis)
    output reg  [31:0]   n_lookup_reads,
    output reg  [31:0]   n_park_reads,
    output reg  [31:0]   n_stall_cycles,
    output reg  [31:0]   n_starts,
    output reg           err_mismatch,
    output reg           err_lane0,
    output reg           err_queue
);

    // ---------------- entry -> {macro, address} ----------------
    function [11:0] map_entry;              // {macro[2:0], address[8:0]}
        input [11:0] e;
        reg [2:0] m; reg [11:0] r;
        begin
            m = {2'd0, e >= 12'd383} + {2'd0, e >= 12'd766} + {2'd0, e >= 12'd1149} +
                {2'd0, e >= 12'd1532} + {2'd0, e >= 12'd1915} + {2'd0, e >= 12'd2298};
            r = e - {9'd0, m} * 12'd383;
            map_entry = {m, r[8:0]};
        end
    endfunction
    function [2:0] layer_of;
        input [11:0] e;
        layer_of = (e < 12'd6) ? 3'd0 : (e < 12'd102) ? 3'd1 : (e < 12'd2022) ? 3'd2 :
                   (e < 12'd2442) ? 3'd3 : (e < 12'd2482) ? 3'd4 : 3'd7;
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
    reg [NSLOT-1:0] tv;
    reg [NSLOT-1:0] dv;
    reg [2:0]       ptr;

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
    reg [2:0]  op_m;
    reg        op_park;
    reg [2:0]  op_slot;
    reg [11:0] op_e;
    reg [4:0]  lowc [0:NM-1];
    reg [NM-1:0] needs_park;
    reg [NM-1:0] expect_more;
    reg        zcap;                    // the captured word of the current lookup has a zero bit
    genvar gs;
    generate for (gs = 0; gs < NSLOT; gs = gs + 1) begin : capen
        assign cap_en[gs] = cap && (cap_slot == gs);
    end endgenerate

    wire [11:0] q0_map = map_entry(rq_e[0]);
    wire [11:0] q1_map = map_entry(rq_e[1]);
    wire        q0_ok  = rq_v[0] && (lowc[q0_map[11:9]] >= T_PRE_LOOK - 2);
    reg  [2:0]  pk_m;  reg pk_ok;  integer mm;
    always @(*) begin
        pk_ok = 1'b0; pk_m = 3'd0;
        for (mm = NM - 1; mm >= 0; mm = mm - 1)
            if (needs_park[mm] && (!expect_more[mm] || lowc[mm] >= T_EXPECT - 1) && (lowc[mm] >= T_PRE_PARK - 2) &&
                !(rq_v[0] && q0_map[11:9] == mm) && !(rq_v[1] && q1_map[11:9] == mm)) begin
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
            sq <= SQ_IDLE; hc <= 3'd0; op_m <= 3'd0; op_park <= 1'b0; op_slot <= 3'd0; op_e <= 12'd0;
            for (i = 0; i < NM; i = i + 1) lowc[i] <= 5'd31;
            needs_park <= {NM{1'b0}}; expect_more <= {NM{1'b0}}; park_end <= {NM{1'b0}}; zcap <= 1'b0;
            rom_clk <= {NM{1'b0}}; rom_cs <= {NM{1'b0}}; rom_park <= 1'b0; rom_addr <= 9'd0;
            cap <= 1'b0; cap_m <= 3'd0; cap_slot <= 3'd0;
            pend <= 1'b0;
            n_lookup_reads <= 0; n_park_reads <= 0; n_stall_cycles <= 0; n_starts <= 0;
            err_mismatch <= 1'b0; err_lane0 <= 1'b0; err_queue <= 1'b0;
        end else begin
            cap      <= 1'b0;
            park_end <= {NM{1'b0}};
            if (cap) zcap <= cap_zero;

            for (i = 0; i < NM; i = i + 1)
                if (!rom_clk[i] && lowc[i] != 5'd31) lowc[i] <= lowc[i] + 5'd1;

            case (sq)
                SQ_IDLE: begin
                    if (q0_ok) begin                              // lookup read of the queue head
                        op_m <= q0_map[11:9]; op_park <= 1'b0; op_slot <= rq_s[0]; op_e <= rq_e[0];
                        rom_addr <= q0_map[8:0];
                        rom_park <= 1'b0;
                        sq <= SQ_SETUP;
                    end else if (pk_ok) begin                     // parking read
                        op_m <= pk_m; op_park <= 1'b1;
                        rom_addr <= PARK_ADDR;
                        rom_park <= 1'b1;
                        sq <= SQ_SETUP;
                    end
                end
                SQ_SETUP: begin
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
                            needs_park[op_m]  <= zcap;
`ifndef SYNTHESIS
                            n_lookup_reads    <= n_lookup_reads + 1;
`endif
                            expect_more[op_m] <= (layer_of(op_e) >= 3'd2) && (layer_of(op_e) <= 3'd4) &&
                                                 (layer_of(op_e + 12'd1) == layer_of(op_e)) &&
                                                 (nxt_map[11:9] == op_m);
                        end
                    end
                end
                default: sq <= SQ_IDLE;
            endcase

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

            key_q <= {layer_id, a0};
            key_init <= 1'b1;
            if (change) begin
                cur_v <= v0;
                if (v0) cur_slot <= hit ? hit_idx : slot_d;
            end
            if (new_d) begin tag[slot_d] <= e0;     tv[slot_d] <= 1'b1; dv[slot_d] <= 1'b0; end
            if (new_p) begin tag[slot_p] <= e_next; tv[slot_p] <= 1'b1; dv[slot_p] <= 1'b0; end
            ptr <= ptr + {2'd0, new_d} + {2'd0, new_p};

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
