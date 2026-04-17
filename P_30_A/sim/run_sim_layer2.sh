#!/usr/bin/env bash
# Simula conv_engine_v4 con vectores de layer 2 de YOLOv4
# Layer 2: CONV 32->64, k=3, stride=2, pad=1 (pesos 18 KB > 4 KB BRAM)
# En modo normal (no_clear=0, no_requantize=0, ext_wb_we=0) debe dar bit-exact.
set -u
set -o pipefail

SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SIM_DIR/../src"

cd "$SIM_DIR" || exit 1
LOG=sim_layer2.log
: > "$LOG"

echo "===== P_30_A sim layer 2 =====" | tee -a "$LOG"
date | tee -a "$LOG"

xvhdl -2008 \
    "$SRC_DIR/mul_s32x32_pipe.vhd" \
    "$SRC_DIR/requantize.vhd" \
    "$SRC_DIR/mac_unit.vhd" \
    "$SRC_DIR/mac_array.vhd" \
    "$SRC_DIR/conv_engine_v4.vhd" \
    "$SRC_DIR/fifo_weights.vhd" \
    conv_v4_layer2_tb.vhd 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
if [ "$RC" -ne 0 ]; then
    echo "!!! xvhdl FAILED (rc=$RC)" | tee -a "$LOG"
    exit 1
fi

xelab -debug typical -top conv_v4_layer2_tb -snapshot layer2_snap 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
if [ "$RC" -ne 0 ]; then
    echo "!!! xelab FAILED (rc=$RC)" | tee -a "$LOG"
    exit 1
fi

cat > run_layer2.tcl <<'EOF'
run all
quit
EOF

xsim layer2_snap -t run_layer2.tcl 2>&1 | tee -a "$LOG"
echo "===== DONE =====" | tee -a "$LOG"
date | tee -a "$LOG"
