"""Atomic Layer-5 frame archive for :mod:`taxi_receiver.reassembler`.

One completed session is written into a temporary sibling directory and
renamed only after every required file is closed.  Unknown image geometry
is represented honestly as ``image.raw`` plus metadata; PNG/PGM output is
not created until width, height, and pixel format become protocol facts.
"""
from __future__ import annotations

import csv
import hashlib
import json
import os
from pathlib import Path
import threading
import time
from typing import TextIO
import uuid

from .reassembler import CompletedFrame


SUMMARY_FIELDS = (
    "camera_id",
    "frame_id",
    "status",
    "close_reason",
    "received_packets",
    "accepted_rows",
    "expected_rows",
    "duplicate_packets",
    "conflicting_duplicates",
    "missing_rows",
    "crc_errors",
    "length_errors",
    "overflow_errors",
    "other_errors",
    "warning_count",
    "duration_seconds",
    "output_path",
)


class StorageAndPipeline:
    """Archive callback suitable for ``on_completed_frame``."""

    def __init__(self, output_root: str | Path):
        self.output_root = Path(output_root)
        self.output_root.mkdir(parents=True, exist_ok=True)
        self.summary_path = self.output_root / "summary.csv"
        self._summary_lock = threading.Lock()
        self._summary_handle: TextIO | None = None
        self._summary_writer: csv.DictWriter | None = None

    def archive(self, frame: CompletedFrame) -> Path:
        camera_dir = self.output_root / f"cam_{frame.camera_id}"
        camera_dir.mkdir(parents=True, exist_ok=True)
        final_dir = camera_dir / f"frame_{frame.frame_id}"
        temp_dir = camera_dir / (
            f".frame_{frame.frame_id}.{uuid.uuid4().hex}.tmp"
        )
        raw = frame.to_bytes()
        metadata = self._metadata(frame, raw)

        if final_dir.exists():
            if self._already_archived(final_dir, metadata):
                return final_dir
            raise FileExistsError(
                f"refusing to overwrite archived frame: {final_dir}"
            )

        temp_dir.mkdir()
        (temp_dir / "image.raw").write_bytes(raw)
        (temp_dir / "metadata.json").write_text(
            json.dumps(metadata, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self._write_packets(temp_dir / "packets.csv", frame)
        (temp_dir / "errors.json").write_text(
            json.dumps(frame.errors, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

        # Destination does not exist, so this publishes the complete directory
        # in one filesystem operation.  A process interruption before this line
        # leaves a visibly temporary directory, never a half-valid frame_N.
        _replace_directory_with_retry(temp_dir, final_dir)
        self._append_summary(frame, final_dir)
        return final_dir

    @staticmethod
    def _already_archived(final_dir: Path, metadata: dict[str, object]) -> bool:
        metadata_path = final_dir / "metadata.json"
        if not metadata_path.is_file():
            return False
        try:
            existing = json.loads(metadata_path.read_text(encoding="utf-8"))
        except Exception:
            return False
        return _stable_metadata(existing) == _stable_metadata(metadata)

    def __call__(self, frame: CompletedFrame) -> None:
        self.archive(frame)

    def close(self) -> None:
        with self._summary_lock:
            if self._summary_handle is not None:
                self._summary_handle.flush()
                self._summary_handle.close()
                self._summary_handle = None
                self._summary_writer = None

    @staticmethod
    def _metadata(frame: CompletedFrame, raw: bytes) -> dict[str, object]:
        return {
            "camera_id": frame.camera_id,
            "frame_id": frame.frame_id,
            "status": frame.status.value,
            "close_reason": frame.close_reason,
            "row_count": frame.row_count,
            "expected_rows": frame.expected_rows,
            "received_row_ids": sorted(frame.rows),
            "missing_rows": frame.missing_rows,
            "duplicate_packets": frame.duplicate_packets,
            "conflicting_duplicates": frame.conflicting_duplicates,
            "had_overflow": frame.had_overflow,
            "saw_first": frame.saw_first,
            "saw_last": frame.saw_last,
            "started_at_monotonic": frame.started_at,
            "ended_at_monotonic": frame.ended_at,
            "duration_seconds": max(0.0, frame.ended_at - frame.started_at),
            "raw_size_bytes": len(raw),
            "raw_sha256": hashlib.sha256(raw).hexdigest(),
            "width": None,
            "height": None,
            "pixel_format": None,
            "rendered_image": None,
            "protocol": "legacy-v0-observed",
        }

    @staticmethod
    def _write_packets(path: Path, frame: CompletedFrame) -> None:
        fields = (
            "packet_index",
            "capture_timestamp",
            "row_idx",
            "row_seq",
            "payload_len",
            "row_flags",
            "accepted",
            "duplicate",
            "conflicting_duplicate",
            "errors",
            "warnings",
        )
        with path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields)
            writer.writeheader()
            for record in frame.packet_records:
                writer.writerow(
                    {
                        "packet_index": record.packet_index,
                        "capture_timestamp": f"{record.capture_timestamp:.9f}",
                        "row_idx": record.row_idx,
                        "row_seq": record.row_seq,
                        "payload_len": record.payload_len,
                        "row_flags": f"0x{record.row_flags:02x}",
                        "accepted": int(record.accepted),
                        "duplicate": int(record.duplicate),
                        "conflicting_duplicate": int(
                            record.conflicting_duplicate
                        ),
                        "errors": ";".join(record.errors),
                        "warnings": ";".join(record.warnings),
                    }
                )

    def _append_summary(
        self,
        frame: CompletedFrame,
        output_path: Path,
    ) -> None:
        row = self._summary_row(frame, output_path)
        with self._summary_lock:
            writer = self._get_summary_writer()
            writer.writerow(row)
            assert self._summary_handle is not None
            self._summary_handle.flush()

    def _get_summary_writer(self) -> csv.DictWriter:
        if self._summary_writer is not None:
            return self._summary_writer

        has_content = (
            self.summary_path.exists()
            and self.summary_path.stat().st_size > 0
        )
        if has_content:
            with self.summary_path.open(
                newline="", encoding="utf-8"
            ) as handle:
                header = next(csv.reader(handle), [])
            if tuple(header) != SUMMARY_FIELDS:
                raise ValueError(
                    "existing summary.csv schema does not match current "
                    f"receiver: {self.summary_path}"
                )

        self._summary_handle = self.summary_path.open(
            "a",
            newline="",
            encoding="utf-8",
        )
        self._summary_writer = csv.DictWriter(
            self._summary_handle,
            fieldnames=SUMMARY_FIELDS,
        )
        if not has_content:
            self._summary_writer.writeheader()
            self._summary_handle.flush()
        return self._summary_writer

    @staticmethod
    def _summary_row(
        frame: CompletedFrame,
        output_path: Path,
    ) -> dict[str, object]:
        packet_errors = [
            error
            for record in frame.packet_records
            for error in record.errors
        ]
        known = {"crc_error", "length_error", "frame_overflow"}
        return {
            "camera_id": frame.camera_id,
            "frame_id": frame.frame_id,
            "status": frame.status.value,
            "close_reason": frame.close_reason,
            "received_packets": len(frame.packet_records),
            "accepted_rows": frame.row_count,
            "expected_rows": frame.expected_rows,
            "duplicate_packets": frame.duplicate_packets,
            "conflicting_duplicates": frame.conflicting_duplicates,
            "missing_rows": len(frame.missing_rows),
            "crc_errors": packet_errors.count("crc_error"),
            "length_errors": packet_errors.count("length_error"),
            "overflow_errors": packet_errors.count("frame_overflow"),
            "other_errors": sum(error not in known for error in packet_errors),
            "warning_count": sum(
                len(record.warnings) for record in frame.packet_records
            ),
            "duration_seconds": (
                f"{max(0.0, frame.ended_at - frame.started_at):.9f}"
            ),
            "output_path": str(output_path),
        }


def _replace_directory_with_retry(
    source: Path,
    destination: Path,
    *,
    attempts: int = 8,
    initial_delay: float = 0.02,
) -> None:
    """Publish a closed temporary directory despite transient Windows locks.

    Every file writer used by :class:`StorageAndPipeline` is closed before
    this function runs. Windows Defender/indexers can nevertheless hold a
    short-lived external handle and make ``os.replace`` raise WinError 5/32.
    Retry only those sharing/access failures; all other errors remain fatal.
    """

    delay = initial_delay
    for attempt in range(attempts):
        try:
            os.replace(source, destination)
            return
        except PermissionError as exc:
            retryable = (
                os.name == "nt"
                and getattr(exc, "winerror", None) in (5, 32)
                and attempt + 1 < attempts
            )
            if not retryable:
                raise
            time.sleep(delay)
            delay = min(delay * 2, 0.5)


def _stable_metadata(metadata: dict[str, object]) -> dict[str, object]:
    volatile_keys = {
        "started_at_monotonic",
        "ended_at_monotonic",
        "duration_seconds",
    }
    return {
        key: value
        for key, value in metadata.items()
        if key not in volatile_keys
    }
