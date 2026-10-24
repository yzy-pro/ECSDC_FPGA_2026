"""The live page gives its space to the two images."""
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QWidget, QVBoxLayout, QLabel, QSplitter
from fpga_host.ui.widgets import VideoView


class LivePage(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(10, 8, 10, 8)
        self.splitter = QSplitter(Qt.Orientation.Horizontal)
        for name, title, waiting in (
                ('raw', '原始相机', '等待原始相机'),
                ('processed', 'FPGA 处理结果', '等待 FPGA USB 采集卡')):
            panel = QWidget()
            column = QVBoxLayout(panel)
            column.setContentsMargins(6, 4, 6, 4)
            heading = QLabel(title)
            heading.setStyleSheet('font-size: 17px; font-weight: bold; color: #71d7ca;')
            view = VideoView(waiting)
            info = QLabel('未连接')
            info.setWordWrap(True)
            column.addWidget(heading)
            column.addWidget(view, 1)
            column.addWidget(info)
            self.splitter.addWidget(panel)
            setattr(self, name + '_view', view)
            setattr(self, name + '_info', info)
        self.splitter.setChildrenCollapsible(False)
        self.splitter.setSizes([700, 700])
        layout.addWidget(self.splitter, 1)
