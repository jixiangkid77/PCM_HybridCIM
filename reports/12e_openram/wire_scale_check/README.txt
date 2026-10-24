Why the analytical power of a macro generated with its layout is about 1e11 mW (2026-10-24)

OpenRAM 1.2.49 (commit e16d9eb) computes the capacitance of a wire in compiler/base/wire_spice_model.py as
    total_c = (spice["wire_unit_c"]*1e12) * wire_length * wire_width
with the comment "Convert the F/um^2 to fF/um^2 ... FIXME: shouldn't it be 1e15?", while the sky130
technology file gives spice["wire_unit_c"] = 0.134 already in fF/um^2, so every wire capacitance comes out
1e12 times too large. Without the layout (netlist_only = True) the wires have no length and the error does
not appear. In the analytical power the wires enter through the bit lines: each column of the bit-cell
array is charged the drain capacitance of its access transistors plus the capacitance of its wire
(gen_bl_wire and analytical_power of compiler/modules/bitcell_array.py and of the sky130 replica arrays).

Test on a small macro (8 bit x 16 words, configs/), three runs of the analytical model:
    netlist only, OpenRAM as released              Dynamic Power: 0.4064574865679999 mW   (logs/nl_orig.log)
    with the layout, OpenRAM as released           Dynamic Power: 1137299486.8064573 mW   (logs/lay_orig.log)
    with the layout, the factor 1e12 removed       Dynamic Power: 0.40759478605439986 mW  (logs/lay_patched.log)
The patch is wire_spice_model.patch. With the factor removed, the figure with the layout is 0.28% above the
netlist-only figure, and both layout runs exceed it by the same wire term (0.0011373 mW, scaled by 1e12 in the
run as released): the layout changes nothing else in the model. For the 4-KB macro the log of the generation
with its layout (reports/e8_rom/e8_4c/gen_sky130_sram_4kbytes_1rw_8x4096_8.log, the configuration of
reports/12e_openram/lib_20260608/ with netlist_only = False) gives 164965317866.21823 mW, so its wire term is
(164965317866.21823 - 11.818194) / 1e12 = 0.165 mW, 1.40% of the netlist-only 11.818 mW
(scripts/sram_lib_energy.py prints it). The 4-KB macro generated with its layout gets 1.649653e+11 in its
library (reports/12e_openram/macros/paper2_sram_pool_8x4096/, reports/e8_rom/e8_4c/, reports/e8_rom/e8_4f/),
against 11.81819 without the layout (reports/12e_openram/lib_20260608/).
Paths of the work folder and of the two OpenRAM copies are written as <work>, <openram> and <openram-patched>.
