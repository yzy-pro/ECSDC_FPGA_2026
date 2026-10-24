"""Nonmodal tools. Closing a window hides it; the main controller owns state."""
from pathlib import Path
from PySide6.QtCore import Qt
from PySide6.QtWidgets import (QDialog, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QCheckBox, QSlider, QSpinBox, QPlainTextEdit)
from fpga_host.core.model import RobotModel
from fpga_host.core.protocols import GET_STATUS, GET_SNAPSHOT, SET_STREAM
from fpga_host.ui.widgets import GammaPlot, RobotView


def tool_window(parent, title, size):
    window = QDialog(parent)
    window.setModal(False)
    window.setWindowTitle(title)
    window.resize(*size)
    return window, QVBoxLayout(window)


def show_tool(window):
    window.show()
    window.raise_()
    window.activateWindow()


class ControlWindows:
    def __init__(self, controller, demo=False):
        c = controller
        self.session, layout = tool_window(c, '设备与对照', (520, 240))
        settings_button = QPushButton('设备设置…')
        settings_button.clicked.connect(c.edit_settings)
        self.settings_button = settings_button
        self.demo_check = QCheckBox('演示模式（模拟数据，不打开硬件）')
        self.demo_check.setChecked(demo)
        layout.addWidget(settings_button)
        layout.addWidget(self.demo_check)
        row = QHBoxLayout()
        row.addWidget(QLabel('主页原图对照延时'))
        self.delay_slider = QSlider(Qt.Orientation.Horizontal)
        self.delay_spin = QSpinBox()
        for widget in (self.delay_slider, self.delay_spin):
            widget.setRange(0, 2000)
        self.delay_spin.setSuffix(' ms')
        self.delay_slider.valueChanged.connect(self.delay_spin.setValue)
        self.delay_spin.valueChanged.connect(self.delay_slider.setValue)
        self.delay_spin.valueChanged.connect(c.delay_changed)
        self.delay_spin.setValue(c.settings.delay_ms)
        row.addWidget(self.delay_slider, 1)
        row.addWidget(self.delay_spin)
        layout.addLayout(row)
        note = QLabel('仅延迟主页原图；副屏输出实时视频。\n检查实时性时可先设为 0 ms。设备设置和演示模式在停止后修改。')
        note.setWordWrap(True)
        layout.addWidget(note)
        layout.addStretch()

        self.fpga, layout = tool_window(c, 'FPGA 控制与 Gamma 遥测', (730, 590))
        self.fpga_info = QLabel('FPGA 串口 · 未连接')
        layout.addWidget(self.fpga_info)
        row = QHBoxLayout()
        self.feature_checks = []
        for text in ('镜头去畸变', '姿态矫正', '自适应 Gamma'):
            check = QCheckBox(text)
            check.setEnabled(False)
            self.feature_checks.append(check)
            row.addWidget(check)
        self.apply_button = QPushButton('应用开关')
        self.apply_button.setEnabled(False)
        self.apply_button.clicked.connect(c.apply_features)
        row.addWidget(self.apply_button)
        layout.addLayout(row)
        self.feature_state = QLabel('请求 — / 已应用 — / 支持 —')
        self.feature_state.setWordWrap(True)
        layout.addWidget(self.feature_state)
        row = QHBoxLayout()
        self.query_button = QPushButton('查询状态')
        self.query_button.clicked.connect(lambda: c.send_command(GET_STATUS))
        self.snapshot_button = QPushButton('统计快照')
        self.snapshot_button.clicked.connect(lambda: c.send_command(GET_SNAPSHOT))
        self.stream_check = QCheckBox('定时遥测')
        self.stream_check.clicked.connect(lambda checked: c.send_command(SET_STREAM, bytes((checked,))))
        for widget in (self.query_button, self.snapshot_button, self.stream_check):
            widget.setEnabled(False)
            row.addWidget(widget)
        row.addStretch()
        layout.addLayout(row)
        self.gamma_plot = GammaPlot()
        layout.addWidget(self.gamma_plot, 1)
        self.gamma_info = QLabel('Gamma · 等待统计')
        self.gamma_values = QLabel('增强前均值 —   增强后均值 —\n原始暗部 —   原始高光 —')
        self.gamma_freshness = QLabel('帧编号 — / 本地接收时间 —')
        for label in (self.gamma_info, self.gamma_values, self.gamma_freshness):
            label.setWordWrap(True)
            layout.addWidget(label)

        self.pose, layout = tool_window(c, '云台姿态 · URDF', (700, 650))
        self.imu_info = QLabel('IMU · 未连接')
        layout.addWidget(self.imu_info)
        try:
            model = RobotModel(Path(c.settings.model_path))
            error = ''
        except (OSError, ValueError, KeyError, IndexError) as exc:
            model, error = None, f'模型加载失败：{exc}'
        self.robot_view = RobotView(model, error)
        layout.addWidget(self.robot_view, 1)
        self.pose_values = QLabel('Yaw —    Pitch —    Roll —')
        layout.addWidget(self.pose_values)
        row = QHBoxLayout()
        self.zero_button = QPushButton('当前姿态设为模型零点')
        self.zero_button.setEnabled(False)
        self.zero_button.clicked.connect(c.zero_pose)
        reset = QPushButton('重置零点')
        reset.clicked.connect(c.reset_zero)
        row.addWidget(self.zero_button)
        row.addWidget(reset)
        layout.addLayout(row)
        layout.addWidget(QLabel('拖动旋转 / 滚轮缩放 · 模型仅映射 yaw / pitch，roll 显示实测读数。'))

        self.log_window, layout = tool_window(c, '运行日志', (800, 420))
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(300)
        layout.addWidget(self.log)

    def hide_all(self):
        for window in (self.session, self.fpga, self.pose, self.log_window):
            window.hide()
