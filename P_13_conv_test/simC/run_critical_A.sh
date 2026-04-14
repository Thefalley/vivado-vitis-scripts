#!/usr/bin/env bash
# run_critical_A.sh -- batch xsim for critical_A_tb (stride-2 asym pad).
set -u
cd "$(dirname "$0")"

VIVBIN="/c/AMDDesignTools/2025.2/Vivado/bin"
SRC="../src"

rm -rf xsim.dir/critical_A xelab.log xvhdl.log xsim.jou xvhdl.pb xelab.pb \
       trace_A.csv sim_A.log 2>/dev/null

LOG=sim_A.log
echo "=== xvhdl : compile RTL + tb ===" | tee $LOG
"$VIVBIN/xvhdl.bat" -2008 \
    "$SRC/mac_unit.vhd" \
    "$SRC/mac_array.vhd" \
    "$SRC/mul_s32x32_pipe.vhd" \
    "$SRC/requantize.vhd" \
    "$SRC/conv_engine_v3.vhd" \
    critical_A_tb.vhd 2>&1 | tee -a $LOG

echo "=== xelab ===" | tee -a $LOG
"$VIVBIN/xelab.bat" -debug typical -L work critical_A_tb -s critical_A_sim 2>&1 | tee -a $LOG

echo "=== xsim : batch run ===" | tee -a $LOG
"$VIVBIN/xsim.bat" critical_A_sim -runall 2>&1 | tee -a $LOG

echo "=== done ===" | tee -a $LOG
ls -la trace_A.csv $LOG 2>&1 | tee -a $LOG
