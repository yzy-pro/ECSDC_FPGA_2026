"""Offscreen interaction tests for the complete Qt application."""
import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
from pathlib import Path
import json
import tempfile
import time
import unittest
from unittest.mock import patch
import cv2
import numpy as np
from PySide6.QtWidgets import QApplication, QDockWidget
from PySide6.QtTest import QTest
from fpga_host.config import Settings
from fpga_host.ui.main_window import MainWindow
from fpga_host.ui.settings_dialog import SettingsDialog, device_value
from fpga_host.devices.video import decode_frame


def wait_for(predicate, timeout=3):
    end = time.monotonic()+timeout
    while time.monotonic() < end:
        QApplication.processEvents()
        if predicate():
            return True
        QTest.qWait(15)
    return False


class UiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cv2.setNumThreads(2)
        cls.app = QApplication.instance() or QApplication([])
        cls.app.setQuitOnLastWindowClosed(False)

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.window = MainWindow(Settings(), Path(self.folder.name)/'config.json', demo=True)
        self.window.show()
        self.assertTrue(wait_for(lambda: self.window.rig is not None and self.window.raw_view.image is not None))

    def tearDown(self):
        self.window.close()
        self.assertTrue(wait_for(lambda: not self.window.running and not self.window.stopping))
        self.window.deleteLater()
        self.app.processEvents()
        self.folder.cleanup()

    def test_demo_controls_delay_pose_and_gamma(self):
        w = self.window
        self.assertTrue(wait_for(lambda: w.apply_button.isEnabled()))
        self.assertIsNotNone(w.robot_view.model)
        self.assertTrue(w.zero_button.isEnabled())
        w.feature_checks[2].setChecked(False)
        w.apply_button.click()
        self.assertTrue(wait_for(lambda: w.rig.snapshot()['status'].applied_mask == 3))
        self.assertTrue(wait_for(lambda: w.rig.snapshot()['gamma'].gamma_enabled == 0))
        w.delay_spin.setValue(500)
        self.assertEqual(w.delay_slider.value(), 500)
        self.assertEqual(w.settings.delay_ms, 500)
        def delayed_by_time():
            # A 500 ms delay is time-based, regardless of actual render FPS.
            target = w.rig.history.at(time.monotonic()-.45)
            return target is not None and w.raw_view.sequence is not None and w.raw_view.sequence <= target.sequence
        self.assertTrue(wait_for(delayed_by_time))
        self.assertIn('Roll', w.pose_values.text())
        self.assertIsNotNone(w.gamma_plot.stats)
        w.zero_button.click()
        self.assertNotEqual(w.zero, (0., 0.))
        w.reset_zero()
        self.assertEqual(w.zero, (0., 0.))

    def test_disconnect_clears_data_and_restart_is_available(self):
        w = self.window
        w.stop_button.click()
        self.assertTrue(wait_for(lambda: not w.stopping))
        self.assertIsNone(w.raw_view.image)
        self.assertIsNone(w.processed_view.image)
        self.assertIsNone(w.gamma_plot.stats)
        self.assertFalse(w.apply_button.isEnabled())
        self.assertFalse(w.zero_button.isEnabled())
        self.assertTrue(w.connect_button.isEnabled())
        w.connect_button.click()
        self.assertTrue(wait_for(lambda: w.raw_view.image is not None))

    def test_settings_roundtrip_manual_device_paths(self):
        dialog = SettingsDialog(self.window.settings, self.app.screens(), self.window)
        dialog.camera.setEditText('/dev/video23')
        dialog.capture.setEditText('/dev/video27')
        dialog.fpga.setEditText('/dev/ttyUSB9')
        dialog.capture_format.setCurrentIndex(dialog.capture_format.findData('YUYV'))
        settings = dialog.settings()
        self.assertEqual(settings.camera, '/dev/video23')
        self.assertEqual(settings.capture, '/dev/video27')
        self.assertEqual(settings.fpga_port, '/dev/ttyUSB9')
        self.assertEqual(settings.capture_fourcc, 'YUYV')
        dialog.deleteLater()

    def test_main_images_and_nonmodal_tool_windows(self):
        w = self.window
        self.assertEqual(w.findChildren(QDockWidget), [])
        self.assertGreater(w.raw_view.width()+w.processed_view.width(), w.width()*.85)
        self.assertGreater(w.raw_view.height(), w.live_page.height()*.8)
        for name, button in w.tool_buttons.items():
            tool = getattr(w.controls, name)
            self.assertFalse(tool.isVisible())
            button.click()
            self.assertTrue(tool.isVisible())
            self.assertFalse(tool.isModal())
            tool.close()
            self.assertFalse(tool.isVisible())
        self.assertTrue(w.running)

    def test_page_switch_is_exclusive_and_demo_report_exports(self):
        w = self.window
        rig = w.rig
        w.tabs.setCurrentIndex(1)
        self.assertTrue(wait_for(lambda: not w.stopping))
        self.assertFalse(rig.thread.is_alive())
        self.assertFalse(w.running, 'switching pages must not auto-start')
        self.assertEqual(w.connect_button.text(), '开始评估')
        self.assertFalse(w.tool_buttons['pose'].isEnabled())
        w.connect_button.click()
        worker = w.evaluation_worker
        self.assertTrue(wait_for(lambda: w.evaluation_page.last_result is not None, 6))
        self.assertIsNone(w.rig)
        self.assertIsNone(w.camera_worker)
        self.assertIsNone(w.capture_worker)
        self.assertIsNone(w.imu_worker)
        page = w.evaluation_page
        self.assertFalse(page.source.isEnabled())
        self.assertTrue(page.export_button.isEnabled())
        report_path = Path(self.folder.name)/'report.json'
        page.save_report(report_path)
        report = json.loads(report_path.read_text())
        self.assertTrue(report['input']['demonstration'])
        self.assertGreater(report['sfr']['valid_edges'], 0)
        self.assertEqual(report['overall_verdict'], 'not_assessed')
        w.tabs.setCurrentIndex(0)
        self.assertTrue(wait_for(lambda: not w.stopping))
        self.assertFalse(worker.thread.is_alive())
        self.assertTrue(page.source.isEnabled())
        w.connect_button.click()
        self.assertTrue(wait_for(lambda: w.raw_view.image is not None))

    def test_static_input_missing_board_and_invalid_calibration_clear_results(self):
        from fpga_host.evaluation.analyzer import demo_board
        w = self.window
        w.tabs.setCurrentIndex(1)
        self.assertTrue(wait_for(lambda: not w.stopping))
        page = w.evaluation_page
        image_path = Path(self.folder.name)/'棋盘格.png'
        image_path.write_bytes(cv2.imencode('.png', demo_board())[1].tobytes())
        page.set_image_path(image_path)
        w.start()
        self.assertTrue(wait_for(lambda: page.last_result is not None, 6))
        self.assertFalse(page.last_result['input']['demonstration'])
        self.assertEqual(page.last_result['stability']['mode'], 'static_unverified')
        w.stop()
        self.assertTrue(wait_for(lambda: not w.stopping))
        calibration_path = Path(self.folder.name)/'calibration.json'
        calibration_path.write_text(json.dumps(dict(camera_matrix=[[800, 0, 640], [0, 800, 450], [0, 0, 1]],
            distortion_coefficients=[0, 0, 0, 0, 0], image_size=[1280, 900])))
        self.assertTrue(page.set_calibration(calibration_path))
        self.assertIsNotNone(page.calibration)
        self.assertFalse(page.set_calibration(Path(self.folder.name)/'missing.json'))
        self.assertIsNone(page.calibration)
        self.assertFalse(page.export_button.isEnabled())
        blank_path = Path(self.folder.name)/'blank.png'
        cv2.imwrite(str(blank_path), np.full((500, 700, 3), 120, np.uint8))
        page.set_image_path(blank_path)
        w.start()
        self.assertTrue(wait_for(lambda: '未检测到' in page.state.text(), 6))
        self.assertIsNone(page.last_result)
        self.assertEqual(page.table.rowCount(), 0)
        self.assertFalse(page.export_button.isEnabled())


class HardwareVideoUiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cv2.setNumThreads(2)
        cls.app = QApplication.instance() or QApplication([])
        cls.app.setQuitOnLastWindowClosed(False)

    def test_capture_evaluation_uses_original_packets_without_main_previews(self):
        from fpga_host.evaluation.analyzer import demo_board
        from fpga_host.devices.evaluation import EvaluationWorker
        packet = cv2.imencode('.jpg', demo_board())[1].tobytes()
        class Source:
            def __init__(self, *args):
                pass
            def read(self, stop):
                return None if stop.wait(1/60) else packet
            def close(self):
                pass
        def fast_evaluator(*args, **kwargs):
            return EvaluationWorker(*args, **kwargs, interval=.05)
        with tempfile.TemporaryDirectory() as folder, \
                patch('fpga_host.devices.video.FFmpegSource', Source), \
                patch('fpga_host.ui.main_window.EvaluationWorker', side_effect=fast_evaluator):
            w = MainWindow(Settings(camera='camera', capture='card', backend='ffmpeg'), Path(folder)/'config.json')
            workers = []
            try:
                w.show()
                w.tabs.setCurrentIndex(1)
                w.evaluation_page.source.setCurrentIndex(w.evaluation_page.source.findData('capture'))
                w.start()
                workers = w._workers()
                self.assertTrue(wait_for(lambda: w.evaluation_page.last_result is not None, 8))
                report = w.evaluation_page.last_result
                self.assertEqual(report['image_size'], [1280, 900])
                self.assertEqual(report['input']['encoding'], 'jpeg')
                self.assertEqual(report['stability']['mode'], 'three_distinct_frames')
                self.assertIsNone(w.imu_worker)
                self.assertIsNone(w.rig)
                self.assertIsNone(w.raw_view.image)
                self.assertIsNone(w.processed_view.image)
                for worker in (w.camera_worker, w.capture_worker):
                    self.assertFalse(worker.preview_enabled)
                    self.assertIsNone(worker.preview_snapshot()[0])
                    self.assertIsNone(worker.snapshot()[0], 'HDMI hidden avoids full decode')
            finally:
                w.close()
                self.assertTrue(wait_for(lambda: not w.stopping))
                for worker in workers:
                    self.assertFalse(worker.is_alive if hasattr(worker, 'is_alive') else worker.thread.is_alive())
                w.deleteLater()
                self.app.processEvents()

    def test_two_mjpeg_inputs_decode_off_gui_thread_and_update_live(self):
        from threading import current_thread, main_thread
        packet = cv2.imencode('.jpg', np.full((1080, 1920, 3), 90, np.uint8))[1].tobytes()
        class Source:
            def __init__(self, *args):
                pass
            def read(self, stop):
                return None if stop.wait(1/60) else packet
            def close(self):
                pass
        decoded_on = []
        def record_decode(frame, preview=False):
            decoded_on.append(current_thread())
            return decode_frame(frame, preview)
        with tempfile.TemporaryDirectory() as folder, \
                patch('fpga_host.devices.video.FFmpegSource', Source), \
                patch('fpga_host.devices.video.decode_frame', side_effect=record_decode):
            settings = Settings(camera='camera', capture='card', backend='ffmpeg',
                                delay_ms=200, model_path=str(Path(folder)/'missing.urdf'))
            w = MainWindow(settings, Path(folder)/'config.json')
            workers = []
            try:
                w.show()
                w.start()
                self.assertTrue(wait_for(lambda: w.raw_view.image is not None and
                                         w.processed_view.image is not None))
                self.assertTrue(decoded_on)
                self.assertTrue(all(thread is not main_thread() for thread in decoded_on))
                self.assertIsNone(w.camera_worker.snapshot()[0], 'hidden HDMI avoids full decode')
                first = w.raw_view.sequence
                self.assertTrue(wait_for(lambda: w.raw_view.sequence > first + 5))
                self.assertIn('预览', w.raw_info.text())
                w.delay_spin.setValue(0)
                self.assertEqual(w.camera_worker.preview_delay, 0)
                self.assertTrue(wait_for(lambda: (f := w.camera_worker.preview_snapshot()[0]) is not None
                                         and time.monotonic()-f.timestamp < .15))
                # Use an ordinary offscreen window to exercise demand switching;
                # screen geometry/physical HDMI mode selection is unchanged.
                w.output.show()
                self.assertTrue(wait_for(lambda: w.output.image is not None))
                self.assertEqual(w.output.image.width(), 1920)
                w.output.hide()
                self.assertTrue(wait_for(lambda: not w.camera_worker.full_resolution))
                workers = [w.camera_worker, w.capture_worker]
            finally:
                w.close()
                self.assertTrue(wait_for(lambda: not w.stopping))
                w.deleteLater()
                self.app.processEvents()
            self.assertTrue(all(not worker.is_alive for worker in workers))
