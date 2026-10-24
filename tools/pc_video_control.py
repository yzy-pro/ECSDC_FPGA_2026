"""CP2102 video-control protocol codec and optional pyserial command-line client."""
import argparse
from functools import reduce
import json
from operator import xor
import struct
import time

EXPONENTS = (0.50, 0.65, 0.80, 1.00, 1.25, 1.55, 1.90)


def encode_packet(kind, sequence, payload=b''):
    payload = bytes(payload)
    if len(payload) > 64:
        raise ValueError('payload exceeds protocol limit')
    body = bytes((1, kind, sequence, len(payload))) + payload
    return b'\xa5\x5a' + body + bytes((reduce(xor, body, 0),))


class PacketDecoder:
    """Preserve partial packets and recover sync after noise or bad checksums."""

    def __init__(self):
        self.buffer = bytearray()

    def feed(self, data):
        self.buffer.extend(data)
        packets = []
        while True:
            index = self.buffer.find(b'\xa5\x5a')
            if index < 0:
                self.buffer[:] = self.buffer[-1:] if self.buffer[-1:] == b'\xa5' else b''
                break
            del self.buffer[:index]
            if len(self.buffer) < 6:
                break
            length = self.buffer[5]
            if self.buffer[2] != 1 or length > 64:
                del self.buffer[0]
                continue
            total = 7 + length
            if len(self.buffer) < total:
                break
            if reduce(xor, self.buffer[2:total], 0):
                del self.buffer[0]
                continue
            packets.append((self.buffer[3], self.buffer[4], bytes(self.buffer[6:6 + length])))
            del self.buffer[:total]
        return packets


def decode_status(payload):
    if len(payload) != 8:
        raise ValueError('status payload must contain 8 bytes')
    names = ('result', 'requested_mask', 'applied_mask', 'pending', 'available_mask',
             'stream_enabled', 'has_stats', 'receive_errors_mod256')
    return dict(zip(names, payload))


def decode_gamma(payload):
    if len(payload) != 28:
        raise ValueError('gamma payload must contain 28 bytes')
    values = struct.unpack('<6I4B', payload)
    names = ('frame_index', 'raw_luma_sum', 'pixel_count', 'dark_count', 'highlight_count',
             'corrected_luma_sum', 'active_curve', 'target_curve', 'gamma_enabled', 'frame_mask')
    result = dict(zip(names, values))
    count = result['pixel_count']
    result['mean_before'] = result['raw_luma_sum'] / count if count else None
    result['mean_after'] = result['corrected_luma_sum'] / count if count else None
    result['dark_ratio'] = result['dark_count'] / count if count else None
    result['highlight_ratio'] = result['highlight_count'] / count if count else None
    curve = result['active_curve']
    result['exponent'] = EXPONENTS[curve] if curve < len(EXPONENTS) else None
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True, help='CP2102 serial port, e.g. COM5')
    parser.add_argument('--mask', type=lambda value: int(value, 0), choices=range(8),
                        help='bit0=lens, bit1=pose, bit2=adaptive gamma')
    parser.add_argument('--stream', choices=('on', 'off'))
    parser.add_argument('--snapshot', action='store_true')
    parser.add_argument('--watch', type=float, default=0, metavar='SECONDS')
    args = parser.parse_args()
    try:
        import serial
    except ImportError:
        parser.error('pyserial is required for hardware I/O: python -m pip install pyserial')
    decoder = PacketDecoder()
    sequence = 0
    telemetry_count = 0

    def receive(port):
        nonlocal telemetry_count
        packets = decoder.feed(port.read(max(port.in_waiting, 1)))
        for kind, seq, payload in packets:
            if kind == 0x81:
                telemetry_count += 1
                print(json.dumps({'type': 'gamma', 'sequence': seq, **decode_gamma(payload)}), flush=True)
        return packets

    def command(port, kind, payload=b''):
        nonlocal sequence
        sequence = (sequence + 1) & 255
        port.write(encode_packet(kind, sequence, payload))
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            for received_kind, received_sequence, received_payload in receive(port):
                if received_kind == 0x80 and received_sequence == sequence:
                    status = decode_status(received_payload)
                    print(json.dumps({'type': 'status', 'sequence': sequence, **status}), flush=True)
                    if status['result']:
                        raise RuntimeError(f"FPGA rejected command: result={status['result']}")
                    return status
        raise TimeoutError('No matching status response from FPGA')

    with serial.Serial(args.port, 115200, bytesize=8, parity='N', stopbits=1,
                       timeout=0.05, write_timeout=1, rtscts=False, dsrdtr=False,
                       xonxoff=False) as port:
        command(port, 0x11)
        if args.stream is not None:
            command(port, 0x12, bytes((int(args.stream == 'on'),)))
        if args.mask is not None:
            command(port, 0x10, bytes((args.mask,)))
            deadline = time.monotonic() + 3
            while True:
                status = command(port, 0x11)
                if not status['pending'] and status['applied_mask'] == args.mask:
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError('Command accepted but no input SOF applied it; check HDMI source')
                time.sleep(0.05)
        if args.snapshot:
            before = telemetry_count
            command(port, 0x13)
            deadline = time.monotonic() + 2
            while telemetry_count == before:
                receive(port)
                if time.monotonic() >= deadline:
                    raise TimeoutError('Snapshot response did not arrive')
        deadline = time.monotonic() + max(args.watch, 0)
        while time.monotonic() < deadline:
            receive(port)


if __name__ == '__main__':
    main()
