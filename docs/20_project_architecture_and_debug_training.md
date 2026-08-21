# 20 Project Architecture and Debug Training

> 扫描基线：2026-07-28，工程根目录 `D:/prg/prg_cam`。  
> 事实优先级：当前源码与 `.xpr` > 当前 Vivado 报告、ILA/PCAP、CSV/JSON > 当前测试 > Git diff > 旧文档。  
> 本文只整理现状和生成调试 Token，不修改 RTL、Taxi、Vivado 工程或 Python 功能代码。

## 0. 结论边界和状态

| 层级 | 当前结论 | 证据与边界 |
|---|---|---|
| 活动工程顶层 | `Camera_Ethernet_Top` | `prg_cam.xpr:481-492`；源码 `prg_cam.srcs/sources_1/new/Camera_Ethernet_Top.sv:15` |
| 当前源选择 | Camera pipeline=1，诊断 FIFO path=1 | `.xpr` generic：`prg_cam.xpr:491-492`；顶层默认值：`Camera_Ethernet_Top.sv:16-18` |
| Taxi 本地依赖 | PASS，26 RTL、8 filelist、16 remap、missing=0 | `scripts/add_taxi_sources.tcl:157-258`；`docs/taxi_local_file_manifest.md:86-104` |
| 当前数字实现 | PASS WITH WARNINGS | 最新 GUI run 报告 `prg_cam.runs/impl_1/Camera_Ethernet_Top_timing_summary_routed.rpt:140-149`：WNS `+2.293 ns`、WHS `+0.033 ns`；DRC 有 Warning、无本文发现的 Error |
| ILA 实现 | PASS WITH WARNINGS，但产物早于当前 50-probe 脚本改动 | `build/ethernet_ila/timing_summary.rpt:151-160`：WNS `+1.431 ns`、WHS `+0.026 ns`；现有 `.bit/.ltx` 时间为 2026-07-27，当前未提交脚本已增加 probe47～49 |
| 固定/Byte FIFO Ethernet TX | 已有硬件与 PCAP 证据 | `docs/sample_eth_data4.pcapng`、既有 ILA/PCAP报告；这不自动证明 Camera 全链 |
| Camera 接收与图像输出 | PARTIAL/PENDING sign-off | `attempt3` 已发布 227 COMPLETE + 795 RECOVERED，但 120.905 s usable fps 为 8.453，且存在 82,135 capture queue drops 与 2,729 length errors |
| Python 离线回归 | PASS | 本轮执行指定解释器：`88 passed in 5.19s` |
| GUI 普通 bit 的板级可重复性 | PENDING | 当前普通 bit 和 ILA bit 均可实现且源码顶层相同，但没有与最新普通 bit SHA-256 绑定的同条件板级 PCAP |

禁止扩大解释：

- `tx_fifo_good_frame`只证明 TX frame FIFO 写侧提交一帧，不证明 MII、PHY 或 PC 已收到。
- route/timing PASS 只证明已分析的数字实现，不等于 LINK 或 Wireshark PASS。
- 看到 LAST_ROW 不等于已收到完整 480 行图像。
- ILA 只增加可观察性，也会改变布局布线；它不是 Ethernet 的功能依赖。

## 1. Project 事实底图

### 1.1 工程、顶层和实际编译源

| 对象 | 当前事实 | 直接证据 |
|---|---|---|
| Vivado 工程 | `prg_cam.xpr`，part=`xc7a50ticsg324-1L` | `prg_cam.xpr:634,674` |
| synthesis/implementation source set | `sources_1` / `constrs_1` | `prg_cam.xpr:634,674` |
| RTL top | `Camera_Ethernet_Top` | `prg_cam.xpr:490` |
| top generics | `USE_CAMERA_PIPELINE=1`、`USE_BYTE_FIFO_PATH=1` | `prg_cam.xpr:491-492` |
| Ethernet XDC | `prg_cam.srcs/constrs_1/new/nexys_a7_ethernet.xdc` | `prg_cam.xpr:503-507` |
| target XDC 属性 | 仍指向空的 deprecated `First_Edition.xdc` | `prg_cam.xpr:497-510`；该文件只有注释，无约束命令 |
| Clock IP | `ethernet_clk_wiz.xci` | `prg_cam.xpr:601-610` |
| BD | `design_1.bd` 存在，但 `design_tree={}`，且不是当前 top | `prg_cam.srcs/sources_1/bd/design_1/design_1.bd:1-13` |

`Camera_Ethernet_Top.sv` 同时保留 fixed generator，属于可综合诊断源；在当前
generic 下，真正送入 Adapter 的是 `camera_packet_*`，选择逻辑见
`Camera_Ethernet_Top.sv:241-250`。顶层单独的 `Byte_FIFO` 只服务
`USE_CAMERA_PIPELINE=0` 的 fixed path；Camera 模式使用
`Camera_Pipeline` 内部的 `Byte_FIFO`。

### 1.2 RTL 层级

```text
Camera_Ethernet_Top
├─ IBUF + BUFG                         100 MHz logic_clk
├─ ethernet_clk_wiz                    50 MHz 0° + 50 MHz 45°
├─ Fixed_Packet_Generator              诊断源，当前不被 packet MUX 选择
├─ Byte_FIFO                           仅 fixed diagnostic path
├─ Camera_Pipeline                     当前 packet 源
│  ├─ 4 × Camera_Capture
│  ├─ 4 × Line_Buffer                  每路 4 × 128-byte slot
│  ├─ Arbitration                      packet 级 one-hot round robin
│  ├─ Byte_Replacer                    patch cam/flags，重算 CRC16
│  └─ Byte_FIFO                        512 × {last,data}
├─ Ethernet_Frame_Adapter              14-byte Ethernet II header
├─ Taxi_Ethernet_Subsystem             flat wrapper；内部 taxi_axis_if
│  └─ taxi_eth_mac_mii_fifo
│     ├─ taxi_axis_async_fifo_adapter   TX frame FIFO + 100→25 MHz CDC
│     ├─ taxi_eth_mac_mii
│     ├─ taxi_eth_mac_1g
│     └─ taxi_axis_gmii_tx              preamble/SFD/pad/FCS/IFG
├─ Ethernet_Mii_Rmii_Bridge
│  └─ rmii_phy_if                      MII 4-bit/25 MHz ↔ RMII 2-bit/50 MHz
├─ IOB TX registers                    falling edge of phy_ref_clk
└─ ODDR                                forwards ETH_REFCLK
```

关键实例证据：

- Camera 四路 Capture、四路 Line Buffer：`Camera_Pipeline.v:99-190`。
- Arbitration/Byte_Replacer/Byte_FIFO：`Camera_Pipeline.v:205-300`。
- Adapter、bridge、Taxi：`Camera_Ethernet_Top.sv:258-342`。
- ODDR 与 PHY 输出：`Camera_Ethernet_Top.sv:344-376`。

### 1.3 Python 包、入口和输出

根目录：
`prg_cam.srcs/sources_1/tx/taxi_receiver_advanced/taxi_receiver/`

| 层 | 文件/入口 | 输入 → 输出 |
|---|---|---|
| CLI | `run_receiver.ps1:1-47` → `taxi_receiver/cli.py:29-305` | PowerShell 参数 → source、stage chain、两个队列、输出 sink |
| Layer 1 | `capture.py:49` `ScapyLiveCapture` | NIC/Npcap packet → `RawEthernetFrame` |
| Layer 2 | `eth_validate.py:33` | MAC/EtherType/长度检查 → Ethernet payload |
| Layer 3 | `camera_parser.py:58`、`packet_format.py:145` | 128-byte payload → typed Camera packet + errors |
| Layer 4 | `stream_monitor.py:55` | 包序列 → per-camera 计数、rate、gap |
| Layer 5 | `reassembler.py:139` `FrameReassembler` | `(cam_id,frame_id,row_idx)` → `CompletedFrame` |
| image policy | `image_pipeline.py:130` | COMPLETE/RECOVERED/REJECTED 决策、阈值图展开 |
| async output | `async_sink.py:23` | completed frame → bounded output queue → worker |
| archive | `storage.py:44` | frame → atomic directory、RAW/metadata/packets/summary |
| 审计 | `session_audit.py:42` | 每个处理上下文 → session CSV |
| 离线分析 | `analyze_camera_archive.py:17,106` | CSV/JSON/PGM/RAW → flags、missing、hash、zero-fill 检查 |

当前 PowerShell 默认：

- capture packet queue=`65536`，`run_receiver.ps1:10,44`；
- frame output queue=`256`，`run_receiver.ps1:12,45`；
- image policy 默认 strict，必须显式选 recover，`run_receiver.ps1:16-21`；
- Python 路径默认为
  `C:/Users/Z/AppData/Local/Python/bin/python.exe`，`run_receiver.ps1:23-25`。

### 1.4 XDC、Tcl、bit、ltx

```text
prg_cam.xpr + sources_1 + constrs_1
          │
          ├─ GUI synth_1/impl_1
          │     └─ prg_cam.runs/impl_1/Camera_Ethernet_Top.bit
          │
          ├─ scripts/rebuild_gui_ethernet.tcl
          │     └─ build/gui_ethernet_rebuild/Camera_Ethernet_Top.bit
          │
          └─ scripts/build_ethernet_ila.tcl
                ├─ build/ethernet_ila/Camera_Ethernet_Top_ila.bit
                └─ build/ethernet_ila/Camera_Ethernet_Top_ila.ltx
```

- `.bit`配置功能与物理布局；`.ltx`描述同一次 debug 实现的探针。
- ILA 烧录脚本同时设置 `PROGRAM.FILE`、`PROBES.FILE` 和
  `FULL_PROBES.FILE`：`scripts/program_ethernet_ila.tcl:23-25`。
- 当前普通 GUI bit SHA-256：
  `4451DFB6...B62083`，时间 2026-07-28 16:34。
- 当前 ILA bit SHA-256：
  `FA4BE84E...2F65C3`；ltx：
  `0D284452...7822C`，时间 2026-07-27 18:50。
- 当前 `build_ethernet_ila.tcl:74-135`定义 probe0～49；现有 `.bit/.ltx`
  早于未提交的 probe47～49 改动，必须重建后才能声称这些新探针已存在。

### 1.5 测试与数据资产

| 资产 | 当前扫描结果 |
|---|---|
| Python tests | 88 项，本轮 `88 passed in 5.19s` |
| 固定链 PCAP | `docs/sample_eth_data4.pcapng`，13,823,740 bytes |
| attempt3 CSV | `rows.csv` 795,297 行记录；`rejected.csv` 802 条拒绝记录 |
| attempt3 输出 | 1,022 JSON + 1,022 PGM + 1,022 RAW；227 COMPLETE、795 RECOVERED |
| 输出尺寸 | RAW=307,200 bytes；PGM=307,215 bytes，640×480 U8 像素加 PGM header |
| archive 分析 | RAW size error=0、PGM/RAW mismatch=0、zero-fill failure=0 |
| 图像截图 | 本轮在 `docs` 与 `images` 未扫描到 `.png/.jpg/.jpeg`；图像证据为 `.pgm/.raw` |

`attempt3` 的 `rows.csv` 实际 flag 分布：

`0x00=789251, 0x02=1649, 0x04=1668, 0x08=2357, 0x0A=23,
0x0C=3, 0x58=346`。`0x01`=overflow、`0x02`=LAST_ROW、
`0x04`=FIRST_ROW、`0x08`=LENGTH_ERROR；`0x58`不是协议定义 flag，
而是 length-error/字段错位证据，不能新增为合法标志。

## 2. 端到端数据流

### 2.1 总流程

```text
OV5640
  │ pixels/HREF/PCLK
  ▼
RP2350A PIO/DMA/packet generator   [源码不在本仓库]
  │ D0-D7 + PCLK + HREF；128-byte row packet
  ▼
Nexys JA/JB IBUF
  ▼
Camera_Capture
  │ byte_valid/line_start/line_end/cam_id/flags
  ▼
Line_Buffer ×4 ─request─► Arbitration ─grant/released─► one-hot MUX
  ▼
Byte_Replacer ─► Byte_FIFO
  │ packet_data[7:0], valid/ready/last @100 MHz
  ▼
Ethernet_Frame_Adapter
  │ 14-byte header + 128-byte payload
  ▼
Taxi AXI-Stream TX FIFO/CDC/MAC
  │ MII TXD[3:0]/TXEN @25 MHz
  ▼
rmii_phy_if
  │ RMII TXD[1:0]/TXEN @50 MHz + forwarded REFCLK
  ▼
LAN8720A → cable → PC NIC/Npcap
  ▼
Layer1 capture queue → Layer2 → Layer3 → Layer4 → Layer5
  ▼
(cam_id,frame_id) session + row_idx placement
  ▼
COMPLETE / RECOVERED / REJECTED
  ▼
bounded frame output queue → RAW/PGM/JSON/CSV
```

### 2.2 分段契约、缓存与丢弃点

| 段 | 输入/输出 | 时钟/复位 | 握手/缓存 | 丢弃、计数和探针 |
|---|---|---|---|---|
| OV5640→RP2350A | sensor pixel/HREF/PCLK → packed row | Camera domain | PIO/DMA，仓库无源码 | FPGA仓库不能证明源端 HREF 数、DMA overflow |
| RP2350A→FPGA pins | D0-D7、PCLK、HREF | 外部异步于100 MHz | 无 ready/backpressure | 电气畸变只可用源端+FPGA端同时测量证明 |
| Camera_Capture | GPIO → byte/line events | 100 MHz采样；`camera_rst_reg`高有效 | 无上游反压；等深度2FF、PCLK投票 | `byte_count!=128`置0x08；探针见 `Camera_Capture.v:39-41,77-100,180-190` |
| Line_Buffer | line event/data →128-byte stream | 100 MHz | 4 slots；`request`为level | 满时整包drop，`overflow_pulse/dropped_packet_count`；`Line_Buffer.v:43-59,124-134` |
| Arbitration | 4 request → one-hot grant | 100 MHz | 包级锁定；release=`valid&&ready&&last` | 不在包中途换源；`Arbitration.v:6-18,69-85` |
| Byte_Replacer | selected byte → patched byte | 100 MHz | ready透明；只在握手时前进 | offset4 cam、offset9 OR flags、126/127 CRC；`Byte_Replacer.v:20-23,74-108` |
| Byte_FIFO | `{last,data}` → packet AXIS-like | 100 MHz同步 | 512 words，4个128-byte包；valid被stall时稳定 | `in_ready`防写满；level/almost_full；`Byte_FIFO.v:14-27,52-69` |
| Frame Adapter | 128-byte packet →142-byte AXIS frame | 100 MHz；`frame_rst_reg` | HEADER时 packet_ready=0；PAYLOAD反压透传 | 状态只在 `valid&&ready`前进；`Ethernet_Frame_Adapter.sv:50-70,89-109` |
| Taxi TX FIFO | 8-bit AXIS → MAC domain | write=100 MHz，read=MII25 MHz | 4096-byte async frame FIFO | 满时 tready反压；overflow/underflow/good_frame |
| MAC | Ethernet bytes → MII nibbles | 25 MHz | 无 Camera 概念 | preamble/SFD/pad/FCS/IFG；`taxi_axis_gmii_tx.sv:343-503` |
| MII→RMII | 4-bit nibble →2-bit dibit | 25↔50 MHz | bridge内部相位/序列状态 | `mii_tx_en/txd`与`rmii_tx_en/txd`分层观测 |
| PHY/NIC/Npcap | RMII → Ethernet frame | 50 MHz PHY与网络时钟 | PHY/NIC/kernel buffers | LINK、FCS坏帧、NIC/kernel drop不由Python queue计数直接区分 |
| capture queue | RawEthernetFrame → worker | 主机线程 | bounded，默认65536；live用`put_nowait` | 满时主动drop；`pipeline.py:136-153` |
| Layer2/3 | Ethernet payload → Camera packet | worker | 同步调用 | EtherType/length/sync/payload_len/CRC错误 |
| reassembler | valid row → session | worker | key=`(cam_id,frame_id)`，row_idx字典 | duplicate/conflict/out-of-range/frame switch/timeout |
| frame output queue | CompletedFrame → output worker | 独立线程 | bounded，默认256；`submit()`满时阻塞 | 不静默丢完整帧；长期磁盘慢会把背压传回packet worker |
| storage | frame → files | output worker | atomic temp/replace、persistent summary writer | Windows rename重试；writer failure计数，最终close/flush |

### 2.3 128-byte Camera row packet

当前 Python 和 FPGA patch offset 对齐：

| Offset | 长度 | 字段 | 字节序/语义 |
|---:|---:|---|---|
| 0 | 2 | sync0 | BE，`0xA5A0` |
| 2 | 2 | sync1 | BE，`0x5A50` |
| 4 | 1 | cam_id | FPGA `Byte_Replacer`覆盖 |
| 5 | 2 | frame_id | BE；上游生成 |
| 7 | 2 | row_idx | BE；帧内行号 |
| 9 | 1 | row_flags | 上游值 OR FPGA flags |
| 10 | 1 | payload_len | 有效 wire payload bytes，须≤80 |
| 11 | 2 | row_seq | BE；连续16-bit行序号 |
| 13 | 11 | reserved | 原样通过 |
| 24 | 80 | packed row | 640 pixels，1 bit/pixel，MSB-first |
| 104 | 10 | trailer pad | 应为0 |
| 114 | 4 | m00 | BE |
| 118 | 2 | xc_q4 | BE |
| 120 | 2 | yc_q4 | BE |
| 122 | 2 | vx_q8 | BE signed |
| 124 | 2 | vy_q8 | BE signed |
| 126 | 2 | CRC16 | little-endian存放；CRC16/CCITT-FALSE覆盖0..125 |

证据：

- `packet_format.py:28-31,45-72,158-179`；
- `camera_parser.py:80-95`；
- `Byte_Replacer.v:20-23,74-92`。

边界必须分清：

```text
Ethernet II bytes supplied by Adapter:
  [DST 6][SRC 6][EtherType 2][Camera row packet 128] = 142 bytes

Taxi/PHY adds on wire:
  [Preamble 7][SFD 1][above 142 bytes][Ethernet CRC-32 FCS 4][IFG]

Camera CRC16 is payload bytes126/127；
Ethernet FCS是MAC生成的另一层CRC，通常不会作为抓包payload交给Python。
```

### 2.4 AXI-Stream 反压 ASM

```text
Adapter:

  +-------- RESET --------+
  |                       v
  |   HEADER(index 0..13) -- frame_ready? --> index++
  |     packet_ready=0
  |     valid/data/last stall-stable
  |              |
  |       byte13 handshake
  |              v
  |   PAYLOAD
  |     packet_ready = frame_ready
  |     frame_valid  = packet_valid
  |     frame_data   = packet_data
  |     frame_last   = packet_valid && packet_last
  |              |
  +--- last valid&&ready handshake ---+
```

```text
Backpressure propagation:

Taxi TX FIFO full
  → frame_ready=0
  → Adapter PAYLOAD packet_ready=0
  → Camera_Pipeline Byte_FIFO out holds {data,last,valid}
  → Byte_FIFO fills
  → Byte_Replacer/Arbitration/Line_Buffer stop releasing
  → Line_Buffer slots fill
  → new physical camera row is dropped as a whole and sticky overflow=1

注意：RP2350A/Camera物理接口没有ready，因此最终只能缓存或丢行。
```

## 3. Taxi 与 MII/RMII

### 3.1 依赖与 Vivado 引用方式

入口为
`prg_cam.srcs/sources_1/lib/taxi-master/eth/rtl/taxi_eth_mac_mii_fifo.f:1-3`。
原 `.f` 中 `../lib/taxi/src/...` 在提取目录下失效；
`scripts/add_taxi_sources.tcl:37-109`先按 `.f` 所在目录解析，再在本地 lib
按文件名唯一重映射。脚本：

1. 递归解析并去重；
2. missing/ambiguous非0立即失败；
3. 扫描重复 module/interface；
4. 只 add 26个依赖 RTL；
5. `.sv`标为 SystemVerilog；
6. `update_compile_order`并检查 missing instances。

`Taxi_Ethernet_Subsystem.sv:31-89`在 wrapper 内声明四个
`taxi_axis_if`；顶层/BD边界只暴露普通 wire。TX映射在
`Taxi_Ethernet_Subsystem.sv:69-84`：

```text
tdata=frame_data, tvalid=frame_valid, tready→frame_ready, tlast=frame_last
tkeep=1, tstrb=1, tuser=0, tid=0, tdest=0
```

本地 `taxi_eth_mac_mii_fifo`没有 `DATA_W`参数；wrapper只传
`VENDOR="XILINX"`、`FAMILY="artix7"`、`STAT_EN=0`，
见 `Taxi_Ethernet_Subsystem.sv:86-90`。不要依据旧需求补一个不存在的
`DATA_W`参数。

### 3.2 Taxi TX 运行机制

```text
8-bit AXIS @100 MHz
  → TX async frame FIFO, depth 4096
  → committed frame跨到MII domain
  → taxi_eth_mac_mii / taxi_eth_mac_1g
  → taxi_axis_gmii_tx
       PREAMBLE → SFD → DATA → optional PAD → FCS → IFG
  → MII 4-bit nibbles @25 MHz
```

- FIFO默认参数：`TX_FIFO_DEPTH=4096`、`TX_FRAME_FIFO=1`、
  `TX_DROP_WHEN_FULL=0`，`taxi_eth_mac_mii_fifo.sv:32-38`。
- MAC padding默认使能、最小帧64 bytes，
  `taxi_eth_mac_mii_fifo.sv:23-24`。当前142-byte MAC输入无需padding，
  但机制仍存在。
- preamble/SFD状态：`taxi_axis_gmii_tx.sv:343-399`；
  padding：`:430-462`；FCS：`:465-493`；IFG：`:496-503`。
- 100→25 MHz CDC由 TX async FIFO完成，不允许用单周期 pulse直接跨域。

### 3.3 MII/RMII和PHY路径

当前不是 Vivado Catalog `mii_to_rmii`，而是：

`Ethernet_Mii_Rmii_Bridge.sv:44-62`
→ `FPGA-RMII-SMII-main/RTL/rmii_phy_if.v:9`。

| 接口 | 数据 | 时钟 | 发送使能 |
|---|---|---|---|
| MII | TXD/RXD 4 bit | TX/RX 25 MHz | TXEN/RXDV |
| RMII | TXD/RXD 2 bit | REFCLK 50 MHz | TXEN/CRSDV |

TX physical path：

`mii_txd/en` → bridge `rmii_txd_dbg/en_dbg`
→ falling-edge IOB registers (`Camera_Ethernet_Top.sv:344-350`)
→ `ETH_TXD A10/A8`、`ETH_TXEN B9`。

Clock path：

`phy_ref_clk 50 MHz +45°`
→ ODDR (`Camera_Ethernet_Top.sv:353-368`)
→ `ETH_REFCLK D5`。

RX physical path：

`ETH_RXD C11/D10`、`ETH_CRSDV D9`、`ETH_RXERR C10`
→ bridge → Taxi RX。首阶段 Python只验证 FPGA TX；RX接口存在但没有完整
上层消费。

### 3.4 FPGA包正确但PC缺包的分层判定

| 最后连续点 | 下一探针 | 判定 |
|---|---|---|
| packet握手连续 | frame header/payload握手 | 不连续：Adapter或上游last/反压 |
| frame握手连续142 bytes | Taxi FIFO状态 | overflow/underflow非0：FIFO/MAC边界 |
| Taxi FIFO提交 | MII TXEN/TXD | MII不动：MAC reset/clock/enable |
| MII正确 | RMII TXEN/TXD | RMII不动/位序错：bridge |
| RMII内部正确 | 外部 REFCLK/TXEN/TXD | 外部异常：IOB/ODDR/XDC/电气 |
| 外部正确且LINK | dumpcap/NIC统计 | PC无帧：FCS/采样窗口/NIC/kernel buffer |
| 原始PCAP连续 | Python queue/gap | Python缺：capture queue/consumer吞吐 |

### 3.5 ILA bit与GUI bit为什么可能不同

两者理论 RTL 数据流可以相同，但物理实现不是同一个：

- ILA插入 debug hub、BRAM和大量路由，改变placement/routing；
- ILA `.bit/.ltx`是一对，普通 bit没有可匹配的 ILA core；
- build Tcl可能显式覆盖generic，而GUI读取 `.xpr`保存值；
- source/XDC工作区快照、增量DCP、生成IP和build时间不同；
- 未完整约束的外部I/O路径可能对布局差异敏感。

当前 `.xpr`已经保存 Camera generic=1，因此
`build_ethernet_ila.tcl:43-47`所称“GUI仍保留fixed generic”的注释已过期。
这不等于 GUI bit硬件复现已经PASS；必须对同一 source hash 做 plain/ILA
A/B build，并把每个 bit hash绑定到PCAP。

## 4. 时钟、复位和CDC

### 4.1 时钟树

```text
E3 CLK100MHZ
  → IBUF sys_clk_ibuf
      ├─ BUFG → logic_clk 100 MHz
      └─ ethernet_clk_wiz (active-high reset)
           ├─ rmii_ref_clk 50 MHz, 0°  → bridge
           └─ phy_ref_clk  50 MHz,45°  → IOB TX regs + ODDR ETH_REFCLK

rmii_phy_if:
  rmii_ref_clk 50 MHz → divide/toggle → mii_tx_clk / mii_rx_clk 25 MHz

External:
  GPIO[8] PCLK → 100 MHz domain synchronizer/filter；不是FPGA内部clock tree
```

XCI事实：

- input 100 MHz：`ethernet_clk_wiz.xci:35`；
- output1 50 MHz/0°：`:69,87-88`；
- output2 50 MHz/45°：`:70,90-91`；
- reset port叫`reset`且ACTIVE_HIGH：`:137,144,226`；
- locked启用：`:135,145`。

### 4.2 reset顺序

1. `CPU_RESETN=0`高有效地复位Clock Wizard输入（`~CPU_RESETN`）。
2. MMCM `locked=0`时，`phy_ready=0`。
3. locked后，100 MHz计数器计满20 bit，约10.49 ms。
4. `ETH_RSTN=phy_ready`释放。
5. `source/camera/frame/bridge/taxi_logic/taxi_mac`使用独立复制寄存器，
   避免一根394 fanout reset树；`Camera_Ethernet_Top.sv:57-95`。
6. Taxi在MII/FIFO域内部用异步置位、同步释放的4-stage
   `taxi_sync_reset`：定义 `taxi_sync_reset.sv:19-40`；
   实例 `taxi_mii_phy_if.sv:105-118`、
   `taxi_axis_async_fifo.sv:346-362`。

### 4.3 Camera CDC

`Camera_Capture.v`不是直接用PCLK作always时钟：

- PCLK、HREF、DATA都采入100 MHz域；
- PCLK/HREF为2FF同步；data有同深度pipeline；
- `PCLK_FILTER_LEN=2`，连续全1/全0才改变`pclk_level`；
- `pclk_pulse`为去抖电平上升沿；
- HREF rise开始一行、fall结束并锁存byte_count。

源码：`Camera_Capture.v:19-23,69-100,117-190`。

限制：多bit DATA逐位同步不是原子总线CDC保证；其安全性依赖源同步接口在
采样窗口内稳定。PCLK频率/占空比过高或HREF/PCLK边沿接近时，100 MHz oversample
和2拍投票可能漏边沿。必须以 raw pin 与 sync/pulse/byte_count 同时ILA验证，
不能只引用未连接FPGA时的逻辑分析仪波形。

### 4.4 CDC清单

| CDC | 当前机制 | 状态 |
|---|---|---|
| PCLK/HREF/DATA→100 MHz | 2FF +等深度data + PCLK filter | 已实现；板级采样窗口仍需实测 |
| AXIS100→MII25 | Taxi async frame FIFO | 已实现 |
| MII25↔RMII50 | `rmii_phy_if`专用转换状态机 | 已实现；外部相位仍需板级验证 |
| reset→MII/FIFO域 | `taxi_sync_reset N=4` | 已实现；PRE false-path已加 |
| MMCM locked→100 MHz控制 | locked用于计数器同步控制 | 当前实现可时序分析；不反馈到Wizard自身reset |
| PHY interrupt/RX→逻辑 | RX进入bridge/Taxi；INTN仅unused reduction | TX-first未做应用验收 |

### 4.5 约束覆盖与空白

已覆盖：

- 100 MHz输入clock：`nexys_a7_ethernet.xdc:4-5`；
- Camera/ETH PACKAGE_PIN和LVCMOS33：`:12-34`；
- forwarded REFCLK：`:42-45`；
- TXEN/TXD output delay max 4.0/min -1.5 ns：`:47-50`；
- MII 25 MHz generated clocks：`:56-57`；
- Taxi异步reset PRE false paths：`:66-74`。

未覆盖或未闭环：

- Camera PCLK没有`create_clock`；XDC明确写“频率尚未建立”，`:9-11`；
- RMII RX没有相对REFCLK的`set_input_delay`；
- 当前 TX delay数值虽有源码注释依据，仍需用板上PHY时序和示波器验证；
- DRC仍有 CFGBVS、IOB placement/register、BRAM async control等Warning；
- `First_Edition.xdc`仍被标为TargetConstrsFile，虽为空文件但配置语义需清理或记录。

## 5. 故障复盘矩阵

| 现象 | 假设 | 使用证据 | 根因/当前最强结论 | 修改/验证 | 尚未解决风险 |
|---|---|---|---|---|---|
| PHY LINK不亮 | Clock Wizard极性、locked死锁、REFCLK、RSTN | XCI端口/相位，D5/B3，top reset计数 | reset为active-high；REFCLK必须50 MHz；早期烧录/时钟/复位版本混淆 | 现top延时释放RSTN，ODDR转发REFCLK；后续LINK已亮 | PHY电气/strap只可板测 |
| LINK正常但0x88B5=0 | TX链未启动、FCS/位序/外部时序 | frame/MII/RMII ILA、PCAP | fixed/Byte FIFO链可发送；目的MAC不是主因 | 固定00..7F PCAP验证 | 普通GUI bit板级复现仍PENDING |
| ILA bit可用、GUI bit异常 | 数据流不同或物理route差异 | `.xpr` generic、build Tcl、bit hash、timing | 当前源码top相同；ILA改变实现，旧注释/构建快照也曾不同 | `ab_build.tcl`保存source manifest和hash | 尚无最新plain/ILA同条件PCAP A/B |
| LENGTH_ERROR | 阈值511错误、FIFO、PCLK/HREF CDC | ILA byte_count 129/130、PCAP fields | 旧异步路径延迟不匹配；残余异常仍需raw/sync/pulse定位 | PCLK/HREF/DATA等深同步+filter；比例历史大降 | attempt3仍2729；CSV不记录物理byte_count |
| HREF/PCLK漏采 | 源端少发或FPGA漏采 | 源端LA与FPGA ILA必须同步 | 仓库不能仅凭PCAP区分A/B | 增加MARK_DEBUG与probe只提供观察 | GPIO电气、窄脉冲、filter窗口待板测 |
| capture queue drops | Npcap/kernel或Python queue满 | `pipeline._on_frame`计数位置，120 s守恒 | 82,135是Python `put_nowait`遇queue.Full，不是EtherType过滤 | async frame sink、65536 queue、peak/rates | 新优化后尚无同条件120 s报告 |
| sequence gaps | RMII错字节或整包丢失 | CRC=0、bad Ethernet length=0、守恒 | `82135+2729=84864`：Python queue drop+L3 length reject解释该轮全部gap | 分离capture与output队列 | MAC前/PCAP/NIC三点计数仍需同测 |
| PGM/RAW不生成 | 480行不全、同步写盘阻塞、Windows rename | reassembler状态、WinError5、输出计数 | 严格策略拒绝不完整帧；旧同步写盘阻塞worker；Windows handle语义 | recover-zero-fill、async sink、atomic retry | writer长期慢时output queue仍会满 |
| usable fps低 | 源帧率低或大量reject | sessions/time、queue drops、reject CSV | 入口约15.09 session/s；usable仅8.453主要由queue drops和reject | Python热路径/输出解耦已加 | 需要新120 s A/B确认接近15 fps |
| “跨帧污染” | session复用旧rows | `(cam,frame)` key、RAW row hash、missing_rows | 当前代码新session独立dict，zero-fill位置检查通过；静止画面hash相同不是充分证据 | `test_reassembler.py`与archive analyzer | 只有missing row出现上一帧非零精确hash才可定性 |

120秒报告的守恒解释：

```text
Capture ingress 877432
  - Matching Ethernet 795297
  = Capture queue drops 82135

Capture queue drops 82135
  + Layer3 length errors 2729
  = sequence gaps 84864
```

由于该轮 `CRC errors=0`、`bad Ethernet length=0`、`parser errors=0`，
首要瓶颈是 Python capture/consumer吞吐和上游行长度异常，而不是优先怀疑
“已收到帧的随机RMII比特损坏”。

## 6. 调试决策树

### 6.1 PHY没有LINK

```text
LINK off
├─ B3 ETH_RSTN一直低
│  ├─ CPU_RESETN极性/引脚C12
│  ├─ clock_locked是否出现
│  └─ 10.49 ms计数是否完成
├─ D5无50 MHz
│  ├─ E3 100 MHz输入
│  ├─ XCI reset为active-high
│  ├─ rmii_ref_clk/phy_ref_clk/locked
│  └─ ODDR Q→ETH_REFCLK约束/引脚
└─ RSTN和REFCLK正常
   └─ PHY供电、strap、线缆、NIC自协商、电气
```

LINK建立前，不先调Camera、Taxi payload或Python。

### 6.2 LINK正常但Wireshark无帧

```text
packet handshake?
  no → Camera/fixed source、FIFO reset/full、ready链
  yes
frame handshake 142 bytes and TLAST at byte141?
  no → Adapter/packet_last/backpressure
  yes
Taxi underflow=0, overflow=0; MII TXEN/TXD active?
  no → Taxi reset/MII25/FIFO
  yes
RMII TXEN/TXD active?
  no → bridge/reset/50 MHz
  yes
pin REFCLK/TXEN/TXD timing valid?
  no → ODDR/IOB/XDC/output timing
  yes → dumpcap无display filter抓原始；查NIC/kernel、FCS与线缆
```

### 6.3 Wireshark有帧但Python无包

1. `dumpcap -D`与CLI `--list`核对接口，不硬编码GUI显示序号。
2. 管理员权限、Npcap安装与WinPcap-compatible选项。
3. 用capture filter `ether proto 0x88b5`，不是把Wireshark display filter
   当BPF。
4. 核对EtherType字节为`88 b5`，Python/Scapy整数为`0x88B5`。
5. 先`--max-stage validate`，再逐层增加parse/monitor/reassemble。

### 6.4 Python有包但sequence gap增长

```text
capture_queue_drops增长?
  yes → queue_peak/capacity、producer/consumer rate、逐包I/O、output worker
  no
raw PCAP row_seq已跳?
  yes → MAC前ILA row_seq/packet count
       ├─ MAC前已跳：Camera/LineBuffer/FIFO
       └─ MAC前连续：MII/RMII/PHY/NIC
  no → Python统计/解析字节序/sequence回绕逻辑
```

### 6.5 行包有效但没有图像

1. 统计不是只看LAST_ROW；检查同一`(cam_id,frame_id)`有效`row_idx`集合。
2. strict要求480行；recover还要求可靠LAST、无overflow/sync/CRC/conflict、
   missing阈值。
3. 查看`rejected.csv`的`reject_reason`、`missing_rows`和连续缺行。
4. 查看frame output queue worker failures与输出根目录。
5. Windows rename失败时确认所有句柄close并检查Defender/目标目录冲突。

### 6.6 图像错位或疑似跨帧污染

1. JSON读取`frame_id/missing_rows/status`。
2. 对每行RAW算SHA-256，缺行必须在对应`row_idx`全0。
3. 检查是否“缺行后整体上移”：这是append/row_idx放置错误。
4. 只有新frame在缺失位置出现上一frame非零行精确hash，且排除静止场景，
   才怀疑buffer生命周期。
5. 核对session key、独立rows dict、发布时不可变bytes、close后删除session。

### 6.7 ILA构建正常但GUI构建异常

1. 不用手点顺序做变量；运行`scripts/ab_build.tcl`。
2. 记录git HEAD/status、source/XDC SHA-256、top、generic、part、Vivado版本。
3. 比较plain/ILA的compile order、XDC、IP checkpoint、incremental DCP。
4. 各自记录WNS/WHS/DRC、bit hash。
5. 同一上电条件分别烧录，保存LINK、ILA（仅ILA版）、dumpcap和PCAP。
6. 若RTL边界均相同而板级不同，优先审查未约束I/O/CDC与布局敏感性。

## 7. 培训用核心概念

| 概念 | 原因 → 结果 | 如何验证 |
|---|---|---|
| AXI-Stream反压 | ready=0时发送端不能换data/last → 否则丢/重字节 | stall assertion；ILA看`valid&&!ready`期间稳定 |
| FIFO overflow | producer长期快于consumer且容量耗尽 → 新数据丢弃或反压 | level/almost_full、overflow、push/pop守恒 |
| FIFO underflow | consumer需要数据但FIFO空 → MAC帧中断/坏帧 | `tx_error_underflow`必须0 |
| CDC/亚稳态 | 异步信号在采样边沿变化 → 偶发错误且RTL仿真可能看不到 | 结构审查、`report_cdc`、ILA统计而非单次波形 |
| MII/RMII | 100 Mb/s下4bit×25 MHz=2bit×50 MHz → bridge必须保持dibit/nibble次序 | 同时抓MII和RMII TXEN/TXD并做scoreboard |
| Ethernet frame vs row packet | Ethernet封装承载一个128-byte Camera行包 → FCS与Camera CRC16是不同层 | offset表、PCAP payload、MAC前后scoreboard |
| packet rate vs image fps | 每图480个row packet → 7000 packet/s不等于7000 image/s | image fps只按COMPLETE/RECOVERED frame计数 |
| usable fps | `(complete+recovered)/elapsed` → reject不计可用图 | CLI image publication counters |
| 有界队列 | 吸收短突发但限制内存 → 长期consumer慢仍会满 | queue peak/capacity、producer/consumer rate、drop |
| async output | 磁盘I/O移出packet热路径 → capture consumer更快 | 小queue+慢sink测试、120秒drop A/B |
| ILA | 插入内部采样硬件 → 提供证据且改变布局 | `.bit/.ltx`成对、分时钟域、与无ILA时序分开报告 |

## 8. 当前文档过期项

以下旧文档是历史记录，不应静默改写；培训时必须与当前代码并读。

| 旧结论 | 冲突的当前事实 |
|---|---|
| `docs/techical docs/README.md:15`、`09_hardware_bringup.md:66`、`14...md:279`称Camera尚未进入活动top | `.xpr:491`和`Camera_Ethernet_Top.sv:202,241-250`表明Camera已被选择 |
| `01_camera_pipeline_dataflow.md:17,39`、`10_interface...md:11`称PCLK由Alarmer产生pulse | 当前`Camera_Capture.v:77-100,128-143`内建等深同步和PCLK filter，不实例化Alarmer |
| `12/13/15`称固定发生器仍为活动顶层、硬件TX全PENDING | 固定链PCAP已存在，Camera模式也已生成attempt3图像；但Full Camera sign-off仍PENDING |
| 早期文档称REFCLK裸assign且无output delay | 当前top使用ODDR+IOB regs，XDC已有`set_output_delay`，见top`:344-368`、XDC`:42-50` |
| `build_ethernet_ila.tcl:43-45`注释称GUI generic仍为fixed | 当前`prg_cam.xpr:491-492`均为1；脚本注释未同步 |
| 旧报告中的WNS/WHS `+3.202/+0.053`或其他数值 | 当前各build不同：latest GUI `+2.293/+0.033`，ILA `+1.431/+0.026`；不可跨实现混用 |
| 旧receiver报告称只有27/37/51/59/68/71 tests | 当前工作树测试集合为88；历史数字只代表当时测试集 |

## 9. 当前验收与未确认项

### 9.1 当前可确认

- 顶层、源选择、Taxi闭包、MII/RMII实际实例关系已由当前源码确认。
- 最新普通GUI run和现有ILA run的已分析时序均为正。
- `attempt3`中1,022个发布图的RAW长度、PGM像素、zero-fill位置均通过离线分析。
- 120秒大规模gap的计数守恒指向Python capture queue drop和Layer3 length
  reject，不支持优先归咎于已收到帧的随机CRC损坏。
- 88个Python测试当前通过。

### 9.2 仓库无法确认

- RP2350A PIO/DMA与正式packet generator的当前C/PIO源码及固件hash不在仓库。
- OV5640接入FPGA负载后，源端实际HREF/PCLK数量、电平、建立/保持和抖动。
- 当前未提交probe47～49对应的新ILA bit/ltx尚未重建。
- 最新普通GUI bit `4451...2083`是否在同一硬件/固件/线缆条件下达到与ILA
  bit相同的PCAP结果。
- NIC/Npcap kernel drop与Python callback ingress之间的独立计数。
- 新async output/queue优化后的同条件120秒
  `queue_drops/peak/rates/usable_fps`报告。
- RMII RX input delay与完整RX协议栈；当前目标仍是TX。
- `0x58`异常首次发生在RP2350A pin、Camera_Capture还是更后级的板上边界；
  CSV只有结果，没有物理byte_count。

## 10. Token A：Xilinx / RTL / ILA Debug

```text
你正在诊断 D:/prg/prg_cam 的 Vivado 2025.2.1、Nexys A7-50T
Camera→Taxi→MII/RMII→LAN8720A TX工程。先只读扫描实际代码和当前构建证据，
不要依据旧文档直接下结论；默认先诊断，只有证据唯一指向某个最小修复时才修改，
禁止修改Taxi core和Vivado自动生成目录。

输入证据：
- prg_cam.xpr、sources_1/sim_1、所有V/SV/VH；
- constrs_1中的XDC、ethernet_clk_wiz.xci；
- scripts中的add/build/program/report/ILA Tcl；
- Taxi入口eth/rtl/taxi_eth_mac_mii_fifo.f及其实际递归闭包；
- MII/RMII wrapper与rmii_phy_if；
- .runs/build中的DCP/bit/ltx/log/timing/CDC/DRC；
- 最新ILA CSV与PCAP（如有）。

执行：
1. 从.xpr确认part、top、SRCSET、CONSTRSET、generics、实际used_in源和空/旧BD。
2. 沿实例建立Camera_Capture→Line_Buffer→Arbitration→Byte_Replacer
   →Byte_FIFO→Frame Adapter→Taxi TX FIFO/CDC/MAC→MII→RMII→pins关系。
3. 对每个ready/valid/last、request/grant/released列出推进条件和stall稳定条件。
4. 建立100/50/25 MHz与外部PCLK时钟树；核对Clock Wizard reset极性、locked、
   ETH_RSTN顺序、Taxi reset synchronizer N值。
5. 审计create_clock/generated_clock、clock groups、reset exceptions、
   RMII input/output delay、unconstrained path；报告实际WNS/WHS和build时间。
6. 比较plain/ILA：source+XDC hash、top/generic、IP/DCP、bit hash、WNS/WHS；
   不把ILA当功能依赖，不把route PASS当Wireshark PASS。
7. 生成最小分域探针：
   logic100：packet/frame握手、FIFO level、grant/drop、raw/sync PCLK/HREF、
             byte_valid/byte_count/line_end/length_error；
   mii25：TXEN/TXD/TXER；
   rmii50：TXEN/TXD/REFCLK。
8. 触发顺序：raw HREF rise/fall、length_error pulse、frame handshake、MII TXEN、
   RMII TXEN。给每个触发的预期波形和“在哪层首次异常”的判定表。
9. 若MAC前row_seq连续而PCAP跳号，转查MII/RMII/PHY/NIC；若MAC前已跳，回查
   Camera/LineBuffer/FIFO。tx_fifo_good_frame只作FIFO提交证据。

验收指标：
- missing/duplicate definition=0；compile/elab PASS；
- unsafe CDC有明确处置；WNS/WHS≥0且报告build身份；
- tx_error_underflow=0、tx_fifo_overflow=0；
- stall期间data/valid/last稳定；
- MII/RMII次序和TXEN边界可由波形说明；
- plain/ILA每份bit均绑定hash、报告和PCAP，不混用证据。

最终报告格式：
A 实际顶层/编译闭包；B 数据/时钟/reset/CDC图；C 约束覆盖与空白；
D ILA probe/trigger/判定表；E plain-vs-ILA差异；F PASS/FAIL/PENDING；
G 最小修复建议、风险和回退。无法板测的项必须写PENDING，不猜测。
```

## 11. Token B：Python Receiver Debug

```text
你正在诊断 D:/prg/prg_cam/prg_cam.srcs/sources_1/tx/
taxi_receiver_advanced/taxi_receiver。先扫描当前Layer1～Layer5、tests、脚本、
PCAP、CSV/JSON/PGM/RAW和git diff；代码/测试优先于旧报告。默认先诊断，
只有证据明确时做最小修改；不放宽Layer3 sync/length/CRC，不改线上协议。

输入证据：
- capture.py、eth_validate.py、packet_format.py、camera_parser.py、stages.py；
- pipeline.py、stream_monitor.py、reassembler.py、image_pipeline.py；
- async_sink.py、storage.py、session_audit.py、cli.py；
- run_receiver.ps1/replay/monitor脚本和全部pytest；
- 目标PCAP、120秒FINAL REPORT、rows.csv、rejected.csv、JSON/RAW/PGM。

执行：
1. 先运行全部pytest并保存解释器、版本、数量、耗时；失败先建立最小复现。
2. 逐层列出输入/输出/拒绝条件和计数位置；确认EtherType 0x88B5、
   128-byte schema、字节序、flags、Camera CRC16与Ethernet FCS边界。
3. 分开审计两个有界队列：
   capture packet queue：producer/callback、put_nowait/full/drop、capacity/peak；
   frame output queue：completed frame、blocking submit、worker/failure/drain/join。
4. 计算ingress、matching、valid、queue_drops、length errors、sequence gaps守恒；
   查统计是否把EtherType过滤、Npcap drop和Python queue.Full混为一谈。
5. 查热路径逐包print/CSV/JSON/fsync、重复bytes复制、GIL/锁、批量flush；
   查summary.csv是否O(n²)重写。
6. 以(cam_id,frame_id)审计session：独立rows容器、row_idx放置、duplicate/conflict、
   frame switch/LAST/timeout清理、不可变payload快照。
7. 对COMPLETE/RECOVERED/REJECTED列准入条件；zero-fill只能填missing row_idx，
   不得append尾部，不得使用Layer3失败payload。
8. 用archive analyzer验证RAW=640×480、PGM pixels=RAW、missing rows全0；
   相邻帧逐行hash只作为证据，静止画面相同不能单独定性跨帧污染。
9. 做120秒A/B：同NIC、bit、固件、queue、输出盘，记录producer/consumer rate、
   两队列peak/capacity、worker failures、length/gaps和三类image fps。

验收指标：
- capture_queue_drops<0.1%或有可定位的剩余来源；
- producer_rate≤可持续consumer_rate，queue peak不长期贴capacity；
- output worker failure=0，退出时stop→drain→flush/close→join；
- CRC/sync不放宽，conflicting duplicate不输出；
- zero-fill位置正确，无跨frame旧row复用；
- complete_fps、recovered_fps、total_usable_fps分别报告，packet rate不叫image fps。

最终报告格式：
A 根因排序；B Layer1～5计数/丢弃表；C 两队列与线程图；
D 协议字段和错误口径；E 重组/存储生命周期；F 测试与120秒A/B；
G 修改文件/理由/风险/回退；H PASS/FAIL/PENDING及剩余reject_reason。
```

## 12. Token C：PowerShell / 运行环境 Debug

```text
你正在为 D:/prg/prg_cam 的0x88B5 Camera receiver诊断Windows PowerShell、
Python、Npcap、网卡、路径、队列参数与120秒回归。先读取实际.ps1和CLI
--help，不要从旧命令猜参数；默认只诊断，证据明确后才最小修改脚本。

输入证据：
- run_receiver.ps1、replay_pcap.ps1、monitor_camera_output.ps1；
- taxi_receiver/cli.py与capture.py；
- PowerShell版本、ExecutionPolicy、Python可执行文件/pytest/scapy版本；
- Npcap接口列表、dumpcap -D、NIC统计；
- 目标OutputRoot/ImagesRoot、FINAL REPORT、CSV/JSON/RAW/PGM、PCAP。

执行：
1. 用Get-Command/Test-Path确认脚本和Python绝对路径；工作目录不能假定为脚本目录。
2. 若ExecutionPolicy阻止脚本，仅对本次进程使用：
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File <absolute ps1> <args>
   不把PowerShell提示符“>>”复制进命令；反引号必须是每行最后一个字符。
3. 运行脚本--help/读取param，核对Interface、OutputRoot、ImagesRoot、
   QueueDepth、FrameOutputQueueDepth、ImagePolicy、missing阈值。
4. 用dumpcap -D和receiver --list核对NPF GUID；确认管理员权限与Npcap。
5. 区分capture filter `ether proto 0x88b5`和Wireshark display filter
   `eth.type == 0x88b5`；先用dumpcap保存原始PCAP。
6. 输出路径全部转绝对路径，冒烟/正式目录隔离；递归统计complete根目录与
   recovered/frame_*/image.pgm，不能只数顶层*.pgm。
7. 前台运行并只按一次Ctrl+C，确认CLI finally完成stop、drain、flush/close、
   worker join和FINAL REPORT；禁止Stop-Job强杀作为验收。
8. 做120秒A/B，唯一变量只能是待测参数/版本。每次保存命令、开始时间、
   bit/ltx/firmware hash、PCAP、console log、summary和目录清单。
9. 交叉核对：
   ingress-matching是否等于queue drops；
   queue drop+Layer3 reject是否解释sequence gaps；
   published文件数是否等于images_complete+images_recovered；
   RAW应307200 bytes，PGM像素区应等于RAW。

建议一次运行模板（先以实际param为准）：
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver\run_receiver.ps1' `
  -Interface '<dumpcap -D确认的NPF GUID>' `
  -OutputRoot 'D:\prg\prg_cam\build\receiver_output\<run_id>' `
  -ImagesRoot 'D:\prg\prg_cam\images\temp\archive\<run_id>' `
  -QueueDepth 65536 -FrameOutputQueueDepth 256 `
  -ImagePolicy 'recover-zero-fill' -MaxMissingRows 4 -MaxConsecutiveMissing 2

验收指标：
- Python/pytest/scapy/Npcap/interface均明确；
- BPF在capture层生效；
- queue drop%、两个queue peak/capacity、producer/consumer rate、worker failure可见；
- 120秒优雅退出且输出计数守恒；
- complete/recovered/rejected和usable fps分开报告；
- 所有证据绑定run_id和绝对路径。

最终报告格式：
A 环境与版本；B 可复制启动命令；C 网卡/BPF/Npcap验证；
D 路径与文件计数；E 120秒指标对比；F PowerShell/CLI错误及修复；
G PASS/FAIL/PENDING、剩余风险和下一条命令。
```

