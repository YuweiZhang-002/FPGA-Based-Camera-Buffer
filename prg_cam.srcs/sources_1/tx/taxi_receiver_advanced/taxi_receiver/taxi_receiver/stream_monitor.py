"""
stream_monitor.py  --  Layer 4 (Stream Monitor).

Consumes the plain result objects produced by Layer 2/3 and turns them
into running statistics, per-camera sequence-integrity checks
(gap/duplicate/out-of-order), and periodic rate/throughput reports.

Nothing here imports scapy or does any capture-related work, so it's
fully testable with results built straight from synthetic packets
(see tests/).
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Callable, Optional

from .camera_parser import CameraModeResult, FixedModeResult


@dataclass
class CameraStatistics:
    packets: int = 0
    crc_errors: int = 0
    length_errors: int = 0
    frame_overflow_packets: int = 0

    sequence_gaps: int = 0
    duplicate_packets: int = 0
    out_of_order_packets: int = 0

    first_row_packets: int = 0
    last_row_packets: int = 0

    last_sequence: Optional[int] = None


@dataclass
class GlobalStatistics:
    total_ethernet_frames: int = 0
    matching_frames: int = 0
    valid_packets: int = 0

    bad_ethernet_length: int = 0
    bad_fixed_payload: int = 0
    bad_crc: int = 0
    parser_errors: int = 0
    processing_errors: int = 0

    dropped_capture_queue: int = 0
    ethernet_validation_failures: int = 0

    total_payload_bytes: int = 0

    start_time: float = field(default_factory=time.monotonic)
    last_report_time: float = field(default_factory=time.monotonic)
    last_report_frames: int = 0
    last_report_bytes: int = 0

    cameras: dict[int, CameraStatistics] = field(default_factory=dict)

    def camera(self, camera_id: int) -> CameraStatistics:
        if camera_id not in self.cameras:
            self.cameras[camera_id] = CameraStatistics()
        return self.cameras[camera_id]


class StreamMonitor:
    def __init__(self, report_interval: float = 1.0, sink: Callable[[str], None] = print):
        self.stats = GlobalStatistics()
        self.report_interval = report_interval
        self.sink = sink

    # ---- ingestion from Layers 1-3 ----------------------------------

    def record_ethernet_frame(self) -> None:
        self.stats.total_ethernet_frames += 1

    def record_dropped_capture(self) -> None:
        self.stats.dropped_capture_queue += 1

    def record_validation_failure(self, reason: str) -> None:
        self.stats.ethernet_validation_failures += 1
        if reason in ("payload_too_short", "payload_too_long"):
            self.stats.bad_ethernet_length += 1

    def record_matching_frame(self, payload_len: int) -> None:
        self.stats.matching_frames += 1
        self.stats.total_payload_bytes += payload_len

    def record_fixed_result(self, result: FixedModeResult) -> None:
        if not result.ok:
            if result.reason == "bad_length":
                self.stats.bad_ethernet_length += 1
            else:
                self.stats.bad_fixed_payload += 1
            return
        self.stats.valid_packets += 1

    def record_camera_result(self, result: CameraModeResult) -> None:
        if result.reason == "bad_length":
            self.stats.bad_ethernet_length += 1
            return

        packet = result.packet
        assert packet is not None
        camera = self.stats.camera(packet.header.cam_id)
        camera.packets += 1

        if packet.first_row:
            camera.first_row_packets += 1
        if packet.last_row:
            camera.last_row_packets += 1
        if packet.frame_overflow:
            camera.frame_overflow_packets += 1
        if packet.length_error:
            camera.length_errors += 1

        if not result.ok:
            if "crc_error" in result.errors:
                camera.crc_errors += 1
                self.stats.bad_crc += 1
            return

        self.stats.valid_packets += 1
        self._update_sequence(camera, packet.header.row_seq)

    @staticmethod
    def _update_sequence(camera: CameraStatistics, sequence: int) -> None:
        if camera.last_sequence is None:
            camera.last_sequence = sequence
            return

        expected = (camera.last_sequence + 1) & 0xFFFF

        if sequence == camera.last_sequence:
            camera.duplicate_packets += 1
        elif sequence == expected:
            camera.last_sequence = sequence
        else:
            forward_distance = (sequence - expected) & 0xFFFF
            if forward_distance < 0x8000:
                camera.sequence_gaps += forward_distance
                camera.last_sequence = sequence
            else:
                camera.out_of_order_packets += 1

    # ---- reporting ----------------------------------------------------

    def maybe_report(self) -> None:
        now = time.monotonic()
        if now - self.stats.last_report_time < self.report_interval:
            return

        interval = now - self.stats.last_report_time
        frame_delta = self.stats.matching_frames - self.stats.last_report_frames
        byte_delta = self.stats.total_payload_bytes - self.stats.last_report_bytes

        fps = frame_delta / interval
        payload_mbps = byte_delta * 8 / interval / 1_000_000

        self.sink(
            f"[RATE] frames={self.stats.matching_frames} "
            f"valid={self.stats.valid_packets} fps={fps:.2f} "
            f"payload={payload_mbps:.3f} Mb/s "
            f"crc_errors={self.stats.bad_crc} "
            f"queue_drops={self.stats.dropped_capture_queue}"
        )

        for camera_id in sorted(self.stats.cameras):
            camera = self.stats.cameras[camera_id]
            self.sink(
                f"       CAM{camera_id}: packets={camera.packets} "
                f"crc={camera.crc_errors} len={camera.length_errors} "
                f"overflow={camera.frame_overflow_packets} "
                f"gaps={camera.sequence_gaps} dup={camera.duplicate_packets} "
                f"ooo={camera.out_of_order_packets}"
            )

        self.stats.last_report_time = now
        self.stats.last_report_frames = self.stats.matching_frames
        self.stats.last_report_bytes = self.stats.total_payload_bytes

    def final_report(self) -> None:
        elapsed = time.monotonic() - self.stats.start_time
        average_fps = self.stats.matching_frames / elapsed if elapsed > 0 else 0.0
        average_mbps = (
            self.stats.total_payload_bytes * 8 / elapsed / 1_000_000 if elapsed > 0 else 0.0
        )

        self.sink("\n============== FINAL REPORT ==============")
        self.sink(f"Elapsed               : {elapsed:.3f} s")
        self.sink(f"Capture ingress       : {self.stats.total_ethernet_frames}")
        self.sink(f"Matching Ethernet     : {self.stats.matching_frames}")
        self.sink(f"Valid packets         : {self.stats.valid_packets}")
        self.sink(f"Bad Ethernet length   : {self.stats.bad_ethernet_length}")
        self.sink(f"Bad fixed payload     : {self.stats.bad_fixed_payload}")
        self.sink(f"CRC errors            : {self.stats.bad_crc}")
        self.sink(f"Parser errors         : {self.stats.parser_errors}")
        self.sink(f"Processing errors     : {self.stats.processing_errors}")
        self.sink(f"Capture queue drops   : {self.stats.dropped_capture_queue}")
        self.sink(f"Average frame rate    : {average_fps:.2f} fps")
        self.sink(f"Average payload rate  : {average_mbps:.3f} Mb/s")

        for camera_id in sorted(self.stats.cameras):
            camera = self.stats.cameras[camera_id]
            self.sink(f"\nCAMERA {camera_id}")
            self.sink(f"  packets             : {camera.packets}")
            self.sink(f"  CRC errors          : {camera.crc_errors}")
            self.sink(f"  length errors       : {camera.length_errors}")
            self.sink(f"  overflow-marked     : {camera.frame_overflow_packets}")
            self.sink(f"  first-row packets   : {camera.first_row_packets}")
            self.sink(f"  last-row packets    : {camera.last_row_packets}")
            self.sink(f"  sequence gaps       : {camera.sequence_gaps}")
            self.sink(f"  duplicates          : {camera.duplicate_packets}")
            self.sink(f"  out-of-order        : {camera.out_of_order_packets}")
