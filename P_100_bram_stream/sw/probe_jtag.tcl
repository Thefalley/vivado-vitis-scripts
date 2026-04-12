# probe_jtag.tcl - Simple xsct script to verify JTAG cable + ZedBoard target
# Usage: xsct probe_jtag.tcl

puts ">>> Connecting to hw_server ..."
if {[catch {connect} err]} {
    puts "FAIL_CONNECT: $err"
    exit 2
}

puts ">>> Listing targets ..."
if {[catch {targets} err]} {
    puts "FAIL_TARGETS: $err"
    exit 3
}

set tgt_list [targets]
puts "RAW_TARGETS:"
puts $tgt_list

# Try to find a Zynq target
if {[catch {targets -set -nocase -filter {name =~ "*7z*" || name =~ "*Cortex*A9*"}} err]} {
    puts "FAIL_FILTER: $err"
    exit 4
}

puts "PROBE_OK: JTAG cable detected, Zynq target found."
disconnect
exit 0
