"""Captura UART de la ZedBoard (115200, 8N1).

Uso:
    python uart_capture.py --port COM4 [--duration 30] [--out log.txt]

Intenta autodetectar cuál de los COM es el UART del board (el otro es JTAG).
"""
from __future__ import annotations

import argparse
import sys
import time

import serial
import serial.tools.list_ports


def list_ports() -> list[str]:
    return [p.device for p in serial.tools.list_ports.comports()]


def autodetect(candidates: list[str], timeout: float = 1.0) -> str | None:
    """Abre cada candidato con 115200 8N1; el que dé ASCII válido en `timeout`
    segundos es UART."""
    for port in candidates:
        try:
            with serial.Serial(port, 115200, timeout=timeout) as ser:
                data = ser.read(64)
                if data:
                    try:
                        data.decode("ascii")
                        return port
                    except UnicodeDecodeError:
                        pass
        except (serial.SerialException, OSError):
            continue
    # fallback: typically the highest COM number is UART
    return candidates[-1] if candidates else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--duration", type=float, default=10.0,
                    help="segundos a capturar")
    ap.add_argument("--out", default=None,
                    help="fichero donde guardar la salida (también stdout)")
    args = ap.parse_args()

    ports = list_ports()
    if not ports:
        print("No COM ports found")
        sys.exit(1)
    print(f"COM ports: {ports}")
    port = args.port or autodetect(ports)
    print(f"Using port: {port}")

    out_f = open(args.out, "w") if args.out else None
    try:
        with serial.Serial(port, args.baud, timeout=0.1) as ser:
            ser.reset_input_buffer()
            print(f"Listening on {port} @ {args.baud} for {args.duration}s ...")
            t0 = time.time()
            while time.time() - t0 < args.duration:
                chunk = ser.read(256)
                if chunk:
                    try:
                        text = chunk.decode("utf-8", errors="replace")
                    except Exception:
                        text = repr(chunk)
                    sys.stdout.write(text)
                    sys.stdout.flush()
                    if out_f:
                        out_f.write(text)
                        out_f.flush()
    finally:
        if out_f:
            out_f.close()
    print("\n--- done ---")


if __name__ == "__main__":
    main()
