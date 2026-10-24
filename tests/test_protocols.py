import math
import random
import struct
import unittest
from fpga_host.core.protocols import (PacketDecoder, ImuDecoder, FpgaStatus, GammaStats,
    encode_packet, STATUS, GAMMA_STATS, GET_STATUS, SET_FEATURES, Packet)
from fpga_host.core.requests import RequestGate, Command


class ProtocolTests(unittest.TestCase):
    def test_documented_commands(self):
        self.assertEqual(encode_packet(SET_FEATURES, 1, b'\x07').hex(' '), 'a5 5a 01 10 01 01 07 16')
        self.assertEqual(encode_packet(GET_STATUS, 1).hex(' '), 'a5 5a 01 11 01 00 11')

    def test_every_split_and_embedded_sync(self):
        payload = bytes.fromhex('00 07 07 00 07 01 01 a5')
        frame = encode_packet(STATUS, 90, payload)
        for split in range(len(frame)+1):
            decoder = PacketDecoder()
            result = decoder.feed(b'noise\xa5')
            result += decoder.feed(frame[:split])
            result += decoder.feed(frame[split:])
            self.assertEqual(result, [Packet(STATUS, 90, payload)])
        frame = encode_packet(0x82, 2, b'\xa5\x5a\x01\x00')
        self.assertEqual(PacketDecoder().feed(frame)[0].payload, b'\xa5\x5a\x01\x00')

    def test_corrupt_frames_resynchronize(self):
        valid = encode_packet(STATUS, 5, bytes((0, 7, 3, 1, 7, 1, 1, 0)))
        bad = bytearray(valid)
        bad[-1] ^= 16
        bad_length = bytearray(valid)
        bad_length[5] = 255
        bad_version = bytearray(valid)
        bad_version[2] = 2
        decoder = PacketDecoder()
        result = decoder.feed(bytes(bad)+bytes(bad_length)+bytes(bad_version)+valid*2)
        self.assertEqual([p.sequence for p in result], [5, 5])
        self.assertGreaterEqual(decoder.errors, 3)

    def test_random_fragmentation(self):
        rng = random.Random(5)
        wire = b''.join(encode_packet(STATUS, i, bytes((0, 7, 7, 0, 7, 1, 1, i))) for i in range(100))
        decoder, decoded = PacketDecoder(), []
        while wire:
            size = rng.randrange(1, 31)
            decoded += decoder.feed(wire[:size])
            wire = wire[size:]
        self.assertEqual([p.sequence for p in decoded], list(range(100)))
        self.assertEqual(decoder.buffer, b'')

    def test_noise_memory_is_bounded(self):
        parser = PacketDecoder()
        parser.feed(b'\xff' * 100000 + b'\xa5')
        self.assertEqual(parser.buffer, b'\xa5')

    def test_status_and_invalid_flags(self):
        status = FpgaStatus.decode(bytes((0, 7, 3, 1, 7, 1, 1, 240)))
        self.assertEqual((status.requested_mask, status.applied_mask, status.pending), (7, 3, 1))
        for payload in (b'', bytes((0, 8, 0, 0, 7, 1, 1, 0)), bytes((0, 7, 7, 2, 7, 1, 1, 0))):
            with self.assertRaises(ValueError):
                FpgaStatus.decode(payload)

    def test_gamma_values_and_zero_denominator(self):
        data = struct.pack('<6I4B', 0xffffffff, 2000, 100, 20, 5, 3000, 2, 1, 1, 7)
        stats = GammaStats.decode(data)
        self.assertEqual((stats.mean_before, stats.mean_after, stats.dark_ratio, stats.highlight_ratio), (20, 30, .2, .05))
        zero = GammaStats.decode(bytes(28))
        self.assertIsNone(zero.mean_before)
        self.assertIsNone(zero.mean_after)
        self.assertIsNone(zero.dark_ratio)
        self.assertIsNone(zero.highlight_ratio)
        with self.assertRaises(ValueError):
            GammaStats.decode(data[:-1])

    def test_imu_documented_signed_angles_all_splits(self):
        data = bytes.fromhex('55 aa 91 0c d0 fb 18 02 82 0d')
        for split in range(11):
            parser = ImuDecoder()
            values = parser.feed(data[:split]) + parser.feed(data[split:])
            self.assertEqual(len(values), 1)
            yaw, pitch, roll = values[0].degrees
            self.assertAlmostEqual(yaw, 90.0003, places=3)
            self.assertAlmostEqual(pitch, -29.9908, places=3)
            self.assertAlmostEqual(roll, 14.9954, places=3)

    def test_imu_bad_checksum_tail_noise_and_payload_sync(self):
        payload = b'\x55\xaa\x0d\x00\x00\x00'
        valid = b'\x55\xaa' + payload + bytes((sum(payload) & 255, 13))
        bad = valid[:-1] + b'\x0a'
        parser = ImuDecoder()
        values = parser.feed(b'junk\x55' + bad + valid*2)
        self.assertEqual(len(values), 2)
        self.assertGreaterEqual(parser.errors, 1)

    def test_imu_quantized_pi_boundary_is_accepted(self):
        payload = struct.pack('<hhh', 6434, -6434, 0)
        wire = b'\x55\xaa'+payload+bytes((sum(payload)&255, 13))
        pose = ImuDecoder().feed(wire)[0]
        self.assertGreater(pose.yaw, math.pi)
        self.assertLess(pose.pitch, -math.pi)

    def test_ack_gate_ignores_telemetry_and_stale_sequences(self):
        gate = RequestGate(timeout=1)
        gate.begin(Command(SET_FEATURES, b'\x03'), 5)
        with self.assertRaises(RuntimeError):
            gate.begin(Command(GET_STATUS), 5.1)
        self.assertFalse(gate.accept(Packet(GAMMA_STATS, 1, b'')))
        self.assertFalse(gate.accept(Packet(STATUS, 99, b'')))
        self.assertFalse(gate.expired(5.9))
        self.assertTrue(gate.expired(6))
        self.assertTrue(gate.accept(Packet(STATUS, 1, b'')))
        self.assertFalse(gate.expired(8))

    def test_command_sequence_wrap(self):
        gate = RequestGate()
        gate.sequence = 255
        wire = gate.begin(Command(GET_STATUS), 0)
        self.assertEqual(PacketDecoder().feed(wire)[0].sequence, 0)
