#!/usr/bin/env python3
"""
yolov4_host.py -- Cliente TCP para cargar pesos/imagen y lanzar inferencia
                  YOLOv4 en la ZedBoard via P_18 DPU+Ethernet.

Implementa el protocolo descrito en docs/ETH_PROTOCOL.md.

Uso basico:
    host = DpuHost("192.168.1.10")
    host.ping()
    host.write_ddr(0x12000000, weights_blob)
    host.run_network(input_addr=0x10000000,
                     head0=0x18000000, head1=0x18100000, head2=0x18200000)
    head0 = host.read_ddr(0x18000000, size_h0)
"""

import socket
import struct
import time
import argparse
import sys
import os


# ==============================================================
# Protocolo
# ==============================================================
CMD_PING         = 0x01
CMD_WRITE_DDR    = 0x02
CMD_READ_DDR     = 0x03
CMD_EXEC_LAYER   = 0x04
CMD_RUN_NETWORK  = 0x05
CMD_DPU_INIT     = 0x06
CMD_DPU_RESET    = 0x07
CMD_CLOSE        = 0xFF

RSP_PONG    = 0x81
RSP_ACK     = 0x82
RSP_DATA    = 0x83
RSP_ERROR   = 0x8E

STATUS_OK                 = 0x00000000
STATUS_ERR_INVALID_CMD    = 0x00000001
STATUS_ERR_INVALID_ADDR   = 0x00000002
STATUS_ERR_DPU_TIMEOUT    = 0x00000003
STATUS_ERR_DPU_FAULT      = 0x00000004
STATUS_ERR_BUFFER_OVERRUN = 0x00000005

HEADER_FMT = "<BBHI"   # opcode(u8), flags(u8), tag(u16), payload_len(u32)
HEADER_SIZE = 8


# ==============================================================
# Cliente
# ==============================================================
class DpuHost:
    def __init__(self, host="192.168.1.10", port=7001, timeout=60.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.sock = None
        self.tag_ctr = 0

    # ---- connection ----
    def connect(self):
        if self.sock is not None:
            return
        self.sock = socket.create_connection((self.host, self.port),
                                             timeout=self.timeout)
        # TCP_NODELAY ayuda para latencia baja en comandos pequeños
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock.settimeout(self.timeout)

    def close(self):
        if self.sock is not None:
            try:
                self._send_header(CMD_CLOSE, 0)
            except OSError:
                pass
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()

    # ---- low-level framing ----
    def _next_tag(self):
        self.tag_ctr = (self.tag_ctr + 1) & 0xFFFF
        return self.tag_ctr

    def _send_header(self, opcode, payload_len, flags=0, tag=None):
        if tag is None:
            tag = self._next_tag()
        hdr = struct.pack(HEADER_FMT, opcode, flags, tag, payload_len)
        self.sock.sendall(hdr)
        return tag

    def _sendall(self, data):
        # data puede ser bytes o memoryview
        self.sock.sendall(data)

    def _recv_exact(self, n):
        buf = bytearray(n)
        mv = memoryview(buf)
        got = 0
        while got < n:
            r = self.sock.recv_into(mv[got:], n - got)
            if r == 0:
                raise ConnectionError(f"server closed after {got}/{n} bytes")
            got += r
        return bytes(buf)

    def _recv_header(self):
        hdr = self._recv_exact(HEADER_SIZE)
        opcode, flags, tag, plen = struct.unpack(HEADER_FMT, hdr)
        return opcode, flags, tag, plen

    def _expect_ack(self):
        op, _, _, plen = self._recv_header()
        if op == RSP_ERROR:
            payload = self._recv_exact(plen)
            err, aux = struct.unpack("<II", payload[:8])
            raise RuntimeError(f"server error code=0x{err:08x} aux=0x{aux:08x}")
        if op != RSP_ACK:
            raise RuntimeError(f"unexpected response opcode=0x{op:02x}")
        payload = self._recv_exact(plen) if plen > 0 else b""
        if plen < 4:
            raise RuntimeError("ACK payload < 4 bytes")
        status = struct.unpack("<I", payload[:4])[0]
        return status, payload[4:]

    # ---- commands ----
    def ping(self):
        """Return True on PONG."""
        self.connect()
        self._send_header(CMD_PING, 0)
        op, _, _, plen = self._recv_header()
        payload = self._recv_exact(plen) if plen > 0 else b""
        if op != RSP_PONG:
            raise RuntimeError(f"ping: unexpected opcode=0x{op:02x}")
        return payload

    def write_ddr(self, addr, data, chunk=1 << 20):
        """Escribe bytes arbitrarios a DDR[addr]. chunk=1MB por default."""
        self.connect()
        total = len(data)
        off = 0
        while off < total:
            blk = data[off:off + chunk]
            n = len(blk)
            payload = struct.pack("<I", addr + off) + bytes(blk)
            self._send_header(CMD_WRITE_DDR, len(payload))
            self._sendall(payload)
            status, _ = self._expect_ack()
            if status != STATUS_OK:
                raise RuntimeError(
                    f"write_ddr(addr=0x{addr+off:08x}, n={n}) status=0x{status:08x}")
            off += n
        return total

    def read_ddr(self, addr, length, chunk=1 << 20):
        """Lee N bytes de DDR[addr] -> bytes."""
        self.connect()
        out = bytearray()
        remaining = length
        cur = addr
        while remaining > 0:
            n = min(remaining, chunk)
            payload = struct.pack("<II", cur, n)
            self._send_header(CMD_READ_DDR, len(payload))
            self._sendall(payload)
            op, _, _, plen = self._recv_header()
            if op == RSP_ERROR:
                err_payload = self._recv_exact(plen)
                err, aux = struct.unpack("<II", err_payload[:8])
                raise RuntimeError(f"read_ddr error 0x{err:08x} aux=0x{aux:08x}")
            if op != RSP_DATA:
                raise RuntimeError(f"read_ddr: unexpected opcode=0x{op:02x}")
            blk = self._recv_exact(plen)
            out.extend(blk)
            cur += plen
            remaining -= plen
        return bytes(out)

    def exec_layer(self, layer_idx, in_addr, out_addr,
                   w_addr=0, b_addr=0, in_b_addr=0):
        self.connect()
        payload = struct.pack("<IIIIII",
                              layer_idx, in_addr, out_addr,
                              w_addr, b_addr, in_b_addr)
        self._send_header(CMD_EXEC_LAYER, len(payload))
        self._sendall(payload)
        status, extra = self._expect_ack()
        cycles = struct.unpack("<I", extra[:4])[0] if len(extra) >= 4 else 0
        return status, cycles

    def run_network(self, input_addr, head0_addr, head1_addr, head2_addr):
        self.connect()
        payload = struct.pack("<IIII",
                              input_addr, head0_addr, head1_addr, head2_addr)
        self._send_header(CMD_RUN_NETWORK, len(payload))
        self._sendall(payload)
        status, extra = self._expect_ack()
        total_cycles = struct.unpack("<I", extra[:4])[0] if len(extra) >= 4 else 0
        return status, total_cycles

    def dpu_init(self):
        self.connect()
        self._send_header(CMD_DPU_INIT, 0)
        return self._expect_ack()[0]

    def dpu_reset(self):
        self.connect()
        self._send_header(CMD_DPU_RESET, 0)
        return self._expect_ack()[0]


# ==============================================================
# Utilidades de alto nivel
# ==============================================================
def pack_weights_from_onnx(onnx_path, out_blob_path):
    """Placeholder: extrae pesos del ONNX a un blob binario concatenado
    que el ARM luego puntea por layer_idx. Implementacion real usa
    gen_golden_full_network.py style, aqui stub.
    """
    raise NotImplementedError("pack_weights — implementar segun tu formato")


def load_file(path):
    with open(path, "rb") as f:
        return f.read()


# ==============================================================
# CLI basico
# ==============================================================
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.1.10")
    ap.add_argument("--port", type=int, default=7001)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ping")

    p_wr = sub.add_parser("write")
    p_wr.add_argument("addr", type=lambda x: int(x, 0))
    p_wr.add_argument("file")

    p_rd = sub.add_parser("read")
    p_rd.add_argument("addr", type=lambda x: int(x, 0))
    p_rd.add_argument("length", type=lambda x: int(x, 0))
    p_rd.add_argument("--out", default="-")

    p_run = sub.add_parser("run")
    p_run.add_argument("--input",  default="0x10000000", type=lambda x: int(x, 0))
    p_run.add_argument("--head0",  default="0x18000000", type=lambda x: int(x, 0))
    p_run.add_argument("--head1",  default="0x18100000", type=lambda x: int(x, 0))
    p_run.add_argument("--head2",  default="0x18200000", type=lambda x: int(x, 0))

    sub.add_parser("init")
    sub.add_parser("reset")

    args = ap.parse_args()

    with DpuHost(args.host, args.port) as h:
        if args.cmd == "ping":
            r = h.ping()
            print(f"PONG: {r!r}")
        elif args.cmd == "write":
            data = load_file(args.file)
            t0 = time.time()
            n = h.write_ddr(args.addr, data)
            dt = time.time() - t0
            mbs = n / dt / 1e6 if dt > 0 else 0
            print(f"wrote {n} bytes @ 0x{args.addr:08x} in {dt:.2f}s "
                  f"({mbs:.1f} MB/s)")
        elif args.cmd == "read":
            t0 = time.time()
            data = h.read_ddr(args.addr, args.length)
            dt = time.time() - t0
            if args.out == "-":
                sys.stdout.buffer.write(data)
            else:
                with open(args.out, "wb") as f:
                    f.write(data)
                print(f"read {len(data)} bytes -> {args.out} in {dt:.2f}s")
        elif args.cmd == "run":
            status, cycles = h.run_network(args.input, args.head0,
                                            args.head1, args.head2)
            print(f"run_network status=0x{status:08x} cycles={cycles}")
        elif args.cmd == "init":
            print("dpu_init status=0x%08x" % h.dpu_init())
        elif args.cmd == "reset":
            print("dpu_reset status=0x%08x" % h.dpu_reset())


if __name__ == "__main__":
    main()
