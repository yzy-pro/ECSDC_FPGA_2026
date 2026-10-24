"""Calibration evaluation page: configuration, annotated image and report."""
import json
from pathlib import Path
import cv2
from PySide6.QtCore import Qt, QPointF
from PySide6.QtGui import QColor, QPainter, QPen, QPolygonF
from PySide6.QtWidgets import (QWidget, QVBoxLayout, QHBoxLayout, QFormLayout, QLabel,
    QPushButton, QSpinBox, QDoubleSpinBox, QComboBox, QCheckBox, QFileDialog,
    QMessageBox, QSplitter, QTableWidget, QTableWidgetItem, QHeaderView, QPlainTextEdit,
    QScrollArea, QTabWidget)
from fpga_host.core.buffering import VideoFrame
from fpga_host.evaluation.calibration import load_calibration
from fpga_host.evaluation.analyzer import EvaluationOptions
from fpga_host.ui.widgets import VideoView


class SfrPlot(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMinimumHeight(155)
        self.curves = []

    def set_report(self, report):
        self.curves = [edge for edge in report['sfr']['edges'] if edge['valid']] if report else []
        self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.fillRect(self.rect(), QColor('#0c1725'))
        left, top, width, height = 42, 15, max(1, self.width()-58), max(1, self.height()-43)
        painter.setPen(QColor('#536b80'))
        painter.drawRect(left, top, width, height)
        painter.drawText(3, top+5, '1.0')
        painter.drawText(3, top+height, '0')
        painter.drawText(left, self.height()-7, '0')
        painter.drawText(max(left, self.width()-160), self.height()-7, '0.5 cycles/pixel')
        painter.setPen(QPen(QColor('#6c7e90'), 1, Qt.PenStyle.DashLine))
        painter.drawLine(left, top+height//2, left+width, top+height//2)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        for curve in self.curves:
            painter.setPen(QPen(QColor(80, 210, 185, 110), 1))
            points = QPolygonF([QPointF(left+f/.5*width, top+(1-min(1.15, max(0, s)))*height)
                                for f, s in zip(curve['frequency_cy_px'], curve['sfr'])])
            painter.drawPolyline(points)
        if not self.curves:
            painter.setPen(QColor('#91a5bb'))
            painter.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter, 'SFR · 等待有效斜边')


class EvaluationPage(QWidget):
    def __init__(self, settings, parent=None):
        super().__init__(parent)
        self.last_result = None
        self.revision = None
        self.calibration = None
        self.image_path = None
        layout = QVBoxLayout(self)
        intro = QLabel('自动检测棋盘格 → 连续 3 次稳定检测 → 全分辨率评估。请平整放置图卡、旋转约 5°、固定曝光和对焦。')
        intro.setWordWrap(True)
        layout.addWidget(intro)
        self.splitter = QSplitter(Qt.Orientation.Horizontal)
        left = QWidget()
        column = QVBoxLayout(left)
        self.view = VideoView('选择输入后点击“开始评估”；也可导入静态图像')
        self.state = QLabel('未启动 · 主功能与评估独立运行')
        self.state.setWordWrap(True)
        column.addWidget(self.view, 1)
        column.addWidget(self.state)
        self.splitter.addWidget(left)
        self.details = QTabWidget()
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        panel = QWidget()
        side = QVBoxLayout(panel)
        form = QFormLayout()
        self.source = QComboBox()
        for text, data in (('原始相机', 'camera'), ('FPGA 采集卡', 'capture'), ('静态图像', 'file')):
            self.source.addItem(text, data)
        form.addRow('输入', self.source)
        self.file_button = QPushButton('选择静态图像…')
        self.file_button.clicked.connect(self.choose_image)
        form.addRow(self.file_button)
        self.file_label = QLabel('未选择图像')
        self.file_label.setWordWrap(True)
        form.addRow(self.file_label)
        row = QHBoxLayout()
        self.cols, self.rows = QSpinBox(), QSpinBox()
        for widget, value in ((self.cols, settings.eval_cols), (self.rows, settings.eval_rows)):
            widget.setRange(3, 30)
            widget.setValue(value)
        row.addWidget(self.cols)
        row.addWidget(QLabel('列 ×'))
        row.addWidget(self.rows)
        row.addWidget(QLabel('行'))
        form.addRow('内角点（非方格数）', row)
        self.square = QDoubleSpinBox()
        self.square.setRange(.1, 1000)
        self.square.setValue(settings.eval_square_mm)
        self.square.setSuffix(' mm')
        form.addRow('方格边长', self.square)
        self.geometry = QComboBox()
        self.geometry.addItem('原始畸变图像', 'distorted')
        self.geometry.addItem('已矫正图像（输出内参同输入）', 'corrected')
        form.addRow('输入几何', self.geometry)
        self.source.currentIndexChanged.connect(self.source_changed)
        self.response = QComboBox()
        for text, value in (('未知响应 · 相对 SFR', 'unknown'), ('线性亮度', 'linear'), ('已知 sRGB · 反变换', 'srgb')):
            self.response.addItem(text, value)
        form.addRow('亮度响应', self.response)
        self.calibration_button = QPushButton('导入标定参数 JSON / YAML…')
        self.calibration_button.clicked.connect(self.choose_calibration)
        clear = QPushButton('清除标定')
        clear.clicked.connect(lambda: self.set_calibration(None))
        self.clear_calibration = clear
        row = QHBoxLayout()
        row.addWidget(self.calibration_button)
        row.addWidget(clear)
        form.addRow(row)
        self.calibration_info = QLabel('未加载内参；可评估直线度与相对 SFR')
        self.calibration_info.setWordWrap(True)
        form.addRow(self.calibration_info)
        self.software = QCheckBox('先软件去畸变再评估（仅原始畸变输入）')
        self.software.setToolTip('使用已导入的内参和畸变系数生成软件参考，不修改 FPGA 参数。')
        form.addRow(self.software)
        self.rms_limit, self.p95_limit = QDoubleSpinBox(), QDoubleSpinBox()
        for spin, value in ((self.rms_limit, .3), (self.p95_limit, .5)):
            spin.setRange(.01, 20)
            spin.setDecimals(2)
            spin.setValue(value)
            spin.setSuffix(' px')
        row = QHBoxLayout()
        row.addWidget(self.rms_limit)
        row.addWidget(self.p95_limit)
        form.addRow('直线度 RMS / P95 阈值', row)
        side.addLayout(form)
        side.addStretch()
        scroll.setWidget(panel)
        self.details.addTab(scroll, '评估参数')
        results = QWidget()
        result_layout = QVBoxLayout(results)
        self.export_button = QPushButton('导出当前评估报告 JSON…')
        self.export_button.setEnabled(False)
        self.export_button.clicked.connect(self.export_report)
        result_layout.addWidget(self.export_button)
        self.table = QTableWidget(0, 2)
        self.table.setHorizontalHeaderLabels(['指标', '当前结果'])
        self.table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        self.table.verticalHeader().hide()
        self.table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.table.setMinimumHeight(285)
        result_layout.addWidget(self.table, 2)
        self.plot = SfrPlot()
        result_layout.addWidget(self.plot, 1)
        self.notes = QPlainTextEdit()
        self.notes.setReadOnly(True)
        self.notes.setMinimumHeight(130)
        result_layout.addWidget(self.notes, 1)
        self.details.addTab(results, '测量结果')
        self.details.setMinimumWidth(410)
        self.splitter.addWidget(self.details)
        self.splitter.setSizes([880, 450])
        layout.addWidget(self.splitter, 1)
        self.inputs = [self.source, self.file_button, self.cols, self.rows, self.square,
                       self.geometry, self.response, self.calibration_button, self.clear_calibration,
                       self.software, self.rms_limit, self.p95_limit]
        for control in (self.cols, self.rows, self.square, self.rms_limit, self.p95_limit):
            control.valueChanged.connect(self.invalidate)
        for control in (self.geometry, self.response, self.source):
            control.currentIndexChanged.connect(self.invalidate)
        self.software.toggled.connect(self.invalidate)
        if settings.calibration_path:
            self.set_calibration(settings.calibration_path)

    def source_changed(self):
        self.geometry.setCurrentIndex(1 if self.source.currentData() == 'capture' else 0)
        self.software.setChecked(False)

    def choose_image(self):
        path, _ = QFileDialog.getOpenFileName(self, '选择标定板图像', '', '图像 (*.png *.jpg *.jpeg *.bmp *.tif *.tiff)')
        if path:
            self.set_image_path(path)

    def set_image_path(self, path):
        self.image_path = str(path)
        self.file_label.setText(Path(path).name)
        self.file_label.setToolTip(str(path))
        self.source.setCurrentIndex(self.source.findData('file'))
        self.invalidate()

    def choose_calibration(self):
        path, _ = QFileDialog.getOpenFileName(self, '导入标定参数', '', '标定文件 (*.json *.yaml *.yml)')
        if path:
            self.set_calibration(path)

    def set_calibration(self, path):
        try:
            calibration = load_calibration(path) if path else None
        except (OSError, ValueError, KeyError, TypeError, cv2.error) as exc:
            # A failed replacement must not silently retain an older calibration.
            self.calibration = None
            self.calibration_info.setText(f'标定参数无效：{exc}')
            self.invalidate()
            return False
        self.calibration = calibration
        if calibration:
            k = calibration.matrix
            self.calibration_info.setText(f'{Path(calibration.path).name} · {calibration.size[0]}×{calibration.size[1]}\n'
                f'fx={k[0,0]:.4f}  fy={k[1,1]:.4f}\ncx={k[0,2]:.4f}  cy={k[1,2]:.4f}\n'
                f'D={calibration.distortion.tolist()}\n{calibration.convention}；仅 PC 参考，未下发 FPGA')
        else:
            self.calibration_info.setText('未加载内参；可评估直线度与相对 SFR')
        self.invalidate()
        return True

    def options(self):
        return EvaluationOptions(pattern=(self.cols.value(), self.rows.value()), square_mm=self.square.value(),
            response=self.response.currentData(), rms_limit_px=self.rms_limit.value(),
            p95_limit_px=self.p95_limit.value(), calibration=self.calibration,
            software_correct=self.software.isChecked(), input_geometry=self.geometry.currentData())

    def set_running(self, running):
        for widget in self.inputs:
            widget.setEnabled(not running)

    def invalidate(self, *_):
        self.last_result = None
        self.export_button.setEnabled(False)
        self.table.setRowCount(0)
        self.plot.set_report(None)
        self.view.set_frame(None)
        self.notes.setPlainText('仅在棋盘格覆盖区域评估。SFR 为相对测量，非 ISO 12233 认证。\n'
                                '几何测试建议关闭姿态矫正与自适应 Gamma，固定曝光；MJPEG 压缩会影响结果。')

    def reset(self, message='未启动'):
        self.invalidate()
        self.revision = None
        self.view.set_frame(None)
        self.state.setText(message)

    def show_result(self, result):
        if result is None or result['revision'] == self.revision:
            return
        self.revision = result['revision']
        self.state.setText(result['state'])
        image = result['image']
        self.view.set_frame(VideoFrame(result['timestamp'], self.revision, image) if image is not None else None)
        report = result['report']
        first_report = self.last_result is None
        self.last_result = report
        self.export_button.setEnabled(report is not None)
        self.plot.set_report(report)
        if report is None:
            self.table.setRowCount(0)
            self.notes.setPlainText('当前没有有效测量。保持棋盘格完整入镜并静止，实时输入需连续三次稳定检测。')
            return
        if first_report:
            self.details.setCurrentIndex(1)
        g, sfr = report['geometry'], report['sfr']
        edge, corner = g['edge_straightness'], g['corner_straightness']
        def number(value, suffix='', digits=3):
            return '不可用' if value is None else f'{value:.{digits}f}{suffix}'
        verdict = {'within_limits': '采样直线度在阈值内', 'exceeds_limits': '采样直线度超出阈值',
                   'insufficient_samples': '直线度有效采样不足'}[report['straightness_verdict']]
        rows = [
            ('直线度判定（局部）', verdict),
            ('边缘直线度 RMS', number(edge['rms_px'] if edge else None, ' px')),
            ('边缘直线度 P95', number(edge['p95_px'] if edge else None, ' px')),
            ('边缘直线度最大值', number(edge['max_px'] if edge else None, ' px')),
            ('角点直线度 RMS', number(corner['rms_px'], ' px')),
            ('网格单应拟合 RMS', number(g['grid_homography_residual']['rms_px'] if g['grid_homography_residual'] else None, ' px')),
            ('标定重投影 RMS', number(report['reprojection']['rms_px'] if report['reprojection'] else None, ' px')),
            ('MTF50 中位数', number(sfr['mtf50_median_cy_px'], ' cy/px')),
            ('最大边缘过冲', number(max((e['overshoot'] for e in sfr['edges'] if e['valid']), default=None)*100
                if sfr['valid_edges'] else None, ' %', 1)),
            ('最大边缘欠冲', number(max((e['undershoot'] for e in sfr['edges'] if e['valid']), default=None)*100
                if sfr['valid_edges'] else None, ' %', 1)),
            ('有效 SFR 边缘', f"{sfr['valid_edges']} / {sfr['attempted_edges']}"),
            ('边缘有效采样率', number(g['edge_sample_valid_ratio']*100 if g['edge_sample_valid_ratio'] is not None else None, ' %', 1)),
            ('棋盘格覆盖面积', number(g['coverage_ratio']*100, ' %', 1)),
            ('分析耗时', number(report.get('analysis_total_ms'), ' ms', 0)),
        ]
        self.table.setRowCount(len(rows))
        for r, (key, value) in enumerate(rows):
            self.table.setItem(r, 0, QTableWidgetItem(key))
            self.table.setItem(r, 1, QTableWidgetItem(value))
        self.notes.setPlainText('\n'.join(report['notes']) + '\n绿色框：有效 SFR；橙色框：条件不足。\n'
                                '不自动给出整机合格结论；无全幅断裂、拉伸或 MTF 保持率判定。')

    def export_report(self):
        if not self.last_result:
            return
        path, _ = QFileDialog.getSaveFileName(self, '导出当前评估报告', 'calibration-evaluation.json', 'JSON (*.json)')
        if path:
            try:
                self.save_report(path)
            except (OSError, ValueError) as exc:
                QMessageBox.warning(self, '导出失败', str(exc))

    def save_report(self, path):
        if not self.last_result:
            raise ValueError('当前没有有效报告')
        path = Path(path)
        temporary = path.with_suffix(path.suffix + '.tmp')
        temporary.write_text(json.dumps(self.last_result, ensure_ascii=False, indent=2, allow_nan=False), encoding='utf-8')
        temporary.replace(path)
