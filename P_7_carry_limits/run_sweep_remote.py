"""
run_sweep_remote.py - Barrido de carry chain limits en servidor remoto
Sube carry_test.vhd, ejecuta Vivado en remoto, descarga resultados.

Uso: python P_7_carry_limits/run_sweep_remote.py
"""
import subprocess
import sys
import os
import re
from pathlib import Path

# ========================== CONFIG ==========================
SSH_HOST = "100.73.144.105"
SSH_USER = "jce03"
SSH_KEY  = os.path.expanduser("~/.ssh/pc-casa")
VIVADO   = "E:/vivado-instalado/2025.2.1/Vivado/bin/vivado.bat"
REMOTE_WORKDIR = "C:/Users/jce03/Desktop/claude/carry_sweep"
# ============================================================

PART = "xc7z020clg484-1"
CLK_PERIOD = 10.0
SRC_FILE = Path(__file__).parent / "src" / "carry_test.vhd"

SSH_ARGS = ["-i", SSH_KEY, "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=no",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=10"]

OP_CONFIGS = {
    0: ("ADD_U",     lambda n: n + 1),
    1: ("ADD_S",     lambda n: n + 1),
    2: ("ADD_3WAY",  lambda n: n + 2),
    3: ("ADD_4TREE", lambda n: n + 2),
    4: ("SHIFT_VAR", lambda n: n),
    5: ("ADD_CARRY", lambda n: n + 1),
}

BIT_WIDTHS = [8, 9, 18, 32, 48, 64]


def ssh(cmd, timeout=600):
    full = ["ssh"] + SSH_ARGS + [f"{SSH_USER}@{SSH_HOST}", cmd]
    r = subprocess.run(full, capture_output=True, text=True, timeout=timeout)
    return r.stdout, r.returncode


def scp_to(local, remote):
    full = ["scp"] + SSH_ARGS + [str(local), f"{SSH_USER}@{SSH_HOST}:{remote}"]
    subprocess.run(full, capture_output=True, timeout=30)


def run_test(op_mode, op_name, data_width, result_width):
    remote_dir = f"{REMOTE_WORKDIR}/{op_name}_{data_width}"
    ssh(f"mkdir -p {remote_dir}")

    tcl = f"""
set part "{PART}"
read_vhdl "{REMOTE_WORKDIR}/carry_test.vhd"
synth_design -top carry_test -part $part \\
    -generic DATA_WIDTH={data_width} \\
    -generic OP_MODE={op_mode} \\
    -generic RESULT_WIDTH={result_width}
create_clock -period {CLK_PERIOD} -name clk [get_ports clk]
opt_design
place_design
route_design
report_timing_summary -file "{remote_dir}/timing.rpt"
report_utilization -file "{remote_dir}/util.rpt"
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set dsp 0
set lut 0
set ff 0
catch {{ set dsp [llength [get_cells -hierarchical -filter {{PRIMITIVE_TYPE =~ DSP*}}]] }}
catch {{ set lut [llength [get_cells -hierarchical -filter {{PRIMITIVE_TYPE =~ CLB.LUT*}}]] }}
catch {{ set ff  [llength [get_cells -hierarchical -filter {{PRIMITIVE_TYPE =~ CLB.FF*}}]] }}
puts "RESULT|{op_name}|{data_width}|{result_width}|$wns|$dsp|$lut|$ff"
"""

    # Escribir TCL en remoto
    tcl_escaped = tcl.replace('"', '\\"').replace('$', '\\$')
    ssh(f'echo "{tcl_escaped}" > {remote_dir}/run.tcl', timeout=10)

    # Mejor: subir como fichero
    tcl_local = Path(__file__).parent / "build_sweep" / f"{op_name}_{data_width}" / "run_remote.tcl"
    tcl_local.parent.mkdir(parents=True, exist_ok=True)
    tcl_local.write_text(tcl)
    scp_to(tcl_local, f"{remote_dir}/run.tcl")

    # Ejecutar Vivado
    stdout, rc = ssh(f'cd {remote_dir} && "{VIVADO}" -mode batch -source run.tcl', timeout=600)

    for line in stdout.splitlines():
        if line.startswith("RESULT|"):
            parts = line.split("|")
            return {
                "op": parts[1], "bits": int(parts[2]),
                "res_bits": int(parts[3]), "wns": float(parts[4]),
                "dsp": int(parts[5]), "lut": int(parts[6]), "ff": int(parts[7]),
            }

    # Fallback: parsear reports
    rpt_stdout, _ = ssh(f'cat {remote_dir}/timing.rpt', timeout=10)
    m = re.search(r'WNS\(ns\)\s+TNS.*\n\s*-+.*\n\s+(-?\d+\.\d+)', rpt_stdout)
    wns = float(m.group(1)) if m else -99

    util_stdout, _ = ssh(f'cat {remote_dir}/util.rpt', timeout=10)
    dsp = int(m.group(1)) if (m := re.search(r'\| DSPs\s+\|\s+(\d+)', util_stdout)) else 0
    lut = int(m.group(1)) if (m := re.search(r'\| Slice LUTs\s+\|\s+(\d+)', util_stdout)) else 0
    ff  = int(m.group(1)) if (m := re.search(r'\| Slice Registers\s+\|\s+(\d+)', util_stdout)) else 0

    return {"op": op_name, "bits": data_width, "res_bits": result_width,
            "wns": wns, "dsp": dsp, "lut": lut, "ff": ff}


def main():
    # Setup remoto
    print("Preparando servidor remoto...")
    ssh(f"mkdir -p {REMOTE_WORKDIR}")
    scp_to(SRC_FILE, f"{REMOTE_WORKDIR}/carry_test.vhd")

    # Tests
    tests = []
    for op_mode, (op_name, res_fn) in OP_CONFIGS.items():
        for bw in BIT_WIDTHS:
            tests.append((op_mode, op_name, bw, res_fn(bw)))

    total = len(tests)
    print(f"\n{'='*100}")
    print(f"  CARRY CHAIN LIMITS @ {CLK_PERIOD}ns ({1000/CLK_PERIOD:.0f} MHz) on {PART}")
    print(f"  Ejecutando en servidor remoto ({SSH_HOST})")
    print(f"  Total: {total} tests")
    print(f"{'='*100}\n")

    results = []
    for i, (op_mode, op_name, bw, rw) in enumerate(tests):
        print(f"[{i+1:2d}/{total}] {op_name:12s} {bw:3d}b -> {rw:3d}b ... ", end="", flush=True)
        try:
            r = run_test(op_mode, op_name, bw, rw)
            if r:
                met = "OK" if r["wns"] >= 0 else "FAIL"
                fmax = 1000.0 / (CLK_PERIOD - r["wns"]) if (CLK_PERIOD - r["wns"]) > 0 else 999.9
                r["fmax"] = fmax
                print(f"WNS={r['wns']:+.3f}ns  LUT={r['lut']:4d}  FF={r['ff']:4d}  Fmax={fmax:.0f}MHz  [{met}]")
                results.append(r)
            else:
                print("ERROR (no result)")
        except Exception as e:
            print(f"ERROR: {e}")

    # Tabla resumen
    print(f"\n{'='*110}")
    print(f"  TABLA: Limites de carry chain @ {CLK_PERIOD}ns ({1000/CLK_PERIOD:.0f} MHz)")
    print(f"{'='*110}")

    for op_name in ["ADD_U", "ADD_S", "ADD_3WAY", "ADD_4TREE", "ADD_CARRY", "SHIFT_VAR"]:
        op_results = [r for r in results if r["op"] == op_name]
        if not op_results:
            continue
        print(f"\n  {op_name}:")
        print(f"  {'Bits':>4s} | {'Res':>4s} | {'WNS(ns)':>8s} | {'Met':>4s} | {'Fmax':>6s} | {'LUT':>4s} | {'FF':>4s}")
        print(f"  -----+------+----------+------+--------+------+-----")
        max_ok = 0
        for r in op_results:
            met = "OK" if r["wns"] >= 0 else "FAIL"
            print(f"  {r['bits']:4d} | {r['res_bits']:4d} | {r['wns']:+8.3f} | {met:>4s} | {r['fmax']:6.0f} | {r['lut']:4d} | {r['ff']:4d}")
            if r["wns"] >= 0:
                max_ok = r["bits"]
        if max_ok > 0:
            print(f"  >>> Max OK: {max_ok} bits")

    # Guardar
    out_file = Path(__file__).parent / "results.txt"
    with open(out_file, "w") as f:
        f.write(f"Carry chain limits @ {CLK_PERIOD}ns ({1000/CLK_PERIOD:.0f} MHz) on {PART}\n\n")
        for op_name in ["ADD_U", "ADD_S", "ADD_3WAY", "ADD_4TREE", "ADD_CARRY", "SHIFT_VAR"]:
            op_results = [r for r in results if r["op"] == op_name]
            if not op_results:
                continue
            f.write(f"\n{op_name}:\n")
            for r in op_results:
                met = "OK" if r["wns"] >= 0 else "FAIL"
                f.write(f"  {r['bits']:3d}b  WNS={r['wns']:+.3f}  {met}  Fmax={r['fmax']:.0f}  LUT={r['lut']}  FF={r['ff']}\n")
    print(f"\nResultados: {out_file}")


if __name__ == "__main__":
    main()
