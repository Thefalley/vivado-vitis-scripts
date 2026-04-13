#!/bin/bash
# Run remaining layers with robust DAP-safe error detection
# v2: catches fpga errors, uses longer delays, proper retry logic

PROJ="C:/project/vivado/P_13_conv_test"
VITIS_GCC="C:/AMDDesignTools/2025.2/Vitis/gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe"
BSP_INC="$PROJ/vitis_ws/zynq_conv_platform/export/zynq_conv_platform/sw/zynq_conv_platform/standalone_domain/bspinclude/include"
BSP_LIB="$PROJ/vitis_ws/zynq_conv_platform/export/zynq_conv_platform/sw/zynq_conv_platform/standalone_domain/bsplib/lib"
LDSCRIPT="$PROJ/vitis_ws/conv_test/src/lscript.ld"
SPEC="$PROJ/vitis_ws/conv_test/Debug/Xilinx.spec"
SRC="$PROJ/vitis_ws/conv_test/src/conv_test.c"
OBJ="$PROJ/vitis_ws/conv_test/Debug/src/conv_test.o"
ELF="$PROJ/vitis_ws/conv_test/Debug/conv_test.elf"
BIT="$PROJ/vitis_ws/conv_test/_ide/bitstream/zynq_conv.bit"
FSBL="$PROJ/vitis_ws/zynq_conv_platform/zynq_fsbl/fsbl.elf"
XSCT="C:/AMDDesignTools/2025.2/Vitis/bin/xsct.bat"
RESULTS="$PROJ/sw/layer_test_results.txt"

LAYERS="$@"

PASS_COUNT=0
FAIL_COUNT=0
HUNG_COUNT=0
TESTED=0
CONSECUTIVE_ERRORS=0

run_xsct() {
    "$XSCT" "$PROJ/sw/run_idx.tcl" "$BIT" "$ELF" "$FSBL" 2>&1
}

is_board_error() {
    # Returns 0 (true) if result indicates board communication failure
    local result="$1"
    if echo "$result" | grep -qiE "DAP|no targets|transaction error|process_tcf_actions|fpga.*line|unable to access|Cannot access|connection reset|timeout"; then
        return 0
    fi
    return 1
}

for LAYER in $LAYERS; do
    LPAD=$(printf "%03d" $LAYER)

    # Kill stale processes
    powershell -Command "Get-Process java,hw_server,xsct -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
    sleep 7

    # 1. Copy source
    cp "$PROJ/sw/layer_tests/layer_${LPAD}_test.c" "$SRC"
    if [ $? -ne 0 ]; then
        echo "Layer $LPAD: COPY_FAIL"
        echo "  Layer $LPAD: COPY_FAIL" >> "$RESULTS"
        continue
    fi

    # 2. Compile
    "$VITIS_GCC" -Wall -O0 -g3 -c -fmessage-length=0 \
        -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
        -I"$BSP_INC" -o "$OBJ" "$SRC" 2>/dev/null
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
        -Wl,--whole-archive -lxil -Wl,--no-whole-archive -lgcc -lc 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "Layer $LPAD: LINK_FAIL"
        echo "  Layer $LPAD: LINK_FAIL" >> "$RESULTS"
        continue
    fi

    # 4. Run on board
    RESULT=$(run_xsct)

    if echo "$RESULT" | grep -q "ALL PASSED"; then
        TOTAL=$(echo "$RESULT" | grep "Total:" | sed 's/.*Total: //' | sed 's/ .*//')
        echo "Layer $LPAD: PASS ${TOTAL}/${TOTAL}"
        echo "  Layer $LPAD: PASS ${TOTAL}/${TOTAL}" >> "$RESULTS"
        PASS_COUNT=$((PASS_COUNT + 1))
        CONSECUTIVE_ERRORS=0
    elif echo "$RESULT" | grep -q "FAILED"; then
        TOTAL=$(echo "$RESULT" | grep "Total:" | sed 's/.*Total: //' | sed 's/ .*//')
        ERRORS=$(echo "$RESULT" | grep "Errors:" | sed 's/.*Errors: //' | sed 's/ .*//')
        echo "Layer $LPAD: FAIL (Errors=$ERRORS/$TOTAL)"
        echo "  Layer $LPAD: FAIL (Errors=$ERRORS/$TOTAL)" >> "$RESULTS"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        CONSECUTIVE_ERRORS=0
    elif is_board_error "$RESULT"; then
        echo "Layer $LPAD: BOARD_ERROR -- retrying in 15s..."
        powershell -Command "Get-Process java,hw_server,xsct -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
        sleep 15

        RESULT=$(run_xsct)

        if echo "$RESULT" | grep -q "ALL PASSED"; then
            TOTAL=$(echo "$RESULT" | grep "Total:" | sed 's/.*Total: //' | sed 's/ .*//')
            echo "Layer $LPAD: PASS ${TOTAL}/${TOTAL} (retry)"
            echo "  Layer $LPAD: PASS ${TOTAL}/${TOTAL}" >> "$RESULTS"
            PASS_COUNT=$((PASS_COUNT + 1))
            CONSECUTIVE_ERRORS=0
        elif echo "$RESULT" | grep -q "FAILED"; then
            TOTAL=$(echo "$RESULT" | grep "Total:" | sed 's/.*Total: //' | sed 's/ .*//')
            ERRORS=$(echo "$RESULT" | grep "Errors:" | sed 's/.*Errors: //' | sed 's/ .*//')
            echo "Layer $LPAD: FAIL (Errors=$ERRORS/$TOTAL) (retry)"
            echo "  Layer $LPAD: FAIL (Errors=$ERRORS/$TOTAL)" >> "$RESULTS"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            CONSECUTIVE_ERRORS=0
        else
            CONSECUTIVE_ERRORS=$((CONSECUTIVE_ERRORS + 1))
            echo "Layer $LPAD: BOARD_HUNG (retry failed too, consecutive=$CONSECUTIVE_ERRORS)"
            echo "  Layer $LPAD: BOARD_HUNG" >> "$RESULTS"
            HUNG_COUNT=$((HUNG_COUNT + 1))
            if [ $CONSECUTIVE_ERRORS -ge 2 ]; then
                echo "*** 2 consecutive board errors, stopping ***"
                break
            fi
            # Try one more layer with extra-long wait
            powershell -Command "Get-Process java,hw_server,xsct -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
            sleep 20
        fi
    else
        echo "Layer $LPAD: UNKNOWN_RESULT"
        echo "$RESULT" | tail -5
        # Treat as potential board error
        CONSECUTIVE_ERRORS=$((CONSECUTIVE_ERRORS + 1))
        if [ $CONSECUTIVE_ERRORS -ge 2 ]; then
            echo "*** 2 consecutive unknown results, stopping ***"
            echo "  Layer $LPAD: UNKNOWN" >> "$RESULTS"
            break
        fi
    fi

    TESTED=$((TESTED + 1))
    sleep 5
done

echo ""
echo "========================================="
echo "BATCH COMPLETE: $TESTED layers tested"
echo "  PASS: $PASS_COUNT"
echo "  FAIL: $FAIL_COUNT"
echo "  HUNG: $HUNG_COUNT"
echo "========================================="
