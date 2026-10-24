"""Numerical tests use analytic edges and known image warps, not UI values."""
from dataclasses import replace
from pathlib import Path
from threading import Event
import json
import math
import tempfile
import time
import unittest
from unittest.mock import patch
import cv2
import numpy as np
from fpga_host.core.buffering import VideoFrame
from fpga_host.evaluation.calibration import load_calibration, Calibration
from fpga_host.evaluation.sfr import slanted_edge_sfr
from fpga_host.evaluation.analyzer import (EvaluationOptions, demo_board, detect_board,
                                           evaluate_board, reference_image)
from fpga_host.devices.evaluation import EvaluationWorker


def wait_for(predicate, timeout=6):
    end = time.monotonic()+timeout
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(.01)
    return False


class CalibrationTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.path = Path(self.folder.name)/'calibration.json'
        self.data = dict(camera_matrix=[[800, 0, 640], [0, 801, 450], [0, 0, 1]],
                         distortion_coefficients=[.01, -.04, .001, -.002, .003],
                         image_size=[1280, 900], model='opencv_brown')

    def load(self, data):
        self.path.write_text(json.dumps(data))
        return load_calibration(self.path)

    def test_matlab_transpose_origin_and_distortion_order(self):
        c = self.load(dict(intrinsic_matrix_matlab=[[748.4469, 0, 0], [0, 748.0773, 0], [944.9033, 522.3963, 1]],
            image_size_hw=[1080, 1920], radial_distortion=[.0099, -.0434, .002],
            tangential_distortion=[.001, -.001], pixel_coordinate_origin=1))
        np.testing.assert_allclose(c.matrix, [[748.4469, 0, 943.9033], [0, 748.0773, 521.3963], [0, 0, 1]])
        np.testing.assert_allclose(c.distortion, [.0099, -.0434, .001, -.001, .002])
        self.assertEqual(c.size, (1920, 1080))
        self.assertEqual(len(c.sha256), 64)
        self.assertFalse(c.metadata()['applied_to_fpga'])

    def test_opencv_json_and_yaml_roundtrip(self):
        c = self.load(self.data)
        yml = Path(self.folder.name)/'calibration.yml'
        fs = cv2.FileStorage(str(yml), cv2.FILE_STORAGE_WRITE)
        fs.write('camera_matrix', c.matrix)
        fs.write('distortion_coefficients', c.distortion)
        fs.write('image_width', c.size[0])
        fs.write('image_height', c.size[1])
        fs.release()
        other = load_calibration(yml)
        np.testing.assert_array_equal(c.matrix, other.matrix)
        np.testing.assert_array_equal(c.distortion, other.distortion)
        self.assertEqual(c.size, other.size)

    def test_rejects_invalid_models_matrices_and_sizes(self):
        cases = [dict(model='fisheye'), dict(camera_matrix=[[1, 0], [0, 1]]),
                 dict(camera_matrix=[[-1, 0, 1], [0, 1, 1], [0, 0, 1]]),
                 dict(distortion_coefficients=[0, 0]), dict(distortion_coefficients=[float('nan')]*5),
                 dict(image_size=[1280, 900.5]), dict(pixel_coordinate_origin=True),
                 dict(camera_matrix=[[1, 1, 1], [0, 1, 1], [0, 0, 1]])]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(ValueError):
                self.load(dict(self.data, **case))

    def test_size_mismatch_never_silently_rescales_parameters(self):
        c = self.load(self.data)
        with self.assertRaises(ValueError):
            reference_image(np.zeros((1080, 1920, 3), np.uint8), EvaluationOptions(calibration=c, software_correct=True))
        with self.assertRaises(ValueError):
            reference_image(demo_board(), EvaluationOptions(calibration=c, software_correct=True, input_geometry='corrected'))

    def test_malformed_yaml_is_a_validation_error(self):
        path = Path(self.folder.name)/'broken.yml'
        path.write_text('just malformed yaml')
        with self.assertRaises(ValueError):
            load_calibration(path)


class AlgorithmTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cv2.setNumThreads(2)

    @staticmethod
    def gaussian_edge(sigma=1.5, angle=5., low=35, high=220):
        yy, xx = np.mgrid[:160, :48]
        slope = math.tan(math.radians(angle))
        distance = (xx-24-slope*(yy-80))/math.sqrt(1+slope*slope)
        erf = np.vectorize(math.erf)(distance/(math.sqrt(2)*sigma))
        return np.round(low+(high-low)*.5*(1+erf)).astype(np.uint8)

    def test_sfr_matches_analytic_gaussian_and_reports_blur(self):
        results = []
        for sigma in (.8, 1.5, 2.5):
            result = slanted_edge_sfr(self.gaussian_edge(sigma), 'linear')
            expected = math.sqrt(math.log(2))/(math.sqrt(2)*math.pi*sigma)
            self.assertAlmostEqual(result['mtf50_cy_px'], expected, delta=.018)
            results.append(result['mtf50_cy_px'])
            self.assertLess(result['frequency_cy_px'][-1], .501)
        self.assertGreater(results[0], results[1])
        self.assertGreater(results[1], results[2])

    def test_sfr_rejects_axis_aligned_clipped_and_low_contrast(self):
        for edge in (self.gaussian_edge(angle=0), self.gaussian_edge(low=0, high=255),
                     self.gaussian_edge(low=100, high=110)):
            with self.assertRaises(ValueError):
                slanted_edge_sfr(edge)

    def test_board_detection_geometry_and_blur_measurement(self):
        image = demo_board()
        gray, corners = detect_board(image, (9, 6))
        self.assertIsNotNone(corners)
        report = evaluate_board(image, gray, corners, EvaluationOptions())
        self.assertLess(report['geometry']['edge_straightness']['rms_px'], .3)
        self.assertGreater(report['sfr']['valid_edges'], 8)
        self.assertEqual(report['straightness_verdict'], 'within_limits')
        self.assertEqual(report['overall_verdict'], 'not_assessed')
        self.assertFalse(report['sfr']['certified_iso12233'])
        blurred = cv2.GaussianBlur(image, (13, 13), 2.)
        g2, c2 = detect_board(blurred, (9, 6))
        report2 = evaluate_board(blurred, g2, c2, EvaluationOptions())
        self.assertLess(report2['sfr']['mtf50_median_cy_px'], report['sfr']['mtf50_median_cy_px']*.7)
        json.dumps(report, allow_nan=False)

    def test_curved_grid_exceeds_threshold_and_blank_has_no_board(self):
        image = demo_board()
        yy, xx = np.mgrid[:image.shape[0], :image.shape[1]].astype(np.float32)
        warped = cv2.remap(image, xx+6*np.sin(yy/85), yy, cv2.INTER_LINEAR)
        gray, corners = detect_board(warped, (9, 6))
        self.assertIsNotNone(corners)
        report = evaluate_board(warped, gray, corners, EvaluationOptions())
        self.assertGreater(report['geometry']['edge_straightness']['rms_px'], .5)
        self.assertEqual(report['straightness_verdict'], 'exceeds_limits')
        self.assertIsNone(detect_board(np.full_like(image, 120), (9, 6))[1])

    def test_reprojection_of_known_pinhole_pose(self):
        image = demo_board()
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        matrix = np.array([[900., 0, 640], [0, 900, 450], [0, 0, 1]])
        calibration = Calibration(matrix, np.zeros(5), (1280, 900), 'synthetic', '', 'OpenCV')
        obj = np.zeros((54, 3))
        obj[:, :2] = np.mgrid[0:9, 0:6].T.reshape(-1, 2)*25
        corners, _ = cv2.projectPoints(obj, np.array([.1, -.1, .05]), np.array([-100., -60, 700]), matrix, np.zeros(5))
        report = evaluate_board(image, gray, corners.astype(np.float32), EvaluationOptions(calibration=calibration))
        self.assertLess(report['reprojection']['rms_px'], .001)


class EvaluationWorkerTests(unittest.TestCase):
    def test_stability_stale_input_and_no_old_report_after_loss(self):
        image = demo_board()
        sequence = [1]
        available = [True]
        def provider():
            return VideoFrame(time.monotonic(), sequence[0], image) if available[0] else None
        worker = EvaluationWorker(EvaluationOptions(), provider, interval=.05)
        self.addCleanup(worker.stop)
        worker.start()
        self.assertTrue(wait_for(lambda: worker.snapshot() is not None))
        self.assertIsNone(worker.snapshot()['report'])
        # Reusing one packet never qualifies as three stable captures.
        time.sleep(.2)
        self.assertIsNone(worker.snapshot()['report'])
        sequence[0] = 2
        self.assertTrue(wait_for(lambda: '2/3' in worker.snapshot()['state']))
        sequence[0] = 3
        self.assertTrue(wait_for(lambda: worker.snapshot()['report'] is not None))
        self.assertEqual(worker.snapshot()['report']['stability']['mode'], 'three_distinct_frames')
        available[0] = False
        self.assertTrue(wait_for(lambda: worker.snapshot()['report'] is None))
        worker.stop()
        self.assertFalse(worker.thread.is_alive())

    def test_stop_during_detection_never_publishes_old_result(self):
        entered, finish = Event(), Event()
        original = detect_board
        def blocked(*args):
            entered.set()
            finish.wait(2)
            return original(*args)
        worker = EvaluationWorker(EvaluationOptions(), demo=True)
        with patch('fpga_host.devices.evaluation.detect_board', side_effect=blocked):
            worker.start()
            self.assertTrue(entered.wait(2))
            worker.stop_event.set()
            finish.set()
            worker.stop()
        self.assertIsNone(worker.snapshot())
        self.assertFalse(worker.thread.is_alive())
