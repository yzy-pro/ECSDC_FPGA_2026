"""Independent identity/black-scene budgets plus agreement with the older model."""
import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from audit_pose_throughput import geometry, add_budget, compute_budget
from audit_rotation_tiles import audit


class ThroughputBudgetTest(unittest.TestCase):
    # Binary-exact intrinsics make the identity mapping exactly pixel aligned.
    CALIBRATION = {
        'image_size_hw': [32, 64],
        'intrinsic_matrix_matlab': [[32, 0, 0], [0, 32, 0], [33, 17, 1]],
        'radial_distortion': [0, 0], 'tangential_distortion': [0, 0],
    }

    def test_identity_and_shared_tile_halo(self):
        small, big = geometry(self.CALIBRATION, (0, 0), [16, 32])
        self.assertEqual(small['valid_pixels'], 63*31)
        self.assertEqual(small['black_pixels'], 64+32-1)
        # Four horizontal source ranges: 2+2+2+1 beats; vertical halo: 17+16 rows.
        self.assertEqual(small['source_read_beats_per_frame'], 7*33)
        self.assertEqual(small['source_read_bursts_per_frame'], 4*33)
        # Two larger source ranges need 3+2 beats and each covers all 32 rows.
        self.assertEqual(big['source_read_beats_per_frame'], 5*32)
        self.assertEqual(big['max_source_tile_bytes'], 3*32*32)

    def test_black_source_does_not_remove_output_traffic(self):
        case = geometry(self.CALIBRATION, (180, 0), [32])[0]
        self.assertEqual(case['valid_pixels'], 0)
        self.assertEqual(case['behind_camera_pixels'], 64*32)
        add_budget(case, 64, 32, 10, 20, 30, [8], 100_000_000, 134)
        transfers = case['transfers']
        self.assertEqual(transfers['source_tile_read']['MB_per_second'], 0)
        self.assertEqual(transfers['capture_write']['MB_per_second'], 4096*10/1e6)
        self.assertEqual(transfers['corrected_frame_write']['MB_per_second'], 4096*20/1e6)
        self.assertEqual(transfers['display_read']['MB_per_second'], 4096*30/1e6)
        self.assertEqual(case['aggregate_MB_per_second'], 4096*60/1e6)
        # capture/display each 32 bursts; rendered tile rows use 64 bursts.
        expected_cycles = 128*60+8*(32*10+64*20+32*30)
        self.assertEqual(case['serialized_ddr_sensitivity'][0]['cycles_per_second'], expected_cycles)

    def test_1080p60_compute_threshold(self):
        budgets = compute_budget(1920, 1080, 60)
        self.assertEqual(budgets[0]['utilization_at_render_fps'], 1.24416)
        self.assertEqual(budgets[2]['utilization_at_render_fps'], 0.62208)
        self.assertTrue(math.isclose(budgets[4]['utilization_at_render_fps'], 124416000/148500000))
        for first, second in zip(budgets[::2], budgets[1::2]):
            self.assertEqual(second['required_cycles_per_frame'], 2*first['required_cycles_per_frame'])

    def test_merged_bounds_match_original_pixel_reference(self):
        calibration = dict(self.CALIBRATION, radial_distortion=[0.0099, -0.0434])
        for pose in ((0, 0), (15, -10), (-30, 20), (90, 90)):
            for case in geometry(calibration, pose, [16, 32]):
                old = audit(calibration, 0, case['tile_size'], 60, 60, 12, pose)
                for field in ('valid_pixels', 'source_read_beats_per_frame',
                              'source_read_bursts_per_frame', 'max_source_tile_bytes',
                              'output_write_bursts_per_frame'):
                    self.assertEqual(case[field], old[field], (pose, field))


if __name__ == '__main__':
    unittest.main()
