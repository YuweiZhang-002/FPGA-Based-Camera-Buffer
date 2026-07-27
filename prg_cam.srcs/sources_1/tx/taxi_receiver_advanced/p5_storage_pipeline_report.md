# P5 StorageAndPipeline 实施与验证报告

> 日期：2026-07-24  
> 实现状态：`PASS`  
> 真实 Camera 图像状态：`FAIL/PENDING_INPUT_FIX`

## 1. 实现

现有 `FrameReassembler` 已扩展，而非平行新增另一套 receiver：

- session key：`(cam_id, frame_id)`；
- 不同 camera 状态完全隔离；
- row 以 `row_idx` 放置，支持乱序；
- 相同 duplicate 去重；
- conflicting duplicate 不覆盖首包并标记 `CORRUPT`；
- 新 frame ID 到达时关闭同 camera 的旧 frame；
- frame ID 使用相等判断，支持 `65535 -> 0` 回绕；
- last row 先到且仍缺行时保持 session，等待迟到包；
- timeout、flush 和 frame switch 均产生可归档结果；
- 状态：`COMPLETE / PARTIAL / CORRUPT / TIMEOUT`；
- pipeline stop 在 flush 前执行 queue drain，结束时没有未解释积压。

Layer 3 校验失败的 packet 仍进入 Layer 5 作为结构化错误记录，但其
payload 不进入 `image.raw`。

## 2. 原子归档

`StorageAndPipeline` 输出：

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

实现先写：

```text
cam_<id>/.frame_<id>.<uuid>.tmp/
```

全部文件关闭后再 `os.replace()` 为最终目录。已存在的最终目录不会被
覆盖。`summary.csv` 同样通过临时文件重写后原子替换。

当前协议没有 width/height/pixel format，所以：

- 保存 `.raw`；
- metadata 中将三者写为 `null`；
- 不生成 PNG/PGM。

## 3. 测试覆盖

新增 9 项：

1. 乱序 row 自动按 byte 重建并原子归档；
2. 两 camera 交错且互不覆盖；
3. 相同 duplicate 去重；
4. conflicting duplicate 判 `CORRUPT`；
5. 缺一行判 `PARTIAL`；
6. CRC 错不进入 image；
7. frame ID 回绕；
8. 中途 timeout；
9. Synthetic source -> full pipeline -> archive。

结果：

```text
P5 targeted tests   9 passed
full suite run 1   51 passed in 3.25s
full suite run 2   51 passed in 3.24s
```

## 4. 真实 Camera PCAP Layer 1→5 回放

输入：

```text
build/ethernet_ila/camera_live_0x88b5_20260724.pcapng
1000 frames
```

命令入口：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\replay_pcap.ps1 `
  -Pcap D:\prg\prg_cam\build\ethernet_ila\camera_live_0x88b5_20260724.pcapng `
  -OutputRoot D:\prg\prg_cam\build\receiver_output\camera_live_20260724_p5_ps1 `
  -ExpectedRows 480
```

Pipeline 结果：

```text
matching Ethernet = 1000
Layer 3 valid      = 459
length error       = 541
overflow marked    = 2
CRC error          = 0
parser exception   = 0
capture queue drop = 0
```

归档 session：

| frame_id | 收到包 | 接受行 | 缺行 | 状态 | 关闭原因 |
|---:|---:|---:|---:|---|---|
| 31689 | 68 | 25 | 455 | CORRUPT | frame_switch |
| 31690 | 480 | 170 | 310 | CORRUPT | frame_switch |
| 31691 | 452 | 264 | 216 | CORRUPT | flush |

这三个 session 被正确归档为诊断材料，没有任何一个被误标为 COMPLETE。
frame 31689 是抓包从一帧中间开始；31691 是抓包在一帧中间结束；
31690 虽收到 480 包，但 310 行因 capture error flag 未被接受。

## 5. 新运行入口

| 文件 | 用途 |
|---|---|
| `replay_pcap.ps1` | 不依赖 Scapy 的 PCAP/PCAPNG Layer1→5 回放 |
| `run_receiver.ps1` | Scapy/Npcap live capture + Layer1→5 归档 |
| `taxi_receiver.cli --replay-pcap` | Python CLI 离线入口 |

当前机器未安装 Scapy，因此：

- offline replay：PASS；
- dumpcap 真实抓包：PASS；
- Python/Scapy live source：PENDING_ENVIRONMENT。

## 6. 修改文件

```text
taxi_receiver/reassembler.py
taxi_receiver/storage.py
taxi_receiver/stages.py
taxi_receiver/pipeline.py
taxi_receiver/stream_monitor.py
taxi_receiver/cli.py
taxi_receiver/__init__.py
tests/test_storage_and_reassembly.py
replay_pcap.ps1
run_receiver.ps1
README.md
```

没有修改 Taxi core、Ethernet RTL 数据流、XDC、XCI 或 Vivado 自动生成目录。

## 7. P5 Gate

| Gate | 状态 |
|---|---|
| session key / 多 camera 隔离 | PASS |
| 乱序 / duplicate / missing | PASS |
| CRC/flags 错误归类 | PASS |
| timeout / frame switch / wrap | PASS |
| atomic frame directory | PASS |
| summary.csv | PASS |
| raw byte reference compare | PASS |
| Python offline PCAP Layer1→5 | PASS |
| Python live Scapy capture | PENDING_ENVIRONMENT |
| 真实 Camera COMPLETE image | FAIL/PENDING_INPUT_FIX |
| PNG/PGM | PENDING_PROTOCOL_METADATA |

