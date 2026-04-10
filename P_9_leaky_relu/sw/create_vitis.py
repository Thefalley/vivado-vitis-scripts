"""
create_vitis.py — Crea workspace Vitis para P_9 leaky_relu
Uso: vitis -s create_vitis.py <xsa_path> <workspace_dir> <app_src_c>
"""
import vitis, sys, os, shutil

xsa_path = os.path.abspath(sys.argv[1])
ws_dir   = os.path.abspath(sys.argv[2])
app_src  = os.path.abspath(sys.argv[3])

if os.path.exists(os.path.join(ws_dir, "zynq_lr_platform")):
    client = vitis.create_client(workspace=ws_dir)
    app_src_dir = os.path.join(ws_dir, "lr_test", "src")
    os.makedirs(app_src_dir, exist_ok=True)
    shutil.copy2(app_src, app_src_dir)
    client.get_component("lr_test").build()
    sys.exit(0)

client = vitis.create_client(workspace=ws_dir)
platform = client.create_platform_component(
    name="zynq_lr_platform", hw_design=xsa_path,
    os="standalone", cpu="ps7_cortexa9_0")
platform.build()

xpfm = os.path.join(ws_dir, "zynq_lr_platform", "export",
                     "zynq_lr_platform", "zynq_lr_platform.xpfm")
app = client.create_app_component(
    name="lr_test", platform=xpfm,
    domain="standalone_ps7_cortexa9_0", template="empty_application")

app_src_dir = os.path.join(ws_dir, "lr_test", "src")
os.makedirs(app_src_dir, exist_ok=True)
shutil.copy2(app_src, app_src_dir)
app.build()

print(f"ELF: {os.path.join(ws_dir, 'lr_test', 'build', 'lr_test.elf')}")
