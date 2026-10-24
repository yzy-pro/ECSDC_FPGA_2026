"""Application controller. Qt stays on the main thread; devices own their I/O."""
from pathlib import Path
from threading import Thread
import math
import time
from PySide6.QtCore import Qt, QTimer, Signal
from PySide6.QtGui import QGuiApplication
from PySide6.QtWidgets import (QApplication, QMainWindow, QLabel, QPushButton, QMessageBox, QToolBar, QTabWidget)
from fpga_host.core.protocols import SET_FEATURES, SET_STREAM, GET_STATUS, GET_SNAPSHOT, EXPONENTS
from fpga_host.core.model import RobotModel
from fpga_host.devices.serial_link import SerialWorker
from fpga_host.devices.video import VideoWorker
from fpga_host.devices.demo import DemoRig
from fpga_host.devices.displays import physical_modes
from fpga_host.ui.widgets import VideoView, RobotView
from fpga_host.ui.live_page import LivePage
from fpga_host.ui.control_windows import ControlWindows, show_tool
from fpga_host.ui.evaluation_page import EvaluationPage
from fpga_host.devices.evaluation import EvaluationWorker
from fpga_host.ui.settings_dialog import SettingsDialog

STYLE = """
QMainWindow, QDialog, QWidget { background: #111d2c; color: #dce8f4; font-size: 13px; }
QGroupBox { border: 1px solid #2e445c; border-radius: 5px; margin-top: 12px; padding-top: 14px; }
QGroupBox::title { subcontrol-origin: margin; left: 10px; color: #71d7ca; }
QPushButton { background: #24445a; border: 1px solid #36617a; border-radius: 4px; padding: 6px 13px; }
QPushButton:hover { background: #316078; }
QPushButton:checked { background: #126b64; }
QPushButton:disabled, QCheckBox:disabled { color: #61768a; }
QLineEdit, QSpinBox, QDoubleSpinBox, QComboBox, QPlainTextEdit { background: #0c1725; border: 1px solid #30455d; padding: 4px; }
QToolBar { spacing: 9px; padding: 8px; border-bottom: 1px solid #2e445c; }
QStatusBar { color: #9ab1c8; }
QSlider::groove:horizontal { height: 4px; background: #30455d; }
QSlider::handle:horizontal { background: #44c8b6; width: 12px; margin: -5px 0; border-radius: 6px; }
"""


def value_text(value, suffix="", precision=2):
    return "无效" if value is None else f"{value:.{precision}f}{suffix}"


def angle_difference(angle, zero):
    return (angle-zero+math.pi) % (2*math.pi) - math.pi


class MainWindow(QMainWindow):
    shutdown_finished = Signal(bool)

    def __init__(self, settings, config_path, demo=False):
        super().__init__()
        self.settings, self.config_path = settings, config_path
        self.running = self.stopping = self.closing = False
        self.camera_worker = self.capture_worker = self.fpga_worker = self.imu_worker = self.rig = None
        self.zero = (0., 0.)
        self.last_pose = None
        self.displayed_requested = None
        self.last_preview = self.last_metrics = 0
        self.evaluation_worker = None
        self.restart_safe = True
        self.setWindowTitle("ECSDC · FPGA 图像处理工作台")
        self.resize(1440, 960)
        self.setMinimumSize(1000, 720)
        self.setStyleSheet(STYLE)
        self.output = VideoView("等待原始相机")
        self.output.setWindowTitle("FPGA HDMI 输入 · 实时原始视频")
        self.output.setWindowFlags(Qt.WindowType.Window | Qt.WindowType.FramelessWindowHint)
        self.output.setCursor(Qt.CursorShape.BlankCursor)
        self.output.escaped.connect(self.output_hidden)
        self._toolbar(demo)
        self._panels(demo)
        self.timer = QTimer(self)
        self.timer.setTimerType(Qt.TimerType.PreciseTimer)
        self.timer.setInterval(16)
        self.timer.timeout.connect(self.tick)
        self.shutdown_finished.connect(self._stopped)
        self.statusBar().showMessage("就绪 · 设置设备后连接，或勾选演示模式")
        app = QApplication.instance()
        app.screenRemoved.connect(self.screen_removed)
        if demo:
            QTimer.singleShot(0, self.start)

    def _toolbar(self, demo):
        bar = QToolBar("工作台", self)
        bar.setObjectName("devices-toolbar")
        bar.setMovable(False)
        self.addToolBar(bar)
        self.connect_button = QPushButton("连接设备")
        self.connect_button.clicked.connect(self.start)
        self.stop_button = QPushButton("停止")
        self.stop_button.setEnabled(False)
        self.stop_button.clicked.connect(self.stop)
        self.output_button = QPushButton("副屏输出")
        self.output_button.setCheckable(True)
        self.output_button.setEnabled(False)
        self.output_button.clicked.connect(self.toggle_output)
        for widget in (self.connect_button, self.stop_button, self.output_button):
            bar.addWidget(widget)
        bar.addSeparator()
        self.tool_buttons = {}
        for title, name in (("设备 / 对照", "session"), ("FPGA / Gamma", "fpga"),
                            ("云台姿态", "pose"), ("日志", "log_window")):
            button = QPushButton(title)
            button.clicked.connect(lambda checked=False, name=name: show_tool(getattr(self.controls, name)))
            bar.addWidget(button)
            self.tool_buttons[name] = button
        bar.addSeparator()
        self.mode_label = QLabel("就绪")
        bar.addWidget(self.mode_label)

    def _panels(self, demo):
        self.tabs = QTabWidget()
        self.live_page = LivePage()
        self.evaluation_page = EvaluationPage(self.settings)
        self.tabs.addTab(self.live_page, "实时对照")
        self.tabs.addTab(self.evaluation_page, "标定评估")
        self.setCentralWidget(self.tabs)
        self.controls = ControlWindows(self, demo)
        # Named widget references used by the controller; construction remains
        # in page/tool modules so device logic does not depend on layouts.
        for name in ("raw_view", "processed_view", "raw_info", "processed_info"):
            setattr(self, name, getattr(self.live_page, name))
        for name in ("settings_button", "demo_check", "delay_slider", "delay_spin",
                     "fpga_info", "feature_checks", "apply_button", "feature_state", "query_button",
                     "snapshot_button", "stream_check", "gamma_plot", "gamma_info", "gamma_values",
                     "gamma_freshness", "imu_info", "robot_view", "pose_values", "zero_button", "log"):
            setattr(self, name, getattr(self.controls, name))
        self.tabs.currentChanged.connect(self.page_changed)

    def page_changed(self, index):
        self.controls.hide_all()
        if self.running:
            self.stop()
        if not self.stopping:
            self.configure_mode()

    def configure_mode(self):
        evaluation = self.tabs.currentIndex() == 1
        self.connect_button.setText("开始评估" if evaluation else "连接设备")
        self.connect_button.setEnabled(self.restart_safe and not self.stopping)
        self.tool_buttons["pose"].setEnabled(not evaluation)
        self.mode_label.setText("标定评估 · 独立运行" if evaluation else "实时对照 · 1920×1080")
        self.statusBar().showMessage("已停止；点击开始运行当前页面。评估与实时对照互斥。")

    def log_message(self, message):
        self.log.appendPlainText(f"{time.strftime('%H:%M:%S')}  {message}")

    def delay_changed(self, value):
        self.settings.delay_ms = value
        if self.camera_worker:
            self.camera_worker.set_preview_delay(value / 1000)

    def persist(self):
        try:
            self.settings.save(self.config_path)
        except OSError as exc:
            self.log_message(f"配置保存失败：{exc}")

    def edit_settings(self):
        dialog = SettingsDialog(self.settings, QGuiApplication.screens(), self)
        if dialog.exec():
            self.settings = dialog.settings()
            self.persist()
            try:
                self.robot_view.model = RobotModel(Path(self.settings.model_path))
                # Recalculate camera framing with the new model.
                new_view = RobotView(self.robot_view.model)
                self.robot_view.center, self.robot_view.radius = new_view.center, new_view.radius
                self.robot_view.reference_points = new_view.reference_points
                new_view.deleteLater()
                self.robot_view.error = ""
            except (OSError, ValueError, KeyError, IndexError) as exc:
                self.robot_view.model = None
                self.robot_view.error = str(exc)
                self.log_message(f"模型加载失败：{exc}")
            self.robot_view.update()

    def start(self):
        if self.running or self.stopping or not self.restart_safe:
            return
        if self.tabs.currentIndex() == 1:
            self.start_evaluation()
            return
        if not self.demo_check.isChecked():
            if self.settings.camera and self.settings.camera == self.settings.capture:
                QMessageBox.warning(self, "设备设置", "原始相机和采集卡不能使用同一个视频节点。")
                return
            if self.settings.fpga_port and self.settings.fpga_port == self.settings.imu_port:
                QMessageBox.warning(self, "设备设置", "FPGA 与 IMU 必须使用各自独立的串口。")
                return
        self.persist()
        self.running = True
        self._reset_display()
        if self.demo_check.isChecked():
            self.rig = DemoRig()
            workers = [self.rig]
        else:
            s = self.settings
            self.camera_worker = VideoWorker(s.camera, s.backend, s.fourcc,
                s.exposure if s.manual_exposure else None, "原始相机") if s.camera else None
            if self.camera_worker:
                self.camera_worker.set_preview_delay(s.delay_ms / 1000)
            self.capture_worker = VideoWorker(s.capture, s.backend, s.capture_fourcc, name="FPGA 采集卡", preview_seconds=.25) if s.capture else None
            self.fpga_worker = SerialWorker(s.fpga_port, "FPGA") if s.fpga_port else None
            self.imu_worker = SerialWorker(s.imu_port, "IMU") if s.imu_port else None
            workers = [w for w in (self.camera_worker, self.capture_worker, self.fpga_worker, self.imu_worker) if w]
        self.connect_button.setEnabled(False)
        self.stop_button.setEnabled(True)
        self.settings_button.setEnabled(False)
        self.demo_check.setEnabled(False)
        self.output_button.setEnabled(True)
        self.mode_label.setText("演示模式 · 模拟数据" if self.rig else "硬件模式 · 1920×1080 @60")
        for worker in workers:
            worker.start()
        self.timer.start()
        self.log_message("已启动演示" if self.rig else "开始连接设备；失败的设备每 2 秒重试")
        self.statusBar().showMessage("运行中 · 副屏输出需单独开启 · Esc 退出副屏全屏")

    def start_evaluation(self):
        page, s = self.evaluation_page, self.settings
        source = page.source.currentData()
        demo = self.demo_check.isChecked() and source != "file"
        try:
            options = page.options()
            if options.software_correct and (options.calibration is None or options.input_geometry != "distorted"):
                raise ValueError("软件去畸变需要导入内参，并选择原始畸变输入")
            if source == "file" and not page.image_path:
                raise ValueError("请先选择静态标定板图像")
            if not demo and source != "file":
                if not (s.camera if source == "camera" else s.capture):
                    raise ValueError("请在设备设置中选择评估输入")
                if source == "capture" and s.camera and s.camera == s.capture:
                    raise ValueError("原始相机和采集卡不能使用同一个视频节点")
        except ValueError as exc:
            QMessageBox.warning(self, "评估配置", str(exc))
            return
        s.eval_cols, s.eval_rows = options.pattern
        s.eval_square_mm = options.square_mm
        s.calibration_path = options.calibration.path if options.calibration else ""
        self.persist()
        self._reset_display()
        page.reset("正在启动独立评估…")
        self.running = True
        self.connect_button.setEnabled(False)
        self.stop_button.setEnabled(True)
        self.settings_button.setEnabled(False)
        self.demo_check.setEnabled(False)
        page.set_running(True)
        provider = None
        metadata = dict(source=source, transport="static" if source == "file" else s.backend)
        if not demo and source != "file":
            if s.camera:
                self.camera_worker = VideoWorker(s.camera, s.backend, s.fourcc,
                    s.exposure if s.manual_exposure else None, "原始相机", preview_enabled=False)
            if source == "capture":
                self.capture_worker = VideoWorker(s.capture, s.backend, s.capture_fourcc,
                    name="FPGA 采集卡", preview_enabled=False)
                self.fpga_worker = SerialWorker(s.fpga_port, "FPGA") if s.fpga_port else None
            selected = self.camera_worker if source == "camera" else self.capture_worker
            provider = selected.input_snapshot
            metadata.update(device=selected.device, requested_format=selected.fourcc)
        if self.fpga_worker:
            serial = self.fpga_worker
            initial = metadata.copy()
            def context():
                state = serial.snapshot()
                status = state.get("status")
                fresh = state.get("connected") and time.monotonic()-state.get("last_status", 0) < 1.5
                return dict(initial, fpga_applied_mask=status.applied_mask if status and fresh else None,
                            fpga_pending=bool(status.pending) if status and fresh else None)
            metadata = context
        self.evaluation_worker = EvaluationWorker(options, provider=provider,
            image_path=page.image_path if source == "file" else None, demo=demo, metadata=metadata)
        for worker in self._workers():
            worker.start()
        self.output_button.setEnabled(self.camera_worker is not None)
        self.mode_label.setText("标定板演示 · 非硬件数据" if demo else "标定评估 · 每秒检测")
        self.timer.start()
        self.log_message("独立评估已启动；稳定检测后自动更新，切换页面将停止当前任务")
        self.statusBar().showMessage("评估 FPGA 时可开启副屏供图；在 FPGA 窗口关闭姿态矫正和 Gamma 后测量几何。")

    def tick_evaluation(self, now):
        if self.camera_worker:
            self.camera_worker.set_full_resolution(self.output.isVisible())
            raw, connected, _ = self.camera_worker.snapshot()
            if self.output.isVisible():
                self.output.set_frame(raw if connected and raw and now-raw.timestamp < .5 else None)
        if now-self.last_metrics < .1:
            return
        self.last_metrics = now
        self.evaluation_page.show_result(self.evaluation_worker.snapshot())
        for worker in self._workers():
            for message in worker.drain_events():
                self.log_message(message)
        if self.fpga_worker:
            self.update_fpga(now)

    def _workers(self):
        return [w for w in (self.evaluation_worker, self.rig, self.camera_worker, self.capture_worker, self.fpga_worker, self.imu_worker) if w]

    def stop(self):
        if not self.running or self.stopping:
            return
        self.running, self.stopping = False, True
        self.tabs.setEnabled(False)
        self.connect_button.setEnabled(False)
        self.timer.stop()
        self.output.hide()
        self.output_button.setChecked(False)
        self.output_button.setEnabled(False)
        self.stop_button.setEnabled(False)
        self.statusBar().showMessage("正在停止后台任务…")
        workers = self._workers()
        def cleanup():
            for worker in workers:
                worker.stop()
            self.shutdown_finished.emit(all(not (w.is_alive if isinstance(w, VideoWorker)
                else w.thread.is_alive()) for w in workers))
        Thread(target=cleanup, daemon=True, name="cleanup").start()

    def _stopped(self, clean):
        self.stopping = False
        self.restart_safe = clean
        self.evaluation_worker = None
        self.tabs.setEnabled(clean)
        self.evaluation_page.set_running(not clean)
        self.evaluation_page.reset("评估已停止" if clean else "后台任务未结束，请重启程序")
        self.camera_worker = self.capture_worker = self.fpga_worker = self.imu_worker = self.rig = None
        self.connect_button.setEnabled(clean)
        self.settings_button.setEnabled(clean)
        self.demo_check.setEnabled(clean)
        self._reset_display()
        self.configure_mode()
        message = "设备已断开" if clean else "驱动未结束读取；请关闭程序并检查视频设备后重启"
        self.log_message(message)
        self.statusBar().showMessage(message)
        if self.closing:
            self.close()

    def _reset_display(self):
        self.raw_view.set_frame(None)
        self.processed_view.set_frame(None)
        self.output.set_frame(None)
        self.gamma_plot.set_stats(None)
        self.raw_info.setText("原始相机 · 未连接")
        self.processed_info.setText("FPGA 采集卡 · 未连接")
        self.fpga_info.setText("FPGA 串口 · 未连接")
        self.imu_info.setText("IMU · 未连接")
        self.gamma_info.setText("Gamma · 等待统计")
        self.gamma_values.setText("增强前均值 —   增强后均值 —\n原始暗部 —   原始高光 —")
        self.gamma_freshness.setText("帧编号 — / 本地接收时间 —")
        self.feature_state.setText("请求 — / 已应用 — / 支持 —")
        self.pose_values.setText("Yaw —    Pitch —    Roll —")
        self.last_pose = None
        self.displayed_requested = None
        self.zero = (0., 0.)
        self.robot_view.set_pose(0, 0)
        self.zero_button.setEnabled(False)
        for widget in (*self.feature_checks, self.apply_button, self.query_button, self.snapshot_button, self.stream_check):
            widget.setEnabled(False)
        for check in self.feature_checks:
            check.setChecked(False)
        self.stream_check.setChecked(False)

    def send_command(self, kind, payload=b""):
        device = self.rig or self.fpga_worker
        if device and device.send(kind, payload):
            self.log_message(f"FPGA 命令 0x{kind:02X}" + (f" · {payload.hex(' ')}" if payload else ""))
            return True
        self.log_message("FPGA 未就绪或上一命令尚未响应")
        return False

    def apply_features(self):
        device = self.rig or self.fpga_worker
        state = device.snapshot() if device else {}
        status = state.get("status")
        if status is None or status.pending:
            return
        mask = sum(1 << i for i, check in enumerate(self.feature_checks) if check.isChecked()) & status.available_mask
        if self.send_command(SET_FEATURES, bytes((mask,))):
            self.apply_button.setEnabled(False)

    def zero_pose(self):
        if self.last_pose:
            self.zero = (self.last_pose.yaw, self.last_pose.pitch)
            self.log_message("已将当前 yaw/pitch 设为模型显示零点")

    def reset_zero(self):
        self.zero = (0., 0.)

    def output_hidden(self):
        self.output_button.setChecked(False)

    def screen_removed(self, screen):
        if self.output.isVisible():
            self.output.hide()
            self.output_button.setChecked(False)
            self.log_message("显示器连接变化，已停止副屏输出")

    def toggle_output(self, checked):
        if not checked:
            self.output.hide()
            return
        screens = QGuiApplication.screens()
        primary = QGuiApplication.primaryScreen()
        screen = next((s for s in screens if s.name() == self.settings.screen_name), None) if self.settings.screen_name else next((s for s in screens if s is not primary), None)
        if screen is None or screen is primary:
            self.output_button.setChecked(False)
            QMessageBox.warning(self, "副屏输出", "请选择独立的 1920×1080 @60 Hz 副屏，并在系统中设置扩展显示。")
            return
        native_w = round(screen.size().width()*screen.devicePixelRatio())
        native_h = round(screen.size().height()*screen.devicePixelRatio())
        native_w, native_h, refresh = physical_modes().get(screen.name(), (native_w, native_h, screen.refreshRate()))
        if (native_w, native_h) != (1920, 1080) or not 59 <= refresh <= 61:
            self.output_button.setChecked(False)
            QMessageBox.warning(self, "副屏模式不匹配", f"Qt 检测到 {native_w}×{native_h} @ {refresh:.2f} Hz。\n请先在系统中设为 1920×1080 @60 Hz；分数缩放下请核对实际信号模式。")
            return
        self.output.setScreen(screen)
        self.output.setGeometry(screen.geometry())
        self.output.showFullScreen()
        self.output.activateWindow()
        self.log_message(f"副屏输出已开启：{screen.name()}（实际信号时序需系统设置确认）")

    def tick(self):
        now = time.monotonic()
        if self.evaluation_worker:
            self.tick_evaluation(now)
            return
        if self.rig:
            raw, processed = self.rig.frames()
            preview = self.rig.history.at(now-self.settings.delay_ms/1000)
            camera_ok = raw is not None
            capture_ok = processed is not None
            raw_fps = capture_fps = 60.0
            raw_preview_fps = capture_preview_fps = 30.0
        else:
            if self.camera_worker:
                self.camera_worker.set_full_resolution(self.output.isVisible())
            raw, camera_ok, raw_fps = self.camera_worker.snapshot() if self.camera_worker else (None, False, 0)
            _, capture_ok, capture_fps = self.capture_worker.snapshot() if self.capture_worker else (None, False, 0)
            preview, raw_preview_fps = self.camera_worker.preview_snapshot() if self.camera_worker else (None, 0)
            processed, capture_preview_fps = self.capture_worker.preview_snapshot() if self.capture_worker else (None, 0)
        if self.output.isVisible():
            self.output.set_frame(raw if camera_ok and raw and now-raw.timestamp < .5 else None)
        # Hardware decoders already cap preview work at 30 Hz. Polling every
        # tick avoids turning 30 Hz into ~21 Hz by rounding to 16 ms ticks.
        if not self.rig or now-self.last_preview >= 1/30:
            self.raw_view.text = "延时缓冲中…" if camera_ok else "原始相机未就绪 / 数据超时"
            self.raw_view.set_frame(preview if camera_ok else None)
            self.processed_view.set_frame(processed if capture_ok else None)
            self.last_preview = now
        if now-self.last_metrics < .1:
            return
        self.last_metrics = now
        raw_age = f"{max(0, (now-preview.timestamp)*1000):.0f}" if preview else "—"
        capture_age = f"{max(0, (now-processed.timestamp)*1000):.0f}" if processed else "—"
        self.raw_info.setText(f"{'在线' if camera_ok else '离线 / 超时'} · 采集 {raw_fps:.1f} / 预览 {raw_preview_fps:.1f} fps · 接收后 {raw_age} ms · 对照 {self.settings.delay_ms} ms")
        self.processed_info.setText(f"{'在线' if capture_ok else '离线 / 超时'} · 采集 {capture_fps:.1f} / 预览 {capture_preview_fps:.1f} fps · 接收后 {capture_age} ms")
        for worker in self._workers():
            for message in worker.drain_events():
                self.log_message(message)
        self.update_fpga(now)
        self.update_imu(now)

    def update_fpga(self, now):
        device = self.rig or self.fpga_worker
        state = device.snapshot() if device else {}
        status = state.get("status")
        ready = bool(state.get("connected") and status and now-state.get("last_status", 0) < 1.5)
        self.fpga_info.setText(("模拟 FPGA" if self.rig else "FPGA 串口") + (" · 在线" if ready else " · 未就绪 / 状态超时"))
        busy = state.get("busy", False)
        for widget in (self.query_button, self.snapshot_button, self.stream_check):
            widget.setEnabled(ready and not busy)
        self.apply_button.setEnabled(ready and not busy and not status.pending if status else False)
        refresh_checks = status and (self.displayed_requested != (status.requested_mask, status.available_mask) or status.result != 0)
        if status:
            self.displayed_requested = (status.requested_mask, status.available_mask)
        else:
            self.displayed_requested = None
            self.feature_state.setText("请求 — / 已应用 — / 支持 —（无有效状态）")
        for i, check in enumerate(self.feature_checks):
            supported = bool(status and status.available_mask & (1 << i))
            check.setEnabled(ready and supported and not busy and not status.pending if status else False)
            check.setToolTip("功能不支持" if status and not supported else "选择目标开关后点击应用")
            if refresh_checks or (status and not supported):
                check.setChecked(bool(status.requested_mask & (1 << i)) if supported else False)
        if status:
            condition = "等待输入 SOF 应用" if status.pending else ("已生效" if status.applied_mask == status.requested_mask else "状态未一致")
            self.feature_state.setText(f"请求 0x{status.requested_mask:02X} / 已应用 0x{status.applied_mask:02X} / 支持 0x{status.available_mask:02X} · {condition}\n设备接收错误 {status.receive_errors}（低8位） · 主机解析错误 {state.get('parse_errors', 0)}")
            self.stream_check.setChecked(bool(status.stream_enabled))
        gamma = state.get("gamma")
        if gamma is None:
            self.gamma_plot.set_stats(None)
            self.gamma_info.setText("Gamma · 等待有效帧统计")
            self.gamma_values.setText("增强前均值 —   增强后均值 —\n原始暗部 —   原始高光 —")
            self.gamma_freshness.setText("尚未收到统计")
            return
        self.gamma_plot.set_stats(gamma)
        self.gamma_info.setText(f"实际启用：{'是' if gamma.gamma_enabled else '否'} · 曲线 {gamma.active_curve} (γ={EXPONENTS[gamma.active_curve]:.2f}) → 目标 {gamma.target_curve} (γ={EXPONENTS[gamma.target_curve]:.2f}) · 帧掩码 0x{gamma.frame_mask:02X}")
        dark = gamma.dark_ratio*100 if gamma.dark_ratio is not None else None
        highlight = gamma.highlight_ratio*100 if gamma.highlight_ratio is not None else None
        self.gamma_values.setText(f"增强前均值 {value_text(gamma.mean_before)}   增强后均值 {value_text(gamma.mean_after)}\n原始暗部 {value_text(dark, '%')}   原始高光 {value_text(highlight, '%')} · 像素 {gamma.pixel_count:,}")
        age = max(0, now-state["last_gamma"])
        frame_age = max(0, now-state["last_frame_change"])
        freshness = "接收超时" if age > 1 else ("帧编号未更新" if frame_age > 1 else "帧编号更新中")
        if status and not status.stream_enabled:
            freshness = "定时遥测已关闭 · 保留最近快照"
        self.gamma_freshness.setText(f"输入统计帧 #{gamma.frame_index} · 本地接收距今 {age:.2f}s · {freshness}（{frame_age:.2f}s）")

    def update_imu(self, now):
        device = self.rig or self.imu_worker
        state = device.snapshot() if device else {}
        pose = state.get("pose")
        age = max(0, now-state.get("last_rx", 0))
        ready = state.get("connected") and pose and age <= .5
        self.zero_button.setEnabled(bool(ready))
        if not ready:
            self.last_pose = None
            self.imu_info.setText("IMU · 未就绪 / 超过 0.5s 无有效帧")
            self.pose_values.setText("Yaw —    Pitch —    Roll —（姿态无效）")
            return
        self.last_pose = pose
        yaw, pitch, roll = pose.degrees
        self.pose_values.setText(f"Yaw {yaw:+8.2f}°    Pitch {pitch:+8.2f}°    Roll {roll:+8.2f}°")
        self.imu_info.setText(f"{'模拟 IMU' if self.rig else 'IMU'} · 有效帧距今 {age*1000:.0f} ms · 解析错误 {state.get('parse_errors', 0)}")
        if not self.controls.pose.isVisible():
            return
        self.robot_view.set_pose(angle_difference(pose.yaw, self.zero[0])*self.settings.yaw_sign,
            angle_difference(pose.pitch, self.zero[1])*self.settings.pitch_sign)

    def closeEvent(self, event):
        if self.running or self.stopping:
            self.closing = True
            if self.running:
                self.stop()
            event.ignore()
            return
        self.persist()
        self.controls.hide_all()
        self.output.close()
        event.accept()
