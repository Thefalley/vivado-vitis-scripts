set bit_file  [lindex $argv 0]
set elf_file  [lindex $argv 1]
set fsbl_file [lindex $argv 2]

connect
after 2000

# Show all targets for debugging
puts "Available targets:"
targets

# Try targets 4 (FPGA on multi-target ZedBoard setup)
# Fall back to xc7z020 if target 4 doesn't exist
if {[catch {targets 4}]} {
    puts "Target 4 not found, looking for xc7z020..."
    set fpga_id ""
    foreach t [targets -filter {name =~ "xc7z020*"}] {
        regexp {^\s*(\d+)} $t -> fpga_id
        break
    }
    if {$fpga_id eq ""} {
        puts "ERROR: No FPGA target found"
        exit 1
    }
    targets $fpga_id
}
fpga $bit_file
after 2000

# Show targets again after FPGA programming (ARM should appear)
puts "Targets after FPGA programming:"
targets

# Try target 2 for ARM (standard ZedBoard)
# Fall back to finding ARM core dynamically
if {[catch {targets 2; rst -processor}]} {
    puts "Target 2 reset failed, looking for ARM core..."
    set arm_id ""
    foreach t [targets -filter {name =~ "*Cortex-A9*#0" || name =~ "*ARM*#0"}] {
        regexp {^\s*(\d+)} $t -> arm_id
        break
    }
    if {$arm_id eq ""} {
        puts "ERROR: No ARM target found"
        exit 1
    }
    targets $arm_id
    rst -processor
}
dow $fsbl_file
con
after 5000
stop
rst -processor
dow $elf_file
con

puts "\nEsperando resultado..."
set timeout 120
set elapsed 0
while {$elapsed < $timeout} {
    after 2000
    set elapsed [expr {$elapsed + 2}]
    stop
    set magic [lindex [mrd -value 0x10200000 1] 0]
    con
    if {$magic == 0xDEAD1234} { break }
}
after 500
stop
set res [mrd -value 0x10200000 3]
puts "\n========================================="
puts "  P_16 Conv + DataMover -- RESULTADO JTAG"
puts "========================================="
puts "  Total: [lindex $res 1] tests"
puts "  Errors: [lindex $res 2]"
if {[lindex $res 2] == 0} { puts "  >>> ALL PASSED -- Conv v3 + DataMover S2MM OK <<<" } else { puts "  >>> FAILED <<<" }
puts "========================================="
