#!/usr/bin/env bash
# run_sim.sh -- batch xsim run for partial_tile_bug_tb
set -u
cd "$(dirname "$0")"

VIVBIN="/c/AMDDesignTools/2025.2/Vivado/bin"
SRC="../src"

rm -rf xsim.dir work trace.csv sim.log xelab.log xvhdl.log xsim.jou xvhdl.pb xelab.pb 2>/dev/null

echo "=== xvhdl : compile RTL ===" | tee sim.log
"$VIVBIN/xvhdl.bat" -2008 \
    "$SRC/mac_unit.vhd" \
    "$SRC/mac_array.vhd" \
    "$SRC/mul_s32x32_pipe.vhd" \
    "$SRC/requantize.vhd" \
    "$SRC/conv_engine_v3.vhd" \
    partial_tile_bug_tb.vhd 2>&1 | tee -a sim.log

echo "=== xelab ===" | tee -a sim.log
# -debug typical is required so hierarchical (external) signal refs resolve.
"$VIVBIN/xelab.bat" -debug typical -L work partial_tile_bug_tb -s part_bug_sim 2>&1 | tee -a sim.log

echo "=== xsim : batch run ===" | tee -a sim.log
"$VIVBIN/xsim.bat" part_bug_sim -runall 2>&1 | tee -a sim.log

echo "=== done ===" | tee -a sim.log
ls -la trace.csv sim.log 2>&1 | tee -a sim.log
