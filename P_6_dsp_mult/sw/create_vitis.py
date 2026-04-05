"""
create_vitis.py - Crea workspace Vitis para P_6 zynq_mult
Uso: vitis -s create_vitis.py <xsa_path> <workspace_dir> <app_src_c>
"""
import vitis
import sys
import os
import shutil

xsa_path = os.path.abspath(sys.argv[1])
ws_dir   = os.path.abspath(sys.argv[2])
app_src  = os.path.abspath(sys.argv[3])

print(f"XSA:       {xsa_path}")
print(f"Workspace: {ws_dir}")
print(f"App src:   {app_src}")

if os.path.exists(os.path.join(ws_dir, "zynq_mult_platform")):
    print("Platform already exists, rebuilding app...")
    client = vitis.create_client(workspace=ws_dir)
    app_src_dir = os.path.join(ws_dir, "mult_test", "src")
    os.makedirs(app_src_dir, exist_ok=True)
    shutil.copy2(app_src, app_src_dir)
    comp = client.get_component("mult_test")
    comp.build()
    elf_path = os.path.join(ws_dir, "mult_test", "build", "mult_test.elf")
    print(f"\n  ELF: {elf_path}")
    sys.exit(0)

client = vitis.create_client(workspace=ws_dir)

print("\n[1/4] Creando platform ...")
platform = client.create_platform_component(
    name="zynq_mult_platform",
    hw_design=xsa_path,
    os="standalone",
    cpu="ps7_cortexa9_0"
)

print("[2/4] Compilando platform ...")
platform.build()

print("[3/4] Creando app mult_test ...")
xpfm_path = os.path.join(ws_dir, "zynq_mult_platform", "export",
                          "zynq_mult_platform", "zynq_mult_platform.xpfm")
app = client.create_app_component(
    name="mult_test",
    platform=xpfm_path,
    domain="standalone_ps7_cortexa9_0",
    template="empty_application"
)

app_src_dir = os.path.join(ws_dir, "mult_test", "src")
os.makedirs(app_src_dir, exist_ok=True)
shutil.copy2(app_src, app_src_dir)

print("[4/4] Compilando app ...")
app.build()

elf_path = os.path.join(ws_dir, "mult_test", "build", "mult_test.elf")
print(f"\n=========================================")
print(f"  Vitis workspace: {ws_dir}")
print(f"  ELF: {elf_path}")
print(f"=========================================")
