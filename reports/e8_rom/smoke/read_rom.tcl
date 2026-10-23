puts "TECH [tech name]"
gds read /mnt/d/Project/hybrid_memory/paper2/reports/12e_openram/macros/paper2_addr_decoder_8x5120/paper2_addr_decoder_8x5120.gds
load paper2_addr_decoder_8x5120
select top cell
puts "BOX_LAMBDA [box values]"
box
quit -noprompt
