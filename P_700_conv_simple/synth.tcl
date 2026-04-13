# synth.tcl — Sintesis standalone de conv_simple para xc7z020
set part xc7z020clg484-1
set top conv_simple

create_project -in_memory -part $part

# Add sources
add_files -norecurse {
    src/mul_s32x32_pipe.vhd
    src/mac_unit.vhd
    src/mac_array.vhd
    src/requantize.vhd
    src/conv_simple.vhd
}
add_files -fileset constrs_1 constrs/timing.xdc

set_property top $top [current_fileset]

# Synthesize
synth_design -top $top -part $part
report_timing_summary -file synth_timing.rpt
report_utilization -file synth_util.rpt

puts "=== TIMING ==="
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts "WNS = $wns ns"
if {$wns < 0} {
    puts "TIMING FAILED"
} else {
    puts "TIMING OK"
}

puts "=== UTILIZATION ==="
foreach r {LUT FF DSP BRAM} {
    set used [llength [get_cells -hierarchical -filter "PRIMITIVE_TYPE =~ *.$r.*"]]
}
puts "See synth_util.rpt for details"
puts "=== SYNTH DONE ==="
