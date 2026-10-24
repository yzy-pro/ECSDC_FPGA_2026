"""Explicit MATLAB/OpenCV calibration conversion to zero-origin Brown model."""
from dataclasses import dataclass
from pathlib import Path
import hashlib
import json
import cv2
import numpy as np


def array(value):
    if isinstance(value, dict):
        return np.asarray(value['data'], dtype=float).reshape(value['rows'], value['cols'])
    return np.asarray(value, dtype=float)


@dataclass(frozen=True)
class Calibration:
    matrix: np.ndarray
    distortion: np.ndarray
    size: tuple
    path: str
    sha256: str
    convention: str

    def metadata(self):
        return dict(path=self.path, sha256=self.sha256, convention=self.convention,
                    camera_matrix=self.matrix.tolist(), distortion_coefficients=self.distortion.tolist(),
                    image_size=list(self.size), pixel_coordinate_origin=0,
                    model='opencv_brown', applied_to_fpga=False)


def load_calibration(path):
    path = Path(path)
    content = path.read_bytes()
    if len(content) > 1024 * 1024:
        raise ValueError('标定文件超过 1 MiB')
    if path.suffix.lower() == '.json':
        data = json.loads(content)
    else:
        try:
            fs = cv2.FileStorage(str(path), cv2.FILE_STORAGE_READ)
        except (cv2.error, SystemError) as exc:
            # Some OpenCV builds wrap a malformed YAML parser error in
            # SystemError instead of cv2.error.
            raise ValueError('无法解析 OpenCV YAML 标定文件') from exc
        try:
            if not fs.isOpened():
                raise ValueError('无法读取 OpenCV YAML 标定文件')
            def node_matrix(name):
                node = fs.getNode(name)
                if node.empty():
                    raise ValueError(f'缺少 {name}')
                return node.mat()
            data = dict(camera_matrix=node_matrix('camera_matrix'),
                        distortion_coefficients=node_matrix('distortion_coefficients'),
                        image_size=[fs.getNode('image_width').real(), fs.getNode('image_height').real()],
                        pixel_coordinate_origin=0,
                        model=fs.getNode('model').string() or 'opencv_brown')
        finally:
            fs.release()
    if not isinstance(data, dict):
        raise ValueError('标定参数必须是对象')
    if data.get('model', 'opencv_brown') not in ('opencv_brown', 'brown', 'plumb_bob'):
        raise ValueError('目前仅支持 Brown 径向/切向模型，不支持鱼眼模型')
    origin = data.get('pixel_coordinate_origin', 0)
    if type(origin) is not int or origin not in (0, 1):
        raise ValueError('pixel_coordinate_origin 只能为 0 或 1')
    if 'intrinsic_matrix_matlab' in data:
        if 'pixel_coordinate_origin' not in data:
            raise ValueError('MATLAB 文件需要明确 pixel_coordinate_origin')
        matrix = array(data['intrinsic_matrix_matlab']).T.copy()
        radial = array(data['radial_distortion']).reshape(-1)
        tangential = array(data['tangential_distortion']).reshape(-1)
        if len(radial) not in (2, 3) or len(tangential) != 2:
            raise ValueError('MATLAB 径向系数需 2/3 项，切向系数需 2 项')
        distortion = np.array([*radial[:2], *tangential, radial[2] if len(radial) == 3 else 0])
        size = list(reversed(data['image_size_hw']))
        convention = f'MATLAB 转置，主点减 {origin}'
    else:
        matrix = array(data['camera_matrix']).copy()
        distortion = array(data['distortion_coefficients']).reshape(-1)
        size = data['image_size']
        convention = f'OpenCV，主点减 {origin}'
    if matrix.shape != (3, 3) or not np.isfinite(matrix).all():
        raise ValueError('内参必须是有限数值的 3×3 矩阵')
    if not np.allclose(matrix[2], [0, 0, 1]) or not np.allclose([matrix[0, 1], matrix[1, 0]], 0):
        raise ValueError('内参末行必须为 [0,0,1]，目前不支持非零 skew')
    if matrix[0, 0] <= 0 or matrix[1, 1] <= 0:
        raise ValueError('焦距必须为正数')
    if len(distortion) not in (4, 5, 8) or not np.isfinite(distortion).all():
        raise ValueError('畸变系数需为 4/5/8 项有限数值，按 k1,k2,p1,p2,k3,k4,k5,k6 排列')
    if len(size) != 2 or any(not np.isfinite(v) or int(v) != v or not 16 <= v <= 20000 for v in size):
        raise ValueError('image_size 需要有效的 [宽,高] 整数尺寸')
    matrix[0, 2] -= origin
    matrix[1, 2] -= origin
    return Calibration(matrix, distortion, tuple(map(int, size)), str(path.resolve()),
                       hashlib.sha256(content).hexdigest(), convention)
