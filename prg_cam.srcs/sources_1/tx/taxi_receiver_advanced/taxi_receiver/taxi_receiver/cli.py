from __future__ import annotations

import argparse
import signal
import sys
import threading
from pathlib import Path

from .capture import ScapyLiveCapture, list_interfaces
from .eth_validate import ETHER_TYPE
from .image_pipeline import CameraImagePipeline
from .pcap_stdlib import StdlibPcapReplayFrameSource
from .pipeline import TaxiReceiverPipeline
from .reassembler import FrameReassembler, NullReassembler
from .recorder import ErrorFrameRecorder, PcapRecorder
from .session_audit import SessionAuditLogger
from .stages import STAGE_ORDER
from .storage import StorageAndPipeline


def print_interfaces() -> None:
    interfaces = list_interfaces()
    print("Available capture interfaces:")
    for index, interface in enumerate(interfaces):
        print(f"  [{index:02d}] {interface}")


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Capture and validate FPGA TAXI Ethernet frames."
    )
    parser.add_argument("--interface", "-i", help="Npcap/libpcap capture interface.")
    parser.add_argument(
        "--replay-pcap",
        type=Path,
        help="Replay classic PCAP/PCAPNG with the standard-library reader.",
    )
    parser.add_argument(
        "--source-mac",
        default="02:00:00:00:00:02",
        help="Optional source-MAC filter for offline replay.",
    )
    parser.add_argument(
        "--mode", choices=("fixed", "camera"), default="camera",
        help="fixed: expect payload 00..7F; camera: parse camera row packets.",
    )
    parser.add_argument("--list", action="store_true", help="List capture interfaces.")
    parser.add_argument("--pcap", type=Path, help="Save matching Ethernet frames to a PCAP file.")
    parser.add_argument("--error-directory", type=Path, help="Save malformed payloads as binary files.")
    parser.add_argument("--queue-depth", type=int, default=8192)
    parser.add_argument("--report-interval", type=float, default=1.0)
    parser.add_argument(
        "--output-root",
        type=Path,
        help="Atomically archive Layer-5 frame directories and summary.csv.",
    )
    parser.add_argument(
        "--images-root",
        type=Path,
        help=(
            "Publish complete threshold images as "
            "camN/<frame_id>.pgm and append camN/rows.csv."
        ),
    )
    parser.add_argument(
        "--bit-order",
        choices=("msb_first", "lsb_first"),
        default="msb_first",
        help="Pixel-bit order inside each 80-byte packed Camera row.",
    )
    parser.add_argument(
        "--expected-rows",
        type=int,
        default=480,
        help="Expected packet rows per frame (current FPGA default: 480).",
    )
    parser.add_argument("--frame-timeout", type=float, default=2.0)
    parser.add_argument(
        "--reassemble", action="store_true",
        help="Shorthand for --max-stage reassemble (enables the Layer-5 FrameReassembler).",
    )
    parser.add_argument(
        "--max-stage", choices=STAGE_ORDER, default="monitor",
        help=(
            "How far up the chain to run: validate=Layer1-2, parse=Layer1-3, "
            "monitor=Layer1-4 (default, full stats/rate reporting), "
            "reassemble=Layer1-5. Useful for bringing a new link up one "
            "layer at a time."
        ),
    )
    return parser


def main() -> int:
    args = build_argument_parser().parse_args()

    if args.list:
        try:
            print_interfaces()
            return 0
        except ModuleNotFoundError:
            print(
                "Scapy is not installed in this Python environment. "
                "Install the dependencies in requirements-live.txt, then "
                "rerun --list. Offline PCAP replay and pytest do not require "
                "Scapy.",
                file=sys.stderr,
            )
            return 5

    if args.interface and args.replay_pcap:
        print("Error: choose --interface or --replay-pcap, not both.")
        return 2
    if not args.interface and not args.replay_pcap:
        print("Error: --interface or --replay-pcap is required.\n")
        try:
            print_interfaces()
        except ModuleNotFoundError:
            print("Scapy is not installed; offline --replay-pcap still works.")
        return 2

    pcap_recorder = PcapRecorder(args.pcap) if args.pcap else None
    error_recorder = ErrorFrameRecorder(args.error_directory) if args.error_directory else None

    # --reassemble is just sugar for --max-stage reassemble.
    max_stage = "reassemble" if args.reassemble else args.max_stage
    if args.output_root is not None or args.images_root is not None:
        max_stage = "reassemble"
    reassembler = (
        FrameReassembler(
            expected_rows=args.expected_rows,
            timeout_seconds=args.frame_timeout,
        )
        if max_stage == "reassemble"
        else NullReassembler()
    )
    storage = (
        StorageAndPipeline(args.output_root)
        if args.output_root is not None
        else None
    )
    session_audit = (
        SessionAuditLogger(args.output_root)
        if args.output_root is not None
        else None
    )
    image_pipeline = (
        CameraImagePipeline(
            args.images_root,
            expected_rows=args.expected_rows,
            bit_order=args.bit_order,
        )
        if args.images_root is not None
        else None
    )
    frame_source = (
        StdlibPcapReplayFrameSource(
            args.replay_pcap,
            ether_type=ETHER_TYPE,
            source_mac=args.source_mac,
        )
        if args.replay_pcap is not None
        else ScapyLiveCapture(args.interface, ether_type=ETHER_TYPE)
    )

    pipeline = TaxiReceiverPipeline(
        frame_source=frame_source,
        mode=args.mode,
        max_stage=max_stage,
        reassembler=reassembler,
        pcap_recorder=pcap_recorder,
        error_recorder=error_recorder,
        queue_depth=args.queue_depth,
        lossless_input=args.replay_pcap is not None,
        report_interval=args.report_interval,
        on_completed_frame=_fanout_callbacks(
            storage,
            image_pipeline.archive_frame if image_pipeline is not None else None,
        ),
        on_frame_processed=_fanout_callbacks(
            session_audit,
            image_pipeline.record_packet if image_pipeline is not None else None,
        ),
    )

    stop_requested = threading.Event()

    def handle_stop(signum, frame) -> None:
        stop_requested.set()

    signal.signal(signal.SIGINT, handle_stop)
    signal.signal(signal.SIGTERM, handle_stop)

    print(
        f"Source    : "
        f"{args.replay_pcap if args.replay_pcap else args.interface}"
    )
    print(f"Mode      : {args.mode}")
    print(f"Max stage : {max_stage} (Layer 1-{STAGE_ORDER.index(max_stage) + 2})")
    print(f"EtherType : 0x{ETHER_TYPE:04X}")
    print(f"Working dir: {Path.cwd().resolve()}")
    if args.output_root is not None:
        print(f"Archive   : {args.output_root.resolve()}")
    if args.images_root is not None:
        print(f"Images    : {args.images_root.resolve()}")
    print("Press Ctrl+C to stop.\n")

    try:
        pipeline.start()
        if args.replay_pcap is None:
            while not stop_requested.wait(0.25):
                pass
    except ModuleNotFoundError:
        print(
            "Scapy is not installed. Install Scapy for live capture or use "
            "--replay-pcap for the dependency-free offline path.",
            file=sys.stderr,
        )
        return 5
    except PermissionError:
        print("Capture permission denied. Run the terminal as Administrator/root.", file=sys.stderr)
        return 3
    except OSError as exc:
        print(f"Capture error: {exc}", file=sys.stderr)
        return 4
    finally:
        try:
            pipeline.stop()
            pipeline.print_final_report()
            if image_pipeline is not None:
                print("")
                for line in image_pipeline.report_lines():
                    print(line)
        finally:
            if session_audit is not None:
                session_audit.close()
            if image_pipeline is not None:
                image_pipeline.close()

    return 0

def _fanout_callbacks(*callbacks):
    """Run every configured observation/storage callback.

    A failure in one sink must not prevent the other evidence sink from
    receiving the same frame.  The first exception is re-raised only after all
    callbacks have been attempted, preserving the pipeline's existing error
    accounting.
    """

    active = tuple(callback for callback in callbacks if callback is not None)
    if not active:
        return None

    def invoke(value) -> None:
        first_error: Exception | None = None
        for callback in active:
            try:
                callback(value)
            except Exception as exc:  # noqa: BLE001 - preserve peer callbacks
                if first_error is None:
                    first_error = exc
        if first_error is not None:
            raise first_error

    return invoke


if __name__ == "__main__":
    raise SystemExit(main())
