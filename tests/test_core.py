from dataclasses import dataclass
from pathlib import Path
import json
import tempfile
import unittest
import numpy as np
from fpga_host.core.buffering import FrameHistory, VideoFrame
from fpga_host.core.model import RobotModel, rotation
from fpga_host.config import Settings, DEFAULT_MODEL
from fpga_host.devices.displays import parse_xrandr


class CoreTests(unittest.TestCase):
    def test_delay_warmup_and_selection(self):
        history = FrameHistory(max_seconds=2, max_bytes=100)
        for n in range(4):
            history.append(VideoFrame(n*.1, n, np.zeros(10, dtype=np.uint8)))
        self.assertIsNone(history.at(-.1))
        self.assertEqual(history.at(.15).sequence, 1)
        self.assertEqual(history.at(.3).sequence, 2)  # .3 < 3*.1
        self.assertEqual(history.at(10).sequence, 3)

    def test_buffer_byte_limit_time_limit_and_clear(self):
        history = FrameHistory(max_seconds=.5, max_bytes=25)
        for n in range(20):
            history.append(VideoFrame(n*.1, n, np.zeros(10, dtype=np.uint8)))
            self.assertLessEqual(history.bytes_used, 25)
        self.assertIsNone(history.at(1.7))
        history.append(VideoFrame(3, 30, np.zeros(10, dtype=np.uint8)))
        self.assertIsNone(history.at(2.9))
        history.clear()
        self.assertEqual(history.bytes_used, 0)
        self.assertIsNone(history.at(10))

    def test_settings_atomic_round_trip(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'nested/settings.json'
            settings = Settings(fpga_port='COM5', delay_ms=333, yaw_sign=-1)
            settings.save(path)
            self.assertEqual(Settings.load(path), settings)
            self.assertFalse(path.with_suffix('.tmp').exists())

    def test_settings_schema_rejects_invalid_values(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'settings.json'
            for data in ([], {'version': 2}, {'version': 1, 'settings': {'delay_ms': -1}},
                    {'version': 1, 'settings': {'delay_ms': '100'}},
                    {'version': 1, 'settings': {'yaw_sign': 0}}):
                path.write_text(json.dumps(data))
                with self.assertRaises(ValueError):
                    Settings.load(path)

    def test_actual_urdf_meshes_and_motion(self):
        model = RobotModel(DEFAULT_MODEL)
        self.assertEqual({m.link for m in model.meshes}, {'ladar_link','yaw_link','pitch_link','camera_link'})
        initial = model.transforms({})
        moved = model.transforms({'yaw_joint': .3, 'pitch_joint': -.2})
        np.testing.assert_allclose(initial['ladar_link'], moved['ladar_link'])
        self.assertFalse(np.allclose(initial['camera_link'], moved['camera_link']))
        meshes = list(model.geometry({'yaw_joint': .3, 'pitch_joint': -.2}))
        self.assertEqual(len(meshes), 4)
        for vertices, color in meshes:
            self.assertTrue(np.isfinite(vertices).all())
            self.assertLessEqual(len(vertices), 1200)

    def test_urdf_origin_axis_composition(self):
        model = RobotModel(DEFAULT_MODEL)
        joint = next(j for j in model.joints if j.name == 'yaw_joint')
        moved = model.transforms({'yaw_joint': .5})['yaw_link']
        np.testing.assert_allclose(moved, joint.transform @ rotation([0, 0, -1], .5))

    def test_xrandr_physical_mode_with_scaled_desktop(self):
        text = """HDMI-1 connected 3840x2160+0+0 (normal left inverted right x axis y axis)
   1920x1080     60.00*+  59.94
   1280x720      60.00
DP-1 disconnected (normal left inverted right x axis y axis)
eDP-1 connected primary 1920x1080+0+0
   1920x1080     59.94*+
"""
        self.assertEqual(parse_xrandr(text), {'HDMI-1': (1920, 1080, 60.0), 'eDP-1': (1920, 1080, 59.94)})
