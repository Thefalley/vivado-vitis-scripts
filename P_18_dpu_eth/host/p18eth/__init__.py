"""p18eth — librería Python del protocolo Ethernet P_18 DPU↔PC.

Uso típico:

    from p18eth import DpuHost, MockServer
    from p18eth.proto import LayerCfg, Kind, OpType

    with DpuHost("192.168.1.10") as h:
        h.hello()
        h.write_input(0x10000000, image_bytes)
        h.write_weights(layer_idx=0, addr=0x12000000, data=w0)
        status, cycles, out_crc = h.exec_layer(0)

El contrato del protocolo está en `docs/ETH_PROTOCOL_V1.md`.
"""
from .proto import (
    PROTO_VERSION,
    Opcode, RspOp, Kind, OpType, Dtype, Err, Flags,
    HEADER_FMT, HEADER_SIZE,
    DATA_HDR_FMT, DATA_HDR_SIZE,
    LAYER_CFG_FMT, LAYER_CFG_SIZE,
    LayerCfg, DataHdr, Header,
    crc32, pack_layer_cfg, unpack_layer_cfg,
    pack_data_hdr, unpack_data_hdr,
    ADDR_INPUT, ADDR_MAILBOX, ADDR_CFG_ARRAY,
    ADDR_WEIGHTS_BASE, ADDR_ACTIV_POOL, ADDR_RESERVED,
    addr_is_safe, cfg_slot_addr,
)
from .client import DpuHost
from .mock_server import MockServer

__all__ = [
    "PROTO_VERSION",
    "Opcode", "RspOp", "Kind", "OpType", "Dtype", "Err", "Flags",
    "HEADER_FMT", "HEADER_SIZE",
    "DATA_HDR_FMT", "DATA_HDR_SIZE",
    "LAYER_CFG_FMT", "LAYER_CFG_SIZE",
    "LayerCfg", "DataHdr", "Header",
    "crc32", "pack_layer_cfg", "unpack_layer_cfg",
    "pack_data_hdr", "unpack_data_hdr",
    "ADDR_INPUT", "ADDR_MAILBOX", "ADDR_CFG_ARRAY",
    "ADDR_WEIGHTS_BASE", "ADDR_ACTIV_POOL", "ADDR_RESERVED",
    "addr_is_safe", "cfg_slot_addr",
    "DpuHost", "MockServer",
]
