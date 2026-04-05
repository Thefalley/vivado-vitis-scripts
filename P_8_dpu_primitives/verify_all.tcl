# verify_all.tcl — Sintetiza e implementa cada modulo DPU individualmente
# Uso: vivado -mode batch -source P_8_dpu_primitives/verify_all.tcl

set src_dir "C:/project/vivado/P_8_dpu_primitives/src"
set out_dir "C:/project/vivado/P_8_dpu_primitives/results"
set part "xc7z020clg484-1"
set clk_period 10.0

file mkdir $out_dir

# Modulos a verificar (en orden de dependencias)
set modules {
    mul_s32x32_pipe
    mul_s9xu30_pipe
    mac_unit
    mac_array
    requantize
    leaky_relu
    elem_add
    maxpool_unit
}

# Leer todos los fuentes una vez
set src_files [glob $src_dir/*.vhd]

set fp_summary [open "$out_dir/summary.txt" w]
puts $fp_summary "DPU Primitives — Verificacion individual @ ${clk_period}ns (100 MHz)"
puts $fp_summary "FPGA: $part (Zynq-7020 / ZedBoard)"
puts $fp_summary ""
puts $fp_summary [format "%-20s | %4s | %5s | %5s | %8s | %4s | %9s" \
    "Modulo" "DSP" "LUT" "FF" "WNS(ns)" "Met" "Fmax(MHz)"]
puts $fp_summary "---------------------+------+-------+-------+----------+------+-----------"

foreach top $modules {
    puts "\n================================================================"
    puts "  Verificando: $top"
    puts "================================================================"

    # Reset design
    if {[catch {close_design} msg]} {}
    if {[catch {close_project} msg]} {}

    # Leer fuentes
    foreach f $src_files {
        read_vhdl $f
    }

    # Sintetizar
    if {[catch {
        synth_design -top $top -part $part
    } msg]} {
        puts "ERROR synth $top: $msg"
        puts $fp_summary [format "%-20s | ERROR: %s" $top $msg]
        continue
    }

    # Clock constraint
    if {[catch {create_clock -period $clk_period -name clk [get_ports clk]}]} {
        # Algunos modulos pueden no tener puerto clk directo
        puts "WARN: no clk port for $top, skipping timing"
    }

    # Implementar
    if {[catch {
        opt_design
        place_design
        route_design
    } msg]} {
        puts "ERROR impl $top: $msg"
        puts $fp_summary [format "%-20s | ERROR impl: %s" $top $msg]
        continue
    }

    # Reports
    report_timing_summary -file "$out_dir/${top}_timing.rpt"
    report_utilization -file "$out_dir/${top}_util.rpt"

    # Extraer WNS
    set wns 0
    catch {
        set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
    }

    # Extraer recursos del report
    set util_text [read [open "$out_dir/${top}_util.rpt" r]]

    set dsp 0
    set lut 0
    set ff 0
    regexp {\| DSPs\s+\|\s+(\d+)} $util_text -> dsp
    regexp {\| Slice LUTs\s+\|\s+(\d+)} $util_text -> lut
    regexp {\| Slice Registers\s+\|\s+(\d+)} $util_text -> ff

    set met "OK"
    if {$wns < 0} { set met "FAIL" }
    set fmax [expr {1000.0 / ($clk_period - $wns)}]

    puts "  -> WNS=${wns}ns  DSP=$dsp  LUT=$lut  FF=$ff  \[$met\]"

    # Escribir resultado
    set fp_result [open "$out_dir/${top}_result.txt" w]
    puts $fp_result "RESULT|$top|$wns|$dsp|$lut|$ff"
    close $fp_result

    puts $fp_summary [format "%-20s | %4s | %5s | %5s | %+8.3f | %4s | %9.1f" \
        $top $dsp $lut $ff $wns $met $fmax]
}

puts $fp_summary "---------------------+------+-------+-------+----------+------+-----------"
close $fp_summary

puts "\n================================================================"
puts "  DONE — Resultados en $out_dir/summary.txt"
puts "================================================================"
