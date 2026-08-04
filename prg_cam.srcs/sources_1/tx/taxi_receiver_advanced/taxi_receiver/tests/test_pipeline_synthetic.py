import time
import sys
import types
from ctypes import Structure, c_ulong
from types import SimpleNamespace

import pytest

import taxi_receiver.cli as cli_module
from taxi_receiver.async_sink import AsyncCallbackDispatcher
from taxi_receiver.capture import ScapyLiveCapture, SyntheticFrameSource, _packet_timestamp
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


def test_frame_output_logs_named_callback_failures():
    messages = []
    seen = []

    def storage(_frame):
        seen.append("storage")
        raise FileExistsError("output already exists")

    def image_publication(_frame):
        seen.append("image publication")
        raise ValueError("geometry mismatch")

    dispatcher = AsyncCallbackDispatcher(
        cli_module._fanout_callbacks(
            ("storage", storage),
            ("image publication", image_publication),
        ),
        queue_depth=1,
        name="test-frame-writer",
        error_sink=messages.append,
    )

    dispatcher.submit(object())
    dispatcher.close()

    assert seen == ["storage", "image publication"]
    assert dispatcher.stats.submitted == 1
    assert dispatcher.stats.processed == 0
    assert dispatcher.stats.failures == 1
    assert len(messages) == 1
    assert messages[0] == (
        "[FRAME OUTPUT ERROR] storage failed: output already exists; "
        "image publication failed: geometry mismatch"
    )


def test_fanout_callbacks_still_accept_plain_callables():
    calls = []

    def first(value):
        calls.append(("first", value))

    def second(value):
        calls.append(("second", value))

    invoke = cli_module._fanout_callbacks(first, second)
    assert invoke is not None

    marker = object()
    invoke(marker)

    assert calls == [("first", marker), ("second", marker)]


def test_final_report_includes_live_pcap_drop_stats():
    class StatsFrameSource:
        def __init__(self):
            self.frames = []

        def start(self, on_frame):
            self.frames.append("started")

        def stop(self):
            self.frames.append("stopped")

        def pcap_stats(self):
            class Stats:
                ps_recv = 12
                ps_drop = 3
                ps_ifdrop = 1

            return Stats()

    lines = []
    pipeline = TaxiReceiverPipeline(
        frame_source=StatsFrameSource(),
        mode="camera",
        report_interval=999,
        sink=lines.append,
    )
    pipeline.print_final_report()

    joined = "\n".join(lines)
    assert "LIVE PCAP STATS" in joined
    assert "ps_recv" in joined
    assert "ps_drop" in joined
    assert "ps_ifdrop" in joined


def test_scapy_live_capture_caches_pcap_stats_across_stop(monkeypatch):
    class FakeSocket:
        def __init__(self):
            self.pcap_fd = SimpleNamespace(pcap=object())
            self.closed = False

        def close(self):
            self.closed = True

    class FakeSniffer:
        def __init__(self, opened_socket=None, prn=None, store=None):
            self.opened_socket = opened_socket
            self.prn = prn
            self.store = store
            self.running = False

        def start(self):
            self.running = True

        def stop(self):
            self.running = False

    class FakeStat(Structure):
        _fields_ = [
            ("ps_recv", c_ulong),
            ("ps_drop", c_ulong),
            ("ps_ifdrop", c_ulong),
        ]

    fake_socket = FakeSocket()

    def fake_pcap_stats(_handle, stat_ptr):
        stat = stat_ptr._obj
        stat.ps_recv = 42
        stat.ps_drop = 7
        stat.ps_ifdrop = 1
        return 0

    scapy_module = types.ModuleType("scapy")
    scapy_libs_module = types.ModuleType("scapy.libs")
    winpcapy_module = types.ModuleType("scapy.libs.winpcapy")
    winpcapy_module.pcap_stat = FakeStat
    winpcapy_module.pcap_stats = fake_pcap_stats
    scapy_libs_module.winpcapy = winpcapy_module
    scapy_module.libs = scapy_libs_module
    monkeypatch.setitem(sys.modules, "scapy", scapy_module)
    monkeypatch.setitem(sys.modules, "scapy.libs", scapy_libs_module)
    monkeypatch.setitem(sys.modules, "scapy.libs.winpcapy", winpcapy_module)

    capture = ScapyLiveCapture.__new__(ScapyLiveCapture)
    capture.interface = "fake0"
    capture.ether_type = 0x88B5
    capture.include_raw = True
    capture._sniffer = FakeSniffer()
    capture._socket = fake_socket
    capture._pcap_stats_snapshot = None

    before_stop = capture.pcap_stats()
    assert before_stop is not None
    assert before_stop.ps_drop == 7

    capture.stop()

    after_stop = capture.pcap_stats()
    assert after_stop is not None
    assert after_stop.ps_drop == 7
    assert fake_socket.closed


def test_scapy_live_capture_uses_pcap_buffer_size_before_activation(monkeypatch):
    calls = []
    fake_handle = object()

    class FakeEther:
        def __init__(self, raw_bytes):
            self.src = "00:11:22:33:44:55"
            self.dst = "66:77:88:99:aa:bb"
            self.type = 0x88B5
            self.payload = b"payload"

    def record(name, return_value=0):
        def _inner(*args, **kwargs):
            calls.append((name, args, kwargs))
            return return_value

        return _inner

    def fake_next_packet(self, _winpcapy, _handle):
        raise RuntimeError("stop thread")

    fake_winpcapy = types.ModuleType("scapy.libs.winpcapy")
    fake_winpcapy.PCAP_ERRBUF_SIZE = 256
    class FakeBpfProgram(Structure):
        _fields_ = []

    fake_winpcapy.bpf_program = FakeBpfProgram
    fake_winpcapy.pcap_create = record("pcap_create", fake_handle)
    fake_winpcapy.pcap_set_snaplen = record("pcap_set_snaplen")
    fake_winpcapy.pcap_set_promisc = record("pcap_set_promisc")
    fake_winpcapy.pcap_set_timeout = record("pcap_set_timeout")
    fake_winpcapy.pcap_set_buffer_size = record("pcap_set_buffer_size")
    fake_winpcapy.pcap_activate = record("pcap_activate")
    fake_winpcapy.pcap_compile = record("pcap_compile")
    fake_winpcapy.pcap_setfilter = record("pcap_setfilter")
    fake_winpcapy.pcap_freecode = record("pcap_freecode")
    fake_winpcapy.pcap_setmintocopy = record("pcap_setmintocopy")
    class FakeStat(Structure):
        _fields_ = [
            ("ps_recv", c_ulong),
            ("ps_drop", c_ulong),
            ("ps_ifdrop", c_ulong),
        ]

    fake_winpcapy.pcap_stat = FakeStat
    fake_winpcapy.pcap_stats = lambda _handle, _stat_ptr: 0
    fake_winpcapy.pcap_geterr = lambda _handle: b"fake error"
    fake_winpcapy.pcap_breakloop = record("pcap_breakloop")
    fake_winpcapy.pcap_close = record("pcap_close")

    fake_layers_l2 = types.ModuleType("scapy.layers.l2")
    fake_layers_l2.Ether = FakeEther

    fake_scapy_all = types.ModuleType("scapy.all")
    fake_scapy_all.conf = SimpleNamespace(use_npcap=True)

    fake_scapy_libs = types.ModuleType("scapy.libs")
    fake_scapy_libs.winpcapy = fake_winpcapy
    fake_scapy = types.ModuleType("scapy")
    fake_scapy.all = fake_scapy_all
    fake_scapy.libs = fake_scapy_libs
    fake_scapy.layers = types.ModuleType("scapy.layers")
    fake_scapy.layers.l2 = fake_layers_l2

    monkeypatch.setitem(sys.modules, "scapy", fake_scapy)
    monkeypatch.setitem(sys.modules, "scapy.all", fake_scapy_all)
    monkeypatch.setitem(sys.modules, "scapy.libs", fake_scapy_libs)
    monkeypatch.setitem(sys.modules, "scapy.libs.winpcapy", fake_winpcapy)
    monkeypatch.setitem(sys.modules, "scapy.layers", fake_scapy.layers)
    monkeypatch.setitem(sys.modules, "scapy.layers.l2", fake_layers_l2)
    monkeypatch.setattr(ScapyLiveCapture, "_next_packet", fake_next_packet)

    capture = ScapyLiveCapture(
        "fake0",
        ether_type=0x88B5,
        include_raw=True,
        pcap_buffer_size=2 * 1024 * 1024,
        read_timeout_ms=250,
    )
    received = []

    capture.start(received.append)
    time.sleep(0.1)
    capture.stop()

    names = [name for name, *_ in calls]
    assert names[0] == "pcap_create"
    assert names.index("pcap_set_buffer_size") < names.index("pcap_activate")
    assert names.index("pcap_activate") < names.index("pcap_setfilter")
    assert names.index("pcap_setfilter") < names.index("pcap_setmintocopy")
    assert names.index("pcap_setmintocopy") < names.index("pcap_close")


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


def test_bad_sync_is_counted_but_cannot_create_image_session():
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
    # Monitoring/session-audit retain the packet error, but Layer 5 must not
    # trust frame_id=24618 from a packet whose sync words are invalid.
    assert completed_frames == []


def test_slow_frame_storage_is_decoupled_from_capture_queue():
    """A slow image/archive callback must not stall the capture consumer."""

    frames = [
        make_camera_frame(
            cam_id=0,
            frame_id=index,
            row_idx=0,
            row_seq=index,
            row_flags=FLAG_FIRST_ROW | FLAG_LAST_ROW,
        )
        for index in range(100)
    ]

    def slow_store(_frame):
        time.sleep(0.002)

    class PacedFrameSource:
        def start(self, on_frame):
            for frame in frames:
                on_frame(frame)
                time.sleep(0.0005)

        def stop(self):
            pass

    direct = TaxiReceiverPipeline(
        frame_source=PacedFrameSource(),
        mode="camera",
        max_stage="reassemble",
        reassembler=FrameReassembler(expected_rows=1),
        queue_depth=2,
        report_interval=999,
        sink=lambda *_: None,
        on_completed_frame=slow_store,
    )
    direct.start()
    direct.stop()
    assert direct.monitor.stats.dropped_capture_queue > 0

    dispatcher = AsyncCallbackDispatcher(
        slow_store,
        queue_depth=len(frames),
        name="test-frame-writer",
        error_sink=lambda _message: None,
    )
    asynchronous = TaxiReceiverPipeline(
        frame_source=PacedFrameSource(),
        mode="camera",
        max_stage="reassemble",
        reassembler=FrameReassembler(expected_rows=1),
        queue_depth=2,
        report_interval=999,
        sink=lambda *_: None,
        on_completed_frame=dispatcher.submit,
    )
    asynchronous.start()
    asynchronous.stop()
    dispatcher.close()

    assert asynchronous.monitor.stats.dropped_capture_queue == 0
    assert dispatcher.stats.submitted == len(frames)
    assert dispatcher.stats.processed == len(frames)
    assert dispatcher.stats.failures == 0
    assert dispatcher.stats.queue_peak > 0


def test_packet_timestamp_prefers_captured_packet_time():
    class DummyPacket:
        time = 123.456

    assert _packet_timestamp(DummyPacket()) == 123.456
