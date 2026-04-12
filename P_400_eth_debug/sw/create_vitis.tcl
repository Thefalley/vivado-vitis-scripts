# create_vitis.tcl - P_400 Ethernet Debug
# Creates Vitis workspace with lwIP bare-metal app from our sources
#
# Run on server:
#   cd C:/Users/jce03/Desktop/claude/vivado-server/P_400_eth_debug
#   E:/vivado-instalado/2025.2.1/Vitis/bin/xsct.bat sw/create_vitis.tcl

set script_dir [file dirname [file normalize [info script]]]
set base_dir   [file dirname $script_dir]
set ws_dir     $base_dir/vitis_ws

file delete -force $ws_dir
setws $ws_dir

# ---- Platform from XSA ----
platform create -name p400_plat \
    -hw $base_dir/system.xsa \
    -proc ps7_cortexa9_0 -os standalone

# ---- Add & configure lwIP ----
bsp setlib -name lwip220

bsp config api_mode          RAW_API
bsp config lwip_dhcp         false
bsp config lwip_udp          true
bsp config lwip_tcp          true
bsp config mem_size           262144
bsp config memp_n_pbuf        1024
bsp config n_rx_descriptors   64
bsp config n_tx_descriptors   32
bsp config pbuf_pool_size     2048
bsp config phy_link_speed     CONFIG_LINKSPEED_AUTODETECT

platform generate

# ---- Application ----
app create -name p400_eth \
    -platform p400_plat \
    -proc ps7_cortexa9_0 \
    -template "Empty Application(C)" \
    -lang c

# Copy our source files
set app_src $ws_dir/p400_eth/src
file copy -force $base_dir/sw/main.c          $app_src/main.c
file copy -force $base_dir/sw/platform_eth.c  $app_src/platform_eth.c
file copy -force $base_dir/sw/platform_eth.h  $app_src/platform_eth.h

# Build
app build -name p400_eth

puts "============================================"
puts "  Build complete!"
puts "  ELF: $ws_dir/p400_eth/Debug/p400_eth.elf"
puts "============================================"
