# build_eth.tcl -- Build P_18 Ethernet app (main + eth_server + dpu_exec + mem_pool)

set xsa_path [lindex $argv 0]
set ws_dir   [lindex $argv 1]
set sw_dir   [lindex $argv 2]

setws $ws_dir

# Platform: necesita LWIP librería. El BSP se configura con -os standalone
# pero hay que añadir lwip220 library en post-processing (o usar template
# lwIP TCP Server). Aqui usamos Empty C y añadimos a lwip lib via settings.
if {[catch {platform create -name dpu_eth_platform -hw $xsa_path \
             -proc ps7_cortexa9_0 -os standalone} err]} {
    puts "platform create: $err (continuing)"
}

# Enable lwip library in BSP
if {[catch {bsp setlib -name lwip220} err]} {
    puts "bsp setlib lwip220: $err (may already be set)"
}
# Configurar lwIP para throughput alto (valores probados en P_400)
foreach {k v} {
    api_mode       RAW_API
    tcp_wnd        16384
    mem_size       131072
    memp_n_pbuf    128
    pbuf_pool_size 128
} {
    if {[catch {bsp config $k $v} err]} { puts "bsp config $k: $err" }
}

platform generate

set APP_NAME "dpu_eth_app"
if {[catch {app create -name $APP_NAME -platform dpu_eth_platform \
             -domain {standalone_domain} -template {Empty Application(C)}} err]} {
    puts "app create: $err"
}

set app_src [file join $ws_dir $APP_NAME src]
file mkdir $app_src

foreach f [glob -nocomplain -directory $sw_dir *.c *.h] {
    file copy -force $f $app_src
    puts "copied [file tail $f]"
}

if {[catch {app build $APP_NAME} err]} {
    puts "BUILD FAILED: $err"
    exit 1
}
puts "BUILD OK: $APP_NAME"
