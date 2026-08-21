# Camera attempt8/attempt9 行错位诊断与 RTL 修正报告

日期：2026-08-01  
范围：Camera 输入边界、Line Buffer、Byte Replacer、ILA 和回归测试。  
明确不变：Taxi core、Ethernet 帧格式、RP2350A 协议、Python Layer1～Layer3、FPGA CRC-16 重算。

## 1. 结论

本轮没有发现“FPGA 把 `row_idx` 数值算错”的证据。包内 `frame_id/row_idx/
row_seq` 来自 RP2350A 字节流；FPGA 的 `Camera_Capture.row_idx` 只用于调试，
没有写回这些字段。实际问题是 FPGA 在 `Camera_Capture` 输入边界发生了两类
字节事件错误：

1. 去抖后的旧 `pclk_level` 阻止更新候选字节，但后续 `pclk_pulse` 仍发出，
   形成“计数正确、数据重复上一字节”；
2. 原连续低电平投票会被一个短高采样清掉低相位进度，从而把下一真实 PCLK
   与前一个周期合并，形成 127-byte 行及 header 左移。

这两类错误都发生在 FPGA 重算 CRC 之前。因此接收端看到 CRC 正确并不矛盾；
它说明 FPGA 输出的最终 128 byte 自洽，不能证明 RP2350A 到 FPGA 的原始 128
byte 未被改坏。按用户要求，CRC 重算机制保持不变。

## 2. CSV 独立复核

证据文件：

- `images/temp/archive/attempt8/cam0/rows.csv`
- `images/temp/archive/attempt8/cam0/rejected.csv`
- `images/temp/archive/attempt9/cam0/rows.csv`
- `images/temp/archive/attempt9/cam0/rejected.csv`

| 指标 | attempt8 | attempt9 |
|---|---:|---:|
| CSV 行包数 | 326,004 | 424,974 |
| 时间跨度 | 42.425 s | 163.509 s |
| 全跨度平均 | 7,684.23 pkt/s | 2,599.09 pkt/s |
| `<5 ms` 活动区间等效速率 | 7,718.53 pkt/s | 7,845.51 pkt/s |
| `parse_ok` | 216,728 (66.480%) | 330,916 (77.867%) |
| `length_error` | 102,895 (31.562%) | 94,058 (22.133%) |
| CRC error | 0 | 0 |
| sync error | 0 | 8 |
| `row_idx` 越界 | 16,271 | 12,750 |
| `row_flags==0x58` | 30,835 | 45,441 |
| `row_flags==row_idx low byte` 且 payload/sync/CRC 形态正常 | 30,533 | 1,835 |
| FIRST bit 被观察次数 | 21,839 | 854 |
| LAST bit 被观察次数 | 21,934 | 649 |
| overflow bit 被观察次数 | 22,222 | 6 |

attempt8 的 679 条 `rejected.csv` 记录全部含 `overflow`，但同一次运行中 flags
又大量等于 `row_idx` 低字节。FIRST/LAST/overflow 数量远大于图像帧数，说明
这些 bit 主要是被重复到 offset 9 的普通数据位，不是真实容量溢出。

attempt9 的 163.509 s 不能直接与 attempt8 的 42.425 s 做速率因果比较：
attempt9 中存在最长 106.154 s 的停止区间，并分成两个活动段：

- 287,046 包 / 38.922 s，7,374.8 pkt/s，length error 21.29%；
- 137,928 包 / 18.432 s，7,483.0 pkt/s，length error 23.89%。

两个活动段之间 `frame_id` 从 598 回到 0。因此“2,599 pkt/s 时错误更低”不是
PCLK 速率证据，而是把 SW15/停机空窗计入总时长造成的平均值失真。

## 3. 首个错误点

### 3.1 候选字节回放

旧条件为：

```verilog
if (pclk_sync_rise && !pclk_level)
    data_on_pclk_rise <= data_sync;
```

`pclk_level` 是上一拍资格状态。合法 rise 与资格下降同拍时，非阻塞赋值语义
使该条件仍看到旧高电平，于是候选字节不更新；之后资格脉冲照常输出，便重复
上一 byte。新增回归在 100 MHz sys_clk 下使用 30 ns 高、20 ns 低的合法边界
相位。修改前 byte count 仍为 128，但 index 1..127 全部读回旧 `0x00`；这与
attempt8 “flags 等于 row_idx 低字节”的静默回放类型一致。

### 3.2 127-byte 合并

旧滤波只有“连续 N 拍全低”才把 `pclk_level` 拉低。一拍短高样本会清掉低相位
连续性；下一真实高相位到来时，资格电平仍为高，因而不再产生新 rise。历史
ILA 已记录这种 127-byte 行。本轮没有把阈值改成 127/129，也没有清除错误位
来掩盖问题。

### 3.3 不是 PC capture queue 的首因

这些包已经进入 `rows.csv`，并携带系统性的 header 位移、`0x58`、越界
`row_idx` 和重新计算后正确的 CRC。PC 队列整包 drop 只能形成序号缺口，不能
把一个已接收包的 offset 9 稳定变成 `0x50 | 0x08`，也不能制造
`row_flags==row_idx low byte`。因此本轮首个可证明错误点在 MAC 前的 Camera
输入/组包路径。

## 4. 实际修改

### 4.1 `Camera_Capture.v`

- 每个 `pclk_sync_rise` 无条件刷新 `data_on_pclk_rise`，去掉旧资格电平门控；
- 用两阶段 PCLK 资格器替代“高低都必须连续”的电平投票：
  - 等待低相位时，短高 runt 不清空已经积累的低证据；
  - re-arm 后，高相位必须连续达到 `PCLK_FILTER_LEN` 才产生一次 byte event；
  - 短高 runt 因达不到连续高门槛而不会产生 byte；
- HREF fall 只置 `line_end_pending`；资格器完成最后一个 PCLK 并重新进入低相位
  后才提交行；
- SW15 仍只作为边界安全的 capture request，不复位 Line Buffer/Byte FIFO/Taxi。

### 4.2 `Line_Buffer.v`

- `capture_flags[3]` 表示长度不为 128 时，释放当前预留 slot，不 commit、不发包；
- 因此不再把 127/129-byte 输入补齐/截断后交给 Byte Replacer 重算成 CRC-valid
  垃圾包；接收端通过 `row_seq` gap 和缺失 `row_idx` 识别该行并按既有策略处理；
- 容量 drop 的 `frame_overflow_pending` 只 OR 到下一条有效包，然后清零；不再
  依赖 Camera_Capture 已经不生成的 `capture_flags[1]`。

### 4.3 ILA

64 个 probe 端口总数不变。Cam0 的两个旧投票观察口改为：

- `pclk_low_count[1:0]`；
- `pclk_high_count[1:0]`；
- 最后一个 probe 改为 `pclk_phase_armed`。

原 `pclk_sync`、`pclk_pulse`、`data_on_pclk_rise`、`byte_valid`、byte count、
line end、length error、FIFO 和 Ethernet 探针全部保留。

### 4.4 保持不变

`Byte_Replacer.v` 未修改：offset 4 cam_id、offset 9 flags OR、offset 126/127
CRC-16 重算全部保持。没有把 FPGA 状态塞入 reserved byte，也没有修改 Python
协议或放宽 Layer3。

## 5. 测试与构建

| 验证 | 结果 |
|---|---|
| `tb_Camera_Capture_Pclk_Glitch` 修改前 | FAIL：count 128，但 index 1..127 回放旧 byte |
| `tb_Camera_Capture_Pclk_Glitch` 修改后 | PASS：20 MHz 边界相位 + 3 个单周期高 runt，2×128 byte 全相等 |
| `tb_Camera_Capture_Boundary_Control` | PASS：SW15 中途启停只在行边界生效 |
| `tb_Line_Buffer` | PASS：overflow 一次报告、下一包清零、127-byte 行不出队 |
| `tb_Camera_Pipeline` | PASS：四路结构/仲裁/header/CRC；短包不进入输出 |
| `tb_Camera_Pipeline_Ethernet_Source` | PASS：3 帧，packet handshake 384，frame handshake 426，stall/TLAST 覆盖 |
| Python `pytest` | PASS：102 passed；仅 `.pytest_cache` WinError 183 warning |
| Vivado source/top/generic 检查 | PASS：`Camera_Ethernet_Top`，Camera/Byte FIFO path 均为 1 |
| 普通实现 | PASS：WNS +1.815 ns，WHS +0.026 ns，route error 0，DRC Error/Critical 0 |
| 新 ILA bit/ltx | 生成完成后见第 7 节 |

普通实现仍有既有 warnings，包括未完整定义外部 input/output delay、Taxi IOB
属性和 BRAM async control 检查；不能把数字实现 PASS 写成 Camera 硬件 PASS。

## 6. CC 建议的取舍

| 建议 | 本轮处理 | 原因 |
|---|---|---|
| 停止 FPGA CRC 重算 | 不采用 | 用户明确要求 FPGA 重算以减轻 MCU；代码保持原样 |
| 无效长度行不发送 | 已采用 | 防止错误内容被补齐并重算为 CRC-valid 包 |
| 取消 offset 9 OR | 暂不采用 | 会改变现有协议；丢字节根因修复且无效行已在 OR 前丢弃 |
| 修候选数据门控 | 已采用 | 有 CSV 签名、RTL 条件和先失败后通过仿真三重证据 |
| 修 sticky overflow | 已采用 | 清零依赖已不存在的 capture LAST，属于确定死条件 |
| reserved 增加 FPGA seq | 暂不采用 | 协议变更，需要 RP/Python 同步版本化，不应混入止损修复 |
| receiver 接受 degraded 行 | 不采用 | 保持 Layer3 严格，不使用已知损坏 payload |
| session epoch | 后续独立项 | attempt9 的 598→0 已证实重启/重新采集，需软件版本化设计 |
| VSYNC 帧边界启停 | PENDING | 当前 FPGA 接口只有 DATA/PCLK/HREF，没有可核实 VSYNC 输入 |
| PCLK 域采集 + async FIFO | 推荐的最终根治，未在本轮强行实施 | Cam0 PCLK=D14/JB1、Cam1 PCLK=H4/JD1，Master XDC 均不是 MRCC/SRCC；需先改接时钟能力引脚 |

可选硬件重布线方向是 Cam0 使用 JB3/G16 或 JB10/H16，Cam1 使用 JD10/F3；
它们在 Master XDC 中标有 MRCC。此项必须先确认实际接线和板级时序，再设计
PCLK-domain FIFO，不能通过 `CLOCK_DEDICATED_ROUTE FALSE` 强行掩盖。

## 7. 新硬件产物与下一次验收

带 ILA 的新实现于 2026-08-01 18:55 完成，Vivado 日志明确输出
`ILA_BUILD_RESULT=PASS`、`ILA_CORE_COUNT=2`、`ILA_PROBE_COUNT=64`。产物必须成对使用：

| 产物 | 路径 | SHA-256 |
|---|---|---|
| bitstream | `build/ethernet_ila/Camera_Ethernet_Top_ila.bit` | `137CA7BFE04F8ABA17FDFE7B66EA9E342D8343C2B9B02882CF6C1D4A043538C7` |
| debug probes | `build/ethernet_ila/Camera_Ethernet_Top_ila.ltx` | `977B1EB580BB21A1BD5937FADA1A6C7F61C620D2832E01C43B2F518B57206341` |
| routed DCP | `build/ethernet_ila/Camera_Ethernet_Top_ila_routed.dcp` | `71B38C39BD7BEF5F88755E8969F264C547790A8CFFDE278180F6D9AB14BD9EED` |

实现后时序为 WNS `+1.304 ns`、WHS `+0.025 ns`，所有用户时序约束满足，TNS/THS
均为 0。写 bitstream 前的 DRC 为 0 Error、0 Critical Warning；独立 DRC 报告仍有 40 条
Warning，主要是已有的配置电压属性、Taxi IOB 属性、BRAM 异步控制和 debug hub 路由提示，
因此状态应写作 **Digital implementation: PASS WITH WARNINGS**，不能写成板级 Camera PASS。

旧配对文件已归档至：
`build/ethernet_ila/archive_before_attempt8_attempt9_fix_20260801_1850/`。旧 bit 的 SHA-256
为 `13A5CCD659B3CA43D17860D9DA0C6D008E8221CBDCA3719CBA7F0396A74A325A`，旧 ltx 的
SHA-256 为 `1A073FB16BB947EC7E0F73E4BBCC203676043FFF0FCFE19B7D4C2A7B7ADE6407`，不得和新产物混用。

下一次板测必须使用同一次生成的 bit/ltx，并按以下顺序判定：

1. ILA 触发 `camera_length_error_pulse_dbg==1`；若抓不到，再触发
   `camera_capture_byte_valid_dbg==1`；
2. 一条正常 HREF 内必须有 128 次 `pclk_pulse/byte_valid`，候选 byte 连续；
3. 短高样本出现时，`pclk_low_count` 进度可保留，但 `pclk_pulse` 不得多发；
4. 采集新的 PCAP/CSV，比较 `sequence_gaps`、FIRST/LAST、越界 row_idx；
5. 由于无效长度行现在不会上网，PC 侧 `length_errors` 应趋近 0；不能只看该值，
   还必须看 `row_seq` gaps 和 ILA 的实际 byte count；
6. 硬件 PASS 门槛：`row_flags==row_idx low byte` 静默回放归零、`0x58` 左移类
   归零或降至可解释的极低值、每帧 0..479 行闭合、usable fps 接近源帧率。

本报告的 RTL PASS 与 implementation PASS 已建立；新 bit 的板级 Camera/图像
结果仍是 PENDING，必须由新 ILA/PCAP/CSV 关闭。
