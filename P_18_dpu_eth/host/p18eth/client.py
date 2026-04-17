"""DpuHost — cliente Python del protocolo V1.

Habla el mismo protocolo contra el MockServer (loopback) o contra el ARM real
(ZedBoard en 192.168.1.10:7001). El único cambio entre ambos entornos es el
host/port pasado al constructor.

Ejemplo:

    with DpuHost("127.0.0.1", port=17001) as h:   # mock
        h.hello()
        h.write_input(addr=0x10000000, data=image_bytes)
        h.write_weights(layer_idx=0, addr=0x12000000, data=w0_bytes)
        h.write_cfg(cfg)
        status, cycles, out_crc, out_len = h.exec_layer(0)
"""
from __future__ import annotations

import socket
import struct
from dataclasses import dataclass
from typing import Iterable, List, Optional, Tuple

from .proto import (
    PROTO_VERSION,
    Opcode, RspOp, Kind, OpType, Dtype, Err, Flags,
    HEADER_SIZE, DATA_HDR_SIZE, LAYER_CFG_SIZE,
    Header, DataHdr, LayerCfg,
    crc32, pack_message, pack_data_hdr,
    ADDR_CFG_ARRAY, cfg_slot_addr,
)


class ProtocolError(RuntimeError):
    """Error devuelto por el peer (RSP_ERROR)."""

    def __init__(self, code: int, aux: int, opcode: int, tag: int):
        self.code = code
        self.aux = aux
        self.opcode = opcode
        self.tag = tag
        name = Err(code).name if code in (e.value for e in Err) else "UNKNOWN"
        super().__init__(
            f"peer ERROR code=0x{code:02x} ({name}) "
            f"aux=0x{aux:08x} after op=0x{opcode:02x} tag={tag}"
        )


@dataclass
class ExecResult:
    status: int
    cycles: int
    out_crc: int
    out_bytes: int


class DpuHost:
    """Cliente alto nivel del protocolo ETH V1.

    Thread-unsafe; usa una instancia por hilo.
    """

    def __init__(self,
                 host: str = "192.168.1.10",
                 port: int = 7001,
                 timeout: float = 60.0,
                 send_chunk: int = 1 << 20,    # 1 MB para WRITE
                 recv_chunk: int = 1 << 20) -> None:
        self.host = host
        self.port = port
        self.timeout = timeout
        self.send_chunk = send_chunk
        self.recv_chunk = recv_chunk

        self._sock: Optional[socket.socket] = None
        self._tag = 0

    # =========================================================================
    # Conexión
    # =========================================================================
    def connect(self) -> None:
        if self._sock is not None:
            return
        self._sock = socket.create_connection((self.host, self.port),
                                              timeout=self.timeout)
        self._sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self._sock.settimeout(self.timeout)

    def close(self) -> None:
        if self._sock is None:
            return
        try:
            self._send_header(Opcode.CLOSE, 0)
        except OSError:
            pass
        try:
            self._sock.close()
        except OSError:
            pass
        self._sock = None

    def __enter__(self) -> "DpuHost":
        self.connect()
        return self

    def __exit__(self, *a) -> None:
        self.close()

    # =========================================================================
    # Framing low-level
    # =========================================================================
    def _next_tag(self) -> int:
        self._tag = (self._tag + 1) & 0xFFFF
        return self._tag

    def _send_header(self, opcode: int, payload_len: int,
                     flags: int = 0, tag: Optional[int] = None) -> int:
        t = tag if tag is not None else self._next_tag()
        self._sock.sendall(Header(opcode, flags, t, payload_len).pack())
        return t

    def _send_all(self, data: bytes) -> None:
        self._sock.sendall(data)

    def _recv_exact(self, n: int) -> bytes:
        buf = bytearray(n)
        mv = memoryview(buf)
        got = 0
        while got < n:
            r = self._sock.recv_into(mv[got:], n - got)
            if r == 0:
                raise ConnectionError(
                    f"server closed after {got}/{n} bytes")
            got += r
        return bytes(buf)

    def _recv_header(self) -> Header:
        return Header.unpack(self._recv_exact(HEADER_SIZE))

    def _expect_ack(self, sent_op: int, sent_tag: int) -> Tuple[int, bytes]:
        h = self._recv_header()
        if h.tag != sent_tag:
            raise RuntimeError(
                f"tag mismatch: sent {sent_tag}, got {h.tag}")
        payload = self._recv_exact(h.payload_len) if h.payload_len else b""
        if h.opcode == RspOp.ERROR:
            code, aux = struct.unpack("<II", payload[:8])
            raise ProtocolError(code, aux, sent_op, sent_tag)
        if h.opcode != RspOp.ACK:
            raise RuntimeError(f"unexpected opcode 0x{h.opcode:02x}")
        if h.payload_len < 4:
            raise RuntimeError("ACK payload < 4 bytes (no status)")
        status = struct.unpack("<I", payload[:4])[0]
        return status, payload[4:]

    # =========================================================================
    # API de alto nivel
    # =========================================================================
    def hello(self) -> dict:
        """Handshake obligatorio tras connect().

        Devuelve dict con versión e info del peer. Lanza ProtocolError si el
        peer no coincide en versión o tamaños de struct.
        """
        self.connect()
        payload = struct.pack("<IIII", PROTO_VERSION, LAYER_CFG_SIZE,
                              DATA_HDR_SIZE, 0)
        tag = self._send_header(Opcode.HELLO, len(payload))
        self._send_all(payload)
        status, extra = self._expect_ack(Opcode.HELLO, tag)
        if status != Err.OK:
            raise RuntimeError(f"hello status=0x{status:08x}")
        if len(extra) < 16:
            raise RuntimeError("hello ACK extra < 16")
        proto, cfg_sz, hdr_sz, caps = struct.unpack("<IIII", extra[:16])
        return {"proto_ver": proto, "layer_cfg_size": cfg_sz,
                "data_hdr_size": hdr_sz, "capabilities": caps}

    def ping(self) -> bytes:
        self.connect()
        tag = self._send_header(Opcode.PING, 0)
        h = self._recv_header()
        if h.tag != tag:
            raise RuntimeError("ping tag mismatch")
        if h.opcode != RspOp.PONG:
            raise RuntimeError(f"ping: opcode 0x{h.opcode:02x}")
        return self._recv_exact(h.payload_len) if h.payload_len else b""

    # ---- WRITE_RAW / READ_RAW (canal legacy) ----
    def write_raw(self, addr: int, data: bytes) -> int:
        self.connect()
        off = 0
        while off < len(data):
            blk = data[off:off + self.send_chunk]
            payload = struct.pack("<I", addr + off) + bytes(blk)
            tag = self._send_header(Opcode.WRITE_RAW, len(payload))
            self._send_all(payload)
            status, _ = self._expect_ack(Opcode.WRITE_RAW, tag)
            if status != Err.OK:
                raise RuntimeError(f"write_raw status=0x{status:08x}")
            off += len(blk)
        return len(data)

    def read_raw(self, addr: int, length: int) -> bytes:
        self.connect()
        out = bytearray()
        remaining = length
        cur = addr
        while remaining > 0:
            n = min(remaining, self.recv_chunk)
            payload = struct.pack("<II", cur, n)
            tag = self._send_header(Opcode.READ_RAW, len(payload))
            self._send_all(payload)
            h = self._recv_header()
            if h.tag != tag:
                raise RuntimeError("read_raw tag mismatch")
            body = self._recv_exact(h.payload_len) if h.payload_len else b""
            if h.opcode == RspOp.ERROR:
                code, aux = struct.unpack("<II", body[:8])
                raise ProtocolError(code, aux, Opcode.READ_RAW, tag)
            if h.opcode != RspOp.DATA:
                raise RuntimeError(f"read_raw op 0x{h.opcode:02x}")
            out.extend(body)
            cur += len(body)
            remaining -= len(body)
        return bytes(out)

    # ---- WRITE_* typed ----
    def _write_typed(self, opcode: int, kind: int, layer_idx: int,
                     addr: int, data: bytes, dtype: int = Dtype.INT8) -> int:
        """Envía un bloque tipado con data_hdr_t + bytes."""
        self.connect()
        off = 0
        total = len(data)
        while off < total:
            blk = bytes(data[off:off + self.send_chunk])
            dh_bytes = pack_data_hdr(
                layer_idx=layer_idx,
                kind=kind,
                dtype=dtype,
                ddr_addr=addr + off,
                data=blk,
            )
            payload = dh_bytes + blk
            tag = self._send_header(opcode, len(payload),
                                    flags=Flags.HAS_DATA_HDR)
            self._send_all(payload)
            status, extra = self._expect_ack(opcode, tag)
            if status != Err.OK:
                raise RuntimeError(
                    f"write_typed op=0x{opcode:02x} status=0x{status:08x}")
            off += len(blk)
        return total

    def write_input(self, addr: int, data: bytes) -> int:
        return self._write_typed(Opcode.WRITE_INPUT, Kind.INPUT,
                                 layer_idx=0xFFFF, addr=addr, data=data,
                                 dtype=Dtype.UINT8)

    def write_weights(self, layer_idx: int, addr: int,
                      data: bytes) -> int:
        return self._write_typed(Opcode.WRITE_WEIGHTS, Kind.WEIGHTS,
                                 layer_idx=layer_idx, addr=addr, data=data,
                                 dtype=Dtype.INT8)

    def write_bias(self, layer_idx: int, addr: int, data: bytes) -> int:
        return self._write_typed(Opcode.WRITE_BIAS, Kind.BIAS,
                                 layer_idx=layer_idx, addr=addr, data=data,
                                 dtype=Dtype.INT32)

    def write_activation_in(self, layer_idx: int, addr: int,
                            data: bytes) -> int:
        return self._write_typed(Opcode.WRITE_ACTIVATION_IN,
                                 Kind.ACTIVATION_IN,
                                 layer_idx=layer_idx, addr=addr, data=data,
                                 dtype=Dtype.INT8)

    def write_cfg(self, cfg: LayerCfg,
                  addr: Optional[int] = None) -> int:
        """Escribe un único cfg (72 B) en el slot que le corresponda.

        Si `addr` es None, usa `cfg_slot_addr(cfg.layer_idx)`.
        """
        self.connect()
        data = cfg.pack()
        if addr is None:
            addr = cfg_slot_addr(cfg.layer_idx)
        return self._write_typed(Opcode.WRITE_CFG, Kind.LAYER_CFG,
                                 layer_idx=cfg.layer_idx, addr=addr,
                                 data=data, dtype=Dtype.INT32)

    def write_cfg_array(self, cfgs: Iterable[LayerCfg],
                        addr: int = ADDR_CFG_ARRAY) -> int:
        """Escribe el array completo de 255 cfgs de una sola vez."""
        data = bytearray()
        for cfg in cfgs:
            packed = cfg.pack()
            if len(packed) != LAYER_CFG_SIZE:
                raise RuntimeError("cfg.pack() tamaño incorrecto")
            data.extend(packed)
        if len(data) != LAYER_CFG_SIZE * 255:
            raise RuntimeError(
                f"esperado {LAYER_CFG_SIZE*255} B, recibido {len(data)}")
        return self._write_typed(Opcode.WRITE_CFG, Kind.LAYER_CFG,
                                 layer_idx=0xFFFF, addr=addr,
                                 data=bytes(data), dtype=Dtype.INT32)

    # ---- EXEC ----
    def exec_layer(self, layer_idx: int,
                   flags: int = 0) -> ExecResult:
        self.connect()
        payload = struct.pack("<HH", layer_idx, flags)
        tag = self._send_header(Opcode.EXEC_LAYER, len(payload))
        self._send_all(payload)
        status, extra = self._expect_ack(Opcode.EXEC_LAYER, tag)
        if len(extra) < 12:
            raise RuntimeError(f"EXEC_LAYER extra={len(extra)} B")
        cycles, out_crc, out_bytes = struct.unpack("<III", extra[:12])
        return ExecResult(status=status, cycles=cycles,
                          out_crc=out_crc, out_bytes=out_bytes)

    # ---- READ_ACTIVATION ----
    def read_activation(self, addr: int, length: int) -> Tuple[bytes, int]:
        """Lee una activación. Devuelve (bytes, crc32).

        El ARM envía un data_hdr_t antes de los bytes; aquí lo parseamos
        y verificamos el CRC.
        """
        self.connect()
        payload = struct.pack("<II", addr, length)
        tag = self._send_header(Opcode.READ_ACTIVATION, len(payload))
        self._send_all(payload)
        h = self._recv_header()
        if h.tag != tag:
            raise RuntimeError("read_activation tag mismatch")
        body = self._recv_exact(h.payload_len) if h.payload_len else b""
        if h.opcode == RspOp.ERROR:
            code, aux = struct.unpack("<II", body[:8])
            raise ProtocolError(code, aux, Opcode.READ_ACTIVATION, tag)
        if h.opcode != RspOp.DATA:
            raise RuntimeError(f"op 0x{h.opcode:02x}")
        if len(body) < DATA_HDR_SIZE:
            raise RuntimeError("RSP_DATA sin data_hdr_t")
        dh = DataHdr.unpack(body[:DATA_HDR_SIZE])
        data = body[DATA_HDR_SIZE:]
        if len(data) != dh.expected_len:
            raise RuntimeError(
                f"len mismatch: {len(data)} vs {dh.expected_len}")
        calc = crc32(data)
        if calc != dh.crc32:
            raise RuntimeError(
                f"CRC mismatch: got 0x{dh.crc32:08x}, calc 0x{calc:08x}")
        return data, dh.crc32

    # ---- GET_STATE ----
    def get_state(self) -> List[dict]:
        """Devuelve una lista con el estado de cada layer."""
        self.connect()
        tag = self._send_header(Opcode.GET_STATE, 0)
        status, extra = self._expect_ack(Opcode.GET_STATE, tag)
        if status != Err.OK:
            raise RuntimeError(f"get_state status=0x{status:08x}")
        if len(extra) < 4:
            raise RuntimeError("state payload < 4 B")
        n = struct.unpack("<I", extra[:4])[0]
        states = []
        for i in range(n):
            b = extra[4 + i]
            states.append({
                "layer_idx": i,
                "cfg_set":  bool(b & (1 << 0)),
                "w_loaded": bool(b & (1 << 1)),
                "b_loaded": bool(b & (1 << 2)),
                "input_ok": bool(b & (1 << 3)),
                "executed": bool(b & (1 << 4)),
                "last_err": (b >> 5) & 0x7,
            })
        return states

    # ---- misc ----
    def reset_state(self) -> None:
        self.connect()
        tag = self._send_header(Opcode.RESET_STATE, 0)
        status, _ = self._expect_ack(Opcode.RESET_STATE, tag)
        if status != Err.OK:
            raise RuntimeError(f"reset_state status=0x{status:08x}")

    def dpu_init(self) -> None:
        self.connect()
        tag = self._send_header(Opcode.DPU_INIT, 0)
        status, _ = self._expect_ack(Opcode.DPU_INIT, tag)
        if status != Err.OK:
            raise RuntimeError(f"dpu_init status=0x{status:08x}")

    def dpu_reset(self) -> None:
        self.connect()
        tag = self._send_header(Opcode.DPU_RESET, 0)
        status, _ = self._expect_ack(Opcode.DPU_RESET, tag)
        if status != Err.OK:
            raise RuntimeError(f"dpu_reset status=0x{status:08x}")
