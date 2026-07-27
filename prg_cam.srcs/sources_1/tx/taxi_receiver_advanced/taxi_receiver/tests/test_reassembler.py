from taxi_receiver.camera_parser import parse_camera_mode
from taxi_receiver.reassembler import FrameReassembler, NullReassembler
from taxi_receiver.packet_format import FLAG_FIRST_ROW, FLAG_LAST_ROW

from .synthetic import make_camera_frame


def _parsed(cam_id, frame_id, row_idx, flags):
    frame = make_camera_frame(cam_id=cam_id, frame_id=frame_id, row_idx=row_idx, row_seq=row_idx, row_flags=flags)
    return parse_camera_mode(frame.payload).packet


def test_null_reassembler_never_completes():
    reassembler = NullReassembler()
    pkt = _parsed(0, 1, 0, FLAG_FIRST_ROW | FLAG_LAST_ROW)
    assert reassembler.on_row(pkt) is None
    assert reassembler.flush() == []


def test_frame_reassembler_completes_on_last_row():
    reassembler = FrameReassembler()

    assert reassembler.on_row(_parsed(0, 1, 0, FLAG_FIRST_ROW)) is None
    assert reassembler.on_row(_parsed(0, 1, 1, 0)) is None
    completed = reassembler.on_row(_parsed(0, 1, 2, FLAG_LAST_ROW))

    assert completed is not None
    assert completed.camera_id == 0
    assert completed.frame_id == 1
    assert completed.row_count == 3
    assert completed.missing_rows == []
    assert reassembler.stats.sessions_created == 1
    assert reassembler.stats.rows_accepted == 3
    assert reassembler.stats.rows_rejected == 0
    assert reassembler.stats.frames_completed == 1


def test_frame_reassembler_reports_missing_rows():
    reassembler = FrameReassembler()
    reassembler.on_row(_parsed(0, 1, 0, FLAG_FIRST_ROW))
    # row 1 lost
    assert reassembler.on_row(_parsed(0, 1, 2, FLAG_LAST_ROW)) is None
    completed = reassembler.flush()[0]

    assert completed.missing_rows == [1]
    assert reassembler.stats.frames_partial == 1


def test_flush_closes_in_progress_frames():
    reassembler = FrameReassembler()
    reassembler.on_row(_parsed(0, 1, 0, FLAG_FIRST_ROW))
    completed = reassembler.flush()

    assert len(completed) == 1
    assert completed[0].frame_id == 1
    assert completed[0].row_count == 1
