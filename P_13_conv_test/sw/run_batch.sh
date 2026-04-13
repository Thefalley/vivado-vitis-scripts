#!/bin/bash
# Run a batch of layer tests on ZedBoard
# Usage: bash sw/run_batch.sh <layer_numbers...>
# Example: bash sw/run_batch.sh 9 11 12 13 14 16 20 25 30

cd C:/project/vivado/P_13_conv_test

BIT="build/zynq_conv.runs/impl_1/zynq_conv_bd_wrapper.bit"
ELF="vitis_ws/conv_test/Debug/conv_test.elf"
FSBL="vitis_ws/zynq_conv_platform/zynq_fsbl/fsbl.elf"
XSCT="C:/AMDDesignTools/2025.2/Vitis/bin/xsct.bat"
RESULTS="sw/layer_test_results.txt"

for LAYER in "$@"; do
    LPAD=$(printf "%03d" $LAYER)
    SRC="sw/layer_tests/layer_${LPAD}_test.c"

    if [ ! -f "$SRC" ]; then
        echo "SKIP: $SRC not found"
        continue
    fi

    # Get config description
    CONFIG=$(grep "Original layer:" "$SRC" | sed 's/.*Original layer: //;s/ *$//')

    echo ""
    echo "===== LAYER $LPAD ($CONFIG) ====="

    # Kill stale processes
    powershell -Command "Get-Process java,hw_server -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
    sleep 3

    # Copy and build
    cp "$SRC" vitis_ws/conv_test/src/conv_test.c
    BUILD_OUT=$("$XSCT" -eval "setws vitis_ws; app build conv_test" 2>&1)
    if ! echo "$BUILD_OUT" | grep -q "Finished building"; then
        echo "  BUILD FAILED"
        echo "  Layer $LPAD ($CONFIG): BUILD_FAIL" >> "$RESULTS"
        continue
    fi

    # Run on hardware
    RUN_OUT=$("$XSCT" sw/run_idx.tcl "$BIT" "$ELF" "$FSBL" 2>&1)

    # Check for DAP error
    if echo "$RUN_OUT" | grep -qi "DAP\|AHB AP"; then
        echo "  DAP ERROR - retrying after 10s..."
        sleep 10
        powershell -Command "Get-Process java,hw_server -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
        sleep 5
        RUN_OUT=$("$XSCT" sw/run_idx.tcl "$BIT" "$ELF" "$FSBL" 2>&1)
        if echo "$RUN_OUT" | grep -qi "DAP\|AHB AP"; then
            echo "  BOARD_HUNG after retry"
            echo "  Layer $LPAD ($CONFIG): BOARD_HUNG" >> "$RESULTS"
            sleep 30
            continue
        fi
    fi

    # Parse results
    TOTAL=$(echo "$RUN_OUT" | grep "Total:" | sed 's/.*Total: //;s/ tests//')
    ERRORS=$(echo "$RUN_OUT" | grep "Errors:" | sed 's/.*Errors: //')

    if [ -z "$TOTAL" ]; then
        echo "  NO RESULT (timeout?)"
        echo "  Layer $LPAD ($CONFIG): TIMEOUT" >> "$RESULTS"
        continue
    fi

    if [ "$ERRORS" = "0" ]; then
        STATUS="PASS"
    else
        STATUS="FAIL"
    fi

    echo "  $STATUS: Total=$TOTAL Errors=$ERRORS"
    echo "  Layer $LPAD ($CONFIG): $STATUS $TOTAL/$TOTAL" >> "$RESULTS"
done

echo ""
echo "===== BATCH COMPLETE ====="
