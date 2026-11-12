//============================================================
// amu9_decode.v   (P2R-E9.1, address-map unit with one word per entry)
//============================================================
// The slots of the 25 lanes from the buffered word of the current
// entry (scripts/e9_1_tables.py):
//   w[24:0]   lane k: 0 = protected, 1 = not protected / no weight
//   w[36:25]  NOT of the count of protected weights before the
//             entry in its layer
// For a lane k that looks up the current entry (valid[k], the
// lane check of amu_lanes and the entry in the buffer):
//   pre(k)     = protected lanes 0..k-1 of the word
//   SRAM slot  = count + pre(k)                    if protected
//   PCM  slot  = a(k) - count - pre(k)             if not protected
// with a(k) the lane's original weight address (= a0 + k, checked
// by amu_lanes). The other side, and every side of a lane that is
// not valid, gives 0xFFFF ("no slot"), so the hit / out-of-range
// logic of the original decoders (rtl/src/sram_addr_decoder.v,
// pcm_addr_decoder.v; rtl/e8/amu_table.v) applies unchanged:
//   raw_hit = slot != 0xFFFF;  pool = base + slot
//   oor     = raw_hit && (slot >= size || pool >= TOTAL)
//   hit     = raw_hit && !oor;  pool_addr = hit ? pool : 0
// No flip-flops.
//
// Place  : rtl/e9/
// Status : NEW FILE.
//============================================================

`timescale 1ns/1ps

module amu9_decode #(
    parameter integer K          = 25,
    parameter integer ADDR_WIDTH = 16,
    parameter integer SRAM_TOTAL = 3074,
    parameter integer PCM_TOTAL  = 58396
)(
    input  wire [36:0]             word,
    input  wire [K*ADDR_WIDTH-1:0] addr_bus,
    input  wire [K-1:0]            valid,
    input  wire [15:0]             sram_base,
    input  wire [15:0]             sram_size,
    input  wire [15:0]             pcm_base,
    input  wire [15:0]             pcm_size,
    output wire [K-1:0]            sram_hit,
    output wire [K-1:0]            sram_oor,
    output wire [K*ADDR_WIDTH-1:0] sram_pool_addr_bus,
    output wire [K-1:0]            pcm_hit,
    output wire [K-1:0]            pcm_oor,
    output wire [K*ADDR_WIDTH-1:0] pcm_pool_addr_bus
);
    wire [K-1:0]  prot  = ~word[K-1:0];
    wire [11:0]   count = ~word[36:25];

    // prefix counts of the protected lanes: pre[k] = protected lanes 0..k-1
    wire [4:0] pre [0:K-1];
    assign pre[0] = 5'd0;
    genvar k;
    generate
        for (k = 1; k < K; k = k + 1) begin : pfx
            assign pre[k] = pre[k-1] + {4'd0, prot[k-1]};
        end
        for (k = 0; k < K; k = k + 1) begin : lane
            wire [15:0] a_k     = addr_bus[k*ADDR_WIDTH +: 16];
            wire [15:0] n_bef   = {4'd0, count} + {11'd0, pre[k]};          // protected weights before this one
            wire [15:0] s_slot  = (valid[k] &&  prot[k]) ? n_bef         : 16'hFFFF;
            wire [15:0] p_slot  = (valid[k] && !prot[k]) ? a_k - n_bef   : 16'hFFFF;
            // ---- the original decoders' hit / out-of-range logic ----
            wire        s_raw   = (s_slot != 16'hFFFF);
            wire [16:0] s_pool  = {1'b0, sram_base} + {1'b0, s_slot};
            wire        s_oor   = s_raw && ((s_slot >= sram_size) || (s_pool >= SRAM_TOTAL));
            wire        p_raw   = (p_slot != 16'hFFFF);
            wire [16:0] p_pool  = {1'b0, pcm_base} + {1'b0, p_slot};
            wire        p_oor   = p_raw && ((p_slot >= pcm_size) || (p_pool >= PCM_TOTAL));
            assign sram_oor[k] = s_oor;
            assign sram_hit[k] = s_raw & ~s_oor;
            assign sram_pool_addr_bus[k*ADDR_WIDTH +: ADDR_WIDTH] = (s_raw & ~s_oor) ? s_pool[15:0] : 16'd0;
            assign pcm_oor[k]  = p_oor;
            assign pcm_hit[k]  = p_raw & ~p_oor;
            assign pcm_pool_addr_bus[k*ADDR_WIDTH +: ADDR_WIDTH]  = (p_raw & ~p_oor) ? p_pool[15:0] : 16'd0;
        end
    endgenerate
endmodule
