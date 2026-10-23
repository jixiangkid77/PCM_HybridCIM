drc off
gds flatten true
gds ordering true
gds read /home/kid/p2r_e8/e8_4f/macro/sky130_sram_4kbytes_1rw_8x4096_8.gds
load sky130_sram_4kbytes_1rw_8x4096_8
select top cell
expand
readspice /home/kid/p2r_e8/e8_4f/macro/sky130_sram_4kbytes_1rw_8x4096_8.sp
extract do local
extract all
ext2spice hierarchy off
ext2spice format ngspice
ext2spice renumber off
ext2spice scale off
ext2spice blackbox on
ext2spice subcircuit top on
ext2spice global off
ext2spice rthresh infinite
ext2spice cthresh infinite
ext2spice -o /home/kid/p2r_e8/e8_4f/extract/sky130_sram_4kbytes_1rw_8x4096_8.flat_lvs.spice
ext2spice cthresh 0
ext2spice -o /home/kid/p2r_e8/e8_4f/extract/sky130_sram_4kbytes_1rw_8x4096_8.flat_pex.spice
quit -noprompt
