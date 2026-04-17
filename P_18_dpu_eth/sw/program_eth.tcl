set bit_file  [lindex $argv 0]
set fsbl_file [lindex $argv 1]
set elf_file  [lindex $argv 2]

connect
after 2000

set fpga_id ""
foreach t [targets -filter {name =~ "xc7z020*"}] {
    regexp {^\s*\*?\s*(\d+)} $t -> fpga_id; break
}
set arm_id ""
foreach t [targets -filter {name =~ "*Cortex-A9*#0" || name =~ "*ARM*#0"}] {
    regexp {^\s*\*?\s*(\d+)} $t -> arm_id; break
}
puts "fpga_id=$fpga_id arm_id=$arm_id"

targets $fpga_id
fpga $bit_file
after 2000

targets $arm_id
rst -processor
after 500
dow $fsbl_file
con
after 3000
stop

rst -processor
after 500
dow $elf_file
con
puts ">>> ELF running — Ethernet server should be up on 192.168.1.10"
disconnect
