#!/usr/bin/env python3
"""
mock_server.py -- Servidor Python que emula el protocolo P_18 para testear
el cliente yolov4_host.py SIN la placa. Simula DDR como un dict/bytearray
gigante y responde al protocolo byte-por-byte.

Uso:
    python mock_server.py [--port 7001]

Desde otra terminal:
    python yolov4_host.py --host 127.0.0.1 ping
    python yolov4_host.py --host 127.0.0.1 write 0x10000000 input.bin
    python yolov4_host.py --host 127.0.0.1 read  0x10000000 0x1000 --out out.bin
"""

import argparse
import socket
import struct
import threading

# Import constants from the host module
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from yolov4_host import (
    CMD_PING, CMD_WRITE_DDR, CMD_READ_DDR, CMD_EXEC_LAYER,
    CMD_RUN_NETWORK, CMD_DPU_INIT, CMD_DPU_RESET, CMD_CLOSE,
    RSP_PONG, RSP_ACK, RSP_DATA, RSP_ERROR,
    STATUS_OK, STATUS_ERR_INVALID_CMD, STATUS_ERR_BUFFER_OVERRUN,
    HEADER_FMT, HEADER_SIZE,
)


# Simulated DDR: sparse dict of 4KB pages so we dont allocate 512 MB
class SimDDR:
    PAGE_BITS = 12
    PAGE_SIZE = 1 << PAGE_BITS
    PAGE_MASK = PAGE_SIZE - 1

    def __init__(self):
        self.pages = {}

    def _page(self, page_idx, alloc=True):
        p = self.pages.get(page_idx)
        if p is None and alloc:
            p = bytearray(self.PAGE_SIZE)
            self.pages[page_idx] = p
        return p

    def write(self, addr, data):
        off = addr
        mv = memoryview(data)
        cur = 0
        while cur < len(mv):
            page_idx = off >> self.PAGE_BITS
            page_off = off & self.PAGE_MASK
            n = min(len(mv) - cur, self.PAGE_SIZE - page_off)
            page = self._page(page_idx, alloc=True)
            page[page_off:page_off + n] = mv[cur:cur + n]
            cur += n
            off += n

    def read(self, addr, length):
        out = bytearray(length)
        off = addr
        cur = 0
        while cur < length:
            page_idx = off >> self.PAGE_BITS
            page_off = off & self.PAGE_MASK
            n = min(length - cur, self.PAGE_SIZE - page_off)
            page = self._page(page_idx, alloc=False)
            if page is None:
                out[cur:cur + n] = b"\x00" * n
            else:
                out[cur:cur + n] = page[page_off:page_off + n]
            cur += n
            off += n
        return bytes(out)


def recv_exact(sock, n):
    buf = bytearray(n)
    mv = memoryview(buf)
    got = 0
    while got < n:
        r = sock.recv_into(mv[got:], n - got)
        if r == 0:
            return None
        got += r
    return bytes(buf)


def send_header(sock, opcode, tag, payload_len, flags=0):
    sock.sendall(struct.pack(HEADER_FMT, opcode, flags, tag, payload_len))


def send_ack(sock, tag, status=STATUS_OK, extra=b""):
    payload = struct.pack("<I", status) + extra
    send_header(sock, RSP_ACK, tag, len(payload))
    sock.sendall(payload)


def handle_client(conn, addr, ddr):
    print(f"[mock] connection from {addr}")
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    try:
        while True:
            hdr = recv_exact(conn, HEADER_SIZE)
            if hdr is None:
                break
            opcode, flags, tag, plen = struct.unpack(HEADER_FMT, hdr)
            payload = recv_exact(conn, plen) if plen > 0 else b""
            if payload is None and plen > 0:
                break

            if opcode == CMD_PING:
                send_header(conn, RSP_PONG, tag, 8)
                conn.sendall(b"P_18 OK\x00")

            elif opcode == CMD_WRITE_DDR:
                addr_w = struct.unpack("<I", payload[:4])[0]
                data = payload[4:]
                ddr.write(addr_w, data)
                print(f"[mock] WRITE {len(data)}B @ 0x{addr_w:08x}")
                send_ack(conn, tag)

            elif opcode == CMD_READ_DDR:
                addr_r, length = struct.unpack("<II", payload[:8])
                data = ddr.read(addr_r, length)
                send_header(conn, RSP_DATA, tag, length)
                conn.sendall(data)
                print(f"[mock] READ  {length}B @ 0x{addr_r:08x}")

            elif opcode == CMD_EXEC_LAYER:
                fields = struct.unpack("<IIIIII", payload[:24])
                layer_idx = fields[0]
                print(f"[mock] EXEC_LAYER {layer_idx}")
                send_ack(conn, tag, STATUS_OK, struct.pack("<I", 12345))

            elif opcode == CMD_RUN_NETWORK:
                input_a, h0, h1, h2 = struct.unpack("<IIII", payload[:16])
                print(f"[mock] RUN_NETWORK in=0x{input_a:08x}")
                send_ack(conn, tag, STATUS_OK, struct.pack("<I", 999999))

            elif opcode == CMD_DPU_INIT:
                send_ack(conn, tag)

            elif opcode == CMD_DPU_RESET:
                send_ack(conn, tag)

            elif opcode == CMD_CLOSE:
                break

            else:
                send_header(conn, RSP_ERROR, tag, 8)
                conn.sendall(struct.pack("<II", STATUS_ERR_INVALID_CMD, 0))
    except ConnectionError as e:
        print(f"[mock] client {addr} disconnected: {e}")
    finally:
        conn.close()
        print(f"[mock] connection {addr} closed")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=7001)
    args = ap.parse_args()

    ddr = SimDDR()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.host, args.port))
    srv.listen(1)
    print(f"[mock] P_18 DPU server listening on {args.host}:{args.port}")

    try:
        while True:
            conn, addr = srv.accept()
            t = threading.Thread(target=handle_client,
                                 args=(conn, addr, ddr), daemon=True)
            t.start()
    except KeyboardInterrupt:
        print("[mock] shutdown")
    finally:
        srv.close()


if __name__ == "__main__":
    main()
