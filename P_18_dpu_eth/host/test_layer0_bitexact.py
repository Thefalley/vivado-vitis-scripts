"""Test bit-exact de la PRIMERA CAPA CONV en FPGA vs ONNX.

Flujo:
  1. Cargar blob de pesos entero (64 MB) a DDR
  2. Cargar input cuantizado (layer_001.bin) con transpose NCHW->NHWC
  3. Escribir layer_cfg_t de layer 0 en DDR
  4. CMD_EXEC_LAYER(0) -> conv_engine_v3 en FPGA
  5. Leer salida, transpose NHWC->NCHW, comparar con onnx_refs/layer_002.bin
"""
import json
import os
import struct
import sys
import time
import zlib

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from yolov4_host import DpuHost, CMD_EXEC_LAYER

# Rutas
BLOB  = r"C:/project/vitis-ai/workspace/c_dpu/yolov4_weights.bin"
REFS  = r"C:/project/vivado/P_18_dpu_eth/host/onnx_refs"
LAYER_001 = os.path.join(REFS, "layer_001.bin")   # input cuantizado NCHW (1,3,416,416) int8
LAYER_002 = os.path.join(REFS, "layer_002.bin")   # output esperado NCHW (1,32,416,416) int8

# Direcciones DDR
ADDR_INPUT       = 0x10000000
ADDR_CFG_ARRAY   = 0x11000000
ADDR_WEIGHTS     = 0x12000000
ADDR_OUT         = 0x16000000

# Entry del manifest para layer 0
W_OFFSET, W_BYTES = 0, 864
B_OFFSET, B_BYTES = 864, 128

LAYER_CFG_FMT = (
    "<BBH IIIII HHHHHH BBBB BBBB BB h i i bbbb III"
)
assert struct.calcsize(LAYER_CFG_FMT) == 72

PRO_OP_CONV = 0


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


def exec_layer(h, idx):
    h.connect()
    payload = struct.pack("<HH", idx, 0)
    tag = h._next_tag()
    h._send_header(CMD_EXEC_LAYER, len(payload), tag=tag)
    h._sendall(payload)
    status, extra = h._expect_ack()
    if len(extra) >= 12:
        cycles, crc, nb = struct.unpack("<III", extra[:12])
        return status, cycles, crc, nb
    return status, 0, 0, 0


def main():
    print("=" * 60)
    print("TEST LAYER 0 BIT-EXACT — primera CONV 3->32 en FPGA vs ONNX")
    print("=" * 60)

    # Cargar artifacts
    print("\n[prep] Cargando artifacts...")
    blob = open(BLOB, "rb").read()
    print(f"       blob pesos: {len(blob)/1e6:.1f} MB")

    # VERIFICADO EN EL RTL (conv_engine_v3.vhd L829): act_ic_offset += hw_reg
    # al cambiar canal --> RTL espera NCHW channels-first. NO transponer.
    in_nchw = np.fromfile(LAYER_001, dtype=np.int8).reshape(1, 3, 416, 416)
    exp_nchw = np.fromfile(LAYER_002, dtype=np.int8).reshape(1, 32, 416, 416)
    exp_crc_nchw = zlib.crc32(exp_nchw.tobytes()) & 0xFFFFFFFF
    print(f"       input  NCHW crc=0x{zlib.crc32(in_nchw.tobytes())&0xFFFFFFFF:08X}")
    print(f"       expect NCHW crc=0x{exp_crc_nchw:08X}")

    with DpuHost("192.168.1.10", timeout=60.0) as h:
        print(f"\n[net] PING: {h.ping()}")
        h.dpu_init()
        print("[net] DPU_INIT OK")

        t0 = time.time()
        h.write_ddr(ADDR_WEIGHTS, blob)
        print(f"[1] Blob pesos 64 MB: {(time.time()-t0)*1000:.0f} ms = "
              f"{len(blob)/(time.time()-t0)/1e6:.1f} MB/s")

        t0 = time.time()
        h.write_ddr(ADDR_INPUT, in_nchw.tobytes())
        print(f"[2] Input NCHW (verbatim) 519K: {(time.time()-t0)*1000:.0f} ms")

        cfg = pack_cfg(
            op_type=PRO_OP_CONV, layer_idx=0,
            in_addr=ADDR_INPUT, out_addr=ADDR_OUT,
            w_addr=ADDR_WEIGHTS + W_OFFSET,
            b_addr=ADDR_WEIGHTS + B_OFFSET,
            c_in=3, c_out=32,
            h_in=416, w_in=416, h_out=416, w_out=416,
            kh=3, kw=3, stride_h=1, stride_w=1,
            pad_top=1, pad_bottom=1, pad_left=1, pad_right=1,
        )
        h.write_ddr(ADDR_CFG_ARRAY + 0 * 72, cfg)
        print("[3] cfg layer 0 escrito en 0x11000000")

        print("\n[4] EXEC_LAYER(0) — conv_engine_v3 ejecutando en FPGA...")
        t0 = time.time()
        status, cycles, out_crc, out_bytes = exec_layer(h, 0)
        dt = time.time() - t0
        print(f"    status = 0x{status:08X}")
        print(f"    cycles = {cycles}")
        print(f"    out_crc (NHWC, del DPU) = 0x{out_crc:08X}")
        print(f"    out_bytes = {out_bytes}")
        print(f"    wall time = {dt*1000:.0f} ms")

        if status != 0:
            print(f"\n❌ Status error 0x{status:08X} — abort")
            return

        # RTL espera NCHW, produce NCHW. Compara directo con expected NCHW.
        if out_crc == exp_crc_nchw:
            print(f"\n✅✅✅ DPU output CRC NCHW == ONNX expected NCHW CRC")
            print("     Primer pipeline CONV real en FPGA BIT-EXACT vs ONNX")
            return

        print(f"\n[5] CRC no coincide. Leo output del DPU y comparo bytes...")
        t0 = time.time()
        dpu_bytes = h.read_ddr(ADDR_OUT, out_bytes)
        print(f"    READ {out_bytes} B en {(time.time()-t0)*1000:.0f} ms")

        # Output del RTL tambien es NCHW (misma logica de addressing).
        dpu_nchw = np.frombuffer(dpu_bytes, dtype=np.int8).reshape(1, 32, 416, 416)
        dpu_flat = dpu_nchw.flatten()
        exp_flat = exp_nchw.flatten()
        diff = np.nonzero(dpu_flat != exp_flat)[0]
        if diff.size == 0:
            print("    ✅ Todos los bytes coinciden NCHW")
        else:
            n_diff = diff.size
            total = exp_flat.size
            print(f"    ❌ {n_diff}/{total} bytes divergentes "
                  f"({100*n_diff/total:.2f}%)")
            print(f"       primer idx divergente: {diff[0]}")
            i0 = diff[0]
            print(f"       dpu[{i0}:{i0+8}]: {dpu_flat[i0:i0+8]}")
            print(f"       exp[{i0}:{i0+8}]: {exp_flat[i0:i0+8]}")
            # Coinciden primeros N bytes?
            if diff[0] > 0:
                print(f"       primeros {diff[0]} bytes coinciden!")


if __name__ == "__main__":
    main()
