# dap_fix.tcl - Clear DAP sticky errors via low-level JTAG
# Then connect and try to access ARM cores

connect
puts "=== Before fix ==="
puts "Debug targets:"
targets
puts "\nJTAG targets:"
jtag targets

# Try to select the DAP via JTAG and clear errors
puts "\n=== Attempting DAP recovery ==="
jtag targets -set -filter {name =~ "*4ba00477*" || name =~ "*DAP*" || name =~ "*dap*"}
puts "Selected JTAG target: [jtag targets -filter {is_current}]"

# Lock JTAG for exclusive access
jtag lock

# DAP has 4-bit IR. IR=0x8 is ABORT register.
# Write to ABORT to clear STICKYERR(bit1) and WDATAERR(bit3): value=0x1E
# JTAG format: shift IR(4 bits), then shift DR(35 bits for DAP)

# Step 1: Write ABORT register to clear all sticky errors
# IR = 0x8 (ABORT), DR = 0x1E (clear all error flags)
jtag sequence 4 -state IDLE -tdi 0x8
jtag sequence 35 -state IDLE -tdi 0x1E

# Step 2: Write CTRL/STAT via DPACC to power up debug+system
# IR = 0xA (DPACC)
# DR format for DAP: [DATA(32)][ADDR(2)][RnW(1)] = 35 bits total
# CTRL/STAT addr=0x4 (2-bit DP addr = 0b01), write (RnW=0)
# DATA = 0x50000000 (CSYSPWRUPREQ | CDBGPWRUPREQ)
# Full 35-bit value: 0x50000000 << 3 | 0b010 = 0x280000002
jtag sequence 4 -state IDLE -tdi 0xA
jtag sequence 35 -state IDLE -tdi 0x280000002

jtag unlock

puts "\n=== After fix ==="
# Force re-enumeration of targets
disconnect
after 1000
connect
puts "Debug targets:"
targets
