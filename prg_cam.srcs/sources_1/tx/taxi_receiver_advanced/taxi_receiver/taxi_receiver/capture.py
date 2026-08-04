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
class PcapStatistics:
    ps_recv: int
    ps_drop: int
    ps_ifdrop: int
    ps_capt: Optional[int] = None
    ps_sent: Optional[int] = None
    ps_netdrop: Optional[int] = None


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


def _packet_timestamp(packet) -> float:
    packet_time = getattr(packet, "time", None)
    if packet_time is None:
        return time.time()
    return float(packet_time)


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
        self._socket = None
        self._pcap_stats_snapshot: Optional[PcapStatistics] = None

    def start(self, on_frame: Callable[[RawEthernetFrame], None]) -> None:
        from scapy.all import AsyncSniffer
        from scapy.all import conf
        from scapy.layers.l2 import Ether

        self._socket = conf.L2listen(
            iface=self.interface,
            filter=f"ether proto 0x{self.ether_type:04x}",
            promisc=True,
            monitor=False,
        )

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
                timestamp=_packet_timestamp(packet),
            ))

        self._sniffer = AsyncSniffer(opened_socket=self._socket, prn=_callback, store=False)
        self._sniffer.start()

    def stop(self) -> None:
        if self._socket is not None:
            snapshot = self._read_pcap_stats()
            if snapshot is not None:
                self._pcap_stats_snapshot = snapshot
        if self._sniffer is not None and self._sniffer.running:
            self._sniffer.stop()
        if self._socket is not None:
            try:
                self._socket.close()
            finally:
                self._socket = None

    def pcap_stats(self) -> Optional[PcapStatistics]:
        if self._socket is None:
            return self._pcap_stats_snapshot

        snapshot = self._read_pcap_stats()
        if snapshot is not None:
            self._pcap_stats_snapshot = snapshot
        return snapshot

    def _read_pcap_stats(self) -> Optional[PcapStatistics]:
        if self._socket is None:
            return None

        from ctypes import byref

        try:
            from scapy.libs import winpcapy
        except Exception:
            return None

        pcap_handle = getattr(self._socket.pcap_fd, "pcap", None)
        if pcap_handle is None:
            return None

        stat = winpcapy.pcap_stat()
        result = winpcapy.pcap_stats(pcap_handle, byref(stat))
        if result != 0:
            return None

        return PcapStatistics(
            ps_recv=int(stat.ps_recv),
            ps_drop=int(stat.ps_drop),
            ps_ifdrop=int(stat.ps_ifdrop),
            ps_capt=int(stat.ps_capt) if hasattr(stat, "ps_capt") else None,
            ps_sent=int(stat.ps_sent) if hasattr(stat, "ps_sent") else None,
            ps_netdrop=int(stat.ps_netdrop) if hasattr(stat, "ps_netdrop") else None,
        )


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
                timestamp=_packet_timestamp(packet),
            ))

    def stop(self) -> None:
        pass
