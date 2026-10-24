"""Reconnectable serial workers with a single outstanding FPGA command."""
from collections import deque
from queue import Queue, Empty, Full
from threading import Event, Lock, Thread
import time
import serial
from serial.tools import list_ports
from fpga_host.core.protocols import (PacketDecoder, ImuDecoder, FpgaStatus, GammaStats,
    GET_STATUS, STATUS, GAMMA_STATS, RESULTS)
from fpga_host.core.requests import Command, RequestGate



def ports():
    return sorted(list_ports.comports(), key=lambda p: p.device)


def preferred_port(vid, pid):
    matches = [p.device for p in ports() if (p.vid, p.pid) == (vid, pid)]
    return matches[0] if len(matches) == 1 else ""


class SerialWorker:
    def __init__(self, port: str, kind: str):
        self.port, self.kind = port, kind
        self.stop_event = Event()
        self.lock = Lock()
        self.commands = Queue(maxsize=8)
        self.events = deque(maxlen=100)
        self.connected = False
        self.busy = False
        self.status = None
        self.gamma = None
        self.pose = None
        self.last_rx = self.last_status = self.last_gamma = self.last_frame_change = 0.0
        self.parse_errors = 0
        self.thread = Thread(target=self._run, name=f"serial-{kind}", daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        self.thread.join(timeout=2)

    def send(self, kind, payload=b""):
        with self.lock:
            if not self.connected or self.busy:
                return False
            self.busy = True
            try:
                self.commands.put_nowait(Command(kind, payload))
            except Full:
                self.busy = False
                return False
        return True

    def snapshot(self):
        with self.lock:
            return {k: getattr(self, k) for k in ("connected", "busy", "status", "gamma", "pose",
                "last_rx", "last_status", "last_gamma", "last_frame_change", "parse_errors")}

    def drain_events(self):
        with self.lock:
            events = list(self.events)
            self.events.clear()
            return events

    def _event(self, message):
        with self.lock:
            self.events.append(f"{self.kind}: {message}")

    def _run(self):
        while not self.stop_event.is_set():
            try:
                with serial.Serial(self.port, 115200, timeout=0.03, write_timeout=0.3,
                        xonxoff=False, rtscts=False, dsrdtr=False) as link:
                    link.reset_input_buffer()
                    self._session(link)
            except (serial.SerialException, OSError, ValueError) as exc:
                self._event(str(exc))
            finally:
                with self.lock:
                    self.connected = False
                    self.busy = False
                    self.status = self.gamma = self.pose = None
                    self.last_rx = self.last_status = self.last_gamma = self.last_frame_change = 0.0
                while True:
                    try:
                        self.commands.get_nowait()
                    except Empty:
                        break
            self.stop_event.wait(2)

    def _session(self, link):
        decoder = PacketDecoder() if self.kind == "FPGA" else ImuDecoder()
        gate = RequestGate()
        with self.lock:
            self.connected = True
        self._event(f"已连接 {self.port}")
        next_poll = 0.0
        last_bytes = time.monotonic()
        while not self.stop_event.is_set():
            now = time.monotonic()
            if self.kind == "FPGA" and gate.outstanding is None:
                try:
                    command = self.commands.get_nowait()
                except Empty:
                    command = Command(GET_STATUS) if now >= next_poll else None
                if command:
                    packet = gate.begin(command, now)
                    if link.write(packet) != len(packet):
                        raise serial.SerialException("串口写入不完整")
                    next_poll = now + 0.25
            data = link.read(min(link.in_waiting or 1, 4096))
            now = time.monotonic()
            if data:
                if self.kind == "FPGA" and now - last_bytes > 0.2:
                    decoder.clear()
                last_bytes = now
                for item in decoder.feed(data):
                    if self.kind == "IMU":
                        with self.lock:
                            self.pose, self.last_rx = item, now
                        continue
                    try:
                        if item.kind == STATUS:
                            status = FpgaStatus.decode(item.payload)
                            # Telemetry and stale ACKs cannot release the gate.
                            if gate.accept(item):
                                with self.lock:
                                    self.status, self.last_status = status, now
                                    self.busy = not self.commands.empty()
                                if status.result:
                                    self._event(RESULTS.get(status.result, f"错误 {status.result}"))
                        elif item.kind == GAMMA_STATS:
                            gamma = GammaStats.decode(item.payload)
                            with self.lock:
                                if self.gamma is None or gamma.frame_index != self.gamma.frame_index:
                                    self.last_frame_change = now
                                self.gamma, self.last_gamma = gamma, now
                        with self.lock:
                            self.last_rx = now
                    except ValueError as exc:
                        self._event(str(exc))
                with self.lock:
                    self.parse_errors = decoder.errors
            if gate.expired(now):
                # SET may already have taken effect. Reopen and query actual
                # state; never blindly replay a timed out feature command.
                raise serial.SerialException("命令响应超时；重新连接后查询实际状态")
