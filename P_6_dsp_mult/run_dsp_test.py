"""
run_dsp_test.py - Comparativa DSP: multiplicacion 32x30 en Zynq-7020
Sintetiza e implementa las 4 variantes y extrae timing + recursos.

Uso: python P_6_dsp_mult/run_dsp_test.py [clk_period_ns]
     python P_6_dsp_mult/run_dsp_test.py 10    # 100 MHz
     python P_6_dsp_mult/run_dsp_test.py 4     # 250 MHz
"""
import subprocess
import sys
import re
from pathlib import Path

VIVADO = r"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
PART = "xc7z020clg484-1"
CLK_PERIOD = float(sys.argv[1]) if len(sys.argv) > 1 else 4.0  # ns
SRC_DIR = Path(__file__).parent / "src"
BUILD_DIR = Path(__file__).parent / "build_sweep"

VARIANTS = [
    {"top": "mult_4dsp_tree", "desc": "4 DSP + tree sum",  "lat": 4, "thr": "1/ciclo"},
    {"top": "mult_4dsp",      "desc": "4 DSP cascada",     "lat": 3, "thr": "1/ciclo"},
    {"top": "mult_2dsp",      "desc": "2 DSP mux",         "lat": 4, "thr": "1/4 ciclos"},
    {"top": "mult_1dsp",      "desc": "1 DSP secuencial",  "lat": 5, "thr": "1/5 ciclos"},
]

SRC_FILES = [str(f).replace("\\", "/") for f in sorted(SRC_DIR.glob("*.vhd"))]

SYNTH_TCL = """
set top "{top}"
set part "{part}"
set clk_period {clk_period}
set build_dir "{build_dir}"
set src_files [list {src_files_tcl}]

foreach f $src_files {{
    read_vhdl $f
}}

synth_design -top $top -part $part

create_clock -period $clk_period -name clk [get_ports clk]
set_input_delay  -clock clk 0.5 [get_ports -filter {{NAME != clk}}]
set_output_delay -clock clk 0.5 [get_ports -filter {{DIRECTION == OUT}}]

opt_design
place_design
route_design

report_timing_summary -file "$build_dir/timing.rpt"
report_utilization -file "$build_dir/util.rpt"

set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts "WNS_RESULT|$wns"
"""


def parse_util_report(build_dir):
    """Parsear el report de utilizacion directamente."""
    util_file = build_dir / "util.rpt"
    if not util_file.exists():
        return 0, 0, 0

    text = util_file.read_text()
    dsp = 0
    lut = 0
    ff = 0

    # Buscar DSPs
    m = re.search(r'\| DSPs\s+\|\s+(\d+)', text)
    if m:
        dsp = int(m.group(1))

    # Buscar Slice LUTs
    m = re.search(r'\| Slice LUTs\s+\|\s+(\d+)', text)
    if m:
        lut = int(m.group(1))

    # Buscar Slice Registers (FFs)
    m = re.search(r'\| Slice Registers\s+\|\s+(\d+)', text)
    if m:
        ff = int(m.group(1))

    return dsp, lut, ff


def run_synth(variant):
    top = variant["top"]
    build_dir = BUILD_DIR / top
    build_dir.mkdir(parents=True, exist_ok=True)

    src_files_tcl = " ".join(f'"{f}"' for f in SRC_FILES)

    tcl_content = SYNTH_TCL.format(
        top=top,
        part=PART,
        clk_period=CLK_PERIOD,
        build_dir=str(build_dir).replace("\\", "/"),
        src_files_tcl=src_files_tcl,
    )

    tcl_file = build_dir / "run.tcl"
    tcl_file.write_text(tcl_content)

    cmd = [VIVADO, "-mode", "batch", "-source", str(tcl_file)]
    print(f"  Ejecutando Vivado para {top}...")
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=str(build_dir))

    # Extraer WNS del stdout
    wns = None
    for line in result.stdout.splitlines():
        if line.startswith("WNS_RESULT|"):
            wns = float(line.split("|")[1])
            break

    if wns is None:
        print(f"  ERROR: No se encontro WNS para {top}")
        for line in result.stdout.splitlines()[-10:]:
            print(f"    {line}")
        return None

    # Parsear recursos del report
    dsp, lut, ff = parse_util_report(build_dir)

    return {
        "top": top,
        "wns": wns,
        "dsp": dsp,
        "lut": lut,
        "ff":  ff,
    }


def main():
    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    print(f"=" * 80)
    print(f"  COMPARATIVA DSP: Multiplicacion 32x30 en {PART}")
    print(f"  Clock target: {CLK_PERIOD} ns ({1000/CLK_PERIOD:.0f} MHz)")
    print(f"=" * 80)
    print()

    results = []
    for i, var in enumerate(VARIANTS):
        print(f"[{i+1}/{len(VARIANTS)}] {var['desc']} ({var['top']})")
        r = run_synth(var)
        if r:
            r["desc"] = var["desc"]
            r["lat"]  = var["lat"]
            r["thr"]  = var["thr"]
            met = "OK" if r["wns"] >= 0 else "FAIL"
            print(f"  -> WNS={r['wns']:+.3f}ns  DSP={r['dsp']}  LUT={r['lut']}  FF={r['ff']}  [{met}]")
            results.append(r)
        else:
            print(f"  -> ERROR")
        print()

    if not results:
        print("No hay resultados.")
        sys.exit(1)

    # Tabla resumen
    print()
    print("=" * 110)
    print(f"  TABLA COMPARATIVA: Multiplicacion 32x30 unsigned")
    print(f"  FPGA: {PART} (ZedBoard / Zynq-7020)")
    print(f"  DSP48E1: multiplicador interno 25x18 = 43 bits max")
    print(f"  Para 32x30 = 62 bits: necesita productos parciales")
    print(f"  Clock target: {CLK_PERIOD} ns ({1000/CLK_PERIOD:.0f} MHz)")
    print("=" * 110)
    print()
    header = (f"{'Variante':25s} | {'DSP':>3s} | {'LUT':>4s} | {'FF':>4s} | "
              f"{'Lat':>3s} | {'Throughput':>12s} | {'WNS(ns)':>8s} | {'Met':>4s} | {'Fmax(MHz)':>9s}")
    print(header)
    print("-" * len(header))

    for r in results:
        met = "OK" if r["wns"] >= 0 else "FAIL"
        real_period = CLK_PERIOD - r["wns"]
        fmax = 1000.0 / real_period if real_period > 0 else 999.9
        print(f"{r['desc']:25s} | {r['dsp']:3d} | {r['lut']:4d} | {r['ff']:4d} | "
              f"{r['lat']:3d} | {r['thr']:>12s} | {r['wns']:+8.3f} | {met:>4s} | {fmax:9.1f}")

    print("-" * len(header))
    print()
    print("Leyenda:")
    print("  DSP  = DSP48E1 slices usados (multiplicadores HW)")
    print("  LUT  = Look-Up Tables (logica combinacional en fabric)")
    print("  FF   = Flip-Flops (registros)")
    print("  Lat  = Latencia en ciclos de reloj (entrada -> salida)")
    print("  WNS  = Worst Negative Slack (>0 = timing met)")
    print("  Fmax = Frecuencia maxima real del critical path")
    print()
    print("Nota sobre sumas:")
    print("  - 'cascada': P1 + (P2<<18) + (P3<<18) + (P4<<36) en 1 ciclo = 3 carry chains")
    print("  - 'tree sum': S1=P1+(P2<<18), S2=(P3<<18)+(P4<<36) paralelo, luego S1+S2")
    print("                = 2 carry chains paralelas + 1 final = mejor Fmax")
    print()

    # Guardar resultados
    out_file = Path(__file__).parent / "results.txt"
    with open(out_file, "w") as f:
        f.write(f"Multiplicacion 32x30 en {PART} @ {CLK_PERIOD}ns ({1000/CLK_PERIOD:.0f} MHz)\n\n")
        f.write(header + "\n")
        f.write("-" * len(header) + "\n")
        for r in results:
            met = "OK" if r["wns"] >= 0 else "FAIL"
            real_period = CLK_PERIOD - r["wns"]
            fmax = 1000.0 / real_period if real_period > 0 else 999.9
            f.write(f"{r['desc']:25s} | {r['dsp']:3d} | {r['lut']:4d} | {r['ff']:4d} | "
                    f"{r['lat']:3d} | {r['thr']:>12s} | {r['wns']:+8.3f} | {met:>4s} | {fmax:9.1f}\n")
    print(f"Resultados guardados en: {out_file}")


if __name__ == "__main__":
    main()
