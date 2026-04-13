#!/bin/bash
# Run remaining 68 layers with DAP-safe delays
# Output: one line per layer to stdout, full log to /tmp/batch_68.log

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
RESULTS="$PROJ/sw/layer_test_results.txt"
LOG="/tmp/batch_68.log"

LAYERS="27 28 29 31 32 33 34 35 36 37 38 39 41 42 43 44 45 46 47 48 49 57 58 59 61 62 63 64 65 66 67 68 69 71 72 73 74 75 76 77 78 79 81 82 83 84 85 86 87 88 89 91 92 93 94 95 96 97 98 99 101 102 103 104 105 106 107 108"

PASS_COUNT=0
FAIL_COUNT=0
HUNG_COUNT=0
TESTED=0

for LAYER in $LAYERS; do
    LPAD=$(printf "%03d" $LAYER)

    # Kill stale processes
    powershell -Command "Get-Process java,hw_server,xsct -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
    sleep 5

    # 1. Copy
    cp "$PROJ/sw/layer_tests/layer_${LPAD}_test.c" "$SRC"
    if [ $? -ne 0 ]; then
        echo "Layer $LPAD: COPY_FAIL"
        echo "  Layer $LPAD: COPY_FAIL" >> "$RESULTS"
        continue
    fi

    # 2. Compile
    "$VITIS_GCC" -Wall -O0 -g3 -c -fmessage-length=0 \
        -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
        -I"$BSP_INC" -o "$OBJ" "$SRC" >> "$LOG" 2>&1
    if [ $? -ne 0 ]; then
        echo "Layer $LPAD: BUILD_FAIL"
        echo "  Layer $LPAD: BUILD_FAIL" >> "$RESULTS"
        continue
    fi

    # 3. Link
    "$VITIS_GCC" -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
        -Wl,-build-id=none -specs="$SPEC" \
        -Wl,-T -Wl,"$LDSCRIPT" -L"$BSP_LIB" \
        -o "$ELF" "$OBJ" \
        -Wl,--whole-archive -lxil -Wl,--no-whole-archive -lgcc -lc >> "$LOG" 2>&1
    if [ $? -ne 0 ]; then
        echo "Layer $LPAD: LINK_FAIL"
        echo "  Layer $LPAD: LINK_FAIL" >> "$RESULTS"
        continue
    fi

    # 4. Run on board
    RESULT=$("$XSCT" "$PROJ/sw/run_idx.tcl" "$BIT" "$ELF" "$FSBL" 2>&1)
    echo "$RESULT" >> "$LOG"

    # 5. Parse result
    if echo "$RESULT" | grep -q "ALL PASSED"; then
        TOTAL=$(echo "$RESULT" | grep "Total:" | sed 's/.*Total: //' | sed 's/ .*//')
        echo "Layer $LPAD: PASS ${TOTAL}/${TOTAL}"
        echo "  Layer $LPAD: PASS ${TOTAL}/${TOTAL}" >> "$RESULTS"
        PASS_COUNT=$((PASS_COUNT + 1))
    elif echo "$RESULT" | grep -q "FAILED"; then
        TOTAL=$(echo "$RESULT" | grep "Total:" | sed 's/.*Total: //' | sed 's/ .*//')
        ERRORS=$(echo "$RESULT" | grep "Errors:" | sed 's/.*Errors: //' | sed 's/ .*//')
        echo "Layer $LPAD: FAIL (Errors=$ERRORS/$TOTAL)"
        echo "  Layer $LPAD: FAIL (Errors=$ERRORS/$TOTAL)" >> "$RESULTS"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif echo "$RESULT" | grep -qiE "DAP|no targets|transaction error|connection"; then
        echo "Layer $LPAD: DAP_ERROR - attempting retry..."
        # DAP error: wait 15s and retry once
        powershell -Command "Get-Process java,hw_server,xsct -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
        sleep 15
        RESULT=$("$XSCT" "$PROJ/sw/run_idx.tcl" "$BIT" "$ELF" "$FSBL" 2>&1)
        echo "$RESULT" >> "$LOG"

        if echo "$RESULT" | grep -q "ALL PASSED"; then
            TOTAL=$(echo "$RESULT" | grep "Total:" | sed 's/.*Total: //' | sed 's/ .*//')
            echo "Layer $LPAD: PASS ${TOTAL}/${TOTAL} (after retry)"
            echo "  Layer $LPAD: PASS ${TOTAL}/${TOTAL}" >> "$RESULTS"
            PASS_COUNT=$((PASS_COUNT + 1))
        elif echo "$RESULT" | grep -q "FAILED"; then
            TOTAL=$(echo "$RESULT" | grep "Total:" | sed 's/.*Total: //' | sed 's/ .*//')
            ERRORS=$(echo "$RESULT" | grep "Errors:" | sed 's/.*Errors: //' | sed 's/ .*//')
            echo "Layer $LPAD: FAIL (Errors=$ERRORS/$TOTAL) (after retry)"
            echo "  Layer $LPAD: FAIL (Errors=$ERRORS/$TOTAL)" >> "$RESULTS"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "Layer $LPAD: BOARD_HUNG - stopping"
            echo "  Layer $LPAD: BOARD_HUNG" >> "$RESULTS"
            HUNG_COUNT=$((HUNG_COUNT + 1))
            break
        fi
    else
        echo "Layer $LPAD: UNKNOWN"
        echo "  Layer $LPAD: UNKNOWN" >> "$RESULTS"
        echo "$RESULT" | tail -5
    fi

    TESTED=$((TESTED + 1))

    # Extra safety delay
    sleep 5
done

echo ""
echo "========================================="
echo "BATCH COMPLETE: $TESTED layers tested"
echo "  PASS: $PASS_COUNT"
echo "  FAIL: $FAIL_COUNT"
echo "  HUNG: $HUNG_COUNT"
echo "========================================="
