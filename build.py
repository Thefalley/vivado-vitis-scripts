"""
build.py - Vivado build automation
Uso:
    python build.py <proyecto> <comando>

Comandos:
    create   Crear proyecto Vivado desde project.cfg
    synth    Sintetizar
    impl     Implementar (place & route)
    bit      Generar bitstream
    program  Cargar bitstream en la FPGA
    build    synth + impl + bit
    all      create + synth + impl + bit
    gui      Abrir proyecto en Vivado GUI

Ejemplos:
    python build.py P_1_blink_led create     # Solo crear proyecto
    python build.py P_1_blink_led build      # Compilar todo (sin crear)
    python build.py P_1_blink_led all        # Crear + compilar
    python build.py P_1_blink_led program    # Cargar bitstream en ZedBoard
    python build.py P_1_blink_led gui        # Abrir en Vivado GUI
    python build.py P_1_blink_led synth impl # Pasos sueltos encadenados
"""

import subprocess
import sys
import configparser
from pathlib import Path

VIVADO = "vivado.bat"
TCL_DIR = Path(__file__).parent / "tcl"


def parse_config(project_dir: Path):
    cfg = configparser.ConfigParser(allow_no_value=True)
    cfg.read(project_dir / "project.cfg")

    sources = [k for k in cfg["sources"]]
    constrs = [k for k in cfg["constraints"]]
    sim_top = cfg.get("simulation", "top")
    sim_sources = [k for k in cfg["simulation"] if k != "top"]

    return {
        "name": cfg.get("project", "name"),
        "part": cfg.get("project", "part"),
        "top": cfg.get("project", "top"),
        "sources": sources,
        "constrs": constrs,
        "sim_top": sim_top,
        "sim_sources": sim_sources,
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


def get_xpr(project_dir: Path, name: str) -> Path:
    return project_dir / "build" / f"{name}.xpr"


def cmd_create(project_dir: Path, cfg: dict):
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


def cmd_program(project_dir: Path, cfg: dict):
    bit_file = project_dir / "build" / f"{cfg['name']}.runs" / "impl_1" / f"{cfg['top']}.bit"
    if not bit_file.exists():
        print(f"ERROR: Bitstream no encontrado: {bit_file}")
        print("Ejecuta primero: python build.py {project_dir.name} bit")
        sys.exit(1)
    run_vivado(TCL_DIR / "program.tcl", [bit_file])


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
