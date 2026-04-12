# program.tcl - P_400 ETH Debug: Program via JTAG (FSBL flow)
# Same sequence as P_101/P_13 that works on this ZedBoard
#
# Usage: xsct program.tcl

set base_dir [file dirname [file normalize [info script]]]
set bit_file  $base_dir/hw_p101/bram_ctrl.bit
set fsbl_file $base_dir/fsbl.elf
set elf_file  $base_dir/p400_eth.elf

puts "\n=== P_400 ETH Debug ==="

# Connect
puts "Conectando a ZedBoard ..."
connect
after 2000
targets

# Program FPGA
puts "\nProgramando bitstream ..."
targets -set -nocase -filter {name =~ "*7z*" || name =~ "*PL*" || name =~ "*xc7z*"}
fpga $bit_file
after 2000

# Load and run FSBL (initializes DDR, clocks, MIO, Ethernet PHY)
puts "\nCargando FSBL ..."
targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}
rst -processor
dow $fsbl_file
con
after 10000
stop

# Now load application
puts "\nCargando aplicacion ..."
rst -processor
dow $elf_file
con

puts "\n========================================="
puts "  P_400 ETH Debug RUNNING"
puts "  Board IP: 192.168.1.10"
puts "  Test:     ping 192.168.1.10"
puts "  Debug:    python pc/eth_debug.py"
puts "========================================="
