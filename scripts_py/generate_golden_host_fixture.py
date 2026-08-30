"""Generate the public, deterministic Host replay fixtures.

The packet bytes are built by the checked-out Host receiver's public
``taxi_receiver.packet_format`` implementation.  This script deliberately
does not contain a second copy of the packet layout.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
import sys
from pathlib import Path


PCAP_GLOBAL = struct.Struct("<IHHIIII")
PCAP_RECORD = struct.Struct("<IIII")
PCAP_MAGIC = 0xA1B2C3D4
ETHERTYPE = 0x88B5
EXPECTED_ROWS = 480
IMAGE_WIDTH = 640


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_head(repository: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def image_row(camera_id: int, row_index: int) -> bytes:
    """Return a visible 640-pixel MSB-first checker/diagonal test row."""
    packed = bytearray(80)
    horizontal_shift = camera_id * 16
    for x in range(IMAGE_WIDTH):
        checker = ((x + horizontal_shift) // 32 + row_index // 24) % 2
        diagonal = abs((x + horizontal_shift) % IMAGE_WIDTH - row_index) < 3
        if checker ^ diagonal:
            packed[x // 8] |= 1 << (7 - (x % 8))
    return bytes(packed)


def ethernet_frame(payload: bytes, camera_id: int) -> bytes:
    destination = bytes.fromhex("ffffffffffff")
    # Both camera lanes leave through the same FPGA Ethernet MAC.  cam_id is
    # payload metadata, not a source-MAC selector.
    source = bytes.fromhex("020000000002")
    return destination + source + ETHERTYPE.to_bytes(2, "big") + payload


def write_pcap(path: Path, records: list[tuple[int, int, bytes]]) -> None:
    with path.open("wb") as handle:
        handle.write(PCAP_GLOBAL.pack(PCAP_MAGIC, 2, 4, 0, 0, 65535, 1))
        for seconds, microseconds, frame in records:
            handle.write(
                PCAP_RECORD.pack(seconds, microseconds, len(frame), len(frame))
            )
            handle.write(frame)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host-repo", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()

    host_repo = args.host_repo.resolve()
    output_root = args.output_root.resolve()
    packet_format = host_repo / "taxi_receiver" / "packet_format.py"
    if not packet_format.is_file():
        raise SystemExit(f"Host packet_format.py not found: {packet_format}")
    if output_root.exists() and any(output_root.iterdir()):
        raise SystemExit(f"output root is not empty: {output_root}")
    output_root.mkdir(parents=True, exist_ok=True)

    sys.path.insert(0, str(host_repo))
    from taxi_receiver.packet_format import (  # pylint: disable=import-error
        FLAG_FIRST_PROCESSED_ROW,
        FLAG_LAST_ROW,
        build_camera_row,
        parse_camera_row,
    )

    records: list[tuple[int, int, bytes]] = []
    base_seconds = 1_700_000_000
    first_crc: dict[str, str] = {}
    last_crc: dict[str, str] = {}
    for row_index in range(EXPECTED_ROWS):
        for camera_id in (0, 1):
            flags = 0
            if row_index == 2:
                flags |= FLAG_FIRST_PROCESSED_ROW
            if row_index == EXPECTED_ROWS - 1:
                flags |= FLAG_LAST_ROW
            packet = build_camera_row(
                cam_id=camera_id,
                frame_id=100 + camera_id,
                row_idx=row_index,
                row_flags=flags,
                row_seq=row_index,
                payload=image_row(camera_id, row_index),
                fpga_status=0,
            )
            parsed = parse_camera_row(packet)
            if not parsed.crc_ok:
                raise RuntimeError("generator produced an invalid CRC")
            if row_index == 0:
                first_crc[f"cam{camera_id}"] = f"0x{parsed.received_crc:04X}"
            if row_index == EXPECTED_ROWS - 1:
                last_crc[f"cam{camera_id}"] = f"0x{parsed.received_crc:04X}"
            usec = row_index * 1_000 + camera_id * 200
            records.append(
                (base_seconds + usec // 1_000_000, usec % 1_000_000,
                 ethernet_frame(packet, camera_id))
            )

    positive_path = output_root / "golden_dual_camera_480rows.pcap"
    write_pcap(positive_path, records)

    bad_packet = build_camera_row(
        cam_id=0,
        frame_id=999,
        row_idx=0,
        row_flags=0,
        row_seq=0,
        payload=image_row(0, 0),
        fpga_status=0,
        corrupt_crc=True,
    )
    negative_path = output_root / "golden_crc_error_single_packet.pcap"
    write_pcap(
        negative_path,
        [(base_seconds, 0, ethernet_frame(bad_packet, 0))],
    )

    expected = {
        "schema_version": 1,
        "fixture_kind": "synthetic_public_regression",
        "fixture_timestamp_utc": "2023-11-14T22:13:20Z",
        "generator": "scripts_py/generate_golden_host_fixture.py",
        "host_repository_commit": git_head(host_repo),
        "wire_contract": {
            "ether_type": "0x88B5",
            "packet_bytes": 128,
            "ethernet_frame_bytes_without_fcs": 142,
            "sync_bytes": "A5 A0 5A 50",
            "metadata_byte_order": "big_endian",
            "pixel_bit_order": "msb_first",
            "crc": "CRC-16/CCITT-FALSE over payload offsets 0..125",
        },
        "positive_fixture": {
            "file": positive_path.name,
            "sha256": sha256(positive_path),
            "packet_count": len(records),
            "matching_ethernet": len(records),
            "valid_packets": len(records),
            "bad_packets": 0,
            "crc_errors": 0,
            "camera_ids": [0, 1],
            "packets_per_camera": EXPECTED_ROWS,
            "complete_frames_per_camera": 1,
            "frame_ids": {"cam0": 100, "cam1": 101},
            "image_shape": [EXPECTED_ROWS, IMAGE_WIDTH],
            "first_row_crc": first_crc,
            "last_row_crc": last_crc,
        },
        "negative_fixture": {
            "file": negative_path.name,
            "sha256": sha256(negative_path),
            "packet_count": 1,
            "expected_first_error": "crc_error",
            "valid_packets": 0,
            "bad_packets": 1,
            "crc_errors": 1,
        },
        "limitations": [
            "Synthetic evidence validates Host parsing and reassembly only.",
            "It does not validate MCU GPIO, FPGA capture, RMII, PHY, NIC, or Npcap.",
            "A physical cold-start run remains an independent acceptance step.",
        ],
    }
    expected_path = output_root / "expected_results.json"
    expected_path.write_text(
        json.dumps(expected, indent=2) + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
