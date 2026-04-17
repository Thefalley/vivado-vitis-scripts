"""Test encadenado LAYER 0 -> LAYER 1 en board.
1. Carga input layer 0 + pesos
2. Ejecuta layer 0 (CONV) -> output en 0x16000000
3. Ejecuta layer 1 (LEAKY) con in_addr = 0x16000000, out_addr = 0x17000000
4. Compara cada output contra ONNX refs.
"""
import sys, os, struct, zlib, time
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from yolov4_host import DpuHost, CMD_EXEC_LAYER

REFS = r"C:/project/vivado/P_18_dpu_eth/host/onnx_refs"
BLOB = r"C:/project/vitis-ai/workspace/c_dpu/yolov4_weights.bin"

ADDR_INPUT = 0x10000000
ADDR_CFG   = 0x11000000
ADDR_W     = 0x12000000
ADDR_OUT0  = 0x16000000
ADDR_OUT1  = 0x17000000

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

# Load artifacts
blob = open(BLOB, "rb").read()
in0 = np.fromfile(os.path.join(REFS, "layer_001.bin"), dtype=np.int8).reshape(1, 3, 416, 416)
exp0 = np.fromfile(os.path.join(REFS, "layer_002.bin"), dtype=np.int8).reshape(1, 32, 416, 416)
exp1 = np.fromfile(os.path.join(REFS, "layer_003.bin"), dtype=np.int8).reshape(1, 32, 416, 416)
exp0_crc = zlib.crc32(exp0.tobytes()) & 0xFFFFFFFF
exp1_crc = zlib.crc32(exp1.tobytes()) & 0xFFFFFFFF
print(f"expected CRC layer_002 = 0x{exp0_crc:08X}")
print(f"expected CRC layer_003 = 0x{exp1_crc:08X}")

with DpuHost("192.168.1.10", timeout=60.0) as h:
    print(f"PING: {h.ping()}")
    h.dpu_init()

    t0 = time.time()
    h.write_ddr(ADDR_W, blob)
    print(f"weights 64 MB: {(time.time()-t0)*1000:.0f} ms")
    h.write_ddr(ADDR_INPUT, in0.tobytes())
    print(f"input 519 KB")

    # cfg layer 0
    cfg0 = pack_cfg(op_type=0, layer_idx=0,
        in_addr=ADDR_INPUT, out_addr=ADDR_OUT0,
        w_addr=ADDR_W, b_addr=ADDR_W + 864,
        c_in=3, c_out=32, h_in=416, w_in=416, h_out=416, w_out=416,
        kh=3, kw=3, stride_h=1, stride_w=1,
        pad_top=1, pad_bottom=1, pad_left=1, pad_right=1)
    h.write_ddr(ADDR_CFG + 0*72, cfg0)

    # cfg layer 1 (LEAKY)
    cfg1 = pack_cfg(op_type=1, layer_idx=1,
        in_addr=ADDR_OUT0, out_addr=ADDR_OUT1,
        c_in=32, c_out=32, h_in=416, w_in=416, h_out=416, w_out=416)
    h.write_ddr(ADDR_CFG + 1*72, cfg1)

    print("\n--- LAYER 0 CONV ---")
    t0 = time.time()
    status, (cy0, crc0, nb0) = exec_layer(h, 0)
    print(f"status={status:08X} cycles={cy0} out_crc=0x{crc0:08X} ({(time.time()-t0)*1000:.0f} ms)")
    print(f"  layer 0 bit-exact: {crc0 == exp0_crc}")
    if crc0 != exp0_crc:
        print("ABORT: layer 0 mismatch")
        sys.exit(1)

    print("\n--- LAYER 1 LEAKY ---")
    t0 = time.time()
    status, (cy1, crc1, nb1) = exec_layer(h, 1)
    print(f"status={status:08X} cycles={cy1} out_crc=0x{crc1:08X} ({(time.time()-t0)*1000:.0f} ms)")
    match1 = crc1 == exp1_crc
    print(f"  layer 1 bit-exact: {match1}")
    if match1:
        print("\n*** LAYER 0 + LAYER 1 BIT-EXACT vs ONNX!!! ***")
    else:
        dpu = h.read_ddr(ADDR_OUT1, nb1)
        da = np.frombuffer(dpu, dtype=np.int8)
        ea = exp1.flatten()
        diff = np.nonzero(da != ea)[0]
        print(f"{len(diff)}/{len(ea)} diff ({100*len(diff)/len(ea):.2f}%)")
        if len(diff):
            i = diff[0]
            print(f"first diff idx={i}: dpu={da[i]} exp={ea[i]}")
            print(f"dpu[:16]: {da[:16].tolist()}")
            print(f"exp[:16]: {ea[:16].tolist()}")
