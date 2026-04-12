# probe.tcl — Diagnose whether the board is alive and the app executes
#
# Steps:
#   1. Connect via JTAG, list targets
#   2. Program bitstream
#   3. Load FSBL, run briefly, stop
#   4. Load app ELF, run for 15s, stop
#   5. Read src[0..3] at 0x01000000 — if src[0]=0xCAFE0000, app started
#   6. Read dst[0..3] at 0x01100000 — check if data came back
#   7. Read result marker at 0x01200000
#   8. Report diagnosis

set bit_file  "build/bit/bram_ctrl_bd_wrapper.bit"
set elf_file  "build/elf/bram_ctrl_test.elf"
set fsbl_file "build/elf/fsbl.elf"

puts "============================================"
puts "  PROBE: Board & App Diagnostic"
puts "============================================"

# --- 1. Connect ---
puts "\n\[1\] Connecting to JTAG..."
connect
after 2000

puts "\nTargets:"
targets

# --- 2. System reset via DAP (clear stale state) ---
puts "\n\[2\] System reset via DAP..."
catch {
    targets -set -nocase -filter {name =~ "*DAP*"}
    rst -system
} err
if {$err ne ""} {
    puts "  DAP reset result: $err"
}
after 3000

puts "\nTargets after reset:"
targets

# --- 3. Program FPGA ---
puts "\n\[3\] Programming bitstream: $bit_file"
targets -set -nocase -filter {name =~ "*7z*" || name =~ "*xc7z*"}
fpga $bit_file
after 3000

puts "\nTargets after FPGA programming:"
targets

# --- 4. Select ARM, load FSBL ---
puts "\n\[4\] Loading FSBL..."
targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}
rst -processor
dow $fsbl_file
con
after 5000
stop
puts "  FSBL loaded and ran for 5s."

# --- 5. Load app ELF ---
puts "\n\[5\] Loading app ELF: $elf_file"
rst -processor
dow $elf_file
con
after 15000
stop
puts "  App loaded and ran for 15s."

# --- 6. Read memory regions ---
puts "\n============================================"
puts "  MEMORY PROBE RESULTS"
puts "============================================"

# Source buffer: 0x01000000
puts "\n  --- Source buffer (0x01000000) ---"
puts "  Expected: src\[0\]=0xCAFE0000 if incremental test"
puts "            src\[0\]=0xBEEF0000 if basic 256-word test"
set src_data [mrd -value 0x01000000 8]
for {set i 0} {$i < 8} {incr i} {
    set v [lindex $src_data $i]
    puts [format "  src\[%d\] = 0x%08X" $i $v]
}

# Destination buffer: 0x01100000
puts "\n  --- Dest buffer (0x01100000) ---"
puts "  Expected: dst\[i\] should match src\[i\]"
set dst_data [mrd -value 0x01100000 8]
for {set i 0} {$i < 8} {incr i} {
    set v [lindex $dst_data $i]
    puts [format "  dst\[%d\] = 0x%08X" $i $v]
}

# Result marker: 0x01200000
puts "\n  --- Result marker (0x01200000) ---"
puts "  Expected: 0xCAFE0000=PASS, 0xDEADxxxx=FAIL"
set result_data [mrd -value 0x01200000 1]
set marker [lindex $result_data 0]
puts [format "  marker = 0x%08X" $marker]

# --- 7. Diagnosis ---
puts "\n============================================"
puts "  DIAGNOSIS"
puts "============================================"

set src0 [lindex $src_data 0]
set dst0 [lindex $dst_data 0]

# Check if app wrote the source pattern
set src_hi [expr {($src0 >> 16) & 0xFFFF}]

if {$src_hi == 0xCAFE} {
    puts "  APP STARTED: src\[0\] has CAFE pattern (incremental test)"
    puts "  -> The C app executed and wrote to DDR."

    if {($marker >> 16) == 0xCAFE} {
        puts "  RESULT: PASS (marker=0xCAFE0000)"
    } elseif {($marker >> 16) == 0xDEAD} {
        set nerr [expr {$marker & 0xFFFF}]
        puts "  RESULT: FAIL ($nerr errors, marker=[format 0x%08X $marker])"
    } else {
        puts "  RESULT: UNKNOWN (marker=[format 0x%08X $marker])"
        puts "  -> App may not have finished in 15s, or crashed."
    }

    # Check dst pattern
    set dst_hi [expr {($dst0 >> 16) & 0xFFFF}]
    if {$dst_hi == 0xCAFE} {
        puts "  DST DATA: Has CAFE pattern — at least some data came back."
    } elseif {$dst0 == 0xAAAAAAAA} {
        puts "  DST DATA: Still 0xAAAAAAAA — NO data came back from DMA."
        puts "  -> DMA S2MM never completed or FIFO never drained."
    } else {
        puts [format "  DST DATA: Unexpected value 0x%08X — garbage." $dst0]
    }
} elseif {$src_hi == 0xBEEF} {
    puts "  APP STARTED: src\[0\] has BEEF pattern (basic 256 test)"
    puts "  -> This is the old basic test, not the incremental one."
} elseif {$src0 == 0x00000000} {
    puts "  APP DID NOT START: src\[0\] is 0x00000000"
    puts "  -> The ELF likely failed to load or FSBL crashed."
    puts "  -> Try power-cycling the board."
} else {
    puts [format "  UNKNOWN STATE: src\[0\] = 0x%08X" $src0]
    puts "  -> Stale DDR data? Power cycle the board and retry."
}

puts "\n============================================"
disconnect
