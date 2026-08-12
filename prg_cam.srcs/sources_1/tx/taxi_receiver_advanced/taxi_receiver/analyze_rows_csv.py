"""Stream rows_v2.csv (or a named legacy CSV) without pandas."""
from __future__ import annotations

import argparse
import collections
import csv
import json
from pathlib import Path

from taxi_receiver.packet_format import (
    FLAG_FRAME_OVERFLOW,
    FLAG_LAST_ROW,
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("csv_path", type=Path)
    parser.add_argument("--expected-rows", type=int, default=480)
    args = parser.parse_args()

    flag_counts: collections.Counter[int] = collections.Counter()
    error_counts: collections.Counter[str] = collections.Counter()
    sessions: dict[tuple[int, int], dict[str, object]] = {}
    row_count = 0

    with args.csv_path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(row for row in handle if row.strip())
        for row in reader:
            row_count += 1
            flags = int(
                row.get("sender_row_flags_raw")
                or row.get("row_flags", "0"),
                16,
            )
            flag_counts[flags] += 1
            error_counts[row["errors"] or "<none>"] += 1

            key = (int(row["cam_id"]), int(row["frame_id"]))
            session = sessions.setdefault(
                key,
                {
                    "rows": set(),
                    "bad": 0,
                    "first": 0,
                    "last": 0,
                    "overflow": 0,
                },
            )
            session["rows"].add(int(row["row_idx"]))
            recorded_errors = [
                value for value in row["errors"].split(";") if value
            ]
            corrected_errors = list(recorded_errors)
            if flags & FLAG_FRAME_OVERFLOW:
                corrected_errors.append("sender_overflow")
            session["bad"] += bool(corrected_errors)
            session["first"] += int(row["row_idx"]) == 0
            session["last"] += bool(flags & FLAG_LAST_ROW)
            session["overflow"] += bool(flags & FLAG_FRAME_OVERFLOW)

    expected = set(range(args.expected_rows))
    complete = [
        {"cam_id": key[0], "frame_id": key[1]}
        for key, session in sessions.items()
        if session["rows"] == expected
        and session["bad"] == 0
        and session["last"]
        and not session["overflow"]
    ]
    result = {
        "csv": str(args.csv_path.resolve()),
        "rows": row_count,
        "sessions": len(sessions),
        "strict_complete_sessions": len(complete),
        "first_complete_sessions": complete[:20],
        "flag_counts": {
            f"0x{flag:02X}": count for flag, count in flag_counts.most_common()
        },
        "error_counts": dict(error_counts.most_common()),
    }
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
