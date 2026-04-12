"""
create_vitis.py - Crea workspace Vitis para P_200 irq_test
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

# If platform already exists, just rebuild app
if os.path.exists(os.path.join(ws_dir, "irq_test_platform")):
    print("Platform already exists, rebuilding app...")
    client = vitis.create_client(workspace=ws_dir)
    app_src_dir = os.path.join(ws_dir, "irq_test_app", "src")
    os.makedirs(app_src_dir, exist_ok=True)
    shutil.copy2(app_src, app_src_dir)
    comp = client.get_component("irq_test_app")
    comp.build()
    elf_path = os.path.join(ws_dir, "irq_test_app", "build", "irq_test_app.elf")
    print(f"\n  ELF: {elf_path}")
    sys.exit(0)

# Create workspace
client = vitis.create_client(workspace=ws_dir)

# Create platform
print("\n[1/4] Creando platform ...")
platform = client.create_platform_component(
    name="irq_test_platform",
    hw_design=xsa_path,
    os="standalone",
    cpu="ps7_cortexa9_0"
)

print("[2/4] Compilando platform ...")
platform.build()

# Create app
print("[3/4] Creando app irq_test_app ...")
xpfm_path = os.path.join(ws_dir, "irq_test_platform", "export",
                          "irq_test_platform", "irq_test_platform.xpfm")
app = client.create_app_component(
    name="irq_test_app",
    platform=xpfm_path,
    domain="standalone_ps7_cortexa9_0",
    template="empty_application"
)

# Copy source
app_src_dir = os.path.join(ws_dir, "irq_test_app", "src")
os.makedirs(app_src_dir, exist_ok=True)
shutil.copy2(app_src, app_src_dir)

print("[4/4] Compilando app ...")
app.build()

elf_path = os.path.join(ws_dir, "irq_test_app", "build", "irq_test_app.elf")
print(f"\n=========================================")
print(f"  Vitis workspace: {ws_dir}")
print(f"  ELF: {elf_path}")
print(f"=========================================")
