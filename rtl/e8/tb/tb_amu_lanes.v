//============================================================
// tb_amu_lanes.v   (P2R-E8.5)
// Place  : rtl/e8/tb/
// Status : NEW FILE.
//============================================================
`timescale 1ns/1ps
// lanes 1..24 against the original decoder (LANE_ID = k): engine address patterns, zero, and random addresses
module tb_amu_lanes;
  reg [2:0] lid; reg [25*16-1:0] bus;
  wire v0; wire [11:0] e0; wire [8:0] flat0, in_dim; wire is_fc;
  wire [24:0] valid, mism;
  amu_entry UE (.layer_id(lid), .a0(bus[15:0]), .v0(v0), .e0(e0), .flat0(flat0), .in_dim(in_dim), .is_fc(is_fc));
  amu_lanes UL (.addr_bus(bus), .v0(v0), .flat0(flat0), .in_dim(in_dim), .is_fc(is_fc), .valid(valid), .mismatch(mism));
  function [12:0] ref_e;   // {valid, entry} of the original decoder for lane `ln`
    input [2:0] l; input [15:0] o16; input integer ln;
    reg [15:0] cc, oc, fl, sb, comp; reg ok;
    begin
      ref_e = 13'd0;
      case (l)
        0: begin cc = o16 / 25; ok = (o16 < 150) && (o16 % 25 == ln) && (cc < 6);   ref_e = {ok, cc[11:0]}; end
        1: begin cc = o16 / 25; ok = (o16 < 2400) && (o16 % 25 == ln) && (cc < 96); ref_e = {ok, 12'd6 + cc[11:0]}; end
        2: begin oc = o16 / 400; fl = o16 - oc*400; sb = (fl >= ln) ? (fl - ln) / 25 : 0; comp = (oc << 4) + sb;
                 ok = (o16 < 48000) && (fl % 25 == ln) && (comp < 1920); ref_e = {ok, 12'd102 + comp[11:0]}; end
        3: begin oc = o16 / 120; fl = o16 - oc*120; sb = (fl >= ln) ? (fl - ln) / 25 : 0; comp = oc*5 + sb;
                 ok = (o16 < 10080) && (fl % 25 == ln) && (comp < 420); ref_e = {ok, 12'd2022 + comp[11:0]}; end
        4: begin oc = o16 / 84; fl = o16 - oc*84; sb = (fl >= ln) ? (fl - ln) / 25 : 0; comp = (oc << 2) + sb;
                 ok = (o16 < 840) && (fl % 25 == ln) && (comp < 40); ref_e = {ok, 12'd2442 + comp[11:0]}; end
        default: ref_e = 13'd0;
      endcase
    end
  endfunction
  integer l, a, k, t, bad_pat, bad_rand, n_pat, n_rand, n_flag, n_tail;
  reg [12:0] r0, rk; reg [15:0] ak; reg engine_ok;
  initial begin
    bad_pat = 0; bad_rand = 0; n_pat = 0; n_rand = 0; n_flag = 0; n_tail = 0;
    for (l = 0; l < 5; l = l + 1)
      for (a = 0; a < 48000; a = a + 1) begin
        r0 = ref_e(l, a, 0);
        if (r0[12]) begin
        // engine pattern: a_k = a0 + k, or 0 for an FC lane past IN_DIM
        lid = l; bus = 0; bus[15:0] = a;
        for (k = 1; k < 25; k = k + 1) bus[k*16 +: 16] = a + k;
        #1;
        for (k = 1; k < 25; k = k + 1)
          if (is_fc && (flat0 + k >= in_dim)) bus[k*16 +: 16] = 0;
        #1;
        for (k = 1; k < 25; k = k + 1) begin
          rk = ref_e(l, bus[k*16 +: 16], k);
          n_pat = n_pat + 1;
          if (bus[k*16 +: 16] == 0) n_tail = n_tail + 1;
          if (rk[12] !== valid[k] || (valid[k] && rk[11:0] !== e0) || mism[k]) begin
            bad_pat = bad_pat + 1;
            if (bad_pat < 6) $display("PATTERN MISMATCH layer %0d a0 %0d lane %0d: ref %0d/%0d new %0d/%0d mism %0d", l, a, k, rk[12], rk[11:0], valid[k], e0, mism[k]);
          end
        end
        // random addresses on all lanes 1..24: a lane the original finds valid on another entry must be flagged
        for (t = 0; t < 2; t = t + 1) begin
          for (k = 1; k < 25; k = k + 1) bus[k*16 +: 16] = ($random & 1) ? (a + k) : ($random % 48000);
          #1;
          for (k = 1; k < 25; k = k + 1) begin
            rk = ref_e(l, bus[k*16 +: 16], k);
            n_rand = n_rand + 1;
            if (mism[k]) n_flag = n_flag + 1;
            // the new unit must either agree with the original or raise mismatch
            if (!mism[k] && (rk[12] !== valid[k] || (valid[k] && rk[11:0] !== e0))) begin
              bad_rand = bad_rand + 1;
              if (bad_rand < 6) $display("RANDOM SILENT MISMATCH layer %0d a0 %0d lane %0d addr %0d: ref %0d/%0d new %0d/%0d", l, a, k, bus[k*16 +: 16], rk[12], rk[11:0], valid[k], e0);
            end
          end
        end
        end
      end
    $display("lanes 1-24, engine pattern: %0d lane lookups (%0d FC dummy lanes), %0d mismatches", n_pat, n_tail, bad_pat);
    $display("lanes 1-24, random addresses: %0d lane lookups, %0d flagged, %0d silent mismatches", n_rand, n_flag, bad_rand);
    $finish;
  end
endmodule
