set bit_file  [lindex $argv 0]
set fsbl_file [lindex $argv 1]
set elf_file  [lindex $argv 2]

connect
after 1000

set fpga_id ""
foreach t [targets -filter {name =~ "xc7z020*"}] {
    regexp {^\s*\*?\s*(\d+)} $t -> fpga_id; break
}
set arm_id ""
foreach t [targets -filter {name =~ "*Cortex-A9*#0" || name =~ "*ARM*#0"}] {
    regexp {^\s*\*?\s*(\d+)} $t -> arm_id; break
}
puts "fpga_id=$fpga_id arm_id=$arm_id"

# 1. System-level reset (PS + PL) via rst -srst
targets $arm_id
puts ">>> rst -srst (system reset)"
catch {rst -srst}
after 2000

# 2. Re-load bitfile (fresh FPGA state)
targets $fpga_id
puts ">>> fpga load"
fpga $bit_file
after 2000

# 3. Processor reset + FSBL
targets $arm_id
puts ">>> rst -processor"
rst -processor
after 500
puts ">>> dow fsbl"
dow $fsbl_file
con
after 3000
stop

# 4. Reset again + load application
rst -processor
after 500
puts ">>> dow ELF"
dow $elf_file
con
puts ">>> ELF running after full reset"
disconnect
