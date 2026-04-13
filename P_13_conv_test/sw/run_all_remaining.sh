#!/bin/bash
# Run all remaining YOLOv4 layer tests on ZedBoard
# Skips already-tested layers: 0,1,2,3,5,8,10,15 (original) + 4,6,7,9,11,12 (this session)

cd C:/project/vivado/P_13_conv_test

BIT="build/zynq_conv.runs/impl_1/zynq_conv_bd_wrapper.bit"
ELF="vitis_ws/conv_test/Debug/conv_test.elf"
FSBL="vitis_ws/zynq_conv_platform/zynq_fsbl/fsbl.elf"
XSCT="C:/AMDDesignTools/2025.2/Vitis/bin/xsct.bat"
LOG="sw/batch_log.txt"

# Already tested layers: 0,1,2,3,4,5,6,7,8,9,10,11,12,13,15
DONE="0 1 2 3 4 5 6 7 8 9 10 11 12 13 15"

# Priority order: priority layers first, then fill in the rest
PRIORITY="14 16 20 25 30 40 50 60 70 80 90 100 109"
FILL="17 18 19 21 22 23 24 26 27 28 29 31 32 33 34 35 36 37 38 39 41 42 43 44 45 46 47 48 49 51 52 53 54 55 56 57 58 59 61 62 63 64 65 66 67 68 69 71 72 73 74 75 76 77 78 79 81 82 83 84 85 86 87 88 89 91 92 93 94 95 96 97 98 99 101 102 103 104 105 106 107 108"

ALL_LAYERS="$PRIORITY $FILL"

echo "=== Starting batch run at $(date) ===" >> "$LOG"
PASS_COUNT=0
FAIL_COUNT=0
ERROR_COUNT=0

for LAYER in $ALL_LAYERS; do
    LPAD=$(printf "%03d" $LAYER)
    SRC="sw/layer_tests/layer_${LPAD}_test.c"

    if [ ! -f "$SRC" ]; then
        echo "SKIP: $SRC not found" >> "$LOG"
        continue
    fi

    CONFIG=$(grep "Original layer:" "$SRC" | sed 's/.*Original layer: //;s/ *$//')
    # Get test subset info (crop line)
    CROP=$(grep "Test subset:" "$SRC" | sed 's/.*Test subset: //;s/ *$//')

    echo "" >> "$LOG"
    echo "===== LAYER $LPAD =====" >> "$LOG"
    echo "Config: $CONFIG" >> "$LOG"
    echo "Subset: $CROP" >> "$LOG"

    # Kill stale processes
    powershell -Command "Get-Process java,hw_server,eclipse,rdi_xsct -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
    # Remove lock file if present
    rm -f vitis_ws/.metadata/.lock 2>/dev/null
    sleep 2

    # Copy and build
    cp "$SRC" vitis_ws/conv_test/src/conv_test.c
    BUILD_OUT=$("$XSCT" -eval "setws vitis_ws; app build conv_test" 2>&1)
    echo "Build: $(echo "$BUILD_OUT" | grep -c "Finished building") finished" >> "$LOG"

    if ! echo "$BUILD_OUT" | grep -q "Finished building"; then
        echo "BUILD FAILED" >> "$LOG"
        echo "$BUILD_OUT" | tail -5 >> "$LOG"
        echo "  Layer $LPAD ($CONFIG): BUILD_FAIL" >> sw/layer_test_results.txt
        ERROR_COUNT=$((ERROR_COUNT + 1))
        # Kill and remove lock for next iteration
        powershell -Command "Get-Process java,hw_server,eclipse,rdi_xsct -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
        rm -f vitis_ws/.metadata/.lock 2>/dev/null
        sleep 2
        continue
    fi

    # Kill build's leftover processes before run
    powershell -Command "Get-Process java,hw_server,eclipse,rdi_xsct -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
    rm -f vitis_ws/.metadata/.lock 2>/dev/null
    sleep 1

    # Run on hardware
    RUN_OUT=$("$XSCT" sw/run_idx.tcl "$BIT" "$ELF" "$FSBL" 2>&1)

    # Check for errors
    if echo "$RUN_OUT" | grep -qiE "DAP|AHB AP|can't read|no such variable"; then
        echo "  JTAG ERROR - retrying after 10s..." >> "$LOG"
        echo "$RUN_OUT" | tail -5 >> "$LOG"
        powershell -Command "Get-Process java,hw_server,eclipse,rdi_xsct -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
        rm -f vitis_ws/.metadata/.lock 2>/dev/null
        sleep 10
        RUN_OUT=$("$XSCT" sw/run_idx.tcl "$BIT" "$ELF" "$FSBL" 2>&1)
        if echo "$RUN_OUT" | grep -qiE "DAP|AHB AP|can't read|no such variable"; then
            echo "  BOARD_HUNG after retry" >> "$LOG"
            echo "  Layer $LPAD ($CONFIG): BOARD_HUNG" >> sw/layer_test_results.txt
            ERROR_COUNT=$((ERROR_COUNT + 1))
            sleep 30
            continue
        fi
    fi

    # Parse results
    TOTAL=$(echo "$RUN_OUT" | grep "Total:" | sed 's/.*Total: //;s/ tests//')
    ERRORS=$(echo "$RUN_OUT" | grep "Errors:" | sed 's/.*Errors: //')

    if [ -z "$TOTAL" ]; then
        echo "  NO RESULT (timeout?)" >> "$LOG"
        echo "$RUN_OUT" | tail -5 >> "$LOG"
        echo "  Layer $LPAD ($CONFIG): TIMEOUT" >> sw/layer_test_results.txt
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    if [ "$ERRORS" = "0" ]; then
        STATUS="PASS"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        STATUS="FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    echo "  $STATUS: Total=$TOTAL Errors=$ERRORS" >> "$LOG"
    echo "  Layer $LPAD ($CONFIG): $STATUS $TOTAL/$TOTAL" >> sw/layer_test_results.txt
    echo "Layer $LPAD: $STATUS"
done

echo "" >> "$LOG"
echo "=== Batch complete at $(date) ===" >> "$LOG"
echo "PASS: $PASS_COUNT  FAIL: $FAIL_COUNT  ERROR: $ERROR_COUNT" >> "$LOG"
echo "BATCH_DONE PASS=$PASS_COUNT FAIL=$FAIL_COUNT ERROR=$ERROR_COUNT"
