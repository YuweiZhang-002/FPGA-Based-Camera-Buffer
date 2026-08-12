"""Directed parser/monitor/reassembler/audit ownership regression."""
from __future__ import annotations

import csv

from taxi_receiver.camera_parser import parse_camera_mode
from taxi_receiver.packet_format import FLAG_LAST_ROW, ROW_BYTES, build_camera_row
from taxi_receiver.reassembler import FrameReassembler
from taxi_receiver.session_audit import SessionAuditLogger
from taxi_receiver.stages import FrameContext
from taxi_receiver.stream_monitor import StreamMonitor

from .synthetic import make_raw_frame


def test_duplicate_and_missing_rows_stay_layered_and_auditable(tmp_path):
    """Sequence 0,1,1,3,...,479 has one duplicate and missing row 2."""

    monitor = StreamMonitor(report_interval=999, sink=lambda *_: None)
    reassembler = FrameReassembler(expected_rows=480)
    audit = SessionAuditLogger(tmp_path)
    row_indices = [0, 1, 1, *range(3, 480)]

    for packet_index, row_idx in enumerate(row_indices):
        raw = build_camera_row(
            cam_id=0,
            frame_id=17,
            row_idx=row_idx,
            row_flags=FLAG_LAST_ROW if row_idx == 479 else 0,
            row_seq=packet_index,
            payload=bytes([row_idx & 0xFF]) * ROW_BYTES,
        )
        result = parse_camera_mode(raw)

        # Parser owns static protocol only; sequence history cannot change it.
        assert result.parsed_ok and result.ok
        monitor.record_camera_result(result)
        reassembler.on_row(
            result.packet,
            errors=result.errors,
            warnings=result.warnings,
            capture_timestamp=float(packet_index),
            now=float(packet_index),
        )
        ctx = FrameContext(
            frame=make_raw_frame(raw, timestamp=float(packet_index)),
            mode="camera",
            camera_result=result,
            packet_record=reassembler.last_packet_record,
        )
        audit(ctx)

    audit.close()
    completed = reassembler.flush()
    assert len(completed) == 1
    frame = completed[0]
    assert frame.duplicate_packets == 1
    assert frame.missing_rows == [2]

    camera = monitor.stats.camera(0)
    assert camera.duplicate_rows == 1
    assert camera.row_jumps == 1
    assert camera.missing_rows == 1

    with (tmp_path / "session_audit_v2.csv").open(
        newline="", encoding="utf-8"
    ) as handle:
        rows = list(csv.DictReader(handle))
    duplicate_rows = [row for row in rows if row["row_idx"] == "1"]
    assert [row["row_accepted"] for row in duplicate_rows] == ["1", "0"]
    assert [row["reject_reason"] for row in duplicate_rows] == [
        "", "duplicate_row"
    ]
