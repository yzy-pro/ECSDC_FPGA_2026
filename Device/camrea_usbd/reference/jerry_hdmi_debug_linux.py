"""AR0234 USB camera -> a 1920x1080 Linux display.

This is the Linux counterpart of :mod:`jerry_hdmi_debug`. It captures the V4L2
MJPG stream through FFmpeg by default (with an OpenCV V4L2 fallback) and asks
``xrandr`` for the active monitors. The selected monitor must already be
configured as 1920x1080. The desktop mode is left unchanged unless
``--set-display-mode`` is requested.

Examples::

    python host/jerry_hdmi_debug_linux.py --list-monitors
    python host/jerry_hdmi_debug_linux.py --camera-index 0 --monitor 1

Press ``q`` or ``Esc`` in the preview window to stop.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass

# Some pip OpenCV wheels omit their bundled Qt font directory.  Point Qt at
# the distribution fonts before importing cv2; this only affects the preview
# GUI and avoids repeated QFontDatabase warnings on every imshow call.
if "QT_QPA_FONTDIR" not in os.environ:
    for _font_dir in (
        "/usr/share/fonts/truetype/dejavu",
        "/usr/share/fonts/truetype/liberation2",
        "/usr/share/fonts",
    ):
        if os.path.isdir(_font_dir):
            os.environ["QT_QPA_FONTDIR"] = _font_dir
            break

import cv2
import numpy as np


CAMERA_WIDTH = 1920
CAMERA_HEIGHT = 1080
CAMERA_FPS = 60.0
# V4L2 exposure_absolute is normally expressed in 100-us units. 156 is a
# 15.6-ms exposure, safely below one 60-Hz frame period and equivalent to the
# fixed 2^-6-second exposure used by the Windows DirectShow script. Drivers that expose a
# different unit may reject this value; --auto-exposure remains available.
DEFAULT_EXPOSURE = 156.0
WINDOW_NAME = "USB CAMERA AR0234 - 1920x1080@60"
MAIN_WINDOW_NAME = "USB CAMERA AR0234 - main preview"
MJPG_FOURCC = cv2.VideoWriter_fourcc(*"MJPG")


@dataclass(frozen=True)
class Monitor:
    index: int
    left: int
    top: int
    # X desktop/framebuffer rectangle occupied by this output.  Under GNOME
    # fractional scaling this can differ from the physical signal mode.
    width: int
    height: int
    mode_width: int
    mode_height: int
    device: str
    primary: bool
    refresh_hz: float | None


class LatestFrameReader:
    """Read continuously so a slow GUI cannot build camera latency."""

    def __init__(self, cap: cv2.VideoCapture) -> None:
        self.cap = cap
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.frame: np.ndarray | None = None
        self.sequence = 0
        self.capture_count = 0
        self.error: str | None = None
        self.thread = threading.Thread(target=self._capture_loop, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def _capture_loop(self) -> None:
        while not self.stop_event.is_set():
            ok, frame = self.cap.read()
            if not ok or frame is None:
                self.error = "The camera stopped returning frames."
                self.stop_event.set()
                return
            if frame.shape[:2] != (CAMERA_HEIGHT, CAMERA_WIDTH):
                self.error = (
                    f"Camera mode changed to {frame.shape[1]}x{frame.shape[0]}."
                )
                self.stop_event.set()
                return
            with self.lock:
                self.frame = frame
                self.sequence += 1
                self.capture_count += 1

    def latest(self) -> tuple[np.ndarray | None, int, int]:
        with self.lock:
            return self.frame, self.sequence, self.capture_count

    def stop(self) -> None:
        self.stop_event.set()
        self.thread.join(timeout=2.0)
        if self.thread.is_alive():
            # Releasing V4L2 normally unblocks a read waiting in the driver.
            self.cap.release()
            self.thread.join(timeout=1.0)


class FFmpegCapture:
    """Decode the camera's MJPG stream through the system FFmpeg build.

    OpenCV's V4L2 backend can decode this camera at roughly 25 fps even when
    the kernel stream delivers 60 fps. FFmpeg reads the same MJPG/V4L2 stream
    and writes BGR frames to a pipe, avoiding that backend-specific bottleneck.
    """

    def __init__(self, index: int, exposure: float | None) -> None:
        if shutil.which("ffmpeg") is None:
            raise RuntimeError("ffmpeg was not found")
        device = f"/dev/video{index}"
        set_v4l2_controls(index, exposure)
        self.width = CAMERA_WIDTH
        self.height = CAMERA_HEIGHT
        self.fps = CAMERA_FPS
        self.frame_bytes = self.width * self.height * 3
        self.process = subprocess.Popen(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-thread_queue_size",
                "64",
                "-f",
                "v4l2",
                "-input_format",
                "mjpeg",
                "-video_size",
                f"{self.width}x{self.height}",
                "-framerate",
                f"{int(self.fps)}/1",
                "-i",
                device,
                "-an",
                "-f",
                "rawvideo",
                "-pix_fmt",
                "bgr24",
                "pipe:1",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        # Give FFmpeg a moment to reject a missing device or unsupported mode.
        time.sleep(0.15)
        if self.process.poll() is not None:
            error = self.process.stderr.read().decode(errors="replace").strip()
            self.release()
            raise RuntimeError(error or f"ffmpeg could not open {device}")

    def isOpened(self) -> bool:
        return self.process.poll() is None and self.process.stdout is not None

    def read(self) -> tuple[bool, np.ndarray | None]:
        if not self.isOpened() or self.process.stdout is None:
            return False, None
        data = bytearray(self.frame_bytes)
        view = memoryview(data)
        offset = 0
        while offset < self.frame_bytes:
            chunk = self.process.stdout.read(self.frame_bytes - offset)
            if not chunk:
                return False, None
            view[offset : offset + len(chunk)] = chunk
            offset += len(chunk)
        frame = np.frombuffer(data, dtype=np.uint8).reshape(
            (self.height, self.width, 3)
        )
        return True, frame

    def get(self, property_id: int) -> float:
        if property_id == cv2.CAP_PROP_FRAME_WIDTH:
            return float(self.width)
        if property_id == cv2.CAP_PROP_FRAME_HEIGHT:
            return float(self.height)
        if property_id == cv2.CAP_PROP_FPS:
            return float(self.fps)
        if property_id == cv2.CAP_PROP_FOURCC:
            return float(MJPG_FOURCC)
        return 0.0

    def release(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=1.0)


def set_v4l2_controls(index: int, exposure: float | None) -> None:
    """Apply the camera's standard UVC exposure controls when available."""
    if exposure is None or shutil.which("v4l2-ctl") is None:
        return
    try:
        result = subprocess.run(
            [
                "v4l2-ctl",
                "-d",
                f"/dev/video{index}",
                "--set-ctrl",
                f"auto_exposure=1,exposure_time_absolute={int(exposure)}",
            ],
            capture_output=True,
            text=True,
            timeout=3,
        )
    except (OSError, subprocess.SubprocessError):
        return
    if result.returncode != 0:
        print(
            f"Warning: could not set V4L2 manual exposure on /dev/video{index}: "
            f"{(result.stderr or result.stdout).strip()}",
            file=sys.stderr,
        )
def enumerate_monitors() -> list[Monitor]:
    """Parse active outputs from ``xrandr --query``.

    xrandr is used instead of an optional Python monitor package so this file
    works with the usual X11 OpenCV builds without adding a dependency.
    """
    if shutil.which("xrandr") is None:
        raise RuntimeError("xrandr was not found; install it and ensure DISPLAY is set.")
    try:
        result = subprocess.run(
            ["xrandr", "--query"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError(
            "Could not query monitors with xrandr; check DISPLAY and X access."
        ) from exc

    monitors: list[Monitor] = []
    # Example: HDMI-1 connected primary 1920x1080+1920+0 (...)
    output_re = re.compile(
        r"^(?P<name>\S+)\s+connected(?P<primary>\s+primary)?\s+(?P<body>.*)$"
    )
    geometry_re = re.compile(r"(?P<w>\d+)x(?P<h>\d+)\+(?P<x>-?\d+)\+(?P<y>-?\d+)")
    output_lines = result.stdout.splitlines()
    for line_index, line in enumerate(output_lines):
        match = output_re.match(line)
        if not match:
            continue
        geometry = geometry_re.search(match.group("body"))
        if geometry is None:
            # An output can be connected but have no active mode.
            continue
        width = int(geometry.group("w"))
        height = int(geometry.group("h"))
        left = int(geometry.group("x"))
        top = int(geometry.group("y"))
        mode_width = width
        mode_height = height
        refresh: float | None = None
        # The following mode line containing '*' is the actual signal mode.
        # Its dimensions may differ from the connected-line geometry when
        # GNOME/XRandR fractional scaling applies a framebuffer transform.
        mode_re = re.compile(r"^\s*(?P<w>\d+)x(?P<h>\d+)\s+(?P<rates>.*)$")
        for mode_line in output_lines[line_index + 1 :]:
            if output_re.match(mode_line):
                break
            mode_match = mode_re.match(mode_line)
            if mode_match and "*" in mode_match.group("rates"):
                mode_width = int(mode_match.group("w"))
                mode_height = int(mode_match.group("h"))
                rates = re.findall(
                    r"(\d+(?:\.\d+)?)\*", mode_match.group("rates")
                )
                if rates:
                    refresh = float(rates[0])
                break
        monitors.append(
            Monitor(
                index=-1,
                left=left,
                top=top,
                width=width,
                height=height,
                mode_width=mode_width,
                mode_height=mode_height,
                device=match.group("name"),
                primary=bool(match.group("primary")),
                refresh_hz=refresh,
            )
        )

    # Keep the primary output at index 0, matching the Windows script's
    # predictable indexing, then preserve xrandr's left-to-right order.
    monitors.sort(key=lambda item: (not item.primary, item.left, item.top))
    return [
        Monitor(
            index=i,
            left=monitor.left,
            top=monitor.top,
            width=monitor.width,
            height=monitor.height,
            mode_width=monitor.mode_width,
            mode_height=monitor.mode_height,
            device=monitor.device,
            primary=monitor.primary,
            refresh_hz=monitor.refresh_hz,
        )
        for i, monitor in enumerate(monitors)
    ]


def choose_monitor(monitors: list[Monitor], requested: int | None) -> Monitor:
    if requested is not None:
        if not 0 <= requested < len(monitors):
            raise RuntimeError(
                f"Monitor index {requested} does not exist; found {len(monitors)} active monitor(s)."
            )
        monitor = monitors[requested]
        if (monitor.mode_width, monitor.mode_height) != (
            CAMERA_WIDTH,
            CAMERA_HEIGHT,
        ):
            raise RuntimeError(
                f"Monitor {requested} signal mode is "
                f"{monitor.mode_width}x{monitor.mode_height}, "
                f"not {CAMERA_WIDTH}x{CAMERA_HEIGHT}. Its desktop rectangle "
                f"is {monitor.width}x{monitor.height}."
            )
        return monitor
    candidates = [
        monitor for monitor in monitors
        if not monitor.primary
        and (monitor.mode_width, monitor.mode_height)
        == (CAMERA_WIDTH, CAMERA_HEIGHT)
    ]
    if candidates:
        return candidates[0]
    details = "\n".join(
        f"  {m.index}: {m.device} at ({m.left},{m.top}) "
        f"desktop {m.width}x{m.height}; signal "
        f"{m.mode_width}x{m.mode_height}@{m.refresh_hz or '?'} Hz"
        f"{' primary' if m.primary else ''}" for m in monitors
    )
    raise RuntimeError(
        "No secondary 1920x1080 monitor was found.\n"
        + details
        + "\nSet the HDMI output to 1920x1080@60 first, or rerun with "
        "--set-display-mode if that mode is listed by xrandr."
    )


def set_display_mode(monitor: Monitor) -> None:
    """Ask xrandr to switch one output to the FPGA's required timing."""
    if shutil.which("xrandr") is None:
        raise RuntimeError("xrandr was not found; cannot set the display mode.")
    command = [
        "xrandr",
        "--output",
        monitor.device,
        "--mode",
        f"{CAMERA_WIDTH}x{CAMERA_HEIGHT}",
        "--rate",
        f"{int(CAMERA_FPS)}",
    ]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError(f"Could not run {' '.join(command)}.") from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(
            f"xrandr could not set {monitor.device} to "
            f"{CAMERA_WIDTH}x{CAMERA_HEIGHT}@{int(CAMERA_FPS)}. "
            f"{detail or 'The mode may not be available.'}"
        )


def monitor_for_mode_change(monitors: list[Monitor], requested: int | None) -> Monitor:
    """Select an output before changing its mode, allowing its current size."""
    if requested is not None:
        if not 0 <= requested < len(monitors):
            raise RuntimeError(
                f"Monitor index {requested} does not exist; found {len(monitors)} active monitor(s)."
            )
        return monitors[requested]
    candidates = [monitor for monitor in monitors if not monitor.primary]
    if candidates:
        return candidates[0]
    if monitors:
        return monitors[0]
    raise RuntimeError("xrandr reported no active monitors.")


def configure_camera(cap: cv2.VideoCapture, exposure: float | None) -> None:
    """Request the low-latency V4L2 mode; unsupported controls are harmless."""
    # Apply exposure before negotiating the media type. Some UVC drivers
    # rebuild their streaming state when this control changes, which can
    # otherwise discard the requested MJPG/1080p60 format.
    if exposure is not None:
        cap.set(cv2.CAP_PROP_AUTO_EXPOSURE, 0.25)
        cap.set(cv2.CAP_PROP_EXPOSURE, exposure)
    cap.set(cv2.CAP_PROP_FOURCC, MJPG_FOURCC)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, CAMERA_WIDTH)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, CAMERA_HEIGHT)
    cap.set(cv2.CAP_PROP_FPS, CAMERA_FPS)
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)


def fourcc_text(value: float) -> str:
    number = int(value)
    return "".join(chr((number >> (8 * shift)) & 0xFF) for shift in range(4))


def try_camera(
    index: int,
    backend: int | str,
    exposure: float | None,
) -> tuple[object | None, float, str]:
    if backend == "ffmpeg":
        try:
            cap: object = FFmpegCapture(index, exposure)
        except (OSError, RuntimeError) as exc:
            return None, 0.0, str(exc)
    else:
        cap = cv2.VideoCapture(index, backend)
    if not cap.isOpened():
        cap.release()
        return None, 0.0, "could not open"
    if backend != "ffmpeg":
        configure_camera(cap, exposure)  # type: ignore[arg-type]
    started = time.perf_counter()
    frames = 0
    frame: np.ndarray | None = None
    while frames < 20 and time.perf_counter() - started < 2.5:
        ok, frame = cap.read()
        if not ok or frame is None:
            break
        frames += 1
    elapsed = time.perf_counter() - started
    fps = frames / elapsed if elapsed > 0 else 0.0
    if frame is None:
        cap.release()
        return None, fps, "opened but returned no frames"
    if frame.shape[:2] != (CAMERA_HEIGHT, CAMERA_WIDTH):
        shape = f"{frame.shape[1]}x{frame.shape[0]}"
        cap.release()
        return None, fps, f"returned {shape}"
    return cap, fps, f"{fourcc_text(cap.get(cv2.CAP_PROP_FOURCC))!r}, measured {fps:.2f} fps"


def open_camera(requested_index: int | None, max_index: int, exposure: float | None,
                backend_choice: str, status_callback: Callable[[str], None] | None = None
                ) -> tuple[object, int, str, float]:
    v4l2 = getattr(cv2, "CAP_V4L2", cv2.CAP_ANY)
    if backend_choice == "ffmpeg":
        backends: list[tuple[int | str, str]] = [("ffmpeg", "FFmpeg/V4L2")]
    elif backend_choice == "v4l2":
        backends = [(v4l2, "V4L2")]
    elif backend_choice == "any":
        backends = [(cv2.CAP_ANY, "default")]
    else:
        # FFmpeg avoids the slow MJPG decode path in OpenCV's V4L2 backend.
        # If it is unavailable, the normal V4L2 probe remains a fallback.
        backends = [("ffmpeg", "FFmpeg/V4L2"), (v4l2, "V4L2")]
    indices = [requested_index] if requested_index is not None else range(max_index + 1)
    attempts: list[str] = []
    best: tuple[object, int, str, float] | None = None
    for index in indices:
        assert index is not None
        for backend, backend_name in backends:
            status = f"Testing camera {index}: {backend_name} / MJPG 1080p60"
            print(status, flush=True)
            if status_callback:
                status_callback(status)
            cap, fps, result = try_camera(index, backend, exposure)
            attempts.append(f"camera {index}, {backend_name}: {result}")
            print(f"  {result}", flush=True)
            if cap is None:
                continue
            candidate = (cap, index, backend_name, fps)
            # Keep a genuinely fast mode immediately; otherwise retain the
            # fastest successful probe for the fallback below.
            if fps >= 45.0:
                if best is not None:
                    best[0].release()
                return candidate
            if best is None or fps > best[3]:
                if best is not None:
                    best[0].release()
                best = candidate
            else:
                cap.release()
        if best is not None and best[3] >= 50.0:
            break
    if best is not None:
        print("Camera mode probes:\n" + "\n".join(f"  {item}" for item in attempts))
        print(f"Warning: using fastest available mode at {best[3]:.2f} fps.", file=sys.stderr)
        return best
    raise RuntimeError("No camera could provide 1920x1080 frames.\n" + "\n".join(f"  {item}" for item in attempts))


def create_video_window(monitor: Monitor, windowed: bool) -> None:
    cv2.namedWindow(WINDOW_NAME, cv2.WINDOW_NORMAL)
    cv2.moveWindow(WINDOW_NAME, monitor.left, monitor.top)
    cv2.resizeWindow(WINDOW_NAME, monitor.width, monitor.height)
    cv2.imshow(
        WINDOW_NAME,
        np.zeros((monitor.height, monitor.width, 3), dtype=np.uint8),
    )
    cv2.waitKey(1)
    if not windowed:
        cv2.setWindowProperty(WINDOW_NAME, cv2.WND_PROP_FULLSCREEN, cv2.WINDOW_FULLSCREEN)


def create_main_preview_window(monitor: Monitor) -> tuple[int, int]:
    """Create a smaller window on the primary desktop for local monitoring."""
    width = min(1280, max(640, monitor.width // 2))
    height = round(width * CAMERA_HEIGHT / CAMERA_WIDTH)
    left = monitor.left + 40
    top = monitor.top + 40
    cv2.namedWindow(MAIN_WINDOW_NAME, cv2.WINDOW_NORMAL)
    cv2.moveWindow(MAIN_WINDOW_NAME, left, top)
    cv2.resizeWindow(MAIN_WINDOW_NAME, width, height)
    cv2.imshow(
        MAIN_WINDOW_NAME,
        np.zeros((CAMERA_HEIGHT, CAMERA_WIDTH, 3), dtype=np.uint8),
    )
    cv2.waitKey(1)
    return width, height


def show_status(
    message: str,
    subtitle: str = "Please wait...",
    main_window: bool = False,
) -> None:
    canvas = np.zeros((CAMERA_HEIGHT, CAMERA_WIDTH, 3), dtype=np.uint8)
    font = cv2.FONT_HERSHEY_SIMPLEX
    for text, scale, y, color in ((message, 1.2, 520, (255, 255, 255)),
                                  (subtitle, 0.8, 580, (180, 180, 180))):
        (width, _), _ = cv2.getTextSize(text, font, scale, 2)
        cv2.putText(canvas, text, (max(30, (CAMERA_WIDTH - width) // 2), y),
                    font, scale, color, 2, cv2.LINE_AA)
    cv2.imshow(WINDOW_NAME, canvas)
    if main_window:
        cv2.imshow(MAIN_WINDOW_NAME, canvas)
    cv2.waitKey(1)


def run(cap: cv2.VideoCapture, camera_index: int, backend_name: str,
        probe_fps: float, monitor: Monitor, main_window: bool,
        main_size: tuple[int, int] | None) -> None:
    print(f"Camera index: {camera_index} ({backend_name})")
    print(f"Driver reports: {int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))}x"
          f"{int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))}, "
          f"{fourcc_text(cap.get(cv2.CAP_PROP_FOURCC))!r}, "
          f"{cap.get(cv2.CAP_PROP_FPS):g} fps")
    print(f"Measured camera delivery during probe: {probe_fps:.2f} fps")
    print(
        f"Display {monitor.index}: {monitor.device} at "
        f"({monitor.left},{monitor.top}), desktop {monitor.width}x{monitor.height}; "
        f"signal {monitor.mode_width}x{monitor.mode_height}@"
        f"{monitor.refresh_hz or '?'} Hz"
    )
    print("Press Esc or Q in the video window to stop.")
    reader = LatestFrameReader(cap)
    reader.start()
    last_sequence = -1
    displayed_frames = 0
    started = time.perf_counter()
    last_report = started
    last_main_update = 0.0
    target_size = (monitor.width, monitor.height)
    try:
        while True:
            frame, sequence, capture_count = reader.latest()
            if reader.error:
                raise RuntimeError(reader.error)
            key = cv2.waitKey(1) & 0xFF
            if key in (27, ord("q"), ord("Q")):
                break
            if cv2.getWindowProperty(WINDOW_NAME, cv2.WND_PROP_VISIBLE) < 1:
                break
            if frame is not None and sequence != last_sequence:
                # GNOME may expose a 3840x2160 desktop rectangle for a
                # physical 1920x1080 output. Resize explicitly so Qt does not
                # perform an expensive implicit scale during every repaint.
                target_frame = frame
                if target_size != (CAMERA_WIDTH, CAMERA_HEIGHT):
                    target_frame = cv2.resize(
                        frame, target_size, interpolation=cv2.INTER_NEAREST
                    )
                cv2.imshow(WINDOW_NAME, target_frame)
                if main_window:
                    # Closing the auxiliary window should not stop the HDMI
                    # output; simply stop submitting frames to that window.
                    now = time.perf_counter()
                    if (
                        main_size is not None
                        and now - last_main_update >= 1.0 / 15.0
                        and cv2.getWindowProperty(
                            MAIN_WINDOW_NAME, cv2.WND_PROP_VISIBLE
                        ) >= 1
                    ):
                        cv2.imshow(
                            MAIN_WINDOW_NAME,
                            cv2.resize(frame, main_size, interpolation=cv2.INTER_AREA),
                        )
                        last_main_update = now
                last_sequence = sequence
                displayed_frames += 1
            now = time.perf_counter()
            if now - last_report >= 5.0:
                elapsed = now - started
                print(
                    f"Measured capture: {capture_count / elapsed:.2f} fps; "
                    f"display updates: {displayed_frames / elapsed:.2f} fps",
                    flush=True,
                )
                last_report = now
            time.sleep(0.001)
    finally:
        reader.stop()
        cap.release()
        cv2.destroyAllWindows()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--camera-index", type=int, help="/dev/video index; default probes 0..N")
    parser.add_argument("--max-camera-index", type=int, default=3)
    parser.add_argument("--monitor", type=int, help="xrandr monitor index; default is a secondary 1080p output")
    parser.add_argument(
        "--backend",
        choices=("auto", "ffmpeg", "v4l2", "any"),
        default="auto",
        help="capture backend; auto prefers FFmpeg MJPG decoding (default)",
    )
    parser.add_argument(
        "--exposure",
        type=float,
        default=DEFAULT_EXPOSURE,
        help=(
            "V4L2 exposure value (usually 100-us units); default 156 "
            "(15.6 ms, manual exposure)"
        ),
    )
    parser.add_argument("--auto-exposure", action="store_true", help="do not change exposure")
    parser.add_argument(
        "--set-display-mode",
        action="store_true",
        help="switch the selected xrandr output to 1920x1080@60 before starting",
    )
    parser.add_argument(
        "--no-main-window",
        action="store_true",
        help="only show the fullscreen HDMI preview; do not open a main-screen window",
    )
    parser.add_argument("--windowed", action="store_true", help="do not make the preview fullscreen")
    parser.add_argument("--list-monitors", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    monitors = enumerate_monitors()
    if args.list_monitors:
        for monitor in monitors:
            print(
                f"{monitor.index}: {monitor.device} at ({monitor.left},{monitor.top}) "
                f"desktop {monitor.width}x{monitor.height}; "
                f"signal {monitor.mode_width}x{monitor.mode_height}@"
                f"{monitor.refresh_hz or '?'} Hz"
                f"{' primary' if monitor.primary else ''}"
            )
        return
    if args.set_display_mode:
        mode_monitor = monitor_for_mode_change(monitors, args.monitor)
        print(
            f"Switching {mode_monitor.device} to "
            f"{CAMERA_WIDTH}x{CAMERA_HEIGHT}@{int(CAMERA_FPS)} ...",
            flush=True,
        )
        set_display_mode(mode_monitor)
        # xrandr applies the new geometry asynchronously on some desktop
        # environments; query it again rather than using stale coordinates.
        time.sleep(0.5)
        monitors = enumerate_monitors()
    monitor = choose_monitor(monitors, args.monitor)
    primary_monitor = next((item for item in monitors if item.primary), None)
    if primary_monitor is monitor:
        primary_monitor = next(
            (item for item in monitors if item.index != monitor.index), None
        )
    main_window = primary_monitor is not None and not args.no_main_window
    main_size: tuple[int, int] | None = None
    create_video_window(monitor, args.windowed)
    if main_window:
        assert primary_monitor is not None
        main_size = create_main_preview_window(primary_monitor)
    show_status(
        "Opening USB CAMERA AR0234",
        "Testing 1920x1080 at 60 fps...",
        main_window=main_window,
    )
    try:
        cap, camera_index, backend_name, probe_fps = open_camera(
            args.camera_index, args.max_camera_index,
            None if args.auto_exposure else args.exposure,
            args.backend,
            status_callback=lambda status: show_status(
                status, main_window=main_window
            ),
        )
    except Exception as exc:
        show_status(
            "Camera initialization failed",
            str(exc)[:100],
            main_window=main_window,
        )
        raise
    run(cap, camera_index, backend_name, probe_fps, monitor, main_window, main_size)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        cv2.destroyAllWindows()
    except Exception as exc:
        cv2.destroyAllWindows()
        print(f"Error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
