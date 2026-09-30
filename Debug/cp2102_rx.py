# /// script
# requires-python = ">=3.10"
# dependencies = ["pyserial>=3.5,<4"]
# ///

"""Receive the FPGA SHA-256 checksum over CP2102 and compare raw bytes."""

import argparse
import sys
import time
from pathlib import Path


HEADER = b"\xAA\x55"
PAYLOAD_SIZE = 32
FRAME_SIZE = len(HEADER) + PAYLOAD_SIZE + 2
DEFAULT_REFERENCE = Path(__file__).resolve().with_name("lut_checksum.bin")


def extract_frame(buffer: bytearray) -> bytes | None:
    """Return one valid payload, retaining partial data for the next read."""
    while True:
        start = buffer.find(HEADER)
        if start < 0:
            buffer[:] = HEADER[:1] if buffer.endswith(HEADER[:1]) else b""
            return None
        del buffer[:start]
        if len(buffer) < FRAME_SIZE:
            return None

        frame = buffer[:FRAME_SIZE]
        payload = bytes(frame[2:2 + PAYLOAD_SIZE])
        xor_checksum = 0
        for value in payload:
            xor_checksum ^= value
        if frame[-2] == xor_checksum and frame[-1] == 0x0D:
            del buffer[:FRAME_SIZE]
            return payload

        del buffer[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", help="CP2102 serial port, for example COM3")
    parser.add_argument("--baud", type=int, default=921_600, help="baud rate (default: 921600)")
    parser.add_argument("--timeout", type=float, default=30.0, help="total wait in seconds (default: 30)")
    parser.add_argument("--reference", type=Path, default=DEFAULT_REFERENCE,
                        help="32-byte reference file (default: Debug/lut_checksum.bin)")
    args = parser.parse_args()

    if args.baud <= 0 or args.timeout <= 0:
        parser.error("--baud and --timeout must be positive")

    try:
        expected = args.reference.read_bytes()
    except OSError as exc:
        print(f"Cannot read reference file: {exc}", file=sys.stderr)
        return 2
    if len(expected) != PAYLOAD_SIZE:
        print(f"Reference must contain {PAYLOAD_SIZE} bytes; found {len(expected)}", file=sys.stderr)
        return 2

    try:
        import serial
    except ImportError:
        print("pyserial is required; run this script with uv run or install pyserial", file=sys.stderr)
        return 2

    buffer = bytearray()
    deadline = time.monotonic() + args.timeout
    try:
        with serial.Serial(args.port, args.baud, timeout=0.2,
                           bytesize=serial.EIGHTBITS, parity=serial.PARITY_NONE,
                           stopbits=serial.STOPBITS_ONE) as connection:
            print(f"Listening on {args.port} at {args.baud} baud; reset the FPGA if it already transmitted.",
                  flush=True)
            while time.monotonic() < deadline:
                buffer.extend(connection.read(min(max(connection.in_waiting, 1), 4096)))
                received = extract_frame(buffer)
                if received is None:
                    continue
                print(f"Received: {received.hex()}")
                print(f"Expected: {expected.hex()}")
                if received == expected:
                    print("PASS: SHA-256 checksum matches")
                    return 0
                print("FAIL: SHA-256 checksum differs")
                return 1
    except serial.SerialException as exc:
        print(f"Serial port error: {exc}", file=sys.stderr)
        return 2

    print("Timed out waiting for a valid 36-byte frame", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
