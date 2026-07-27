# P7 当前硬件 ILA、Session Audit 与 GUI/ILA A/B 构建报告

> 日期：2026-07-26  
> Vivado：2025.2.1  
> 器件：xc7a50ticsg324-1L  
> 顶层：`Camera_Ethernet_Top`  
> Git：`2487fee48f59ee176ce293b217a6909cb9159a11`，分支
> `feat/taxi-ethernet-bringup`

## 1. 结论摘要

本轮完成了当前 Camera_Capture CDC 修复版的重新构建、烧录、47 探针
ILA 分层抓取、Python `session_audit.csv` 实现与回归，以及普通/ILA 两种
实现的同源 A/B 构建。

主要结论：

1. 当前 Camera → Byte_FIFO → Frame Adapter → Taxi → RMII 发送链正在运行。
   ILA 捕获到一帧严格的 14-byte Ethernet header + 128-byte payload，共
   142 次 AXI-Stream 握手；最后一个 payload byte 同拍 `frame_last=1`。
2. 当前 payload 的前四字节在 Camera_Capture 边界已经是
   `95 90 6A 60`，因此问题不在 Frame Adapter、Taxi、RMII、PC 网卡或
   Wireshark。
3. `A5→95`、`A0→90`、`5A→6A`、`50→60` 全部严格等价于每个 byte 的
   bit4/bit5 互换。工程 RTL 和 XDC 是 `GPIO[4]=JA7/D17`、
   `GPIO[5]=JA8/E17` 的直接映射；下一步应检查 RP2350A GPIO 映射及
   JA7/JA8 实际连线，不应先在 Taxi 内补偿。
4. 捕获到的残余 `LENGTH_ERROR` 是 127 byte，不再是修复前的 129/130
   重复采样。完整行波形显示同步 PCLK 的一拍毛刺打断低电平去抖窗口，
   导致相邻两个合法 PCLK 高相位在 `pclk_level` 上合并并少产生一个
   `byte_valid`。增大 `PCLK_FILTER_LEN` 不能从结构上解决该问题。
5. 普通与 ILA 构建使用完全相同的 source/constrs 快照，二者时序均通过。
   ILA 不是 Ethernet 功能依赖；它会增加 debug 逻辑并导致独立布局布线，
   所以 `.bit` hash 不应相同。
6. Python 全回归为 `59 passed in 3.55s`。`SessionAuditLogger` 已能记录
   每个包、传播同一帧内的 `0x08` 污染、识别非法计数回退，并在后续
   Storage 阶段失败时仍保留审计记录。

## 2. 事实来源与产物绑定

### 2.1 本轮实际烧录版本

硬件抓取使用下列已归档配对产物：

```text
build/ethernet_ila/archive/camera_cdc_fix_47_probes_20260726_2256/
  Camera_Ethernet_Top_ila.bit
  Camera_Ethernet_Top_ila.ltx
  Camera_Ethernet_Top_ila_routed.dcp
  timing_summary.rpt
  drc.rpt
  frame_handshake_capture.csv
  camera_capture_byte_valid_dbg_capture.csv
  camera_length_error_pulse_dbg_capture.csv
```

哈希：

| 产物 | SHA-256 |
|---|---|
| 上板 `.bit` | `9312A4E72A7218C5D0F0B509614370A5D5283448556312C1BCEADF6732BC152D` |
| 配对 `.ltx` | `0D284452E1B1A3C969D108C9CB2D2666F9B7F43544ACC365EE38E90250B7822C` |
| `Camera_Capture.v` | `6803DBF33A0193360836F4635314D1A67F6D02209D2E51B84E24D8386136FB05` |

Vivado 烧录后回读到一个 `hw_ila_1`，共 47 个 probe；新增的
`pclk_hist`、`pclk_level`、`pclk_sync`、`href_sync`、`data_sync`
均成功识别。

### 2.2 `sample_eth_data4_ref.pcapng` 的证据边界

当前工作区和已检查的附件目录中不存在
`sample_eth_data4_ref.pcapng`，也没有本次 RP2350A 固件源码或固件
binary/hash。因此无法给该文件绑定精确 bit/固件版本。

当前可读取的 `docs/sample_eth_data4.pcapng` 为：

| 项目 | 数值 |
|---|---|
| SHA-256 | `8A4DE79782E53743A966255D8040CCDFDE9BB8539CF0CBB8D59ABDCB4904B815` |
| 包数 | 78,467 |
| 时间 | 2026-07-24 20:11:41.1392281 至 20:11:52.5975417 |
| payload 长度 | 78,467/78,467 均为 128 byte |
| sync 主值 | 78,464 包为 `A5 A5 5A 5A` |

而 2026-07-26 当前板上 ILA 稳定看到 `95 90 6A 60`。两批数据至少在
协议字节上不相同，不能把旧 `sample_eth_data4.pcapng` 当成当前 RP2350A
固件行为的回归基准。

另有一个必须保留的协议冲突：

- 当前 `packet_format.py:40-41` 定义 `SYNC0=0xA5A5`、
  `SYNC1=0x5A5A`；
- 本轮任务描述给出的当前预期 byte 是 `A5 A0 5A 50`；
- 当前硬件实际为其 bit4/bit5 交换结果 `95 90 6A 60`。

在获得当前 RP2350A 源码或明确常量前，不修改 `packet_format.py`，也不把
任一常量升级为新的正式协议。

## 3. ILA 分层结果

### 3.1 Frame Adapter / Camera packet / RMII 活动

证据：
`frame_handshake_capture.csv`

4096 个 100 MHz 样本中：

| 检查项 | 结果 |
|---|---:|
| `frame_valid && frame_ready` | 142 |
| `packet_valid && packet_ready` | 128 |
| `camera_packet_valid && camera_packet_ready` | 128 |
| `frame_last` 高电平样本 | 1 |
| `rmii_tx_en_dbg` 高电平样本 | 1232 |
| `tx_error_underflow` 高电平样本 | 0 |
| `tx_fifo_overflow` 高电平样本 | 0 |

握手 byte 序列开头：

```text
ff ff ff ff ff ff 02 00 00 00 00 02 88 b5
95 90 6a 60 ...
```

这证明：

- 14-byte Ethernet header 全部握手；
- 128-byte Camera packet 全部出队；
- `frame_last` 仅位于第 128 个 payload byte；
- Taxi/RMII 发送侧有活动且本窗口无 underflow/overflow。

它不证明 PC 网卡已经接收，也不把 `tx_fifo_good_frame` 解释为线上发送完成。

### 3.2 正常 Camera 行

证据：
`camera_capture_byte_valid_dbg_capture.csv`

- `camera_capture_byte_valid_dbg` 共 128 次；
- `camera_current_byte_count_dbg` 严格从 `0x0001` 增加到 `0x0080`；
- 相邻 `byte_valid` 间隔为 8 或 9 个 100 MHz 周期，符合约 12 MHz PCLK；
- 本窗口 `camera_length_error_pulse_dbg=0`；
- `data_sync` 前四字节为 `95 90 6A 60`。

因此 bit4/bit5 互换在 Camera_Capture 的同步输入边界已经存在。

### 3.3 残余 LENGTH_ERROR 行

证据：
`camera_length_error_pulse_dbg_capture.csv`

本次使用：

```powershell
$env:ILA_TRIGGER_NAME='camera_length_error_pulse_dbg'
$env:ILA_TRIGGER_POSITION='3072'
vivado -mode batch -source scripts/capture_ethernet_ila.tcl
```

触发结果：

| 项目 | 结果 |
|---|---:|
| `last_line_byte_count` | `0x007F`，即 127 |
| 同步 HREF 窗口 | sample `[1982,3071)` |
| 该窗口 `byte_valid` | 127 |
| 同步 PCLK 高电平 run | 130 |
| 其中宽度 1 拍 | 2 |
| 去抖后 `pclk_level` 上升沿 | 127 |

关键波形行为：

- sample 2589 出现一拍 `pclk_sync=1`；
- 它打断 `pclk_hist` 连续全零，使 `pclk_level` 未在两个真实脉冲之间
  及时回落；
- 下一合法高相位没有产生新的 `pclk_level` 上升沿；
- 最终少一次 `byte_valid`，HREF 下降时计数为 127。

这与修复前的“同一物理沿被识别为两次、计数 129/130”不同。当前
2FF + filter 是有效缓解，但不是异步源同步总线的最终 CDC 架构。

推荐下一步是让 `camera_data/href` 在 PCLK 域采样并写入异步 FIFO，再由
100 MHz 域读取；不建议仅增加 `PCLK_FILTER_LEN`。

## 4. JA 数据位核对

当前仓库中的直接连接为：

| 逻辑位 | Nexys Pmod | FPGA pin | 顶层 |
|---|---|---|---|
| D4 / `GPIO[4]` | JA7 | D17 | `camera_data_dbg=GPIO[7:0]` |
| D5 / `GPIO[5]` | JA8 | E17 | `camera_data_dbg=GPIO[7:0]` |

依据：

- `prg_cam.srcs/constrs_1/new/nexys_a7_ethernet.xdc`
- `prg_cam.srcs/sources_1/new/Camera_Ethernet_Top.sv:172-174`
- `Camera_Ethernet_Top.sv:207` 到 `Camera_Pipeline.cam0_data`

RTL 没有对 bit4/bit5 做交换。当前最小物理诊断是让 RP2350A 输出 walking
bit（`01,02,04,08,10,20,40,80`），在 ILA 比较 `camera_data_dbg` 与
`data_sync`。在该测试前，bit4/bit5 的责任边界仍是：

```text
RP2350A GPIO 定义 / 排线 JA7-JA8 连接：首要怀疑
FPGA XDC / 顶层直连：仓库内自洽
Taxi / Ethernet：已由 ILA 排除
```

## 5. Session Audit

新增：

- `taxi_receiver/taxi_receiver/session_audit.py`
- `tests/test_session_audit.py`

接入：

- `cli.py:117,141`：有 `--output-root` 时创建并挂载 logger；
- `pipeline.py:154-155`：通过 `finally` 调用
  `on_frame_processed`，保证后级存储失败时仍审计。

CSV：

```text
output_root/session_audit.csv
```

字段为：

```text
timestamp,cam_id,frame_id,row_idx,row_flags_raw,row_flags_effective,
payload_len,row_seq,crc_ok,m00,xc_q4,yc_q4,vx_q8,vy_q8
```

已验证：

- 同一 `(cam_id, frame_id)` 从首次 `row_flags_raw & 0x08` 起向后传播到
  `row_flags_effective`；
- raw 字段不被覆盖；
- 新 frame 和不同 camera 的 contamination 独立清零；
- 16-bit 正常回绕不误判为新上电；
- 非法大幅回退以 `w` 模式重建 CSV；
- Layer3 失败和后级 Storage 异常的包仍记录；
- malformed 包不会以伪造 metadata 触发 session overwrite。

对 `sample_eth_data4.pcapng` 的无丢队列回放结果：

```text
build/receiver_output/sample_eth_data4_session_audit_full_v3/session_audit.csv
```

- 78,467 个输入包；
- 78,467 条 CSV 数据记录，另加 1 条 header；
- capture queue drops = 0；
- valid = 77,814；
- length error = 489；
- overflow = 164；
- CRC error = 0；
- Storage 拒绝覆盖两个已归档 frame，但对应包仍在 audit CSV。

Python 最终回归：

```powershell
python -m pytest -q --basetemp D:\prg\prg_cam\build\pytest_tmp_20260726_2327
```

结果：`59 passed in 3.55s`。

## 6. GUI / ILA A/B 构建

证据目录：

```text
build/ab_build/20260726_231631/
```

构建固定条件：

| 项目 | 值 |
|---|---|
| Vivado | 2025.2.1 |
| part | xc7a50ticsg324-1L |
| top | Camera_Ethernet_Top |
| srcset | sources_1 |
| constrset | constrs_1 |
| Git HEAD | `2487fee48f59ee176ce293b217a6909cb9159a11` |

构建前后 manifest SHA-256 均为：

```text
E84A827FD0D2B07B77FE995CB95227C975077AD83D53B06D223D0D4E849AA1F4
```

因此 `SOURCE_SNAPSHOT_STABLE=PASS`。

| 变体 | bit SHA-256 | WNS | WHS | 结果 |
|---|---|---:|---:|---|
| plain | `D2416F13D88E9818B0E51A0E90D94976346AA5CEE7BF6B99C2693405A68889CE` | +0.793 ns | +0.071 ns | PASS WITH WARNINGS |
| ILA, 47 probes | `7BDE7723424F4EB2D905D84E922776D598C5FE2E2F4002A25CC9A915FA0695D2` | +0.953 ns | +0.046 ns | PASS WITH WARNINGS |

两套 bit 不同是正常结果：ILA 变体加入 debug hub、BRAM、采样寄存器并
独立布局布线。A/B 证明的是二者消费相同的功能源码和约束并均能完成
实现，不是要求 bitstream 二进制相同。

普通实现实际 run 目录由 Vivado 查询为：

```text
D:/prg/prg_cam/impl_1
```

`rebuild_gui_ethernet.tcl` 已改为读取 `get_runs impl_1` 的 `DIRECTORY`，
不再错误假设 `prg_cam.runs/impl_1`。

## 7. PASS / FAIL / PENDING

| Gate | 状态 | 证据或原因 |
|---|---|---|
| 当前 CDC 修复版 ILA build/program | PASS | 47 probes，板上回读成功 |
| 普通与 ILA 同源码快照 build | PASS | A/B before/after manifest 相同 |
| 普通实现 timing | PASS | WNS +0.793 ns，WHS +0.071 ns |
| ILA 实现 timing | PASS | WNS +0.953 ns，WHS +0.046 ns |
| Taxi reset false-path 覆盖 | PASS | 两组各 4 个 PRE pin，100% coverage |
| Camera → Adapter AXIS 142 handshakes | PASS | 14 + 128，TLAST 位置正确 |
| ILA underflow/overflow | PASS | 本捕获窗口均为 0 |
| Python receiver 回归 | PASS | 59/59 |
| Session audit 全包记录 | PASS | data4 78,467/78,467 |
| 当前 Camera sync 内容 | FAIL | `95 90 6A 60`，bit4/bit5 互换 |
| 当前 Camera 行长度 | FAIL（低比例残余） | 现场抓到 127-byte 行 |
| 精确 `data4_ref` 版本绑定 | PENDING | 文件与固件 hash 不在工作区 |
| 当前正式 sync 常量 | PENDING | Python 为 A5A5/5A5A，任务描述为 A5A0/5A50 |
| 新 Camera PCAP | PENDING | 先确认/修复 bit4-bit5 与协议常量 |
| 图像重建硬件验收 | PENDING | 当前 payload 协议仍不一致 |
| Wireshark 当前修复版连续验收 | PENDING | 本轮先完成 ILA，未在错误协议前提下新抓 PCAP |

## 8. 后续优先级

1. 用 RP2350A walking-bit 测试确认 JA7/JA8 是否物理互换；保存固件 hash。
2. 明确当前 sync 常量到底是 A5A5/5A5A 还是 A5A0/5A50，再更新协议和
   parser regression vector。
3. 修复物理/固件 bit4-bit5 后重新抓 2,000 包 PCAP，先检查 sync、长度和
   CRC，再做图像重建。
4. 将 Camera 输入重构为 PCLK 域采样 + async FIFO，消除 127-byte 残余
   毛刺，而不是继续堆叠电平去抖长度。
5. 新 PCAP 通过后再评估 Storage COMPLETE/PARTIAL/CORRUPT/TIMEOUT 和
   图像归档的硬件 PASS。

本轮未修改 Taxi core，未删除 `.runs/.cache/prg_cam.gen`、旧 bit/ltx、
PCAP 或历史报告。
