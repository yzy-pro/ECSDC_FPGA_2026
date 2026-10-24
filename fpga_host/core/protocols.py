"""Wire formats from Device/*/reference; no Qt or serial dependencies."""
from dataclasses import dataclass
from functools import reduce
from operator import xor
import math
import struct

SET_FEATURES, GET_STATUS, SET_STREAM, GET_SNAPSHOT = 0x10, 0x11, 0x12, 0x13
STATUS, GAMMA_STATS = 0x80, 0x81
EXPONENTS = (0.50, 0.65, 0.80, 1.00, 1.25, 1.55, 1.90)
RESULTS = {0: "成功", 1: "未知命令", 2: "负载长度错误", 3: "数值非法",
           4: "BUSY：上一配置等待生效", 5: "功能不支持", 6: "尚无有效帧统计"}


@dataclass(frozen=True)
class Packet:
    kind: int
    sequence: int
    payload: bytes


def encode_packet(kind: int, sequence: int, payload: bytes = b"") -> bytes:
    if not 0 <= kind <= 255 or not 0 <= sequence <= 255 or len(payload) > 255:
        raise ValueError("type/sequence/length must fit uint8")
    body = bytes((1, kind, sequence, len(payload))) + payload
    return b"\xa5\x5a" + body + bytes((reduce(xor, body, 0),))


class PacketDecoder:
    """Incremental, bounded parser; valid payloads may contain sync words."""
    def __init__(self):
        self.buffer = bytearray()
        self.errors = 0

    def clear(self):
        self.buffer.clear()

    def feed(self, data: bytes) -> list[Packet]:
        self.buffer.extend(data)
        packets = []
        while self.buffer:
            start = self.buffer.find(b"\xa5\x5a")
            if start < 0:
                self.buffer[:] = b"\xa5" if self.buffer.endswith(b"\xa5") else b""
                break
            del self.buffer[:start]
            if len(self.buffer) < 6:
                break
            if self.buffer[2] != 1:
                self.errors += 1
                del self.buffer[0]
                continue
            size = 7 + self.buffer[5]
            # Known message sizes also reject corrupt LENGTH without waiting
            # indefinitely for a fictitious 255-byte telemetry packet.
            expected = {STATUS: 8, GAMMA_STATS: 28}.get(self.buffer[3])
            if expected is not None and self.buffer[5] != expected:
                self.errors += 1
                del self.buffer[0]
                continue
            if len(self.buffer) < size:
                break
            if reduce(xor, self.buffer[2:size], 0):
                self.errors += 1
                del self.buffer[0]
                continue
            packets.append(Packet(self.buffer[3], self.buffer[4], bytes(self.buffer[6:size-1])))
            del self.buffer[:size]
        return packets


@dataclass(frozen=True)
class FpgaStatus:
    result: int
    requested_mask: int
    applied_mask: int
    pending: int
    available_mask: int
    stream_enabled: int
    has_stats: int
    receive_errors: int

    @classmethod
    def decode(cls, payload: bytes):
        if len(payload) != 8:
            raise ValueError("STATUS requires 8 bytes")
        value = cls(*payload)
        if any(mask & ~7 for mask in (value.requested_mask, value.applied_mask, value.available_mask)):
            raise ValueError("invalid feature mask")
        if any(flag not in (0, 1) for flag in (value.pending, value.stream_enabled, value.has_stats)):
            raise ValueError("invalid STATUS flag")
        return value


@dataclass(frozen=True)
class GammaStats:
    frame_index: int
    raw_luma_sum: int
    pixel_count: int
    dark_count: int
    highlight_count: int
    corrected_luma_sum: int
    active_curve: int
    target_curve: int
    gamma_enabled: int
    frame_mask: int

    @classmethod
    def decode(cls, payload: bytes):
        if len(payload) != 28:
            raise ValueError("GAMMA_STATS requires 28 bytes")
        value = cls(*struct.unpack("<6I4B", payload))
        if value.active_curve > 6 or value.target_curve > 6 or value.gamma_enabled > 1 or value.frame_mask > 7:
            raise ValueError("invalid Gamma metadata")
        return value

    @property
    def mean_before(self):
        return self.raw_luma_sum / self.pixel_count if self.pixel_count else None

    @property
    def mean_after(self):
        return self.corrected_luma_sum / self.pixel_count if self.pixel_count else None

    @property
    def dark_ratio(self):
        return self.dark_count / self.pixel_count if self.pixel_count else None

    @property
    def highlight_ratio(self):
        return self.highlight_count / self.pixel_count if self.pixel_count else None


@dataclass(frozen=True)
class Pose:
    yaw: float
    pitch: float
    roll: float

    @property
    def degrees(self):
        return tuple(math.degrees(v) for v in (self.yaw, self.pitch, self.roll))


class ImuDecoder:
    def __init__(self):
        self.buffer = bytearray()
        self.errors = 0

    def feed(self, data: bytes) -> list[Pose]:
        self.buffer.extend(data)
        result = []
        while self.buffer:
            start = self.buffer.find(b"\x55\xaa")
            if start < 0:
                self.buffer[:] = b"\x55" if self.buffer.endswith(b"\x55") else b""
                break
            del self.buffer[:start]
            if len(self.buffer) < 10:
                break
            if self.buffer[9] != 0x0d or self.buffer[8] != sum(self.buffer[2:8]) & 255:
                self.errors += 1
                del self.buffer[0]
                continue
            result.append(Pose(*(v / 2048.0 for v in struct.unpack_from("<hhh", self.buffer, 2))))
            del self.buffer[:10]
        return result
