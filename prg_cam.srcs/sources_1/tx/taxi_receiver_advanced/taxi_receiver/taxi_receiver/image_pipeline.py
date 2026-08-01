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
from collections import Counter
from dataclasses import dataclass
from enum import Enum
import hashlib
import json
import os
from pathlib import Path
import threading
import time
from typing import Callable, TextIO
import uuid

from .packet_format import (
    FLAG_FIRST_ROW,
    FLAG_LAST_ROW,
    ROW_BYTES,
    SYNC0_DEFAULT,
    SYNC1_DEFAULT,
)
from .reassembler import CompletedFrame, FrameStatus
from .stages import FrameContext
from .threshold_recover import (
    BitOrder,
    MissingRowPolicy,
    ROW_PIXELS,
    recover_completed_frame,
)


ROW_CSV_FIELDS = (
    "timestamp",
    "cam_id",
    "frame_id",
    "row_idx",
    "row_seq",
    "row_flags",
    "fpga_status",
    "header_check",
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
    images_complete: int = 0
    images_recovered: int = 0
    images_rejected: int = 0
    rows_zero_filled: int = 0
    reject_reasons: Counter[str] | None = None

    def __post_init__(self) -> None:
        if self.reject_reasons is None:
            self.reject_reasons = Counter()


class ImagePolicy(str, Enum):
    """Layer-5 image publication policy; Layer1-3 remain unchanged."""

    STRICT = "strict"
    RECOVER_ZERO_FILL = "recover-zero-fill"


@dataclass(frozen=True)
class RecoveryDecision:
    eligible: bool
    reject_reasons: tuple[str, ...]
    missing_rows: tuple[int, ...]
    max_consecutive_missing: int
    wire_row_bytes: int
    row_bytes: int


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
        image_policy: ImagePolicy | str = ImagePolicy.STRICT,
        max_missing_rows: int = 4,
        max_consecutive_missing: int = 2,
        report_interval: float = 1.0,
        report_sink: Callable[[str], None] = print,
    ) -> None:
        if expected_rows <= 0:
            raise ValueError("expected_rows must be positive")
        if csv_flush_rows <= 0:
            raise ValueError("csv_flush_rows must be positive")
        if csv_flush_seconds <= 0:
            raise ValueError("csv_flush_seconds must be positive")
        if max_missing_rows < 0:
            raise ValueError("max_missing_rows must be non-negative")
        if max_consecutive_missing < 1:
            raise ValueError("max_consecutive_missing must be positive")
        if report_interval <= 0:
            raise ValueError("report_interval must be positive")
        self.images_root = Path(images_root)
        self.expected_rows = expected_rows
        self.bit_order = BitOrder(bit_order)
        self.image_policy = ImagePolicy(image_policy)
        self.max_missing_rows = max_missing_rows
        # This is deliberately an exclusive reject threshold: the requested
        # CLI value 2 rejects a run of two missing rows and therefore permits
        # at most one consecutive missing row.
        self.max_consecutive_missing = max_consecutive_missing
        self.report_interval = report_interval
        self.report_sink = report_sink
        self.csv_flush_rows = csv_flush_rows
        self.csv_flush_seconds = csv_flush_seconds
        self.images_root.mkdir(parents=True, exist_ok=True)
        for cam_id in precreate_cameras:
            self._camera_dir(cam_id).mkdir(parents=True, exist_ok=True)
        self._csv_lock = threading.Lock()
        self._csv_sinks: dict[int, _CsvSink] = {}
        self.stats = ImagePublicationStatistics()
        self._rate_started = time.monotonic()
        self._rate_last = self._rate_started
        self._rate_last_counts = (0, 0, 0)

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
            "fpga_status": f"0x{header.fpga_status:02X}",
            "header_check": f"0x{header.header_check:02X}",
            "frame_overflow": int(packet.frame_overflow),
            "length_error": int(packet.length_error),
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
        """Publish a COMPLETE image or an explicitly eligible RECOVERED image."""

        decision: RecoveryDecision | None = None
        if frame.status is FrameStatus.COMPLETE:
            self.stats.completed_frames_seen += 1
            output_status = "COMPLETE"
            missing_policy = MissingRowPolicy.REJECT
        elif self.image_policy is ImagePolicy.RECOVER_ZERO_FILL:
            self.stats.noncomplete_frames_skipped += 1
            decision = self._assess_recovery(frame)
            if not decision.eligible:
                self._record_rejection(frame, decision)
                return None
            output_status = "RECOVERED"
            missing_policy = MissingRowPolicy.ZERO_FILL
        else:
            self.stats.noncomplete_frames_skipped += 1
            # Preserve strict mode's pre-change disk behavior: incomplete
            # frames produce no image-side artifact.  They are counted for
            # truthful rate reporting but rejected.csv is recovery-mode
            # evidence only.
            self.stats.images_rejected += 1
            assert self.stats.reject_reasons is not None
            self.stats.reject_reasons["strict_requires_complete"] += 1
            self._maybe_report_rates()
            return None

        try:
            recovered = recover_completed_frame(
                frame,
                self.expected_rows,
                bit_order=self.bit_order,
                missing_policy=missing_policy,
            )
        except Exception:
            self.stats.recovery_failures += 1
            raise

        required_height = (
            480 if output_status == "RECOVERED" else self.expected_rows
        )
        if (
            recovered.height != required_height
            or recovered.width != ROW_PIXELS
            or len(recovered.pixels) != required_height * ROW_PIXELS
        ):
            raise ValueError(
                "image geometry mismatch after publication recovery: "
                f"{recovered.width}x{recovered.height}, "
                f"{len(recovered.pixels)} bytes"
            )

        camera_dir = self._camera_dir(frame.camera_id)
        if output_status == "RECOVERED":
            artifact_dir = (
                camera_dir / "recovered" / f"frame_{frame.frame_id}"
            )
            artifact_dir.mkdir(parents=True, exist_ok=True)
            pgm_path = artifact_dir / "image.pgm"
            raw_path = artifact_dir / "image.raw"
            metadata_path = artifact_dir / "metadata.json"
            row_csv_ref = "../../rows.csv"
        else:
            camera_dir.mkdir(parents=True, exist_ok=True)
            stem = str(frame.frame_id)
            pgm_path = camera_dir / f"{stem}.pgm"
            raw_path = camera_dir / f"{stem}.raw"
            metadata_path = camera_dir / f"{stem}.json"
            row_csv_ref = "rows.csv"

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
            "status": output_status,
            "close_reason": frame.close_reason,
            "width": recovered.width,
            "height": recovered.height,
            "pixel_format": "threshold_u8_0_255",
            "wire_row_format": f"{ROW_BYTES}_byte_packed_1bpp",
            "bit_order": recovered.bit_order.value,
            "row_count": frame.row_count,
            "expected_rows": required_height,
            "missing_rows": (
                list(decision.missing_rows) if decision is not None else []
            ),
            "missing_count": (
                len(decision.missing_rows) if decision is not None else 0
            ),
            "max_consecutive_missing": (
                decision.max_consecutive_missing if decision is not None else 0
            ),
            "fill_policy": "zero" if decision is not None else "none",
            "row_bytes": recovered.width,
            "wire_row_bytes": ROW_BYTES,
            "had_overflow": frame.had_overflow,
            "had_crc_error": False,
            "had_sync_error": False,
            "had_conflicting_duplicate": False,
            "pixels_sha256": hashlib.sha256(recovered.pixels).hexdigest(),
            "pgm_file": pgm_path.name,
            "raw_file": raw_path.name,
            "row_csv": row_csv_ref,
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
        if output_status == "RECOVERED":
            assert decision is not None
            self.stats.images_recovered += 1
            self.stats.rows_zero_filled += len(decision.missing_rows)
        else:
            self.stats.images_complete += 1
        self._maybe_report_rates()
        return pgm_path

    def _assess_recovery(self, frame: CompletedFrame) -> RecoveryDecision:
        """Apply the opt-in recovery gate without relaxing packet validation."""

        reasons: list[str] = []
        if self.expected_rows != 480 or frame.expected_rows != 480:
            reasons.append("expected_rows_not_480")
        if not 0 <= frame.frame_id <= 0xFFFF:
            reasons.append("frame_id_out_of_range")

        accepted_records = [
            record for record in frame.packet_records if record.accepted
        ]
        reliable_last = any(
            record.row_idx == 479
            and bool(record.row_flags & FLAG_LAST_ROW)
            for record in accepted_records
        )
        if not reliable_last:
            reasons.append("reliable_last_row_not_seen")

        all_errors = {
            error
            for record in frame.packet_records
            for error in record.errors
        }
        if frame.had_overflow or "frame_overflow" in all_errors:
            reasons.append("overflow")
        if "bad_sync" in all_errors:
            reasons.append("bad_sync")
        if "crc_error" in all_errors:
            reasons.append("crc_error")
        if frame.conflicting_duplicates or any(
            record.conflicting_duplicate for record in frame.packet_records
        ):
            reasons.append("conflicting_duplicate")

        # Length-invalid rows may account for a missing row, but their payload
        # is never used.  Any other Layer-3 error is a hard recovery rejection.
        permitted_missing_row_errors = {
            "length_error",
            "payload_len_out_of_range",
        }
        unhandled_errors = sorted(all_errors - permitted_missing_row_errors - {
            "frame_overflow",
            "bad_sync",
            "crc_error",
        })
        reasons.extend(f"layer3_error:{error}" for error in unhandled_errors)

        valid_row_indices = set(frame.rows)
        accepted_row_indices = {record.row_idx for record in accepted_records}
        if any(index < 0 or index >= 480 for index in valid_row_indices):
            reasons.append("row_idx_out_of_range")
        if any(index < 0 or index >= 480 for index in accepted_row_indices):
            reasons.append("row_idx_out_of_range")

        valid_in_range = {
            index for index in valid_row_indices if 0 <= index < 480
        }
        expected = set(range(480))
        missing_rows = tuple(sorted(expected - valid_in_range))
        max_consecutive = self._max_consecutive(missing_rows)
        if not missing_rows:
            reasons.append("no_missing_rows_to_recover")
        if len(missing_rows) > self.max_missing_rows:
            reasons.append("too_many_missing_rows")
        if max_consecutive >= self.max_consecutive_missing:
            reasons.append("consecutive_missing_rows")

        row_lengths = {len(frame.rows[index]) for index in valid_in_range}
        if not row_lengths:
            reasons.append("no_valid_rows")
        elif row_lengths != {ROW_BYTES}:
            reasons.append("row_byte_length_mismatch")

        if self.bit_order not in (BitOrder.MSB_FIRST, BitOrder.LSB_FIRST):
            reasons.append("unsupported_pixel_format")

        # The accepted row sequence must advance by exactly the row-index gap.
        # This admits known missing rows and natural 16-bit wrap, but rejects a
        # jump that cannot be explained by either condition.
        records_by_row = {
            record.row_idx: record
            for record in accepted_records
            if 0 <= record.row_idx < 480
        }
        ordered = sorted(records_by_row.items())
        for (previous_idx, previous), (current_idx, current) in zip(
            ordered, ordered[1:]
        ):
            row_gap = current_idx - previous_idx
            sequence_gap = (current.row_seq - previous.row_seq) & 0xFFFF
            if sequence_gap != row_gap:
                reasons.append("row_seq_discontinuity")
                break

        return RecoveryDecision(
            eligible=not reasons,
            reject_reasons=tuple(dict.fromkeys(reasons)),
            missing_rows=missing_rows,
            max_consecutive_missing=max_consecutive,
            wire_row_bytes=ROW_BYTES,
            row_bytes=ROW_PIXELS,
        )

    @staticmethod
    def _max_consecutive(rows: tuple[int, ...]) -> int:
        longest = 0
        current = 0
        previous: int | None = None
        for row in rows:
            current = current + 1 if previous is not None and row == previous + 1 else 1
            longest = max(longest, current)
            previous = row
        return longest

    def _record_rejection(
        self,
        frame: CompletedFrame,
        decision: RecoveryDecision,
    ) -> None:
        self.stats.images_rejected += 1
        assert self.stats.reject_reasons is not None
        for reason in decision.reject_reasons:
            self.stats.reject_reasons[reason] += 1

        camera_dir = self._camera_dir(frame.camera_id)
        camera_dir.mkdir(parents=True, exist_ok=True)
        path = camera_dir / "rejected.csv"
        exists = path.exists() and path.stat().st_size > 0
        with path.open("a", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            if not exists:
                writer.writerow(
                    (
                        "timestamp",
                        "cam_id",
                        "frame_id",
                        "publication_status",
                        "frame_status",
                        "close_reason",
                        "reject_reason",
                        "missing_count",
                        "missing_rows",
                        "max_consecutive_missing",
                    )
                )
            writer.writerow(
                (
                    f"{time.time():.9f}",
                    frame.camera_id,
                    frame.frame_id,
                    "REJECTED",
                    frame.status.value,
                    frame.close_reason,
                    ";".join(decision.reject_reasons),
                    len(decision.missing_rows),
                    " ".join(str(row) for row in decision.missing_rows),
                    decision.max_consecutive_missing,
                )
            )
        self._maybe_report_rates()

    def _maybe_report_rates(self, *, force: bool = False) -> None:
        now = time.monotonic()
        elapsed = now - self._rate_last
        if not force and elapsed < self.report_interval:
            return
        counts = (
            self.stats.images_complete,
            self.stats.images_recovered,
            self.stats.images_rejected,
        )
        if elapsed <= 0:
            return
        deltas = tuple(
            current - previous
            for current, previous in zip(counts, self._rate_last_counts)
        )
        self.report_sink(
            "[IMAGE RATE] "
            f"complete_fps={deltas[0] / elapsed:.3f} "
            f"recovered_fps={deltas[1] / elapsed:.3f} "
            f"rejected_fps={deltas[2] / elapsed:.3f} "
            f"total_usable_fps={(deltas[0] + deltas[1]) / elapsed:.3f}"
        )
        self._rate_last = now
        self._rate_last_counts = counts

    def report_lines(self) -> tuple[str, ...]:
        """Return stable final-report lines without coupling this sink to CLI."""

        elapsed = max(time.monotonic() - self._rate_started, 1e-9)
        reject_summary = (
            ", ".join(
                f"{reason}={count}"
                for reason, count in sorted(
                    (self.stats.reject_reasons or {}).items()
                )
            )
            or "none"
        )
        return (
            "IMAGE PUBLICATION",
            f"  image policy        : {self.image_policy.value}",
            f"  complete frames seen: {self.stats.completed_frames_seen}",
            f"  noncomplete skipped : {self.stats.noncomplete_frames_skipped}",
            f"  recovery failures   : {self.stats.recovery_failures}",
            f"  images complete     : {self.stats.images_complete}",
            f"  images recovered    : {self.stats.images_recovered}",
            f"  images rejected     : {self.stats.images_rejected}",
            f"  rows zero-filled    : {self.stats.rows_zero_filled}",
            f"  complete_fps        : "
            f"{self.stats.images_complete / elapsed:.3f}",
            f"  recovered_fps       : "
            f"{self.stats.images_recovered / elapsed:.3f}",
            f"  total_usable_fps    : "
            f"{(self.stats.images_complete + self.stats.images_recovered) / elapsed:.3f}",
            f"  reject reasons      : {reject_summary}",
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
