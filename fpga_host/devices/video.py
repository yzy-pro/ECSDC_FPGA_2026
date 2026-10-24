"""Continuous input, bounded history and independent latest-frame decoders.

MJPEG is never decoded by the reader. Preview decoding skips intermediate
frames; only an active HDMI output requests a full-resolution decoder.
"""
from collections import deque
from threading import Event, Lock, Thread
import os
import shutil
import subprocess
import time
import cv2
import numpy as np
from fpga_host.core.buffering import FrameHistory, VideoFrame
from fpga_host.devices.video_sources import FFmpegSource, OpenCVSource

PREVIEW_SIZE = (640, 360)
PREVIEW_FPS = 30


def decode_frame(frame, preview=False):
    """Run outside Qt. Reduced JPEG decoding avoids a full 1080p allocation."""
    image = frame.image
    if frame.encoding == "jpeg":
        mode = cv2.IMREAD_REDUCED_COLOR_2 if preview else cv2.IMREAD_COLOR
        # Ignore EXIF orientation: preview and HDMI must share sensor geometry.
        image = cv2.imdecode(np.frombuffer(image, dtype=np.uint8), mode | cv2.IMREAD_IGNORE_ORIENTATION)
        if image is None:
            raise ValueError("JPEG 图像解码失败")
    if preview:
        image = cv2.resize(image, PREVIEW_SIZE, interpolation=cv2.INTER_LINEAR)
    return VideoFrame(frame.timestamp, frame.sequence, image)


class VideoWorker:
    def __init__(self, device, backend="auto", fourcc="MJPG", exposure=None,
                 name="视频", preview_seconds=2.5, preview_enabled=True):
        self.device, self.backend, self.fourcc, self.exposure = device, backend, fourcc, exposure
        self.name = name
        self.preview_enabled = preview_enabled
        # JPEG history is compressed. Raw backends keep only reduced previews.
        self.history = FrameHistory(max_seconds=preview_seconds)
        self.lock, self.stop_event = Lock(), Event()
        self.latest_input = self.latest = self.preview = None
        self.connected = False
        self.fps = self.preview_fps = 0.0
        self.preview_delay = 0.0
        self.full_resolution = False
        self._generation = self._delay_revision = self._full_revision = 0
        self.events = deque(maxlen=30)
        self.thread = Thread(target=self._run, name=name + "读取", daemon=True)
        self.preview_thread = Thread(target=self._preview_loop, name=name + "预览", daemon=True)
        self.output_thread = Thread(target=self._output_loop, name=name + "副屏", daemon=True)

    def start(self):
        for thread in (self.thread, self.preview_thread, self.output_thread):
            thread.start()

    def stop(self):
        self.stop_event.set()
        deadline = time.monotonic() + 4
        for thread in (self.thread, self.preview_thread, self.output_thread):
            thread.join(timeout=max(0, deadline - time.monotonic()))

    @property
    def is_alive(self):
        return any(t.is_alive() for t in (self.thread, self.preview_thread, self.output_thread))

    def set_preview_delay(self, seconds):
        seconds = max(0.0, min(2.0, seconds))
        with self.lock:
            if seconds != self.preview_delay:
                self.preview_delay = seconds
                self._delay_revision += 1
                self.preview = None

    def set_full_resolution(self, enabled):
        with self.lock:
            if enabled != self.full_resolution:
                self.full_resolution = enabled
                self._full_revision += 1
                self.latest = None

    def snapshot(self):
        """Full-size output (only when requested), input health and input fps."""
        with self.lock:
            connected = self._fresh()
            frame = self.latest
            if self.full_resolution and self.latest_input and self.latest_input.encoding == "bgr":
                frame = self.latest_input
            return (frame if connected else None), connected, self.fps

    def input_snapshot(self):
        """Original JPEG/BGR packet for occasional background measurements."""
        with self.lock:
            return self.latest_input if self._fresh() else None

    def preview_snapshot(self):
        with self.lock:
            frame = self.preview
            if not self._fresh() or (frame and time.monotonic() - frame.timestamp > self.preview_delay + .5):
                frame = None
            return frame, self.preview_fps

    def _fresh(self):
        # Caller holds lock. Decode completion must not make old input fresh.
        return bool(self.connected and self.latest_input and
                    time.monotonic() - self.latest_input.timestamp < .5)

    def drain_events(self):
        with self.lock:
            result = list(self.events)
            self.events.clear()
            return result

    def _event(self, message):
        with self.lock:
            self.events.append(f"{self.name}: {message}")

    def _reset(self):
        with self.lock:
            self._generation += 1
            self.connected = False
            self.latest_input = self.latest = self.preview = None
            self.fps = self.preview_fps = 0.0
            self.history.clear()

    def _run(self):
        sequence = 0
        while not self.stop_event.is_set():
            source = None
            try:
                use_ffmpeg = self.backend == "ffmpeg" or (self.backend == "auto" and os.name != "nt" and shutil.which("ffmpeg"))
                factory = FFmpegSource if use_ffmpeg else OpenCVSource
                source = factory(self.device, self.fourcc, self.exposure)
                self._event(f"已打开 {self.device} / {factory.__name__}，请求 1080p60；预览最多 {PREVIEW_FPS} fps")
                started, count = time.monotonic(), 0
                while not self.stop_event.is_set():
                    image = source.read(self.stop_event)
                    if image is None:
                        break
                    now = time.monotonic()
                    sequence += 1
                    count += 1
                    encoding = "jpeg" if isinstance(image, bytes) else "bgr"
                    frame = VideoFrame(now, sequence, image, encoding)
                    with self.lock:
                        self.latest_input, self.connected = frame, True
                        if encoding == "jpeg" and self.preview_enabled:
                            self.history.append(frame)
                        if now - started >= 1:
                            self.fps = count / (now - started)
                            started, count = now, 0
            except (OSError, RuntimeError, ValueError, cv2.error, subprocess.SubprocessError) as exc:
                self._event(str(exc))
            finally:
                # Invalidate in-flight decoders before closing a failed source.
                self._reset()
                if source:
                    source.close()
            self.stop_event.wait(2)

    def _preview_loop(self):
        previous = reduced_previous = None
        started, count, generation_seen = time.monotonic(), 0, -1
        while not self.stop_event.is_set():
            tick = time.monotonic()
            if not self.preview_enabled:
                self.stop_event.wait(.1)
                continue
            with self.lock:
                generation, revision = self._generation, self._delay_revision
                delay, latest = self.preview_delay, self.latest_input
                frame = self.history.at(tick - delay) if latest and latest.encoding == "jpeg" else None
            if generation != generation_seen:
                started, count, generation_seen = tick, 0, generation
            try:
                if latest and latest.encoding == "bgr":
                    key = (generation, latest.sequence)
                    if key != reduced_previous:
                        small = decode_frame(latest, preview=True)
                        with self.lock:
                            if generation == self._generation and not self.stop_event.is_set():
                                self.history.append(small)
                        reduced_previous = key
                    with self.lock:
                        frame = self.history.at(time.monotonic() - delay) if generation == self._generation else None
                key = (generation, revision, frame.sequence if frame else None)
                if frame and key != previous:
                    previous = key
                    decoded = decode_frame(frame, preview=True) if frame.encoding == "jpeg" else frame
                    with self.lock:
                        if (generation == self._generation and revision == self._delay_revision
                                and not self.stop_event.is_set()):
                            self.preview = decoded
                            count += 1
                if time.monotonic() - started >= 1:
                    with self.lock:
                        if generation == self._generation:
                            self.preview_fps = count / (time.monotonic() - started)
                    started, count = time.monotonic(), 0
            except (ValueError, cv2.error) as exc:
                self._event(str(exc))
            # No catch-up iterations: the next pass chooses the newest target.
            self.stop_event.wait(max(.001, 1/PREVIEW_FPS - (time.monotonic() - tick)))

    def _output_loop(self):
        previous = None
        while not self.stop_event.is_set():
            tick = time.monotonic()
            with self.lock:
                frame, enabled = self.latest_input, self.full_resolution
                generation, revision = self._generation, self._full_revision
            key = (generation, revision, frame.sequence if frame else None)
            if enabled and frame and frame.encoding == "jpeg" and key != previous:
                previous = key
                try:
                    decoded = decode_frame(frame)
                    with self.lock:
                        if (generation == self._generation and revision == self._full_revision
                                and self.full_resolution and not self.stop_event.is_set()):
                            self.latest = decoded
                except (ValueError, cv2.error) as exc:
                    self._event(str(exc))
            self.stop_event.wait(max(.001, 1/60 - (time.monotonic() - tick)))
