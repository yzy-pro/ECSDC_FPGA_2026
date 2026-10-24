"""CLI entry point; run from source with python -m fpga_host."""
import argparse
from pathlib import Path
import sys


def main(argv=None):
    parser = argparse.ArgumentParser(description="ECSDC FPGA Qt 上位机")
    parser.add_argument("--demo", action="store_true", help="启动模拟视频、Gamma 和 IMU，无需硬件")
    parser.add_argument("--config", type=Path, help="指定 JSON 配置路径")
    parser.add_argument("--quit-after", type=float, help="自动退出秒数，用于演示与界面冒烟验证")
    args = parser.parse_args(argv)
    import cv2
    # Two video sources and separate decoders already run concurrently. Avoid
    # each small resize spawning a machine-wide OpenCV thread pool as well.
    cv2.setNumThreads(2)
    from PySide6.QtCore import QStandardPaths, QTimer
    from PySide6.QtWidgets import QApplication, QMessageBox
    from fpga_host.config import Settings
    from fpga_host.devices.discovery import video_devices
    from fpga_host.devices.serial_link import preferred_port
    from fpga_host.ui.main_window import MainWindow
    app = QApplication(sys.argv[:1])
    app.setApplicationName("ECSDC-FPGA-Host")
    app.setOrganizationName("ECSDC")
    config_path = args.config or Path(QStandardPaths.writableLocation(QStandardPaths.StandardLocation.AppConfigLocation)) / "settings.json"
    config_error = None
    try:
        settings = Settings.load(config_path)
    except (OSError, ValueError, TypeError) as exc:
        settings = Settings()
        config_error = str(exc)
    if not config_path.exists():
        try:
            settings.fpga_port = preferred_port(0x10c4, 0xea60)
            settings.imu_port = preferred_port(0x0483, 0x5740)
            for path, name, vid, pid in reversed(video_devices()):
                if (vid, pid) == (0x1bcf, 0x2cd1):
                    settings.camera = path
                elif (vid, pid) == (0x2b89, 0x5854):
                    settings.capture = path
        except OSError:
            pass
    window = MainWindow(settings, config_path, demo=args.demo)
    window.show()
    if config_error:
        window.log_message(f"配置无效，使用默认值：{config_error}")
    if args.quit_after is not None:
        QTimer.singleShot(max(0, round(args.quit_after*1000)), window.close)
    return app.exec()
