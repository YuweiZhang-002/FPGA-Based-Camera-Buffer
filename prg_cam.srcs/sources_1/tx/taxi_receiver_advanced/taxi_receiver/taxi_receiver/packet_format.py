"""
packet_format.py  --  binary layout only, no I/O, no threading.

Mirrors the FPGA-side C structures exactly:

    pkt_row_header_t   (24 bytes)
    pkt_row_payload_t  (ROW_BYTES bytes)
    plt_row_trailer_t  (24 bytes)
                        ----------------
                        128 bytes total  =>  ROW_BYTES = 128-24-24 = 80

Kept deliberately dependency-free (just `struct` + dataclasses) so it
can be imported and unit tested without scapy, Npcap, or any hardware
in the loop -- this is the module every other layer, and every test,
builds on.

All multi-byte fields, including the final CRC16, are emitted high byte first.
"""
from __future__ import annotations

import binascii
import struct
from dataclasses import dataclass
from typing import Optional

HEADER_LEN = 24
TRAILER_LEN = 24
PACKET_LEN = 128
ROW_BYTES = PACKET_LEN - HEADER_LEN - TRAILER_LEN  # 80

# RP2354 sender-owned byte at wire offset 9.  First-row is not a flag: it is
# derived solely from row_idx == 0.
FLAG_SENDER_OVERFLOW = 1 << 0
FLAG_LAST_ROW = 1 << 1
FLAG_SENDER_ROW2_MARKER = 1 << 2
SOURCE_ROW_FLAG_MASK = (
    FLAG_SENDER_OVERFLOW | FLAG_LAST_ROW | FLAG_SENDER_ROW2_MARKER
)
# Compatibility name for callers that already describe bit 0 as frame
# overflow.  It never includes the FPGA diagnostic byte.
FLAG_FRAME_OVERFLOW = FLAG_SENDER_OVERFLOW

# FPGA-owned status is no longer ORed into the MCU row_flags byte.  It occupies
# pkt_row_header_t.reserved[0] (wire offset 13), keeping the two fault domains
# independently observable.  FLAG_LENGTH_ERROR remains as a compatibility name
# for project-side code, but it is a bit in fpga_status, not in row_flags.
FPGA_STATUS_FRAME_OVERFLOW = 1 << 0
FPGA_STATUS_LENGTH_ERROR = 1 << 3
FPGA_STATUS_CRC_ERROR = 1 << 4
FLAG_LENGTH_ERROR = FPGA_STATUS_LENGTH_ERROR

CRC_MODE_ENABLED = "enabled"
CRC_MODE_PLACEHOLDER = "placeholder"
CRC_MODES = (CRC_MODE_ENABLED, CRC_MODE_PLACEHOLDER)

# Protocol word values and their expected MSB-byte-first wire representation.
# This is byte order inside each multi-byte metadata field; it is not an
# MSB/LSB bit reversal inside an individual byte.
SYNC0_DEFAULT = 0xA5A0
SYNC1_DEFAULT = 0x5A50
SYNC_BYTES_DEFAULT = struct.pack(">HH", SYNC0_DEFAULT, SYNC1_DEFAULT)
assert SYNC_BYTES_DEFAULT == bytes.fromhex("a5a05a50")

# ---- pkt_row_header_t ---------------------------------------------------
# uint16 sync0, uint16 sync1, uint8 cam_id, uint16 frame_id, uint16 row_idx,
# uint8 sender_row_flags, uint8 payload_len, uint16 row_seq,
# uint8 fpga_status, uint8 reserved[10]
_HEADER_STRUCT_BE = struct.Struct(">HHBHHBBHB10s")
assert _HEADER_STRUCT_BE.size == HEADER_LEN

# ---- plt_row_trailer_t ---------------------------------------------------
# uint8 padding[10], uint8 sync_pattern[12], uint16 crc16
TRAILER_SYNC = bytes.fromhex("a55a" * 6)
_TRAILER_BODY_STRUCT_BE = struct.Struct(">10s12s")
assert _TRAILER_BODY_STRUCT_BE.size == TRAILER_LEN - 2

# Everything except the trailing crc16 -- this is exactly what the CRC
# is calculated over (mirrors the original code's payload[:126]).
_CRC_COVERED_LEN = PACKET_LEN - 2
_BODY_STRUCT_BE = struct.Struct(f">HHBHHBBHB10s{ROW_BYTES}s10s12s")
assert _BODY_STRUCT_BE.size == _CRC_COVERED_LEN


@dataclass(slots=True)
class RowHeader:
    sync0: int
    sync1: int
    cam_id: int
    frame_id: int
    row_idx: int
    row_flags: int
    payload_len: int
    row_seq: int
    fpga_status_raw: int
    reserved: bytes

    @property
    def fpga_status(self) -> int:
        """FPGA receiver diagnostic status byte at wire offset 13."""
        return self.fpga_status_raw


@dataclass(slots=True)
class RowTrailer:
    padding: bytes
    sync_pattern: bytes
    crc16: int


@dataclass(slots=True)
class CameraRowPacket:
    raw: bytes
    header: RowHeader
    payload: bytes
    trailer: RowTrailer

    received_crc: int
    calculated_crc: int
    crc_mode: str
    crc_checked: bool
    crc_ok: Optional[bool]

    first_row: bool
    last_row: bool
    sender_overflow: bool
    sender_row2_marker: bool
    fpga_frame_overflow: bool
    fpga_length_error: bool
    fpga_crc_error: bool
    frame_overflow: bool
    length_error: bool


def peek_camera_id(raw_ethernet_frame: bytes) -> Optional[int]:
    """Return the on-wire cam_id byte if the Ethernet frame is long enough.

    The current protocol places cam_id at Ethernet payload offset 4, which is
    absolute frame offset 18 once the 14-byte Ethernet header is included.
    This helper intentionally does not validate the full camera header; it is
    just the cheap routing hint needed by the capture thread.
    """
    if len(raw_ethernet_frame) <= 18:
        return None
    return raw_ethernet_frame[18]


def crc16_ccitt_false(data: bytes, initial: int = 0xFFFF) -> int:
    """CRC-16-CCITT (False): poly=0x1021, init=0xFFFF, refin=false,
    refout=false, xorout=0x0000 -- matches the FPGA crc16_byte core."""
    return binascii.crc_hqx(data, initial & 0xFFFF)


def normalize_crc_mode(crc_mode: str) -> str:
    if crc_mode not in CRC_MODES:
        raise ValueError(f"crc_mode must be one of {CRC_MODES}, got {crc_mode!r}")
    return crc_mode


def parse_camera_row(
    payload: bytes,
    *,
    crc_mode: str = CRC_MODE_ENABLED,
) -> CameraRowPacket:
    """Unpack a 128-byte camera-row packet. Raises ValueError if the
    length is wrong; callers that need a non-raising result should use
    camera_parser.parse_camera_mode() instead."""
    if len(payload) != PACKET_LEN:
        raise ValueError(f"camera row packet must be {PACKET_LEN} bytes, got {len(payload)}")

    crc_mode = normalize_crc_mode(crc_mode)
    (sync0, sync1, cam_id, frame_id, row_idx, row_flags, payload_len,
     row_seq, fpga_status, reserved, row_payload, padding,
     trailer_sync) = _BODY_STRUCT_BE.unpack(payload[:_CRC_COVERED_LEN])
    crc16 = int.from_bytes(payload[_CRC_COVERED_LEN:], "big")

    header = RowHeader(sync0, sync1, cam_id, frame_id, row_idx,
                       row_flags, payload_len, row_seq, fpga_status,
                       reserved)
    trailer = RowTrailer(padding, trailer_sync, crc16)

    calculated_crc = crc16_ccitt_false(payload[:_CRC_COVERED_LEN])
    crc_checked = crc_mode == CRC_MODE_ENABLED
    sender_overflow = bool(row_flags & FLAG_SENDER_OVERFLOW)
    fpga_frame_overflow = bool(
        fpga_status & FPGA_STATUS_FRAME_OVERFLOW
    )

    return CameraRowPacket(
        raw=payload,
        header=header,
        payload=row_payload,
        trailer=trailer,
        received_crc=crc16,
        calculated_crc=calculated_crc,
        crc_mode=crc_mode,
        crc_checked=crc_checked,
        crc_ok=(crc16 == calculated_crc) if crc_checked else None,
        first_row=(row_idx == 0),
        last_row=bool(row_flags & FLAG_LAST_ROW),
        sender_overflow=sender_overflow,
        sender_row2_marker=bool(row_flags & FLAG_SENDER_ROW2_MARKER),
        fpga_frame_overflow=fpga_frame_overflow,
        fpga_length_error=bool(fpga_status & FPGA_STATUS_LENGTH_ERROR),
        fpga_crc_error=bool(fpga_status & FPGA_STATUS_CRC_ERROR),
        frame_overflow=sender_overflow or fpga_frame_overflow,
        length_error=bool(fpga_status & FPGA_STATUS_LENGTH_ERROR),
    )


def build_camera_row(
    *,
    cam_id: int,
    frame_id: int,
    row_idx: int,
    row_flags: int,
    row_seq: int,
    payload: bytes,
    sync0: int = SYNC0_DEFAULT,
    sync1: int = SYNC1_DEFAULT,
    payload_len: Optional[int] = None,
    reserved: bytes = b"\x00" * 10,
    fpga_status: Optional[int] = None,
    trailer_padding: bytes = b"\x00" * 10,
    trailer_sync: bytes = TRAILER_SYNC,
    crc_mode: str = CRC_MODE_ENABLED,
    corrupt_crc: bool = False,
) -> bytes:
    """Build a well-formed (or, with corrupt_crc=True, deliberately
    broken) 128-byte camera row packet.

    This is the synthetic-packet generator: it's what lets Layers 2-4
    be exercised in unit tests without any RMII/FPGA hardware, real
    NIC, or Npcap/root privileges in the loop -- see README.md.
    """
    if len(payload) != ROW_BYTES:
        raise ValueError(f"payload must be {ROW_BYTES} bytes, got {len(payload)}")
    if len(reserved) != 10:
        raise ValueError("reserved must be 10 bytes")
    if len(trailer_padding) != 10:
        raise ValueError("trailer_padding must be 10 bytes")
    if len(trailer_sync) != 12:
        raise ValueError("trailer_sync must be 12 bytes")
    crc_mode = normalize_crc_mode(crc_mode)
    if payload_len is None:
        payload_len = ROW_BYTES

    if fpga_status is None:
        fpga_status = 0
    if not 0 <= fpga_status <= 0xFF:
        raise ValueError("fpga_status must fit in one byte")

    body = _BODY_STRUCT_BE.pack(
        sync0, sync1, cam_id, frame_id, row_idx, row_flags,
        payload_len, row_seq, fpga_status, reserved, payload,
        trailer_padding, trailer_sync,
    )
    if crc_mode == CRC_MODE_PLACEHOLDER:
        if corrupt_crc:
            raise ValueError("corrupt_crc is not meaningful in placeholder mode")
        return body + b"\xFF\xFF"
    crc = crc16_ccitt_false(body)
    if corrupt_crc:
        crc ^= 0xFFFF
    return body + struct.pack(">H", crc)


class ByteStreamFramer:
    """Depacketizer for a *continuous, unframed* byte stream -- e.g. a
    raw UART/serial bridge or an FPGA DMA/debug channel that hasn't
    already been split into discrete Ethernet frames by an OS NIC
    driver.

    This is NOT needed for the current Scapy/Npcap capture path --
    libpcap already delivers whole frames there. It's the answer to
    "what if I extend capture to a raw byte-stream source later":
    the FPGA's RMII-side "shift 2 bits in, count to 8" logic has
    already been done for you by the time bytes reach Python (by the
    PHY/MAC + driver, or by the FPGA's own RMII receiver block if
    *you* control that RTL). Python only ever needs the byte-level
    analogue: hunt for the sync word to (re)gain alignment, then count
    up to PACKET_LEN bytes.
    """

    def __init__(self, on_packet):
        self._buf = bytearray()
        self._on_packet = on_packet
        self._sync = SYNC_BYTES_DEFAULT

    def feed(self, chunk: bytes) -> None:
        self._buf.extend(chunk)
        while True:
            idx = self._buf.find(self._sync)
            if idx == -1:
                # No sync word yet -- keep only enough tail bytes that
                # a sync word could still be found once split across
                # chunk boundaries.
                keep = len(self._sync) - 1
                if len(self._buf) > keep:
                    del self._buf[: len(self._buf) - keep]
                return

            if idx > 0:
                del self._buf[:idx]

            if len(self._buf) < PACKET_LEN:
                return

            packet = bytes(self._buf[:PACKET_LEN])
            del self._buf[:PACKET_LEN]
            self._on_packet(packet)

    def reset(self) -> None:
        self._buf.clear()
