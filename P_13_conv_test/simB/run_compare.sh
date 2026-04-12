#!/bin/bash
# Run both RTL and post-synth sims with same TB, compare outputs
VIVADO="C:/AMDDesignTools/2025.2/Vivado/bin"
SRC="../src"
cd "$(dirname "$0")"

echo "=== RTL SIM ==="
rm -rf xsim.dir work 2>/dev/null
$VIVADO/xvhdl.bat $SRC/mac_unit.vhd $SRC/mac_array.vhd $SRC/mul_s32x32_pipe.vhd $SRC/requantize.vhd $SRC/conv_engine.vhd $SRC/conv_test_wrapper.vhd post_synth_tb.vhd 2>&1 | grep ERROR
# Fix entity name for RTL
sed -i 's/zynq_conv_bd_conv_test_wrapper_0_0/conv_test_wrapper/g' post_synth_tb.vhd
$VIVADO/xvhdl.bat post_synth_tb.vhd 2>&1 | grep ERROR
$VIVADO/xelab.bat post_synth_tb -debug off 2>&1 | grep ERROR
$VIVADO/xsim.bat post_synth_tb -runall 2>&1 | grep "out\[" | tee rtl_output.txt

echo ""
echo "=== POST-SYNTH SIM ==="
rm -rf xsim.dir work 2>/dev/null
# Restore entity name for post-synth
sed -i 's/conv_test_wrapper/zynq_conv_bd_conv_test_wrapper_0_0/g' post_synth_tb.vhd
$VIVADO/xvhdl.bat post_synth/conv_test_wrapper_funcsim.vhd post_synth_tb.vhd 2>&1 | grep ERROR
$VIVADO/xelab.bat post_synth_tb -debug off 2>&1 | grep ERROR
$VIVADO/xsim.bat post_synth_tb -runall 2>&1 | grep "out\[" | tee postsynth_output.txt

echo ""
echo "=== DIFF ==="
diff rtl_output.txt postsynth_output.txt || echo "DIFFERENCES FOUND"
