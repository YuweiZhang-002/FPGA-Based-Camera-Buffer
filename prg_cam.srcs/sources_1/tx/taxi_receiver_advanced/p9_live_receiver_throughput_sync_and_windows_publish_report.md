# P9 Live Receiver 吞吐、Sync 字节序与 Windows 发布修复报告

> 日期：2026-07-27  
> 范围：仅 Python receiver、测试和启动脚本  
> 未修改：Taxi core、FPGA RTL、XDC、XCI、BD、Vivado 生成目录

## 1. 本轮输入证据

现场运行：

```text
Elapsed             : 178 s
Matching Ethernet   : 57173
Capture queue drops : 1143766
Valid packets       : 0
first-row packets   : 0
last-row packets    : 114
length errors       : 1176
```

该运行中，进入 receiver 的总量至少为 `57173 + 1143766 = 1200939`，
队列前丢弃率约 `95.24%`。因此 1176 个 LENGTH_ERROR、114 个 LAST_ROW
和任何帧完整性比例均不具有硬件诊断代表性。

## 2. CSV 吞吐根因

源码审查确认两个独立热点：

1. `CameraImagePipeline` 每个包都重新打开 `rows.csv`、读取一次 header、
   写一行后关闭；
2. `SessionAuditLogger._write_row()` 保持文件打开，但每一个包都明确调用
   `flush()`。

原实现没有对 `rows.csv` 每包调用 `fsync()`，但每包 open/read/write/close
和第二份 CSV 每包 flush 足以阻塞唯一 worker。

修复后：

- 每个 cam 的 `rows.csv` 使用持久文件句柄；
- `rows.csv` 和 `session_audit.csv` 每 256 行或 0.5 秒 flush；
- `rows.csv` 遇到 LAST_ROW 时额外 flush，保证整帧审计及时可见；
- CLI 退出时在 `finally` 中关闭两个 logger；
- `run_receiver.ps1` 的 live queue 默认从 8192 提升为 65536；
- PCAP replay 继续使用无损 backpressure；live capture 仍保留 queue full
  丢弃计数，避免掩盖主机过载。

## 3. `valid_packets=0` 与 frame 目录并不矛盾

统计路径没有断开：

- `MonitoringStage` 对每个结构可解析 Camera 包调用
  `record_camera_result()`；
- `camera.packets/first_row/last_row` 按原始 header/flag 计数；
- 只有 `CameraModeResult.ok` 才增加 `valid_packets`；
- Reassembler 会接收带 `bad_sync/CRC/flags` 错误的结构化包，但不把其
  payload 接受为有效行；
- session 关闭后状态为 `CORRUPT`，原有 `StorageAndPipeline` 仍会把
  CORRUPT/PARTIAL/TIMEOUT 作为错误证据归档。

因此出现 `frame_24618` 只证明 header 能被 unpack、session 被关闭并尝试
归档，不证明 Layer3 valid，更不证明图像 COMPLETE。新增回归测试明确覆盖：

```text
valid_packets = 0
camera packets = 1
last-row packets = 1
completed evidence session = CORRUPT
accepted row_count = 0
```

真正的统计命名问题是 worker 顶层原来把 storage/callback 的异常也记作
`Parser errors`。现在已分为：

- `Parser errors`：解析器内部异常；
- `Processing errors`：storage/observer/其他 stage 抛出的异常。

## 4. WinError 5

`StorageAndPipeline` 在 `os.replace(temp_dir, final_dir)` 前使用的
`Path.write_bytes()`、`Path.write_text()` 和 `with path.open()` 均已结束，
本进程没有故意保持这些临时文件句柄。

Windows Defender、索引器或其他扫描进程仍可能短暂持有目录内文件，使目录
rename 返回 WinError 5/32。修复只对 Windows 的这两个错误执行有限重试：

```text
attempts = 8
delay = 20 ms, 40 ms, 80 ms, ... capped at 500 ms
```

其他错误立即抛出，最终失败时临时目录继续保留，不会被误当成完整归档。
自动测试模拟前两次 WinError 5、第三次成功，结果 PASS。

## 5. Sync、MSB/LSB 与 metadata byte order

当前协议的 C 字段是：

```text
sync0 uint16_t = 0xA5A0
sync1 uint16_t = 0x5A50
```

现场 `rows.csv` 的旧 `<` parser 显示：

```text
sync0 display : 0xA0A5
sync1 display : 0x505A
```

由于 `<HH` 会把 raw `A5 A0 5A 50` 显示为 `0xA0A5/0x505A`，该现场证据
证明线上 raw bytes 已经是用户预期值，错误发生在 Python metadata
byte order，不是 `bit[7:0]` 的 MSB/LSB reversal。

同一批 CSV 中，旧 parser 给出 `row_idx=14081/16641/18945/...`；逐字段交换
byte 后得到约 300 范围内的合理行号。因此当前 parser 对 header 和 trailer
metadata 使用 MSB-byte-first；CRC16 仍按 FPGA `Byte_Replacer` 的
offset126 low byte、offset127 high byte 解析。RP2350A 源码/新 PCAP 不在
工作区，所以该混合端序仍须下一轮 raw PCAP 最终绑定。

工程 RTL 证据：

- `Camera_Ethernet_Top.sv:174`：`camera_data_dbg = GPIO[7:0]`；
- `Camera_Ethernet_Top.sv:207`：直接连到 `cam0_data`；
- `Camera_Capture.v`：`data_meta <= camera_data; data_sync <= data_meta;`
  并直接输出 `byte_data <= data_sync`；
- `Byte_Replacer.v` 只修改 offset 4、9、126、127，不交换 sync bytes；
- XDC 将 GPIO[0..7] 顺序映射到 D0..D7，未见 bit reversal。

Python 已改为：

```python
SYNC0_DEFAULT = 0xA5A0
SYNC1_DEFAULT = 0x5A50
SYNC_BYTES_DEFAULT = bytes.fromhex("a5a05a50")
```

旧 `A5 A5 5A 5A` ILA vector 仍作为 legacy byte/CRC 回归，但不再被误认为
当前 sync valid。

## 6. CRC 性能修复

CRC-16-CCITT-FALSE 原实现对每个 128-byte 包执行约 1008 次 Python bit
循环。已替换为等价的 256-entry lookup table；polynomial、init、无反射、
无 final XOR、覆盖 bytes 0..125 均未改变。

68 项回归和历史 CRC vector 全部通过，说明算法结果保持一致。

## 7. 压力回放结果

输入：

```text
docs/sample_eth_data4.pcapng
78467 个 EtherType 0x88B5 包
同时启用 Layer5、session_audit.csv、rows.csv 和证据归档
```

### 7.1 CRC 查表前

```text
Elapsed             : 10.255 s
Average frame rate  : 7651 packet/s
Capture queue drops : 0
```

### 7.2 CRC 查表后

```text
Elapsed             : 4.757 s
Average frame rate  : 16496 packet/s
Capture queue drops : 0
```

吞吐提高约 `2.16x`。相对现场 ingress 约
`1200939 / 178 = 6747 packet/s`，离线全功能处理速率约为其 `2.44x`。
这不是 live NIC 的最终 PASS，但已建立足够明确的软件吞吐余量。

纯 Layer1-4 回放结果为：

```text
Capture ingress     : 78467
Matching Ethernet   : 78467
Capture queue drops : 0
Average frame rate  : 46160 packet/s
```

旧 PCAP 使用历史 sync，因此在当前 strict parser 下 `Valid packets=0` 是
预期结果。

## 8. 自动验证

```powershell
python -m pytest -q -p no:cacheprovider
```

结果：

```text
68 passed in 4.62s
```

新增/更新覆盖：

- 当前 sync word、MSB-byte-first metadata 与 little-endian CRC tail；
- legacy ILA vector 被标记 bad_sync；
- 结构可解析但 invalid 的包仍可生成 CORRUPT evidence session；
- storage 异常不再被计入 Parser errors；
- Windows WinError 5 transient retry；
- 65536 live queue 启动参数；
- CRC 查表结果与所有既有 vector 一致。

## 9. 下一次 live 冒烟测试

现场 `D:\prg\prg_cam\images\cam0\rows.csv` 已由修改前进程写入约 10 MB；
尾部仍显示旧 parser 的 `sync0=0xA0A5, sync1=0x505A, bad_sync`。Python
进程不会热加载本轮源码，必须先停止旧 receiver，再重新启动。为避免同一 CSV
混入两种 byte-order 语义，先保留并改名旧文件，或为本次验证指定一个全新的
`ImagesRoot`；不要直接追加到旧 `rows.csv`。

使用全新的 OutputRoot，避免旧 evidence 目录的 frame_id 冲突：

```powershell
.\run_receiver.ps1 `
  -Interface '\Device\NPF_{6BDDE37E-7DCA-4078-98B0-E374EFE04E7C}' `
  -OutputRoot D:\prg\prg_cam\build\receiver_output\camera_live_afterfix `
  -ImagesRoot D:\prg\prg_cam\build\receiver_images\camera_live_afterfix `
  -QueueDepth 65536
```

先运行 30 秒，Gate：

| 检查 | PASS 条件 |
|---|---|
| Capture ingress | 持续增长 |
| Matching Ethernet | 与 ingress 基本一致 |
| Capture queue drops | 0 |
| Parser errors | 0 |
| Processing errors | 0 |
| Valid packets | 持续增长且不为 0 |
| sync | raw bytes `A5 A0 5A 50` |
| CRC errors | 0 |
| first-row packets | 持续增长 |
| last-row packets | 持续增长 |
| COMPLETE image | `images/cam0/<frame_id>.pgm/.raw/.json` 出现 |

只有这轮 live Gate 通过后，才能重新解释 LENGTH_ERROR、FIRST/LAST 比例和
完整帧数量。当前准确状态：

```text
Receiver code/tests          PASS
Offline full-path throughput PASS
Current sync parser          PASS
Live capture after fixes     PENDING
Hardware complete images     PENDING
```
