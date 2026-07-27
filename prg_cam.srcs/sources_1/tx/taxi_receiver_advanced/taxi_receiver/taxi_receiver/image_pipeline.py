"""Numbered camera-image publication and per-row CSV telemetry.

This is a project-side Layer-5 sink.  It does not alter the 128-byte wire
format or TAXI.  Parsed rows are appended to ``images/camN/rows.csv`` as they
arrive.  A row whose raw flags satisfy ``flags & 0x02 == 0x02`` terminates the
human-readable CSV group with one blank line.

Only a fully reassembled frame is published as an image.  The current payload
is an 80-byte packed threshold row (640 one-bit pixels), so the dependency-free
image format is binary PGM (P5), with the numeric ``frame_id`` as its stem.
"""
from __future__ import annotations

import csv
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import threading
import time
from typing import TextIO
import uuid

from .packet_format import (
    FLAG_FIRST_ROW,
    FLAG_FRAME_OVERFLOW,
    FLAG_LAST_ROW,
    FLAG_LENGTH_ERROR,
    ROW_BYTES,
    SYNC0_DEFAULT,
    SYNC1_DEFAULT,
)
from .reassembler import CompletedFrame, FrameStatus
from .stages import FrameContext
from .threshold_recover import (
    BitOrder,
    MissingRowPolicy,
    recover_completed_frame,
)


ROW_CSV_FIELDS = (
    "timestamp",
    "cam_id",
    "frame_id",
    "row_idx",
    "row_seq",
    "row_flags",
    "first_row",
    "last_row",
    "frame_overflow",
    "length_error",
    "frame_end",
    "sync0",
    "sync1",
    "sync_ok",
    "payload_len",
    "payload_len_ok",
    "crc_ok",
    "received_crc",
    "calculated_crc",
    "trailer_pad_zero",
    "m00",
    "xc_q4",
    "yc_q4",
    "x",
    "y",
    "vx_q8",
    "vy_q8",
    "vx",
    "vy",
    "parse_ok",
    "errors",
    "warnings",
)


@dataclass
class _CsvSink:
    handle: TextIO
    writer: csv.DictWriter
    pending_rows: int = 0
    last_flush: float = 0.0


@dataclass
class ImagePublicationStatistics:
    completed_frames_seen: int = 0
    noncomplete_frames_skipped: int = 0
    recovery_failures: int = 0
    raw_write_attempts: int = 0
    raw_write_success: int = 0
    raw_write_failures: int = 0
    pgm_write_attempts: int = 0
    pgm_write_success: int = 0
    pgm_write_failures: int = 0


class CameraImagePipeline:
    """Publish ``camN/<frame_id>.pgm`` and append ``camN/rows.csv``."""

    def __init__(
        self,
        images_root: str | Path,
        *,
        expected_rows: int = 480,
        bit_order: BitOrder | str = BitOrder.MSB_FIRST,
        precreate_cameras: tuple[int, ...] = (0, 1),
        csv_flush_rows: int = 256,
        csv_flush_seconds: float = 0.5,
    ) -> None:
        if expected_rows <= 0:
            raise ValueError("expected_rows must be positive")
        if csv_flush_rows <= 0:
            raise ValueError("csv_flush_rows must be positive")
        if csv_flush_seconds <= 0:
            raise ValueError("csv_flush_seconds must be positive")
        self.images_root = Path(images_root)
        self.expected_rows = expected_rows
        self.bit_order = BitOrder(bit_order)
        self.csv_flush_rows = csv_flush_rows
        self.csv_flush_seconds = csv_flush_seconds
        self.images_root.mkdir(parents=True, exist_ok=True)
        for cam_id in precreate_cameras:
            self._camera_dir(cam_id).mkdir(parents=True, exist_ok=True)
        self._csv_lock = threading.Lock()
        self._csv_sinks: dict[int, _CsvSink] = {}
        self.stats = ImagePublicationStatistics()

    def record_packet(self, ctx: FrameContext) -> None:
        """Append one parsed Camera packet to its camera CSV.

        Packets with CRC/flag validation errors are intentionally retained as
        evidence.  Ethernet frames that could not be parsed into a complete
        128-byte Camera packet have no trustworthy cam_id and cannot be routed
        into a camN file.
        """

        result = ctx.camera_result
        if result is None or result.packet is None:
            return
        packet = result.packet
        header = packet.header
        trailer = packet.trailer
        flags = header.row_flags
        frame_end = (flags & FLAG_LAST_ROW) == FLAG_LAST_ROW

        row = {
            "timestamp": f"{ctx.frame.timestamp:.9f}",
            "cam_id": header.cam_id,
            "frame_id": header.frame_id,
            "row_idx": header.row_idx,
            "row_seq": header.row_seq,
            "row_flags": f"0x{flags:02X}",
            "first_row": int(bool(flags & FLAG_FIRST_ROW)),
            "last_row": int(bool(flags & FLAG_LAST_ROW)),
            "frame_overflow": int(bool(flags & FLAG_FRAME_OVERFLOW)),
            "length_error": int(bool(flags & FLAG_LENGTH_ERROR)),
            "frame_end": int(frame_end),
            "sync0": f"0x{header.sync0:04X}",
            "sync1": f"0x{header.sync1:04X}",
            "sync_ok": int(
                header.sync0 == SYNC0_DEFAULT
                and header.sync1 == SYNC1_DEFAULT
            ),
            "payload_len": header.payload_len,
            "payload_len_ok": int(0 < header.payload_len <= ROW_BYTES),
            "crc_ok": int(packet.crc_ok),
            "received_crc": f"0x{packet.received_crc:04X}",
            "calculated_crc": f"0x{packet.calculated_crc:04X}",
            "trailer_pad_zero": int(not any(trailer.pad)),
            "m00": trailer.m00,
            "xc_q4": trailer.xc_q4,
            "yc_q4": trailer.yc_q4,
            "x": f"{trailer.xc_q4 / 16.0:.4f}",
            "y": f"{trailer.yc_q4 / 16.0:.4f}",
            "vx_q8": trailer.vx_q8,
            "vy_q8": trailer.vy_q8,
            "vx": f"{trailer.vx_q8 / 256.0:.6f}",
            "vy": f"{trailer.vy_q8 / 256.0:.6f}",
            "parse_ok": int(result.ok),
            "errors": ";".join(result.errors),
            "warnings": ";".join(result.warnings),
        }

        csv_path = self._camera_dir(header.cam_id) / "rows.csv"
        with self._csv_lock:
            sink = self._csv_sink(header.cam_id, csv_path)
            sink.writer.writerow(row)
            if frame_end:
                # An actual blank line, not a comma-filled empty CSV record.
                sink.handle.write("\n")
            sink.pending_rows += 1
            now = time.monotonic()
            if (
                frame_end
                or sink.pending_rows >= self.csv_flush_rows
                or now - sink.last_flush >= self.csv_flush_seconds
            ):
                self._flush_sink(sink, now)

    def close(self) -> None:
        """Flush and close all per-camera CSV files."""
        with self._csv_lock:
            for sink in self._csv_sinks.values():
                sink.handle.flush()
                sink.handle.close()
            self._csv_sinks.clear()

    def archive_frame(self, frame: CompletedFrame) -> Path | None:
        """Publish one complete frame as numeric-stem PGM/RAW/JSON files.

        PARTIAL, CORRUPT, and TIMEOUT frames remain represented by the row CSV
        and, when configured, the existing StorageAndPipeline evidence
        archive.  They are not mislabeled as usable photographs.
        """

        if frame.status is not FrameStatus.COMPLETE:
            self.stats.noncomplete_frames_skipped += 1
            return None

        self.stats.completed_frames_seen += 1
        try:
            recovered = recover_completed_frame(
                frame,
                self.expected_rows,
                bit_order=self.bit_order,
                missing_policy=MissingRowPolicy.REJECT,
            )
        except Exception:
            self.stats.recovery_failures += 1
            raise
        camera_dir = self._camera_dir(frame.camera_id)
        camera_dir.mkdir(parents=True, exist_ok=True)
        stem = str(frame.frame_id)
        pgm_path = camera_dir / f"{stem}.pgm"
        raw_path = camera_dir / f"{stem}.raw"
        metadata_path = camera_dir / f"{stem}.json"

        targets = (pgm_path, raw_path, metadata_path)
        existing = [str(path) for path in targets if path.exists()]
        if existing:
            raise FileExistsError(
                "refusing to overwrite numbered image artifact(s): "
                + ", ".join(existing)
            )

        pgm = (
            f"P5\n{recovered.width} {recovered.height}\n255\n".encode("ascii")
            + recovered.pixels
        )
        metadata = {
            "cam_id": frame.camera_id,
            "frame_id": frame.frame_id,
            "status": frame.status.value,
            "close_reason": frame.close_reason,
            "width": recovered.width,
            "height": recovered.height,
            "pixel_format": "threshold_u8_0_255",
            "wire_row_format": f"{ROW_BYTES}_byte_packed_1bpp",
            "bit_order": recovered.bit_order.value,
            "row_count": frame.row_count,
            "expected_rows": frame.expected_rows,
            "missing_rows": frame.missing_rows,
            "had_overflow": frame.had_overflow,
            "pixels_sha256": hashlib.sha256(recovered.pixels).hexdigest(),
            "pgm_file": pgm_path.name,
            "raw_file": raw_path.name,
            "row_csv": "rows.csv",
        }

        # Each visible file appears only after its complete temporary file has
        # been closed.  Existing numbered frames are never silently replaced.
        self.stats.pgm_write_attempts += 1
        try:
            self._atomic_create(pgm_path, pgm)
        except Exception:
            self.stats.pgm_write_failures += 1
            raise
        else:
            self.stats.pgm_write_success += 1

        self.stats.raw_write_attempts += 1
        try:
            self._atomic_create(raw_path, recovered.pixels)
        except Exception:
            self.stats.raw_write_failures += 1
            raise
        else:
            self.stats.raw_write_success += 1
        self._atomic_create(
            metadata_path,
            (json.dumps(metadata, indent=2, sort_keys=True) + "\n").encode(
                "utf-8"
            ),
        )
        return pgm_path

    def report_lines(self) -> tuple[str, ...]:
        """Return stable final-report lines without coupling this sink to CLI."""

        return (
            "IMAGE PUBLICATION",
            f"  complete frames seen: {self.stats.completed_frames_seen}",
            f"  noncomplete skipped : {self.stats.noncomplete_frames_skipped}",
            f"  recovery failures   : {self.stats.recovery_failures}",
            f"  RAW attempts/success/fail: "
            f"{self.stats.raw_write_attempts}/"
            f"{self.stats.raw_write_success}/"
            f"{self.stats.raw_write_failures}",
            f"  PGM attempts/success/fail: "
            f"{self.stats.pgm_write_attempts}/"
            f"{self.stats.pgm_write_success}/"
            f"{self.stats.pgm_write_failures}",
            f"  resolved images root: {self.images_root.resolve()}",
        )

    def _camera_dir(self, cam_id: int) -> Path:
        if cam_id < 0:
            raise ValueError(f"cam_id must be non-negative, got {cam_id}")
        return self.images_root / f"cam{cam_id}"

    def _csv_sink(self, cam_id: int, path: Path) -> _CsvSink:
        existing_sink = self._csv_sinks.get(cam_id)
        if existing_sink is not None:
            return existing_sink

        path.parent.mkdir(parents=True, exist_ok=True)
        has_content = path.exists() and path.stat().st_size > 0
        if has_content:
            with path.open(newline="", encoding="utf-8") as check:
                header = next(csv.reader(check), [])
            if tuple(header) != ROW_CSV_FIELDS:
                raise ValueError(
                    f"existing CSV schema does not match current receiver: {path}"
                )

        handle = path.open("a", newline="", encoding="utf-8")
        writer = csv.DictWriter(handle, fieldnames=ROW_CSV_FIELDS)
        if not has_content:
            writer.writeheader()
            handle.flush()
        sink = _CsvSink(
            handle=handle,
            writer=writer,
            last_flush=time.monotonic(),
        )
        self._csv_sinks[cam_id] = sink
        return sink

    @staticmethod
    def _flush_sink(sink: _CsvSink, now: float) -> None:
        sink.handle.flush()
        sink.pending_rows = 0
        sink.last_flush = now

    @staticmethod
    def _atomic_create(path: Path, data: bytes) -> None:
        temp = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
        try:
            with temp.open("xb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            if path.exists():
                raise FileExistsError(f"refusing to overwrite: {path}")
            os.replace(temp, path)
        finally:
            if temp.exists():
                temp.unlink()
