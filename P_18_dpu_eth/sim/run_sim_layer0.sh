#!/usr/bin/env bash
# Simulacion LAYER 0 del YOLOv4 con vectores reales del ONNX.
# Compila conv_engine_v3 + dependencias + TB. Corre xsim batch (sin GUI).
set -u
set -o pipefail

SIM_DIR="C:/project/vivado/P_18_dpu_eth/sim"
SRC_P13="C:/project/vivado/P_13_conv_test/src"

cd "$SIM_DIR" || exit 1
LOG=sim_layer0.log
: > "$LOG"

echo "===== SIM LAYER 0 =====" | tee -a "$LOG"
date | tee -a "$LOG"

xvhdl -2008 \
    "$SRC_P13/mul_s32x32_pipe.vhd" \
    "$SRC_P13/requantize.vhd" \
    "$SRC_P13/mac_unit.vhd" \
    "$SRC_P13/mac_array.vhd" \
    "$SRC_P13/conv_engine_v3.vhd" \
    conv_engine_v3_layer0_tb.vhd 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
if [ "$RC" -ne 0 ]; then
    echo "!!! xvhdl FAILED (rc=$RC)" | tee -a "$LOG"
    exit 1
fi

xelab -debug typical -top conv_engine_v3_layer0_tb \
    -snapshot layer0_snap 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
if [ "$RC" -ne 0 ]; then
    echo "!!! xelab FAILED (rc=$RC)" | tee -a "$LOG"
    exit 1
fi

cat > run_layer0.tcl <<'EOF'
run all
quit
EOF

xsim layer0_snap -t run_layer0.tcl 2>&1 | tee -a "$LOG"
echo "===== DONE =====" | tee -a "$LOG"
date | tee -a "$LOG"
