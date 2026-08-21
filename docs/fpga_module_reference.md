# Active FPGA Module Reference

The links below point to the active source tree. Signal names are summarized from the module declarations and the current ready/valid implementation; legacy modules are intentionally excluded from the active table.

| Module | Inputs | Outputs | Flags/state | Clock/reset | Backpressure/data flow |
|---|---|---|---|---|---|
| [Camera_Ethernet_Top.sv](../prg_cam.srcs/sources_1/new/Camera_Ethernet_Top.sv) | board clocks, camera pins, PHY pins | Ethernet/RMII pins, debug outputs | top-level enables and debug observation | board clock/reset domains | connects camera pipeline to Ethernet subsystem |
| [Camera_Pipeline.v](../prg_cam.srcs/sources_1/new/Camera_Pipeline.v) | four camera data/PCLK/HREF groups, system control, sink ready | packet data/valid/last, camera metadata, diagnostics | lane selection and shared-path control | system clock plus synchronized camera events | muxes one granted lane and propagates sink ready |
| [Camera_Capture.v](../prg_cam.srcs/sources_1/new/Camera_Capture.v) | DATA[7:0], PCLK, HREF/packet_valid, reset | row bytes, valid/last, row/frame metadata, length/overflow flags | byte counter, row/frame counters, HREF history | synchronized PCLK event into sys_clk | stops accepting a row on invalid boundary or reset |
| [Line_Buffer.v](../prg_cam.srcs/sources_1/new/Line_Buffer.v) | row write stream, read ready, reset | request, packet byte/valid/last, metadata, overflow diagnostics | wr_ptr, rd_ptr, used_count, committed_count | system clock | full drops a complete incoming row; read stalls preserve pointers |
| [Arbitration.v](../prg_cam.srcs/sources_1/new/Arbitration.v) | four requests, per-lane data/valid/last, sink ready | one-hot grant, selected stream, release | round-robin pointer and packet lock | system clock/reset | grant remains stable until final accepted byte |
| [Byte_Replacer.v](../prg_cam.srcs/sources_1/new/Byte_Replacer.v) | selected 128-byte stream and metadata | modified byte stream, valid/ready/last | byte index, CRC accumulator, status merge | system clock/reset | byte index and CRC hold while downstream is stalled |
| [Byte_FIFO.v](../prg_cam.srcs/sources_1/new/Byte_FIFO.v) | upstream data/valid/last, downstream ready, reset | downstream data/valid/last, ready, occupancy | TX write, RX read, CNT occupancy | system clock/reset | full deasserts ready; last is stored with its byte |
| [Ethernet_Frame_Adapter.sv](../prg_cam.srcs/sources_1/new/Ethernet_Frame_Adapter.sv) | packet stream, MAC ready | Ethernet frame stream with last | frame/header counters | MAC clock/reset domain | ready/valid/last handshake to MAC |
| [Taxi_Ethernet_Subsystem.sv](../prg_cam.srcs/sources_1/new/Taxi_Ethernet_Subsystem.sv) | MAC-side stream, clock/reset, PHY-side signals | MII/RMII-side transmit/receive and status | Taxi MAC/FIFO internal state | Ethernet clock domains | preserves MAC handshake and PHY flow control |
| [Ethernet_Mii_Rmii_Bridge.sv](../prg_cam.srcs/sources_1/new/Ethernet_Mii_Rmii_Bridge.sv) | MII-side TX stream, RMII clock/reset | RMII two-bit TX and PHY control | serial phase and transmit valid | RMII clock/reset domain | emits only accepted MAC bytes |

## Implicit state convention

`Camera_Capture`, `Line_Buffer`, `Arbitration`, `Byte_Replacer`, and `Byte_FIFO` do not require a single explicit state register for their main flow. Their effective states are combinations of counters, valid/ready handshakes, HREF history, pointer/count relations, grant lock, byte index, and CRC accumulator. The equivalent transitions are: idle to capture on a valid PCLK/HREF event; capture to commit on HREF falling; request to grant on a nonzero committed count; grant to release on `valid && ready && last`; and FIFO occupancy changes on independent accepted write/read events.

## Diagnostic ownership

Sender flags remain in the source row-flags field. FPGA-owned overflow, ingress length error, and ingress CRC error are carried in the FPGA diagnostic status field. Byte_Replacer regenerates the egress CRC after FPGA-owned fields are final, so the Host can distinguish an ingress failure from an egress corruption.
