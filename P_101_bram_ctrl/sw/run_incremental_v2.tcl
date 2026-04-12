# run_incremental_v2.tcl — Run incremental test v2 and read diagnostics

set bit_file  "build/bit/bram_ctrl_bd_wrapper.bit"
set elf_file  "build/elf/bram_ctrl_test.elf"
set fsbl_file "build/elf/fsbl.elf"

puts "============================================"
puts "  INCREMENTAL TEST V2"
puts "============================================"

# Connect
puts "\n\[1\] Connecting..."
connect
after 2000

# System reset
puts "\[2\] System reset..."
catch {
    targets -set -nocase -filter {name =~ "*DAP*"}
    rst -system
}
after 3000

# Program bitstream
puts "\[3\] Programming bitstream..."
targets -set -nocase -filter {name =~ "*7z*" || name =~ "*xc7z*"}
fpga $bit_file
after 3000

# FSBL
puts "\[4\] Loading FSBL..."
targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}
rst -processor
dow $fsbl_file
con
after 5000
stop

# App — give 30 seconds for 7 iterations + verify
puts "\[5\] Loading incremental_test_v2 app..."
rst -processor
dow $elf_file
con
after 30000
stop

# Read markers
puts "\n============================================"
puts "  JTAG DIAGNOSTIC MARKERS"
puts "============================================"

set m0 [lindex [mrd -value 0x01200000 1] 0]
set m1 [lindex [mrd -value 0x01200004 1] 0]
set m2 [lindex [mrd -value 0x01200008 1] 0]
set m3 [lindex [mrd -value 0x0120000C 1] 0]
set m4 [lindex [mrd -value 0x01200010 1] 0]
set m5 [lindex [mrd -value 0x01200014 1] 0]
set m6 [lindex [mrd -value 0x01200018 1] 0]

puts [format "  \[0\] result            = 0x%08X" $m0]
puts [format "  \[1\] iters completed   = %d" $m1]
puts [format "  \[2\] current iteration = %d" $m2]
puts [format "  \[3\] current phase     = %d" $m3]
puts [format "  \[4\] first bad idx     = 0x%08X" $m4]
puts [format "  \[5\] first bad dst val = 0x%08X" $m5]
puts [format "  \[6\] first bad expect  = 0x%08X" $m6]

# Interpret result
set m0_hi [expr {($m0 >> 16) & 0xFFFF}]
if {$m0_hi == 0xCAFE} {
    puts "\n  >> PASS: All 260 words matched!"
} elseif {$m0_hi == 0xDEAD} {
    set nerr [expr {$m0 & 0xFFFF}]
    puts "\n  >> FAIL: $nerr errors"
    puts "     First bad at index $m4: got [format 0x%08X $m5], expected [format 0x%08X $m6]"
} elseif {$m0_hi == 0xBBBB} {
    set iter [expr {($m0 >> 8) & 0xFF}]
    set phase [expr {$m0 & 0xFF}]
    if {$phase == 1} {
        puts "\n  >> HUNG: MM2S timeout at iteration $iter"
    } elseif {$phase == 2} {
        puts "\n  >> HUNG: S2MM timeout at iteration $iter"
    } else {
        puts "\n  >> HUNG: timeout at iteration $iter, phase $phase"
    }
    puts "     Completed $m1 iterations before timeout"
} elseif {$m0_hi == 0xEEEE} {
    set code [expr {$m0 & 0xFFFF}]
    puts "\n  >> INIT ERROR: code=$code"
} elseif {$m0 == 0} {
    puts "\n  >> App did not start or markers not written"
    puts "     Phase=$m3 at iteration $m2"
} else {
    puts "\n  >> UNKNOWN marker state"
}

# Read src[0..3]
puts "\n  --- Source (first 4) ---"
set src_data [mrd -value 0x01000000 4]
for {set i 0} {$i < 4} {incr i} {
    puts [format "  src\[%d\] = 0x%08X" $i [lindex $src_data $i]]
}

# Read dst: first few words of each chunk boundary
puts "\n  --- Dest (chunk boundaries) ---"
for {set chunk 0} {$chunk < 7} {incr chunk} {
    set base [expr {$chunk * 40}]
    set addr [expr {0x01100000 + $base * 4}]
    set data [mrd -value $addr 4]
    for {set j 0} {$j < 4} {incr j} {
        set idx [expr {$base + $j}]
        set v [lindex $data $j]
        set expected [expr {0xCAFE0000 + $idx}]
        if {$v == $expected} {
            set tag "OK"
        } elseif {$v == 0} {
            set tag "ZERO"
        } else {
            set tag "WRONG"
        }
        puts [format "  dst\[%3d\] = 0x%08X  %s  (expect 0x%08X)" $idx $v $tag $expected]
    }
    puts "  ..."
}

puts "\n============================================"
disconnect
