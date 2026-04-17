"""Test LAYER 1 del firmware: LeakyRelu tras la primera conv.
Input  = layer_002.bin (salida verificada bit-exact de LAYER 0) NCHW 32x416x416.
Output = layer_003.bin esperada.

Si bit-exact -> dpu_exec_leaky tambien esta OK. Si diverge, el runtime de
leaky tiene bug (caches o algo analogo al fixeado en conv).
"""
import sys, os, struct, zlib, time
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from yolov4_host import DpuHost, CMD_EXEC_LAYER

REFS = r"C:/project/vivado/P_18_dpu_eth/host/onnx_refs"
LAYER_IN  = os.path.join(REFS, "layer_002.bin")   # (1,32,416,416) int8
LAYER_OUT = os.path.join(REFS, "layer_003.bin")   # (1,32,416,416) int8

ADDR_IN, ADDR_OUT, ADDR_CFG = 0x10000000, 0x16000000, 0x11000000
LAYER_CFG_FMT = "<BBH IIIII HHHHHH BBBB BBBB BB h i i bbbb III"
PRO_OP_LEAKY = 1

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

# Load tensors
inp = np.fromfile(LAYER_IN, dtype=np.int8).reshape(1, 32, 416, 416)
exp = np.fromfile(LAYER_OUT, dtype=np.int8).reshape(1, 32, 416, 416)
in_bytes = inp.tobytes()
exp_bytes = exp.tobytes()
exp_crc = zlib.crc32(exp_bytes) & 0xFFFFFFFF
print(f"input crc  = 0x{zlib.crc32(in_bytes)&0xFFFFFFFF:08X}  size={len(in_bytes)}")
print(f"expect crc = 0x{exp_crc:08X}")

with DpuHost("192.168.1.10", timeout=30.0) as h:
    print(f"PING: {h.ping()}")
    h.dpu_init()

    t0 = time.time()
    h.write_ddr(ADDR_IN, in_bytes)
    print(f"write input {len(in_bytes)/1e6:.1f} MB: {(time.time()-t0)*1000:.0f} ms")

    # cfg layer 1 (LEAKY). No c_in/c_out mismatch: c_out = c_in = 32.
    cfg = pack_cfg(op_type=PRO_OP_LEAKY, layer_idx=1,
                   in_addr=ADDR_IN, out_addr=ADDR_OUT,
                   c_in=32, c_out=32, h_in=416, w_in=416, h_out=416, w_out=416)
    h.write_ddr(ADDR_CFG + 1 * 72, cfg)

    t0 = time.time()
    status, (cycles, out_crc, out_bytes_ret) = exec_layer(h, 1)
    dt = time.time() - t0
    print(f"EXEC status=0x{status:08X} cycles={cycles} out_crc=0x{out_crc:08X} out_bytes={out_bytes_ret} ({dt*1000:.0f} ms)")

    if status != 0:
        print(f"status error")
        sys.exit(1)

    match = out_crc == exp_crc
    print(f"Expected=0x{exp_crc:08X}  match={match}")
    if match:
        print("\n*** LAYER 1 (LEAKY) BIT-EXACT! ***")
    else:
        dpu = h.read_ddr(ADDR_OUT, out_bytes_ret)
        da = np.frombuffer(dpu, dtype=np.int8)
        ea = np.frombuffer(exp_bytes, dtype=np.int8)
        diff = np.nonzero(da != ea)[0]
        print(f"{len(diff)}/{len(ea)} diff ({100*len(diff)/len(ea):.2f}%)")
        if len(diff):
            i = diff[0]
            print(f"first diff idx={i}: dpu={da[i]} exp={ea[i]}")
            print(f"dpu[0:16]: {da[:16].tolist()}")
            print(f"exp[0:16]: {ea[:16].tolist()}")
