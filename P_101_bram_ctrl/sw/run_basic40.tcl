# run_basic40.tcl — Run basic40 test and read JTAG markers

set bit_file  "build/bit/bram_ctrl_bd_wrapper.bit"
set elf_file  "build/elf/bram_ctrl_test.elf"
set fsbl_file "build/elf/fsbl.elf"

puts "============================================"
puts "  BASIC 40-WORD TEST"
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

# App
puts "\[5\] Loading basic40 app..."
rst -processor
dow $elf_file
con
after 10000
stop

# Read markers
puts "\n============================================"
puts "  JTAG RESULTS"
puts "============================================"

set m0 [lindex [mrd -value 0x01200000 1] 0]
set m1 [lindex [mrd -value 0x01200004 1] 0]
set m2 [lindex [mrd -value 0x01200008 1] 0]
set m3 [lindex [mrd -value 0x0120000C 1] 0]

puts [format "  marker\[0\] = 0x%08X  (result)" $m0]
puts [format "  marker\[1\] = 0x%08X  (phase reached)" $m1]
puts [format "  marker\[2\] = 0x%08X  (first bad idx)" $m2]
puts [format "  marker\[3\] = 0x%08X  (first bad val)" $m3]

# Interpret marker[0]
set m0_hi [expr {($m0 >> 16) & 0xFFFF}]
if {$m0_hi == 0xCAFE} {
    puts "\n  >> PASS: 40/40 words matched!"
} elseif {$m0_hi == 0xDEAD} {
    set nerr [expr {$m0 & 0xFFFF}]
    puts "\n  >> FAIL: $nerr errors"
} elseif {$m0_hi == 0xBBBB} {
    set code [expr {$m0 & 0xFFFF}]
    if {$code == 1} {
        puts "\n  >> HUNG: MM2S DMA timeout (data never sent to FIFO)"
    } elseif {$code == 2} {
        puts "\n  >> HUNG: S2MM DMA timeout (data never returned from FIFO)"
    } else {
        puts "\n  >> HUNG: DMA timeout (code=$code)"
    }
} elseif {$m0_hi == 0xEEEE} {
    set code [expr {$m0 & 0xFFFF}]
    puts "\n  >> INIT ERROR: code=$code"
} elseif {$m0_hi == 0xAAAA} {
    puts "\n  >> App started but did not complete (stuck at phase $m1)"
    puts "     Phases: 1=DMA init, 2=fill, 3=nwords, 4=CMD_LOAD, 5=MM2S wait, 6=DRAIN, 7=S2MM wait, 8=verify, 9=done"
} else {
    puts "\n  >> UNKNOWN marker (app may not have run)"
}

# Read src[0..3] and dst[0..3]
puts "\n  --- Source ---"
set src_data [mrd -value 0x01000000 4]
for {set i 0} {$i < 4} {incr i} {
    puts [format "  src\[%d\] = 0x%08X" $i [lindex $src_data $i]]
}

puts "\n  --- Dest ---"
set dst_data [mrd -value 0x01100000 40]
for {set i 0} {$i < 40} {incr i} {
    set v [lindex $dst_data $i]
    set expected [expr {0xCAFE0000 + $i}]
    if {$v == $expected} {
        set tag "OK"
    } elseif {$v == 0} {
        set tag "ZERO (untouched)"
    } else {
        set tag "WRONG"
    }
    puts [format "  dst\[%2d\] = 0x%08X  %s" $i $v $tag]
}

puts "\n============================================"
disconnect
