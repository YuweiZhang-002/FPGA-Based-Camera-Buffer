# P1 LENGTH_ERROR 板上根因报告

> 日期：2026-07-24  
> 状态：`ROOT_CAUSE_LOCALIZED`；上游最终修复仍为 `PENDING`  
> 范围：Camera 0 输入、`Camera_Capture` 行长度判定、ILA 与现有 Ethernet 发送链。  
> 本阶段没有修改 Taxi core，也没有改变
> `Camera_Pipeline -> Byte_FIFO -> Frame Adapter -> Taxi -> RMII` 数据选择或握手。

## 1. 结论

此前看到的 `511` 不是本次 Camera 行的真实长度，也不是应改成的新阈值。
它来自原 9-bit 计数器的饱和值，无法区分 511 和更长输入。

板上重新构建、下载并连续抓取后，直接触发
`camera_length_error_dbg = row_flags[3]` 得到：

| 抓取 | 触发条件 | 触发前一行 | 报错行实际计数 | `row_flags` |
|---|---|---:|---:|---:|
| capture 1 | 判定脉冲 | 128 | 130 | `0x08` |
| capture 2 | 判定脉冲 | 128 | 129 | `0x08` |
| capture 3 | 原始 `row_flags[3]` | 128 | 129 | `0x08` |

因此当前唯一可由硬件证据支持的根因是：

```text
Camera/RP2350A 接口的部分 HREF 窗口内，FPGA 实际观察到 129 或 130 个
PCLK 上升沿，而当前协议要求每个 HREF 窗口严格等于 128 byte。
```

这不是固定的“阈值写错为 511”。也不能简单把阈值改成 129 或 130，
因为相邻正常行确实为 128，错误行长度又在 129/130 间变化。

ILA 还证明报错时下游仍完成了 128 次 Camera packet handshake，并产生
RMII TX 活动。`Line_Buffer` 只保存前 128 byte，因此 `LENGTH_ERROR`
是输入成帧异常标志，不等于 Ethernet 链完全停止。

## 2. 判定逻辑的源码证据

- `Camera_Capture.v:57-72`：PCLK 经 `Alarmer` 同步/边沿检测；本阶段把
  `byte_count` 从 9 bit 扩为 16 bit，仅用于避免 511 饱和值隐藏真实长度。
- `Camera_Capture.v:119-131`：在同步后的 HREF 有效期内，每个
  `pclk_pulse` 使计数加一。
- `Camera_Capture.v:136-147`：HREF 下降时锁存计数，并以
  `byte_count != PACKET_BYTES` 产生 `row_flags[3]`；当前
  `PACKET_BYTES=128`。
- `Alarmer.v:5-13,23-39`：PCLK 是异步输入，经两级同步后在 100 MHz
  域检测上升沿。源码同时明确说明：若采样速率/数据稳定时间不满足，
  应改成 PCLK 写侧异步 FIFO。
- `Line_Buffer.v:143-145,210-227`：即使 HREF 更长，也只写入前
  `PACKET_BYTES=128` byte；多出的 PCLK byte 不会扩大 Ethernet payload。
- `Camera_Ethernet_Top.sv:221-229`：Camera 模式仍把
  `camera_packet_*` 直接选到既有 Ethernet packet 接口。

## 3. ILA 直接证据

### 3.1 新增探针

| 探针 | 含义 |
|---|---|
| `camera_current_byte_count_dbg[15:0]` | 当前 HREF 的实时计数 |
| `camera_last_line_byte_count_dbg[15:0]` | HREF 下降判定时锁存值 |
| `camera_line_flags_dbg[7:0]` | 原始行 flags |
| `camera_length_error_dbg` | `camera_line_flags_dbg[3]` |
| `camera_length_error_pulse_dbg` | 与长度比较同拍的一周期事件 |
| `camera_capture_byte_valid_dbg` | 被 Camera_Capture 接受的 byte 脉冲 |

新 `.ltx` 回读后，设备报告 1 个 ILA、上述全部探针存在。

### 3.2 第三次直接触发

触发条件：

```text
camera_length_error_dbg == 1
```

触发样本 512：

```text
camera_current_byte_count_dbg   = 0x0081 = 129
camera_last_line_byte_count_dbg = 0x0081 = 129
camera_line_flags_dbg           = 0x08
camera_line_end_dbg             = 1
camera_length_error_dbg         = 1
camera_length_error_pulse_dbg   = 1
前一行 last_line_byte_count     = 128
```

该窗口末端的有效 byte 事件为：

```text
count 126 -> data 0x00
count 127 -> data 0x00
count 128 -> data 0xFF
count 129 -> data 0xFF
```

在 count 129 时，ILA 采到原始 HREF 仍为高；之后 HREF 拉低，四个
100 MHz 样本后产生同步域 `line_end`/`LENGTH_ERROR` 判定。因此本次
多计数不是 HREF 已经明确为低后仍盲目计数，而是接口端实际提供了额外
PCLK/HREF 有效重叠。其最终来源仍需结合 RP2350A 固件确认。

### 3.3 下游同一窗口

```text
camera_packet_valid && camera_packet_ready = 128 次
rmii_tx_en_dbg 高电平样本              = 1232
tx_error_underflow                     = 0
tx_fifo_overflow                       = 0
```

这说明：

- Camera `Line_Buffer` 到 Taxi/RMII 数据链仍在运行；
- 发送的是固定 128-byte payload；
- `row_flags[3]` 报告的是输入 HREF/PCLK 长度不一致；
- RMII 内部活动不能替代 PC 端 Camera PCAP 验收。

## 4. 构建与下载结果

新 ILA 构建：

```text
ILA_BUILD_RESULT = PASS
ILA_PROBE_COUNT  = 42
route failed nets = 0
WNS = +0.795 ns
WHS = +0.035 ns
timing constraints met
bitstream DRC errors = 0
```

DRC 报告有 40 条 warning，主要包括未设置配置 bank 属性、Taxi MII
内部寄存器的 IOB 属性不适用于当前 RMII wrapper、BRAM 异步控制和
debug hub LUT 检查。本阶段未把这些 warning 解释为硬件验收 PASS。

产物：

```text
build/ethernet_ila/Camera_Ethernet_Top_ila.bit
SHA-256 4224EF7C73BBB4437723D92E17FCE5B61372D18DA90295FE8A35A69DA52A1036

build/ethernet_ila/Camera_Ethernet_Top_ila.ltx
SHA-256 807EA17323EE4D854B5AFB4AA5ECE166D0816FB41446CCBB02DBF3BA271B763B
```

旧工作版本已成对保存在：

```text
build/ethernet_ila/archive/pre_p1_20260724_1443/
```

## 5. 证据文件

| 文件 | 用途 |
|---|---|
| `build/ethernet_ila/camera_length_error_pulse_dbg_capture_1.csv` | 130-byte 错误行 |
| `build/ethernet_ila/camera_length_error_pulse_dbg_capture_2.csv` | 129-byte 错误行 |
| `build/ethernet_ila/camera_length_error_dbg_capture.csv` | 直接以 `row_flags[3]` 触发的 129-byte 错误行 |
| `build/ethernet_ila/timing_summary.rpt` | 实现后时序 |
| `build/ethernet_ila/drc.rpt` | 实现后 DRC |
| `scripts/build_ethernet_ila.tcl` | 42 探针插入 |
| `scripts/capture_ethernet_ila.tcl` | 可选探针触发与 CSV 导出 |

## 6. 修复边界与下一步

### 不应实施

- 不应把 `PACKET_BYTES` 改成 511。
- 不应把严格阈值直接改成 129 或 130。
- 不应仅清除 `LENGTH_ERROR` flag 来掩盖问题。
- 不应修改 Taxi core；该问题发生在 Taxi 之前。

### 应优先核实

1. RP2350A 固件是否在 128 个数据 byte 后又产生 1～2 个 PCLK 脉冲；
2. HREF 拉低相对最后一个 PCLK 的固件指令顺序；
3. 额外 `0xFF` 是明确的尾部/空闲符号，还是 GPIO/HSTX 停止过程；
4. 若 RP2350A 保证严格 128 byte，则用示波器/逻辑分析仪同步验证
   PCLK、HREF、D[7:0]，再判断 FPGA 两路独立同步是否造成边界歧义；
5. 长期可靠方案是 PCLK 域采样数据并经异步 FIFO 跨到 100 MHz，
   但这是架构修复，不能在未核实 RP2350A 时直接实施。

## 7. P1 Gate

| 项目 | 状态 | 结论 |
|---|---|---|
| 直接以 `row_flags[3]` 触发 | PASS | 已完成 |
| 判定瞬间实际 byte count | PASS | 129；另一次为 130 |
| 511 是否真实行长度 | PASS | 否，是旧计数器饱和值 |
| FPGA 下游 128-byte handshake | PASS | 报错窗口内为 128 |
| PCLK/HREF 边界异常定位 | PASS | 部分 HREF 含 1～2 个额外 PCLK |
| RP2350A 固件最终来源 | PENDING | 本仓库无固件源码 |
| 上游修复后 `LENGTH_ERROR=0` | FAIL/PENDING_FIX | 尚未修复并复测 |

