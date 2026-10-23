# Paper 2 ROM macro: bias_storage (dense flat)
# RTL logical: 32 bit (4 byte) × 236 words = 7.552 Kbit
# Physical macro: 32 bit (4 byte) × 256 words = 8.192 Kbit (~8.5% padding)

word_size = 4   # bytes (= 32 bits per word)
import os
rom_data = os.path.join(os.path.dirname(__file__), 'paper2_bias_storage.bin')
data_type = "bin"
output_name = "paper2_bias_storage_32x256"
output_path = "macro/{output_name}".format(**locals())

exec(open(os.path.join(os.path.dirname(__file__), 'sky130_rom_common.py')).read())
check_lvsdrc = False
