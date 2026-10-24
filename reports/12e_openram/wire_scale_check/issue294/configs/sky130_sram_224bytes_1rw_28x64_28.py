# Configuration described in OpenRAM issue #294 (word_size 28, num_words 64, one read-write port,
# one spare row and one spare column, write_size 28, words_per_row 1).
word_size = 28
num_words = 64
write_size = 28
words_per_row = 1
num_rw_ports = 1
num_r_ports = 0
num_w_ports = 0
num_spare_rows = 1
num_spare_cols = 1
human_byte_size = "224bytes"
ports_human = '1rw'
import os
exec(open(os.path.join(os.path.dirname(__file__), 'sky130_sram_common.py')).read())
