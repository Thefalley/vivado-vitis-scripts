"""Test 4x4 del layer 0 en board real (sin tiling H+W del ARM).
El RTL ya es bit-exact en XSIM. Ahora verificamos el wrapper y el dispatch
del ARM sin la complicacion del tiling.
"""
import sys, os, struct, zlib, time
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from yolov4_host import DpuHost, CMD_EXEC_LAYER

ADDR_INPUT, ADDR_CFG, ADDR_W, ADDR_OUT = 0x10000000, 0x11000000, 0x12000000, 0x16000000
LAYER_CFG_FMT = "<BBH IIIII HHHHHH BBBB BBBB BB h i i bbbb III"
assert struct.calcsize(LAYER_CFG_FMT) == 72

def pack_cfg(**kv):
    f = dict(op_type=0, act_type=0, layer_idx=0, in_addr=0, in_b_addr=0,
             out_addr=0, w_addr=0, b_addr=0, c_in=0, c_out=0, h_in=0, w_in=0,
             h_out=0, w_out=0, kh=0, kw=0, stride_h=0, stride_w=0,
             pad_top=0, pad_bottom=0, pad_left=0, pad_right=0,
             ic_tile_size=0, post_shift=0, leaky_alpha_q=0, a_scale_m=0,
             b_scale_m=0, a_scale_s=0, b_scale_s=0, out_zp=0, out_scale_s=0,
             reserved0=0, reserved1=0, reserved2=0)
    f.update(kv)
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
    if len(extra) >= 12:
        cycles, crc, nb = struct.unpack("<III", extra[:12])
        return status, cycles, crc, nb
    return status, 0, 0, 0

# Load vectors (same as XSIM used)
VEC = r"C:/project/vivado/P_18_dpu_eth/host/xsim_vectors"
def load_hex_bytes(path):
    with open(path) as f:
        return bytes(int(line.strip(), 16) for line in f if line.strip())

in_bytes = load_hex_bytes(os.path.join(VEC, "input_4x4x3_nchw.hex"))
w_bytes  = load_hex_bytes(os.path.join(VEC, "weights_ohwi.hex"))
b_bytes  = load_hex_bytes(os.path.join(VEC, "bias_int32.hex"))
exp      = load_hex_bytes(os.path.join(VEC, "expected_out_nchw.hex"))
print(f"in={len(in_bytes)} w={len(w_bytes)} b={len(b_bytes)} exp={len(exp)}")

with DpuHost("192.168.1.10", timeout=15.0) as h:
    print(f"PING: {h.ping()}")
    h.dpu_init()

    t0 = time.time()
    h.write_ddr(ADDR_W,              w_bytes)
    h.write_ddr(ADDR_W + 0x10000,    b_bytes)   # bias offset 64KB
    h.write_ddr(ADDR_INPUT,          in_bytes)
    print(f"writes done in {(time.time()-t0)*1000:.0f} ms")

    # cfg: layer 0 CONV override 4x4
    cfg = pack_cfg(
        op_type=0, layer_idx=0,
        in_addr=ADDR_INPUT, out_addr=ADDR_OUT,
        w_addr=ADDR_W, b_addr=ADDR_W + 0x10000,
        c_in=3, c_out=32, h_in=4, w_in=4, h_out=4, w_out=4,
        kh=3, kw=3, stride_h=1, stride_w=1,
        pad_top=1, pad_bottom=1, pad_left=1, pad_right=1,
    )
    h.write_ddr(ADDR_CFG + 0 * 72, cfg)

    t0 = time.time()
    status, cycles, out_crc, out_bytes = exec_layer(h, 0)
    print(f"EXEC status=0x{status:08X} cycles={cycles} out_crc=0x{out_crc:08X} out_bytes={out_bytes} ({(time.time()-t0)*1000:.0f} ms)")

    if status != 0:
        print(f"Status error 0x{status:08X}")
        import sys; sys.exit(1)

    exp_crc = zlib.crc32(exp) & 0xFFFFFFFF
    print(f"Expected crc=0x{exp_crc:08X}  match={out_crc == exp_crc}")
    if out_crc == exp_crc:
        print("\n*** BIT-EXACT 4x4 on board!!! ***")
    else:
        dpu = h.read_ddr(ADDR_OUT, out_bytes)
        assert len(dpu) == len(exp)
        da = np.frombuffer(dpu, dtype=np.int8)
        ea = np.frombuffer(exp, dtype=np.int8)
        diff_idx = np.nonzero(da != ea)[0]
        print(f"{len(diff_idx)}/{len(ea)} bytes diff ({100*len(diff_idx)/len(ea):.2f}%)")
        if len(diff_idx):
            i = diff_idx[0]
            print(f"first diff idx={i}: dpu={da[i]} exp={ea[i]}")
            print(f"dpu[0:8]: {da[:8].tolist()}")
            print(f"exp[0:8]: {ea[:8].tolist()}")
