# run_all_layers.tcl -- Run each ELF sequentially with full PS+PL reset between.
#
# Args:
#   bit_file   - path to .bit
#   fsbl_file  - path to fsbl.elf
#   ws_dir     - vitis workspace root (expects $ws_dir/<app>/Debug/<app>.elf)
#   app_list   - space-separated app names
#
# Clean-recovery loop (avoids JTAG/DAP degradation observed after 20-25 iterations):
#   per app:
#     1. `rst -system`         -- full PS+PL soft reset via SLCR PSS_RST_CTRL.
#                                 Wipes DMAs, DataMover, GIC, caches, debug state.
#                                 Leaves JTAG/DAP alive (unlike physical button).
#     2. Re-program bitstream (PL was wiped by rst -system)
#     3. Load FSBL, run to init DDR+MMU, stop
#     4. Clear result mailbox
#     5. rst -processor, load ELF, run, poll, capture

set bit_file  [lindex $argv 0]
set fsbl_file [lindex $argv 1]
set ws_dir    [lindex $argv 2]
set app_list  [lrange $argv 3 end]

set RESULT_ADDR 0x10200000
set MAGIC_DONE  0xDEAD1234
set TIMEOUT_SEC 180

puts ""
puts "==========================================="
puts "  P_16 Multi-Layer Test Runner (rst -system)"
puts "==========================================="
puts "  bit_file  = $bit_file"
puts "  fsbl_file = $fsbl_file"
puts "  ws_dir    = $ws_dir"
puts "  apps      = [llength $app_list]"
puts "==========================================="
puts ""

connect
after 2000

set fpga_id ""
foreach t [targets -filter {name =~ "xc7z020*"}] {
    regexp {^\s*\*?\s*(\d+)} $t -> fpga_id
    break
}
if {$fpga_id eq ""} {
    puts "ERROR: No FPGA target"
    exit 1
}

set arm_id ""
foreach t [targets -filter {name =~ "*Cortex-A9*#0" || name =~ "*ARM*#0"}] {
    regexp {^\s*\*?\s*(\d+)} $t -> arm_id
    break
}
if {$arm_id eq ""} {
    puts "ERROR: No ARM target"
    exit 1
}

puts "FPGA target id: $fpga_id"
puts "ARM  target id: $arm_id"

set results [list]
set idx 0
set total_apps [llength $app_list]

foreach app $app_list {
    incr idx
    set elf_file [file join $ws_dir $app "Debug" "${app}.elf"]
    if {![file exists $elf_file]} {
        puts "ERROR: ELF not found for $app: $elf_file"
        lappend results [list $app "N/A" "N/A" "NO_ELF"]
        continue
    }

    puts ""
    puts "-------------------------------------------"
    puts "\[$idx / $total_apps\] RUN: $app"
    puts "-------------------------------------------"

    # 1) FULL SYSTEM SOFT RESET (clears PL DMAs, DataMover, GIC, caches, debug)
    # Catch errors because first iteration has nothing to reset to ARM-side,
    # but the bit has been freshly programmed by the outer loop only on iter #1.
    if {$idx > 1} {
        targets $arm_id
        if {[catch {stop} err]} { puts "WARN: stop before rst: $err" }
        if {[catch {rst -system} err]} { puts "WARN: rst -system: $err" }
        after 2000
    }

    # 2) Re-program bitstream (PL wiped by rst -system; first iter also needs it)
    targets $fpga_id
    if {[catch {fpga $bit_file} err]} {
        puts "ERROR: fpga program: $err"
        lappend results [list $app "N/A" "N/A" "PROG_FAIL"]
        continue
    }
    after 1000

    # 3) Load FSBL: initializes DDR controller + MMU + clocks
    targets $arm_id
    if {[catch {rst -processor} err]} { puts "WARN: rst -processor: $err" }
    after 500
    dow $fsbl_file
    con
    after 3000
    stop

    # 4) DDR alive: clear mailbox
    mwr $RESULT_ADDR 0
    mwr [expr {$RESULT_ADDR + 4}] 0
    mwr [expr {$RESULT_ADDR + 8}] 0

    # 5) Reset core, load ELF, run
    rst -processor
    after 500
    dow $elf_file
    con

    # 6) Poll for completion
    set elapsed 0
    set magic 0
    while {$elapsed < $TIMEOUT_SEC} {
        after 2000
        incr elapsed 2
        stop
        if {[catch {set magic [lindex [mrd -value $RESULT_ADDR 1] 0]} err]} {
            puts "WARN: mrd failed (elapsed=$elapsed): $err"
            set magic 0
        }
        con
        if {$magic == $MAGIC_DONE} { break }
    }

    after 500
    stop
    if {[catch {set res [mrd -value $RESULT_ADDR 3]} err]} {
        set res [list 0 0 0]
    }
    set got_magic [lindex $res 0]
    set total     [lindex $res 1]
    set errors    [lindex $res 2]

    if {$got_magic == $MAGIC_DONE} {
        if {$errors == 0} {
            set status "PASS"
        } else {
            set status "FAIL"
        }
    } else {
        set status "TIMEOUT"
    }
    puts ">>> \[$idx/$total_apps\] $app: magic=0x[format %08x $got_magic] total=$total errors=$errors status=$status"
    lappend results [list $app $total $errors $status]
}

puts ""
puts "==========================================="
puts "  P_16 MULTI-LAYER RESULTS ($total_apps apps)"
puts "==========================================="
puts [format "  %-24s %8s %8s %10s" "APP" "TOTAL" "ERRORS" "STATUS"]
puts "  ----------------------------------------------------"
set total_pass 0
set total_fail 0
set total_timeout 0
foreach r $results {
    lassign $r app total errors status
    puts [format "  %-24s %8s %8s %10s" $app $total $errors $status]
    if {$status == "PASS"}    { incr total_pass }
    if {$status == "FAIL"}    { incr total_fail }
    if {$status == "TIMEOUT"} { incr total_timeout }
}
puts "  ----------------------------------------------------"
puts [format "  %-24s pass=%d  fail=%d  timeout=%d" "SUMMARY" $total_pass $total_fail $total_timeout]
puts "==========================================="
