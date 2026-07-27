# P3 RP2350A 字段来源审计

> 日期：2026-07-24  
> 状态：FPGA-owned 字段 `CONFIRMED`；RP2350A-owned 字段
> `SOURCE_MISSING`  
> 规则：只把当前活动 RTL 和 2026-07-24 Camera PCAP 当作证据。

## 1. 结论

当前 `D:\prg\prg_cam` 仓库中没有 RP2350A 固件源码：

```text
*.c        0
*.h        0
*.pio      0
CMakeLists 0
```

因此无法从本仓库证明 `frame_id`、`row_idx`、`payload_len`、
`row_seq` 和 trailer 统计字段由 RP2350A 的哪一函数、哪一状态机生成。

当前只能确认：

- FPGA 输入每个 HREF 应是一个已经封装好的 128-byte packet；
- 活动 RTL 不重建上游 header；
- FPGA 只改写 cam ID、OR flags、重算 CRC；
- Camera PCAP 中确实观察到符合当前 Python layout 的 sync/header/trailer
  数值，但这是 `legacy-v0-observed`，不是固件源码定义。

## 2. 128-byte observed layout

当前 `packet_format.py` 的 little-endian layout：

| offset | length | 字段 | 当前可确认来源 |
|---:|---:|---|---|
| 0 | 2 | `sync0=0xA5A5` | 上游输入；PCAP 观察到 |
| 2 | 2 | `sync1=0x5A5A` | 上游输入；PCAP 观察到 |
| 4 | 1 | `cam_id` | **FPGA Byte_Replacer 覆盖** |
| 5 | 2 | `frame_id` | 上游输入；RP 源码缺失 |
| 7 | 2 | `row_idx` | 上游输入；RP 源码缺失 |
| 9 | 1 | `row_flags` | 上游值 OR FPGA flags |
| 10 | 1 | `payload_len` | 上游输入；RP 源码缺失 |
| 11 | 2 | `row_seq` | 上游输入；RP 源码缺失 |
| 13 | 11 | `reserved` | 上游输入；语义未确认 |
| 24 | 80 | row payload | 上游输入；像素语义未确认 |
| 104 | 10 | pad | 上游输入；语义未确认 |
| 114 | 4 | `m00` | 上游输入；算法来源缺失 |
| 118 | 2 | `xc_q4` | 上游输入；算法来源缺失 |
| 120 | 2 | `yc_q4` | 上游输入；算法来源缺失 |
| 122 | 2 | `vx_q8` | 上游输入；算法来源缺失 |
| 124 | 2 | `vy_q8` | 上游输入；算法来源缺失 |
| 126 | 2 | CRC-16 | **FPGA Byte_Replacer 重算/覆盖** |

当前 schema 没有 version 字段，因此名称必须保持
`legacy-v0-observed`，不能宣称已具备可演进的正式协议版本。

## 3. FPGA-owned 字段证据

活动模块 `Byte_Replacer.v:5-18,20-24,67-97` 明确定义：

```text
offset 4   = {6'd0, in_cam_id}
offset 9   = original row_flags OR in_row_flags
offset 126 = CRC low
offset 127 = CRC high + packet_last
CRC coverage = modified bytes 0..125
```

`Camera_Capture.v:32-41,122-153` 生成的 FPGA flag：

| bit | 含义 | 来源 |
|---:|---|---|
| 0 | FIRST_ROW | FPGA 内部 `row_idx==0` |
| 1 | LAST_ROW | FPGA 内部 `row_idx==LINES_PER_FRAME-1` |
| 2 | FRAME_OVERFLOW | `Line_Buffer` 容量事件 |
| 3 | LENGTH_ERROR | HREF 内 PCLK count 不等于 128 |

关键限制：

- `Camera_Capture` 的内部 `current_row_idx` 没有写回 packet offset 7..8；
- packet 中的 `row_idx` 仍是上游原始 byte；
- 因此 P2 中 `row_idx=1028/32896` 不能由 FPGA 的内部行计数解释。

## 4. 当前 PCAP 的 observed evidence

`camera_live_0x88b5_20260724.pcapng`：

- 1,000/1,000 sync words 为 `A5 A5 5A 5A`；
- frame ID 观察到 31689..31691；
- 正常包中 row index 与 row sequence 连续；
- 63 包 `payload_len` 异常；
- 100 个 row sequence transition 异常；
- 14 个 row index transition 异常；
- CRC 仍全部正确，因为 FPGA 在异常数据被采入后重新计算。

这证明 observed layout 对多数包具有解释力，但也证明输入采样/上游边界
当前不够可靠，不能反过来用 PCAP 猜固件字段生成规则。

## 5. 仓库内冲突

### 5.1 Header 长度冲突

`Camera_Capture.v:10-13` 的注释写：

```text
existing 16-byte header and 2-byte CRC tail
```

当前 `packet_format.py` 实际使用：

```text
24-byte header + 80-byte payload + 24-byte trailer = 128 byte
```

活动 `Byte_Replacer` 的 offset 4/9/126/127 与 Python schema 相容，但
“16-byte header”注释不完整或已过时。P3 不修改该注释，只记录冲突。

### 5.2 “mirrors C structures exactly”缺乏本仓库证据

`packet_format.py` 文档字符串称 layout 精确镜像 FPGA-side C structures，
但仓库不存在这些 C structures。基于当前证据，更准确的状态是：

```text
layout matches current observed PCAP and existing Python tests,
but RP2350A source definition is not present.
```

### 5.3 Deprecated formatter 不是当前协议来源

`sources_1/new/deprecated/Packet_Formatter.v` 有另一套旧 offset/flag 语义，
且不在活动层次。禁止用它解释当前 Camera PCAP。

## 6. 需要固件负责人提供的最小证据

至少需要以下任一项：

1. 生成完整 128-byte packet 的 C struct 和序列化函数；
2. PIO/HSTX/GPIO 输出 PCLK、HREF、D[7:0] 的代码；
3. 字段 offset、字节序、计数回绕和 flag 定义；
4. 128 byte 后 HREF/PCLK 停止顺序；
5. `0xFF` 尾部是否是协议字节或停机填充值；
6. 图像 width/height/pixel format 与每行 packet 数。

## 7. P3 Gate

| 项目 | 状态 |
|---|---|
| FPGA cam ID 来源 | PASS/CONFIRMED |
| FPGA flags 来源 | PASS/CONFIRMED |
| FPGA CRC 来源 | PASS/CONFIRMED |
| RP sync 来源 | SOURCE_MISSING |
| RP frame/row/seq 来源 | SOURCE_MISSING |
| RP payload_len 来源 | SOURCE_MISSING |
| RP trailer 统计来源 | SOURCE_MISSING |
| 图像尺寸/像素格式 | SOURCE_MISSING |
| 正式协议 version | MISSING |

