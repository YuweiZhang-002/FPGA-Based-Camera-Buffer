"""Frozen byte-level contract for the RP2354 128-byte row packet."""

from pathlib import Path


VECTOR_PATH = Path(__file__).parent / "vectors" / "rp2354_camera_row_v1.hex"


def test_rp2354_camera_row_v1_golden_offsets():
    raw = bytes.fromhex(VECTOR_PATH.read_text(encoding="ascii"))

    assert len(raw) == 128
    assert raw[0:2] == bytes.fromhex("a5a0")
    assert raw[2:4] == bytes.fromhex("5a50")
    assert raw[4] == 0x02
    assert raw[5:7] == bytes.fromhex("1234")
    assert raw[7:9] == bytes.fromhex("0002")
    assert raw[9] == 0x04
    assert raw[10] == 0x50
    assert raw[11:13] == bytes.fromhex("abcd")
    assert raw[13] == 0x18
    assert raw[14:24] == bytes(10)
    assert raw[24:104] == bytes(range(80))
    assert raw[104:114] == bytes(10)
    assert raw[114:126] == bytes.fromhex("a55a" * 6)
    assert raw[126:128] == bytes.fromhex("ffff")


def test_sender_row2_marker_is_not_a_first_row_marker():
    raw = bytes.fromhex(VECTOR_PATH.read_text(encoding="ascii"))

    row_idx = int.from_bytes(raw[7:9], "big")
    sender_row2_marker = bool(raw[9] & 0x04)
    first_row = row_idx == 0

    assert sender_row2_marker
    assert not first_row
