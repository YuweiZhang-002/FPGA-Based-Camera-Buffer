import time

from taxi_receiver.capture import SyntheticFrameSource
from taxi_receiver.packet_format import (
    FLAG_FIRST_ROW,
    FLAG_LAST_ROW,
    ROW_BYTES,
    build_camera_row,
)
from taxi_receiver.pipeline import TaxiReceiverPipeline
from taxi_receiver.reassembler import FrameReassembler, FrameStatus

from .synthetic import make_camera_frame, make_fixed_frame, make_raw_frame


def test_pipeline_camera_mode_end_to_end():
    frames = [
        make_camera_frame(cam_id=1, frame_id=1, row_idx=i, row_seq=i)
        for i in range(3)
    ]
    frames.append(make_camera_frame(cam_id=1, frame_id=1, row_idx=3, row_seq=3, corrupt_crc=True))

    source = SyntheticFrameSource(frames)
    pipeline = TaxiReceiverPipeline(
        frame_source=source, mode="camera", report_interval=999, sink=lambda *_: None
    )
    pipeline.start()
    time.sleep(0.3)
    pipeline.stop()

    assert pipeline.monitor.stats.valid_packets == 3
    assert pipeline.monitor.stats.bad_crc == 1
    assert pipeline.monitor.stats.camera(1).packets == 4


def test_pipeline_with_reassembler_layer5():
    frames = [
        make_camera_frame(
            cam_id=0, frame_id=7, row_idx=0, row_seq=0,
            row_flags=FLAG_FIRST_ROW,
        ),
        make_camera_frame(
            cam_id=0, frame_id=7, row_idx=1, row_seq=1,
            row_flags=FLAG_LAST_ROW,
        ),
    ]
    completed_frames = []

    pipeline = TaxiReceiverPipeline(
        frame_source=SyntheticFrameSource(frames),
        mode="camera",
        max_stage="reassemble",  # Layer 1-5; default "monitor" would stop at Layer 4
        reassembler=FrameReassembler(),
        report_interval=999,
        sink=lambda *_: None,
        on_completed_frame=completed_frames.append,
    )
    pipeline.start()
    time.sleep(0.3)
    pipeline.stop()

    assert len(completed_frames) == 1
    assert completed_frames[0].camera_id == 0
    assert completed_frames[0].frame_id == 7
    assert completed_frames[0].row_count == 2


def test_pipeline_fixed_mode():
    frames = [make_fixed_frame(), make_fixed_frame(corrupt=True)]
    pipeline = TaxiReceiverPipeline(
        frame_source=SyntheticFrameSource(frames), mode="fixed",
        report_interval=999, sink=lambda *_: None,
    )
    pipeline.start()
    time.sleep(0.3)
    pipeline.stop()

    assert pipeline.monitor.stats.valid_packets == 1
    assert pipeline.monitor.stats.bad_fixed_payload == 1


def test_invalid_structured_packet_can_close_corrupt_evidence_session():
    payload = build_camera_row(
        cam_id=0,
        frame_id=24618,
        row_idx=0,
        row_flags=FLAG_LAST_ROW,
        row_seq=1,
        payload=bytes(ROW_BYTES),
        sync0=0x1111,
        sync1=0x2222,
    )
    completed_frames = []
    pipeline = TaxiReceiverPipeline(
        frame_source=SyntheticFrameSource([make_raw_frame(payload)]),
        mode="camera",
        max_stage="reassemble",
        reassembler=FrameReassembler(expected_rows=1),
        report_interval=999,
        sink=lambda *_: None,
        on_completed_frame=completed_frames.append,
    )

    pipeline.start()
    pipeline.stop()

    assert pipeline.monitor.stats.valid_packets == 0
    assert pipeline.monitor.stats.camera(0).packets == 1
    assert pipeline.monitor.stats.camera(0).last_row_packets == 1
    assert len(completed_frames) == 1
    assert completed_frames[0].frame_id == 24618
    assert completed_frames[0].status is FrameStatus.CORRUPT
    assert completed_frames[0].row_count == 0
