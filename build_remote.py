#!/usr/bin/env python3
"""
build_remote.py - Sintetiza e implementa un proyecto Vivado en un servidor remoto.

Uso:
    python build_remote.py P_1_blink_led          # build completo
    python build_remote.py P_4_zynq_adder synth   # solo hasta sintesis

Pasos que ejecuta:
    1. Sube fuentes (src/, constrs/) + scripts TCL al servidor
    2. Crea el proyecto Vivado (RTL o Block Design)
    3. Sintetiza
    4. Implementa (place & route)
    5. Genera bitstream
    6. Exporta .xsa (hardware para Vitis)
    7. Descarga bitstream + .xsa + reportes al PC local
"""

import subprocess, sys, os, configparser, glob, time

# ========================== CONFIGURACION ==========================
# Servidor remoto (Tailscale IP - cambiar si cambia)
SSH_HOST = "100.73.144.105"
SSH_USER = "jce03"
SSH_KEY  = "~/.ssh/pc-casa"

# Vivado en el servidor
VIVADO = "E:/vivado-instalado/2025.2.1/Vivado/bin/vivado.bat"

# Directorio de trabajo en el servidor
REMOTE_WORKDIR = "C:/Users/jce03/Desktop/claude/vivado-server"
# ===================================================================

# Directorio raiz del repo (donde esta este script)
REPO_DIR = os.path.dirname(os.path.abspath(__file__))
TCL_DIR  = os.path.join(REPO_DIR, "tcl")

# SSH/SCP base args
SSH_ARGS = ["-i", os.path.expanduser(SSH_KEY),
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=no",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=10"]


def ssh_cmd(cmd, timeout=600, check=True):
    """Ejecuta un comando en el servidor remoto. Devuelve stdout."""
    full = ["ssh"] + SSH_ARGS + [f"{SSH_USER}@{SSH_HOST}", cmd]
    print(f"  [SSH] {cmd}")
    r = subprocess.run(full, capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        # Filtrar basura de stderr (Board warnings etc.)
        stderr_clean = "\n".join(
            l for l in r.stderr.splitlines()
            if not any(skip in l for skip in ["Board 49-26", "m2w64-gcc", "====", "SERVIDOR", "Conectar", "claude"])
        ).strip()
        if stderr_clean:
            print(f"  [STDERR] {stderr_clean}")
        raise RuntimeError(f"SSH failed (exit {r.returncode})")
    return r.stdout.strip()


def scp_to(local_path, remote_path):
    """Copia un archivo local al servidor."""
    full = ["scp"] + SSH_ARGS + [local_path, f"{SSH_USER}@{SSH_HOST}:{remote_path}"]
    subprocess.run(full, check=True, capture_output=True, timeout=30)


def scp_from(remote_path, local_path):
    """Descarga un archivo del servidor al PC local."""
    os.makedirs(os.path.dirname(local_path) or ".", exist_ok=True)
    full = ["scp"] + SSH_ARGS + [f"{SSH_USER}@{SSH_HOST}:{remote_path}", local_path]
    r = subprocess.run(full, capture_output=True, timeout=60)
    return r.returncode == 0


def vivado_batch(tcl_script, tclargs="", timeout=1800):
    """Ejecuta un script TCL en Vivado batch mode en el servidor."""
    cmd = f'cd /d "{REMOTE_WORKDIR}" && "{VIVADO}" -mode batch -source {tcl_script}'
    if tclargs:
        cmd += f" -tclargs {tclargs}"
    print(f"\n{'='*60}")
    print(f"  VIVADO: {tcl_script}")
    print(f"{'='*60}")
    t0 = time.time()
    out = ssh_cmd(cmd, timeout=timeout)
    dt = time.time() - t0

    # Filtrar output: solo lineas relevantes (ignorar Board warnings)
    n_warnings = 0
    has_error = False
    for line in out.splitlines():
        stripped = line.strip()
        if "Board 49-26" in stripped:
            continue
        if "WARNING:" in stripped:
            n_warnings += 1
            continue
        if stripped.startswith("#"):
            continue
        if "ERROR:" in stripped or ("failed" in stripped.lower() and "0 errors" not in stripped.lower()):
            has_error = True
            print(f"  ** {stripped}")
        elif any(k in stripped for k in ["OK:", "Complete!", "Synth Design complete",
                                          "route_design completed", "write_bitstream",
                                          "WNS=", "Exporting hardware"]):
            print(f"  {stripped}")

    status = f"  {dt:.0f}s"
    if n_warnings > 0:
        status += f" ({n_warnings} warnings)"
    print(status)

    if has_error:
        print("\n  === BUILD FALLIDO ===")
        # Mostrar las ultimas 20 lineas para debug
        for line in out.splitlines()[-20:]:
            print(f"  {line.rstrip()}")
        sys.exit(1)
    return out


def parse_project_cfg(project_dir):
    """Parsea project.cfg y devuelve un dict con la configuracion."""
    cfg_path = os.path.join(project_dir, "project.cfg")
    cfg = configparser.ConfigParser(allow_no_value=True)
    cfg.read(cfg_path)

    info = {
        "name": cfg.get("project", "name"),
        "part": cfg.get("project", "part"),
        "top":  cfg.get("project", "top"),
    }

    # Sources: las keys de la seccion (configparser sin valor)
    info["sources"] = [k for k in cfg["sources"] if k.strip()]

    # Constraints
    info["constrs"] = [k for k in cfg["constraints"] if k.strip()] if "constraints" in cfg else []

    # Detectar si es Block Design (fuente es un .tcl)
    info["is_bd"] = any(s.endswith(".tcl") for s in info["sources"])

    return info


def upload_project(project_dir, project_name, remote_project):
    """Sube los archivos del proyecto al servidor."""
    print(f"\n--- Subiendo {project_name} al servidor ---")

    # Crear directorios remotos
    ssh_cmd(f'powershell -Command "New-Item -ItemType Directory -Force -Path '
            f"'{remote_project}/src','{remote_project}/constrs'\"")

    # Subir todos los archivos de src/
    src_dir = os.path.join(project_dir, "src")
    if os.path.isdir(src_dir):
        for f in os.listdir(src_dir):
            local = os.path.join(src_dir, f)
            if os.path.isfile(local):
                scp_to(local, f"{remote_project}/src/")
                print(f"    src/{f}")

    # Subir constraints
    constrs_dir = os.path.join(project_dir, "constrs")
    if os.path.isdir(constrs_dir):
        for f in os.listdir(constrs_dir):
            local = os.path.join(constrs_dir, f)
            if os.path.isfile(local):
                scp_to(local, f"{remote_project}/constrs/")
                print(f"    constrs/{f}")

    # Subir project.cfg
    scp_to(os.path.join(project_dir, "project.cfg"), f"{remote_project}/")
    print(f"    project.cfg")


def upload_tcl_scripts():
    """Sube los scripts TCL de build al servidor."""
    print(f"\n--- Subiendo scripts TCL ---")
    remote_tcl = f"{REMOTE_WORKDIR}/tcl"
    ssh_cmd(f'powershell -Command "New-Item -ItemType Directory -Force -Path \'{remote_tcl}\'"')
    for tcl_file in glob.glob(os.path.join(TCL_DIR, "*.tcl")):
        scp_to(tcl_file, f"{remote_tcl}/")
        print(f"    tcl/{os.path.basename(tcl_file)}")


def download_results(project_name, cfg_name, local_output_dir):
    """Descarga bitstream, XSA y reportes del servidor."""
    print(f"\n--- Descargando resultados ---")
    os.makedirs(local_output_dir, exist_ok=True)

    remote_build = f"{REMOTE_WORKDIR}/{project_name}/build"
    impl_dir = f"{remote_build}/{cfg_name}.runs/impl_1"

    results = {
        "bitstream": (f"{impl_dir}/{cfg_name}.bit",
                      os.path.join(local_output_dir, f"{cfg_name}.bit")),
        "xsa":       (f"{remote_build}/{cfg_name}.xsa",
                      os.path.join(local_output_dir, f"{cfg_name}.xsa")),
        "timing":    (f"{impl_dir}/{cfg_name}_timing_summary_routed.rpt",
                      os.path.join(local_output_dir, f"{cfg_name}_timing.rpt")),
        "util":      (f"{impl_dir}/{cfg_name}_utilization_placed.rpt",
                      os.path.join(local_output_dir, f"{cfg_name}_utilization.rpt")),
        "power":     (f"{impl_dir}/{cfg_name}_power_routed.rpt",
                      os.path.join(local_output_dir, f"{cfg_name}_power.rpt")),
    }

    for name, (remote, local) in results.items():
        if scp_from(remote, local):
            size = os.path.getsize(local)
            print(f"    {name}: {os.path.basename(local)} ({size:,} bytes)")
        else:
            print(f"    {name}: no encontrado (puede ser normal)")


def clean_remote(remote_project):
    """Limpia el directorio del proyecto en el servidor antes de compilar."""
    ssh_cmd(f'powershell -Command "if (Test-Path \'{remote_project}/build\') '
            f'{{ Remove-Item -Recurse -Force \'{remote_project}/build\' }}"')


def main():
    if len(sys.argv) < 2:
        print("Uso: python build_remote.py <proyecto> [synth|impl|bit|all]")
        print("  Ejemplos:")
        print("    python build_remote.py P_1_blink_led")
        print("    python build_remote.py P_4_zynq_adder synth")
        sys.exit(1)

    project_name = sys.argv[1].rstrip("/\\")
    stop_after   = sys.argv[2] if len(sys.argv) > 2 else "all"

    project_dir = os.path.join(REPO_DIR, project_name)
    if not os.path.isdir(project_dir):
        print(f"Error: no existe el directorio '{project_dir}'")
        sys.exit(1)

    # Parsear configuracion
    cfg = parse_project_cfg(project_dir)
    cfg_name = cfg["name"]
    remote_project = f"{REMOTE_WORKDIR}/{project_name}"

    print(f"Proyecto:  {project_name} ({cfg_name})")
    print(f"FPGA:      {cfg['part']}")
    print(f"Top:       {cfg['top']}")
    print(f"Tipo:      {'Block Design' if cfg['is_bd'] else 'RTL'}")
    print(f"Servidor:  {SSH_USER}@{SSH_HOST}")
    print(f"Hasta:     {stop_after}")

    t_total = time.time()

    # 1. Limpiar build anterior en el servidor
    clean_remote(remote_project)

    # 2. Subir archivos
    upload_project(project_dir, project_name, remote_project)
    upload_tcl_scripts()

    # 3. Crear proyecto
    xpr = f"{project_name}/build/{cfg_name}.xpr"
    if cfg["is_bd"]:
        bd_tcl = [s for s in cfg["sources"] if s.endswith(".tcl")][0]
        vivado_batch("tcl/create_bd_project.tcl",
                     f"{project_name} {cfg_name} {cfg['part']} {bd_tcl}")
    else:
        args = f"{project_name} {cfg_name} {cfg['part']} {cfg['top']}"
        for src in cfg["sources"]:
            args += f" {src}"
        if cfg["constrs"]:
            args += " -constrs"
            for xdc in cfg["constrs"]:
                args += f" {xdc}"
        vivado_batch("tcl/create_project.tcl", args)

    if stop_after == "project":
        print(f"\nParado despues de crear proyecto ({time.time()-t_total:.0f}s total)")
        return

    # 4. Sintesis
    vivado_batch("tcl/synthesize.tcl", xpr)

    if stop_after == "synth":
        print(f"\nParado despues de sintesis ({time.time()-t_total:.0f}s total)")
        return

    # 5. Implementacion
    vivado_batch("tcl/implement.tcl", xpr)

    if stop_after == "impl":
        print(f"\nParado despues de implementacion ({time.time()-t_total:.0f}s total)")
        return

    # 6. Bitstream
    vivado_batch("tcl/gen_bitstream.tcl", xpr)

    if stop_after == "bit":
        print(f"\nParado despues de bitstream ({time.time()-t_total:.0f}s total)")
        return

    # 7. Export XSA
    xsa_path = f"{project_name}/build/{cfg_name}.xsa"
    vivado_batch("tcl/export_hw.tcl", f"{xpr} {xsa_path}")

    # 8. Descargar resultados
    output_dir = os.path.join(project_dir, "remote_output")
    download_results(project_name, cfg_name, output_dir)

    dt = time.time() - t_total
    print(f"\n{'='*60}")
    print(f"  BUILD REMOTO COMPLETADO en {dt:.0f}s")
    print(f"  Resultados en: {output_dir}")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
