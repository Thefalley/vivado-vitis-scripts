"""MockServer — simulador del ARM en Python puro.

Implementa el protocolo V1 completo en loopback TCP. Mantiene estado interno
idéntico al que tendrá el ARM (g_state + DDR virtual), así podemos validar
cliente y protocolo antes de tocar firmware.

Uso:

    from p18eth import MockServer, DpuHost

    with MockServer(port=17001) as srv:   # arranca thread en background
        with DpuHost("127.0.0.1", port=17001) as h:
            h.hello()
            h.exec_layer(0)

El mock NO ejecuta el DPU real. Por defecto devuelve output_bytes = zeros;
se puede inyectar un hook `fake_exec(cfg) -> bytes` para devolver una
activación concreta (p.ej. la del ONNX de referencia).
"""
from __future__ import annotations

import logging
import socket
import struct
import threading
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional

from .proto import (
    PROTO_VERSION,
    Opcode, RspOp, Kind, OpType, Dtype, Err, Flags,
    HEADER_FMT, HEADER_SIZE,
    DATA_HDR_SIZE, LAYER_CFG_SIZE,
    Header, DataHdr, LayerCfg,
    crc32, pack_message, addr_is_safe,
    ADDR_CFG_ARRAY,
)

log = logging.getLogger("p18eth.mock")


# =============================================================================
# Estado interno del mock (espejo de g_state en C)
# =============================================================================
@dataclass
class LayerState:
    cfg_set:  bool = False
    w_loaded: bool = False
    b_loaded: bool = False
    input_ok: bool = False
    executed: bool = False
    last_err: int  = 0


@dataclass
class GlobalState:
    proto_ver: int = PROTO_VERSION
    dpu_initialized: bool = False
    input_loaded: bool = False
    total_bytes_written: int = 0
    total_crc_errors: int = 0
    layer: List[LayerState] = field(
        default_factory=lambda: [LayerState() for _ in range(255)]
    )

    def reset(self) -> None:
        self.__init__()


# =============================================================================
# DDR virtual: dict[addr_offset] -> bytes
# =============================================================================
class VirtualDDR:
    """DDR como diccionario de páginas para evitar alocar 512 MB contiguos."""

    PAGE = 1 << 16  # 64 KB por página

    def __init__(self) -> None:
        self._pages: Dict[int, bytearray] = {}

    def _page(self, addr: int) -> bytearray:
        p = addr // self.PAGE
        if p not in self._pages:
            self._pages[p] = bytearray(self.PAGE)
        return self._pages[p]

    def write(self, addr: int, data: bytes) -> None:
        off = 0
        while off < len(data):
            page_start = (addr + off) // self.PAGE
            page_off = (addr + off) % self.PAGE
            remaining_in_page = self.PAGE - page_off
            n = min(len(data) - off, remaining_in_page)
            page = self._page((addr + off) & ~(self.PAGE - 1))
            page[page_off : page_off + n] = data[off : off + n]
            off += n

    def read(self, addr: int, length: int) -> bytes:
        out = bytearray(length)
        off = 0
        while off < length:
            page_off = (addr + off) % self.PAGE
            remaining_in_page = self.PAGE - page_off
            n = min(length - off, remaining_in_page)
            page = self._page((addr + off) & ~(self.PAGE - 1))
            out[off : off + n] = page[page_off : page_off + n]
            off += n
        return bytes(out)


# =============================================================================
# Tipo del hook de ejecución: recibe cfg + inputs, devuelve output_bytes
# =============================================================================
ExecHook = Callable[[LayerCfg, "MockServer"], bytes]


def _default_exec(cfg: LayerCfg, srv: "MockServer") -> bytes:
    """Hook por defecto: output = zeros del tamaño correcto."""
    out_bytes = _estimated_output_size(cfg)
    return bytes(out_bytes)


def _estimated_output_size(cfg: LayerCfg) -> int:
    """Calcula el tamaño en bytes de la activación de salida (int8, CHW)."""
    return max(cfg.c_out * cfg.h_out * cfg.w_out, 1)


# =============================================================================
# MockServer
# =============================================================================
class MockServer:
    """Server TCP mock. Se arranca con `start()` (o context manager).

    Parámetros:
        host: interfaz a bindear (default loopback).
        port: puerto TCP.
        exec_hook: función llamada en CMD_EXEC_LAYER; recibe cfg y retorna
                   los bytes de la activación de salida.
        strict: si True, rechaza EXEC_LAYER sin prereqs. Default True.
    """

    def __init__(self,
                 host: str = "127.0.0.1",
                 port: int = 17001,
                 exec_hook: Optional[ExecHook] = None,
                 strict: bool = True,
                 verbose: bool = False) -> None:
        self.host = host
        self.port = port
        self.exec_hook = exec_hook or _default_exec
        self.strict = strict
        self.verbose = verbose

        self.state = GlobalState()
        self.ddr = VirtualDDR()
        self.cfgs: Dict[int, LayerCfg] = {}

        self._sock: Optional[socket.socket] = None
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self._clients_seen = 0
        self._log: List[str] = []

    # ---- lifecycle ----
    def start(self) -> "MockServer":
        if self._sock is not None:
            raise RuntimeError("MockServer already started")
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind((self.host, self.port))
        self._sock.listen(1)
        self._sock.settimeout(0.2)
        self._stop.clear()
        self._thread = threading.Thread(target=self._accept_loop,
                                        daemon=True,
                                        name="MockServer")
        self._thread.start()
        self._note(f"MockServer listening on {self.host}:{self.port}")
        return self

    def stop(self) -> None:
        self._stop.set()
        try:
            if self._sock:
                self._sock.close()
        except OSError:
            pass
        if self._thread:
            self._thread.join(timeout=2.0)
        self._thread = None
        self._sock = None

    def __enter__(self) -> "MockServer":
        return self.start()

    def __exit__(self, *a) -> None:
        self.stop()

    # ---- state helpers ----
    def reset(self) -> None:
        self.state.reset()
        self.ddr = VirtualDDR()
        self.cfgs.clear()

    def get_log(self) -> List[str]:
        return list(self._log)

    # ---- internal logging ----
    def _note(self, msg: str) -> None:
        self._log.append(msg)
        if self.verbose:
            print(f"[mock] {msg}", flush=True)

    # ---- accept loop ----
    def _accept_loop(self) -> None:
        while not self._stop.is_set():
            try:
                conn, addr = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self._clients_seen += 1
            self._note(f"client connected from {addr}")
            try:
                self._serve(conn)
            except Exception as e:          # noqa: BLE001
                self._note(f"error serving client: {e}")
            finally:
                try:
                    conn.close()
                except OSError:
                    pass
                self._note("client disconnected")

    # ---- per-connection handler ----
    def _serve(self, conn: socket.socket) -> None:
        conn.settimeout(5.0)
        while not self._stop.is_set():
            hdr_buf = self._recv_exact(conn, HEADER_SIZE)
            if hdr_buf is None:
                return
            hdr = Header.unpack(hdr_buf)
            payload = b""
            if hdr.payload_len > 0:
                payload = self._recv_exact(conn, hdr.payload_len)
                if payload is None:
                    return

            try:
                self._dispatch(conn, hdr, payload)
            except _ProtocolError as e:
                self._send_error(conn, hdr.tag, e.code, e.aux)

            if hdr.opcode == Opcode.CLOSE:
                return

    def _recv_exact(self, conn: socket.socket, n: int) -> Optional[bytes]:
        buf = bytearray(n)
        got = 0
        while got < n:
            try:
                r = conn.recv_into(memoryview(buf)[got:], n - got)
            except (socket.timeout, OSError):
                return None
            if r == 0:
                return None
            got += r
        return bytes(buf)

    # ---- dispatch ----
    def _dispatch(self, conn: socket.socket, hdr: Header, payload: bytes) -> None:
        op = hdr.opcode
        self._note(f"RX op=0x{op:02x} tag={hdr.tag} plen={hdr.payload_len}")

        if op == Opcode.HELLO:
            self._h_hello(conn, hdr, payload)
        elif op == Opcode.PING:
            self._send(conn, RspOp.PONG, hdr.tag, b"P_18 OK\0")
        elif op == Opcode.WRITE_RAW:
            self._h_write_raw(conn, hdr, payload)
        elif op == Opcode.READ_RAW:
            self._h_read_raw(conn, hdr, payload)
        elif op == Opcode.WRITE_INPUT:
            self._h_write_typed(conn, hdr, payload, expected_kind=Kind.INPUT)
        elif op == Opcode.WRITE_WEIGHTS:
            self._h_write_typed(conn, hdr, payload, expected_kind=Kind.WEIGHTS)
        elif op == Opcode.WRITE_BIAS:
            self._h_write_typed(conn, hdr, payload, expected_kind=Kind.BIAS)
        elif op == Opcode.WRITE_ACTIVATION_IN:
            self._h_write_typed(conn, hdr, payload,
                                expected_kind=Kind.ACTIVATION_IN)
        elif op == Opcode.WRITE_CFG:
            self._h_write_cfg(conn, hdr, payload)
        elif op == Opcode.EXEC_LAYER:
            self._h_exec_layer(conn, hdr, payload)
        elif op == Opcode.READ_ACTIVATION:
            self._h_read_activation(conn, hdr, payload)
        elif op == Opcode.GET_STATE:
            self._h_get_state(conn, hdr)
        elif op == Opcode.RESET_STATE:
            self.reset()
            self._send_ack(conn, hdr.tag, Err.OK)
        elif op == Opcode.DPU_INIT:
            self.state.dpu_initialized = True
            self._send_ack(conn, hdr.tag, Err.OK)
        elif op == Opcode.DPU_RESET:
            self._send_ack(conn, hdr.tag, Err.OK)
        elif op == Opcode.CLOSE:
            pass  # caller returns
        else:
            raise _ProtocolError(Err.INVALID_CMD, op)

    # ---- handlers ----
    def _h_hello(self, conn, hdr, payload):
        if len(payload) < 16:
            raise _ProtocolError(Err.INVALID_CMD, 0)
        proto_ver, cfg_size, hdr_size, flags = struct.unpack(
            "<IIII", payload[:16])
        if (proto_ver != PROTO_VERSION or
                cfg_size != LAYER_CFG_SIZE or
                hdr_size != DATA_HDR_SIZE):
            self._send_error(conn, hdr.tag, Err.PROTO_VERSION, proto_ver)
            return
        extra = struct.pack("<IIII", PROTO_VERSION, LAYER_CFG_SIZE,
                            DATA_HDR_SIZE, 0)
        self._send_ack(conn, hdr.tag, Err.OK, extra)

    def _h_write_raw(self, conn, hdr, payload):
        if len(payload) < 4:
            raise _ProtocolError(Err.INVALID_CMD, 0)
        addr = struct.unpack("<I", payload[:4])[0]
        data = payload[4:]
        if not addr_is_safe(addr, len(data)):
            raise _ProtocolError(Err.BAD_ADDR, addr)
        self.ddr.write(addr, data)
        self.state.total_bytes_written += len(data)
        extra = struct.pack("<II", len(data), 0)
        self._send_ack(conn, hdr.tag, Err.OK, extra)

    def _h_read_raw(self, conn, hdr, payload):
        if len(payload) < 8:
            raise _ProtocolError(Err.INVALID_CMD, 0)
        addr, length = struct.unpack("<II", payload[:8])
        if not addr_is_safe(addr, length):
            raise _ProtocolError(Err.BAD_ADDR, addr)
        data = self.ddr.read(addr, length)
        self._send(conn, RspOp.DATA, hdr.tag, data)

    def _parse_typed_payload(self, payload: bytes, expected_kind: int):
        if len(payload) < DATA_HDR_SIZE:
            raise _ProtocolError(Err.LEN_MISMATCH, len(payload))
        dh = DataHdr.unpack(payload[:DATA_HDR_SIZE])
        data = payload[DATA_HDR_SIZE:]

        if dh.kind != expected_kind:
            raise _ProtocolError(Err.KIND_MISMATCH, dh.kind)
        if dh.kind not in (k for k in Kind):
            raise _ProtocolError(Err.BAD_KIND, dh.kind)
        if dh.dtype not in (d for d in Dtype):
            raise _ProtocolError(Err.BAD_DTYPE, dh.dtype)
        if dh.expected_len != len(data):
            raise _ProtocolError(Err.LEN_MISMATCH,
                                 dh.expected_len - len(data))
        # layer_idx: 0xFFFF para datos globales (INPUT, CFG array completo)
        if dh.layer_idx != 0xFFFF and dh.layer_idx >= 255:
            raise _ProtocolError(Err.BAD_LAYER, dh.layer_idx)
        if not addr_is_safe(dh.ddr_addr, dh.expected_len):
            raise _ProtocolError(Err.BAD_ADDR, dh.ddr_addr)

        # CRC check
        calc = crc32(data)
        if calc != dh.crc32:
            self.state.total_crc_errors += 1
            raise _ProtocolError(Err.CRC, calc)

        return dh, data

    def _h_write_typed(self, conn, hdr, payload, expected_kind: int):
        dh, data = self._parse_typed_payload(payload, expected_kind)
        self.ddr.write(dh.ddr_addr, data)
        self.state.total_bytes_written += len(data)

        # actualizar g_state según kind
        if expected_kind == Kind.WEIGHTS:
            self.state.layer[dh.layer_idx].w_loaded = True
        elif expected_kind == Kind.BIAS:
            self.state.layer[dh.layer_idx].b_loaded = True
        elif expected_kind == Kind.INPUT:
            self.state.input_loaded = True
            # el layer 0 tiene su input listo
            self.state.layer[0].input_ok = True
        elif expected_kind == Kind.ACTIVATION_IN:
            self.state.layer[dh.layer_idx].input_ok = True

        extra = struct.pack("<II", len(data), dh.crc32)
        self._send_ack(conn, hdr.tag, Err.OK, extra)

    def _h_write_cfg(self, conn, hdr, payload):
        dh, data = self._parse_typed_payload(payload, Kind.LAYER_CFG)
        # data puede ser un solo cfg (72 B) o el array completo (255*72)
        if len(data) == LAYER_CFG_SIZE:
            cfg = LayerCfg.unpack(data)
            idx = cfg.layer_idx if dh.layer_idx == 0xFFFF else dh.layer_idx
            self.cfgs[idx] = cfg
            self.ddr.write(dh.ddr_addr, data)
            self.state.layer[idx].cfg_set = True
        elif len(data) == LAYER_CFG_SIZE * 255:
            for i in range(255):
                chunk = data[i * LAYER_CFG_SIZE : (i + 1) * LAYER_CFG_SIZE]
                cfg = LayerCfg.unpack(chunk)
                self.cfgs[i] = cfg
                self.state.layer[i].cfg_set = True
            self.ddr.write(dh.ddr_addr, data)
        else:
            raise _ProtocolError(Err.LEN_MISMATCH, len(data))

        extra = struct.pack("<II", len(data), dh.crc32)
        self._send_ack(conn, hdr.tag, Err.OK, extra)

    def _h_exec_layer(self, conn, hdr, payload):
        if len(payload) < 4:
            raise _ProtocolError(Err.INVALID_CMD, 0)
        layer_idx, flags = struct.unpack("<HH", payload[:4])
        if layer_idx >= 255:
            raise _ProtocolError(Err.BAD_LAYER, layer_idx)
        st = self.state.layer[layer_idx]
        if not st.cfg_set:
            raise _ProtocolError(Err.NOT_CONFIGURED, layer_idx)

        cfg = self.cfgs.get(layer_idx)
        if cfg is None:
            raise _ProtocolError(Err.NOT_CONFIGURED, layer_idx)

        if self.strict:
            missing = 0
            if cfg.op_type == OpType.CONV:
                if not st.w_loaded:  missing |= 0x01
                if not st.b_loaded:  missing |= 0x02
                if not st.input_ok:  missing |= 0x04
            elif cfg.op_type in (OpType.LEAKY, OpType.POOL_MAX,
                                 OpType.RESIZE):
                if not st.input_ok:  missing |= 0x04
            elif cfg.op_type == OpType.ELEM_ADD:
                if not st.input_ok:  missing |= 0x04
                # el segundo operando debe estar producido; lo aproximamos
                # verificando que haya bytes en in_b_addr (placeholder)
            elif cfg.op_type == OpType.CONCAT:
                if not st.input_ok:  missing |= 0x04
            if missing != 0:
                raise _ProtocolError(Err.MISSING_DATA, missing)

        # "Ejecutar" via hook
        out_bytes = self.exec_hook(cfg, self)
        self.ddr.write(cfg.out_addr, out_bytes)
        out_crc = crc32(out_bytes)
        self.state.layer[layer_idx].executed = True

        # la capa siguiente (por defecto) tendrá su input listo
        # (para CONCAT / residual el PC debe marcarlo explícitamente vía cfg)
        if layer_idx + 1 < 255:
            self.state.layer[layer_idx + 1].input_ok = True

        cycles = max(cfg.h_out * cfg.w_out * cfg.c_out, 1000)  # fake
        extra = struct.pack("<III", cycles, out_crc, len(out_bytes))
        self._send_ack(conn, hdr.tag, Err.OK, extra)

    def _h_read_activation(self, conn, hdr, payload):
        if len(payload) < 8:
            raise _ProtocolError(Err.INVALID_CMD, 0)
        addr, length = struct.unpack("<II", payload[:8])
        if not addr_is_safe(addr, length):
            raise _ProtocolError(Err.BAD_ADDR, addr)
        data = self.ddr.read(addr, length)
        dh = DataHdr(
            layer_idx=0xFFFF,
            kind=Kind.ACTIVATION_OUT,
            dtype=Dtype.INT8,
            ddr_addr=addr,
            expected_len=length,
            crc32=crc32(data),
        )
        self._send(conn, RspOp.DATA, hdr.tag, dh.pack() + data)

    def _h_get_state(self, conn, hdr):
        # Serializa: u32 n_layers + 255 × layer_state_t (1 byte cada uno)
        body = struct.pack("<I", 255)
        for st in self.state.layer:
            flags = ((1 if st.cfg_set else 0) << 0
                     | (1 if st.w_loaded else 0) << 1
                     | (1 if st.b_loaded else 0) << 2
                     | (1 if st.input_ok else 0) << 3
                     | (1 if st.executed else 0) << 4
                     | (st.last_err & 0x7) << 5)
            body += bytes([flags])
        self._send_ack(conn, hdr.tag, Err.OK, body)

    # ---- send helpers ----
    def _send(self, conn: socket.socket, op: int, tag: int,
              payload: bytes) -> None:
        msg = pack_message(op, tag, payload)
        conn.sendall(msg)
        self._note(f"TX op=0x{op:02x} tag={tag} plen={len(payload)}")

    def _send_ack(self, conn: socket.socket, tag: int,
                  status: int, extra: bytes = b"") -> None:
        payload = struct.pack("<I", status) + extra
        self._send(conn, RspOp.ACK, tag, payload)

    def _send_error(self, conn: socket.socket, tag: int,
                    code: int, aux: int) -> None:
        payload = struct.pack("<II", code, aux & 0xFFFFFFFF)
        self._send(conn, RspOp.ERROR, tag, payload)


class _ProtocolError(Exception):
    def __init__(self, code: int, aux: int = 0):
        self.code = int(code)
        self.aux = int(aux) & 0xFFFFFFFF
