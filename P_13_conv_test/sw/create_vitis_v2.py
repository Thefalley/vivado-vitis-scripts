import vitis, sys, os, shutil
xsa_path = os.path.abspath(sys.argv[1])
ws_dir   = os.path.abspath(sys.argv[2])
app_src  = os.path.abspath(sys.argv[3])

print(f"[py] xsa_path = {xsa_path}", flush=True)
print(f"[py] ws_dir   = {ws_dir}", flush=True)
print(f"[py] app_src  = {app_src}", flush=True)

os.makedirs(ws_dir, exist_ok=True)

if os.path.exists(os.path.join(ws_dir, "zynq_conv_platform")):
    print("[py] platform already exists, reusing", flush=True)
    client = vitis.create_client(workspace=ws_dir)
    d = os.path.join(ws_dir, "conv_test", "src")
    os.makedirs(d, exist_ok=True)
    shutil.copy2(app_src, d)
    client.get_component("conv_test").build()
    sys.exit(0)

print("[py] creating client", flush=True)
client = vitis.create_client(workspace=ws_dir)

print("[py] creating platform component", flush=True)
try:
    p = client.create_platform_component(
        name="zynq_conv_platform",
        hw_design=xsa_path,
        os="standalone",
        cpu="ps7_cortexa9_0",
    )
except Exception as e:
    print(f"[py] create_platform_component raised: {type(e).__name__}: {e}", flush=True)
    print(f"[py] ws_dir contents: {os.listdir(ws_dir)}", flush=True)
    raise

print("[py] platform created, building", flush=True)
p.build()

xpfm = os.path.join(ws_dir, "zynq_conv_platform", "export", "zynq_conv_platform", "zynq_conv_platform.xpfm")
print(f"[py] xpfm = {xpfm}", flush=True)

app = client.create_app_component(name="conv_test", platform=xpfm, domain="standalone_ps7_cortexa9_0", template="empty_application")
d = os.path.join(ws_dir, "conv_test", "src")
os.makedirs(d, exist_ok=True)
shutil.copy2(app_src, d)
app.build()
print(f"ELF: {os.path.join(ws_dir, 'conv_test', 'build', 'conv_test.elf')}", flush=True)
