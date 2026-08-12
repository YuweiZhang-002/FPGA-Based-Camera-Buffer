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
    CRC_MODE_ENABLED,
    PACKET_LEN,
    ROW_BYTES,
    SOURCE_ROW_FLAG_MASK,
    SYNC0_DEFAULT,
    SYNC1_DEFAULT,
    TRAILER_SYNC,
    normalize_crc_mode,
    parse_camera_row,
)

FIXED_TEST_PAYLOAD = bytes(range(128))
CAMERA_PROTOCOL = "rp2354-camera-row-v1"
EXPECTED_IMAGE_ROWS = 480


@dataclass(slots=True)
class FixedModeResult:
    ok: bool
    reason: str = ""  # "", "bad_length", "bad_data"
    mismatch_offset: Optional[int] = None
    received_len: int = 0


@dataclass(slots=True)
class CameraModeResult:
    ok: bool
    parsed_ok: bool = False
    reason: str = ""
    packet: Optional[CameraRowPacket] = None
    received_len: int = 0
    protocol: str = CAMERA_PROTOCOL
    crc_mode: str = CRC_MODE_ENABLED
    crc_checked: bool = False
    crc_ok: Optional[bool] = None
    protocol_errors: tuple[str, ...] = ()
    diagnostic_errors: tuple[str, ...] = ()
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


def parse_camera_mode(
    payload: bytes,
    *,
    crc_mode: str = CRC_MODE_ENABLED,
) -> CameraModeResult:
    crc_mode = normalize_crc_mode(crc_mode)
    if len(payload) != PACKET_LEN:
        return CameraModeResult(
            ok=False,
            parsed_ok=False,
            reason="bad_length",
            received_len=len(payload),
            crc_mode=crc_mode,
            crc_checked=False,
            protocol_errors=("bad_length",),
            errors=("bad_length",),
        )

    packet = parse_camera_row(payload, crc_mode=crc_mode)
    protocol_errors: list[str] = []
    diagnostic_errors: list[str] = []
    warnings: list[str] = []

    # Current protocol words are 0xA5A0/0x5A50 and the observed/expected raw
    # Ethernet payload bytes are A5 A0 5A 50 (MSB byte first). There is no
    # protocol-version field; reject another pair instead of silently parsing
    # an incompatible layout.
    if (
        packet.header.sync0 != SYNC0_DEFAULT
        or packet.header.sync1 != SYNC1_DEFAULT
    ):
        protocol_errors.append("bad_sync")

    if packet.header.payload_len != ROW_BYTES:
        protocol_errors.append("bad_payload_len")

    if packet.crc_checked and packet.crc_ok is False:
        protocol_errors.append("crc_error")
    elif not packet.crc_checked and packet.received_crc != 0xFFFF:
        warnings.append("crc_placeholder_non_ffff")

    if packet.header.cam_id > 3:
        protocol_errors.append("cam_id_out_of_range")
    if packet.header.row_idx >= EXPECTED_IMAGE_ROWS:
        protocol_errors.append("row_idx_out_of_range")

    # Offset 9 belongs only to the sender.  Any bit outside overflow/final/
    # row2-marker is a protocol-version mismatch, not FPGA status.
    if packet.header.row_flags & ~SOURCE_ROW_FLAG_MASK:
        protocol_errors.append("undefined_sender_flag_bits")

    # Only offsets 14..23 are reserved.  Offset 13 is the separately decoded
    # FPGA receiver diagnostic status byte and is intentionally excluded.
    if any(packet.header.reserved):
        protocol_errors.append("reserved_nonzero")
    if any(packet.trailer.padding):
        protocol_errors.append("trailer_padding_nonzero")
    if packet.trailer.sync_pattern != TRAILER_SYNC:
        protocol_errors.append("bad_trailer_sync")

    # Diagnostic status is not a structural parse failure.  Keep it separate
    # so normalized 127/129-byte rows are auditable (parsed_ok=True) while
    # remaining ineligible for image reassembly (ok=False).
    if packet.sender_overflow:
        diagnostic_errors.append("sender_overflow")
    if packet.fpga_frame_overflow:
        diagnostic_errors.append("fpga_frame_overflow")
    if packet.fpga_length_error:
        diagnostic_errors.append("fpga_length_error")
    if packet.fpga_crc_error:
        diagnostic_errors.append("fpga_crc_error")

    errors = (*protocol_errors, *diagnostic_errors)
    parsed_ok = not protocol_errors

    return CameraModeResult(
        ok=parsed_ok and not diagnostic_errors,
        parsed_ok=parsed_ok,
        reason=errors[0] if errors else "",
        packet=packet,
        received_len=len(payload),
        crc_mode=crc_mode,
        crc_checked=packet.crc_checked,
        crc_ok=packet.crc_ok,
        protocol_errors=tuple(protocol_errors),
        diagnostic_errors=tuple(diagnostic_errors),
        errors=errors,
        warnings=tuple(warnings),
    )


def _first_mismatch(received: bytes, expected: bytes) -> int:
    for index, (actual, wanted) in enumerate(zip(received, expected)):
        if actual != wanted:
            return index
    return min(len(received), len(expected))
