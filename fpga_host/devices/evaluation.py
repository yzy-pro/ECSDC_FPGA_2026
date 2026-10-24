"""One bounded background evaluation task, independent of live comparison UI."""
from threading import Event, Lock, Thread
import time
import cv2
import numpy as np
from fpga_host.devices.video import decode_frame
from fpga_host.evaluation.analyzer import (detect_board, reference_image, evaluate_board,
                                            overlay, demo_board)


class EvaluationWorker:
    def __init__(self, options, provider=None, image_path=None, demo=False, metadata=None, interval=1.):
        self.options, self.provider = options, provider
        self.image_path, self.demo = image_path, demo
        self.metadata = metadata or {}
        self.interval = interval
        self.stop_event, self.lock = Event(), Lock()
        self.thread = Thread(target=self._run, name='标定板评估', daemon=True)
        self.result = None
        self.revision = 0
        self.events = []

    def start(self):
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        self.thread.join(timeout=4)

    def drain_events(self):
        with self.lock:
            result, self.events = self.events, []
            return result

    def snapshot(self):
        with self.lock:
            return self.result

    def _publish(self, state, image=None, corners=None, report=None, motion=None):
        if self.stop_event.is_set():
            return
        annotated = overlay(image, corners, self.options.pattern, report) if image is not None else None
        with self.lock:
            if not self.stop_event.is_set():
                self.revision += 1
                self.result = dict(revision=self.revision, state=state, image=annotated, report=report,
                                   motion_px=motion, timestamp=time.monotonic())

    def _run(self):
        previous, stable, last_sequence = None, 0, None
        static = self.demo or self.image_path is not None
        try:
            static_image = None
            if self.demo:
                static_image = demo_board(self.options.pattern)
            elif self.image_path:
                from pathlib import Path
                path = Path(self.image_path)
                if path.stat().st_size > 64*1024*1024:
                    raise ValueError('静态图像文件不能超过 64 MiB')
                static_image = cv2.imdecode(np.frombuffer(path.read_bytes(), np.uint8), cv2.IMREAD_COLOR | cv2.IMREAD_IGNORE_ORIENTATION)
                if static_image is None:
                    raise ValueError('无法解码静态图像')
                if static_image.shape[0]*static_image.shape[1] > 40_000_000:
                    raise ValueError('静态图像不能超过 4000 万像素')
            while not self.stop_event.is_set():
                tick = time.monotonic()
                context = self.metadata() if callable(self.metadata) else self.metadata
                metadata = dict(context, demonstration=self.demo, image_path=self.image_path)
                if static:
                    image = static_image
                else:
                    frame = self.provider() if self.provider else None
                    if frame is None or tick-frame.timestamp > .5:
                        previous, stable = None, 0
                        self._publish('等待新鲜的全分辨率输入…')
                        self.stop_event.wait(.2)
                        continue
                    if frame.sequence == last_sequence:
                        self.stop_event.wait(.1)
                        continue
                    last_sequence = frame.sequence
                    image = decode_frame(frame).image
                    metadata.update(sequence=frame.sequence, received_monotonic=frame.timestamp,
                                    encoding=frame.encoding)
                if self.stop_event.is_set():
                    break
                image = reference_image(image, self.options)
                gray, corners = detect_board(image, self.options.pattern)
                if self.stop_event.is_set():
                    break
                if corners is None:
                    previous, stable = None, 0
                    self._publish('未检测到完整棋盘格：请核对内角点数量，保持图卡完整入镜', image)
                else:
                    motion = float(np.sqrt(np.mean(np.sum((corners-previous)**2, axis=2)))) if previous is not None else None
                    stable = stable+1 if motion is not None and motion < 1.5 else 1
                    previous = corners.copy()
                    if static or stable >= 3:
                        report = evaluate_board(image, gray, corners, self.options, metadata)
                        report['stability'] = dict(mode='static_unverified' if static else 'three_distinct_frames',
                                                   corner_motion_rms_px=motion, stable_samples=stable)
                        report['analysis_total_ms'] = (time.monotonic()-tick)*1000
                        self._publish('演示图评估完成（非硬件测量）' if self.demo else
                                      ('静态图评估完成（未验证运动稳定性）' if static else '检测稳定，已自动更新评估'),
                                      image, corners, report, motion)
                    else:
                        self._publish(f'已检测棋盘格，等待稳定 {stable}/3（保持图卡与相机静止）', image, corners, motion=motion)
                if static:
                    self.stop_event.wait()
                    break
                self.stop_event.wait(max(.05, self.interval-(time.monotonic()-tick)))
        except (OSError, ValueError, KeyError, TypeError, cv2.error) as exc:
            self._publish(f'评估失败：{exc}')
