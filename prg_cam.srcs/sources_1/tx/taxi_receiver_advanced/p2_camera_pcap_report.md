# P2 Camera 模式 PCAP 采集报告

> 日期：2026-07-24  
> 状态：Layer 1/2 `PASS`；Camera 数据可信度 `FAIL/PENDING_FIX`  
> 前置条件：P1 已用 ILA 定位到部分 HREF 含 129/130 个 PCLK。

## 1. 离线回归

使用 Python 3.14.6、pytest 9.1.1 和标准库 PCAP reader：

```powershell
python -m pytest -p no:cacheprovider -q tests/test_pcap_stdlib.py -vv
```

结果：

```text
10 passed in 1.12s
```

其中包括：

- 1,000 帧固定发生器 PCAP；
- 229,629 帧内部 Byte FIFO PCAP；
- Ethernet-II 解码、EtherType/source-MAC filter；
- classic PCAP 与 PCAPNG；
- 截断/非法结构错误处理。

## 2. 当前主机捕获条件

```text
Scapy                         MISSING
Wireshark/dumpcap/tshark      PRESENT
Npcap interface               PRESENT
FPGA 直连有线接口             interface 6（以太网）
PC IPv4                       169.254.35.66/16
PC NIC                        Realtek Gaming GbE Family Controller
```

Scapy 缺失没有阻塞 P2；使用 Wireshark 自带 `dumpcap` 直接调用 Npcap。

## 3. 实时捕获

命令：

```powershell
dumpcap.exe -i 6 -f "ether proto 0x88b5" `
  -a duration:15 -c 1000 `
  -w D:\prg\prg_cam\build\ethernet_ila\camera_live_0x88b5_20260724.pcapng
```

结果：

```text
Packets captured = 1000
Packets dropped  = 0
capture duration = 0.129696 s
observed rate    = 7702.62 packet/s
```

文件：

```text
D:\prg\prg_cam\build\ethernet_ila\camera_live_0x88b5_20260724.pcapng
size    = 176512 byte
SHA-256 = 7A64865C3D1129886627C6721501AB20ECACC8E7B9C4BD3F3EA0B272491F2047
```

## 4. Layer 1/2 结果

| 检查 | 结果 |
|---|---|
| 过滤 EtherType | 1,000/1,000 为 `0x88B5` |
| Ethernet frame length | 1,000/1,000 为 142 byte |
| Ethernet payload length | 1,000/1,000 为 128 byte |
| source MAC | 1,000/1,000 为 `02:00:00:00:00:02` |
| destination MAC | 1,000/1,000 为广播 |
| NIC/dumpcap drop | 0 |

P2 的“真实 Camera 模式帧到达 PC”因此为 `PASS`。这不是完整图像重建 PASS。

## 5. legacy-v0 字段初筛

按当前 `packet_format.py` 的 observed schema 解析：

```text
sync words correct        1000/1000
camera CRC-16 correct     1000/1000
cam_id                    全部 0
frame_id range            31689..31691
row_flags LENGTH_ERROR    541/1000
FRAME_OVERFLOW            2/1000
payload_len == 80         937/1000
payload_len != 80         63/1000
row_seq transition errors 100
row_idx transition errors 14
```

`row_flags` 分布：

```text
0x00: 457
0x08: 528
0x09:   9
0x0C:   2
0x0A:   2
0x02:   1
0x01:   1
```

代表性异常：

```text
packet 67:
  frame_id=31689 row_idx=479 row_flags=0x09
  payload_len=2 row_seq=48976

packet 68:
  frame_id=31690 row_idx=0 row_flags=0x08
  payload_len=0 row_seq=49232

packet 72:
  frame_id=31690 row_idx=1028 row_flags=0x08
  payload_len=0 row_seq=50256
```

正常邻近包的 `payload_len` 为 80，`row_seq` 逐一递增。

## 6. 为什么 CRC 全对仍不能信任全部字段

当前 `Byte_Replacer` 在 FPGA 已捕获 128 byte 之后：

- 写入/确认 cam ID；
- OR 行 flags；
- 对 byte 0..125 重新计算 CRC-16；
- 覆盖 byte 126..127。

因此 Camera CRC-16 能证明：

```text
FPGA 形成的最终 128-byte payload 在 Ethernet 发送到 PC 后未变化。
```

它不能证明：

```text
RP2350A 在 PCLK/HREF 边界之前提供的每个原始 byte 都被 FPGA 正确采样。
```

P1 已观察到 129/130 个 PCLK；P2 又观察到 `payload_len`、`row_seq` 和
`row_idx` 的间歇异常。两者共同说明，在修复/确认 RP2350A 发送边界和
FPGA 输入 CDC 之前，Camera PCAP 只能用于 Layer 1/2 与异常诊断，不能
作为图像像素可信基线。

## 7. P2 Gate

| Gate | 状态 |
|---|---|
| 固定链 PCAP stdlib 回归 | PASS |
| 当前有线接口识别 | PASS |
| 真实 Camera 0x88B5 捕获 | PASS |
| 1,000 帧归档 | PASS |
| Ethernet header/长度稳定 | PASS |
| Camera sync words | PASS |
| FPGA 生成 CRC-16 | PASS |
| Camera metadata 连续性 | FAIL |
| Camera payload 可用于图像重建 | FAIL/PENDING_FIX |
| Scapy live source | PENDING（Scapy 未安装） |

