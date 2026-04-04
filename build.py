"""
build.py - Vivado build automation
Uso:
    python build.py <proyecto> <comando>

Comandos:
    create   Crear proyecto Vivado desde project.cfg (RTL o Block Design)
    synth    Sintetizar
    impl     Implementar (place & route)
    bit      Generar bitstream
    export   Exportar .xsa para Vitis (proyectos Zynq)
    vitis    Crear workspace Vitis + compilar app bare-metal
    run      Programar bitstream + ejecutar ELF en la placa
    program  Cargar solo bitstream en la FPGA
    build    synth + impl + bit
    all      create + synth + impl + bit
    gui      Abrir proyecto en Vivado GUI

Ejemplos:
    python build.py P_1_blink_led create      # Crear proyecto RTL
    python build.py P_2_zynq_dma  create      # Crear proyecto Block Design
    python build.py P_1_blink_led build       # Compilar todo (sin crear)
    python build.py P_1_blink_led all         # Crear + compilar
    python build.py P_2_zynq_dma  export      # Exportar .xsa para Vitis
    python build.py P_2_zynq_dma  vitis       # Crear app Vitis desde XSA
    python build.py P_2_zynq_dma  run         # Programar + ejecutar en ZedBoard
    python build.py P_1_blink_led program     # Cargar bitstream en ZedBoard
    python build.py P_1_blink_led gui         # Abrir en Vivado GUI
    python build.py P_1_blink_led synth impl  # Pasos sueltos encadenados
"""

import subprocess
import sys
import configparser
from pathlib import Path

TCL_DIR = Path(__file__).parent / "tcl"

# Find Vivado and XSCT
_AMD_BASE = Path(r"C:\AMDDesignTools\2025.2")

_VIVADO_KNOWN = _AMD_BASE / "Vivado" / "bin" / "vivado.bat"
if _VIVADO_KNOWN.exists():
    VIVADO = str(_VIVADO_KNOWN)
else:
    import shutil
    VIVADO = shutil.which("vivado.bat") or shutil.which("vivado") or "vivado.bat"

_VITIS_KNOWN = _AMD_BASE / "Vitis" / "bin" / "vitis.bat"
if _VITIS_KNOWN.exists():
    VITIS = str(_VITIS_KNOWN)
else:
    import shutil
    VITIS = shutil.which("vitis.bat") or shutil.which("vitis") or "vitis.bat"

_XSCT_KNOWN = _AMD_BASE / "Vitis" / "bin" / "xsct.bat"
if _XSCT_KNOWN.exists():
    XSCT = str(_XSCT_KNOWN)
else:
    import shutil
    XSCT = shutil.which("xsct.bat") or shutil.which("xsct") or "xsct.bat"


def parse_config(project_dir: Path):
    cfg = configparser.ConfigParser(allow_no_value=True)
    cfg.read(project_dir / "project.cfg")

    sources = [k for k in cfg["sources"]]
    constrs = [k for k in cfg["constraints"]] if cfg.has_section("constraints") else []
    sim_top = cfg.get("simulation", "top", fallback="none")
    sim_sources = [k for k in cfg["simulation"] if k != "top"] if cfg.has_section("simulation") else []

    # Detect block design project (source is a .tcl)
    is_bd = any(s.endswith(".tcl") for s in sources)

    return {
        "name": cfg.get("project", "name"),
        "part": cfg.get("project", "part"),
        "top": cfg.get("project", "top"),
        "board": cfg.get("project", "board", fallback=""),
        "sources": sources,
        "constrs": constrs,
        "sim_top": sim_top,
        "sim_sources": sim_sources,
        "is_bd": is_bd,
    }


def run_vivado(tcl_script, args=None):
    cmd = [VIVADO, "-mode", "batch", "-source", str(tcl_script)]
    if args:
        cmd += ["-tclargs"] + [str(a) for a in args]
    print(f">> {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=str(Path(__file__).parent))
    if result.returncode != 0:
        print(f"ERROR: Vivado exited with code {result.returncode}")
        sys.exit(result.returncode)


def run_vitis(py_script, args=None):
    cmd = [VITIS, "-s", str(py_script)]
    if args:
        cmd += [str(a) for a in args]
    print(f">> {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=str(Path(__file__).parent))
    if result.returncode != 0:
        print(f"ERROR: Vitis exited with code {result.returncode}")
        sys.exit(result.returncode)


def run_xsct(tcl_script, args=None):
    cmd = [XSCT, str(tcl_script)]
    if args:
        cmd += [str(a) for a in args]
    print(f">> {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=str(Path(__file__).parent))
    if result.returncode != 0:
        print(f"ERROR: XSCT exited with code {result.returncode}")
        sys.exit(result.returncode)


def get_xpr(project_dir: Path, name: str) -> Path:
    return project_dir / "build" / f"{name}.xpr"


def cmd_create(project_dir: Path, cfg: dict):
    if cfg["is_bd"]:
        # Block Design project
        bd_tcl = cfg["sources"][0]
        args = [str(project_dir), cfg["name"], cfg["part"], bd_tcl]
        run_vivado(TCL_DIR / "create_bd_project.tcl", args)
    else:
        # RTL project
        args = [str(project_dir), cfg["name"], cfg["part"], cfg["top"]]
        args += cfg["sources"]
        args += ["-constrs"] + cfg["constrs"]
        args += ["-sim", cfg["sim_top"]] + cfg["sim_sources"]
        run_vivado(TCL_DIR / "create_project.tcl", args)


def cmd_synth(project_dir: Path, cfg: dict):
    run_vivado(TCL_DIR / "synthesize.tcl", [get_xpr(project_dir, cfg["name"])])


def cmd_impl(project_dir: Path, cfg: dict):
    run_vivado(TCL_DIR / "implement.tcl", [get_xpr(project_dir, cfg["name"])])


def cmd_bit(project_dir: Path, cfg: dict):
    run_vivado(TCL_DIR / "gen_bitstream.tcl", [get_xpr(project_dir, cfg["name"])])


def cmd_export(project_dir: Path, cfg: dict):
    xsa_file = project_dir / "build" / f"{cfg['name']}.xsa"
    run_vivado(TCL_DIR / "export_hw.tcl", [get_xpr(project_dir, cfg["name"]), xsa_file])
    print(f"XSA exportado: {xsa_file}")


def find_bitstream(project_dir: Path, cfg: dict) -> Path:
    """Find bitstream in either old or new location."""
    candidates = [
        project_dir / "build" / f"{cfg['top']}.bit",
        project_dir / "build" / f"{cfg['name']}.runs" / "impl_1" / f"{cfg['top']}.bit",
    ]
    for p in candidates:
        if p.exists():
            return p
    print(f"ERROR: Bitstream no encontrado. Buscado en:")
    for p in candidates:
        print(f"  - {p}")
    print(f"Ejecuta primero: python build.py {project_dir.name} bit")
    sys.exit(1)


def cmd_program(project_dir: Path, cfg: dict):
    bit_file = find_bitstream(project_dir, cfg)
    run_vivado(TCL_DIR / "program.tcl", [bit_file])


def cmd_vitis(project_dir: Path, cfg: dict):
    xsa_file = project_dir / "build" / f"{cfg['name']}.xsa"
    if not xsa_file.exists():
        print(f"ERROR: XSA no encontrado: {xsa_file}")
        print(f"Ejecuta primero: python build.py {project_dir.name} export")
        sys.exit(1)
    sw_dir = project_dir / "sw"
    vitis_py = sw_dir / "create_vitis.py"
    app_src = sw_dir / "dma_test.c"
    ws_dir = project_dir / "vitis_ws"
    if not vitis_py.exists():
        print(f"ERROR: No se encontro {vitis_py}")
        sys.exit(1)
    run_vitis(vitis_py, [xsa_file, ws_dir, app_src])


def cmd_run(project_dir: Path, cfg: dict):
    bit_file = find_bitstream(project_dir, cfg)
    elf_file = project_dir / "vitis_ws" / "dma_test" / "build" / "dma_test.elf"
    if not elf_file.exists():
        elf_file = project_dir / "vitis_ws" / "dma_test" / "Debug" / "dma_test.elf"
    if not elf_file.exists():
        print(f"ERROR: ELF no encontrado")
        print(f"Ejecuta primero: python build.py {project_dir.name} vitis")
        sys.exit(1)
    # Find FSBL
    fsbl_file = project_dir / "vitis_ws" / "zynq_dma_platform" / "export" / "zynq_dma_platform" / "sw" / "boot" / "fsbl.elf"
    if not fsbl_file.exists():
        print(f"ERROR: FSBL no encontrado: {fsbl_file}")
        sys.exit(1)
    run_tcl = project_dir / "sw" / "run.tcl"
    run_xsct(run_tcl, [bit_file, elf_file, fsbl_file])


def cmd_gui(project_dir: Path, cfg: dict):
    xpr = get_xpr(project_dir, cfg["name"])
    cmd = [VIVADO, str(xpr)]
    print(f">> {' '.join(cmd)}")
    subprocess.Popen(cmd, cwd=str(Path(__file__).parent))
    print("Vivado GUI launched.")


COMMANDS = {
    "create": cmd_create,
    "synth": cmd_synth,
    "impl": cmd_impl,
    "bit": cmd_bit,
    "export": cmd_export,
    "vitis": cmd_vitis,
    "run": cmd_run,
    "program": cmd_program,
    "gui": cmd_gui,
}


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    project_folder = sys.argv[1]
    steps = sys.argv[2:]

    project_dir = Path(__file__).parent / project_folder
    if not (project_dir / "project.cfg").exists():
        print(f"ERROR: No se encontro {project_dir / 'project.cfg'}")
        sys.exit(1)

    cfg = parse_config(project_dir)

    if "all" in steps:
        steps = ["create", "synth", "impl", "bit"]
    elif "build" in steps:
        steps = ["synth", "impl", "bit"]

    for step in steps:
        if step not in COMMANDS:
            print(f"ERROR: Paso desconocido '{step}'. Disponibles: {', '.join(COMMANDS)}")
            sys.exit(1)
        print(f"\n{'='*50}")
        print(f"  PASO: {step.upper()}")
        print(f"{'='*50}\n")
        COMMANDS[step](project_dir, cfg)

    print("\nDone.")


if __name__ == "__main__":
    main()
