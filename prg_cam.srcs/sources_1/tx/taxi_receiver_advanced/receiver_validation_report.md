# Taxi Camera Receiver 验证报告

> 当前范围：Python/pytest 与离线 PCAP 基线  
> 日期：2026-07-24  
> 下一阶段：P1 `LENGTH_ERROR` 根因排查  
> 本报告没有把固定 PCAP PASS 解释成 Camera 图像链 PASS。

## 1. 基线结论

```text
Python interpreter selection        PASS
Original tests (27)                 PASS
Stdlib PCAP tests (10)              PASS
Full suite run 1 (37)               PASS
Full suite run 2 (37)               PASS
Fixed 1000-frame PCAP regression    PASS
Internal FIFO 229629-frame PCAP     PASS
Scapy/Npcap live capture            PENDING
Camera-mode PCAP                    PENDING
Camera image reconstruction         PENDING
P1 LENGTH_ERROR                     FAIL / NEXT INVESTIGATION
```

本次建立的可重复基线是：

```text
37 passed in 2.78s
37 passed in 2.75s
```

两次测试使用相同解释器、相同测试集，并禁用 pytest cache 和 Python
bytecode 写入。

## 2. Python 与 VSCode 环境

实际通过测试的解释器：

```text
C:\Users\Z\AppData\Local\Python\bin\python.exe
Python 3.14.6
pytest 9.1.1
```

[`D:\prg\prg_cam\.vscode\settings.json`](../../../../.vscode/settings.json)
已经明确设置：

- `python.defaultInterpreterPath`；
- pytest enable；
- receiver tests 路径；
- receiver package analysis path。

因此从工程根目录打开 VSCode 时，应选择上述 Python，而不是
`C:\Users\Z\AppData\Local\Microsoft\WindowsApps\python.exe`。后者只是
Microsoft Store alias，在当前系统上不能运行真实解释器。

当前 `scapy` 未安装。这不阻塞本报告的 37 项离线测试，因为新增的 PCAP
reader 只使用 Python 标准库。live capture 仍需后续安装/配置
Scapy + Npcap。

VSCode 设置文件 SHA-256：

```text
911F41EBC4C4B32F78AA355796A9D67DC70B318AF9B16BADCB3ED182A2E7C15D
```

## 3. 原有 27 项测试

测试命令：

```powershell
$py = 'C:\Users\Z\AppData\Local\Python\bin\python.exe'
Set-Location D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver
$env:PYTHONDONTWRITEBYTECODE = '1'
$env:PYTHONHASHSEED = '0'
& $py -m pytest -p no:cacheprovider -q `
  tests/test_camera_parser.py `
  tests/test_packet_format.py `
  tests/test_pipeline_synthetic.py `
  tests/test_reassembler.py `
  tests/test_stages.py `
  tests/test_stream_monitor.py `
  tests/test_threshold_recover.py
```

实际结果：

```text
...........................                                              [100%]
27 passed in 1.70s
```

该结果证明当前已有的 synthetic schema、CRC、parser、monitor、stage
composition、基础 reassembler 和 threshold recovery tests 可以在本机
Python 3.14.6 上运行。

它不证明：

- RP2350A 实际字段来源；
- Camera 行长度；
- Camera payload 已到达 PC；
- 完整图像存储功能。

## 4. 标准库 PCAP Layer 1

扫描时仓库并不存在先前计划中提到的 `pcap_stdlib.py` 和
`test_pcap_stdlib.py`。为完成 27+10 基线，新增：

- [`pcap_stdlib.py`](taxi_receiver/taxi_receiver/pcap_stdlib.py)；
- [`test_pcap_stdlib.py`](taxi_receiver/tests/test_pcap_stdlib.py)。

`pcap_stdlib.py` 不依赖 Scapy，提供：

- little/big-endian classic PCAP；
- microsecond/nanosecond timestamps；
- PCAPNG Section Header、Interface Description、Enhanced Packet、
  Simple Packet 和旧 Packet blocks；
- 多 section/interface；
- Ethernet-II header decode；
- EtherType 和 source-MAC filter；
- `StdlibPcapReplayFrameSource`；
- 截断、非法 block length、非法 link type 的明确异常。

代码 SHA-256：

```text
pcap_stdlib.py
9B022050998011F39A59D9921B644FD15501118E1317D5F27F42ED6B9B40489A

test_pcap_stdlib.py
486B7F4BDEA866491CECDBBC41A3B9BDD51FB634CE356D6D1C93FC4E3F91172F
```

## 5. 新增 10 项测试

覆盖：

1. Ethernet header/payload decode；
2. 短 Ethernet frame 拒绝；
3. little-endian classic PCAP；
4. big-endian nanosecond classic PCAP；
5. little-endian PCAPNG；
6. big-endian PCAPNG；
7. EtherType/source-MAC filter 和 FrameSource callback；
8. 截断 capture 的明确错误；
9. 仓库 1,000 帧 PCAP 完整回归；
10. 仓库 229,629 帧 PCAP 完整回归。

命令：

```powershell
& 'C:\Users\Z\AppData\Local\Python\bin\python.exe' `
  -m pytest -p no:cacheprovider -q tests/test_pcap_stdlib.py -vv
```

实际结果：

```text
collected 10 items
10 passed in 1.09s
```

### 5.1 固定 1,000 帧 PCAP

文件：

[`wireshark_fixed_1000.pcapng`](../../../../build/ethernet_ila/wireshark_fixed_1000.pcapng)

SHA-256：

```text
EDE9545ED888C1EB7E08DF5FF46343F92375614FAE6B0F5971B83E76F614BF57
```

自动检查每一帧：

- frame length = 142；
- dst = `FF:FF:FF:FF:FF:FF`；
- src = `02:00:00:00:00:02`；
- EtherType = `0x88B5`；
- payload length = 128；
- payload 精确等于 `00..7F`；
- Layer 2 validation PASS。

结果：`1000/1000 PASS`。

### 5.2 内部 Byte FIFO 229,629 帧 PCAP

文件：

[`internal_byte_fifo_0x88b5.pcapng`](../../../../build/ethernet_ila/internal_byte_fifo_0x88b5.pcapng)

SHA-256：

```text
5729041D57D7DB8C9814688C2757B7CC88E5247C2FBD22E4B89142D5FFFCC518
```

执行与上一节相同的逐帧检查。

结果：`229629/229629 PASS`。

这两项只建立 Fixed/Internal Byte FIFO PCAP 的 Layer 1/2 基线，不是
Camera metadata 或图像重建 PASS。

## 6. 全量 37 项重复运行

命令：

```powershell
$py = 'C:\Users\Z\AppData\Local\Python\bin\python.exe'
Set-Location D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver
$env:PYTHONDONTWRITEBYTECODE = '1'
$env:PYTHONHASHSEED = '0'
& $py -m pytest -p no:cacheprovider -q
& $py -m pytest -p no:cacheprovider -q
```

结果：

```text
FULL BASELINE RUN 1
.....................................                                    [100%]
37 passed in 2.78s

FULL BASELINE RUN 2
.....................................                                    [100%]
37 passed in 2.75s
```

重复运行均返回 exit code 0。

## 7. P1 入口状态

当前唯一明确的硬件 FAIL 仍是：

```text
Camera ILA payload row_flags = 0x08
row_flags[3] = LENGTH_ERROR
```

进入 P1 后需要直接捕获错误判定瞬间，而不是继续使用固定链 PCAP 或把
`frame_last` 当成错误触发。

当前 RTL 的事实是：

- `Camera_Capture.byte_count` 是 9-bit，统计一个 HREF 窗口内检测到的 PCLK
  byte 数；
- `PACKET_BYTES` 当前为 128；
- `line_flags[3]` 在 HREF 结束时根据实际 byte count 判定；
- Line Buffer/FIFO 的 `used_count`、`fifo_level` 等计数不是 Camera
  `byte_count`，不能把显示值 511 直接解释为一行 511 bytes；
- 当前 ILA probe list 尚未直接包含 `Camera_Capture` 的 byte count 或
  `line_flags[3]`。

P1 的下一步应先核对到底是哪一个名为 count/level 的信号显示 511，再对
真实判定寄存器加 `MARK_DEBUG`/ILA probe。该修改属于后续 P1，不属于本次
Python 基线。

## 8. 当前 gate matrix

| Gate | 状态 | 证据 |
|---|---|---|
| Python 解释器 | PASS | Python 3.14.6 |
| pytest | PASS | pytest 9.1.1 |
| VSCode workspace interpreter | PASS | `.vscode/settings.json` |
| 原有 27 tests | PASS | `27 passed in 1.70s` |
| 新增 PCAP 10 tests | PASS | `10 passed in 1.09s` |
| 全量 37 tests run 1 | PASS | `37 passed in 2.78s` |
| 全量 37 tests run 2 | PASS | `37 passed in 2.75s` |
| Scapy/Npcap | PENDING | 当前未安装 |
| live capture | PENDING | 等待 Npcap 与 P1 |
| Camera PCAP | PENDING | 现有 PCAP 都是固定 payload |
| `LENGTH_ERROR` | FAIL | 当前 ILA Camera 包 flag 0x08 |
| Layer 3 加固 | PENDING | P4 |
| Layer 5 storage | PENDING | P5 |
| GUI/ILA 可复现性 | PENDING | P6 |

## 9. 基线复现命令

从任意 PowerShell：

```powershell
$py = 'C:\Users\Z\AppData\Local\Python\bin\python.exe'
$receiver = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'

Set-Location $receiver
$env:PYTHONDONTWRITEBYTECODE = '1'
$env:PYTHONHASHSEED = '0'
& $py -m pytest -p no:cacheprovider -q
```

预期输出：

```text
37 passed
```

如果 pytest collection 不是 37，先检查：

1. VSCode/终端解释器是否为本报告中的 Python；
2. `tests/test_pcap_stdlib.py` 是否存在；
3. 工作目录是否为 receiver package 根目录；
4. 两份 `build/ethernet_ila/*.pcapng` 是否存在且 hash 一致。
