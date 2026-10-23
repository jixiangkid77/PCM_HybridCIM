# Paper 2 ROM: drift LUT log2 (CONDITIONAL on 5.2 HW decision)
# RTL logical: 12-bit × 1024 = 12.29 Kbit
# Physical macro: 8-bit × 2048 = 16.38 Kbit (33% padding, 12-bit read via 1.5-byte burst)

word_size = 1
import os
rom_data = os.path.join(os.path.dirname(__file__), 'paper2_drift_lut_log2.bin')
data_type = "bin"
output_name = "paper2_drift_lut_log2_8x2048"
output_path = "macro/{output_name}".format(**locals())

exec(open(os.path.join(os.path.dirname(__file__), 'sky130_rom_common.py')).read())
check_lvsdrc = False
