"""
create_vitis.py -- Crea workspace Vitis para P_11 elem_add
Uso: vitis -s create_vitis.py <xsa_path> <workspace_dir> <app_src_c>
"""
import vitis, sys, os, shutil

xsa_path = os.path.abspath(sys.argv[1])
ws_dir   = os.path.abspath(sys.argv[2])
app_src  = os.path.abspath(sys.argv[3])

if os.path.exists(os.path.join(ws_dir, "zynq_ea_platform")):
    client = vitis.create_client(workspace=ws_dir)
    app_src_dir = os.path.join(ws_dir, "ea_test", "src")
    os.makedirs(app_src_dir, exist_ok=True)
    shutil.copy2(app_src, app_src_dir)
    client.get_component("ea_test").build()
    sys.exit(0)

client = vitis.create_client(workspace=ws_dir)
platform = client.create_platform_component(
    name="zynq_ea_platform", hw_design=xsa_path,
    os="standalone", cpu="ps7_cortexa9_0")
platform.build()

xpfm = os.path.join(ws_dir, "zynq_ea_platform", "export",
                     "zynq_ea_platform", "zynq_ea_platform.xpfm")
app = client.create_app_component(
    name="ea_test", platform=xpfm,
    domain="standalone_ps7_cortexa9_0", template="empty_application")

app_src_dir = os.path.join(ws_dir, "ea_test", "src")
os.makedirs(app_src_dir, exist_ok=True)
shutil.copy2(app_src, app_src_dir)
app.build()

print(f"ELF: {os.path.join(ws_dir, 'ea_test', 'build', 'ea_test.elf')}")
