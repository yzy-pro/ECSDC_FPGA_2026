#!/usr/bin/env python3

# uv run Debug/debug_usb_host.py
"""解析 STM32 USB CDC 发送的 yaw、pitch，并以角度制打印。"""

import argparse
import math
import struct
import sys
from dataclasses import dataclass
from typing import Iterable, List, Optional

FRAME_HEADER = b"\x55\xaa"
FRAME_TAIL = 0x0D
FRAME_SIZE = 8
Q2048_SCALE = 2048.0

# USB_DEVICE/App/usbd_desc.c 中配置的 VID/PID。
DEFAULT_USB_VID = 0x0483
DEFAULT_USB_PID = 0x5740


@dataclass(frozen=True)
class GimbalFrame:
    yaw_raw: int
    pitch_raw: int
    raw_frame: bytes

    @property
    def yaw_rad(self) -> float:
        return self.yaw_raw / Q2048_SCALE

    @property
    def pitch_rad(self) -> float:
        return self.pitch_raw / Q2048_SCALE

    @property
    def yaw_deg(self) -> float:
        return math.degrees(self.yaw_rad)

    @property
    def pitch_deg(self) -> float:
        return math.degrees(self.pitch_rad)


class FrameParser:
    """从任意分块的字节流中提取并校验 8 字节协议帧。"""

    def __init__(self) -> None:
        self._buffer = bytearray()
        self.valid_frames = 0
        self.checksum_errors = 0
        self.tail_errors = 0
        self.discarded_bytes = 0

    def feed(self, data: bytes) -> List[GimbalFrame]:
        self._buffer.extend(data)
        frames: List[GimbalFrame] = []

        while True:
            header_index = self._buffer.find(FRAME_HEADER)
            if header_index < 0:
                # 保留可能作为下一帧帧头首字节的 0x55。
                keep = 1 if self._buffer.endswith(FRAME_HEADER[:1]) else 0
                discard_count = len(self._buffer) - keep
                if discard_count > 0:
                    del self._buffer[:discard_count]
                    self.discarded_bytes += discard_count
                break

            if header_index > 0:
                del self._buffer[:header_index]
                self.discarded_bytes += header_index

            if len(self._buffer) < FRAME_SIZE:
                break

            candidate = bytes(self._buffer[:FRAME_SIZE])

            if candidate[7] != FRAME_TAIL:
                self.tail_errors += 1
                del self._buffer[0]
                self.discarded_bytes += 1
                continue

            expected_checksum = sum(candidate[2:6]) & 0xFF
            if candidate[6] != expected_checksum:
                self.checksum_errors += 1
                del self._buffer[0]
                self.discarded_bytes += 1
                continue

            yaw_raw, pitch_raw = struct.unpack_from("<hh", candidate, 2)
            frames.append(GimbalFrame(yaw_raw, pitch_raw, candidate))
            self.valid_frames += 1
            del self._buffer[:FRAME_SIZE]

        return frames


def _encode_test_frame(yaw_rad: float, pitch_rad: float) -> bytes:
    def to_q2048(value: float) -> int:
        scaled = value * Q2048_SCALE
        scaled = min(32767.0, max(-32768.0, scaled))
        return int(scaled + 0.5 if scaled >= 0.0 else scaled - 0.5)

    payload = struct.pack("<hh", to_q2048(yaw_rad), to_q2048(pitch_rad))
    checksum = sum(payload) & 0xFF
    return FRAME_HEADER + payload + bytes((checksum, FRAME_TAIL))


def run_self_test() -> None:
    expected_yaw = math.radians(90.0)
    expected_pitch = math.radians(-30.0)
    valid_frame = _encode_test_frame(expected_yaw, expected_pitch)
    corrupted_frame = bytearray(valid_frame)
    corrupted_frame[6] ^= 0x01

    parser = FrameParser()
    stream = b"\x00\x55\x01" + bytes(corrupted_frame) + valid_frame
    parsed: List[GimbalFrame] = []
    for chunk in (stream[:4], stream[4:9], stream[9:15], stream[15:]):
        parsed.extend(parser.feed(chunk))

    if len(parsed) != 1:
        raise AssertionError(f"期望解析到 1 帧，实际为 {len(parsed)} 帧")
    if parser.checksum_errors != 1:
        raise AssertionError("损坏帧未被校验和检查拒绝")

    frame = parsed[0]
    tolerance_deg = math.degrees(0.5 / Q2048_SCALE)
    if abs(frame.yaw_deg - 90.0) > tolerance_deg:
        raise AssertionError(f"yaw 解码错误：{frame.yaw_deg:.6f} deg")
    if abs(frame.pitch_deg - (-30.0)) > tolerance_deg:
        raise AssertionError(f"pitch 解码错误：{frame.pitch_deg:.6f} deg")

    print("自检通过")
    print(f"测试帧: {valid_frame.hex(' ').upper()}")
    print(f"解析值: yaw={frame.yaw_deg:.4f} deg, " f"pitch={frame.pitch_deg:.4f} deg")


def _load_serial_modules():
    try:
        import serial
        from serial.tools import list_ports
    except ImportError as exc:
        raise RuntimeError(
            "缺少 pyserial，请执行：python3 -m pip install pyserial"
        ) from exc
    return serial, list_ports


def list_serial_ports() -> None:
    _, list_ports = _load_serial_modules()
    ports = list(list_ports.comports())
    if not ports:
        print("未发现串口设备")
        return

    for port in ports:
        vid_pid = ""
        if port.vid is not None and port.pid is not None:
            vid_pid = f" VID:PID={port.vid:04X}:{port.pid:04X}"
        print(f"{port.device}: {port.description}{vid_pid}")


def find_stm32_port() -> str:
    _, list_ports = _load_serial_modules()
    matches = [
        port.device
        for port in list_ports.comports()
        if port.vid == DEFAULT_USB_VID and port.pid == DEFAULT_USB_PID
    ]

    if not matches:
        raise RuntimeError(
            "未找到 STM32 Virtual ComPort "
            f"({DEFAULT_USB_VID:04X}:{DEFAULT_USB_PID:04X})；"
            "请使用 --list 查看设备，或用 --port 手动指定"
        )
    if len(matches) > 1:
        raise RuntimeError(
            "检测到多个匹配设备，请用 --port 指定：" + ", ".join(matches)
        )
    return matches[0]


def monitor(port: Optional[str], baudrate: int, show_hex: bool) -> None:
    serial, _ = _load_serial_modules()
    selected_port = port or find_stm32_port()
    parser = FrameParser()
    sequence = 0

    print(f"打开 {selected_port}，波特率 {baudrate}")
    print("等待数据，按 Ctrl+C 退出……")

    try:
        with serial.Serial(selected_port, baudrate, timeout=0.2) as device:
            while True:
                data = device.read(device.in_waiting or 1)
                for frame in parser.feed(data):
                    sequence += 1
                    line = (
                        f"#{sequence:06d}  "
                        f"yaw={frame.yaw_deg:9.4f} deg  "
                        f"pitch={frame.pitch_deg:9.4f} deg  "
                        f"raw=({frame.yaw_raw:6d}, {frame.pitch_raw:6d})"
                    )
                    if show_hex:
                        line += f"  frame={frame.raw_frame.hex(' ').upper()}"
                    print(line)
    except KeyboardInterrupt:
        print(
            "\n已停止："
            f"有效帧={parser.valid_frames}，"
            f"校验错误={parser.checksum_errors}，"
            f"帧尾错误={parser.tail_errors}，"
            f"丢弃字节={parser.discarded_bytes}"
        )
    except serial.SerialException as exc:
        raise RuntimeError(f"串口通信失败：{exc}") from exc


def parse_args(argv: Optional[Iterable[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="解析 STM32 USB CDC 云台 yaw/pitch 数据"
    )
    parser.add_argument("--port", help="串口设备，例如 /dev/ttyACM0 或 COM5")
    parser.add_argument(
        "--baudrate",
        type=int,
        default=115200,
        help="CDC 串口波特率（默认：115200）",
    )
    parser.add_argument("--hex", action="store_true", help="同时打印完整帧十六进制")
    parser.add_argument("--list", action="store_true", help="列出串口设备后退出")
    parser.add_argument("--self-test", action="store_true", help="运行解析器自检后退出")
    return parser.parse_args(argv)


def main() -> int:
    args = parse_args()
    try:
        if args.self_test:
            run_self_test()
        elif args.list:
            list_serial_ports()
        else:
            monitor(args.port, args.baudrate, args.hex)
    except (RuntimeError, AssertionError) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
