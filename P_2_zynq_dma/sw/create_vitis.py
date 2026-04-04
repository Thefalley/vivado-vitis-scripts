"""
create_vitis.py - Crea workspace Vitis 2025.2 desde XSA
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

# If workspace exists, skip recreation
if os.path.exists(os.path.join(ws_dir, "zynq_dma_platform")):
    print("Platform already exists, skipping platform creation...")
    client = vitis.create_client(workspace=ws_dir)
    # Just rebuild the app
    app_src_dir = os.path.join(ws_dir, "dma_test", "src")
    os.makedirs(app_src_dir, exist_ok=True)
    shutil.copy2(app_src, app_src_dir)
    comp = client.get_component("dma_test")
    comp.build()
    elf_path = os.path.join(ws_dir, "dma_test", "build", "dma_test.elf")
    print(f"\n=========================================")
    print(f"  ELF: {elf_path}")
    print(f"=========================================")
    sys.exit(0)

# Create workspace
client = vitis.create_client(workspace=ws_dir)

# Create platform from XSA
print("\n[1/4] Creando platform desde XSA ...")
platform = client.create_platform_component(
    name="zynq_dma_platform",
    hw_design=xsa_path,
    os="standalone",
    cpu="ps7_cortexa9_0"
)

# Build platform
print("[2/4] Compilando platform ...")
platform.build()

# Create bare-metal app
print("[3/4] Creando app dma_test ...")
xpfm_path = os.path.join(ws_dir, "zynq_dma_platform", "export", "zynq_dma_platform", "zynq_dma_platform.xpfm")
print(f"   Platform: {xpfm_path}")
app = client.create_app_component(
    name="dma_test",
    platform=xpfm_path,
    domain="standalone_ps7_cortexa9_0",
    template="empty_application"
)

# Copy source file
app_src_dir = os.path.join(ws_dir, "dma_test", "src")
os.makedirs(app_src_dir, exist_ok=True)
shutil.copy2(app_src, app_src_dir)
print(f"   Copiado: {app_src} -> {app_src_dir}")

# Build app
print("[4/4] Compilando app ...")
app.build()

elf_path = os.path.join(ws_dir, "dma_test", "build", "dma_test.elf")
print(f"\n=========================================")
print(f"  Vitis workspace: {ws_dir}")
print(f"  ELF: {elf_path}")
print(f"=========================================")
