#!/usr/bin/env bash
# run_critical_B.sh -- batch xsim for critical_B_tb (max tiling).
set -u
cd "$(dirname "$0")"

VIVBIN="/c/AMDDesignTools/2025.2/Vivado/bin"
SRC="../src"

rm -rf xsim.dir/critical_B xelab.log xvhdl.log xsim.jou xvhdl.pb xelab.pb \
       trace_B.csv sim_B.log 2>/dev/null

LOG=sim_B.log
echo "=== xvhdl : compile RTL + tb ===" | tee $LOG
"$VIVBIN/xvhdl.bat" -2008 \
    "$SRC/mac_unit.vhd" \
    "$SRC/mac_array.vhd" \
    "$SRC/mul_s32x32_pipe.vhd" \
    "$SRC/requantize.vhd" \
    "$SRC/conv_engine_v3.vhd" \
    critical_B_tb.vhd 2>&1 | tee -a $LOG

echo "=== xelab ===" | tee -a $LOG
"$VIVBIN/xelab.bat" -debug typical -L work critical_B_tb -s critical_B_sim 2>&1 | tee -a $LOG

echo "=== xsim : batch run ===" | tee -a $LOG
"$VIVBIN/xsim.bat" critical_B_sim -runall 2>&1 | tee -a $LOG

echo "=== done ===" | tee -a $LOG
ls -la trace_B.csv $LOG 2>&1 | tee -a $LOG
