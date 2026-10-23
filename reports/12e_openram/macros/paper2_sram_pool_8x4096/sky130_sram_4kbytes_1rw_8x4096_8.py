# Paper 2 macro: sram_pool_25lane physical macro
# RTL logical: 8 bit x 3074 words = 24.592 Kbit
# Physical macro: 8 bit x 4096 words = 32.768 Kbit
# 1 spare col + 1 spare row required by OpenRAM array organization

word_size = 8
num_words = 4096
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
