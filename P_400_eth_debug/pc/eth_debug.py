#!/usr/bin/env python3
"""
P_400 ETH Debug - PC side tool
Communicates with ZedBoard over UDP for debug.

Setup:
  1. Connect ZedBoard Ethernet to PC (direct or via switch)
  2. Set PC Ethernet adapter IP to 192.168.1.100, mask 255.255.255.0
  3. Board runs at 192.168.1.10

Usage:
  python eth_debug.py                  # interactive shell
  python eth_debug.py ping             # single command
  python eth_debug.py read 0xF8000000  # read SLCR device ID
  python eth_debug.py dump 0x43C00000 8  # dump 8 AXI regs
  python eth_debug.py write 0x43C00000 0x00000001  # write reg
"""

import socket
import sys
import time

BOARD_IP   = "192.168.1.10"
BOARD_PORT = 7777
LOCAL_PORT = 7777
TIMEOUT    = 3.0


def create_socket():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(TIMEOUT)
    # Bind to any available port (avoid conflict if multiple instances)
    sock.bind(("0.0.0.0", 0))
    return sock


def send_cmd(sock, cmd):
    """Send command to board, return response string."""
    sock.sendto(cmd.encode("utf-8"), (BOARD_IP, BOARD_PORT))
    try:
        data, addr = sock.recvfrom(4096)
        return data.decode("utf-8", errors="replace").strip()
    except socket.timeout:
        return "[TIMEOUT] No response from board"


def interactive(sock):
    """Interactive debug shell."""
    print(f"ETH Debug Shell -> {BOARD_IP}:{BOARD_PORT}")
    print("Commands: ping, read <addr>, write <addr> <val>, dump <addr> [n], quit")
    print()
    while True:
        try:
            cmd = input("zed> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not cmd:
            continue
        if cmd in ("quit", "exit", "q"):
            break
        resp = send_cmd(sock, cmd)
        print(resp)


def main():
    sock = create_socket()

    if len(sys.argv) < 2:
        interactive(sock)
    else:
        cmd = " ".join(sys.argv[1:])
        print(send_cmd(sock, cmd))

    sock.close()


if __name__ == "__main__":
    main()
