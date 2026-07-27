# taxi_receiver

Layered re-implementation of the original single-file `0x88B5` TAXI
Ethernet receiver prototype.

```
taxi_receiver/
  capture.py          Layer 1 - Capture            (only module that may import scapy, and lazily)
  eth_validate.py      Layer 2 - Ethernet Validation (EtherType / MAC / coarse length)
  packet_format.py     Layer 3 core - legacy-v0-observed layout + CRC-16
  camera_parser.py     Layer 3 - mode-aware parsing (fixed / camera), returns result objects
  stream_monitor.py    Layer 4 - statistics, seq gap/dup/ooo, rate + throughput reporting
  reassembler.py        Layer 5 - per-camera sessions, status, timeout, deduplication
  storage.py            Layer 5 - atomic raw/JSON/CSV archive + summary.csv
  session_audit.py      Side-band per-packet CSV + frame-local 0x08 propagation
  threshold_recover.py  Layer 6 - expand 80 packed bytes into 640 threshold bytes per row
  image_pipeline.py     Numbered camN PGM/RAW/JSON output + per-row telemetry CSV
  recorder.py           pcap + error-frame file I/O (side effects, wired in optionally)
  stages.py              Stage protocol + build_stage_chain(): compose Layer1-2/3/4/5 by name
  pipeline.py            orchestration only: queue + worker thread, runs whatever stage list it's given
  cli.py                 argparse entry point (adds --max-stage on top of the original flags)

tests/
  synthetic.py           builds 128-byte camera/fixed packets + RawEthernetFrame without scapy
  test_packet_format.py  struct sizes, CRC round-trip, ByteStreamFramer resync
  test_camera_parser.py  fixed/camera mode result objects
  test_stream_monitor.py sequence gap/duplicate/out-of-order arithmetic
  test_reassembler.py    Layer 5 reference implementation
  test_pipeline_synthetic.py  full pipeline, camera + fixed mode, with and without Layer 5
  test_storage_and_reassembly.py  out-of-order/duplicate/missing/timeout/storage gates
  test_session_audit.py  contamination, reboot overwrite, wrap, invalid-packet audit
  test_image_pipeline.py cam routing, frame-id naming, flags/CRC/CSV/PGM gates
```

Run tests: `pytest tests/ -v` (no scapy, Npcap, or NIC access required -- verified in-repo).

## Why this split

Python's visibility into "the network" starts only after the OS (or,
on the FPGA side, the PHY/MAC) has already turned RMII's 2-bit-per-clock
signal into complete bytes and, in Ethernet's case, complete frames.
Scapy/Npcap deliver whole `Ether` packets to `capture.py`; there is no
bit-shifting or counter logic to replicate in Python for that path.

That means the natural boundary for *testing without hardware* is
exactly `capture.py`'s output type, `RawEthernetFrame`. Everything
from `eth_validate.py` down is plain-data-in, plain-data-out, so
`tests/synthetic.py` builds `RawEthernetFrame` objects directly (via
`packet_format.build_camera_row`, the same `struct.pack` logic the
real parser's `struct.unpack` inverts) and feeds them straight into
Layer 2, Layer 3, Layer 4, or the whole `TaxiReceiverPipeline` through
`SyntheticFrameSource`. Only `capture.py` itself (and, if you use it,
`recorder.py`'s pcap writer) touches scapy, and that import is deferred
into the methods that need it -- confirmed by running the whole test
suite with scapy not even installed.

If a future capture source *doesn't* already deliver frame-delimited
bytes -- e.g. reading a continuous stream off a raw UART/serial bridge
or an FPGA DMA/debug channel instead of a NIC -- `packet_format.py`
also includes `ByteStreamFramer`, which is the byte-granularity
analogue of the RMII-side "shift bits in, count to 8" logic: it scans
for the `sync0`/`sync1` word to (re)gain frame alignment, then counts
up to `PACKET_LEN` (128) bytes per packet. It isn't wired into anything
today because it isn't needed for the Scapy/Npcap path, but it's a
drop-in `FrameSource`-style building block for that future scenario.

## Composing Layer 1-4 vs Layer 1-5 (or adding layers one at a time)

Per-frame processing (Layers 2-5) is an explicit `list[Stage]`
(`stages.py`), not baked into `pipeline.py`. Two ways to build that
list:

**Declarative**, by name, via `TaxiReceiverPipeline(..., max_stage=...)`:

```python
TaxiReceiverPipeline(frame_source, mode="camera", max_stage="monitor")     # Layer 1-4
TaxiReceiverPipeline(frame_source, mode="camera", max_stage="reassemble",  # Layer 1-5
                      reassembler=FrameReassembler())
```

`max_stage` is one of `"validate"` (1-2), `"parse"` (1-3), `"monitor"`
(1-4, the default), `"reassemble"` (1-5). Same knob on the CLI:
`--max-stage {validate,parse,monitor,reassemble}` (`--reassemble` is
just shorthand for `--max-stage reassemble`).

This is also the bring-up workflow for "adding layers one at a time":
start a real link with `max_stage="validate"` and an
`on_frame_processed` hook that prints `ctx.validation` to confirm
frames are arriving and passing the EtherType/MAC filter; once that
looks right, bump to `"parse"` and print `ctx.camera_result` to watch
CRC/parsing on a packet-by-packet basis; then `"monitor"` once you
trust the aggregate stats; then `"reassemble"` last. Nothing about
Layers 2/3 changes as you do this -- you're only changing which
stages are in the list.

**Manual / top-level**, by handing `TaxiReceiverPipeline` your own
list (bypasses `build_stage_chain` entirely, e.g. to insert a custom
debug stage, reorder something, or drop a layer that doesn't apply to
your setup):

```python
from taxi_receiver.stages import ValidationStage, ParsingStage, MonitoringStage

monitor = StreamMonitor()
pipeline = TaxiReceiverPipeline(
    frame_source, mode="camera",
    stages=[ValidationStage(monitor), ParsingStage("camera"), MonitoringStage(monitor)],
)
```

Either way, `pipeline.py` itself never branches on "how many layers" --
it only ever does `for stage in self.stages: stage.process(ctx)`.
Only `ValidationStage` can stop the chain early (not-our-traffic,
MAC-filtered, bad length); parse failures still flow through to
`MonitoringStage` so Layer 4's counters stay accurate regardless of
where you cap the chain.

## Layer 5 reassembly and atomic storage

`FrameReassembler` isolates `(cam_id, frame_id)` sessions, places rows
out of order, deduplicates identical packets, preserves the first copy
of a conflicting duplicate, closes an old camera frame when the next
frame ID arrives, and supports timeout/flush. A last-row packet does
not prematurely close a frame while earlier rows are still missing.
Every result is classified `COMPLETE`, `PARTIAL`, `CORRUPT`, or
`TIMEOUT`.

`StorageAndPipeline` is the `on_completed_frame` callback. It writes:

```text
output_root/
  summary.csv
  cam_<cam_id>/
    frame_<frame_id>/
      image.raw
      metadata.json
      packets.csv
      errors.json
```

The frame directory is first written with a `.tmp` name and atomically
renamed. It refuses to overwrite an existing frame. Width, height and
pixel format are not present in legacy-v0, so the receiver does not
create a fake PNG/PGM in this evidence archive.

For the confirmed 80-byte packed threshold-image path, supplying
`--images-root` also enables `CameraImagePipeline`:

```text
images/
  cam0/
    <frame_id>.pgm
    <frame_id>.raw
    <frame_id>.json
    rows.csv
  cam1/
    ...
```

The numeric file stem comes directly from header `frame_id`; `camN`
comes directly from `cam_id`. Only a `COMPLETE` frame is published as
PGM. CRC-invalid, missing-row, overflow, partial and timeout sessions
remain visible in telemetry/evidence but are not mislabeled as photos.

`rows.csv` is created on the first parsed row and records header/trailer
fields, sync/payload/CRC checks, raw flags, `m00`, Q4 centroid
coordinates and Q8 velocities plus converted values. The row itself is
always written, including validation failures. If and only if
`(row_flags & 0x02) == 0x02`, one real blank line is appended after that
row to separate the next frame.

The current wire flag map is fixed and must not be inferred from older
receiver counters:

| Mask | Meaning |
|---:|---|
| `0x01` | frame/line-buffer overflow |
| `0x02` | last row / frame end |
| `0x04` | first valid row / frame start |
| `0x08` | FPGA-observed line length error |

In particular, `0x04` is not overflow. A received `0x58` is not a new
flag definition: the live `attempt2` data shows it is consistent with a
one-byte-short row where `payload_len=0x50` shifted into the flag offset
and the FPGA then ORed in `0x08`. Use `analyze_rows_csv.py` for that
diagnosis; do not make the parser accept `0x58` as a valid control value.

Both `rows.csv` and `session_audit.csv` keep their file handle open and
flush in batches (256 rows or 0.5 seconds, plus a `rows.csv` flush at
LAST_ROW). They do not open/close or explicitly flush once per packet.
`run_receiver.ps1` uses a 65536-entry live queue by default to absorb
short host scheduling bursts; a nonzero `Capture queue drops` count is
still a failure signal, not something this buffer hides.

When `--output-root` is supplied, the CLI also attaches
`SessionAuditLogger` through `on_frame_processed` and writes:

```text
output_root/session_audit.csv
```

This is a side-band record for every processed packet, including Layer-3
failures. `row_flags_raw` preserves the received flag byte while
`row_flags_effective` propagates bit `0x08` through the remainder of the
same `(cam_id, frame_id)`. A large non-wrap rollback of `frame_id` or
`row_seq` is treated as a new board power-on and recreates the CSV with
`"w"` instead of appending evidence from the previous session.

Offline PCAP replay (does not require Scapy):

```powershell
.\replay_pcap.ps1 `
  -Pcap D:\prg\prg_cam\build\ethernet_ila\camera_live_0x88b5_20260724.pcapng `
  -OutputRoot D:\prg\prg_cam\build\receiver_output\camera_replay `
  -ImagesRoot D:\prg\prg_cam\build\receiver_images\camera_replay
```

PCAP replay is lossless at the receiver queue boundary: when the worker
cannot keep up with disk iteration, the replay source is backpressured
instead of incrementing `Capture queue drops`. Live capture deliberately
keeps the bounded non-blocking queue, because a real host overload must
remain visible in the final statistics instead of stalling the Npcap
callback.

Recursive live output monitoring:

```powershell
.\monitor_camera_output.ps1 `
  -OutputRoot D:\capture\archive `
  -ImagesRoot D:\capture\images
```

If the host blocks local scripts, use a process-local policy without
changing the machine policy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\replay_pcap.ps1 `
  -Pcap <capture.pcapng> -OutputRoot <output-directory>
```

Live capture requires Scapy/Npcap:

```powershell
python -m pip install -r .\requirements-live.txt
python -m taxi_receiver.cli --list

.\run_receiver.ps1 `
  -Interface "<Npcap interface name>" `
  -OutputRoot D:\prg\prg_cam\build\receiver_output\camera_live
```

For live capture, `run_receiver.ps1` defaults `ImagesRoot` to the
project-level `D:\prg\prg_cam\images`, so the pre-created `cam0` and
`cam1` directories are used automatically. Override `-ImagesRoot` for
an isolated test. The default threshold bit order is `msb_first`; pass
CLI `--bit-order lsb_first` only when the sender's packed-pixel order
has been confirmed to require it.

## Packet layout (packet_format.py)

The current wire layout uses MSB-byte-first header/trailer metadata and
a little-endian CRC16 tail regenerated by FPGA `Byte_Replacer`. The
RP2350A C/PIO source is not in this repository, so it must not be
described as a source-confirmed native C ABI:

| offset | bytes | field                                  |
|-------:|------:|-----------------------------------------|
| 0      | 2     | sync0 = word `0xA5A0`, wire `A5 A0`      |
| 2      | 2     | sync1 = word `0x5A50`, wire `5A 50`      |
| 4      | 1     | cam_id                                   |
| 5      | 2     | frame_id                                 |
| 7      | 2     | row_idx                                  |
| 9      | 1     | row_flags                                |
| 10     | 1     | payload_len                              |
| 11     | 2     | row_seq                                  |
| 13     | 11    | reserved                                 |
| 24     | 80    | payload (ROW_BYTES)                      |
| 104    | 10    | trailer pad                              |
| 114    | 4     | m00                                      |
| 118    | 2     | xc_q4                                    |
| 120    | 2     | yc_q4                                    |
| 122    | 2     | vx_q8 (signed)                           |
| 124    | 2     | vy_q8 (signed)                           |
| 126    | 2     | crc16 (covers bytes 0..125)              |

The expected four sync bytes are `A5 A0 5A 50`. The old Python `<`
struct displayed those same raw bytes as numeric values
`0xA0A5/0x505A`; that display was the byte-order bug. Current parsing
uses MSB-byte-first metadata but still reads CRC bytes 126/127 as
low/high, matching `Byte_Replacer`. This is not an MSB/LSB bit reversal.
The camera GPIO RTL preserves `GPIO[7:0]` without bit reversal.

Active FPGA RTL confirms only its owned replacements: `cam_id` at
offset 4, ORed `row_flags` at offset 9, and regenerated CRC at
126-127. The remaining field producers are pending RP2350A source
confirmation.

## Layer 6: recover threshold pixels at `on_completed_frame`

`threshold_recover.py` keeps the 80-byte rows packed through capture,
CRC checking and reassembly, then expands each bit to `0x00`/`0xFF`
only when a `CompletedFrame` reaches the business callback:

```python
from taxi_receiver.pipeline import TaxiReceiverPipeline
from taxi_receiver.reassembler import FrameReassembler
from taxi_receiver.threshold_recover import (
    BitOrder,
    MissingRowPolicy,
    ThresholdFrameRecoverer,
)

recovered_frames = []
recoverer = ThresholdFrameRecoverer(
    expected_rows=480,                 # use the real sensor height
    bit_order=BitOrder.MSB_FIRST,      # confirm this against FPGA packing
    missing_policy=MissingRowPolicy.REJECT,
    on_recovered_frame=recovered_frames.append,
)

pipeline = TaxiReceiverPipeline(
    frame_source=frame_source,
    mode="camera",
    max_stage="reassemble",
    reassembler=FrameReassembler(),
    on_completed_frame=recoverer,
)
```

Each `RecoveredThresholdFrame` contains row-major `pixels` with
`expected_rows * 640` bytes and preserves `camera_id`, `frame_id`,
`missing_rows` and `had_overflow`. With `ZERO_FILL`, missing rows become
640 zero bytes. With `REJECT` (the default), the pure
`recover_completed_frame()` function raises
`IncompleteThresholdFrameError`; the callback adapter catches that
condition so it is not miscounted as a parser error, and exposes
`rejected_frames`, `last_rejection` and `on_rejected_frame`.

The callback normally runs on the pipeline's only parser worker. A
storage, display or inference callback should therefore enqueue the
recovered object to another bounded worker instead of doing expensive
work inline. Shutdown `flush()` callbacks run from the thread calling
`pipeline.stop()`.
