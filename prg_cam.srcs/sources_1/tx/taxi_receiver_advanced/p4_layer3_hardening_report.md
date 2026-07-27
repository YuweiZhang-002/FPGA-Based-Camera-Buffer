# P4 legacy-v0 Layer 3 加固报告

> 日期：2026-07-24  
> 状态：`PASS`  
> 协议名：`legacy-v0-observed`；当前没有 version 字段。

## 1. 实施内容

`camera_parser.parse_camera_mode()` 现在检查：

1. Ethernet payload 必须正好 128 byte；
2. sync 必须为 `0xA5A5/0x5A5A`；
3. `payload_len` 不能超过物理 row payload 的 80 byte；
4. CRC-16-CCITT-FALSE；
5. FPGA `FRAME_OVERFLOW` flag；
6. FPGA `LENGTH_ERROR` flag。

返回结果保留：

```text
reason    第一个失败原因，兼容原调用方
errors    所有失败原因
warnings  非致命但需记录的异常
protocol  legacy-v0-observed
packet    即使校验失败仍保留已解析的强类型字段
```

由于 RP2350A 源码缺失，`payload_len=0` 当前记录为
`zero_payload_len` warning，而不是凭经验判定非法。`payload_len>80`
则无歧义地判为 `payload_len_out_of_range`。

## 2. ILA regression vector

旧 `receiver_architecture_report.md` 中的 hex dump 有 245 个十六进制
字符，第三行长度为奇数，不能形成 byte stream。本阶段没有猜测删除某个
字符，而是从原始：

```text
build/ethernet_ila/iladata.ila
  -> waveform.csv
  -> camera_packet_valid && camera_packet_ready
```

重新抽取全部 128 次握手 byte，得到 256 个十六进制字符，保存为：

```text
tests/vectors/ila_camera_payload_legacy_v0.hex
```

自动检查字段：

```text
sync0       = 0xA5A5
sync1       = 0x5A5A
cam_id      = 0
frame_id    = 2073
row_idx     = 330
row_flags   = 0x08
payload_len = 80
row_seq     = 12330
crc16       = 0xB753
crc_ok      = true
Layer3      = FAIL(reason=length_error)
```

CRC 正确而 Layer 3 FAIL 是预期结果：CRC 证明 FPGA 最终 payload
自洽，`row_flags[3]` 证明输入 HREF 长度错误。

## 3. 测试

新增覆盖：

- 错误 sync 但 CRC 正确；
- `payload_len=81`；
- `payload_len=0` warning；
- overflow + length error 多错误；
- 原始 ILA 128-byte 回归向量。

结果：

```text
targeted parser/format tests  13 passed
full receiver suite           42 passed in 2.84s
```

## 4. 真实 Camera PCAP 回放

对 `camera_live_0x88b5_20260724.pcapng` 的 1,000 帧：

```text
Layer 3 PASS                 459
Layer 3 FAIL                 541
primary length_error         539
primary frame_overflow         2
all length_error             541
all frame_overflow             2
zero_payload_len warnings     62
```

`row_seq`/`row_idx` 的跨包连续性不属于单包 Layer 3，继续由 monitor /
reassembler 层判断。

## 5. 修改文件

| 文件 | 原因 |
|---|---|
| `taxi_receiver/camera_parser.py` | 严格单包校验和结构化原因 |
| `tests/test_camera_parser.py` | 新边界与回归测试 |
| `tests/vectors/ila_camera_payload_legacy_v0.hex` | 原始 ILA 向量 |

未修改 Taxi core、RTL 数据通路、XDC、XCI 或 Vivado 自动生成目录。

