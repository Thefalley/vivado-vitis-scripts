#!/bin/bash
# run_remaining.sh -- Run remaining YOLOv4 layer tests (skip already-passed ones)
# Already tested: 0,1,2,3,5,8,10,15 -> all PASS
# Representative set (covers all configs): 20,30,40,50,60,70,80,90,100,105,109

PROJ="C:/project/vivado/P_13_conv_test"
XSCT="C:/AMDDesignTools/2025.2/Vitis/bin/xsct.bat"
BIT="$PROJ/build/zynq_conv.runs/impl_1/zynq_conv_bd_wrapper.bit"
ELF="$PROJ/vitis_ws/conv_test/Debug/conv_test.elf"
FSBL="$PROJ/vitis_ws/zynq_conv_platform/zynq_fsbl/fsbl.elf"
RESULTS="$PROJ/sw/layer_test_results.txt"

# All 110 layers
LAYERS=$(seq 0 109)

# Skip already tested
SKIP="0 1 2 3 5 8 10 15"

pass=0
fail=0
skip=0

for i in $LAYERS; do
    # Check if already tested
    is_skip=0
    for s in $SKIP; do
        if [ "$i" = "$s" ]; then is_skip=1; break; fi
    done
    if [ "$is_skip" = "1" ]; then
        skip=$((skip + 1))
        continue
    fi

    idx=$(printf "%03d" $i)
    src="$PROJ/sw/layer_tests/layer_${idx}_test.c"

    if [ ! -f "$src" ]; then
        echo "Layer $idx: SKIP (no file)" | tee -a "$RESULTS"
        continue
    fi

    # Kill stale processes
    powershell -Command "Get-Process java,hw_server -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
    sleep 4

    # Copy and build
    cp "$src" "$PROJ/vitis_ws/conv_test/src/conv_test.c"
    build_out=$("$XSCT" -eval "setws vitis_ws; app build conv_test" 2>&1)

    if echo "$build_out" | grep -q "Error"; then
        echo "Layer $idx: BUILD FAIL" | tee -a "$RESULTS"
        fail=$((fail + 1))
        continue
    fi

    # Run on ZedBoard
    run_out=$("$XSCT" "$PROJ/sw/run_idx.tcl" "$BIT" "$ELF" "$FSBL" 2>&1)

    if echo "$run_out" | grep -q "ALL PASSED"; then
        total=$(echo "$run_out" | grep "Total:" | sed 's/.*Total: //' | sed 's/ tests//')
        echo "Layer $idx: PASS $total/$total" | tee -a "$RESULTS"
        pass=$((pass + 1))
    elif echo "$run_out" | grep -q "FAILED"; then
        errors=$(echo "$run_out" | grep "Errors:" | sed 's/.*Errors: //')
        total=$(echo "$run_out" | grep "Total:" | sed 's/.*Total: //' | sed 's/ tests//')
        echo "Layer $idx: FAIL ($errors errors of $total)" | tee -a "$RESULTS"
        fail=$((fail + 1))
    elif echo "$run_out" | grep -q "DAP"; then
        echo "Layer $idx: BOARD HUNG (DAP error) - stopping" | tee -a "$RESULTS"
        echo "" | tee -a "$RESULTS"
        echo "Board needs power cycle. Resume with run_remaining.sh (update SKIP list)." | tee -a "$RESULTS"
        break
    else
        echo "Layer $idx: TIMEOUT or ERROR" | tee -a "$RESULTS"
        fail=$((fail + 1))
    fi
done

echo "=========================================" | tee -a "$RESULTS"
echo "Session: $pass PASS, $fail FAIL, $skip skipped" | tee -a "$RESULTS"
echo "========================================="
