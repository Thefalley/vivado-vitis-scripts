"""
build_crop.py -- Build conv_crop_test.c using existing Vitis workspace.

Usage (from Vitis 2025.2 shell):
  vitis -s build_crop.py

Or from command line:
  C:/AMDDesignTools/2025.2/Vitis/bin/vitis.bat -s C:/project/vivado/P_13_conv_test/sw/build_crop.py

What it does:
  1. Points to the existing workspace at P_13_conv_test/vitis_ws
  2. Copies conv_crop_test.c to the app src dir (alongside conv_test.c)
  3. Removes conv_test.c from compilation (renames it)
  4. Builds the app
  5. Restores conv_test.c

The resulting ELF: vitis_ws/conv_test/build/conv_test.elf
(same name, but with crop test code)
"""
import vitis
import os
import shutil
import sys

SW_DIR = os.path.dirname(os.path.abspath(__file__))
WS_DIR = os.path.join(os.path.dirname(SW_DIR), "vitis_ws")
SRC_DIR = os.path.join(WS_DIR, "conv_test", "src")
CROP_SRC = os.path.join(SW_DIR, "conv_crop_test.c")
ORIG_SRC = os.path.join(SRC_DIR, "conv_test.c")
BACKUP = ORIG_SRC + ".bak"

print(f"[build_crop] WS_DIR  = {WS_DIR}", flush=True)
print(f"[build_crop] SRC_DIR = {SRC_DIR}", flush=True)
print(f"[build_crop] CROP_SRC = {CROP_SRC}", flush=True)

# Backup original
if os.path.exists(ORIG_SRC):
    shutil.copy2(ORIG_SRC, BACKUP)
    print(f"[build_crop] Backed up conv_test.c -> conv_test.c.bak", flush=True)

# Copy crop test as the main source
shutil.copy2(CROP_SRC, os.path.join(SRC_DIR, "conv_test.c"))
print(f"[build_crop] Copied conv_crop_test.c -> conv_test.c", flush=True)

# Build
client = vitis.create_client(workspace=WS_DIR)
comp = client.get_component("conv_test")
comp.build()

# Restore original
if os.path.exists(BACKUP):
    shutil.copy2(BACKUP, ORIG_SRC)
    os.remove(BACKUP)
    print(f"[build_crop] Restored original conv_test.c", flush=True)

elf_path = os.path.join(WS_DIR, "conv_test", "build", "conv_test.elf")
print(f"[build_crop] ELF: {elf_path}", flush=True)
print(f"[build_crop] ELF exists: {os.path.exists(elf_path)}", flush=True)
