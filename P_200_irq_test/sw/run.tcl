# ==============================================================
# run.tcl - P_200: Programa + ejecuta + verifica por JTAG
# ==============================================================

set bit_file  [lindex $argv 0]
set elf_file  [lindex $argv 1]
set fsbl_file [lindex $argv 2]
set ps7_init_file "remote_output/ps7_init.tcl"
set irq_base 0x40000000

proc find_target {pattern} {
    foreach t [targets -target-properties] {
        if {[string match -nocase $pattern [dict get $t name]]} {
            return [dict get $t target_id]
        }
    }
    return -1
}

puts "\n========================================="
puts "  P_200 IRQ Test - ZedBoard JTAG"
puts "=========================================\n"

# --- Connect ---
puts "\[1\] Conectando ..."
connect
after 3000

set arm_id [find_target "*Cortex*#0"]
if {$arm_id == -1} { set arm_id [find_target "*A9*#0"] }
if {$arm_id == -1} {
    puts "  ARM no visible, rst -srst ..."
    targets 1
    catch {rst -srst}
    after 5000
    set arm_id [find_target "*Cortex*#0"]
    if {$arm_id == -1} { set arm_id [find_target "*A9*#0"] }
}
if {$arm_id == -1} { puts "FATAL: no ARM"; disconnect; exit 1 }
puts "  ARM: target $arm_id"

# --- ps7_init ---
puts "\[2\] ps7_init ..."
targets $arm_id
catch {rst -processor}
after 1000
catch {stop}
after 500
source $ps7_init_file
ps7_init
after 1000
puts "  Clocks + DDR OK"

# --- FPGA ---
puts "\[3\] Programando bitstream ..."
set fpga_id [find_target "*xc7z*"]
targets $fpga_id
fpga $bit_file
after 2000
puts "  Bitstream cargado"

# --- ps7_post_config ---
puts "\[4\] ps7_post_config ..."
targets $arm_id
catch {stop}
after 500
ps7_post_config
after 1000
puts "  PS-PL habilitado"

# --- Run app ---
puts "\[5\] Cargando irq_test ..."
rst -processor
dow $elf_file
puts "  Ejecutando ..."
con

# Wait for DDR marker
puts "  Esperando (max 20s) ..."
set done 0
for {set attempt 0} {$attempt < 40} {incr attempt} {
    after 500
    catch {
        stop
        set marker [lindex [mrd -force -value 0x00100000 1] 0]
        if {$marker == 0xDEADBEEF} {
            set done 1
        } else {
            con
        }
    }
    if {$done} break
}
if {!$done} {
    catch {stop}
    puts "  WARN: Timeout - checking state..."
    # Check where the PC is
    catch {
        set pc_val [rrd pc]
        puts "  PC = $pc_val"
    }
    catch {
        set marker [lindex [mrd -force -value 0x00100000 1] 0]
        puts "  DDR marker = [format 0x%08X $marker]"
    }
}

# ==============================================================
# VERIFICACION - usar -force para acceder PL
# ==============================================================
puts "\n========================================="
puts "  VERIFICACION POR JTAG"
puts "========================================="

catch {
    set ctrl      [lindex [mrd -force -value [expr {$irq_base + 0x00}] 1] 0]
    set threshold [lindex [mrd -force -value [expr {$irq_base + 0x04}] 1] 0]
    set condition [lindex [mrd -force -value [expr {$irq_base + 0x08}] 1] 0]
    set status_r  [lindex [mrd -force -value [expr {$irq_base + 0x0C}] 1] 0]
    set count     [lindex [mrd -force -value [expr {$irq_base + 0x10}] 1] 0]
    set irq_count [lindex [mrd -force -value [expr {$irq_base + 0x14}] 1] 0]
    set ddr_mark  [lindex [mrd -force -value 0x00100000 1] 0]

    puts ""
    puts "  CTRL       = [format 0x%08X $ctrl]"
    puts "  THRESHOLD  = $threshold"
    puts "  CONDITION  = $condition"
    puts "  STATUS     = [format 0x%08X $status_r]"
    puts "  COUNT      = $count"
    puts "  IRQ_COUNT  = $irq_count"
    puts "  DDR marker = [format 0x%08X $ddr_mark]"

    puts "\n========================================="
    set errors 0

    if {$ddr_mark == 0xDEADBEEF} {
        puts "  App completada:       OK"
    } else {
        puts "  App completada:       FAIL"
        incr errors
    }

    if {$irq_count >= 2} {
        puts "  IRQ_COUNT >= 2:       OK ($irq_count interrupciones)"
    } elseif {$irq_count == 1} {
        puts "  IRQ_COUNT = 1:        FAIL"
        incr errors
    } else {
        puts "  IRQ_COUNT = 0:        FAIL"
        incr errors
    }

    if {$status_r == 0} {
        puts "  STATUS = IDLE:        OK"
    } else {
        puts "  STATUS = [format 0x%X $status_r]:  INFO"
    }

    puts "========================================="
    if {$errors == 0 && $irq_count >= 2} {
        puts "  RESULTADO: PASS"
        puts "  Interrupciones PL->PS VERIFICADAS!"
    } else {
        puts "  RESULTADO: FAIL ($errors errores)"
    }
    puts "========================================="
} err

if {$err ne ""} { puts "\n  Error: $err" }

puts ""
disconnect
