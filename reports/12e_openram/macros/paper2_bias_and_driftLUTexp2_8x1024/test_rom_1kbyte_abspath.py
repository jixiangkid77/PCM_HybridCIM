# Test config: same as sky130_rom_1kbyte.py but with absolute path
word_size = 1
import os
rom_data = "/home/kid/openram/OpenRAM/macros/rom_configs/example_1kbyte.bin"
data_type = "bin"
output_name = "test_rom_1kbyte_abspath"
output_path = "macro/{output_name}".format(**locals())

exec(open("/home/kid/openram/OpenRAM/macros/rom_configs/sky130_rom_common.py").read())
check_lvsdrc = False
