"""Versioned JSON settings. Paths are explicit and models stay outside code."""
from dataclasses import asdict, dataclass, fields
from pathlib import Path
import json
import os

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MODEL = ROOT / "Device/imu_usbdcdc/ladar_urdf/urdf/ladar_urdf.urdf"


@dataclass
class Settings:
    camera: str = "/dev/video0" if os.name != "nt" else "0"
    capture: str = "/dev/video2" if os.name != "nt" else "1"
    fpga_port: str = ""
    imu_port: str = ""
    backend: str = "auto"
    fourcc: str = "MJPG"
    capture_fourcc: str = "MJPG"
    exposure: int = 156
    manual_exposure: bool = True
    delay_ms: int = 150
    screen_name: str = ""
    model_path: str = str(DEFAULT_MODEL)
    yaw_sign: int = 1
    pitch_sign: int = 1
    calibration_path: str = ""
    eval_cols: int = 9
    eval_rows: int = 6
    eval_square_mm: float = 25.0

    @classmethod
    def load(cls, path: Path):
        if not path.exists():
            return cls()
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or data.get("version") != 1:
            raise ValueError("不支持的配置版本")
        values = data.get("settings", {})
        if not isinstance(values, dict):
            raise ValueError("settings 必须是对象")
        defaults = cls()
        known = {f.name for f in fields(cls)}
        for name, value in values.items():
            if name in known and type(value) is not type(getattr(defaults, name)):
                raise ValueError(f"配置字段 {name} 类型错误")
        result = cls(**{k: v for k, v in values.items() if k in known})
        if not 0 <= result.delay_ms <= 2000 or result.backend not in ("auto", "ffmpeg", "opencv"):
            raise ValueError("配置中的延时或采集后端无效")
        if result.fourcc not in ("MJPG", "YUYV", "NV12") or result.capture_fourcc not in ("MJPG", "YUYV", "NV12") or result.yaw_sign not in (-1, 1) or result.pitch_sign not in (-1, 1):
            raise ValueError("配置中的格式或轴方向无效")
        if not (3 <= result.eval_cols <= 30 and 3 <= result.eval_rows <= 30 and .1 <= result.eval_square_mm <= 1000):
            raise ValueError("配置中的棋盘格尺寸无效")
        return result

    def save(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps({"version": 1, "settings": asdict(self)}, ensure_ascii=False, indent=2), encoding="utf-8")
        temporary.replace(path)
