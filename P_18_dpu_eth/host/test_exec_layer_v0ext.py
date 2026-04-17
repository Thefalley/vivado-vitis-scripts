"""Test del V0-extendido: write_raw + EXEC_LAYER real.

El server C ahora implementa CMD_EXEC_LAYER leyendo layer_cfg_t de DDR.
Workflow:
  1. PC pone layer_cfg_t en DDR @ ADDR_CFG_ARRAY + idx*72 con write_raw
  2. PC pone input en cfg.in_addr
  3. PC manda CMD_EXEC_LAYER(layer_idx, flags=0)
  4. ARM lee cfg de DDR, ejecuta (stub: zeros o RESIZE/CONCAT ARM), calcula CRC
  5. ARM responde ACK{status, cycles, out_crc, out_bytes}
  6. PC compara out_crc con ONNX reference
"""
import os
import struct
import sys
import time
import zlib

sys.path.insert(0, os.path.dirname(__file__))
from yolov4_host import DpuHost, CMD_EXEC_LAYER

# Constantes del eth_protocol.h (V0 extended)
ADDR_CFG_ARRAY = 0x11000000
LAYER_CFG_SIZE = 72

LAYER_CFG_FMT = (
    "<BBH IIIII HHHHHH BBBB BBBB BB h i i bbbb III"
)
assert struct.calcsize(LAYER_CFG_FMT) == 72

PRO_OP_CONV      = 0
PRO_OP_LEAKY     = 1
PRO_OP_POOL_MAX  = 2
PRO_OP_ELEM_ADD  = 3
PRO_OP_CONCAT    = 4
PRO_OP_RESIZE    = 5


def pack_cfg(**kv):
    fields = dict(
        op_type=0, act_type=0, layer_idx=0,
        in_addr=0, in_b_addr=0, out_addr=0, w_addr=0, b_addr=0,
        c_in=0, c_out=0, h_in=0, w_in=0, h_out=0, w_out=0,
        kh=0, kw=0, stride_h=0, stride_w=0,
        pad_top=0, pad_bottom=0, pad_left=0, pad_right=0,
        ic_tile_size=0, post_shift=0, leaky_alpha_q=0,
        a_scale_m=0, b_scale_m=0,
        a_scale_s=0, b_scale_s=0, out_zp=0, out_scale_s=0,
        reserved0=0, reserved1=0, reserved2=0,
    )
    fields.update(kv)
    return struct.pack(LAYER_CFG_FMT,
        fields["op_type"], fields["act_type"], fields["layer_idx"],
        fields["in_addr"], fields["in_b_addr"], fields["out_addr"],
        fields["w_addr"], fields["b_addr"],
        fields["c_in"], fields["c_out"],
        fields["h_in"], fields["w_in"], fields["h_out"], fields["w_out"],
        fields["kh"], fields["kw"],
        fields["stride_h"], fields["stride_w"],
        fields["pad_top"], fields["pad_bottom"],
        fields["pad_left"], fields["pad_right"],
        fields["ic_tile_size"], fields["post_shift"],
        fields["leaky_alpha_q"],
        fields["a_scale_m"], fields["b_scale_m"],
        fields["a_scale_s"], fields["b_scale_s"],
        fields["out_zp"], fields["out_scale_s"],
        fields["reserved0"], fields["reserved1"], fields["reserved2"],
    )


def exec_layer_v0ext(h: DpuHost, layer_idx: int):
    """Manda CMD_EXEC_LAYER con payload nuevo (u16 idx + u16 flags)."""
    h.connect()
    payload = struct.pack("<HH", layer_idx, 0)
    tag = h._next_tag()
    h._send_header(CMD_EXEC_LAYER, len(payload), tag=tag)
    h._sendall(payload)
    status, extra = h._expect_ack()
    if len(extra) >= 12:
        cycles, out_crc, out_bytes = struct.unpack("<III", extra[:12])
        return status, cycles, out_crc, out_bytes
    return status, 0, 0, 0


def crc32(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def main():
    print("=== V0-extended test ===")
    with DpuHost("192.168.1.10", timeout=20.0) as h:
        print(f"PING: {h.ping()}")

        # Test 1: CONV (stub zeros). in_addr arbitrary, out_addr = ACTIV_POOL.
        print("\n--- Test 1: CONV (stub zeros) ---")
        cfg = pack_cfg(
            op_type=PRO_OP_CONV, layer_idx=0,
            in_addr=0x10000000, out_addr=0x16000000,
            c_in=3, c_out=32, h_in=416, w_in=416, h_out=416, w_out=416,
            kh=3, kw=3, stride_h=1, stride_w=1,
            pad_top=1, pad_bottom=1, pad_left=1, pad_right=1,
        )
        h.write_ddr(ADDR_CFG_ARRAY + 0 * LAYER_CFG_SIZE, cfg)

        t0 = time.time()
        status, cycles, out_crc, out_bytes = exec_layer_v0ext(h, 0)
        dt = time.time() - t0
        print(f"  status=0x{status:08X} cycles={cycles} "
              f"out_crc=0x{out_crc:08X} out_bytes={out_bytes} ({dt*1000:.1f}ms)")

        expected_zeros_crc = crc32(bytes(out_bytes))
        print(f"  expected zeros_crc=0x{expected_zeros_crc:08X}  "
              f"match: {out_crc == expected_zeros_crc}")

        # Test 2: RESIZE 2x (ARM real, bit-exact)
        print("\n--- Test 2: RESIZE 2x (ARM real) ---")
        import numpy as np
        np.random.seed(7)
        H, W, C = 13, 13, 4
        in_img = np.random.randint(0, 256, (H, W, C), dtype=np.uint8)

        h.write_ddr(0x10100000, in_img.tobytes())   # input
        # Cfg manda c_in=C, h_in=H, w_in=W → out = 2H x 2W
        cfg = pack_cfg(
            op_type=PRO_OP_RESIZE, layer_idx=1,
            in_addr=0x10100000, out_addr=0x10200000,
            c_in=C, c_out=C,
            h_in=H, w_in=W, h_out=2*H, w_out=2*W,
        )
        h.write_ddr(ADDR_CFG_ARRAY + 1 * LAYER_CFG_SIZE, cfg)

        status, cycles, out_crc, out_bytes = exec_layer_v0ext(h, 1)
        print(f"  status=0x{status:08X} cycles={cycles} "
              f"out_crc=0x{out_crc:08X} out_bytes={out_bytes}")

        # Referencia: replicar en PC
        expected = np.repeat(np.repeat(in_img, 2, axis=0), 2, axis=1)
        expected_bytes = expected.tobytes()
        expected_crc = crc32(expected_bytes)
        print(f"  expected_crc=0x{expected_crc:08X}  "
              f"out_bytes_expected={len(expected_bytes)}  "
              f"match: {out_crc == expected_crc}")

        # Verificar leyendo la salida
        back = h.read_ddr(0x10200000, len(expected_bytes))
        print(f"  bit-exact read vs expected: {back == expected_bytes}")


if __name__ == "__main__":
    main()
