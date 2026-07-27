# Taxi Camera Receiver 第一阶段事实报告

> 状态：Stage 1 / 只读扫描完成  
> 日期：2026-07-24  
> 工程根目录：`D:\prg\prg_cam`  
> 本阶段没有修改 RTL、Taxi core、XDC、XCI、Block Design、Vivado 工程设置或 Python 源码。

> 后续状态更新：主机 Python 环境安装后，原有 27 项与新增 10 项标准库
> PCAP 测试已连续两次全量通过。本文中历史性的
> `PENDING_ENVIRONMENT` 已由
> [`receiver_validation_report.md`](receiver_validation_report.md)
> 的 37-test 基线取代。

## 1. 结论摘要

### 1.1 当前能够确认的事实

1. 当前工程顶层是 `Camera_Ethernet_Top`，其参数默认值为
   `USE_CAMERA_PIPELINE=1`。因此当前默认活动发送源不是固定发生器，而是
   `Camera_Pipeline` 的内部 `Byte_FIFO` 输出。
2. 当前活动发送链为：

   ```text
   RP2350A GPIO byte/PCLK/HREF
       -> Camera_Capture
       -> Line_Buffer
       -> Arbitration + one-hot mux
       -> Byte_Replacer
       -> Camera_Pipeline 内部 Byte_FIFO
       -> Ethernet_Frame_Adapter
       -> Taxi_Ethernet_Subsystem
       -> Taxi TX FIFO / CDC / MII MAC
       -> Ethernet_Mii_Rmii_Bridge
       -> RMII PHY
       -> PC NIC
   ```

3. 两份现有 PCAP 都只包含固定诊断 payload `00 01 ... 7F`：

   | PCAP | 0x88B5 帧数 | 帧长 | 非 `00..7F` payload |
   |---|---:|---:|---:|
   | `wireshark_fixed_1000.pcapng` | 1,000 | 全部 142 byte | 0 |
   | `internal_byte_fifo_0x88b5.pcapng` | 229,629 | 全部 142 byte | 0 |

   两者均为 `FF:FF:FF:FF:FF:FF <- 02:00:00:00:00:02`、EtherType
   `0x88B5`、128-byte payload。它们证明固定/内部 Byte FIFO 测试链，
   **不证明 Camera 数据已经到达 PC**。
4. 与上述旧 PCAP 不同，当前
   [`build/ethernet_ila/iladata.ila`](../../../../build/ethernet_ila/iladata.ila)
   内嵌的 ILA 波形包含 Camera 探针，并捕获到：

   - 142 次 `frame_valid && frame_ready`；
   - 128 次 `packet_valid && packet_ready`；
   - 最后一次 packet/frame 握手的 `last=1`；
   - 随后的 `rmii_tx_en_dbg=1` 活动；
   - `tx_error_underflow=0`、`tx_fifo_overflow=0`；
   - 一次 `tx_fifo_good_frame` 脉冲。

   `tx_fifo_good_frame` 只表示 Taxi TX FIFO 接受/提交了好帧，不能解释为
   PHY 已经在线缆上发送成功，也不能解释为 PC 已收到。
5. 从该 ILA 波形恢复出的 Camera payload 是 128 byte，现有
   `packet_format.py` 能将它解析为：

   ```text
   sync0       = 0xA5A5
   sync1       = 0x5A5A
   cam_id      = 0
   frame_id    = 2073
   row_idx     = 330
   row_flags   = 0x08  (LENGTH_ERROR)
   payload_len = 80
   row_seq     = 12330
   crc16       = 0xB753
   calculated  = 0xB753
   ```

   因而不能把当前情况笼统标为“全部 Camera metadata 缺失”。至少一个
   FPGA 内部硬件捕获已经观察到 `cam_id/frame_id/row_idx/row_seq/CRC`。
   但是：

   - 该 Camera payload 尚未出现在当前 PCAP 中；
   - `frame_id/row_idx/row_seq` 的 RP2350A 生成源码不在本仓库；
   - 协议版本、图像宽高、像素格式和 `line_byte_offset` 不在当前包定义中；
   - 单包 `LENGTH_ERROR=1` 表明 Camera 输入包长仍有硬件问题。
6. `taxi_receiver_advanced` 已有 Layer 1～Layer 6 原型，但还不是用户要求的
   完整接收与归档程序。特别是 Layer 5 只在内存中拼行，没有规定目录、
   原子写入、`summary.csv`、结构化错误文件、超时关闭和完整性状态。
7. 当前 Windows 的 `python` 只是 Microsoft Store alias；Vivado 自带
   Python 3.13.0 不含 `pytest` 或 `scapy`。因此现有 27 个测试本阶段未能
   运行，状态为 `PENDING_ENVIRONMENT`，不能沿用 README 中“已验证”的文字
   作为本次验证证据。

### 1.2 阶段门结论

| 项目 | 状态 | 结论 |
|---|---|---|
| 文件/源码/文档/报告/抓包扫描 | PASS | 已完成第一阶段事实扫描 |
| 固定 0x88B5 PCAP 的 Layer 1/2 可解析性 | PASS（由 tshark 复核） | 两份 PCAP 都是固定 `00..7F` |
| Camera metadata 在 FPGA 内部出现 | PASS（单包 ILA 证据） | schema 与现有 Python 布局吻合，CRC 正确 |
| Camera payload 到达 PC | PENDING | 没有 Camera PCAP |
| Camera 行长度 | FAIL（该 ILA 样本） | `row_flags[3]=LENGTH_ERROR` |
| 完整 Camera 图像重建 | PENDING | 没有多行/多帧 Camera PCAP，存储层未实现 |
| 现有 Python 测试 | PENDING_ENVIRONMENT | 缺少可用 pytest/scapy 环境 |
| GUI bit 与 ILA bit 根因 | PENDING | 已列出差异，但现有证据不足以证明根因 |
| 进入 Stage 2 | AWAITING_REVIEW | 按任务要求，先停在本报告 |

## 2. 扫描范围与证据优先级

本报告按以下优先级取证：

```text
当前源码 > 当前 ILA/PCAP/报告 > 当前日志 > 当前工程/XPR状态
        > 旧 Markdown > README 中未经复核的描述
```

扫描过的项目相关范围：

| 范围 | 数量 | 说明 |
|---|---:|---|
| `sources_1/new` | 27 | 21 `.v`、5 `.sv`、1 README |
| `taxi_receiver_advanced/taxi_receiver` | 22 | 21 `.py`、1 README |
| `scripts` | 14 | 项目 Tcl |
| `constrs_1` | 4 | 项目 XDC |
| `sim_1` | 9 | 自研 SystemVerilog testbench |
| `docs` | 26 | 当前项目 Markdown |
| 本地 Taxi | 单独按入口/引用链检查 | 未把 Taxi 示例工程当成本项目活动层次 |

同时检查了：

- `prg_cam.xpr`；
- `build/ethernet_ila/prg_cam_ila.xpr`；
- GUI 与 ILA 的 bit/DCP/ltx 时间戳和 SHA-256；
- `build/ethernet_ila` 中的 PCAP、CSV 和 `.ila`；
- 当前 Vivado/XSim 报告和日志；
- 当前 Git 工作区状态。

工作区在本次任务开始前已经存在未提交修改和未跟踪文件。本阶段没有清理、
覆盖或回退这些内容。

## 3. 当前真实发送链

### 3.1 顶层数据源选择

[`Camera_Ethernet_Top.sv`](../../new/Camera_Ethernet_Top.sv#L15)
定义：

```systemverilog
parameter bit USE_CAMERA_PIPELINE = 1'b1;
```

默认情况下：

```text
packet_data  = camera_packet_data
packet_valid = camera_packet_valid
packet_last  = camera_packet_last
camera_packet_ready = packet_ready
fixed_path_packet_ready = 0
```

证据见
[`Camera_Ethernet_Top.sv:205-213`](../../new/Camera_Ethernet_Top.sv#L205)。
固定发生器仍被实例化，但在 Camera 模式下不获得 `ready`。它是诊断回退路径，
不是默认活动源。

### 3.2 Camera 到 Byte FIFO

[`Camera_Pipeline.v`](../../new/Camera_Pipeline.v#L18) 内部完成：

```text
4 x Camera_Capture
    -> 4 x Line_Buffer
    -> Arbitration
    -> one-hot data/cam_id/flags mux
    -> Byte_Replacer
    -> Byte_FIFO
    -> packet_data/valid/ready/last
```

关键边界：

| 边界 | 数据 | 时钟/握手 |
|---|---|---|
| GPIO -> `Camera_Capture` | 8-bit byte、PCLK、HREF | PCLK/HREF 被同步到 `sys_clk` 后检测 |
| `Camera_Capture` -> `Line_Buffer` | byte、valid、line_end、cam_id、flags | `sys_clk=100 MHz` |
| `Line_Buffer` -> arbitration mux | 8-bit byte、valid/ready/last、cam_id、flags | `sys_clk` |
| mux -> `Byte_Replacer` | 8-bit byte及行 metadata | 只在 `valid && ready` 推进 offset/CRC |
| `Byte_Replacer` -> `Byte_FIFO` | `{packet_last, data[7:0]}` | 9-bit FIFO word |
| `Byte_FIFO` -> Adapter | 8-bit packet data、valid/ready/last | `sys_clk` |

`Camera_Capture` 有内部 `row_idx`，但是
[`Camera_Pipeline.v:93/103/113/123`](../../new/Camera_Pipeline.v#L93)
把 `current_row_idx` 端口留空。这个内部计数没有直接写入 payload 的 offset
7～8；它只参与 FIRST/LAST 行 flag 的生成。

### 3.3 Frame Adapter

[`Ethernet_Frame_Adapter.sv`](../../new/Ethernet_Frame_Adapter.sv#L31)
在每个 128-byte packet 前增加 14-byte Ethernet II header：

| Ethernet byte offset | 长度 | 内容 |
|---:|---:|---|
| 0 | 6 | `FF FF FF FF FF FF` |
| 6 | 6 | `02 00 00 00 00 02` |
| 12 | 2 | `88 B5`，网络字节序 |
| 14 | 128 | Camera/固定 payload |

HEADER 状态 `packet_ready=0`；PAYLOAD 状态把 packet 侧与 frame 侧直接映射。
只有最后一个 payload byte 的真实握手携带 `frame_last=1`。相关逻辑见
[`Ethernet_Frame_Adapter.sv:50-70`](../../new/Ethernet_Frame_Adapter.sv#L50)
和
[`Ethernet_Frame_Adapter.sv:93-106`](../../new/Ethernet_Frame_Adapter.sv#L93)。

### 3.4 Taxi AXI-Stream、TX FIFO、CDC 与 MAC

[`Taxi_Ethernet_Subsystem.sv`](../../new/Taxi_Ethernet_Subsystem.sv#L31)
只在 wrapper 内使用 `taxi_axis_if`：

```text
frame_data  -> s_axis_tx.tdata[7:0]
frame_valid -> s_axis_tx.tvalid
frame_ready <- s_axis_tx.tready
frame_last  -> s_axis_tx.tlast
tkeep/tstrb = 1
tuser/tid/tdest = 0
```

当前本地 `taxi_eth_mac_mii_fifo` 没有 `DATA_W` 参数；wrapper 只传
`VENDOR="XILINX"`、`FAMILY="artix7"`、`STAT_EN=0`。证据见
[`Taxi_Ethernet_Subsystem.sv:70-90`](../../new/Taxi_Ethernet_Subsystem.sv#L70)。

Taxi 的 TX async FIFO 位于
[`taxi_eth_mac_mii_fifo.sv:364`](../../lib/taxi-master/eth/rtl/taxi_eth_mac_mii_fifo.sv#L364)，
负责从 100 MHz logic side 跨到 25 MHz MII TX 域。MAC 负责前导码、SFD、
必要 padding、Ethernet CRC-32/FCS 和 IFG；这些不属于 128-byte Camera
payload。

PC NIC/Scapy 当前看到的 142 byte 是：

```text
14-byte Ethernet header + 128-byte Camera payload
```

前导码、SFD 和通常的 Ethernet FCS 不由 libpcap 作为 payload 交给 Python。
Camera packet 自己在 offset 126～127 的 CRC-16 与 Ethernet FCS 是两种完全
不同的校验，禁止混用。

### 3.5 MII、RMII 和 PHY

[`Ethernet_Mii_Rmii_Bridge.sv`](../../new/Ethernet_Mii_Rmii_Bridge.sv#L44)
实例化本地 `rmii_phy_if`：

```text
Taxi MII: 4-bit @ 25 MHz
    -> rmii_phy_if
RMII: 2-bit @ 50 MHz
    -> ETH_TXD[1:0], ETH_TXEN
```

顶层在 `phy_ref_clk` 下降沿寄存 RMII TX 数据，并通过 ODDR 转发
`ETH_REFCLK`。证据见
[`Camera_Ethernet_Top.sv:307-339`](../../new/Camera_Ethernet_Top.sv#L307)。

## 4. 当前 PC 接收链

### 4.1 Layer 1～Layer 5 文件和状态

| Layer | 文件/入口 | 输入 | 输出 | 当前状态 |
|---|---|---|---|---|
| 1 Capture | [`capture.py`](taxi_receiver/taxi_receiver/capture.py#L27) | live NIC、PCAP 或 synthetic objects | `RawEthernetFrame` | 三个 source class 已有；CLI 只接 live |
| 2 Ethernet decode/validate | [`eth_validate.py`](taxi_receiver/taxi_receiver/eth_validate.py#L29) | `RawEthernetFrame` | `ValidationResult` | 校验 EtherType、可选 src MAC、46～1500 payload；未显式校验 dst MAC/原始 header 长度 |
| 3 Camera packet decode | [`packet_format.py`](taxi_receiver/taxi_receiver/packet_format.py#L121)、[`camera_parser.py`](taxi_receiver/taxi_receiver/camera_parser.py#L37) | 128-byte payload | `CameraRowPacket` 或 result | struct/CRC 已有；magic、version、payload_len 范围等验证不足 |
| 4 Monitor | [`stream_monitor.py`](taxi_receiver/taxi_receiver/stream_monitor.py#L67) | parse result | 内存统计和文本报告 | 有 seq gap/dup/ooo、CRC/长度/queue 计数；不是结构化日志 |
| 5 Reassembly | [`reassembler.py`](taxi_receiver/taxi_receiver/reassembler.py#L71) | CRC-OK `CameraRowPacket` | `CompletedFrame` | 按 `(cam_id, frame_id)` 分组；没有 timeout、完整性枚举或文件归档 |

辅助模块：

| 文件 | 当前用途 | 缺口 |
|---|---|---|
| [`stages.py`](taxi_receiver/taxi_receiver/stages.py#L154) | 组装 validate/parse/monitor/reassemble | 基本可复用 |
| [`pipeline.py`](taxi_receiver/taxi_receiver/pipeline.py#L33) | bounded queue + 单 worker | stop 超时后仍可能 flush；没有结构化生命周期记录 |
| [`recorder.py`](taxi_receiver/taxi_receiver/recorder.py#L12) | PCAP 和坏 payload `.bin` | 不等于图像归档层 |
| [`cli.py`](taxi_receiver/taxi_receiver/cli.py#L23) | live capture CLI | 无 PCAP replay/synthetic CLI、无 source-MAC 参数 |
| [`threshold_recover.py`](taxi_receiver/taxi_receiver/threshold_recover.py#L115) | 80 packed bytes -> 640 个 00/FF byte | 640-pixel、bit order、height 尚未由当前 RTL/PCAP 完整证明 |

### 4.2 Layer 1 实际入口

`capture.py` 已有：

- `ScapyLiveCapture(interface, ether_type=0x88B5)`；
- `PcapReplayFrameSource(path, ether_type)`；
- `SyntheticFrameSource(frames)`；
- `list_interfaces()`。

live BPF 是 `ether proto 0x88b5`，见
[`capture.py:81-84`](taxi_receiver/taxi_receiver/capture.py#L81)。
接口名称不是硬编码数字，但 `cli.py` 要求用户传 `--interface`。

当前 CLI 实际只能这样启动 live capture：

```powershell
python -m taxi_receiver.cli --list
python -m taxi_receiver.cli --interface "<Npcap interface>" --mode fixed
python -m taxi_receiver.cli --interface "<Npcap interface>" --mode camera --max-stage monitor
```

`PcapReplayFrameSource` 和 `SyntheticFrameSource` 没有接入 CLI，当前需要从
Python API 手工构造。

### 4.3 Layer 3 的实际校验行为

当前 `parse_camera_row()`：

- 要求 payload 精确为 128 byte；
- 按 little-endian struct 解包；
- 计算 bytes 0～125 的 CRC-16-CCITT-FALSE；
- 输出 `crc_ok`；
- 从 `row_flags` 派生 first/last/overflow/length_error。

当前没有拒绝：

- 错误 `sync0/sync1`；
- 未知协议版本（当前根本没有 version 字段）；
- 非法 `payload_len`；
- 非零 reserved/pad；
- 超范围的 camera/row/frame 值。

因此“CRC 恰好正确”目前可能使一个不符合期望 schema 的包继续进入重组。

### 4.4 Layer 4 的实际统计

`StreamMonitor` 按 camera 记录 `row_seq` gap、duplicate 和
out-of-order，见
[`stream_monitor.py:99-146`](taxi_receiver/taxi_receiver/stream_monitor.py#L99)。
它统计的是包序号现象，不负责实际去重或放置 payload。

当前输出为人读文本，不是 JSON/CSV 结构化日志。

### 4.5 Layer 5 的实际行为

`FrameReassembler` 使用 `(cam_id, frame_id)` 为 key，这一点符合目标。
它把 `rows[row_idx] = payload`，所以天然可以按 row index 接受乱序。

但当前实现有以下缺口：

1. 相同 `row_idx` 会静默覆盖，未区分相同 duplicate 和冲突 duplicate；
2. 没有 packet timestamp 和 frame timeout；
3. 新 frame 到来不会按规则关闭旧 frame；
4. `missing_rows` 只检查 `0..max(received row)`，无法识别缺失尾行；
5. 内存上限淘汰会直接删除旧 session，没有产生可交付的
   `TIMEOUT/PARTIAL` 记录；
6. 没有 `COMPLETE/PARTIAL/CORRUPT/TIMEOUT` 枚举；
7. 没有 `output_root/cam_x/frame_y` 存储；
8. 没有 `.raw`、`metadata.json`、`packets.csv`、`errors.json`、
   `summary.csv`；
9. 没有临时目录 + atomic rename。

因此当前 Layer 5 是重组原型，不是目标 StorageAndPipeline。

## 5. 当前 128-byte Camera payload 字段表

### 5.1 Ethernet、Camera header 和 FCS 边界

```text
PC-visible Ethernet frame:

offset 0..5     destination MAC
offset 6..11    source MAC
offset 12..13   EtherType 0x88B5
offset 14..141  128-byte Camera payload

wire-only / normally stripped before Scapy:
preamble + SFD
Ethernet CRC-32 FCS
```

Camera payload 自身：

| Payload offset | 长度 | Python 字段 | 当前 ILA 值 | RTL 内的真实来源 |
|---:|---:|---|---|---|
| 0 | 2 | `sync0` | `A5 A5` | 外部输入 byte 原样穿过；本仓库 RTL 不生成 |
| 2 | 2 | `sync1` | `5A 5A` | 外部输入 byte 原样穿过；本仓库 RTL 不生成 |
| 4 | 1 | `cam_id` | `00` | `Byte_Replacer` 用仲裁 camera ID 覆盖 |
| 5 | 2 | `frame_id` LE | `19 08` = 2073 | 外部输入原样穿过；RP2350A 生成源码不在仓库 |
| 7 | 2 | `row_idx` LE | `4A 01` = 330 | 外部输入原样穿过；`Camera_Capture.current_row_idx` 没接到这里 |
| 9 | 1 | `row_flags` | `08` | 外部原值 OR FPGA FIRST/LAST/LENGTH flags |
| 10 | 1 | `payload_len` | `50` = 80 | 外部输入原样穿过 |
| 11 | 2 | `row_seq` LE | `2A 30` = 12330 | 外部输入原样穿过 |
| 13 | 11 | `reserved` | 全 0 | 外部输入原样穿过 |
| 24 | 80 | packed row payload | 80 byte | 外部输入原样穿过 |
| 104 | 10 | trailer pad | 全 0 | 外部输入原样穿过 |
| 114 | 4 | `m00` LE | `00 CF 06 06` | 外部输入原样穿过 |
| 118 | 2 | `xc_q4` LE | `00 00` | 外部输入原样穿过 |
| 120 | 2 | `yc_q4` LE | `FF 18` | 外部输入原样穿过 |
| 122 | 2 | `vx_q8` LE signed | `AC 09` | 外部输入原样穿过 |
| 124 | 2 | `vy_q8` LE signed | `00 00` | 外部输入原样穿过 |
| 126 | 2 | Camera CRC-16 LE | `53 B7` = `0xB753` | FPGA `Byte_Replacer` 重新计算并覆盖 |

上述布局定义见
[`packet_format.py:28-63`](taxi_receiver/taxi_receiver/packet_format.py#L28)；
ILA 的单包值来自
[`iladata.ila`](../../../../build/ethernet_ila/iladata.ila) 内部
`waveform.csv` 的 128 次 packet handshake。

### 5.2 ILA 恢复出的完整 payload

```text
a5a55a5a0019084a0108502a3000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000
0000003fffe0e0000000000000000000000000000000000000000000000000000
00000000000000000000000000cf06060000ff18ac09000053b7
```

现有 `crc16_ccitt_false()` 对 bytes 0～125 的计算结果与尾部
`0xB753` 一致。

### 5.3 字段存在性和 `METADATA_MISSING`

| 目标字段 | 当前状态 | 证据/说明 |
|---|---|---|
| magic | PRESENT（`sync0/sync1`） | 单包 ILA 为 `A5A5/5A5A` |
| version | **METADATA_MISSING** | schema 和 RTL 都无版本字段 |
| cam_id | PRESENT | offset 4，由 FPGA 覆盖 |
| image_frame_id | PRESENT_IN_ILA | offset 5～6；上游生成代码缺失 |
| line_id / row_idx | PRESENT_IN_ILA | offset 7～8；上游生成代码缺失 |
| packet_index / row_seq | PRESENT_IN_ILA | offset 11～12；上游生成代码缺失 |
| line_byte_offset | **METADATA_MISSING** | 当前协议假定一包是一行 payload |
| valid_payload_len | PRESENT | offset 10 |
| line_end | IMPLICIT | 每个 128-byte packet 的 byte 127 携带 AXIS `packet_last` |
| frame_end | PRESENT_AS_FLAG | `row_flags[1]`；仅源码定义，当前样本未置位 |
| Camera payload CRC-16 | PRESENT | offset 126～127，FPGA 重算 |
| image width/height | **METADATA_MISSING** | 当前包未携带 |
| pixel format/bit order | **METADATA_MISSING** | Python 的 1-bit/640-pixel 假设尚未硬件闭环 |

## 6. `cam_id/frame_id/line_id/CRC/last` 的 RTL 溯源

### 6.1 `cam_id`

1. `Camera_Capture` 输出常量 `CAM_ID`，见
   [`Camera_Capture.v:70`](../../new/Camera_Capture.v#L70)；
2. `Line_Buffer` 每个 slot 保存 `cam_id`；
3. arbitration mux 同步选择 data、cam_id 和 flags；
4. `Byte_Replacer` 在 offset 4 输出 `{6'd0, in_cam_id}`，见
   [`Byte_Replacer.v:73-76`](../../new/Byte_Replacer.v#L73)。

结论：offset 4 的 `cam_id` 是当前 RTL 能完全溯源的 metadata。

### 6.2 `frame_id`

offset 5～6 不在 `Byte_Replacer` 的修改列表中，因此来自 GPIO 输入包并原样
穿过 Camera Capture/Line Buffer/mux。仓库内没有 RP2350A 发送端 C/C++ 源码，
不能从本仓库证明它的计数、回绕或复位策略。

结论：字段在当前 ILA 单包中存在，但生成来源为
`UPSTREAM_SOURCE_NOT_IN_REPOSITORY`。

### 6.3 `line_id / row_idx`

`Camera_Capture` 自己维护一个 16-bit `row_idx`，见
[`Camera_Capture.v:67`](../../new/Camera_Capture.v#L67)，但顶层 pipeline
没有把该值送入 payload。offset 7～8 仍是外部输入包的原值。

结论：当前 ILA 中 `row_idx=330`，但它不是 FPGA 内部 row counter 写入的。

### 6.4 Camera CRC-16

`Byte_Replacer`：

- 对最终被发送的 bytes 0～125 计算 CRC-16-CCITT-FALSE；
- 初值 `0xFFFF`，poly `0x1021`，不反射，无 final xor；
- offset 126 输出低 byte；
- offset 127 输出高 byte。

证据见
[`Byte_Replacer.v:43-58`](../../new/Byte_Replacer.v#L43) 和
[`Byte_Replacer.v:84-101`](../../new/Byte_Replacer.v#L84)。

### 6.5 `last` 的三种含义

必须区分：

1. `row_flags[1]`：图像的 LAST_ROW/frame end；
2. `packet_last`：128-byte Camera packet 的 byte 127；
3. `frame_last`/AXIS `tlast`：完整 Ethernet frame 的最后一个 payload byte。

当前 `Byte_Replacer` 按 byte index 127 产生 `packet_last`，见
[`Byte_Replacer.v:89-92`](../../new/Byte_Replacer.v#L89)。
`Byte_FIFO` 将 `{last,data}` 一起存储，
[`Camera_Pipeline.v:269-289`](../../new/Camera_Pipeline.v#L269)。
Adapter 在 payload handshake 时把它映射为 `frame_last`。

不能用 AXIS `tlast` 推断这是整张图像的最后一行。

## 7. 现有 ILA/PCAP 证据

### 7.1 旧固定链 PCAP

| 文件 | 修改时间 | 结论 |
|---|---|---|
| `wireshark_fixed_1000.pcapng` | 2026-07-22 16:05 | 1,000 个固定帧 |
| `internal_byte_fifo_0x88b5.pcapng` | 2026-07-22 19:13 | 229,629 个固定帧 |

本阶段用 tshark 对每一帧检查 frame length、MAC、payload 长度和完整
`00..7F` 内容，异常数均为 0。

### 7.2 旧固定链 CSV

[`frame_handshake_capture.csv`](../../../../build/ethernet_ila/frame_handshake_capture.csv)
修改时间为 2026-07-22 20:05，只含 23 个旧探针，包括
`fixed_packet_*`，不含 Camera GPIO/Camera pipeline probes。

### 7.3 当前 Camera ILA 数据

[`iladata.ila`](../../../../build/ethernet_ila/iladata.ila) 修改时间为
2026-07-23 11:39。它是 ZIP 容器，内部有：

- `waveform.csv`；
- `waveform.vcd`；
- `waveform.wdb`；
- `probes.ltx`；
- ILA waveform config。

该 capture 共 4096 个 100 MHz samples，关键统计：

| 信号/事件 | 统计 |
|---|---:|
| `frame_handshake` | 142 samples |
| packet real handshake | 128 samples |
| `frame_last && frame_handshake` | 1 sample |
| `packet_last && packet_valid && packet_ready` | 1 sample |
| `rmii_tx_en_dbg=1` | 1232 samples |
| `camera_pclk_dbg=1` | 545 samples |
| `camera_href_dbg=1` | 1091 samples |
| `camera_arb_grant=1` | 129 samples |
| `camera_overflow_pulse != 0` | 0 |
| `camera_drop_count_0` | 始终 0 |
| `tx_error_underflow != 0` | 0 |
| `tx_fifo_overflow != 0` | 0 |
| `tx_fifo_good_frame=1` | 1 sample |

这证明在该次硬件捕获里，Camera 输入活动产生了一个完整的 Adapter AXIS
frame，并进入 Taxi/RMII 内部链。它仍不能替代 PC 端 Camera PCAP。

特别需要处置的异常是 payload offset 9 为 `0x08`，即 FPGA 检测到
`LENGTH_ERROR`。在进行图像重建验收前，必须确认 RP2350A 的 HREF 窗口内
到底输出多少个 PCLK byte，以及它是否与 `PACKET_BYTES=128` 一致。

## 8. GUI bit 与 ILA bit 的构建差异

### 8.1 相同项

本阶段比较
[`prg_cam.xpr`](../../../../prg_cam.xpr) 和
[`build/ethernet_ila/prg_cam_ila.xpr`](../../../../build/ethernet_ila/prg_cam_ila.xpr)：

- 两者各有 63 个 `<File Path=...>` 条目，集合完全相同；
- top 都是 `Camera_Ethernet_Top`；
- part 都是 `xc7a50ticsg324-1L`；
- `synth_1` 都声明 `SrcSet=sources_1`、`ConstrsSet=constrs_1`；
- `impl_1` 都声明 `ConstrsSet=constrs_1`；
- 两者都引用 `nexys_a7_ethernet.xdc`。

源码时间顺序：

```text
Camera_Ethernet_Top.sv modified         2026-07-23 10:55:48
ILA synth DCP                           2026-07-23 10:57:07
ILA routed DCP                          2026-07-23 11:00:37
ILA bit                                 2026-07-23 11:00:48
GUI synth DCP                           2026-07-23 11:11:38
GUI routed DCP                          2026-07-23 11:12:37
GUI bit                                 2026-07-23 11:31:03
```

当前文件时间没有显示这段窗口内又修改活动 RTL/XDC，但构建时没有生成
源码 hash manifest，所以不能把“同一源码快照”提升为密码学意义上的证明。

### 8.2 不同项

| 项目 | ILA build | GUI run build |
|---|---|---|
| 入口 | `scripts/build_ethernet_ila.tcl` | `synth_1 -> impl_1 -> write_bitstream` |
| 综合方式 | 脚本直接 `synth_design` 后插入 debug core | project run |
| ILA | `u_ila_ethernet_bringup`，35 probes | 没有 `.ltx`，普通 bit |
| BoardPart | ILA project copy 中清空 | Digilent Nexys A7 board part |
| incremental run 属性 | XPR 中仍存在，但直接 `synth_design` 不等于 run | `synth_1` 挂有旧 `AXI4_Compiler.dcp` incremental checkpoint |
| routed DCP 大小 | 3,734,499 byte | 813,838 byte |
| bit SHA-256 | `CC96A491...B7DD13` | `87AD6B4F...FB73C1` |
| bit 大小 | 2,192,146 byte | 2,192,146 byte |

ILA 配对文件：

```text
Camera_Ethernet_Top_ila.bit
SHA256 CC96A491BE5F6B6483C0C598FD8A8E24E8B54A739E67FFE01D57F43E99B7DD13

Camera_Ethernet_Top_ila.ltx
SHA256 DA444A0E888BF9665FBA1F12910FFDE8ED65C3B7608999EB71F76DFF321C1EB6
```

GUI bit：

```text
prg_cam.runs/impl_1/Camera_Ethernet_Top.bit
SHA256 87AD6B4FB06C6CF69FDD39DFF5EEF791977C1348FC10F501B3D8532F5AFB73C1
```

当前 `prg_cam.runs` 下没有 `.ltx`。因此“run 目录下带 ILA 的 bit/ltx”
与当前文件系统不完全一致：ILA pair 实际位于 `build/ethernet_ila`，GUI
普通 bit 位于 `prg_cam.runs/impl_1`。

### 8.3 证据不能支持的推论

旧固定 PCAP 的时间早于当前 Camera ILA bit 一天。因此不能直接宣称这两份
PCAP 是由当前 2026-07-23 Camera/ILA bit 生成的。

当前证据也不能证明“ILA 是 Ethernet 的功能依赖”。ILA 改变布局布线和
实现结果，但设计功能上不应依赖 ILA。GUI/ILA 差异的根因需要后续在冻结的
源码/XDC snapshot 上做受控 A/B build，并记录：

- source/XDC SHA-256 manifest；
- top、part、SrcSet、ConstrSet；
- 是否使用 incremental checkpoint；
- post-route timing、CDC、DRC；
- bit/DCP hash；
- 同一物理接线下的 ILA/PCAP 结果。

## 9. 现有测试与缺口

当前 `tests/` 有 27 个 `test_*`：

- packet size、round-trip、CRC 和 byte-stream framer；
- fixed parser 正常/坏长度/坏数据；
- Camera CRC error；
- monitor gap/duplicate/out-of-order；
- reassembler complete/missing/flush；
- stage depth；
- synthetic pipeline；
- threshold bit order、缺行策略和 callback。

当前没有覆盖用户要求的完整集合：

- 两 camera 交错重组；
- reassembler 的真实乱序放置；
- duplicate 相同/冲突分类；
- frame ID 回绕；
- timeout 关闭；
- 新 frame 到来关闭旧 frame；
- PCAP replay CLI；
- 当前固定 PCAP 的自动 Layer 1/2 回归；
- synthetic PCAP -> raw reference 的 byte-for-byte integration；
- 文件目录/atomic rename/summary；
- live 1000-frame receiver workflow。

本阶段尝试运行：

```powershell
python -m pytest -p no:cacheprovider -q
```

结果：

```text
Windows python.exe = Microsoft Store alias，不能启动真实解释器
Vivado Python 3.13.0 = 可启动，但 No module named pytest
Vivado Python 3.13.0 = No module named scapy
```

本阶段按“禁止在线下载”的既有工程约束，没有安装依赖。

## 10. 最小可行协议建议（只建议，不实施）

### 10.1 兼容当前硬件的 v0

现有 ILA 表明当前 128-byte schema 不是纯猜测，至少一个真实硬件包与它吻合。
因此 Stage 2 不应重新发明整个协议。建议先把当前布局冻结为
`legacy-v0-observed`：

- `sync0=A5A5`、`sync1=5A5A` 作为 4-byte magic；
- cam/frame/row/flags/payload_len/row_seq 保持当前 offsets；
- packed payload 仍为 80 byte；
- CRC-16 保持 offset 126～127；
- v0 没有内嵌 version，接收器只能通过配置显式选择 v0；
- 未确认 width/height/pixel format 时只允许保存 `.raw + metadata.json`。

Stage 2 首先应加强 Python v0 parser：

- 严格检查 sync words；
- 检查 `payload_len <= 80`；
- 保留所有 parse failure reason；
- 把 `row_flags.LENGTH_ERROR` 作为 corrupt/invalid 输入；
- 将本报告中的 ILA payload 固化为只读 regression vector。

### 10.2 最小 v1 扩展建议

当前 offset 13～23 是 11-byte reserved，ILA 样本全为 0。若用户确认 RP2350A
发送端也把这 11 byte 定义为 reserved，可在不改变 128-byte 总长、不修改
Taxi core 的前提下定义：

| offset | 建议字段 | 长度 |
|---:|---|---:|
| 13 | `protocol_version` | 1 |
| 14 | `pixel_format` | 1 |
| 15 | `image_width` LE | 2 |
| 17 | `image_height` LE | 2 |
| 19 | `line_byte_offset` 或 `packet_index` LE | 2 |
| 21 | 保留 | 3 |

现有字段已经提供：

- magic：offset 0～3；
- cam ID：4；
- image frame ID：5～6；
- line ID：7～8；
- line/frame flags：9；
- valid payload length：10；
- sequence：11～12；
- payload CRC-16：126～127。

这个扩展需要先获得两项用户确认：

1. RP2350A 侧真实 C struct/packing/endian 定义；
2. offsets 13～23 确实未被生产固件占用。

若确认，优先由 RP2350A metadata 生成端填入，FPGA 继续只覆盖 cam ID、OR flags
和重算 CRC。若必须在 FPGA 侧补字段，也只能改 metadata wrapper/
`Byte_Replacer` 路径，不能改 Taxi core。

## 11. 第二阶段前的待确认清单

1. 提供或纳入仓库的 RP2350A packet struct/发送源码；
2. 确认 `frame_id/row_idx/row_seq` 的位宽、回绕和复位规则；
3. 确认 reserved[11] 是否可分配；
4. 确认 80-byte payload 的像素含义和 bit order；
5. 确认图像 width/height，以及是否恒定；
6. 查明 ILA 样本 `LENGTH_ERROR=1` 的原因；
7. 捕获至少一份 Camera 模式 PCAP；
8. 准备可离线安装的 Python/pytest/scapy 运行环境或给出允许使用的解释器；
9. 冻结 GUI/ILA A/B build 的源码和 XDC hash manifest。

## 12. 第一阶段最终状态

```text
STAGE_1_FACT_SCAN                 PASS
FIXED_PCAP_LAYER1_LAYER2         PASS
CAMERA_METADATA_INTERNAL_ILA     PASS (single packet only)
CAMERA_PACKET_CRC16              PASS (single packet only)
CAMERA_INPUT_PACKET_LENGTH       FAIL (LENGTH_ERROR observed)
CAMERA_TO_PC_PCAP                PENDING
MULTI_LINE_IMAGE_REASSEMBLY      PENDING
PYTHON_TEST_EXECUTION            PENDING_ENVIRONMENT
GUI_VS_ILA_ROOT_CAUSE            PENDING
FULL_CAMERA_TO_ETHERNET          PENDING
```

本报告完成后按任务规则暂停，不进入 Stage 2，不改接收器或 FPGA 协议。
