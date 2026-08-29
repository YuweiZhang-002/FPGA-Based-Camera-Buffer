#!/usr/bin/env python3
"""Stream-audit per-camera rows_v2.csv files from a dual-camera capture."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
import sys


def _bad(row: dict[str, str], field: str, expected: str) -> int:
    return int(row.get(field, "") != expected)


def audit_camera(root: Path, camera_id: int) -> dict[str, object]:
    camera_root = root / f"cam{camera_id}"
    rows_path = camera_root / "rows_v2.csv"
    if not rows_path.is_file():
        raise FileNotFoundError(f"CAM{camera_id} rows_v2.csv missing: {rows_path}")

    counters = {
        "wrong_camera_id": 0,
        "wrong_crc_mode": 0,
        "crc_not_checked": 0,
        "egress_crc_failures": 0,
        "ingress_crc_failures": 0,
        "sync_failures": 0,
        "payload_length_failures": 0,
        "fpga_length_failures": 0,
        "parse_failures": 0,
        "rows_not_accepted": 0,
    }
    total_rows = 0
    frame_ids: set[str] = set()
    with rows_path.open("r", encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            total_rows += 1
            frame_ids.add(row.get("frame_id", ""))
            counters["wrong_camera_id"] += _bad(row, "cam_id", str(camera_id))
            counters["wrong_crc_mode"] += _bad(row, "crc_mode", "enabled")
            counters["crc_not_checked"] += _bad(row, "crc_checked", "1")
            counters["egress_crc_failures"] += _bad(row, "crc_ok", "1")
            counters["ingress_crc_failures"] += _bad(row, "fpga_crc_error", "0")
            counters["sync_failures"] += _bad(row, "sync_ok", "1")
            counters["payload_length_failures"] += _bad(row, "payload_len_ok", "1")
            counters["fpga_length_failures"] += _bad(row, "fpga_length_error", "0")
            counters["parse_failures"] += _bad(row, "parsed_ok", "1")
            counters["rows_not_accepted"] += _bad(row, "row_accepted", "1")

    result: dict[str, object] = {
        "camera_id": camera_id,
        "rows_csv": str(rows_path),
        "total_rows": total_rows,
        "unique_frame_ids": len(frame_ids),
        "pgm_files": sum(1 for _ in camera_root.glob("*.pgm")),
        "raw_files": sum(1 for _ in camera_root.glob("*.raw")),
        **counters,
    }
    result["pass"] = total_rows > 0 and all(value == 0 for value in counters.values())
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("images_root", type=Path)
    parser.add_argument("--camera-ids", default="0,1")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    try:
        camera_ids = [int(token.strip()) for token in args.camera_ids.split(",")]
        results = [audit_camera(args.images_root, camera_id) for camera_id in camera_ids]
    except (FileNotFoundError, ValueError) as exc:
        print(f"CRC audit failed: {exc}", file=sys.stderr)
        return 2

    for result in results:
        print(
            f"CAM{result['camera_id']}: {'PASS' if result['pass'] else 'FAIL'}  "
            f"rows={result['total_rows']} frames={result['unique_frame_ids']} "
            f"PGM={result['pgm_files']} egress_crc={result['egress_crc_failures']} "
            f"ingress_crc={result['ingress_crc_failures']}"
        )
        failures = {
            key: value
            for key, value in result.items()
            if key.endswith("failures") or key in {
                "wrong_camera_id", "wrong_crc_mode", "crc_not_checked",
                "rows_not_accepted",
            }
        }
        if any(failures.values()):
            print("  " + "  ".join(f"{key}={value}" for key, value in failures.items()))

    payload = {"pass": all(bool(item["pass"]) for item in results), "cameras": results}
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"summary: {args.output}")
    return 0 if payload["pass"] else 3


if __name__ == "__main__":
    raise SystemExit(main())
