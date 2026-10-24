"""JPEG framing and real threaded video tests without camera hardware."""
from threading import Event
import shutil
import time
import unittest
from unittest.mock import patch
import cv2
import numpy as np
from fpga_host.core.buffering import FrameHistory, VideoFrame
from fpga_host.core.jpeg import JpegStreamParser, jpeg_size
from fpga_host.devices.video import VideoWorker, decode_frame
from fpga_host.devices.video_sources import ffmpeg_command, FFmpegSource


def wait_for(predicate, timeout=3):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(.005)
    return False


def jpeg(image, progressive=False):
    ok, encoded = cv2.imencode('.jpg', image, [cv2.IMWRITE_JPEG_PROGRESSIVE, int(progressive)])
    assert ok
    return encoded.tobytes()


class JpegTests(unittest.TestCase):
    def test_all_split_positions_with_embedded_thumbnail_markers(self):
        packet = jpeg(np.zeros((32, 48, 3), np.uint8))
        payload = b'thumbnail\xff\xd8\xff\xd9tail'
        packet = packet[:2] + b'\xff\xe1' + (len(payload)+2).to_bytes(2, 'big') + payload + packet[2:]
        for split in range(len(packet)+1):
            parser = JpegStreamParser()
            frames = parser.feed(b'noise' + packet[:split]) + parser.feed(packet[split:] + packet)
            self.assertEqual(frames, [packet, packet], split)
        self.assertEqual(jpeg_size(packet), (48, 32))

    def test_progressive_byte_chunks_stuffing_and_restart_markers(self):
        image = np.random.default_rng(42).integers(0, 256, (72, 128, 3), dtype=np.uint8)
        packet = jpeg(image, progressive=True)
        parser = JpegStreamParser()
        frames = []
        for byte in packet:
            frames.extend(parser.feed(bytes([byte])))
        self.assertEqual(frames, [packet])
        np.testing.assert_array_equal(cv2.imdecode(np.frombuffer(frames[0], np.uint8), 1),
                                      cv2.imdecode(np.frombuffer(packet, np.uint8), 1))
        # Minimal structural stream: stuffed FF, RST, fill FF and multiple scans.
        packet = b'\xff\xd8\xff\xda\x00\x02abc\xff\x00\xd9\xff\xd0def\xff\xc4\x00\x02\xff\xda\x00\x02ghi\xff\xff\xd9'
        self.assertEqual(JpegStreamParser().feed(packet), [packet])

    def test_corruption_resync_and_bounded_memory(self):
        packet = jpeg(np.zeros((16, 16, 3), np.uint8))
        parser = JpegStreamParser(max_frame_bytes=2048)
        self.assertEqual(parser.feed(b'noise\xff\xd8\xff\xe0\x00\x01bad' + packet), [packet])
        parser.feed(b'\xff\xd8\xff\xda\x00\x02' + b'x'*10000)
        self.assertLessEqual(len(parser.buffer), 2048)
        self.assertEqual(parser.feed(packet), [packet])
        # The limit applies to each frame, not an aggregate pipe read.
        self.assertEqual(parser.feed(packet*10), [packet]*10)
        with self.assertRaises(ValueError):
            jpeg_size(b'not jpeg')

    def test_compressed_history_accounts_for_byte_and_time_limits(self):
        history = FrameHistory(max_seconds=.5, max_bytes=25)
        for n in range(10):
            history.append(VideoFrame(n*.1, n, b'x'*10, 'jpeg'))
        self.assertEqual(history.bytes_used, 20)
        self.assertIsNone(history.at(.7))
        self.assertEqual(history.at(.85).sequence, 8)
        history.clear()
        self.assertEqual(history.bytes_used, 0)

    def test_reduced_preview_and_full_resolution(self):
        packet = jpeg(np.full((1080, 1920, 3), (20, 70, 130), np.uint8))
        frame = VideoFrame(123., 42, packet, 'jpeg')
        small = decode_frame(frame, preview=True)
        full = decode_frame(frame)
        self.assertEqual(small.image.shape, (360, 640, 3))
        self.assertEqual(full.image.shape, (1080, 1920, 3))
        self.assertEqual((small.timestamp, small.sequence), (123., 42))
        np.testing.assert_allclose(small.image[0, 0], (20, 70, 130), atol=3)

    @unittest.skipUnless(shutil.which('ffmpeg'), 'requires system ffmpeg')
    def test_ffmpeg_stream_copy_pipe_read_and_cleanup(self):
        command = ffmpeg_command('/dev/not-used', 'MJPG')
        self.assertEqual(command[command.index('-c:v')+1], 'copy')
        self.assertNotIn('rawvideo', command)
        raw = ffmpeg_command('/dev/not-used', 'YUYV')
        self.assertIn('rawvideo', raw)
        # Real child process, selectors, chunked reads and JPEG framing. Replace
        # only the unavailable V4L2 device input with a finite generated stream.
        test_command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
            '-i', 'color=c=blue:s=1920x1080:r=60', '-frames:v', '4', '-threads', '1',
            '-c:v', 'mjpeg', '-f', 'image2pipe', '-flush_packets', '1', 'pipe:1']
        with patch('fpga_host.devices.video_sources.ffmpeg_command', return_value=test_command):
            source = FFmpegSource('synthetic', 'MJPG', None)
        try:
            frames = [source.read(Event()) for _ in range(4)]
            self.assertTrue(all(jpeg_size(frame) == (1920, 1080) for frame in frames))
            with self.assertRaises(RuntimeError):
                source.read(Event())
        finally:
            source.close()
        self.assertIsNotNone(source.process.poll())


class SyntheticSource:
    image = b''
    rate = 120

    def __init__(self, *args):
        self.next = time.monotonic()
        self.closed = False

    def read(self, stop):
        self.next += 1/self.rate
        if stop.wait(max(0, self.next-time.monotonic())):
            return None
        return self.image

    def close(self):
        self.closed = True


class VideoWorkerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image = np.full((1080, 1920, 3), 80, dtype=np.uint8)
        cls.packet = jpeg(cls.image)

    def start_worker(self, image, delay=0):
        class Source(SyntheticSource):
            pass
        Source.image = image
        worker = VideoWorker('synthetic', backend='ffmpeg')
        worker.set_preview_delay(delay)
        patcher = patch('fpga_host.devices.video.FFmpegSource', Source)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(worker.stop)
        worker.start()
        return worker

    def test_slow_decoder_skips_old_frames_without_slowing_input(self):
        seen = []
        full_calls = []
        def slow(frame, preview=False):
            if preview:
                time.sleep(.06)  # ~16 fps decoder, 120 fps camera
                seen.append((frame.sequence, time.monotonic()-frame.timestamp))
            else:
                full_calls.append(frame.sequence)
            return decode_frame(frame, preview)
        with patch('fpga_host.devices.video.decode_frame', side_effect=slow):
            worker = self.start_worker(self.packet)
            self.assertTrue(wait_for(lambda: len(seen) >= 18))
            frame, preview_fps = worker.preview_snapshot()
            _, online, fps = worker.snapshot()
            self.assertTrue(online)
            self.assertGreater(fps, 70)
            self.assertLess(preview_fps, 25)
            self.assertIsNotNone(frame)
            self.assertTrue(any(b[0]-a[0] >= 4 for a, b in zip(seen, seen[1:])))
            self.assertLess(max(age for _, age in seen), .3)
            self.assertFalse(full_calls, 'hidden HDMI must not decode full-size JPEG')
            self.assertLess(worker.history.bytes_used, worker.history.max_bytes)
            worker.stop()
            self.assertFalse(worker.is_alive)
            self.assertEqual(worker.history.bytes_used, 0)
            self.assertIsNone(worker.preview_snapshot()[0])

    def test_live_delay_changes_and_hdmi_independence(self):
        worker = self.start_worker(self.packet, delay=.2)
        self.assertTrue(wait_for(lambda: worker.preview_snapshot()[0] is not None))
        frame, _ = worker.preview_snapshot()
        self.assertGreaterEqual(time.monotonic()-frame.timestamp, .2)
        worker.set_full_resolution(True)
        self.assertTrue(wait_for(lambda: worker.snapshot()[0] is not None))
        full = worker.snapshot()[0]
        self.assertEqual(full.image.shape, (1080, 1920, 3))
        self.assertLess(time.monotonic()-full.timestamp, .2)
        worker.set_full_resolution(False)
        self.assertIsNone(worker.snapshot()[0])
        worker.set_preview_delay(0)
        self.assertTrue(wait_for(lambda: (f := worker.preview_snapshot()[0]) is not None
                                and time.monotonic()-f.timestamp < .15))

    def test_raw_fallback_retains_delayed_small_history(self):
        worker = self.start_worker(self.image, delay=.25)
        self.assertTrue(wait_for(lambda: worker.preview_snapshot()[0] is not None))
        frame = worker.preview_snapshot()[0]
        self.assertEqual(frame.image.shape, (360, 640, 3))
        self.assertGreaterEqual(time.monotonic()-frame.timestamp, .25)
        self.assertLess(worker.history.bytes_used, 20*640*360*3)
        worker.set_full_resolution(True)
        self.assertIs(worker.snapshot()[0].image, self.image)

    def test_disconnect_invalidates_inflight_decode(self):
        entered, finish = Event(), Event()
        def blocked(frame, preview=False):
            entered.set()
            finish.wait(2)
            return decode_frame(frame, preview)
        worker = VideoWorker('synthetic')
        worker.latest_input = VideoFrame(time.monotonic(), 1, self.packet, 'jpeg')
        worker.connected = True
        worker.history.append(worker.latest_input)
        with patch('fpga_host.devices.video.decode_frame', side_effect=blocked):
            worker.preview_thread.start()
            self.assertTrue(entered.wait(1))
            worker._reset()
            finish.set()
            time.sleep(.08)  # Allow the old decode to complete while still running.
            self.assertIsNone(worker.preview_snapshot()[0])
            self.assertIsNone(worker.preview)
            worker.stop_event.set()
            worker.preview_thread.join(2)
        self.assertIsNone(worker.preview_snapshot()[0])
        self.assertFalse(worker.connected)
        self.assertEqual(worker.history.bytes_used, 0)
