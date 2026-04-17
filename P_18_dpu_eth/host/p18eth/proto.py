"""Protocolo ETH V1 — fuente única de verdad (espejo de eth_protocol.h).

Si modificas opcodes, layer_cfg_t o data_hdr_t aquí, debes tocar también
`sw/eth_protocol.h` y regenerar el firmware. El test `test_proto.py` verifica
que los tamaños siguen coincidiendo con la especificación.

Documento de diseño: `docs/ETH_PROTOCOL_V1.md`.
"""
from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass, field, fields
from enum import IntEnum
from typing import Optional

# =============================================================================
# Versión
# =============================================================================
PROTO_VERSION = 1

# =============================================================================
# Opcodes (PC → ARM)
# =============================================================================
class Opcode(IntEnum):
    HELLO               = 0x00
    PING                = 0x01
    WRITE_RAW           = 0x02
    READ_RAW            = 0x03
    WRITE_INPUT         = 0x10
    WRITE_WEIGHTS       = 0x11
    WRITE_BIAS          = 0x12
    WRITE_ACTIVATION_IN = 0x13
    WRITE_CFG           = 0x14
    EXEC_LAYER          = 0x20
    RUN_RANGE           = 0x21
    READ_ACTIVATION     = 0x30
    GET_STATE           = 0x40
    RESET_STATE         = 0x41
    DPU_INIT            = 0x42
    DPU_RESET           = 0x43
    CLOSE               = 0xFF


# =============================================================================
# Respuestas (ARM → PC)
# =============================================================================
class RspOp(IntEnum):
    PONG  = 0x81
    ACK   = 0x82
    DATA  = 0x83
    ERROR = 0x8E


# =============================================================================
# Kind (tipo semántico del dato en data_hdr_t)
# =============================================================================
class Kind(IntEnum):
    NONE            = 0
    WEIGHTS         = 1
    BIAS            = 2
    INPUT           = 3
    ACTIVATION_IN   = 4
    LAYER_CFG       = 5
    ACTIVATION_OUT  = 6


# =============================================================================
# OpType (tipo de operación en layer_cfg_t)
# =============================================================================
class OpType(IntEnum):
    CONV     = 0
    LEAKY    = 1
    POOL_MAX = 2
    ELEM_ADD = 3
    CONCAT   = 4
    RESIZE   = 5


# =============================================================================
# Dtype
# =============================================================================
class Dtype(IntEnum):
    INT8  = 0
    INT32 = 1
    UINT8 = 2


# =============================================================================
# Err codes
# =============================================================================
class Err(IntEnum):
    OK                = 0x00
    INVALID_CMD       = 0x01
    BAD_ADDR          = 0x02
    DPU_TIMEOUT       = 0x03
    DPU_FAULT         = 0x04
    BUFFER_OVERRUN    = 0x05
    BAD_LAYER         = 0x10
    BAD_KIND          = 0x11
    BAD_DTYPE         = 0x12
    LEN_MISMATCH      = 0x13
    KIND_MISMATCH     = 0x14
    CRC               = 0x15
    NOT_CONFIGURED    = 0x20
    MISSING_DATA      = 0x21
    DEP_NOT_READY     = 0x22
    PROTO_VERSION     = 0x30


# =============================================================================
# Flags en el header
# =============================================================================
class Flags:
    HAS_DATA_HDR = 1 << 0    # el payload empieza con data_hdr_t
    EXPECT_CRC   = 1 << 1    # pedir crc32 en la respuesta


# =============================================================================
# act_type en layer_cfg_t
# =============================================================================
class ActType(IntEnum):
    NONE  = 0
    LEAKY = 1


# =============================================================================
# Formato del Header común (8 bytes)
# =============================================================================
HEADER_FMT  = "<BBHI"
HEADER_SIZE = struct.calcsize(HEADER_FMT)
assert HEADER_SIZE == 8, f"header debe ser 8 B, es {HEADER_SIZE}"


@dataclass
class Header:
    opcode: int
    flags: int
    tag: int
    payload_len: int

    def pack(self) -> bytes:
        return struct.pack(HEADER_FMT, self.opcode & 0xFF, self.flags & 0xFF,
                           self.tag & 0xFFFF, self.payload_len & 0xFFFFFFFF)

    @classmethod
    def unpack(cls, buf: bytes) -> "Header":
        return cls(*struct.unpack(HEADER_FMT, buf[:HEADER_SIZE]))


# =============================================================================
# Formato data_hdr_t (16 bytes)
# =============================================================================
DATA_HDR_FMT  = "<HBBIII"
DATA_HDR_SIZE = struct.calcsize(DATA_HDR_FMT)
assert DATA_HDR_SIZE == 16, f"data_hdr_t debe ser 16 B, es {DATA_HDR_SIZE}"


@dataclass
class DataHdr:
    layer_idx: int       # 0xFFFF si no aplica
    kind: int            # Kind enum
    dtype: int           # Dtype enum
    ddr_addr: int
    expected_len: int
    crc32: int

    def pack(self) -> bytes:
        return struct.pack(
            DATA_HDR_FMT,
            self.layer_idx & 0xFFFF,
            self.kind & 0xFF,
            self.dtype & 0xFF,
            self.ddr_addr & 0xFFFFFFFF,
            self.expected_len & 0xFFFFFFFF,
            self.crc32 & 0xFFFFFFFF,
        )

    @classmethod
    def unpack(cls, buf: bytes) -> "DataHdr":
        return cls(*struct.unpack(DATA_HDR_FMT, buf[:DATA_HDR_SIZE]))


def pack_data_hdr(layer_idx: int, kind: int, dtype: int,
                  ddr_addr: int, data: bytes) -> bytes:
    """Serializa un data_hdr con crc32 calculado automáticamente."""
    hdr = DataHdr(
        layer_idx=layer_idx,
        kind=kind,
        dtype=dtype,
        ddr_addr=ddr_addr,
        expected_len=len(data),
        crc32=crc32(data),
    )
    return hdr.pack()


def unpack_data_hdr(buf: bytes) -> DataHdr:
    return DataHdr.unpack(buf)


# =============================================================================
# Formato layer_cfg_t (72 bytes)
# =============================================================================
#
# Layout byte-por-byte (mismo orden que eth_protocol.h):
#   offset  size  campo
#     0      1    op_type          (B)
#     1      1    act_type         (B)
#     2      2    layer_idx        (H)
#     4      4    in_addr          (I)
#     8      4    in_b_addr        (I)
#    12      4    out_addr         (I)
#    16      4    w_addr           (I)
#    20      4    b_addr           (I)
#    24      2    c_in             (H)
#    26      2    c_out            (H)
#    28      2    h_in             (H)
#    30      2    w_in             (H)
#    32      2    h_out            (H)
#    34      2    w_out            (H)
#    36      1    kh               (B)
#    37      1    kw               (B)
#    38      1    stride_h         (B)
#    39      1    stride_w         (B)
#    40      1    pad_top          (B)
#    41      1    pad_bottom       (B)
#    42      1    pad_left         (B)
#    43      1    pad_right        (B)
#    44      1    ic_tile_size     (B)
#    45      1    post_shift       (B)
#    46      2    leaky_alpha_q    (h, int16)
#    48      4    a_scale_m        (i, int32)
#    52      4    b_scale_m        (i, int32)
#    56      1    a_scale_s        (b, int8)
#    57      1    b_scale_s        (b, int8)
#    58      1    out_zp           (b, int8)
#    59      1    out_scale_s      (b, int8)
#    60     12    reserved[3]      (III)
#    72     -     (end)
LAYER_CFG_FMT = (
    "<"       # little-endian, sin padding
    "BB"      # op_type, act_type
    "H"       # layer_idx
    "IIIII"   # in_addr, in_b_addr, out_addr, w_addr, b_addr
    "HHHHHH"  # c_in, c_out, h_in, w_in, h_out, w_out
    "BB"      # kh, kw
    "BB"      # stride_h, stride_w
    "BBBB"    # pad_top, pad_bottom, pad_left, pad_right
    "BB"      # ic_tile_size, post_shift
    "h"       # leaky_alpha_q
    "i"       # a_scale_m
    "i"       # b_scale_m
    "bbbb"    # a_scale_s, b_scale_s, out_zp, out_scale_s
    "III"     # reserved[3]
)
LAYER_CFG_SIZE = struct.calcsize(LAYER_CFG_FMT)
assert LAYER_CFG_SIZE == 72, f"layer_cfg_t debe ser 72 B, es {LAYER_CFG_SIZE}"


@dataclass
class LayerCfg:
    op_type:       int = 0           # OpType
    act_type:      int = 0           # ActType
    layer_idx:     int = 0
    in_addr:       int = 0
    in_b_addr:     int = 0
    out_addr:      int = 0
    w_addr:        int = 0
    b_addr:        int = 0
    c_in:          int = 0
    c_out:         int = 0
    h_in:          int = 0
    w_in:          int = 0
    h_out:         int = 0
    w_out:         int = 0
    kh:            int = 0
    kw:            int = 0
    stride_h:      int = 0
    stride_w:      int = 0
    pad_top:       int = 0
    pad_bottom:    int = 0
    pad_left:      int = 0
    pad_right:     int = 0
    ic_tile_size:  int = 0
    post_shift:    int = 0
    leaky_alpha_q: int = 0
    a_scale_m:     int = 0
    b_scale_m:     int = 0
    a_scale_s:     int = 0
    b_scale_s:     int = 0
    out_zp:        int = 0
    out_scale_s:   int = 0
    reserved0:     int = 0
    reserved1:     int = 0
    reserved2:     int = 0

    def pack(self) -> bytes:
        return struct.pack(
            LAYER_CFG_FMT,
            self.op_type & 0xFF, self.act_type & 0xFF,
            self.layer_idx & 0xFFFF,
            self.in_addr & 0xFFFFFFFF, self.in_b_addr & 0xFFFFFFFF,
            self.out_addr & 0xFFFFFFFF, self.w_addr & 0xFFFFFFFF,
            self.b_addr & 0xFFFFFFFF,
            self.c_in & 0xFFFF, self.c_out & 0xFFFF,
            self.h_in & 0xFFFF, self.w_in & 0xFFFF,
            self.h_out & 0xFFFF, self.w_out & 0xFFFF,
            self.kh & 0xFF, self.kw & 0xFF,
            self.stride_h & 0xFF, self.stride_w & 0xFF,
            self.pad_top & 0xFF, self.pad_bottom & 0xFF,
            self.pad_left & 0xFF, self.pad_right & 0xFF,
            self.ic_tile_size & 0xFF, self.post_shift & 0xFF,
            self.leaky_alpha_q,
            self.a_scale_m, self.b_scale_m,
            self.a_scale_s, self.b_scale_s,
            self.out_zp, self.out_scale_s,
            self.reserved0 & 0xFFFFFFFF, self.reserved1 & 0xFFFFFFFF,
            self.reserved2 & 0xFFFFFFFF,
        )

    @classmethod
    def unpack(cls, buf: bytes) -> "LayerCfg":
        if len(buf) < LAYER_CFG_SIZE:
            raise ValueError(f"LayerCfg buffer {len(buf)} < {LAYER_CFG_SIZE}")
        vals = struct.unpack(LAYER_CFG_FMT, buf[:LAYER_CFG_SIZE])
        return cls(*vals)


def pack_layer_cfg(cfg: LayerCfg) -> bytes:
    return cfg.pack()


def unpack_layer_cfg(buf: bytes) -> LayerCfg:
    return LayerCfg.unpack(buf)


# =============================================================================
# CRC32 — IEEE 802.3 (el mismo que usa zlib)
# =============================================================================
def crc32(data: bytes) -> int:
    """CRC32 estándar (IEEE 802.3 / Ethernet). Devuelve int de 32 bits."""
    return zlib.crc32(data) & 0xFFFFFFFF


# =============================================================================
# Helpers para mensajes
# =============================================================================
def pack_message(opcode: int, tag: int, payload: bytes,
                 flags: int = 0) -> bytes:
    """Serializa un mensaje completo: header + payload."""
    hdr = Header(opcode=opcode, flags=flags, tag=tag,
                 payload_len=len(payload))
    return hdr.pack() + payload


# =============================================================================
# Safe DDR ranges (espejo de eth_addr_is_safe en C)
# =============================================================================
DDR_SAFE_RANGES = [
    (0x10000000, 0x10FFFFFF),   # buffers DPU + mailbox + cfg array + heads
    (0x11000000, 0x1FFFFFFF),   # activation pool + weights + heads extra
]


def addr_is_safe(addr: int, length: int) -> bool:
    if length == 0:
        return False
    hi = addr + length - 1
    if hi < addr:       # overflow
        return False
    for lo, range_hi in DDR_SAFE_RANGES:
        if addr >= lo and hi <= range_hi:
            return True
    return False


# =============================================================================
# Direcciones fijas del mapa de memoria (acordadas en ETH_PROTOCOL_V1.md §4)
# =============================================================================
ADDR_INPUT        = 0x10000000
ADDR_MAILBOX      = 0x10100000
ADDR_CFG_ARRAY    = 0x11000000   # 255 × LAYER_CFG_SIZE = 18360 B
ADDR_WEIGHTS_BASE = 0x12000000
ADDR_ACTIV_POOL   = 0x16000000
ADDR_RESERVED     = 0x1C000000

CFG_ARRAY_BYTES = 255 * LAYER_CFG_SIZE  # 18360


def cfg_slot_addr(layer_idx: int) -> int:
    """Dirección del slot del layer_cfg_t[layer_idx] en DDR."""
    if not 0 <= layer_idx < 255:
        raise ValueError(f"layer_idx fuera de rango: {layer_idx}")
    return ADDR_CFG_ARRAY + layer_idx * LAYER_CFG_SIZE
