"""
run_sweep.py - Barrido exhaustivo de limites de carry chains y barrel shifters
Sintetiza e implementa cada combinacion y extrae WNS + recursos.

Uso: python P_7_carry_limits/run_sweep.py
"""
import subprocess
import sys
import re
from pathlib import Path

VIVADO = r"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
PART = "xc7z020clg484-1"
CLK_PERIOD = 10.0  # 100 MHz
SRC_DIR = Path(__file__).parent / "src"
BUILD_DIR = Path(__file__).parent / "build_sweep"

# op_mode: (name, result_width_fn, needs_c, needs_d, shift_bits_fn)
OP_CONFIGS = {
    0: ("ADD_U",       lambda n: n + 1,  False, False, None),
    1: ("ADD_S",       lambda n: n + 1,  False, False, None),
    2: ("ADD_3WAY",    lambda n: n + 2,  True,  False, None),
    3: ("ADD_4TREE",   lambda n: n + 2,  True,  True,  None),
    4: ("SHIFT_VAR",   lambda n: n,      False, False, lambda n: min(n, 32)),
    5: ("ADD_CARRY",   lambda n: n + 1,  True,  False, None),
}

# Anchos a probar (reducidos: los que importan)
BIT_WIDTHS = [8, 9, 18, 32, 48, 64]

# Para shift variable, mismos anchos
SHIFT_WIDTHS = [8, 9, 18, 32, 48, 64]

SYNTH_TCL = """
set part "{part}"
set clk_period {clk_period}
set data_width {data_width}
set result_width {result_width}
set op_mode {op_mode}
set op_name "{op_name}"
set build_dir "{build_dir}"

read_vhdl "{src_file}"

synth_design -top carry_test -part $part \\
    -generic DATA_WIDTH=$data_width \\
    -generic OP_MODE=$op_mode \\
    -generic RESULT_WIDTH=$result_width

create_clock -period $clk_period -name clk [get_ports clk]

opt_design
place_design
route_design

report_timing_summary -file "$build_dir/timing.rpt"
report_utilization -file "$build_dir/util.rpt"

set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts "RESULT|$op_name|$data_width|$result_width|$wns"

# Escribir resultado a fichero (Windows no captura stdout bien)
set fp [open "$build_dir/result.txt" w]
puts $fp "RESULT|$op_name|$data_width|$result_width|$wns"
close $fp
"""


def parse_util(build_dir):
    util_file = build_dir / "util.rpt"
    if not util_file.exists():
        return 0, 0, 0
    text = util_file.read_text()
    dsp = int(m.group(1)) if (m := re.search(r'\| DSPs\s+\|\s+(\d+)', text)) else 0
    lut = int(m.group(1)) if (m := re.search(r'\| Slice LUTs\s+\|\s+(\d+)', text)) else 0
    ff  = int(m.group(1)) if (m := re.search(r'\| Slice Registers\s+\|\s+(\d+)', text)) else 0
    return dsp, lut, ff


def run_test(op_mode, op_name, data_width, result_width):
    build_dir = BUILD_DIR / f"{op_name}_{data_width}"
    build_dir.mkdir(parents=True, exist_ok=True)

    tcl_content = SYNTH_TCL.format(
        part=PART,
        clk_period=CLK_PERIOD,
        data_width=data_width,
        result_width=result_width,
        op_mode=op_mode,
        op_name=op_name,
        build_dir=str(build_dir).replace("\\", "/"),
        src_file=str(SRC_DIR / "carry_test.vhd").replace("\\", "/"),
    )

    tcl_file = build_dir / "run.tcl"
    tcl_file.write_text(tcl_content)

    cmd = [VIVADO, "-mode", "batch", "-source", str(tcl_file)]
    subprocess.run(cmd, capture_output=True, text=True, cwd=str(build_dir))

    # Leer resultado de fichero (Vivado en Windows no captura stdout bien)
    result_file = build_dir / "result.txt"
    if result_file.exists():
        for line in result_file.read_text().splitlines():
            if line.startswith("RESULT|"):
                parts = line.split("|")
                wns = float(parts[4])
                dsp, lut, ff = parse_util(build_dir)
                return {"op": parts[1], "bits": int(parts[2]), "res_bits": int(parts[3]),
                        "wns": wns, "dsp": dsp, "lut": lut, "ff": ff}

    # Fallback: parsear timing report
    timing_file = build_dir / "timing.rpt"
    if timing_file.exists():
        text = timing_file.read_text()
        m = re.search(r'WNS\(ns\)\s+TNS.*\n\s*-+.*\n\s+(-?\d+\.\d+)', text)
        wns = float(m.group(1)) if m else -99
        dsp, lut, ff = parse_util(build_dir)
        return {"op": op_name, "bits": data_width, "res_bits": result_width,
                "wns": wns, "dsp": dsp, "lut": lut, "ff": ff}

    print(f"    ERROR: no result for {op_name}_{data_width}")
    return None


def main():
    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    # Operaciones a probar
    tests = []

    # ADD unsigned, signed, 3-way, 4-tree, add+carry
    for op_mode in [0, 1, 2, 3, 5]:
        op_name, res_fn, _, _, _ = OP_CONFIGS[op_mode]
        for bw in BIT_WIDTHS:
            tests.append((op_mode, op_name, bw, res_fn(bw)))

    # Shift variable (anchos distintos)
    op_mode = 4
    op_name, res_fn, _, _, _ = OP_CONFIGS[op_mode]
    for bw in SHIFT_WIDTHS:
        tests.append((op_mode, op_name, bw, res_fn(bw)))

    total = len(tests)
    print(f"=" * 100)
    print(f"  CARRY CHAIN LIMITS @ {CLK_PERIOD}ns ({1000/CLK_PERIOD:.0f} MHz) on {PART}")
    print(f"  Total: {total} tests")
    print(f"=" * 100)
    print()

    results = []
    for i, (op_mode, op_name, bw, rw) in enumerate(tests):
        print(f"[{i+1:2d}/{total}] {op_name:12s} {bw:3d}b -> {rw:3d}b ... ", end="", flush=True)
        r = run_test(op_mode, op_name, bw, rw)
        if r:
            met = "OK" if r["wns"] >= 0 else "FAIL"
            fmax = 1000.0 / (CLK_PERIOD - r["wns"]) if (CLK_PERIOD - r["wns"]) > 0 else 999.9
            print(f"WNS={r['wns']:+.3f}ns  LUT={r['lut']:4d}  FF={r['ff']:4d}  Fmax={fmax:.0f}MHz  [{met}]")
            r["fmax"] = fmax
            results.append(r)
        else:
            print("ERROR")

    # Tabla por operacion
    print()
    print("=" * 110)
    print(f"  TABLA: Limites de carry chain @ {CLK_PERIOD}ns ({1000/CLK_PERIOD:.0f} MHz)")
    print(f"  FPGA: {PART} (Zynq-7020)")
    print("=" * 110)

    for op_name in ["ADD_U", "ADD_S", "ADD_3WAY", "ADD_4TREE", "ADD_CARRY", "SHIFT_VAR"]:
        op_results = [r for r in results if r["op"] == op_name]
        if not op_results:
            continue

        print(f"\n  {op_name}:")
        print(f"  {'Bits':>4s} | {'Res':>4s} | {'WNS(ns)':>8s} | {'Met':>4s} | {'Fmax':>6s} | {'LUT':>4s} | {'FF':>4s}")
        print(f"  {'-'*4}-+-{'-'*4}-+-{'-'*8}-+-{'-'*4}-+-{'-'*6}-+-{'-'*4}-+-{'-'*4}")

        max_ok = 0
        for r in op_results:
            met = "OK" if r["wns"] >= 0 else "FAIL"
            fmax = r.get("fmax", 0)
            print(f"  {r['bits']:4d} | {r['res_bits']:4d} | {r['wns']:+8.3f} | {met:>4s} | {fmax:6.0f} | {r['lut']:4d} | {r['ff']:4d}")
            if r["wns"] >= 0:
                max_ok = r["bits"]

        if max_ok > 0:
            print(f"  >>> Maximo que pasa timing: {max_ok} bits")
        else:
            print(f"  >>> NINGUNO pasa timing a {1000/CLK_PERIOD:.0f} MHz")

    # Guardar
    out_file = Path(__file__).parent / "results.txt"
    with open(out_file, "w") as f:
        f.write(f"Carry chain limits @ {CLK_PERIOD}ns ({1000/CLK_PERIOD:.0f} MHz) on {PART}\n\n")
        for r in results:
            met = "OK" if r["wns"] >= 0 else "FAIL"
            f.write(f"{r['op']:12s} {r['bits']:3d}b  WNS={r['wns']:+.3f}  {met}  "
                    f"LUT={r['lut']}  FF={r['ff']}  Fmax={r.get('fmax',0):.0f}\n")
    print(f"\nResultados: {out_file}")


if __name__ == "__main__":
    main()
