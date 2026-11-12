# P2R-E10.1: one bank of the banked protected-weight pool (rtl/e10/sram_bank_128x8.v)
# the configuration of the manuscript's 4-KB macro (reports/e8_rom/e8_4f/configs/) with num_words and words_per_row
word_size = 8
num_words = 128
words_per_row = 4
human_byte_size = "{:.0f}bytes".format((word_size * num_words)/8)
write_size = 8
num_rw_ports = 1
num_r_ports = 0
num_w_ports = 0
ports_human = '1rw'
num_spare_cols = 1
num_spare_rows = 1

import os
exec(open(os.path.join(os.path.dirname(__file__), 'sky130_sram_common.py')).read())
output_name = "sky130_sram_128bytes_1rw_8x128_8"
output_path = "/home/kid/p2r_e10/e10_1f/libgen_l689/out/"
netlist_only = True
check_lvsdrc = False
