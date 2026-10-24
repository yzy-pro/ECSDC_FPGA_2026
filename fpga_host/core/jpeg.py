"""Incremental JPEG framing, respecting segment lengths and entropy escaping.

APP segments may contain thumbnails, including SOI/EOI bytes. Scanning for EOI
alone would truncate those images. The cursor advances once through scan data.
"""


class JpegStreamParser:
    def __init__(self, max_frame_bytes=16 * 1024 * 1024):
        self.max_frame_bytes = max_frame_bytes
        self.buffer = bytearray()
        self.position = None
        self.scanning = False

    def feed(self, data):
        self.buffer.extend(data)
        frames = []
        while True:
            if self.position is None:
                start = self.buffer.find(b"\xff\xd8")
                if start < 0:
                    self.buffer[:] = self.buffer[-1:] if self.buffer.endswith(b"\xff") else b""
                    break
                del self.buffer[:start]
                self.position, self.scanning = 2, False
            pos = self.position
            if self.scanning:
                pos = self.buffer.find(b"\xff", pos)
                if pos < 0:
                    self.position = len(self.buffer)
                    break
            if pos >= len(self.buffer):
                break
            if self.buffer[pos] != 0xff:
                # Damaged header: discard this SOI and search for another.
                del self.buffer[:2]
                self.position = None
                continue
            marker_pos = pos + 1
            while marker_pos < len(self.buffer) and self.buffer[marker_pos] == 0xff:
                marker_pos += 1
            if marker_pos >= len(self.buffer):
                self.position = pos
                break
            marker = self.buffer[marker_pos]
            end = marker_pos + 1
            if self.scanning and (marker == 0 or 0xd0 <= marker <= 0xd7):
                self.position = end
                continue
            if marker == 0xd8:
                del self.buffer[:pos]
                self.position, self.scanning = 2, False
                continue
            if marker == 0xd9:
                if end <= self.max_frame_bytes:
                    frames.append(bytes(self.buffer[:end]))
                del self.buffer[:end]
                self.position = None
                continue
            if marker == 1 or 0xd0 <= marker <= 0xd7:
                self.position = end
                continue
            if marker == 0 or end + 2 > len(self.buffer):
                if marker == 0:
                    del self.buffer[:2]
                    self.position = None
                    continue
                self.position = pos
                break
            length = int.from_bytes(self.buffer[end:end+2], "big")
            if length < 2:
                del self.buffer[:2]
                self.position = None
                continue
            if end + length > len(self.buffer):
                self.position = pos
                break
            self.position = end + length
            self.scanning = marker == 0xda
        if len(self.buffer) > self.max_frame_bytes:
            self.buffer[:] = self.buffer[-1:] if self.buffer.endswith(b"\xff") else b""
            self.position = None
            self.scanning = False
        return frames


def jpeg_size(data):
    """Read (width, height) without decoding or entering APP/entropy payloads."""
    if not data.startswith(b"\xff\xd8"):
        raise ValueError("无效 JPEG 帧头")
    pos = 2
    while pos + 4 <= len(data):
        if data[pos] != 0xff:
            break
        while pos < len(data) and data[pos] == 0xff:
            pos += 1
        if pos >= len(data):
            break
        marker = data[pos]
        pos += 1
        if marker in (0xd8, 1) or 0xd0 <= marker <= 0xd7:
            continue
        if marker in (0xda, 0xd9):
            break
        length = int.from_bytes(data[pos:pos+2], "big")
        if length < 2 or pos + length > len(data):
            break
        if marker in (0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7,
                      0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf) and length >= 8:
            return int.from_bytes(data[pos+5:pos+7], "big"), int.from_bytes(data[pos+3:pos+5], "big")
        pos += length
    raise ValueError("JPEG 缺少有效尺寸信息")
