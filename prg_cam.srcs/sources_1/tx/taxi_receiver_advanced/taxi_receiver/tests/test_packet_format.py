import binascii

import pytest

from taxi_receiver.packet_format import (
    ByteStreamFramer,
    CRC_MODE_PLACEHOLDER,
    FLAG_FRAME_OVERFLOW,
    FLAG_LAST_ROW,
    FLAG_LENGTH_ERROR,
    FLAG_SENDER_ROW2_MARKER,
    FPGA_STATUS_CRC_ERROR,
    FPGA_STATUS_LENGTH_ERROR,
    PACKET_LEN,
    ROW_BYTES,
    TRAILER_SYNC,
    build_camera_row,
    crc16_ccitt_false,
    parse_camera_row,
)


def test_sizes_and_flag_assignments():
    assert PACKET_LEN == 128
    assert ROW_BYTES == 80
    assert FLAG_FRAME_OVERFLOW == 0x01
    assert FLAG_LAST_ROW == 0x02
    assert FLAG_SENDER_ROW2_MARKER == 0x04
    assert FLAG_LENGTH_ERROR == 0x08
    assert FPGA_STATUS_CRC_ERROR == 0x10


def test_round_trip_uses_row_index_for_first_and_bit2_for_row2_marker():
    payload = bytes(range(80))
    raw = build_camera_row(
        cam_id=2,
        frame_id=100,
        row_idx=2,
        row_flags=FLAG_SENDER_ROW2_MARKER,
        row_seq=42,
        payload=payload,
    )
    packet = parse_camera_row(raw)

    assert packet.crc_checked and packet.crc_ok
    assert not packet.first_row
    assert packet.sender_row2_marker
    assert packet.payload == payload

    first = parse_camera_row(
        build_camera_row(
            cam_id=2, frame_id=100, row_idx=0, row_flags=0,
            row_seq=40, payload=payload,
        )
    )
    assert first.first_row
    assert not first.sender_row2_marker


def test_fpga_status_is_separate_from_sender_flags_and_reserved():
    status = FPGA_STATUS_LENGTH_ERROR | FPGA_STATUS_CRC_ERROR
    raw = build_camera_row(
        cam_id=0,
        frame_id=7,
        row_idx=3,
        row_flags=FLAG_SENDER_ROW2_MARKER,
        row_seq=9,
        payload=bytes(ROW_BYTES),
        fpga_status=status,
    )
    packet = parse_camera_row(raw)

    assert raw[9] == FLAG_SENDER_ROW2_MARKER
    assert raw[13] == status
    assert raw[14:24] == bytes(10)
    assert packet.header.fpga_status_raw == status
    assert packet.fpga_length_error
    assert packet.fpga_crc_error


def test_all_metadata_crc_and_trailer_are_big_endian_and_fixed():
    raw = build_camera_row(
        cam_id=0,
        frame_id=0x1234,
        row_idx=0x01DF,
        row_flags=0,
        row_seq=0xABCD,
        payload=bytes(80),
    )
    packet = parse_camera_row(raw)

    assert raw[:4] == bytes.fromhex("a5a05a50")
    assert raw[5:7] == bytes.fromhex("1234")
    assert raw[7:9] == bytes.fromhex("01df")
    assert raw[11:13] == bytes.fromhex("abcd")
    assert raw[104:114] == bytes(10)
    assert raw[114:126] == TRAILER_SYNC
    assert raw[126:128] == packet.calculated_crc.to_bytes(2, "big")
    assert packet.trailer.padding == bytes(10)
    assert packet.trailer.sync_pattern == TRAILER_SYNC


def test_placeholder_mode_is_explicit_and_not_checked():
    raw = build_camera_row(
        cam_id=0, frame_id=1, row_idx=0, row_flags=0,
        row_seq=0, payload=bytes(80), crc_mode=CRC_MODE_PLACEHOLDER,
    )
    packet = parse_camera_row(raw, crc_mode=CRC_MODE_PLACEHOLDER)

    assert raw[126:128] == b"\xFF\xFF"
    assert not packet.crc_checked
    assert packet.crc_ok is None


def test_corrupt_crc_detected_when_enabled():
    raw = build_camera_row(
        cam_id=1, frame_id=1, row_idx=0, row_flags=0,
        row_seq=0, payload=bytes(range(80)), corrupt_crc=True,
    )
    packet = parse_camera_row(raw)
    assert packet.crc_checked
    assert packet.crc_ok is False


@pytest.mark.parametrize(
    "data",
    [b"", b"\x00", b"\x00\x01", bytes(range(80)), bytes(range(126))],
)
def test_crc16_ccitt_false_matches_binascii_crc_hqx(data):
    assert crc16_ccitt_false(data) == binascii.crc_hqx(data, 0xFFFF)


def test_byte_stream_framer_resyncs_and_extracts_packets():
    good = build_camera_row(
        cam_id=0, frame_id=1, row_idx=0, row_flags=0,
        row_seq=0, payload=bytes(80),
    )
    seen = []
    framer = ByteStreamFramer(on_packet=seen.append)
    stream = b"\x00\x11\x22\x33\x44" + good + good
    for index in range(0, len(stream), 7):
        framer.feed(stream[index:index + 7])
    assert seen == [good, good]
