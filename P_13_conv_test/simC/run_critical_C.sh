#!/usr/bin/env bash
# run_critical_C.sh -- batch xsim for critical_C_tb (partial tile regression).
set -u
cd "$(dirname "$0")"

VIVBIN="/c/AMDDesignTools/2025.2/Vivado/bin"
SRC="../src"

rm -rf xsim.dir/critical_C xelab.log xvhdl.log xsim.jou xvhdl.pb xelab.pb \
       trace_C.csv sim_C.log 2>/dev/null

LOG=sim_C.log
echo "=== xvhdl : compile RTL + tb ===" | tee $LOG
"$VIVBIN/xvhdl.bat" -2008 \
    "$SRC/mac_unit.vhd" \
    "$SRC/mac_array.vhd" \
    "$SRC/mul_s32x32_pipe.vhd" \
    "$SRC/requantize.vhd" \
    "$SRC/conv_engine_v3.vhd" \
    critical_C_tb.vhd 2>&1 | tee -a $LOG

echo "=== xelab ===" | tee -a $LOG
"$VIVBIN/xelab.bat" -debug typical -L work critical_C_tb -s critical_C_sim 2>&1 | tee -a $LOG

echo "=== xsim : batch run ===" | tee -a $LOG
"$VIVBIN/xsim.bat" critical_C_sim -runall 2>&1 | tee -a $LOG

echo "=== done ===" | tee -a $LOG
ls -la trace_C.csv $LOG 2>&1 | tee -a $LOG
