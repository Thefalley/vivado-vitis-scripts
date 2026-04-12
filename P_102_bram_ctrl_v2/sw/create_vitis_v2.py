"""
create_vitis_v2.py - Crea workspace Vitis para P_102 bram_ctrl_v2
More robust: builds platform, then tries to build app in separate step.
Uso: vitis -s create_vitis_v2.py <xsa_path> <workspace_dir> <app_src_c>
"""
import vitis
import sys
import os
import shutil
import glob
import time

xsa_path = os.path.abspath(sys.argv[1])
ws_dir   = os.path.abspath(sys.argv[2])
app_src  = os.path.abspath(sys.argv[3])

print(f"XSA:       {xsa_path}")
print(f"Workspace: {ws_dir}")
print(f"App src:   {app_src}")

plat_name = "bram_ctrl_v2_platform"
app_name  = "bram_ctrl_v2_test"

# Create workspace
client = vitis.create_client(workspace=ws_dir)

# Check if platform exists
plat_dir = os.path.join(ws_dir, plat_name)
xpfm_path = os.path.join(plat_dir, "export", plat_name, f"{plat_name}.xpfm")

if not os.path.exists(xpfm_path):
    print("\n[1/4] Creando platform ...")
    try:
        platform = client.create_platform_component(
            name=plat_name,
            hw_design=xsa_path,
            os="standalone",
            cpu="ps7_cortexa9_0"
        )
    except:
        # Platform component might already exist from failed run
        platform = client.get_component(plat_name)

    print("[2/4] Compilando platform ...")
    try:
        platform.build()
    except Exception as e:
        print(f"  Platform build returned error: {e}")
        print("  Checking if platform was actually built...")

    # Check if xpfm exists now
    if not os.path.exists(xpfm_path):
        # Try to find it
        found = glob.glob(os.path.join(plat_dir, "export", "**", "*.xpfm"), recursive=True)
        if found:
            xpfm_path = found[0]
            print(f"  Found xpfm at: {xpfm_path}")
        else:
            print("  ERROR: Platform xpfm not found after build")
            print("  Contents of export dir:")
            for root, dirs, files in os.walk(os.path.join(plat_dir, "export")):
                for f in files:
                    print(f"    {os.path.join(root, f)}")
            sys.exit(1)
else:
    print("Platform already exists, skipping build...")

print(f"  XPFM: {xpfm_path}")

# Create app
print(f"[3/4] Creando app {app_name} ...")

app_dir = os.path.join(ws_dir, app_name)
if os.path.exists(app_dir):
    # App already exists, just copy source and rebuild
    app_src_dir = os.path.join(app_dir, "src")
    os.makedirs(app_src_dir, exist_ok=True)
    # Remove old .c files
    for f in glob.glob(os.path.join(app_src_dir, "*.c")):
        os.remove(f)
    shutil.copy2(app_src, app_src_dir)
    comp = client.get_component(app_name)
else:
    comp = client.create_app_component(
        name=app_name,
        platform=xpfm_path,
        domain="standalone_ps7_cortexa9_0",
        template="empty_application"
    )
    # Copy source
    app_src_dir = os.path.join(app_dir, "src")
    os.makedirs(app_src_dir, exist_ok=True)
    shutil.copy2(app_src, app_src_dir)

print("[4/4] Compilando app ...")
comp.build()

elf_path = os.path.join(app_dir, "build", f"{app_name}.elf")
print(f"\n=========================================")
print(f"  Vitis workspace: {ws_dir}")
print(f"  ELF: {elf_path}")
print(f"=========================================")
