"""Tests de serialización del protocolo (sin red)."""
import struct

import pytest

from p18eth.proto import (
    HEADER_SIZE, DATA_HDR_SIZE, LAYER_CFG_SIZE,
    Header, DataHdr, LayerCfg,
    Kind, OpType, Dtype, Err, Opcode, RspOp,
    crc32, pack_data_hdr, pack_layer_cfg, unpack_layer_cfg,
    addr_is_safe, cfg_slot_addr,
    ADDR_INPUT, ADDR_CFG_ARRAY, ADDR_WEIGHTS_BASE, ADDR_ACTIV_POOL,
)


# =============================================================================
# Tamaños
# =============================================================================
def test_header_size():
    assert HEADER_SIZE == 8


def test_data_hdr_size():
    assert DATA_HDR_SIZE == 16


def test_layer_cfg_size():
    assert LAYER_CFG_SIZE == 72


# =============================================================================
# Header round-trip
# =============================================================================
def test_header_roundtrip():
    h = Header(opcode=0x11, flags=1, tag=0xBEEF, payload_len=1234)
    data = h.pack()
    assert len(data) == HEADER_SIZE
    h2 = Header.unpack(data)
    assert (h2.opcode, h2.flags, h2.tag, h2.payload_len) == \
           (0x11, 1, 0xBEEF, 1234)


# =============================================================================
# DataHdr round-trip + crc
# =============================================================================
def test_data_hdr_roundtrip():
    payload = b"\xAB" * 1024
    dh_bytes = pack_data_hdr(
        layer_idx=42, kind=Kind.WEIGHTS, dtype=Dtype.INT8,
        ddr_addr=0x12003000, data=payload,
    )
    assert len(dh_bytes) == DATA_HDR_SIZE
    dh = DataHdr.unpack(dh_bytes)
    assert dh.layer_idx == 42
    assert dh.kind == Kind.WEIGHTS
    assert dh.dtype == Dtype.INT8
    assert dh.ddr_addr == 0x12003000
    assert dh.expected_len == len(payload)
    assert dh.crc32 == crc32(payload)


def test_crc_matches_zlib():
    import zlib
    data = b"hello protocol 1"
    assert crc32(data) == zlib.crc32(data) & 0xFFFFFFFF


# =============================================================================
# LayerCfg round-trip
# =============================================================================
def test_layer_cfg_defaults_pack():
    cfg = LayerCfg()
    b = cfg.pack()
    assert len(b) == LAYER_CFG_SIZE
    # todo zeros
    assert b == b"\x00" * LAYER_CFG_SIZE


def test_layer_cfg_fields_roundtrip():
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
    assert len(data) == LAYER_CFG_SIZE
    cfg2 = LayerCfg.unpack(data)
    for f in cfg.__dataclass_fields__:
        assert getattr(cfg, f) == getattr(cfg2, f), f"field {f} diverges"


def test_layer_cfg_layout_offsets():
    """Verifica offsets crít­icos del layout (espejo del struct C)."""
    cfg = LayerCfg(
        op_type=0xAA, act_type=0xBB, layer_idx=0xCCDD,
        in_addr=0x11112222, in_b_addr=0x33334444,
        out_addr=0x55556666, w_addr=0x77778888,
        b_addr=0x9999AAAA,
        c_in=0x1111, c_out=0x2222,
        h_in=0x3333, w_in=0x4444, h_out=0x5555, w_out=0x6666,
    )
    b = cfg.pack()
    assert b[0] == 0xAA                                 # op_type
    assert b[1] == 0xBB                                 # act_type
    assert struct.unpack("<H", b[2:4])[0] == 0xCCDD     # layer_idx
    assert struct.unpack("<I", b[4:8])[0] == 0x11112222  # in_addr
    assert struct.unpack("<I", b[8:12])[0] == 0x33334444 # in_b_addr
    assert struct.unpack("<I", b[12:16])[0] == 0x55556666
    assert struct.unpack("<I", b[16:20])[0] == 0x77778888
    assert struct.unpack("<I", b[20:24])[0] == 0x9999AAAA
    assert struct.unpack("<H", b[24:26])[0] == 0x1111   # c_in


# =============================================================================
# addr_is_safe
# =============================================================================
def test_addr_is_safe_mailbox_region():
    assert addr_is_safe(0x10000000, 1024)
    assert addr_is_safe(0x10FFF000, 0x1000)
    # overflow por encima del rango
    assert not addr_is_safe(0x10FFFF00, 0x200)


def test_addr_is_safe_weights_region():
    assert addr_is_safe(0x12000000, 61 << 20)
    assert addr_is_safe(0x11000000, 18360)


def test_addr_is_safe_zero_length():
    assert not addr_is_safe(0x10000000, 0)


def test_addr_is_safe_outside_ranges():
    assert not addr_is_safe(0x00000000, 1024)    # bajo reserva
    assert not addr_is_safe(0x20000000, 1024)    # fuera de DDR 512 MB DPU
    assert not addr_is_safe(0x0FF00000, 0x200000)  # cruza límite low


# =============================================================================
# Memory map
# =============================================================================
def test_cfg_slot_addr():
    assert cfg_slot_addr(0) == ADDR_CFG_ARRAY
    assert cfg_slot_addr(1) == ADDR_CFG_ARRAY + LAYER_CFG_SIZE
    assert cfg_slot_addr(254) == ADDR_CFG_ARRAY + 254 * LAYER_CFG_SIZE


def test_cfg_slot_addr_out_of_range():
    with pytest.raises(ValueError):
        cfg_slot_addr(-1)
    with pytest.raises(ValueError):
        cfg_slot_addr(255)


def test_addresses_do_not_overlap():
    # El array de cfgs cabe entre 0x11000000 y 0x12000000
    assert ADDR_CFG_ARRAY + 255 * LAYER_CFG_SIZE <= ADDR_WEIGHTS_BASE
    # Weights base < activations pool
    assert ADDR_WEIGHTS_BASE < ADDR_ACTIV_POOL


# =============================================================================
# Enums sanity
# =============================================================================
def test_enum_values_unique():
    for enum_cls in [Opcode, RspOp, Kind, OpType, Dtype, Err]:
        values = [e.value for e in enum_cls]
        assert len(values) == len(set(values)), \
            f"{enum_cls.__name__} tiene valores duplicados"


def test_known_opcodes():
    assert Opcode.HELLO == 0x00
    assert Opcode.PING == 0x01
    assert Opcode.EXEC_LAYER == 0x20
    assert Opcode.CLOSE == 0xFF
