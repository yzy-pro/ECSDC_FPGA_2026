import unittest

from Debug.cp2102_rx import PAYLOAD_SIZE, extract_frame


def frame(payload: bytes) -> bytes:
    checksum = 0
    for value in payload:
        checksum ^= value
    return b"\xAA\x55" + payload + bytes((checksum, 0x0D))


class FrameParserTests(unittest.TestCase):
    def test_split_frame_and_noise(self):
        payload = bytes(range(PAYLOAD_SIZE))
        data = frame(payload)
        buffer = bytearray(b"noise\xAA")
        self.assertIsNone(extract_frame(buffer))
        buffer.extend(data[1:20])
        self.assertIsNone(extract_frame(buffer))
        buffer.extend(data[20:])
        self.assertEqual(extract_frame(buffer), payload)
        self.assertEqual(buffer, bytearray())

    def test_bad_checksum_and_tail_recover(self):
        payload = b"\xAA\x55" + bytes(range(PAYLOAD_SIZE - 2))
        bad_checksum = bytearray(frame(payload))
        bad_checksum[-2] ^= 1
        bad_tail = bytearray(frame(payload))
        bad_tail[-1] = 0
        buffer = bad_checksum + bad_tail + frame(payload)
        self.assertEqual(extract_frame(buffer), payload)


if __name__ == "__main__":
    unittest.main()
