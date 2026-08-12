"""Per-packet, session-scoped CSV audit logging.

This module is deliberately a side-band observer.  It consumes the
``FrameContext`` exposed by ``TaxiReceiverPipeline.on_frame_processed`` and
does not alter Layer-3 validation, reassembly, or storage decisions.
"""
from __future__ import annotations

import csv
from pathlib import Path
import threading
import time
from typing import Optional, TextIO

from .stages import FrameContext


AUDIT_FIELDS = (
    "timestamp",
    "cam_id",
    "frame_id",
    "row_idx",
    "sender_row_flags_raw",
    "sender_row2_marker",
    "fpga_status_raw",
    "fpga_length_error",
    "fpga_crc_error",
    "payload_len",
    "row_seq",
    "crc_mode",
    "crc_checked",
    "crc_ok",
    "validation_status",
    "reject_reason",
    "row_accepted",
)

_COUNTER_MAX = 0xFFFF
_WRAP_HIGH = 0xF000
_WRAP_LOW = 0x0FFF


class SessionAuditLogger:
    """Write one CSV row for every processed capture record.

    A large, non-wrap rollback of either frame_id or row_seq is treated as a
    new power-on session.  The CSV is then reopened with ``"w"`` so evidence
    from different board sessions cannot be accidentally merged.
    """

    def __init__(
        self,
        output_root: str | Path,
        *,
        rollback_threshold: int = 1024,
        flush_every_rows: int = 256,
        flush_interval_seconds: float = 0.5,
    ) -> None:
        if not 1 <= rollback_threshold <= _COUNTER_MAX:
            raise ValueError("rollback_threshold must be in 1..65535")
        if flush_every_rows <= 0:
            raise ValueError("flush_every_rows must be positive")
        if flush_interval_seconds <= 0:
            raise ValueError("flush_interval_seconds must be positive")

        self.output_root = Path(output_root)
        self.path = self.output_root / "session_audit_v2.csv"
        self.rollback_threshold = rollback_threshold
        self.flush_every_rows = flush_every_rows
        self.flush_interval_seconds = flush_interval_seconds
        self._lock = threading.Lock()
        self._handle: Optional[TextIO] = None
        self._writer: Optional[csv.DictWriter] = None
        self._max_frame_id: dict[int, int] = {}
        self._max_row_seq: dict[int, int] = {}
        self._pending_rows = 0
        self._last_flush = time.monotonic()
        self.reset_count = 0
        self._start_new_session(initial=True)

    def __call__(self, ctx: FrameContext) -> None:
        self.log_context(ctx)

    def log_context(self, ctx: FrameContext) -> None:
        """Record a processed frame, including Layer-3 failures."""
        result = ctx.camera_result
        packet = result.packet if result is not None else None

        with self._lock:
            if packet is None:
                self._write_row(
                    {
                        "timestamp": _format_timestamp(ctx.frame.timestamp),
                        **{name: "" for name in AUDIT_FIELDS[1:-3]},
                        "validation_status": "UNPARSED",
                        "reject_reason": (
                            result.reason if result is not None else
                            ctx.stop_reason or "no_camera_packet"
                        ),
                        "row_accepted": 0,
                    }
                )
                return

            header = packet.header
            cam_id = header.cam_id
            frame_id = header.frame_id
            row_seq = header.row_seq

            # A malformed header can contain arbitrary frame/sequence values.
            # It is still written below, but it must not erase the current
            # session's CSV.  Only a Layer-3-valid packet is a "known value"
            # for power-session rollback detection.
            trusted_for_session = result is not None and result.ok
            if trusted_for_session:
                if self._is_new_power_session(cam_id, frame_id, row_seq):
                    self._start_new_session(initial=False)
                self._update_counter_maxima(cam_id, frame_id, row_seq)

            row_flags_raw = header.row_flags
            if result.errors:
                reject_reason = ";".join(result.errors)
            elif (
                ctx.packet_record is not None
                and ctx.packet_record.conflicting_duplicate
            ):
                reject_reason = "conflicting_duplicate"
            elif (
                ctx.packet_record is not None
                and ctx.packet_record.duplicate
            ):
                reject_reason = "duplicate_row"
            else:
                reject_reason = ""

            self._write_row(
                {
                    "timestamp": _format_timestamp(ctx.frame.timestamp),
                    "cam_id": cam_id,
                    "frame_id": frame_id,
                    "row_idx": header.row_idx,
                    "sender_row_flags_raw": f"0x{row_flags_raw:02X}",
                    "sender_row2_marker": int(packet.sender_row2_marker),
                    "fpga_status_raw": f"0x{header.fpga_status_raw:02X}",
                    "fpga_length_error": int(packet.fpga_length_error),
                    "fpga_crc_error": int(packet.fpga_crc_error),
                    "payload_len": header.payload_len,
                    "row_seq": row_seq,
                    "crc_mode": result.crc_mode,
                    "crc_checked": int(result.crc_checked),
                    "crc_ok": (
                        "" if result.crc_ok is None else int(result.crc_ok)
                    ),
                    "validation_status": (
                        "PASS" if result.ok else
                        "DIAGNOSTIC_REJECT" if result.parsed_ok else
                        "PROTOCOL_REJECT"
                    ),
                    "reject_reason": reject_reason,
                    "row_accepted": int(
                        ctx.packet_record is not None
                        and ctx.packet_record.accepted
                    ),
                }
            )

    def close(self) -> None:
        with self._lock:
            if self._handle is not None:
                self._handle.flush()
                self._handle.close()
                self._handle = None
                self._writer = None

    def _start_new_session(self, *, initial: bool) -> None:
        if self._handle is not None:
            self._handle.flush()
            self._handle.close()

        self.output_root.mkdir(parents=True, exist_ok=True)
        self._handle = self.path.open("w", newline="", encoding="utf-8")
        self._writer = csv.DictWriter(self._handle, fieldnames=AUDIT_FIELDS)
        self._writer.writeheader()
        self._handle.flush()
        self._pending_rows = 0
        self._last_flush = time.monotonic()

        self._max_frame_id.clear()
        self._max_row_seq.clear()
        if not initial:
            self.reset_count += 1

    def _is_new_power_session(
        self,
        cam_id: int,
        frame_id: int,
        row_seq: int,
    ) -> bool:
        previous_frame = self._max_frame_id.get(cam_id)
        previous_row_seq = self._max_row_seq.get(cam_id)
        return (
            previous_frame is not None
            and _is_illegal_rollback(
                previous_frame,
                frame_id,
                self.rollback_threshold,
            )
        ) or (
            previous_row_seq is not None
            and _is_illegal_rollback(
                previous_row_seq,
                row_seq,
                self.rollback_threshold,
            )
        )

    def _update_counter_maxima(
        self,
        cam_id: int,
        frame_id: int,
        row_seq: int,
    ) -> None:
        self._max_frame_id[cam_id] = _updated_max(
            self._max_frame_id.get(cam_id), frame_id
        )
        self._max_row_seq[cam_id] = _updated_max(
            self._max_row_seq.get(cam_id), row_seq
        )

    def _write_row(self, values: dict[str, object]) -> None:
        if self._writer is None or self._handle is None:
            raise RuntimeError("session audit logger is closed")
        self._writer.writerow(values)
        self._pending_rows += 1
        now = time.monotonic()
        if (
            self._pending_rows >= self.flush_every_rows
            or now - self._last_flush >= self.flush_interval_seconds
        ):
            self._handle.flush()
            self._pending_rows = 0
            self._last_flush = now


def _is_illegal_rollback(previous: int, current: int, threshold: int) -> bool:
    if current >= previous:
        return False
    if previous >= _WRAP_HIGH and current <= _WRAP_LOW:
        return False
    return previous - current >= threshold


def _updated_max(previous: Optional[int], current: int) -> int:
    if previous is None:
        return current
    if previous >= _WRAP_HIGH and current <= _WRAP_LOW:
        return current
    return max(previous, current)


def _format_timestamp(timestamp: float) -> str:
    return f"{timestamp:.9f}"
