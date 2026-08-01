"""
capture.py  --  Layer 1 (Capture).

This is the *only* layer that is allowed to know Scapy/Npcap exist,
and even here the import is deferred into the methods that need it,
not done at module scope. That means:

  * Importing taxi_receiver.capture (or anything downstream of it)
    never requires scapy or Npcap to be installed.
  * Unit tests for Layers 2-5 use SyntheticFrameSource below instead
    of a real NIC, with zero scapy dependency.
  * The RMII/PHY/MAC bit-to-byte assembly happens entirely below this
    module (in hardware, or in the OS driver) -- by the time a
    RawEthernetFrame exists, framing is already done. See
    packet_format.ByteStreamFramer for the one scenario where Python
    *would* need to do its own (byte-level) framing: a future capture
    source that hands over a raw, un-delimited byte stream instead of
    already-segmented Ethernet frames.
"""
from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Callable, Iterable, Optional, Protocol


@dataclass(slots=True)
class RawEthernetFrame:
    """Output of Layer 1 / input to Layer 2. Deliberately plain data --
    no scapy Packet object survives past this point."""
    src_mac: str
    dst_mac: str
    ethertype: int
    payload: bytes
    raw_bytes: bytes  # full L2 frame, kept only for optional pcap recording
    timestamp: float


class FrameSource(Protocol):
    def start(self, on_frame: Callable[[RawEthernetFrame], None]) -> None: ...
    def stop(self) -> None: ...


def list_interfaces() -> list[str]:
    from scapy.all import get_if_list
    return list(get_if_list())


class ScapyLiveCapture:
    """Real Layer 1: wraps scapy's AsyncSniffer.

    The sniff callback extracts only src/dst/ethertype/payload/raw
    bytes -- no CRC math, no struct unpack of the 128-byte body, no
    printing, no file I/O -- keeping it as light as the original
    prototype's comment insisted on, while still handing every other
    layer plain data instead of a scapy Packet.
    """

    def __init__(
        self,
        interface: str,
        ether_type: int = 0x88B5,
        *,
        include_raw: bool = True,
    ):
        self.interface = interface
        self.ether_type = ether_type
        self.include_raw = include_raw
        self._sniffer = None

    def start(self, on_frame: Callable[[RawEthernetFrame], None]) -> None:
        from scapy.all import AsyncSniffer
        from scapy.layers.l2 import Ether

        def _callback(packet) -> None:
            if Ether not in packet:
                return
            eth = packet[Ether]
            on_frame(RawEthernetFrame(
                src_mac=eth.src,
                dst_mac=eth.dst,
                ethertype=int(eth.type),
                payload=bytes(eth.payload),
                # The complete second byte copy is needed only when the
                # optional PCAP recorder is enabled.
                raw_bytes=bytes(packet) if self.include_raw else b"",
                timestamp=time.time(),
            ))

        self._sniffer = AsyncSniffer(
            iface=self.interface,
            filter=f"ether proto 0x{self.ether_type:04x}",
            prn=_callback,
            store=False,
        )
        self._sniffer.start()

    def stop(self) -> None:
        if self._sniffer is not None and self._sniffer.running:
            self._sniffer.stop()


class SyntheticFrameSource:
    """Test/offline Layer 1: replays a pre-built list (or generator)
    of RawEthernetFrame objects through the same FrameSource interface
    a real capture would use. No scapy, no NIC, no admin/root rights.

    This is the seam referred to throughout: because Layer 1's output
    type (RawEthernetFrame) is the boundary where "hardware-assembled
    bytes" become "Python objects", everything from here down can be
    validated with synthetic data regardless of whether the real
    source is a NIC, a pcap replay, or eventually a raw RMII/FPGA
    byte stream via ByteStreamFramer.
    """

    def __init__(self, frames: Iterable[RawEthernetFrame]):
        self._frames = list(frames)

    def start(self, on_frame: Callable[[RawEthernetFrame], None]) -> None:
        for frame in self._frames:
            on_frame(frame)

    def stop(self) -> None:
        pass


class PcapReplayFrameSource:
    """Offline Layer 1: replays frames from an existing .pcap file.
    Useful for regression testing against a real bench capture without
    needing the hardware present. Still touches scapy, but only here,
    and only for reading -- not for anything downstream."""

    def __init__(self, path: str, ether_type: Optional[int] = None):
        self.path = path
        self.ether_type = ether_type

    def start(self, on_frame: Callable[[RawEthernetFrame], None]) -> None:
        from scapy.all import rdpcap
        from scapy.layers.l2 import Ether

        for packet in rdpcap(self.path):
            if Ether not in packet:
                continue
            eth = packet[Ether]
            if self.ether_type is not None and int(eth.type) != self.ether_type:
                continue
            on_frame(RawEthernetFrame(
                src_mac=eth.src,
                dst_mac=eth.dst,
                ethertype=int(eth.type),
                payload=bytes(eth.payload),
                raw_bytes=bytes(packet),
                timestamp=time.time(),
            ))

    def stop(self) -> None:
        pass
