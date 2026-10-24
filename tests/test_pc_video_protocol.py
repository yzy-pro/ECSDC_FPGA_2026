"""Check PC-side framing against documented wire bytes and telemetry fields."""
import importlib.util
from pathlib import Path
import struct
import unittest

path = Path(__file__).resolve().parents[1] / 'tools/pc_video_control.py'
spec = importlib.util.spec_from_file_location('pc_video_control', path)
protocol = importlib.util.module_from_spec(spec)
spec.loader.exec_module(protocol)


class ProtocolTests(unittest.TestCase):
    def test_set_wire_example(self):
        self.assertEqual(protocol.encode_packet(0x10, 1, b'\x07').hex(' '),
                         'a5 5a 01 10 01 01 07 16')

    def test_stream_fragments_and_checksum_recovery(self):
        packet = protocol.encode_packet(0x80, 9, bytes((0, 7, 7, 0, 7, 1, 1, 0)))
        corrupted = packet[:-1] + bytes((packet[-1] ^ 1,))
        decoder = protocol.PacketDecoder()
        actual = []
        for value in b'noise\xa5' + corrupted + packet + packet:
            actual.extend(decoder.feed(bytes((value,))))
        self.assertEqual(len(actual), 2)
        self.assertEqual(protocol.decode_status(actual[0][2])['applied_mask'], 7)

    def test_statistics_and_disabled_gamma(self):
        payload = struct.pack('<6I4B', 42, 3200, 100, 100, 0, 9000, 0, 0, 1, 7)
        decoded = protocol.decode_gamma(payload)
        self.assertEqual(decoded['mean_before'], 32)
        self.assertEqual(decoded['mean_after'], 90)
        self.assertEqual(decoded['exponent'], 0.5)
        self.assertEqual(decoded['dark_ratio'], 1)
        disabled = struct.pack('<6I4B', 43, 3200, 100, 100, 0, 3200, 0, 0, 0, 3)
        self.assertEqual(protocol.decode_gamma(disabled)['mean_after'], 32)


if __name__ == '__main__':
    unittest.main()
