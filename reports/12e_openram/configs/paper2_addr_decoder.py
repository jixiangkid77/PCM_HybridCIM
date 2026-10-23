# Paper 2 ROM: address-mapping decoder (per lane, × 50 instances)
# RTL logical: 16-bit × 2482 entries = 39.71 Kbit per decoder
# Physical macro: 8-bit × 5120 = 40.96 Kbit (3.1% padding, 16-bit read via 2-byte burst)

word_size = 1
import os
rom_data = os.path.join(os.path.dirname(__file__), 'paper2_addr_decoder.bin')
data_type = "bin"
output_name = "paper2_addr_decoder_8x5120"
output_path = "macro/{output_name}".format(**locals())

exec(open(os.path.join(os.path.dirname(__file__), 'sky130_rom_common.py')).read())
check_lvsdrc = False
