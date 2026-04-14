#!/bin/bash
# run_layer.sh <layer_number>
# Build and run a single layer test on ZedBoard
# Returns 0 on PASS, 1 on FAIL/ERROR, 2 on DAP/board error

LAYER=$1
LAYER_PAD=$(printf "%03d" $LAYER)
PROJ="C:/project/vivado/P_13_conv_test"
BIT="$PROJ/build/zynq_conv.runs/impl_1/zynq_conv_bd_wrapper.bit"
ELF="$PROJ/vitis_ws/conv_test/Debug/conv_test.elf"
FSBL="$PROJ/vitis_ws/zynq_conv_platform/zynq_fsbl/fsbl.elf"
XSCT="C:/AMDDesignTools/2025.2/Vitis/bin/xsct.bat"

# 1. Copy layer source
cp "$PROJ/sw/layer_tests/layer_${LAYER_PAD}_test.c" "$PROJ/vitis_ws/conv_test/src/conv_test.c"
if [ $? -ne 0 ]; then
    echo "Layer $LAYER_PAD: COPY_FAIL"
    exit 1
fi

# 2. Build via XSCT (has ARM toolchain in its env)
cat > /tmp/build_conv.tcl << 'EOFTCL'
setws C:/project/vivado/P_13_conv_test/vitis_ws
app build -name conv_test
EOFTCL
"$XSCT" /tmp/build_conv.tcl > /tmp/xsct_build_${LAYER_PAD}.log 2>&1
BUILD_RC=$?
if [ $BUILD_RC -ne 0 ]; then
    echo "Layer $LAYER_PAD: BUILD_FAIL"
    cat /tmp/xsct_build_${LAYER_PAD}.log | tail -5
    exit 1
fi

# Verify ELF was updated
if [ ! -f "$ELF" ]; then
    echo "Layer $LAYER_PAD: ELF_MISSING"
    exit 1
fi

# 3. Kill stale processes and run on board
powershell -Command "Get-Process java,hw_server,xsct -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
sleep 5

RESULT=$("$XSCT" "$PROJ/sw/run_idx.tcl" "$BIT" "$ELF" "$FSBL" 2>&1)

# Check for DAP/connection errors
if echo "$RESULT" | grep -qiE "DAP|AHB AP transaction|connection|Cannot connect"; then
    echo "Layer $LAYER_PAD: DAP_ERROR"
    echo "$RESULT" | tail -5
    exit 2
fi

# Extract result
TOTAL=$(echo "$RESULT" | grep "Total:" | sed 's/.*Total: //' | sed 's/ .*//')
ERRORS=$(echo "$RESULT" | grep "Errors:" | sed 's/.*Errors: //' | sed 's/ .*//')

if echo "$RESULT" | grep -q "ALL PASSED"; then
    echo "Layer $LAYER_PAD: PASS ${TOTAL}/${TOTAL}"
    exit 0
elif [ -n "$ERRORS" ]; then
    echo "Layer $LAYER_PAD: FAIL (Errors=${ERRORS}/${TOTAL})"
    exit 1
else
    echo "Layer $LAYER_PAD: UNKNOWN_RESULT"
    echo "$RESULT" | tail -10
    exit 1
fi
