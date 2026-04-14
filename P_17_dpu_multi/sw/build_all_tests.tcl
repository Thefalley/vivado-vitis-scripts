# build_all_tests.tcl -- Vitis XSCT script to build all layer tests for P_16
#
# Args:
#   xsa_path  - path to conv_dm.xsa
#   ws_dir    - workspace directory (will be wiped)
#   tests_dir - directory containing layer_NNN_test.c files
#
# Builds: conv_dm_platform + one app per .c file in tests_dir.

set xsa_path  [lindex $argv 0]
set ws_dir    [lindex $argv 1]
set tests_dir [lindex $argv 2]

puts "xsa_path  = $xsa_path"
puts "ws_dir    = $ws_dir"
puts "tests_dir = $tests_dir"

setws $ws_dir
puts "workspace set"

# Platform (single shared platform for all apps)
if {[catch {platform create -name conv_dm_platform -hw $xsa_path \
             -proc ps7_cortexa9_0 -os standalone} err]} {
    puts "platform create: $err (may already exist; continuing)"
} else {
    puts "platform created"
}

platform generate
puts "platform generated"

# List all test .c files (layer_NNN_test.c pattern)
set test_files [glob -nocomplain -directory $tests_dir "layer_*_test.c"]
set test_files [lsort $test_files]

puts ""
puts "Found [llength $test_files] test files:"
foreach tf $test_files {
    puts "  - [file tail $tf]"
}
puts ""

foreach src_file $test_files {
    set src_name  [file tail $src_file]
    set app_name  [file rootname $src_name]

    puts "=============================================="
    puts "Building $app_name from $src_name"
    puts "=============================================="

    # Create app (skip if exists, which happens when re-running)
    if {[catch {app create -name $app_name -platform conv_dm_platform \
                 -domain {standalone_domain} -template {Empty Application(C)}} err]} {
        puts "app create: $err (may already exist; continuing)"
    }

    # Copy source
    set app_dir [file join $ws_dir $app_name src]
    file mkdir $app_dir
    file copy -force $src_file $app_dir
    puts "src copied to $app_dir"

    # Build
    if {[catch {app build $app_name} err]} {
        puts "BUILD FAILED for $app_name: $err"
    } else {
        puts "BUILD OK: $app_name"
    }
    puts ""
}

puts "ALL DONE"
