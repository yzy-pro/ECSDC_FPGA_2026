"""Video input adapters. MJPG remains JPEG bytes; other formats return BGR."""
from collections import deque
import os
import selectors
import shutil
import subprocess
import tempfile
import time
import cv2
import numpy as np
from fpga_host.core.jpeg import JpegStreamParser, jpeg_size

WIDTH, HEIGHT, FPS = 1920, 1080, 60


def ffmpeg_command(device, fourcc):
    input_format = {"MJPG": "mjpeg", "YUYV": "yuyv422", "NV12": "nv12"}.get(fourcc)
    if input_format is None:
        raise ValueError("FFmpeg 格式需为 MJPG/YUYV/NV12")
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "v4l2",
        "-input_format", input_format, "-video_size", "1920x1080", "-framerate", "60",
        "-analyzeduration", "0", "-probesize", "32", "-i", device, "-an"]
    if fourcc == "MJPG":
        return command + ["-c:v", "copy", "-f", "image2pipe", "-flush_packets", "1", "pipe:1"]
    return command + ["-threads", "2", "-f", "rawvideo", "-pix_fmt", "bgr24", "pipe:1"]


class FFmpegSource:
    def __init__(self, device, fourcc, exposure):
        if os.name == "nt" or not shutil.which("ffmpeg"):
            raise RuntimeError("FFmpeg/V4L2 后端需要 Linux 和系统 ffmpeg")
        if exposure is not None and shutil.which("v4l2-ctl"):
            subprocess.run(["v4l2-ctl", "-d", device, "--set-ctrl",
                f"auto_exposure=1,exposure_time_absolute={exposure}"],
                capture_output=True, timeout=3, check=False)
        self.jpeg = fourcc == "MJPG"
        self.parser = JpegStreamParser()
        self.pending = deque()
        self.errors = tempfile.TemporaryFile()
        try:
            self.process = subprocess.Popen(ffmpeg_command(device, fourcc),
                stdout=subprocess.PIPE, stderr=self.errors, bufsize=0)
        except Exception:
            self.errors.close()
            raise
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = bytearray()

    def read(self, stop):
        size = WIDTH * HEIGHT * 3
        deadline = time.monotonic() + 3
        while not stop.is_set():
            if self.jpeg and self.pending:
                packet = self.pending.popleft()
                if jpeg_size(packet) != (WIDTH, HEIGHT):
                    raise RuntimeError("设备 JPEG 尺寸不是 1920×1080")
                return packet
            if not self.jpeg and len(self.buffer) >= size:
                image = np.frombuffer(bytes(self.buffer[:size]), dtype=np.uint8).reshape(HEIGHT, WIDTH, 3)
                del self.buffer[:size]
                return image
            if time.monotonic() > deadline:
                raise RuntimeError("视频读取超时（3 秒）")
            if not self.selector.select(0.1):
                continue
            amount = 256 * 1024 if self.jpeg else min(size - len(self.buffer), 256 * 1024)
            data = os.read(self.process.stdout.fileno(), amount)
            if not data:
                self.errors.seek(0)
                raise RuntimeError(self.errors.read(4000).decode(errors="replace").strip() or "FFmpeg 视频流已结束")
            if self.jpeg:
                self.pending.extend(self.parser.feed(data))
            else:
                self.buffer.extend(data)
        return None

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=1)
        self.selector.close()
        self.process.stdout.close()
        self.errors.close()


class OpenCVSource:
    def __init__(self, device, fourcc, exposure):
        source = int(device) if device.isdecimal() else device
        backend = cv2.CAP_DSHOW if os.name == "nt" else cv2.CAP_V4L2
        self.capture = cv2.VideoCapture(source, backend)
        if not self.capture.isOpened():
            self.capture.release()
            raise RuntimeError(f"无法打开视频设备 {device}")
        if exposure is not None:
            self.capture.set(cv2.CAP_PROP_AUTO_EXPOSURE, 0.25)
            self.capture.set(cv2.CAP_PROP_EXPOSURE, exposure)
        self.capture.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*fourcc))
        self.capture.set(cv2.CAP_PROP_FRAME_WIDTH, WIDTH)
        self.capture.set(cv2.CAP_PROP_FRAME_HEIGHT, HEIGHT)
        self.capture.set(cv2.CAP_PROP_FPS, FPS)
        self.capture.set(cv2.CAP_PROP_BUFFERSIZE, 1)

    def read(self, stop):
        ok, image = self.capture.read()
        if not ok:
            raise RuntimeError("视频读取失败")
        if image.shape[:2] != (HEIGHT, WIDTH):
            raise RuntimeError(f"设备返回 {image.shape[1]}×{image.shape[0]}，需要 1920×1080")
        return image

    def close(self):
        self.capture.release()

