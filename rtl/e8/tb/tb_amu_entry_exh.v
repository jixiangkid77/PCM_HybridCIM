//============================================================
// tb_amu_entry_exh.v   (P2R-E8.5)
// Place  : rtl/e8/tb/
// Status : NEW FILE.
//============================================================
`timescale 1ns/1ps
// exhaustive check of amu_entry against the original decoder arithmetic (LANE_ID = 0)
module tb_amu_entry_exh;
  reg [2:0] lid; reg [15:0] a;
  wire v0; wire [11:0] e0; wire [8:0] flat0, in_dim; wire is_fc;
  amu_entry U (.layer_id(lid), .a0(a), .v0(v0), .e0(e0), .flat0(flat0), .in_dim(in_dim), .is_fc(is_fc));
  // reference: the original decoder (rtl/src/sram_addr_decoder.v) for LANE_ID = 0
  function [12:0] ref_e;   // {valid, entry}
    input [2:0] l; input [15:0] o16;
    reg [15:0] cc, oc, fl, sb, comp; reg ok;
    begin
      ref_e = 13'd0;
      case (l)
        0: begin cc = o16 / 25; ok = (o16 < 150) && (o16 % 25 == 0) && (cc < 6);   ref_e = {ok, cc[11:0]}; end
        1: begin cc = o16 / 25; ok = (o16 < 2400) && (o16 % 25 == 0) && (cc < 96); ref_e = {ok, 12'd6 + cc[11:0]}; end
        2: begin oc = o16 / 400; fl = o16 - oc*400; sb = fl / 25; comp = (oc << 4) + sb;
                 ok = (o16 < 48000) && (fl % 25 == 0) && (comp < 1920); ref_e = {ok, 12'd102 + comp[11:0]}; end
        3: begin oc = o16 / 120; fl = o16 - oc*120; sb = fl / 25; comp = oc*5 + sb;
                 ok = (o16 < 10080) && (fl % 25 == 0) && (comp < 420); ref_e = {ok, 12'd2022 + comp[11:0]}; end
        4: begin oc = o16 / 84; fl = o16 - oc*84; sb = fl / 25; comp = (oc << 2) + sb;
                 ok = (o16 < 840) && (fl % 25 == 0) && (comp < 40); ref_e = {ok, 12'd2442 + comp[11:0]}; end
        default: ref_e = 13'd0;
      endcase
    end
  endfunction
  integer i, j, bad, nvalid; reg [12:0] r;
  initial begin
    bad = 0; nvalid = 0;
    for (i = 0; i < 8; i = i + 1)
      for (j = 0; j < 65536; j = j + 1) begin
        lid = i; a = j; #1;
        r = ref_e(lid, a);
        if (r[12] !== v0 || (v0 && r[11:0] !== e0)) begin
          bad = bad + 1;
          if (bad < 10) $display("MISMATCH layer %0d a0 %0d: ref valid %0d entry %0d, amu valid %0d entry %0d", i, j, r[12], r[11:0], v0, e0);
        end
        if (v0) nvalid = nvalid + 1;
      end
    $display("amu_entry exhaustive check: %0d vectors, %0d valid lookups, %0d mismatches", 8*65536, nvalid, bad);
    $finish;
  end
endmodule
