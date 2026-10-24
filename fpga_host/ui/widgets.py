"""Reusable Qt video, plotting and URDF widgets."""
import math
import numpy as np
from PySide6.QtCore import Qt, QPointF, QRectF, Signal
from PySide6.QtGui import QColor, QImage, QPainter, QPen, QPolygonF
from PySide6.QtWidgets import QWidget
from fpga_host.core.model import rotation
from fpga_host.core.protocols import EXPONENTS


class VideoView(QWidget):
    escaped = Signal()

    def __init__(self, text="等待视频设备", parent=None):
        super().__init__(parent)
        self.setMinimumSize(240, 135)
        self.image = None
        self.array = None
        self.sequence = None
        self.text = text
        self.setAttribute(Qt.WidgetAttribute.WA_OpaquePaintEvent)

    def set_frame(self, frame):
        if frame is None:
            if self.image is not None:
                self.image = self.array = self.sequence = None
                self.update()
            return
        if frame.sequence == self.sequence:
            return
        array = frame.image
        h, w = array.shape[:2]
        image = QImage(array.data, w, h, array.strides[0], QImage.Format.Format_BGR888)
        # Release the old QImage before its backing array. Keep both new local
        # references alive throughout the swap; no full-image copy is needed.
        self.image = image
        self.array = array
        self.sequence = frame.sequence
        self.update()

    def paintEvent(self, event):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor("#080f19"))
        if self.image is None:
            p.setPen(QColor("#91a5bb"))
            p.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter, self.text)
            return
        size = self.image.size().scaled(self.size(), Qt.AspectRatioMode.KeepAspectRatio)
        rect = QRectF((self.width()-size.width())/2, (self.height()-size.height())/2, size.width(), size.height())
        p.drawImage(rect, self.image)

    def keyPressEvent(self, event):
        if event.key() == Qt.Key.Key_Escape:
            self.escaped.emit()
            self.hide()
        else:
            super().keyPressEvent(event)

    def closeEvent(self, event):
        self.escaped.emit()
        super().closeEvent(event)


class GammaPlot(QWidget):
    def __init__(self):
        super().__init__()
        self.setMinimumHeight(125)
        self.stats = None

    def set_stats(self, stats):
        if stats != self.stats:
            self.stats = stats
            self.update()

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.fillRect(self.rect(), QColor("#0d1725"))
        area = QRectF(36, 15, max(1, self.width()-55), max(1, self.height()-40))
        p.setPen(QPen(QColor("#25364a"), 1))
        for n in range(5):
            f = n/4
            p.drawLine(QPointF(area.left(), area.bottom()-f*area.height()), QPointF(area.right(), area.bottom()-f*area.height()))
        p.setPen(QPen(QColor("#63788d"), 1, Qt.PenStyle.DashLine))
        p.drawLine(area.bottomLeft(), area.topRight())
        if self.stats:
            exponent = EXPONENTS[self.stats.active_curve] if self.stats.gamma_enabled else 1.0
            points = [QPointF(area.left()+x/255*area.width(), area.bottom()-(x/255)**exponent*area.height()) for x in range(256)]
            p.setPen(QPen(QColor("#42d3bf"), 2))
            p.drawPolyline(QPolygonF(points))
        p.setPen(QColor("#90a5bb"))
        p.drawText(4, 17, "255")
        p.drawText(22, self.height()-9, "0")
        p.drawText(self.width()-95, self.height()-9, "输入亮度 255")


class RobotView(QWidget):
    def __init__(self, model=None, error=""):
        super().__init__()
        self.setMinimumSize(280, 180)
        self.model, self.error = model, error
        self.yaw = self.pitch = 0
        self.azimuth, self.elevation, self.zoom = -.65, .6, 1.0
        self.drag = None
        self.center, self.radius = np.zeros(3), .25
        self.reference_points = None
        if model:
            points = np.concatenate([v.reshape(-1, 3) for v, color in model.geometry({})])
            low, high = points.min(axis=0), points.max(axis=0)
            self.center = (low+high)/2
            self.reference_points = points
            self.radius = max(np.linalg.norm(high-low)/2, .001)

    def set_pose(self, yaw, pitch):
        if (yaw, pitch) != (self.yaw, self.pitch):
            self.yaw, self.pitch = yaw, pitch
            self.update()

    def mousePressEvent(self, event):
        self.drag = event.position()

    def mouseMoveEvent(self, event):
        if self.drag is not None:
            delta = event.position() - self.drag
            self.azimuth += delta.x()*.008
            self.elevation = max(-1.4, min(1.4, self.elevation+delta.y()*.008))
            self.drag = event.position()
            self.update()

    def mouseReleaseEvent(self, event):
        self.drag = None

    def wheelEvent(self, event):
        self.zoom = max(.3, min(4., self.zoom * math.exp(event.angleDelta().y()/1200)))
        self.update()

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.fillRect(self.rect(), QColor("#0d1725"))
        if not self.model:
            p.setPen(QColor("#f1bb76"))
            p.drawText(self.rect().adjusted(15, 15, -15, -15), Qt.TextFlag.TextWordWrap | Qt.AlignmentFlag.AlignCenter, self.error or "未加载 URDF")
            return
        camera = (rotation([1, 0, 0], self.elevation) @ rotation([0, 0, 1], self.azimuth))[:3, :3]
        reference = (self.reference_points-self.center) @ camera.T
        extent = np.maximum(np.ptp(reference, axis=0), .001)
        projected_center = (reference.max(axis=0)+reference.min(axis=0))/2
        scale = min(self.width()*.85/extent[0], self.height()*.75/extent[2])*self.zoom
        polygons = []
        light = np.array([.3, -.5, .8])
        for triangles, color in self.model.geometry({"yaw_joint": self.yaw, "pitch_joint": self.pitch}):
            view = (triangles - self.center) @ camera.T - projected_center
            normals = np.cross(view[:, 1]-view[:, 0], view[:, 2]-view[:, 0])
            length = np.linalg.norm(normals, axis=1)
            normals /= np.maximum(length[:, None], 1e-12)
            lighting = .35+.65*np.abs(normals @ light)
            # Camera looks along +Y, with model Z pointing up.
            for triangle, shade in zip(view, lighting):
                screen = [QPointF(self.width()/2+v[0]*scale, self.height()/2-v[2]*scale) for v in triangle]
                rgb = [int(min(255, max(0, (c*.65+.25)*shade*255))) for c in color[:3]]
                polygons.append((triangle[:, 1].mean(), QPolygonF(screen), QColor(*rgb)))
        p.setPen(Qt.PenStyle.NoPen)
        for depth, polygon, color in sorted(polygons, key=lambda item: item[0], reverse=True):
            p.setBrush(color)
            p.drawPolygon(polygon)
        p.setPen(QColor("#8298af"))
        p.drawText(10, self.height()-10, "URDF · 拖动旋转 / 滚轮缩放 · yaw / pitch")
