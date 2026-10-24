"""Board detection and complete reports. All coordinates refer to input pixels."""
from dataclasses import dataclass
from datetime import datetime
import time
import cv2
import numpy as np
from fpga_host.evaluation.geometry import geometry_metrics
from fpga_host.evaluation.sfr import board_sfr


@dataclass(frozen=True)
class EvaluationOptions:
    pattern: tuple = (9, 6)  # Inner corners: columns, rows; not square counts.
    square_mm: float = 25.
    response: str = 'unknown'
    rms_limit_px: float = .3
    p95_limit_px: float = .5
    calibration: object = None
    software_correct: bool = False
    input_geometry: str = 'distorted'

    def __post_init__(self):
        if len(self.pattern) != 2 or any(type(v) is not int or not 3 <= v <= 30 for v in self.pattern):
            raise ValueError('内角点行列数需为 3～30')
        if not np.isfinite(self.square_mm) or self.square_mm <= 0:
            raise ValueError('方格边长必须大于零')
        if self.response not in ('unknown', 'linear', 'srgb'):
            raise ValueError('未知亮度响应模式')
        if self.input_geometry not in ('distorted', 'corrected'):
            raise ValueError('未知输入几何模式')
        if any(not np.isfinite(v) or v <= 0 for v in (self.rms_limit_px, self.p95_limit_px)):
            raise ValueError('误差阈值必须为正数')


def detect_board(image, pattern):
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    # Bound costly search resolution. Full-resolution refinement follows;
    # geometry and SFR always use the original input, never this search image.
    scale = min(1., 1000/max(image.shape[:2]))
    small = cv2.resize(gray, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA) if scale < 1 else gray
    found, corners = cv2.findChessboardCornersSB(small, pattern, cv2.CALIB_CB_NORMALIZE_IMAGE)
    if not found:
        return gray, None
    corners = ((corners + .5)/scale - .5).astype(np.float32)
    spacing = np.median(np.linalg.norm(np.diff(corners.reshape(pattern[1], pattern[0], 2), axis=1), axis=2))
    radius = max(2, min(8, int(spacing*.12)))
    cv2.cornerSubPix(gray, corners, (radius, radius), (-1, -1),
                     (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_MAX_ITER, 30, .001))
    return gray, corners


def reference_image(image, options):
    calibration = options.calibration
    if options.software_correct:
        if calibration is None:
            raise ValueError('软件去畸变需要先导入标定参数')
        if options.input_geometry != 'distorted':
            raise ValueError('已矫正输入不能再次执行软件去畸变')
        if image.shape[1::-1] != calibration.size:
            raise ValueError(f'图像尺寸 {image.shape[1]}×{image.shape[0]} 与标定 {calibration.size} 不符，未自动缩放参数')
        image = cv2.undistort(image, calibration.matrix, calibration.distortion, None, calibration.matrix)
    return image


def evaluate_board(image, gray, corners, options, metadata=None):
    started = time.monotonic()
    metrics = geometry_metrics(gray, corners, options.pattern)
    sfr = board_sfr(gray, corners, options.pattern, options.response)
    calibration = options.calibration
    notes = []
    reprojection = None
    if calibration:
        if calibration.size != image.shape[1::-1]:
            notes.append('标定尺寸与图像不符，未计算重投影误差')
        else:
            cols, rows = options.pattern
            obj = np.zeros((rows*cols, 3), np.float64)
            obj[:, :2] = np.mgrid[0:cols, 0:rows].T.reshape(-1, 2)*options.square_mm
            distortion = np.zeros(5) if options.software_correct or options.input_geometry == 'corrected' else calibration.distortion
            ok, rotation, translation = cv2.solvePnP(obj, corners, calibration.matrix, distortion)
            if ok:
                projected, _ = cv2.projectPoints(obj, rotation, translation, calibration.matrix, distortion)
                distances = np.linalg.norm(projected.reshape(-1, 2)-corners.reshape(-1, 2), axis=1)
                reprojection = dict(rms_px=float(np.sqrt(np.mean(distances**2))),
                                    max_px=float(distances.max()), fitted_to_same_corners=True)
    else:
        notes.append('未导入内参，重投影误差不可用；直线度和相对 SFR 仍可测量')
    if options.response == 'unknown':
        notes.append('相机亮度响应未知，SFR 为当前编码亮度下的相对测量')
    if not sfr['valid_edges']:
        reasons = list(dict.fromkeys(e.get('reason', '') for e in sfr['edges']))
        notes.append('SFR 不可用：' + '；'.join(reasons[:3]))
    metadata = metadata or {}
    if metadata.get('encoding') == 'jpeg' or metadata.get('requested_format') == 'MJPG':
        notes.append('输入经过 JPEG 压缩，压缩伪影会影响直线度和 SFR；对比时保持采集设置一致')
    if metadata.get('source') == 'capture':
        mask = metadata.get('fpga_applied_mask')
        if mask is None:
            notes.append('未获取新鲜 FPGA 状态，当前功能开关与输入几何需人工核对')
        else:
            notes.append(f'分析前查询 FPGA 已应用掩码 0x{mask:02X}；串口状态与视频未逐帧同步')
            if metadata.get('fpga_pending'):
                notes.append('FPGA 尚有待应用请求，请等待生效后重新测量')
            if mask & 6:
                notes.append('姿态矫正或自适应 Gamma 已启用，建议关闭并固定曝光后测量几何和相对清晰度')
            if options.input_geometry == 'corrected' and not mask & 1:
                notes.append('所选输入为已矫正，但 FPGA 去畸变开关关闭；请核对输入几何设置')
    notes.extend(['结果只覆盖检测到的棋盘格区域，不能据此判断整幅边缘无断裂或拉伸',
                  '重投影为同一组角点拟合后的残差，不是独立标定精度认证',
                  '单路评估不计算 FPGA / 原图 MTF 保持率，也不验证 FPGA 内部参数身份'])
    edge = metrics['edge_straightness']
    enough = bool(edge and metrics['edge_sample_valid_ratio'] >= .8)
    within = bool(enough and edge['rms_px'] <= options.rms_limit_px and edge['p95_px'] <= options.p95_limit_px)
    report = dict(schema_version=1, measured_at=datetime.now().astimezone().isoformat(timespec='seconds'),
                  image_size=list(image.shape[1::-1]), pattern_inner_corners=list(options.pattern),
                  square_mm=options.square_mm, calibration=calibration.metadata() if calibration else None,
                  software_corrected=options.software_correct, input_geometry=options.input_geometry,
                  geometry=metrics, sfr=sfr, reprojection=reprojection,
                  thresholds=dict(edge_rms_px=options.rms_limit_px, edge_p95_px=options.p95_limit_px),
                  straightness_verdict='within_limits' if within else ('exceeds_limits' if enough else 'insufficient_samples'),
                  overall_verdict='not_assessed', notes=notes, input=metadata,
                  calculation_ms=(time.monotonic()-started)*1000)
    return report


def overlay(image, corners, pattern, report=None):
    annotated = image.copy()
    if corners is not None:
        cv2.drawChessboardCorners(annotated, pattern, corners, True)
    if report:
        for edge in report['sfr']['edges']:
            x0, y0, x1, y1 = edge['roi']
            cv2.rectangle(annotated, (x0, y0), (x1, y1), (90, 230, 70) if edge['valid'] else (40, 160, 240), 1)
    scale = min(1., 1000/image.shape[1])
    if scale < 1:
        annotated = cv2.resize(annotated, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    return annotated


def demo_board(pattern=(9, 6), size=(1280, 900)):
    """Moderate-contrast rotated chart for UI demonstrations and smoke tests."""
    cols, rows = pattern
    cell = min(80, (size[0]-240)//(cols+1), (size[1]-240)//(rows+1))
    chart = np.full((size[1], size[0]), 230, np.uint8)
    left, top = (size[0]-(cols+1)*cell)//2, (size[1]-(rows+1)*cell)//2
    for r in range(rows+1):
        for c in range(cols+1):
            chart[top+r*cell:top+(r+1)*cell, left+c*cell:left+(c+1)*cell] = 35 if (r+c)%2 == 0 else 220
    matrix = cv2.getRotationMatrix2D((size[0]/2, size[1]/2), 5., 1.)
    chart = cv2.warpAffine(chart, matrix, size, flags=cv2.INTER_LINEAR, borderValue=230)
    chart = cv2.GaussianBlur(chart, (5, 5), .8)
    return cv2.cvtColor(chart, cv2.COLOR_GRAY2BGR)
