# Paper 2 macro: feature_buffer (single bank)
# RTL logical per bank: 8 bit x 4704 words = 37.632 Kbit
# Physical macro: 8 bit x 5120 words = 40.960 Kbit (8.8% padding)
# Total feature_buffer = 2 banks × this area (ping-pong)

word_size = 8
num_words = 5120
human_byte_size = "{:.0f}kbytes".format((word_size * num_words)/1024/8)
write_size = 8
num_rw_ports = 1
num_r_ports = 0
num_w_ports = 0
ports_human = '1rw'
num_spare_cols = 1
num_spare_rows = 1

import os
exec(open(os.path.join(os.path.dirname(__file__), 'sky130_sram_common.py')).read())
output_name = "sky130_sram_5kbytes_1rw_8x5120_8"
output_path = "/home/kid/p2r_e8/e8_4c5k/macro/"
netlist_only = False
check_lvsdrc = False
