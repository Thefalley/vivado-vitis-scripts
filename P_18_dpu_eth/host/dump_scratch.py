"""Dumpea el scratch buffer que dpu_exec_conv prepara ANTES del DMA, y lo
compara byte-a-byte con el layout esperado (el que XSIM uso y dio bit-exact).

Si coincide: el bug esta en DMA->BRAM->conv (post-scratch).
Si NO coincide: el bug es cómo dpu_exec_conv prepara el scratch.

Layout esperado (BRAM):
  0x000 : OUTPUT scratch (zeros, 512 B, aligned to 64)
  0x200 : INPUT (48 B, aligned to 64 -> 0x200 + 0x40 = 0x240 starts, but
                 OUT_OFF = 0x000 + 512 aligned to 64 = 0x200)
  TB XSIM calcula:
     OUT_OFF  = 0x000  (512 B zeros, aligned 64 -> 0x240)
     IN_OFF   = 0x240  (48 B, aligned 64 -> next is 0x280)
     W_OFF    = 0x280  (864 B, aligned 64 -> next is 0x5E0)
     B_OFF    = 0x5E0  (128 B, aligned 64 -> TOT = 0x660)
  Nota: estos offsets dependen de TOT_BYTES del RTL.

Este script lee los TOT_BYTES del ARM (suele ser ~1600) y compara contra
la reconstruccion en Python.
"""
import sys, os, struct, zlib, time
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from yolov4_host import DpuHost, CMD_EXEC_LAYER

ADDR_INPUT, ADDR_CFG, ADDR_W, ADDR_OUT = 0x10000000, 0x11000000, 0x12000000, 0x16000000
ADDR_MAILBOX = 0x10100000

LAYER_CFG_FMT = "<BBH IIIII HHHHHH BBBB BBBB BB h i i bbbb III"
def pack_cfg(**kv):
    f = dict(op_type=0, act_type=0, layer_idx=0, in_addr=0, in_b_addr=0,
             out_addr=0, w_addr=0, b_addr=0, c_in=0, c_out=0, h_in=0, w_in=0,
             h_out=0, w_out=0, kh=0, kw=0, stride_h=0, stride_w=0,
             pad_top=0, pad_bottom=0, pad_left=0, pad_right=0,
             ic_tile_size=0, post_shift=0, leaky_alpha_q=0, a_scale_m=0,
             b_scale_m=0, a_scale_s=0, b_scale_s=0, out_zp=0, out_scale_s=0,
             reserved0=0, reserved1=0, reserved2=0); f.update(kv)
    return struct.pack(LAYER_CFG_FMT, f["op_type"], f["act_type"], f["layer_idx"],
        f["in_addr"], f["in_b_addr"], f["out_addr"], f["w_addr"], f["b_addr"],
        f["c_in"], f["c_out"], f["h_in"], f["w_in"], f["h_out"], f["w_out"],
        f["kh"], f["kw"], f["stride_h"], f["stride_w"],
        f["pad_top"], f["pad_bottom"], f["pad_left"], f["pad_right"],
        f["ic_tile_size"], f["post_shift"], f["leaky_alpha_q"],
        f["a_scale_m"], f["b_scale_m"], f["a_scale_s"], f["b_scale_s"],
        f["out_zp"], f["out_scale_s"],
        f["reserved0"], f["reserved1"], f["reserved2"])

def exec_layer(h, idx):
    h.connect()
    tag = h._next_tag()
    h._send_header(CMD_EXEC_LAYER, 4, tag=tag)
    h._sendall(struct.pack("<HH", idx, 0))
    status, extra = h._expect_ack()
    return status, struct.unpack("<III", extra[:12]) if len(extra) >= 12 else (0,0,0)

VEC = r"C:/project/vivado/P_18_dpu_eth/host/xsim_vectors"
def load_hex_bytes(path):
    return bytes(int(line.strip(), 16) for line in open(path) if line.strip())

in_bytes = load_hex_bytes(os.path.join(VEC, "input_4x4x3_nchw.hex"))
w_bytes  = load_hex_bytes(os.path.join(VEC, "weights_ohwi.hex"))
b_bytes  = load_hex_bytes(os.path.join(VEC, "bias_int32.hex"))

# Reconstruir el scratch esperado como dpu_exec_conv deberia dejarlo
def align64(n): return (n + 0x3F) & ~0x3F
OUT_BYTES = 32 * 4 * 4   # 512
IN_BYTES  = 3 * 4 * 4    # 48
W_BYTES   = 32 * 3 * 3 * 3  # 864
B_BYTES   = 32 * 4       # 128
OUT_OFF = 0
IN_OFF  = align64(OUT_OFF + OUT_BYTES)   # 0x200
W_OFF   = align64(IN_OFF + IN_BYTES)     # 0x240 (48 < 64 -> align 0x240+0x40=0x280? no, 0x200+48=0x230, align64=0x240)
B_OFF   = align64(W_OFF + W_BYTES)
TOT     = align64(B_OFF + B_BYTES)
print(f"expected offsets: OUT=0x{OUT_OFF:X} IN=0x{IN_OFF:X} W=0x{W_OFF:X} B=0x{B_OFF:X} TOT={TOT}")

expected = bytearray(TOT)
expected[IN_OFF : IN_OFF + IN_BYTES] = in_bytes
expected[W_OFF  : W_OFF + W_BYTES]   = w_bytes
expected[B_OFF  : B_OFF + B_BYTES]   = b_bytes

with DpuHost("192.168.1.10", timeout=15.0) as h:
    print(f"PING: {h.ping()}")
    h.dpu_init()

    h.write_ddr(ADDR_W,              w_bytes)
    h.write_ddr(ADDR_W + 0x10000,    b_bytes)
    h.write_ddr(ADDR_INPUT,          in_bytes)

    cfg = pack_cfg(op_type=0, layer_idx=0,
        in_addr=ADDR_INPUT, out_addr=ADDR_OUT,
        w_addr=ADDR_W, b_addr=ADDR_W + 0x10000,
        c_in=3, c_out=32, h_in=4, w_in=4, h_out=4, w_out=4,
        kh=3, kw=3, stride_h=1, stride_w=1,
        pad_top=1, pad_bottom=1, pad_left=1, pad_right=1)
    h.write_ddr(ADDR_CFG + 0 * 72, cfg)

    status, (cycles, out_crc, out_bytes_ret) = exec_layer(h, 0)
    print(f"EXEC status=0x{status:08X} out_crc=0x{out_crc:08X}")

    # Now read the scratch dump from mailbox
    scratch_dump = h.read_ddr(ADDR_MAILBOX, TOT)
    print(f"Read scratch {len(scratch_dump)} B")

    # Compare
    ok = scratch_dump == bytes(expected)
    print(f"\n=== SCRATCH vs EXPECTED ===")
    print(f"  match={ok}")
    if not ok:
        sd = np.frombuffer(scratch_dump, dtype=np.uint8)
        ed = np.frombuffer(bytes(expected), dtype=np.uint8)
        diff = np.nonzero(sd != ed)[0]
        print(f"  diff={len(diff)}/{len(ed)} ({100*len(diff)/len(ed):.1f}%)")
        if len(diff):
            for region, lo, hi in [("OUT", OUT_OFF, IN_OFF),
                                   ("IN",  IN_OFF, W_OFF),
                                   ("W",   W_OFF,  B_OFF),
                                   ("BIAS",B_OFF,  TOT)]:
                d_in = diff[(diff >= lo) & (diff < hi)]
                print(f"  region {region} [0x{lo:X}..0x{hi:X}]: {len(d_in)}/{hi-lo} diff")
            i = diff[0]
            print(f"  first diff idx=0x{i:X}: got=0x{sd[i]:02X} exp=0x{ed[i]:02X}")
            print(f"  got[{i}:{i+16}]: {sd[i:i+16].tolist()}")
            print(f"  exp[{i}:{i+16}]: {ed[i:i+16].tolist()}")
