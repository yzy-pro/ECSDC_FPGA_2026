"""Timestamped, memory-bounded image history (JPEG bytes or BGR arrays)."""
from collections import deque
from dataclasses import dataclass
from threading import Lock
from typing import Any


@dataclass(frozen=True)
class VideoFrame:
    timestamp: float
    sequence: int
    image: Any
    encoding: str = "bgr"


def image_bytes(image):
    return len(image) if isinstance(image, bytes) else image.nbytes


class FrameHistory:
    def __init__(self, max_seconds=2.5, max_bytes=128 * 1024 * 1024):
        self.max_seconds = max_seconds
        self.max_bytes = max_bytes
        self._frames = deque()
        self._bytes = 0
        self._lock = Lock()

    def append(self, frame: VideoFrame):
        with self._lock:
            self._frames.append(frame)
            self._bytes += image_bytes(frame.image)
            while self._frames and (self._bytes > self.max_bytes or
                    frame.timestamp - self._frames[0].timestamp > self.max_seconds):
                self._bytes -= image_bytes(self._frames.popleft().image)

    def at(self, timestamp: float):
        """Last frame at/before target, or None while requested delay warms up."""
        with self._lock:
            for frame in reversed(self._frames):
                if frame.timestamp <= timestamp:
                    return frame
        return None

    def clear(self):
        with self._lock:
            self._frames.clear()
            self._bytes = 0

    @property
    def bytes_used(self):
        with self._lock:
            return self._bytes
