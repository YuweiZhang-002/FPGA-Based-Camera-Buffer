from taxi_receiver.camera_parser import parse_camera_mode, parse_fixed_mode
from taxi_receiver.packet_format import (
    CRC_MODE_PLACEHOLDER,
    FPGA_STATUS_CRC_ERROR,
    FPGA_STATUS_LENGTH_ERROR,
    ROW_BYTES,
    TRAILER_SYNC,
    build_camera_row,
)


def _row(**overrides):
    values = dict(
        cam_id=0,
        frame_id=1,
        row_idx=0,
        row_flags=0,
        row_seq=0,
        payload=bytes(ROW_BYTES),
    )
    values.update(overrides)
    return build_camera_row(**values)


def test_fixed_modes():
    assert parse_fixed_mode(bytes(range(128))).ok
    assert parse_fixed_mode(bytes(100)).reason == "bad_length"
    payload = bytearray(range(128))
    payload[10] ^= 0xFF
    assert parse_fixed_mode(bytes(payload)).mismatch_offset == 10


def test_enabled_crc_correct_and_error_paths():
    good = parse_camera_mode(_row())
    bad = parse_camera_mode(_row(corrupt_crc=True))
    assert good.ok and good.parsed_ok and good.crc_checked and good.crc_ok
    assert not bad.ok and not bad.parsed_ok
    assert bad.reason == "crc_error"


def test_placeholder_crc_is_unchecked_and_never_reported_failed():
    raw = _row(crc_mode=CRC_MODE_PLACEHOLDER)
    result = parse_camera_mode(raw, crc_mode=CRC_MODE_PLACEHOLDER)
    assert result.ok and result.parsed_ok
    assert not result.crc_checked
    assert result.crc_ok is None
    assert "crc_error" not in result.errors


def test_row_idx_zero_is_first_and_bit2_is_only_sender_row2_marker():
    first = parse_camera_mode(_row(row_idx=0, row_flags=0))
    row2 = parse_camera_mode(_row(row_idx=2, row_flags=0x04))
    assert first.packet is not None and first.packet.first_row
    assert not first.packet.sender_row2_marker
    assert row2.packet is not None and not row2.packet.first_row
    assert row2.packet.sender_row2_marker


def test_fpga_status_is_diagnostic_not_reserved_and_rejects_image_use():
    result = parse_camera_mode(
        _row(fpga_status=FPGA_STATUS_LENGTH_ERROR | FPGA_STATUS_CRC_ERROR)
    )
    assert result.parsed_ok
    assert not result.ok
    assert result.protocol_errors == ()
    assert result.diagnostic_errors == (
        "fpga_length_error", "fpga_crc_error"
    )
    assert "reserved_nonzero" not in result.errors


def test_static_protocol_error_names():
    cases = (
        (_row(sync0=0x1234), "bad_sync"),
        (_row(payload_len=79), "bad_payload_len"),
        (_row(cam_id=4), "cam_id_out_of_range"),
        (_row(row_idx=480), "row_idx_out_of_range"),
        (_row(row_flags=0x08), "undefined_sender_flag_bits"),
        (_row(reserved=b"\x01" + bytes(9)), "reserved_nonzero"),
        (_row(trailer_padding=b"\x01" + bytes(9)), "trailer_padding_nonzero"),
        (_row(trailer_sync=TRAILER_SYNC[:-1] + b"\x00"), "bad_trailer_sync"),
    )
    for raw, expected in cases:
        result = parse_camera_mode(raw)
        assert expected in result.protocol_errors
        assert not result.parsed_ok


def test_sender_overflow_is_separate_diagnostic_error():
    result = parse_camera_mode(_row(row_idx=1, row_flags=0x01))
    assert result.parsed_ok and not result.ok
    assert result.errors == ("sender_overflow",)


def test_bad_length_has_no_parsed_packet_and_crc_is_not_checked():
    result = parse_camera_mode(bytes(127))
    assert not result.ok and not result.parsed_ok
    assert result.packet is None
    assert result.reason == "bad_length"
    assert not result.crc_checked
