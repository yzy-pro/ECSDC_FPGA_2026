"""One outstanding request, ACK correlation and timeout tracking."""
from dataclasses import dataclass
from fpga_host.core.protocols import STATUS, encode_packet


@dataclass(frozen=True)
class Command:
    kind: int
    payload: bytes = b""


class RequestGate:
    def __init__(self, timeout=1.0):
        self.sequence = 0
        self.outstanding = None
        self.timeout = timeout

    def begin(self, command, now):
        if self.outstanding is not None:
            raise RuntimeError("only one request may be outstanding")
        self.sequence = (self.sequence + 1) & 255
        self.outstanding = (self.sequence, now, command)
        return encode_packet(command.kind, self.sequence, command.payload)

    def accept(self, packet):
        if packet.kind != STATUS or self.outstanding is None or packet.sequence != self.outstanding[0]:
            return False
        self.outstanding = None
        return True

    def expired(self, now):
        return self.outstanding is not None and now - self.outstanding[1] >= self.timeout
