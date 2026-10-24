"""Deterministic simulated devices. Never opens physical device handles."""
from collections import deque
from threading import Event, Lock, Thread
import math
import time
import cv2
import numpy as np
from fpga_host.core.buffering import FrameHistory, VideoFrame
from fpga_host.core.protocols import Pose, FpgaStatus, GammaStats, SET_FEATURES, SET_STREAM


class DemoRig:
    def __init__(self):
        self.history = FrameHistory()
        self.capture_history = FrameHistory(max_seconds=.5)
        self.lock, self.stop_event = Lock(), Event()
        self.latest = self.capture = None
        self.pose = Pose(0, 0, 0)
        self.mask = 7
        self.applied = 7
        self.apply_at = 0
        self.stream = 1
        self.gamma = None
        self.last_gamma = self.last_frame_change = 0.0
        self.events = deque(["演示模式：所有图像和遥测均为模拟数据"], maxlen=30)
        self.thread = Thread(target=self._run, daemon=True, name="demo")

    def start(self):
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        self.thread.join(timeout=2)

    def send(self, kind, payload=b""):
        with self.lock:
            if kind == SET_FEATURES:
                self.mask = payload[0]
                self.apply_at = time.monotonic() + .1
            elif kind == SET_STREAM:
                self.stream = payload[0]
            else:
                self.last_gamma = 0  # Force snapshot on next render.
        return True

    def snapshot(self):
        now = time.monotonic()
        with self.lock:
            return dict(connected=True, busy=False, status=FpgaStatus(0, self.mask, self.applied,
                int(self.mask != self.applied), 7, self.stream, int(self.gamma is not None), 0),
                gamma=self.gamma, pose=self.pose, last_rx=now, last_status=now,
                last_gamma=self.last_gamma, last_frame_change=self.last_frame_change, parse_errors=0)

    def drain_events(self):
        with self.lock:
            events = list(self.events)
            self.events.clear()
            return events

    def frames(self):
        with self.lock:
            return self.latest, self.capture

    def _run(self):
        width, height = 1280, 720
        x = np.linspace(0, 255, width, dtype=np.uint8)
        base = np.tile(x, (height, 1))
        background = cv2.merge((base, np.flip(base, 1), np.full_like(base, 55)))
        sequence = 0
        next_tick = time.monotonic()
        while not self.stop_event.is_set():
            now = time.monotonic()
            t = sequence / 60
            image = background.copy()
            cv2.circle(image, (int(width/2 + 430*math.sin(t)), 360), 100, (90, 220, 245), -1)
            for y in range(0, height, 60):
                cv2.line(image, (0, y), (width, y), (80, 90, 100), 1)
            cv2.putText(image, f"DEMO - frame {sequence:06d}", (35, 60), cv2.FONT_HERSHEY_SIMPLEX, 1, (255, 255, 255), 2)
            small = cv2.resize(image, (640, 360), interpolation=cv2.INTER_AREA)
            self.history.append(VideoFrame(now, sequence, small))
            with self.lock:
                if self.apply_at and now >= self.apply_at:
                    self.applied, self.apply_at = self.mask, 0
                self.latest = VideoFrame(now, sequence, image)
                self.pose = Pose(.5*math.sin(t*.4), .25*math.sin(t*.8), .12*math.cos(t))
                mask = self.applied
                if (self.stream or not self.last_gamma) and now - self.last_gamma >= .1:
                    pixels = width * height
                    self.gamma = GammaStats(sequence, pixels*95, pixels, pixels//5, pixels//12,
                        pixels*(125 if mask & 4 else 95), 2, 1, bool(mask & 4), mask)
                    self.last_gamma = self.last_frame_change = now
            corrected = cv2.convertScaleAbs(small, alpha=1.15, beta=14) if mask & 4 else small
            self.capture_history.append(VideoFrame(now, sequence, corrected))
            delayed = self.capture_history.at(now - .15)
            with self.lock:
                self.capture = delayed
            sequence += 1
            next_tick += 1/60
            self.stop_event.wait(max(0, next_tick - time.monotonic()))
