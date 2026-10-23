//============================================================
// conv1_cache.v   (P2R-E8.5e: register cache of the 150 conv1 weights)
//============================================================
// All 150 conv1 weights are protected weights in the SRAM pool
// (both models: every conv1 entry of the 25 SRAM-side address
// tables is a hit, slots 0..149 of conv1's pool region). conv1
// reads them 117,600 times per inference (6 output channels x
// 784 output pixels x 25 lanes), 44.0 % of the SRAM reads of
// model A and 57.2 % of model B. This block holds them in
// registers and sits between the address-map unit, the pool
// (the SRAM macros) and sram_mac, so that the macros are not
// clocked during conv1. All logic that E8.5e adds is in this
// module (synthesised on its own for its area and power).
//
// Organisation: lane l of conv1 only ever reads the weights of
// its kernel position for the 6 output channels (orig_addr =
// oc*25 + l, rtl/src/sram_addr_decoder.v: conv1 compact index
// orig_addr / 25), so each lane has its own 6 entries, entry
// l*6 + oc, and a 6:1 selection; there are no shared read ports.
//
// Per lane l, in cycle s:
//   sel  = sram_hit_pool[l] & (layer_id == 0)   (a conv1 hit)
//   idx  = orig_addr[l] / 25                     (oc, 0..5)
//   sram_hit_macro[l] = sram_hit_pool[l] & ~sel  (the pool reads
//          only the lanes that the cache does not serve)
// Timing, the same as the two-cycle SRAM read (E8.5c):
//   edge s+1 : sel/idx -> stage 1;  edge s+2 : -> stage 2
//   cycle s+2: the lane's weight and hit to sram_mac are the
//              cache's when stage 2 holds sel, else the pool's
//   edge s+3 : sram_mac registers the sum
// Only sel and idx are pipelined (4 bits per lane). The stages
// load only while a conv1 hit is in flight (enable = any sel in
// the request or the stages), so outside conv1 their clock can
// be gated.
//
// Loading: the host writes the entries at boot like the other
// configuration: wr_addr 0x22, wr_data[15:8] = entry l*6 + oc,
// [7:0] = weight (layer_config_regfile ignores this address). In
// simulation the storage starts from INIT_FILE ($readmemh, 150
// lines, written by scripts/e8_5e_cache_hex.py from the same data
// as the pool).
//
// Place  : rtl/e8/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

module conv1_cache #(
    parameter integer K          = 25,
    parameter integer DATA_WIDTH = 8,
    parameter integer ADDR_WIDTH = 16,
    parameter         INIT_FILE  = ""
)(
    input  wire                       clk,
    input  wire                       rst_n,
    // host configuration write (boot)
    input  wire                       wr_en,
    input  wire [5:0]                 wr_addr,
    input  wire [31:0]                wr_data,
    // lookups of cycle s
    input  wire [2:0]                 layer_id,
    input  wire [K*ADDR_WIDTH-1:0]    orig_addr_bus,
    input  wire [K-1:0]               sram_hit_pool,
    // to the pool: the lanes it reads
    output wire [K-1:0]               sram_hit_macro,
    // the pool's two-cycle output
    input  wire [K*DATA_WIDTH-1:0]    pool_weight_bus,
    input  wire [K-1:0]               pool_hit_reg_bus,
    // to sram_mac (cycle s+2)
    output wire [K*DATA_WIDTH-1:0]    weight_bus,
    output wire [K-1:0]               hit_reg_bus
);

    localparam integer NOC = 6;       // conv1 output channels

    // ---- storage (written at boot) ----
    reg [DATA_WIDTH-1:0] mem [0:K*NOC-1];
    integer i;
`ifndef SYNTHESIS
    // simulation: INIT_FILE, or +e85e_cache=<file> (lenet5_top and the
    // testbench pass no parameter for it and are not changed)
    reg [8*256-1:0] cfile;
    initial begin
        for (i = 0; i < K*NOC; i = i + 1) mem[i] = {DATA_WIDTH{1'b0}};
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
            $display("[E8.5e] conv1 cache loaded from %0s", INIT_FILE);
        end else if ($value$plusargs("e85e_cache=%s", cfile)) begin
            $readmemh(cfile, mem);
            $display("[E8.5e] conv1 cache loaded from %0s", cfile);
        end else begin
            $display("[E8.5e] conv1 cache: no contents given (INIT_FILE or +e85e_cache=)");
        end
    end
`endif
    wire       we    = wr_en && (wr_addr == 6'h22);
    wire [7:0] waddr = wr_data[15:8];
    always @(posedge clk) begin
        if (we && waddr < K*NOC) mem[waddr] <= wr_data[DATA_WIDTH-1:0];
    end

    // ---- requests of cycle s ----
    wire           is_conv1 = (layer_id == 3'd0);
    wire [K-1:0]   sel;
    wire [K*3-1:0] idx;
    genvar gl;
    generate
        for (gl = 0; gl < K; gl = gl + 1) begin: req
            wire [ADDR_WIDTH-1:0] o = orig_addr_bus[gl*ADDR_WIDTH +: ADDR_WIDTH];
            assign idx[gl*3 +: 3] = (o >= 125) ? 3'd5 : (o >= 100) ? 3'd4 : (o >= 75) ? 3'd3 :
                                    (o >=  50) ? 3'd2 : (o >=  25) ? 3'd1 : 3'd0;
            assign sel[gl] = sram_hit_pool[gl] & is_conv1;
        end
    endgenerate
    assign sram_hit_macro = sram_hit_pool & ~sel;

    // ---- two stages (sel, idx); loaded only while a conv1 hit is in flight ----
    reg [K-1:0]   sel_s1, sel_s2;
    reg [K*3-1:0] idx_s1, idx_s2;
    wire          en = (|sel) | (|sel_s1) | (|sel_s2);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sel_s1 <= {K{1'b0}};
            sel_s2 <= {K{1'b0}};
            idx_s1 <= {(K*3){1'b0}};
            idx_s2 <= {(K*3){1'b0}};
        end else if (en) begin
            sel_s1 <= sel;
            idx_s1 <= idx;
            sel_s2 <= sel_s1;
            idx_s2 <= idx_s1;
        end
    end

    // ---- cycle s+2: the lane's 6:1 selection, or the pool's output ----
    generate
        for (gl = 0; gl < K; gl = gl + 1) begin: out
            wire [2:0]            ix = idx_s2[gl*3 +: 3];
            wire [DATA_WIDTH-1:0] e0 = mem[gl*NOC + 0];
            wire [DATA_WIDTH-1:0] e1 = mem[gl*NOC + 1];
            wire [DATA_WIDTH-1:0] e2 = mem[gl*NOC + 2];
            wire [DATA_WIDTH-1:0] e3 = mem[gl*NOC + 3];
            wire [DATA_WIDTH-1:0] e4 = mem[gl*NOC + 4];
            wire [DATA_WIDTH-1:0] e5 = mem[gl*NOC + 5];
            wire [DATA_WIDTH-1:0] cw = (ix == 3'd0) ? e0 : (ix == 3'd1) ? e1 : (ix == 3'd2) ? e2 :
                                       (ix == 3'd3) ? e3 : (ix == 3'd4) ? e4 : e5;
            wire                  cv = sel_s2[gl];
            assign weight_bus[gl*DATA_WIDTH +: DATA_WIDTH] = cv ? cw : pool_weight_bus[gl*DATA_WIDTH +: DATA_WIDTH];
            assign hit_reg_bus[gl] = cv | pool_hit_reg_bus[gl];
        end
    endgenerate

endmodule
