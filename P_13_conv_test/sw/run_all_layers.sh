#!/bin/bash
# run_all_layers.sh -- Run all 110 YOLOv4 layer tests on ZedBoard
# Results saved to layer_test_results.txt

PROJ="C:/project/vivado/P_13_conv_test"
XSCT="C:/AMDDesignTools/2025.2/Vitis/bin/xsct.bat"
BIT="$PROJ/build/zynq_conv.runs/impl_1/zynq_conv_bd_wrapper.bit"
ELF="$PROJ/vitis_ws/conv_test/Debug/conv_test.elf"
FSBL="$PROJ/vitis_ws/zynq_conv_platform/zynq_fsbl/fsbl.elf"
RESULTS="$PROJ/sw/layer_test_results.txt"

echo "YOLOv4 Layer Test Results -- $(date)" > "$RESULTS"
echo "=========================================" >> "$RESULTS"

total_pass=0
total_fail=0
total_timeout=0

for i in $(seq 0 109); do
    idx=$(printf "%03d" $i)
    src="$PROJ/sw/layer_tests/layer_${idx}_test.c"

    if [ ! -f "$src" ]; then
        echo "Layer $idx: SKIP (file not found)" | tee -a "$RESULTS"
        continue
    fi

    # Kill stale processes
    powershell -Command "Get-Process java,hw_server -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
    sleep 3

    # Copy and build
    cp "$src" "$PROJ/vitis_ws/conv_test/src/conv_test.c"
    build_out=$("$XSCT" -eval "setws vitis_ws; app build conv_test" 2>&1 | tail -1)

    if [[ "$build_out" != *"Finished"* ]]; then
        echo "Layer $idx: BUILD FAIL" | tee -a "$RESULTS"
        total_fail=$((total_fail + 1))
        continue
    fi

    # Run on ZedBoard
    run_out=$("$XSCT" "$PROJ/sw/run_idx.tcl" "$BIT" "$ELF" "$FSBL" 2>&1)

    total=$(echo "$run_out" | grep "Total:" | sed 's/.*Total: //' | sed 's/ tests//')
    errors=$(echo "$run_out" | grep "Errors:" | sed 's/.*Errors: //')

    if echo "$run_out" | grep -q "ALL PASSED"; then
        echo "Layer $idx: PASS $total/$total" | tee -a "$RESULTS"
        total_pass=$((total_pass + 1))
    elif echo "$run_out" | grep -q "FAILED"; then
        echo "Layer $idx: FAIL ($errors errors of $total)" | tee -a "$RESULTS"
        total_fail=$((total_fail + 1))
    else
        echo "Layer $idx: TIMEOUT or ERROR" | tee -a "$RESULTS"
        total_timeout=$((total_timeout + 1))
    fi
done

echo "=========================================" >> "$RESULTS"
echo "TOTAL: $total_pass/110 PASS, $total_fail FAIL, $total_timeout TIMEOUT" >> "$RESULTS"
echo "" >> "$RESULTS"
echo "========================================="
echo "TOTAL: $total_pass/110 PASS, $total_fail FAIL, $total_timeout TIMEOUT"
echo "========================================="
