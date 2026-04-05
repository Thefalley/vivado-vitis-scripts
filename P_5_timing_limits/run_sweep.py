"""
run_sweep.py - Barrido de timing para operaciones aritmeticas en Zynq-7020
Sintetiza e implementa cada combinacion (operacion x ancho_bits) y extrae WNS.
Sin trampas: resultado con ancho real de la operacion.

Uso: python P_5_timing_limits/run_sweep.py
"""
import subprocess
import sys
from pathlib import Path

VIVADO = r"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
PART = "xc7z020clg484-1"
CLK_PERIOD = 10.0  # ns (100 MHz)
SRC_DIR = Path(__file__).parent / "src"
BUILD_DIR = Path(__file__).parent / "build_sweep"

# op_mode: (name, result_width_formula)
# result_width formulas: "N+1", "2N", "N", "2N+1"
OP_CONFIGS = {
    0: ("ADD",       lambda n: n + 1),       # N + N = N+1 bits
    1: ("MULT",      lambda n: 2 * n),       # N * N = 2N bits
    2: ("SHIFT_VAR", lambda n: n),            # barrel shift = N bits
    3: ("MAC",       lambda n: 2 * n + 1),   # N*N + N = 2N+1 bits
}

BIT_WIDTHS = [8, 16, 24, 32, 48, 64]

TCL_TEMPLATE = """
set part "{part}"
set clk_period {clk_period}
set data_width {data_width}
set result_width {result_width}
set op_mode {op_mode}
set op_name "{op_name}"
set build_dir "{build_dir}"

# Read source
read_vhdl "{src_file}"

# Synth with generics
synth_design -top timing_test -part $part \\
    -generic DATA_WIDTH=$data_width \\
    -generic OP_MODE=$op_mode \\
    -generic RESULT_WIDTH=$result_width

# Clock constraint
create_clock -period $clk_period -name clk [get_ports clk]

# Implement
opt_design
place_design
route_design

# Timing
report_timing_summary -file "$build_dir/timing.rpt"
report_utilization -file "$build_dir/util.rpt"

# Extract WNS
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]

# Extract DSP and LUT counts
set dsp_used 0
set lut_used 0
catch {{ set dsp_used [llength [get_cells -hierarchical -filter {{PRIMITIVE_TYPE =~ DSP*}}]] }}
catch {{ set lut_used [llength [get_cells -hierarchical -filter {{PRIMITIVE_TYPE =~ CLB.LUT*}}]] }}

# Extract FF count
set ff_used 0
catch {{ set ff_used [llength [get_cells -hierarchical -filter {{PRIMITIVE_TYPE =~ CLB.FF*}}]] }}

puts "RESULT|$op_name|$data_width|$result_width|$wns|$dsp_used|$lut_used|$ff_used"
"""


def run_test(op_mode, op_name, data_width, result_width):
    build_dir = BUILD_DIR / f"{op_name}_{data_width}"
    build_dir.mkdir(parents=True, exist_ok=True)

    tcl_content = TCL_TEMPLATE.format(
        part=PART,
        clk_period=CLK_PERIOD,
        data_width=data_width,
        result_width=result_width,
        op_mode=op_mode,
        op_name=op_name,
        build_dir=str(build_dir).replace("\\", "/"),
        src_file=str(SRC_DIR / "timing_test.vhd").replace("\\", "/"),
    )

    tcl_file = build_dir / "run.tcl"
    tcl_file.write_text(tcl_content)

    cmd = [VIVADO, "-mode", "batch", "-source", str(tcl_file)]
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=str(build_dir))

    for line in result.stdout.splitlines():
        if line.startswith("RESULT|"):
            parts = line.split("|")
            return {
                "op": parts[1],
                "bits": int(parts[2]),
                "res_bits": int(parts[3]),
                "wns": float(parts[4]),
                "dsp": int(parts[5]),
                "luts": int(parts[6]),
                "ffs": int(parts[7]),
            }

    # Debug: print last lines if failed
    for line in result.stdout.splitlines()[-5:]:
        print(f"    {line}")
    return None


def main():
    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    total = len(OP_CONFIGS) * len(BIT_WIDTHS)
    print(f"Timing sweep @ {CLK_PERIOD}ns ({1000/CLK_PERIOD:.0f} MHz) on {PART}")
    print(f"Operaciones: {[v[0] for v in OP_CONFIGS.values()]}")
    print(f"Anchos: {BIT_WIDTHS} bits")
    print(f"Total: {total} tests\n")

    results = []
    count = 0

    for op_mode, (op_name, res_fn) in OP_CONFIGS.items():
        for bw in BIT_WIDTHS:
            count += 1
            rw = res_fn(bw)
            print(f"[{count:2d}/{total}] {op_name:10s} {bw:3d}b -> {rw:3d}b result ... ",
                  end="", flush=True)
            r = run_test(op_mode, op_name, bw, rw)
            if r:
                met = "OK" if r["wns"] >= 0 else "FAIL"
                print(f"WNS={r['wns']:+.3f}ns  DSP={r['dsp']}  LUT={r['luts']}  FF={r['ffs']}  [{met}]")
                results.append(r)
            else:
                print("ERROR")

    # Summary table
    print("\n" + "=" * 90)
    print(f"{'OP':10s} | {'IN':>3s} | {'OUT':>3s} | {'WNS(ns)':>8s} | {'MET':>4s} | {'Fmax(MHz)':>9s} | {'DSP':>3s} | {'LUT':>4s} | {'FF':>4s}")
    print("-" * 90)
    for r in results:
        met = "OK" if r["wns"] >= 0 else "FAIL"
        slack = CLK_PERIOD - r["wns"]
        fmax = 1000.0 / slack if slack > 0 else 999.9
        print(f"{r['op']:10s} | {r['bits']:3d} | {r['res_bits']:3d} | {r['wns']:+8.3f} | {met:>4s} | {fmax:9.1f} | {r['dsp']:3d} | {r['luts']:4d} | {r['ffs']:4d}")

    print("=" * 90)
    print(f"\nClock target: {CLK_PERIOD}ns ({1000/CLK_PERIOD:.0f} MHz)")
    print("WNS > 0 = timing met (sobra tiempo)")
    print("WNS < 0 = timing violation (falta tiempo, hay que partir)")
    print("Fmax = frecuencia maxima real de esa operacion combinacional")
    print("DSP > 0 = Vivado usa DSP48 slices (multiplicadores HW)")


if __name__ == "__main__":
    main()
