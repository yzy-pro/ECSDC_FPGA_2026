"""Editable device selection, with VID/PID suggestions and explicit modes."""
from dataclasses import replace
from PySide6.QtWidgets import (QDialog, QFormLayout, QComboBox, QSpinBox,
    QCheckBox, QDialogButtonBox, QLineEdit, QLabel, QPushButton, QFileDialog)
from fpga_host.devices.serial_link import ports
from fpga_host.devices.discovery import video_devices


def device_combo(items, current):
    combo = QComboBox()
    combo.setEditable(True)
    for label, value in items:
        combo.addItem(label, value)
    index = combo.findData(current)
    if index >= 0:
        combo.setCurrentIndex(index)
    else:
        combo.setEditText(current)
    return combo


def device_value(combo):
    index = combo.currentIndex()
    if index >= 0 and combo.currentText() == combo.itemText(index):
        return combo.itemData(index)
    return combo.currentText().strip()


class SettingsDialog(QDialog):
    def __init__(self, settings, screens, parent=None):
        super().__init__(parent)
        self.setWindowTitle("设备与显示设置")
        self.resize(620, 500)
        form = QFormLayout(self)
        video = video_devices()
        cameras = [(f"{path} · {name} [{vid:04x}:{pid:04x}]" if vid is not None else f"{path} · {name}", path) for path, name, vid, pid in video]
        self.camera = device_combo(cameras, settings.camera)
        self.capture = device_combo(cameras, settings.capture)
        detected = ports()
        serials = [(f"{p.device} · {p.description}", p.device) for p in detected]
        self.fpga = device_combo([("不连接", ""), *serials], settings.fpga_port)
        self.imu = device_combo([("不连接", ""), *serials], settings.imu_port)
        self.backend = device_combo([("自动（Linux 优先 FFmpeg）", "auto"), ("FFmpeg / V4L2", "ffmpeg"), ("OpenCV", "opencv")], settings.backend)
        self.backend.setEditable(False)
        self.format = device_combo([(x, x) for x in ("MJPG", "YUYV", "NV12")], settings.fourcc)
        self.format.setEditable(False)
        self.capture_format = device_combo([(x, x) for x in ("MJPG", "YUYV", "NV12")], settings.capture_fourcc)
        self.capture_format.setEditable(False)
        self.manual = QCheckBox("固定曝光（Linux V4L2 单位通常为 100 μs）")
        self.manual.setChecked(settings.manual_exposure)
        self.exposure = QSpinBox()
        self.exposure.setRange(-10000, 100000)
        self.exposure.setValue(settings.exposure)
        self.screen = device_combo([("自动选择副屏", ""), *[(f"{s.name()} · {s.size().width()}×{s.size().height()} @ {s.refreshRate():.1f} Hz", s.name()) for s in screens]], settings.screen_name)
        self.screen.setEditable(False)
        self.model = QLineEdit(settings.model_path)
        browse = QPushButton("选择 URDF…")
        browse.clicked.connect(self.browse_model)
        self.yaw = QComboBox()
        self.pitch = QComboBox()
        for combo, value in ((self.yaw, settings.yaw_sign), (self.pitch, settings.pitch_sign)):
            combo.addItem("+1", 1)
            combo.addItem("−1", -1)
            combo.setCurrentIndex(combo.findData(value))
        for title, widget in (("原始相机", self.camera), ("FPGA 采集卡", self.capture),
                ("FPGA 串口 · 10c4:ea60", self.fpga), ("IMU 串口 · 0483:5740", self.imu),
                ("采集后端", self.backend), ("原始相机格式 · 1080p60", self.format), ("采集卡格式 · 1080p60", self.capture_format),
                ("相机曝光", self.manual), ("曝光值（仅原始相机）", self.exposure),
                ("HDMI 副屏", self.screen), ("模型路径", self.model), ("", browse),
                ("Yaw 方向", self.yaw), ("Pitch 方向", self.pitch)):
            form.addRow(title, widget)
        note = QLabel("视频节点允许手动输入 /dev/videoN；Windows 使用数字索引。\n同一 USB 设备可能有多个节点，请选择支持视频捕获的节点。\n固定曝光值与后端/驱动相关；Windows 常用负数对数值。")
        note.setWordWrap(True)
        form.addRow(note)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        form.addRow(buttons)
        self.original = settings

    def browse_model(self):
        path, _ = QFileDialog.getOpenFileName(self, "选择 URDF", self.model.text(), "URDF (*.urdf)")
        if path:
            self.model.setText(path)

    def settings(self):
        return replace(self.original, camera=device_value(self.camera), capture=device_value(self.capture),
            fpga_port=device_value(self.fpga), imu_port=device_value(self.imu), backend=device_value(self.backend),
            fourcc=device_value(self.format), capture_fourcc=device_value(self.capture_format), manual_exposure=self.manual.isChecked(), exposure=self.exposure.value(),
            screen_name=device_value(self.screen), model_path=self.model.text().strip(),
            yaw_sign=self.yaw.currentData(), pitch_sign=self.pitch.currentData())
