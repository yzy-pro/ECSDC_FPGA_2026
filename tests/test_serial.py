"""PTY integration: exercise real pyserial reads without physical devices."""
import os
import select
import struct
import time
import unittest
from fpga_host.core.protocols import PacketDecoder, encode_packet, STATUS, GAMMA_STATS, SET_FEATURES
from fpga_host.devices.serial_link import SerialWorker


def until(predicate, timeout=1):
    end = time.monotonic()+timeout
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(.005)
    return False


@unittest.skipUnless(os.name == 'posix', 'PTY integration requires POSIX')
class SerialIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.master, self.slave = os.openpty()
        self.worker = SerialWorker(os.ttyname(self.slave), 'FPGA')
        self.worker.start()
        self.decoder = PacketDecoder()
        self.pending = []

    def tearDown(self):
        self.worker.stop()
        os.close(self.master)
        os.close(self.slave)
        self.assertFalse(self.worker.thread.is_alive())

    def request(self, timeout=1):
        end = time.monotonic()+timeout
        while time.monotonic() < end:
            if self.pending:
                return self.pending.pop(0)
            if select.select([self.master], [], [], .05)[0]:
                self.pending += self.decoder.feed(os.read(self.master, 4096))
        self.fail('request not received')

    def status(self, seq, requested=7, applied=7, pending=0):
        frame = encode_packet(STATUS, seq, bytes((0, requested, applied, pending, 7, 1, 1, 0)))
        os.write(self.master, frame[:4])
        os.write(self.master, frame[4:])

    def test_telemetry_before_ack_and_pending_application(self):
        first = self.request()
        gamma = struct.pack('<6I4B', 44, 500, 10, 2, 1, 800, 2, 1, 1, 7)
        os.write(self.master, encode_packet(GAMMA_STATS, 0, gamma))
        self.assertTrue(until(lambda: self.worker.snapshot()['gamma'] is not None))
        self.assertIsNone(self.worker.snapshot()['status'])
        self.status(first.sequence)
        self.assertTrue(until(lambda: self.worker.snapshot()['status'] is not None))
        self.assertTrue(self.worker.send(SET_FEATURES, b'\x03'))
        self.assertFalse(self.worker.send(SET_FEATURES, b'\x07'))
        command = self.request()
        self.assertEqual((command.kind, command.payload), (SET_FEATURES, b'\x03'))
        # A stale ACK cannot complete this command.
        self.status((command.sequence+100)&255)
        time.sleep(.04)
        self.assertTrue(self.worker.snapshot()['busy'])
        self.status(command.sequence, 3, 7, 1)
        self.assertTrue(until(lambda: not self.worker.snapshot()['busy']))
        self.assertEqual(self.worker.snapshot()['status'].pending, 1)
        poll = self.request()
        self.status(poll.sequence, 3, 3, 0)
        self.assertTrue(until(lambda: self.worker.snapshot()['status'].applied_mask == 3))
        # Repeated stats update receive time but not frame-change time.
        previous = self.worker.snapshot()['last_frame_change']
        time.sleep(.02)
        os.write(self.master, encode_packet(GAMMA_STATS, 1, gamma))
        self.assertTrue(until(lambda: self.worker.snapshot()['last_gamma'] > previous))
        self.assertEqual(self.worker.snapshot()['last_frame_change'], previous)

    def test_no_response_times_out_without_replaying_set(self):
        first = self.request()
        self.status(first.sequence)
        self.assertTrue(until(lambda: self.worker.snapshot()['status'] is not None))
        self.assertTrue(self.worker.send(SET_FEATURES, b'\x00'))
        self.assertEqual(self.request().kind, SET_FEATURES)
        self.assertTrue(until(lambda: not self.worker.snapshot()['connected'], timeout=1.4))
        self.assertIsNone(self.worker.snapshot()['status'])
        self.assertTrue(any('响应超时' in msg for msg in self.worker.drain_events()))
