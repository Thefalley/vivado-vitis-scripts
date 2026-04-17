"""Runner unittest (stdlib) de los tests de p18eth.

No requiere pytest. Ejecutar:
    python -m p18eth.tests.run_tests
    python p18eth/tests/run_tests.py
"""
from __future__ import annotations

import socket
import struct
import sys
import time
import unittest

from p18eth import (
    DpuHost, MockServer,
    Kind, OpType, Dtype, Err, Opcode, RspOp, Flags,
    LayerCfg, DataHdr, crc32, pack_data_hdr,
    LAYER_CFG_SIZE, DATA_HDR_SIZE, HEADER_SIZE,
    ADDR_CFG_ARRAY,
)
from p18eth.client import ProtocolError
from p18eth.proto import (
    addr_is_safe, cfg_slot_addr,
    ADDR_INPUT, ADDR_WEIGHTS_BASE, ADDR_ACTIV_POOL,
)


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


# =============================================================================
# Suite 1 — serialización sin red
# =============================================================================
class ProtoSerialization(unittest.TestCase):

    def test_header_size(self):
        self.assertEqual(HEADER_SIZE, 8)

    def test_data_hdr_size(self):
        self.assertEqual(DATA_HDR_SIZE, 16)

    def test_layer_cfg_size(self):
        self.assertEqual(LAYER_CFG_SIZE, 72)

    def test_data_hdr_roundtrip(self):
        payload = b"\xAB" * 1024
        dh_bytes = pack_data_hdr(
            layer_idx=42, kind=Kind.WEIGHTS, dtype=Dtype.INT8,
            ddr_addr=0x12003000, data=payload,
        )
        self.assertEqual(len(dh_bytes), DATA_HDR_SIZE)
        dh = DataHdr.unpack(dh_bytes)
        self.assertEqual(dh.layer_idx, 42)
        self.assertEqual(dh.kind, Kind.WEIGHTS)
        self.assertEqual(dh.ddr_addr, 0x12003000)
        self.assertEqual(dh.expected_len, len(payload))
        self.assertEqual(dh.crc32, crc32(payload))

    def test_crc_matches_zlib(self):
        import zlib
        data = b"hello protocol 1"
        self.assertEqual(crc32(data), zlib.crc32(data) & 0xFFFFFFFF)

    def test_layer_cfg_defaults_zero_bytes(self):
        self.assertEqual(LayerCfg().pack(), b"\x00" * LAYER_CFG_SIZE)

    def test_layer_cfg_fields_roundtrip(self):
        cfg = LayerCfg(
            op_type=OpType.CONV, act_type=1, layer_idx=47,
            in_addr=0x16000000, in_b_addr=0, out_addr=0x17000000,
            w_addr=0x12050000, b_addr=0x12300000,
            c_in=64, c_out=128, h_in=52, w_in=52, h_out=52, w_out=52,
            kh=3, kw=3, stride_h=1, stride_w=1,
            pad_top=1, pad_bottom=1, pad_left=1, pad_right=1,
            ic_tile_size=16, post_shift=5, leaky_alpha_q=0x0333,
            a_scale_m=0x7FFFFFFF, b_scale_m=-1,
            a_scale_s=-3, b_scale_s=2, out_zp=-128, out_scale_s=-7,
            reserved0=0xDEADBEEF, reserved1=0, reserved2=0xCAFEBABE,
        )
        data = cfg.pack()
        self.assertEqual(len(data), LAYER_CFG_SIZE)
        cfg2 = LayerCfg.unpack(data)
        for f in cfg.__dataclass_fields__:
            self.assertEqual(getattr(cfg, f), getattr(cfg2, f),
                             f"field {f} diverges")

    def test_layer_cfg_layout_offsets(self):
        cfg = LayerCfg(
            op_type=0xAA, act_type=0xBB, layer_idx=0xCCDD,
            in_addr=0x11112222, in_b_addr=0x33334444,
            out_addr=0x55556666, w_addr=0x77778888,
            b_addr=0x9999AAAA,
            c_in=0x1111, c_out=0x2222,
            h_in=0x3333, w_in=0x4444, h_out=0x5555, w_out=0x6666,
        )
        b = cfg.pack()
        self.assertEqual(b[0], 0xAA)
        self.assertEqual(b[1], 0xBB)
        self.assertEqual(struct.unpack("<H", b[2:4])[0], 0xCCDD)
        self.assertEqual(struct.unpack("<I", b[4:8])[0], 0x11112222)
        self.assertEqual(struct.unpack("<I", b[8:12])[0], 0x33334444)
        self.assertEqual(struct.unpack("<I", b[12:16])[0], 0x55556666)
        self.assertEqual(struct.unpack("<H", b[24:26])[0], 0x1111)

    def test_addr_is_safe(self):
        self.assertTrue(addr_is_safe(0x10000000, 1024))
        self.assertTrue(addr_is_safe(0x12000000, 61 << 20))
        self.assertTrue(addr_is_safe(0x11000000, 18360))
        self.assertFalse(addr_is_safe(0x10000000, 0))
        self.assertFalse(addr_is_safe(0x00000000, 1024))
        self.assertFalse(addr_is_safe(0x20000000, 1024))
        self.assertFalse(addr_is_safe(0x0FF00000, 0x200000))

    def test_cfg_slot_addr(self):
        self.assertEqual(cfg_slot_addr(0), ADDR_CFG_ARRAY)
        self.assertEqual(cfg_slot_addr(1), ADDR_CFG_ARRAY + LAYER_CFG_SIZE)
        self.assertEqual(cfg_slot_addr(254),
                         ADDR_CFG_ARRAY + 254 * LAYER_CFG_SIZE)
        with self.assertRaises(ValueError):
            cfg_slot_addr(255)

    def test_addresses_do_not_overlap(self):
        self.assertLessEqual(
            ADDR_CFG_ARRAY + 255 * LAYER_CFG_SIZE, ADDR_WEIGHTS_BASE)
        self.assertLess(ADDR_WEIGHTS_BASE, ADDR_ACTIV_POOL)

    def test_enum_values_unique(self):
        for cls in [Opcode, RspOp, Kind, OpType, Dtype, Err]:
            values = [e.value for e in cls]
            self.assertEqual(len(values), len(set(values)),
                             f"{cls.__name__} duplicates")


# =============================================================================
# Suite 2 — client ↔ mock (TCP loopback)
# =============================================================================
class ClientMockE2E(unittest.TestCase):

    def setUp(self):
        self.port = _free_port()
        self.srv = MockServer(host="127.0.0.1", port=self.port, verbose=False)
        self.srv.start()
        # NO connect eager: los tests con socket crudo necesitan que el mock
        # tenga el accept disponible. self.h se conecta perezosamente en la
        # primera llamada API.
        self.h = DpuHost("127.0.0.1", port=self.port, timeout=5.0)

    def tearDown(self):
        try:
            self.h.close()
        except Exception:
            pass
        self.srv.stop()

    # ---- basic ----
    def test_hello_ok(self):
        info = self.h.hello()
        self.assertEqual(info["proto_ver"], 1)
        self.assertEqual(info["layer_cfg_size"], LAYER_CFG_SIZE)
        self.assertEqual(info["data_hdr_size"], DATA_HDR_SIZE)

    def test_ping(self):
        self.assertEqual(self.h.ping(), b"P_18 OK\0")

    # ---- write/read raw ----
    def test_write_read_raw_small(self):
        self.h.hello()
        data = b"\x01\x02\x03\x04" * 64
        self.h.write_raw(0x10000000, data)
        back = self.h.read_raw(0x10000000, len(data))
        self.assertEqual(back, data)

    def test_write_read_raw_1mb(self):
        self.h.hello()
        data = bytes(range(256)) * 4096    # 1 MB exacto
        self.h.write_raw(0x12000000, data)
        back = self.h.read_raw(0x12000000, len(data))
        self.assertEqual(back, data)

    def test_write_raw_bad_address(self):
        self.h.hello()
        with self.assertRaises(ProtocolError) as ctx:
            self.h.write_raw(0x00000000, b"\xAA" * 16)
        self.assertEqual(ctx.exception.code, Err.BAD_ADDR)

    # ---- typed ----
    def test_write_input_marks_state(self):
        self.h.hello()
        img = bytes([7]) * (416 * 416 * 3)
        self.h.write_input(addr=0x10000000, data=img)
        self.assertTrue(self.srv.state.input_loaded)
        self.assertEqual(self.srv.ddr.read(0x10000000, len(img)), img)

    def test_write_weights_marks_state(self):
        self.h.hello()
        self.h.write_weights(layer_idx=0, addr=0x12000000, data=b"\x7F" * 864)
        self.assertTrue(self.srv.state.layer[0].w_loaded)
        self.assertFalse(self.srv.state.layer[1].w_loaded)

    def test_write_bias_marks_state(self):
        self.h.hello()
        bias = struct.pack("<" + "i" * 32, *range(32))
        self.h.write_bias(layer_idx=0, addr=0x12100000, data=bias)
        self.assertTrue(self.srv.state.layer[0].b_loaded)

    # ---- error paths ----
    def test_exec_without_cfg_rejected(self):
        self.h.hello()
        with self.assertRaises(ProtocolError) as ctx:
            self.h.exec_layer(3)
        self.assertEqual(ctx.exception.code, Err.NOT_CONFIGURED)

    def test_exec_missing_weights_rejected(self):
        self.h.hello()
        cfg = LayerCfg(
            op_type=OpType.CONV, layer_idx=0,
            c_in=3, c_out=32, h_in=416, w_in=416, h_out=416, w_out=416,
            kh=3, kw=3, stride_h=1, stride_w=1,
            pad_top=1, pad_bottom=1, pad_left=1, pad_right=1,
            in_addr=0x10000000, out_addr=0x16000000,
            w_addr=0x12000000, b_addr=0x12A00000,
        )
        self.h.write_cfg(cfg)
        with self.assertRaises(ProtocolError) as ctx:
            self.h.exec_layer(0)
        self.assertEqual(ctx.exception.code, Err.MISSING_DATA)

    def test_hello_wrong_version_rejected(self):
        # conexión cruda, no reutilizar self.h (que ya hizo hello)
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=2.0)
        bad = struct.pack("<IIII", 999, LAYER_CFG_SIZE, DATA_HDR_SIZE, 0)
        h = struct.pack("<BBHI", Opcode.HELLO, 0, 1, len(bad))
        sock.sendall(h + bad)
        rh = sock.recv(8)
        plen = struct.unpack("<I", rh[4:8])[0]
        body = sock.recv(plen)
        sock.close()
        self.assertEqual(rh[0], RspOp.ERROR)
        code = struct.unpack("<I", body[:4])[0]
        self.assertEqual(code, Err.PROTO_VERSION)

    def test_crc_corruption_detected(self):
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=2.0)
        hello_payload = struct.pack("<IIII", 1, LAYER_CFG_SIZE,
                                    DATA_HDR_SIZE, 0)
        hello_hdr = struct.pack("<BBHI", Opcode.HELLO, 0, 1,
                                len(hello_payload))
        sock.sendall(hello_hdr + hello_payload)
        # descartar respuesta ACK del hello (header + payload)
        rh = sock.recv(8)
        plen = struct.unpack("<I", rh[4:8])[0]
        sock.recv(plen)

        data = b"\x41" * 16
        bad_dh = DataHdr(layer_idx=0, kind=Kind.WEIGHTS, dtype=Dtype.INT8,
                         ddr_addr=0x12000000, expected_len=16,
                         crc32=0xDEADBEEF).pack()
        payload = bad_dh + data
        hdr = struct.pack("<BBHI", Opcode.WRITE_WEIGHTS,
                          Flags.HAS_DATA_HDR, 2, len(payload))
        sock.sendall(hdr + payload)
        rh = sock.recv(8)
        plen = struct.unpack("<I", rh[4:8])[0]
        body = sock.recv(plen)
        sock.close()

        self.assertEqual(rh[0], RspOp.ERROR)
        code = struct.unpack("<I", body[:4])[0]
        self.assertEqual(code, Err.CRC)
        self.assertEqual(self.srv.state.total_crc_errors, 1)

    def test_kind_mismatch_rejected(self):
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=2.0)
        hello_payload = struct.pack("<IIII", 1, LAYER_CFG_SIZE,
                                    DATA_HDR_SIZE, 0)
        hello_hdr = struct.pack("<BBHI", Opcode.HELLO, 0, 1,
                                len(hello_payload))
        sock.sendall(hello_hdr + hello_payload)
        rh = sock.recv(8)
        plen = struct.unpack("<I", rh[4:8])[0]
        sock.recv(plen)

        data = b"\xAB" * 16
        # kind=INPUT pero opcode=WRITE_WEIGHTS → mismatch
        bad_dh = pack_data_hdr(layer_idx=0, kind=Kind.INPUT,
                               dtype=Dtype.INT8,
                               ddr_addr=0x12000000, data=data)
        payload = bad_dh + data
        hdr = struct.pack("<BBHI", Opcode.WRITE_WEIGHTS,
                          Flags.HAS_DATA_HDR, 5, len(payload))
        sock.sendall(hdr + payload)
        rh = sock.recv(8)
        plen = struct.unpack("<I", rh[4:8])[0]
        body = sock.recv(plen)
        sock.close()
        self.assertEqual(rh[0], RspOp.ERROR)
        code = struct.unpack("<I", body[:4])[0]
        self.assertEqual(code, Err.KIND_MISMATCH)

    # ---- happy path ----
    def test_exec_layer_conv_happy_path(self):
        self.h.hello()
        image = bytes([7]) * (416 * 416 * 3)
        self.h.write_input(addr=0x10000000, data=image)
        self.h.write_weights(0, 0x12000000, b"\x01" * 864)
        self.h.write_bias(0, 0x12A00000, struct.pack("<" + "i" * 32,
                                                     *([0] * 32)))
        cfg = LayerCfg(
            op_type=OpType.CONV, layer_idx=0,
            c_in=3, c_out=32, h_in=416, w_in=416, h_out=416, w_out=416,
            kh=3, kw=3, stride_h=1, stride_w=1,
            pad_top=1, pad_bottom=1, pad_left=1, pad_right=1,
            in_addr=0x10000000, out_addr=0x16000000,
            w_addr=0x12000000, b_addr=0x12A00000,
        )
        self.h.write_cfg(cfg)
        res = self.h.exec_layer(0)
        self.assertEqual(res.status, Err.OK)
        self.assertEqual(res.out_bytes, 32 * 416 * 416)
        self.assertEqual(res.out_crc, crc32(bytes(res.out_bytes)))

    def test_read_activation_roundtrip(self):
        self.h.hello()
        payload = bytes(range(256)) * 1024
        self.srv.ddr.write(0x16000000, payload)
        data, crc_reported = self.h.read_activation(0x16000000, len(payload))
        self.assertEqual(data, payload)
        self.assertEqual(crc_reported, crc32(payload))

    # ---- state ----
    def test_reset_state_clears_flags(self):
        self.h.hello()
        self.h.write_weights(10, 0x12000000, b"\x01" * 16)
        self.assertTrue(self.srv.state.layer[10].w_loaded)
        self.h.reset_state()
        self.assertFalse(self.srv.state.layer[10].w_loaded)

    def test_get_state_reports_flags(self):
        self.h.hello()
        self.h.write_weights(100, 0x12000000, b"\x00" * 32)
        st = self.h.get_state()
        self.assertEqual(len(st), 255)
        self.assertTrue(st[100]["w_loaded"])
        self.assertFalse(st[100]["b_loaded"])

    def test_255_layers_simulation(self):
        self.h.hello()
        image = bytes([7]) * (416 * 416 * 3)
        self.h.write_input(addr=0x10000000, data=image)

        cfgs = []
        for i in range(255):
            cfg = LayerCfg(
                op_type=OpType.CONV, layer_idx=i,
                c_in=4, c_out=4, h_in=4, w_in=4, h_out=4, w_out=4,
                kh=1, kw=1, stride_h=1, stride_w=1,
                in_addr=(0x10000000 if i == 0
                         else 0x16000000 + i * 256),
                out_addr=0x16000000 + (i + 1) * 256,
                w_addr=0x12000000 + i * 64,
                b_addr=0x12A00000 + i * 16,
            )
            cfgs.append(cfg)
        self.h.write_cfg_array(cfgs)
        for i in range(255):
            self.h.write_weights(i, 0x12000000 + i * 64, b"\x01" * 16)
            self.h.write_bias(i, 0x12A00000 + i * 16, b"\x00" * 16)
        for i in range(255):
            res = self.h.exec_layer(i)
            self.assertEqual(res.status, Err.OK,
                             f"layer {i} status=0x{res.status:08x}")
        st = self.h.get_state()
        for s in st:
            self.assertTrue(s["cfg_set"])
            self.assertTrue(s["w_loaded"])
            self.assertTrue(s["executed"])

    def test_custom_exec_hook_out_crc(self):
        """exec_hook custom para verificar que out_crc refleja los bytes."""
        expected = b"\x55" * 256
        self.srv.exec_hook = lambda cfg, srv: expected
        self.h.hello()
        cfg = LayerCfg(
            op_type=OpType.CONV, layer_idx=42,
            c_in=4, c_out=4, h_in=4, w_in=4, h_out=4, w_out=4,
            kh=1, kw=1,
            in_addr=0x10000000, out_addr=0x16000000,
            w_addr=0x12000000, b_addr=0x12A00000,
        )
        self.h.write_cfg(cfg)
        self.h.write_weights(42, 0x12000000, b"\x01" * 16)
        self.h.write_bias(42, 0x12A00000, b"\x00" * 16)
        self.h.write_activation_in(42, 0x10000000, b"\x00" * 64)
        res = self.h.exec_layer(42)
        self.assertEqual(res.status, Err.OK)
        self.assertEqual(res.out_crc, crc32(expected))


# =============================================================================
# Entry point
# =============================================================================
if __name__ == "__main__":
    unittest.main(verbosity=2)
