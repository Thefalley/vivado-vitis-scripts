# probe2.tcl — Deep diagnosis: check if app hung during first iteration
#
# Reads wider ranges to see:
# 1. Did memset(dst, 0xAA) happen? Check dst[40..79] — should be 0xAAAAAAAA if
#    the app only completed iteration 0's DMA but hung on iteration 1
# 2. Check the DMA registers to see if a transfer is stuck
# 3. Check the AXI-Lite registers (ctrl_cmd, n_words)

set bit_file  "build/bit/bram_ctrl_bd_wrapper.bit"
set elf_file  "build/elf/bram_ctrl_test.elf"
set fsbl_file "build/elf/fsbl.elf"

puts "============================================"
puts "  PROBE2: Deep Diagnostic"
puts "============================================"

# Connect, program, run
puts "\n\[1\] Connecting..."
connect
after 2000

puts "\n\[2\] System reset..."
catch {
    targets -set -nocase -filter {name =~ "*DAP*"}
    rst -system
}
after 3000

puts "\n\[3\] Programming bitstream..."
targets -set -nocase -filter {name =~ "*7z*" || name =~ "*xc7z*"}
fpga $bit_file
after 3000

puts "\n\[4\] Loading FSBL..."
targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}
rst -processor
dow $fsbl_file
con
after 5000
stop

puts "\n\[5\] Loading app..."
rst -processor
dow $elf_file
con

# Wait 20 seconds for the app
after 20000
stop

puts "\n============================================"
puts "  DETAILED MEMORY DUMP"
puts "============================================"

# Source buffer first 8
puts "\n  --- src\[0..7\] ---"
set src_data [mrd -value 0x01000000 8]
for {set i 0} {$i < 8} {incr i} {
    puts [format "  src\[%d\] = 0x%08X" $i [lindex $src_data $i]]
}

# Destination buffer: first 48 (covers first chunk + start of second)
puts "\n  --- dst\[0..47\] (first chunk=0..39, second=40..47) ---"
set dst_data [mrd -value 0x01100000 48]
for {set i 0} {$i < 48} {incr i} {
    set v [lindex $dst_data $i]
    set expected [expr {0xCAFE0000 + $i}]
    if {$v == $expected} {
        set tag "OK"
    } elseif {$v == 0xAAAAAAAA} {
        set tag "UNTOUCHED (0xAA fill)"
    } else {
        set tag "GARBAGE"
    }
    puts [format "  dst\[%3d\] = 0x%08X  %s" $i $v $tag]
}

# Result marker
puts "\n  --- Result marker ---"
set marker [lindex [mrd -value 0x01200000 1] 0]
puts [format "  marker = 0x%08X" $marker]

# DMA registers (0x40400000)
puts "\n  --- DMA Registers (0x40400000) ---"
set dma_base 0x40400000
# MM2S
set mm2s_cr     [lindex [mrd -value [expr {$dma_base + 0x00}] 1] 0]
set mm2s_sr     [lindex [mrd -value [expr {$dma_base + 0x04}] 1] 0]
set mm2s_sa     [lindex [mrd -value [expr {$dma_base + 0x18}] 1] 0]
set mm2s_len    [lindex [mrd -value [expr {$dma_base + 0x28}] 1] 0]
# S2MM
set s2mm_cr     [lindex [mrd -value [expr {$dma_base + 0x30}] 1] 0]
set s2mm_sr     [lindex [mrd -value [expr {$dma_base + 0x34}] 1] 0]
set s2mm_da     [lindex [mrd -value [expr {$dma_base + 0x48}] 1] 0]
set s2mm_len    [lindex [mrd -value [expr {$dma_base + 0x58}] 1] 0]

puts [format "  MM2S_DMACR  = 0x%08X" $mm2s_cr]
puts [format "  MM2S_DMASR  = 0x%08X  (bit1=idle, bit0=halted)" $mm2s_sr]
puts [format "  MM2S_SA     = 0x%08X" $mm2s_sa]
puts [format "  MM2S_LENGTH = 0x%08X  (%d bytes)" $mm2s_len $mm2s_len]
puts [format "  S2MM_DMACR  = 0x%08X" $s2mm_cr]
puts [format "  S2MM_DMASR  = 0x%08X  (bit1=idle, bit0=halted)" $s2mm_sr]
puts [format "  S2MM_DA     = 0x%08X" $s2mm_da]
puts [format "  S2MM_LENGTH = 0x%08X  (%d bytes)" $s2mm_len $s2mm_len]

# Check for DMA errors
set mm2s_err [expr {($mm2s_sr >> 4) & 0x7}]
set s2mm_err [expr {($s2mm_sr >> 4) & 0x7}]
if {$mm2s_err != 0} {
    puts "  ** MM2S DMA ERROR bits: [format 0x%X $mm2s_err]"
}
if {$s2mm_err != 0} {
    puts "  ** S2MM DMA ERROR bits: [format 0x%X $s2mm_err]"
}

# AXI-Lite registers (0x40000000)
puts "\n  --- AXI-Lite Registers (0x40000000) ---"
set ctrl_cmd [lindex [mrd -value 0x40000000 1] 0]
set n_words  [lindex [mrd -value 0x40000004 1] 0]
puts [format "  ctrl_cmd = 0x%08X" $ctrl_cmd]
puts [format "  n_words  = 0x%08X  (%d)" $n_words $n_words]

# ARM PC register (tells us where the app is stuck)
puts "\n  --- ARM State ---"
catch {
    set pc_val [rrd pc]
    puts "  PC: $pc_val"
}

puts "\n============================================"
puts "  ANALYSIS"
puts "============================================"

# Interpret DMA status
set mm2s_halted [expr {$mm2s_sr & 1}]
set mm2s_idle   [expr {($mm2s_sr >> 1) & 1}]
set s2mm_halted [expr {$s2mm_sr & 1}]
set s2mm_idle   [expr {($s2mm_sr >> 1) & 1}]

if {$mm2s_halted} {
    puts "  MM2S: HALTED (not running)"
} elseif {$mm2s_idle} {
    puts "  MM2S: IDLE (completed)"
} else {
    puts "  MM2S: RUNNING (transfer in progress — STUCK?)"
}

if {$s2mm_halted} {
    puts "  S2MM: HALTED (not running)"
} elseif {$s2mm_idle} {
    puts "  S2MM: IDLE (completed)"
} else {
    puts "  S2MM: RUNNING (transfer in progress — STUCK?)"
}

puts "\n============================================"
disconnect
