# ==============================================================
# create_vitis.tcl - Crea workspace Vitis desde XSA
# Uso: xsct create_vitis.tcl <xsa_path> <workspace_dir> <app_src>
#
# Crea:
#   1. Platform desde XSA (standalone, ps7_cortexa9_0)
#   2. App bare-metal con el codigo C
# ==============================================================

set xsa_path   [lindex $argv 0]
set ws_dir     [lindex $argv 1]
set app_src    [lindex $argv 2]

# Clean workspace
if {[file exists $ws_dir]} {
    file delete -force $ws_dir
}

# Set workspace
setws $ws_dir

# Create platform from XSA
puts "Creando platform desde $xsa_path ..."
platform create -name "zynq_dma_platform" \
    -hw $xsa_path \
    -os standalone \
    -proc ps7_cortexa9_0

platform generate

# Create application
puts "Creando app dma_test ..."
app create -name "dma_test" \
    -platform "zynq_dma_platform" \
    -domain "standalone_domain" \
    -template "Empty Application(C)"

# Copy source file into app
set app_src_dir [file join $ws_dir dma_test src]
file copy -force $app_src $app_src_dir

# Build
puts "Compilando ..."
app build -name "dma_test"

puts ""
puts "========================================="
puts "  Vitis workspace creado en: $ws_dir"
puts "  App: dma_test"
puts "  ELF: $ws_dir/dma_test/Debug/dma_test.elf"
puts "========================================="
