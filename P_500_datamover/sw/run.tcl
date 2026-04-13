# ==============================================================
# run.tcl - Programa bitstream + FSBL + ejecuta ELF en ZedBoard
# Uso: xsct run.tcl <bitstream.bit> <elf_file> <fsbl.elf>
#
# Flujo:
#   1. Cerrar Tera Term
#   2. Ejecutar este script (programa + carga app)
#   3. Abrir Tera Term en COM5 115200
#   4. La app se queda ejecutando, la salida se ve en Tera Term
# ==============================================================

set bit_file  [lindex $argv 0]
set elf_file  [lindex $argv 1]
set fsbl_file [lindex $argv 2]

# Connect
puts ""
puts ">>> CIERRA Tera Term antes de continuar <<<"
puts ""
puts "Conectando a ZedBoard ..."
connect
after 2000
targets

# Program FPGA
puts "\nProgramando bitstream ..."
targets -set -nocase -filter {name =~ "*7z*" || name =~ "*PL*" || name =~ "*xc7z*"}
fpga $bit_file
after 1000

# Select ARM core
targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}

# FSBL: initialize DDR, clocks, MIO
puts "Cargando FSBL (inicializando DDR) ..."
rst -processor
dow $fsbl_file
con
after 5000
stop

# Load app but DON'T run yet
puts "Cargando app: [file tail $elf_file]"
rst -processor
dow $elf_file

puts ""
puts "========================================="
puts "  TODO CARGADO OK"
puts "========================================="
puts "  1. Abre Tera Term -> COM5 -> 115200"
puts "  2. La app arrancara en 15 segundos..."
puts "========================================="

# Give user time to open Tera Term
after 15000

# NOW run the app
con
after 10000

puts ""
puts "  App ejecutada. Revisa Tera Term."
puts "========================================="
