Timing library of the 4-KB SRAM macro generated with the compiler's default loads (2026-10-24)

OpenRAM 1.2.49 (commit e16d9eb), sky130, run as
    python3 -u sram_compiler.py -v sky130_sram_4kbytes_1rw_8x4096_8.py
with the configuration of reports/12e_openram/lib_20260608/netlist_only_regeneration/ (netlist_only = True,
analytical_delay = True) except that use_specified_load_slew is not set (sky130_sram_common.py here, with
output_path set to the work folder), so that the compiler takes its default loads and slews: load_scales x
dff_in_cap = 1.7225, 6.89 and 27.56 fF (compiler/globals.py; compiler/characterizer/lib.py, prepare_tables).

The compiler's log (sky130_sram_4kbytes_1rw_8x4096_8.log) reports
    Loads: [ 1.7225  6.89   27.56  ]
    Dynamic Power: 14.72870639404804 mW
    Leakage Power: 0.034375 mW
The analytical model takes the last load, 27.56 fF (compiler/characterizer/elmore.py, analytical_power: "only last
load is used"), and the library writes the result into every clk0 internal_power entry, 1.472871e+01, for reads,
writes and a deselected port alike, against 1.181819e+01 with the single load of 6.89 fF in
reports/12e_openram/lib_20260608/. A gate-level power analysis therefore charges 29.46 pJ for a read. The figure
equals the one that scripts/openram_power_breakdown.py computes for these loads
(reports/12e_openram/lib_20260608/netlist_only_regeneration/power_breakdown.txt). The leakage is the same, the
minimum period of clk0 is 1.769 ns, and dout0 follows the falling clock edge by 0.333 to 0.478 ns.
scripts/sram_lib_energy.py prints this library with the others. datasheet.info is the compiler's datasheet record
of the run. Paths of the work folder, of the OpenRAM installation and of temporary folders are written as <work>,
<openram> and <tmp>.
