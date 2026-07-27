# P8 Python 图像接收、编号归档与逐行审计报告

> 日期：2026-07-27  
> 工程：`D:\prg\prg_cam`  
> 接收器：`prg_cam.srcs/sources_1/tx/taxi_receiver_advanced/taxi_receiver`  
> 图像根目录：`D:\prg\prg_cam\images`

## 1. 结论

Python 侧的协议解析、CRC 检查、按相机/帧编号重组、完整帧图像发布和逐行
CSV 已完成，依赖硬件以外的自动测试为 `68 passed`。现有 PCAP 的标准库
回放也已改成无损背压，完整处理 `78467` 个 EtherType `0x88B5` 包且
`Capture queue drops = 0`。

目前还不能把“真实 Camera 照片归档”标为最终 PASS：当前 Python 环境没有
安装 Scapy，所以尚未从真实网卡运行本接收器；仓库内唯一 Camera PCAP 是
硬件修正前的旧证据，其中仍带 `LENGTH_ERROR/overflow` 标志。项目根目录
下的 `images/cam0`、`images/cam1` 因此保持为空，没有用合成数据伪造硬件
验收结果。

## 2. 事实来源

| 结论 | 当前证据 |
|---|---|
| 128-byte Camera 包布局 | `taxi_receiver/packet_format.py:28-62` |
| CRC 覆盖 bytes 0..125 | `taxi_receiver/packet_format.py:61-62,136-145` |
| `LAST_ROW = 0x02` | `taxi_receiver/packet_format.py:34` |
| 行重组、重复/冲突/缺行判定 | `taxi_receiver/reassembler.py:126-333` |
| packed threshold 行恢复 | `taxi_receiver/threshold_recover.py:173-229` |
| cam/frame 图像发布与 CSV | `taxi_receiver/image_pipeline.py:76-261` |
| CLI 接入点 | `taxi_receiver/cli.py:121-183` |
| 自动验证 | `tests/test_image_pipeline.py`、`tests/test_pcap_stdlib.py` |
| 当前数字实现 | `build/ab_build/20260726_231631/{plain,ila}` |
| 当前离线 Camera 抓包 | `docs/sample_eth_data4.pcapng` |

当前 A/B 构建 manifest 与工作区 Vivado 输入（排除纯 Python
`sources_1/tx`）共核对 `1186` 个文件，大小/hash 差异为 `0`。因此本次
Python 修改没有改变已生成 bitstream 的 RTL/XDC 输入；这不等价于本轮
重新运行 Vivado。

用户已确认先前 sync/数据位问题属于硬件并已改正。本报告不再把它记为
当前 RTL FAIL，但仍要求用改正后的新 PCAP 完成最终回归。旧
`sample_eth_data4.pcapng` 只能代表修正前状态。

## 3. 当前包头、payload 与包尾

当前 header/trailer metadata 的多字节字段按 MSB-byte-first 解析；FPGA
`Byte_Replacer` 重算的最后 CRC16 仍按 low byte/high byte，即 little-endian。

| Byte offset | 长度 | 字段 | 检查/用途 |
|---:|---:|---|---|
| 0 | 2 | `sync0` | word `0xA5A0`，wire bytes `A5 A0` |
| 2 | 2 | `sync1` | word `0x5A50`，wire bytes `5A 50` |
| 4 | 1 | `cam_id` | 选择 `images/cam<cam_id>` |
| 5 | 2 | `frame_id` | 图像文件名；即用户所称 `image_id` |
| 7 | 2 | `row_idx` | 帧内行位置 |
| 9 | 1 | `row_flags` | FIRST/LAST/OVERFLOW/LENGTH_ERROR |
| 10 | 1 | `payload_len` | 必须为 `1..80` |
| 11 | 2 | `row_seq` | 跨帧连续行序号 |
| 13 | 11 | `reserved` | 保留 |
| 24 | 80 | `payload` | 当前 packed 1-bpp threshold 行 |
| 104 | 10 | trailer `pad` | CSV 记录是否全零 |
| 114 | 4 | `m00` | 无符号原始量 |
| 118 | 2 | `xc_q4` | `x = xc_q4 / 16` |
| 120 | 2 | `yc_q4` | `y = yc_q4 / 16` |
| 122 | 2 | `vx_q8` | 有符号；`vx = vx_q8 / 256` |
| 124 | 2 | `vy_q8` | 有符号；`vy = vy_q8 / 256` |
| 126 | 2 | `crc16` | CRC-16-CCITT-FALSE，覆盖 0..125 |

Ethernet II 的 14-byte header 不属于上述 128-byte Camera 包；线上 Ethernet
FCS 也不属于 Camera trailer 的 `crc16`。Layer 2 先剥离 Ethernet header，
Layer 3 才解析上述 payload。

## 4. 帧结束与图像完整性

CSV 分帧严格采用用户指定的位掩码：

```python
frame_end = (row_flags & 0x02) == 0x02
```

它不要求 `row_flags == 0x02`，所以 `0x03`、`0x0A`、`0x83` 同样表示
LAST_ROW。记录该行后，接收器向 `rows.csv` 写入一个真实空行。

图像发布比 CSV 分隔更严格：

1. session key 为 `(cam_id, frame_id)`；
2. 必须收到配置范围 `0..expected_rows-1` 的全部行；
3. 不得有 CRC/长度/overflow/冲突重复错误；
4. 必须看到 LAST_ROW；
5. 只有 `FrameStatus.COMPLETE` 才生成照片。

因此，仅收到 `row_flags & 0x02` 会关闭/分隔一帧，但缺行帧不会被误命名成
正常照片。PARTIAL、CORRUPT、TIMEOUT 仍保留在逐行 CSV 和原有证据归档中。

## 5. 输出目录与命名

当前目标目录：

```text
D:\prg\prg_cam\images\
  cam0\
    rows.csv
    <frame_id>.pgm
    <frame_id>.raw
    <frame_id>.json
  cam1\
    rows.csv
    <frame_id>.pgm
    <frame_id>.raw
    <frame_id>.json
```

当前接入相机的 `cam_id=0`，因此完整帧 `frame_id=42` 会产生
`images/cam0/42.pgm`、`42.raw`、`42.json`。cam1 的数据不会覆盖 cam0。
已有同名 frame 文件时接收器拒绝覆盖，以防 frame_id 回绕或重复运行破坏
旧证据。每个可见文件均先完整写入临时文件、flush/fsync 后再原子替换名称。

当前 80-byte payload 被解释为 `640` 个 1-bit threshold pixels。默认位序
为 `msb_first`，完整 480 行生成 `640x480` 的 binary PGM（P5）和
`307200`-byte raw。位序必须用新 Camera 抓包或已知测试图确认；必要时使用
`--bit-order lsb_first`，不能只凭视觉猜测。

## 6. `rows.csv`

CSV 在第一条可解析 Camera 行到达时创建，不存在时先写 header。每个
`cam_id` 有独立 CSV。主要字段为：

- 定位：`timestamp, cam_id, frame_id, row_idx, row_seq`；
- 标志：`row_flags, first_row, last_row, frame_overflow, length_error,
  frame_end`；
- 协议检查：`sync0, sync1, sync_ok, payload_len, payload_len_ok,
  crc_ok, received_crc, calculated_crc, trailer_pad_zero, parse_ok`；
- 运动信息：`m00, xc_q4, yc_q4, x, y, vx_q8, vy_q8, vx, vy`；
- 诊断：`errors, warnings`。

CRC 错等 Layer-3 校验失败的包仍写 CSV，以免审计证据被静默丢弃；但这些包
不会进入完整照片。

## 7. 实现变更

| 文件 | 原因 |
|---|---|
| `taxi_receiver/image_pipeline.py` | 新增编号图像发布与 per-camera 逐行 CSV |
| `taxi_receiver/cli.py` | 增加 `--images-root`、`--bit-order` 并接入两个回调 |
| `taxi_receiver/pipeline.py` | PCAP 回放启用无损队列背压；live 保持队满丢弃统计 |
| `taxi_receiver/__init__.py` | 导出新增 Layer-5 能力 |
| `tests/test_image_pipeline.py` | 覆盖 cam0/cam1、完整帧、CRC 错、缺行、空行 |
| `tests/test_pcap_stdlib.py` | 容量 1 队列下验证 200 包无损回放 |
| `run_receiver.ps1` | live 默认输出到工程 `images` |
| `replay_pcap.ps1` | 可选隔离的 `ImagesRoot` |
| `requirements-live.txt` | 明确 live capture 的 Scapy 依赖 |
| `README.md` | 运行、目录、位序和无损回放说明 |

没有修改 Taxi core、FPGA RTL、XDC、XCI、BD 或 Vivado 生成目录。

## 8. 验证结果

### 8.1 自动测试

```powershell
cd D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver
C:\Users\Z\AppData\Local\Python\bin\python.exe -m pytest -q `
  -p no:cacheprovider `
  --basetemp D:\prg\prg_cam\build\pytest_tmp_20260727_image_pipeline_clean
```

结果：

```text
68 passed in 4.62s
```

图像专项覆盖：

- cam0、cam1 分目录；
- numeric `frame_id` 文件名；
- packed bit 到 PGM/raw 的逐 byte 对比；
- `0x83 & 0x02` 仍正确结束；
- CSV trailer 数值及 Q4/Q8 换算；
- 帧结束后真实空行；
- CRC 错只记录、不发布图片；
- 缺行只记录、不发布图片。

### 8.2 当前 PCAP 无损回放

```powershell
python -m taxi_receiver.cli `
  --replay-pcap D:\prg\prg_cam\docs\sample_eth_data4.pcapng `
  --mode camera --max-stage monitor --report-interval 999
```

结果：

```text
Matching Ethernet   : 78467
Valid packets       : 0
CRC errors          : 0
Parser errors       : 0
Processing errors   : 0
Capture queue drops : 0
CAM0 packets        : 78467
length errors       : 489
overflow-marked     : 164
last-row packets    : 163
```

这证明 Layer 1-4 能无损读取该 PCAP，不证明旧抓包可以产出完整照片。该旧
PCAP 使用历史 sync `A5 A5 5A 5A`，当前协议严格要求
`A5 A0 5A 50`，因此当前 parser 将其全部标为 `bad_sync`，`Valid packets=0`
是正确口径。489 个 LENGTH_ERROR 和 164 个 overflow 同样是旧包中携带的
硬件状态，不是此次 Python 回放制造的错误。

## 9. 正式 live 运行

Npcap 已可被 Wireshark `dumpcap` 识别，当前物理 Ethernet 接口为：

```text
\Device\NPF_{6BDDE37E-7DCA-4078-98B0-E374EFE04E7C} (以太网)
```

当前 Python 环境缺 Scapy。先在接收器目录执行：

```powershell
python -m pip install -r .\requirements-live.txt
python -m taxi_receiver.cli --list
```

然后运行：

```powershell
.\run_receiver.ps1 `
  -Interface '\Device\NPF_{6BDDE37E-7DCA-4078-98B0-E374EFE04E7C}' `
  -OutputRoot D:\prg\prg_cam\build\receiver_output\camera_live
```

`ImagesRoot` 默认解析为 `D:\prg\prg_cam\images`。停止时查看最终报告：

- `Capture queue drops` 必须为 0；
- `CRC errors` 必须为 0；
- `length errors` 和 `overflow-marked` 必须为 0；
- cam0 应持续出现 LAST_ROW；
- `images/cam0/<frame_id>.pgm/.raw/.json` 应按 frame_id 递增；
- `images/cam0/rows.csv` 每帧末尾有一行空行；
- `images/cam1` 在未接 cam1 时不应出现数据文件。

## 10. Gate matrix

| Gate | 状态 | 说明 |
|---|---|---|
| 当前 Vivado 输入与已验收 A/B build 一致 | PASS | 1186 项，0 hash/size 差异；未因 Python 变更重跑实现 |
| 数字实现 timing | PASS WITH WARNINGS | 普通 WNS/WHS `+0.793/+0.071 ns`；ILA `+0.953/+0.046 ns` |
| Python 全回归 | PASS | 68/68 |
| 包头/包尾/CRC 解析 | PASS | synthetic + PCAP replay |
| cam_id 隔离和 frame_id 命名 | PASS | 自动 byte/file compare |
| LAST_ROW 位掩码与 CSV 空行 | PASS | 含 `row_flags=0x83` |
| 缺行/CRC 错保护 | PASS | 不发布伪完整照片 |
| PCAP 无损回放 | PASS | 78467 包，queue drops=0 |
| Npcap/网卡枚举 | PASS | `dumpcap -D` 可见物理 Ethernet |
| Python Scapy live 依赖 | FAIL_ENV | 当前未安装；离线和 pytest 不受影响 |
| 修正硬件后的新 Camera PCAP | PENDING | 需要重新采集 |
| 残余 127-byte/LENGTH_ERROR 回归 | PENDING | 必须由新 PCAP 清零/量化 |
| 真实 cam0 照片按编号归档 | PENDING | 等 live capture |
| 图像 bit order/视觉内容 | PENDING | 等已知测试图或硬件参考图 |

正式确认条件是最后四项 PENDING/FAIL_ENV 清零。在此之前，准确结论为：
**接收与归档软件 READY / 自动验证 PASS；真实 Camera-to-Python image
archive 尚未完成硬件验收。**
