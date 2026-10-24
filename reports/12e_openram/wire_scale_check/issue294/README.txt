The configuration of OpenRAM issue #294 (2026-10-24)

OpenRAM issue #294, "Incorrect internal_power values in generated SKY130 Liberty files"
(https://github.com/VLSIDA/OpenRAM/issues/294), reports clk0 internal_power entries of 1.034875e+10 in the timing
library of the sky130 macro sky130_sram_224bytes_1rw_28x64_28 (28 bits x 64 words, one read-write port, one spare
row and one spare column, write_size 28, words_per_row 1). That configuration (configs/, with the compiler's
macros/sram_configs/sky130_sram_common.py except check_lvsdrc = False, use_nix = False and spice_name = "ngspice",
which this environment needs, and the output folder) was run with OpenRAM 1.2.49 (commit e16d9eb) as
    python3 -u sram_compiler.py -v sky130_sram_224bytes_1rw_28x64_28.py
with the layout (netlist_only is not set) and the analytical model (the default), once as released and once with
the factor 1e12 removed from compiler/base/wire_spice_model.py (../wire_spice_model.patch):
    as released       Dynamic Power: 10348750643.988943 mW   library entries 1.034875e+10   (orig/)
    factor removed    Dynamic Power: 2.399287883313599 mW    library entries 2.399288e+00   (patched/)
The run as released gives the value reported in the issue; without the factor the figure is 2.40 mW, of which the
bit-line wires are 0.0103 mW ((10348750643.988943 - 2.399287883313599) / (1e12 - 1)). The two libraries differ
only in these eight entries. The configuration sets no loads, so the compiler takes its default loads (1.7225, 6.89
and 27.56 fF); each run took about 3 minutes. orig/ and patched/ hold the compiler's log and the library of each
run. Paths of the work folder, of the two OpenRAM copies and of temporary folders are written as <work>, <openram>,
<openram-patched> and <tmp>.
