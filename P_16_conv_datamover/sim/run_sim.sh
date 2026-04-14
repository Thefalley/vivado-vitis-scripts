#!/usr/bin/env bash
# run_sim.sh -- Compile + elab + simulate P_16 conv_stream_wrapper TB
# Usage: bash run_sim.sh   (writes sim.log)
set -u
set -o pipefail

SIM_DIR="C:/project/vivado/P_16_conv_datamover/sim"
SRC_P13="C:/project/vivado/P_13_conv_test/src"
SRC_P16="C:/project/vivado/P_16_conv_datamover/src"

cd "$SIM_DIR" || exit 1

LOG=sim.log
: > "$LOG"

echo "===== P_16 conv_stream_wrapper TB =====" | tee -a "$LOG"
echo "Working dir: $(pwd)"                     | tee -a "$LOG"
date                                            | tee -a "$LOG"

# ---------------------------------------------------------------------------
# xvhdl (analyze)
# Order matters: lower-level units first.
# ---------------------------------------------------------------------------
echo "-- xvhdl: analyzing VHDL sources --" | tee -a "$LOG"

xvhdl -2008 \
    "$SRC_P13/mul_s32x32_pipe.vhd" \
    "$SRC_P13/requantize.vhd" \
    "$SRC_P13/mac_unit.vhd" \
    "$SRC_P13/mac_array.vhd" \
    "$SRC_P13/conv_engine_v3.vhd" \
    "$SRC_P16/conv_stream_wrapper.vhd" \
    "$SIM_DIR/conv_stream_tb.vhd" 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
if [ "$RC" -ne 0 ]; then
    echo "!!! xvhdl FAILED (rc=$RC)" | tee -a "$LOG"
    exit 1
fi

# ---------------------------------------------------------------------------
# xelab
# ---------------------------------------------------------------------------
echo "-- xelab: elaborating conv_stream_tb --" | tee -a "$LOG"

xelab -debug typical -top conv_stream_tb -snapshot conv_stream_tb_snap 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
if [ "$RC" -ne 0 ]; then
    echo "!!! xelab FAILED (rc=$RC)" | tee -a "$LOG"
    exit 1
fi

# ---------------------------------------------------------------------------
# xsim (batch; TB ends via 'assert false ... severity failure')
# ---------------------------------------------------------------------------
echo "-- xsim: running simulation --" | tee -a "$LOG"

cat > run_tcl.tcl <<'EOF'
run 20 us
quit
EOF

xsim conv_stream_tb_snap -R 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
echo "xsim rc=$RC" | tee -a "$LOG"

echo "===== DONE =====" | tee -a "$LOG"
date                   | tee -a "$LOG"
