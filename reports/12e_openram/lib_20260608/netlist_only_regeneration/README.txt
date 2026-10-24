Rerun of the generation of the timing library in reports/12e_openram/lib_20260608/ (2026-10-24)

OpenRAM 1.2.49 (commit e16d9eb), sky130, run as
    python3 -u sram_compiler.py -v sky130_sram_4kbytes_1rw_8x4096_8.py
with the macro configuration reports/12e_openram/configs/paper2_sram_pool_8x4096.py (copied here by
OpenRAM as sky130_sram_4kbytes_1rw_8x4096_8.py) and reports/e8_rom/e8_4c/configs/sky130_sram_common.py
(here, with output_path set to the work folder): netlist_only = True, analytical_delay = True,
use_specified_load_slew = [(6.89, 0.005)]. With this option the compiler writes in the log the warning
"Using the option "use_specified_load_slew" will make load slew,data in lib file inaccurate."; the same
generation with the compiler's default loads is in reports/12e_openram/lib_default_loads/.

Result: the library written by this run is byte for byte the one in reports/12e_openram/lib_20260608/
(7,836 bytes, md5 c4ee11c6c22a186c87835cac9590ec35), so it is not stored twice. The compiler's log
(sky130_sram_4kbytes_1rw_8x4096_8.log) reports the analytical figures that the library carries:
    Netlist only mode (no physical design is being done ...)
    Dynamic Power: 11.818194269111972 mW
    Leakage Power: 0.034375 mW
The leakage is the compiler's placeholder of 1 nW for every bit cell and gate (technology/sky130/tech/tech.py:
bitcell_leakage, inv_leakage, nand2_leakage, ..., dff_leakage = 1, under the comment "analytical power
parameters, many values are temporary"); the bit-cell array of 257 x 129 cells (see the log) gives 33.153 uW
of the 34.375 uW. The dynamic power uses spice["default_event_frequency"] = 100 (MHz) of the same file.
power_breakdown.txt splits the analytical power of this run over the modules of the macro:
scripts/openram_power_breakdown.py, run in the OpenRAM installation with the two configuration files here,
builds the macro as sram_compiler.py does (about 40 minutes, no file written) and evaluates the same
analytical_power. The split adds up to the logged 11.818194269 mW and 34.375 uW: 6.53 mW from the 258 word-line
drivers (those of the 257 rows and of the replica bit line, 25.31 uW each), 3.76 mW from the bit lines (each of
the 129 columns charged 257 x 0.7 fF through half the supply), 1.53 mW from the other gates, nothing from the
sense amplifiers; the leakage is 33.153 uW for the bit cells and 1 nW for each of the 1,222 gates. The same file
gives the split by the module that holds each instance (the 257 word-line drivers are in wordline_driver, the
one of the replica bit line in an and2_dec) and the model's figure with the compiler's default loads (1.7225,
6.89 and 27.56 fF; the model takes the last, 27.56 fF), 14.7287 mW, the figure of the library in
reports/12e_openram/lib_default_loads/.
datasheet.info is the compiler's datasheet record of the same run. Paths of the work folder, of the
OpenRAM installation and of temporary folders are written as <work>, <openram> and <tmp>.
