"""
camera_parser.py  --  Layer 3 (Camera Packet Parser).

Wraps packet_format's pure struct/CRC logic with the two operating
modes from the original tool (`fixed` self-test, `camera` real
packets), and returns plain result dataclasses instead of mutating
statistics or printing -- that split is what makes this layer testable
on its own, and lets Layer 4 (stream_monitor) stay a dumb consumer of
results rather than reimplementing parsing.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from .packet_format import (
    CameraRowPacket,
    PACKET_LEN,
    ROW_BYTES,
    SYNC0_DEFAULT,
    SYNC1_DEFAULT,
    parse_camera_row,
)

FIXED_TEST_PAYLOAD = bytes(range(128))
LEGACY_PROTOCOL = "legacy-v0-observed"


@dataclass(slots=True)
class FixedModeResult:
    ok: bool
    reason: str = ""  # "", "bad_length", "bad_data"
    mismatch_offset: Optional[int] = None
    received_len: int = 0


@dataclass(slots=True)
class CameraModeResult:
    ok: bool
    reason: str = ""
    packet: Optional[CameraRowPacket] = None
    received_len: int = 0
    protocol: str = LEGACY_PROTOCOL
    errors: tuple[str, ...] = ()
    warnings: tuple[str, ...] = ()


def parse_fixed_mode(payload: bytes) -> FixedModeResult:
    if len(payload) != PACKET_LEN:
        return FixedModeResult(ok=False, reason="bad_length", received_len=len(payload))

    if payload != FIXED_TEST_PAYLOAD:
        offset = _first_mismatch(payload, FIXED_TEST_PAYLOAD)
        return FixedModeResult(
            ok=False, reason="bad_data",
            mismatch_offset=offset, received_len=len(payload),
        )

    return FixedModeResult(ok=True, received_len=len(payload))


def parse_camera_mode(payload: bytes) -> CameraModeResult:
    if len(payload) != PACKET_LEN:
        return CameraModeResult(
            ok=False,
            reason="bad_length",
            received_len=len(payload),
            errors=("bad_length",),
        )

    packet = parse_camera_row(payload)
    errors: list[str] = []
    warnings: list[str] = []

    # Current protocol words are 0xA5A0/0x5A50 and the observed/expected raw
    # Ethernet payload bytes are A5 A0 5A 50 (MSB byte first). There is no
    # protocol-version field; reject another pair instead of silently parsing
    # an incompatible layout.
    if (
        packet.header.sync0 != SYNC0_DEFAULT
        or packet.header.sync1 != SYNC1_DEFAULT
    ):
        errors.append("bad_sync")

    # payload_len describes valid bytes inside the fixed 80-byte row payload.
    # Zero is not rejected because the RP2350A source definition is absent;
    # surface it as a warning until firmware defines whether an empty row is
    # legal.  A value larger than the physical field is unambiguously invalid.
    if packet.header.payload_len > ROW_BYTES:
        errors.append("payload_len_out_of_range")
    elif packet.header.payload_len == 0:
        warnings.append("zero_payload_len")

    if not packet.crc_ok:
        errors.append("crc_error")

    # These flags are generated/ORed by the active FPGA capture path and make
    # the packet unsuitable for image reconstruction even when its post-capture
    # CRC is correct.
    if packet.frame_overflow:
        errors.append("frame_overflow")
    if packet.length_error:
        errors.append("length_error")

    return CameraModeResult(
        ok=not errors,
        reason=errors[0] if errors else "",
        packet=packet,
        received_len=len(payload),
        errors=tuple(errors),
        warnings=tuple(warnings),
    )


def _first_mismatch(received: bytes, expected: bytes) -> int:
    for index, (actual, wanted) in enumerate(zip(received, expected)):
        if actual != wanted:
            return index
    return min(len(received), len(expected))
