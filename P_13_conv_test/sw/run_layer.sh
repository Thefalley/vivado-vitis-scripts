#!/bin/bash
# run_layer.sh <layer_number>
# Build and run a single layer test on ZedBoard
# Returns 0 on PASS, 1 on FAIL/ERROR

LAYER=$1
LAYER_PAD=$(printf "%03d" $LAYER)
PROJ="C:/project/vivado/P_13_conv_test"
VITIS_GCC="C:/AMDDesignTools/2025.2/Vitis/gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe"
BSP_INC="$PROJ/vitis_ws/zynq_conv_platform/export/zynq_conv_platform/sw/zynq_conv_platform/standalone_domain/bspinclude/include"
BSP_LIB="$PROJ/vitis_ws/zynq_conv_platform/export/zynq_conv_platform/sw/zynq_conv_platform/standalone_domain/bsplib/lib"
LDSCRIPT="$PROJ/vitis_ws/conv_test/src/lscript.ld"
SPEC="$PROJ/vitis_ws/conv_test/Debug/Xilinx.spec"
SRC="$PROJ/vitis_ws/conv_test/src/conv_test.c"
OBJ="$PROJ/vitis_ws/conv_test/Debug/src/conv_test.o"
ELF="$PROJ/vitis_ws/conv_test/Debug/conv_test.elf"
BIT="$PROJ/build/zynq_conv.runs/impl_1/zynq_conv_bd_wrapper.bit"
FSBL="$PROJ/vitis_ws/zynq_conv_platform/zynq_fsbl/fsbl.elf"
XSCT="C:/AMDDesignTools/2025.2/Vitis/bin/xsct.bat"

# 1. Copy layer source
cp "$PROJ/sw/layer_tests/layer_${LAYER_PAD}_test.c" "$SRC"
if [ $? -ne 0 ]; then
    echo "Layer $LAYER_PAD: COPY_FAIL"
    exit 1
fi

# 2. Compile
"$VITIS_GCC" -Wall -O0 -g3 -c -fmessage-length=0 \
    -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
    -I"$BSP_INC" -o "$OBJ" "$SRC" 2>&1
if [ $? -ne 0 ]; then
    echo "Layer $LAYER_PAD: BUILD_FAIL"
    exit 1
fi

# 3. Link
"$VITIS_GCC" -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
    -Wl,-build-id=none -specs="$SPEC" \
    -Wl,-T -Wl,"$LDSCRIPT" -L"$BSP_LIB" \
    -o "$ELF" "$OBJ" \
    -Wl,--whole-archive -lxil -Wl,--no-whole-archive -lgcc -lc 2>&1
if [ $? -ne 0 ]; then
    echo "Layer $LAYER_PAD: LINK_FAIL"
    exit 1
fi

# 4. Run on board
RESULT=$("$XSCT" "$PROJ/sw/run_idx.tcl" "$BIT" "$ELF" "$FSBL" 2>&1)
echo "$RESULT" | grep -qE "DAP|connection|failed|timeout"
if [ $? -eq 0 ]; then
    echo "Layer $LAYER_PAD: DAP_ERROR"
    exit 2
fi

# Extract result
TOTAL=$(echo "$RESULT" | grep "Total:" | sed 's/.*Total: //' | sed 's/ .*//')
ERRORS=$(echo "$RESULT" | grep "Errors:" | sed 's/.*Errors: //' | sed 's/ .*//')
PASS_LINE=$(echo "$RESULT" | grep -E "PASSED|FAILED")

if echo "$RESULT" | grep -q "ALL PASSED"; then
    echo "Layer $LAYER_PAD: PASS ${TOTAL}/${TOTAL}"
    exit 0
elif [ -n "$ERRORS" ]; then
    echo "Layer $LAYER_PAD: FAIL (${ERRORS} errors out of ${TOTAL})"
    exit 1
else
    echo "Layer $LAYER_PAD: UNKNOWN_RESULT"
    echo "$RESULT" | tail -10
    exit 1
fi
