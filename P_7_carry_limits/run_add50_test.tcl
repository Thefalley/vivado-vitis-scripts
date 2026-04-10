# run_add50_test.tcl - Synthesis + Implementation of add50_test
# Target: xc7z020clg484-1 @ 100 MHz

read_vhdl C:/project/vivado/P_7_carry_limits/src/add50_test.vhd
synth_design -top add50_test -part xc7z020clg484-1
create_clock -period 10.0 -name clk [get_ports clk]
opt_design
place_design
route_design

# --- Extract results ---
set outfile [open "C:/project/vivado/P_7_carry_limits/add50_result.txt" w]

# Timing
set timing_rpt [report_timing_summary -return_string]
puts $outfile "=== TIMING SUMMARY ==="
puts $outfile $timing_rpt

# Utilization
set util_rpt [report_utilization -return_string]
puts $outfile "\n=== UTILIZATION ==="
puts $outfile $util_rpt

# Extract WNS
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts $outfile "\n=== KEY METRICS ==="
puts $outfile "WNS (setup): $wns ns"

set period 10.0
set fmax [expr {1000.0 / ($period - $wns)}]
puts $outfile "Fmax: $fmax MHz"

if {$wns >= 0} {
    puts $outfile "RESULT: PASS - 50+50 meets timing at 100 MHz"
} else {
    puts $outfile "RESULT: FAIL - 50+50 does NOT meet timing at 100 MHz"
}

close $outfile

puts "=== DONE - results written to add50_result.txt ==="
puts "WNS = $wns ns"
