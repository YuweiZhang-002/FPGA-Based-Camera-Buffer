# P10 Camera 图像接收端到端诊断与 row_flags 修复报告

日期：2026-07-27  
事实优先级：当前源码 > 当前运行数据/PCAP > 当前测试与 Vivado 报告 > 旧文档。

## 1. 最终结论

`attempt2` 中的 `PGM=0/RAW=0` 不是 PowerShell 少写 `-Recurse`
造成的显示假象；`D:\prg\prg_cam\images\temp\archive\attempt2`
实际只有 `cam0/rows.csv`，没有任何 PGM 或 RAW。

直接根因是项目把线上 `row_flags=0x04` 错当成 overflow。当前真实协议为：

| bit | mask | 当前语义 |
|---:|---:|---|
| 0 | `0x01` | FRAME/BUFFER OVERFLOW |
| 1 | `0x02` | LAST_ROW / frame end |
| 2 | `0x04` | FIRST_ROW / valid frame start |
| 3 | `0x08` | LENGTH_ERROR |

因此每个真正的首行都被 Layer 3 以 `frame_overflow` 拒绝。旧 CSV 中共有
2,073 个 `0x04`，恰好全部被旧解析器计为 overflow；重组器收不到
`row_idx=0`，严格完整帧条件永远不能满足，所以 RAW/PGM 写入回调从未被触发。

`0x58` 不是项目定义的新标志，也不是“高 8 位全部反向置位”。它是 127-byte
短包发生字段左移后得到的确定组合：

1. 原 offset 9 的 `row_flags` 字节丢失；
2. offset 10 的正常 `payload_len=0x50` 左移到 offset 9；
3. FPGA 检出 127-byte 行后由 `Byte_Replacer` 在 offset 9 OR 入
   `LENGTH_ERROR=0x08`；
4. 得到 `0x50 | 0x08 = 0x58`；
5. 原 `row_seq` 高字节移入 `payload_len`，低字节移到 `row_seq` 高字节，
   行缓冲补的 `0x00` 成为其低字节，因而出现
   `row_seq = (原低字节 << 8)` 的“严重失真”。

此变化发生在 Taxi/Ethernet 之前。`Byte_Replacer` 对修正后的 126 bytes
重新计算 CRC，所以 PC 端看到 `crc_ok=1` 并不能证明进入 FPGA 前的 128 bytes
没有丢字节。

软件保存链已由合成帧验证为 PASS；真实 Camera 640×480 图像保存仍需用
Camera 模式 bitstream 重新采集，不能用离线合成测试冒充硬件 PASS。

## 2. 运行数据证据

输入：
`D:\prg\prg_cam\images\temp\archive\attempt2\cam0\rows.csv`

流式扫描结果：

| 指标 | 数值 |
|---|---:|
| CSV 数据行 | 1,062,904 |
| `(cam_id, frame_id)` 会话 | 2,215 |
| 旧解析器 valid | 1,051,964 |
| 旧解析器 invalid | 10,940（1.029%） |
| `0x04` | 2,073 |
| `0x02` | 2,161 |
| `0x08` | 6,777 |
| `0x58` | 1,898 |
| `0x0C` | 139 |
| `0x0A` | 53 |
| 当前 sync `A5 A0 5A 50` | 1,062,894 |
| `payload_len=80` | 1,061,002 |
| 按修正后 flags 语义重算的严格完整候选帧 | 71 |

示例：

| frame | row | flags | payload_len | row_seq | 解释 |
|---:|---:|---:|---:|---:|---|
| 0 | 247 | `0x58` | 0 | 63232=`0xF700` | 原 `row_seq=247=0x00F7` 的低字节移到高位 |
| 0 | 447 | `0x58` | 1 | 48896=`0xBF00` | 原 `row_seq=447=0x01BF` 同样左移一字节 |

因此本次完整 CSV 的累计无效率是 `10,940 / 1,062,904 = 1.029%`，并非
0.55%；0.55% 可能是另一时间窗口或只统计一种错误。即使假设独立单行失败率
仅为 0.5%，完整帧概率也会按 `(1-p)^N` 放大下降：

| 行数 N | `(1-0.005)^N` |
|---:|---:|
| 77 | 67.98% |
| 240 | 30.03% |
| 480 | 9.02% |

这能解释完整帧变少，但不能解释无限长运行始终 PGM=0；后者还需要
“首行被误判 overflow”这个完成条件错误，而该错误已由 flags 计数直接证实。

可重复命令：

```powershell
cd D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver
python .\analyze_rows_csv.py `
  D:\prg\prg_cam\images\temp\archive\attempt2\cam0\rows.csv
```

## 3. 实际调用链

```text
ScapyLiveCapture / PcapReplayCapture
  capture.py: RawEthernetFrame
        |
        v
TaxiReceiverPipeline._on_frame()
  pipeline.py: bounded queue + ethernet_frames_received/queue_drops
        |
        v
ValidationStage
  eth_validate.py: dst/src/EtherType/length，去掉 14-byte Ethernet II header
        |
        v
ParsingStage
  camera_parser.py -> packet_format.py
  sync/payload_len/CRC/overflow/length_error
        |
        +--> on_frame_processed
        |      SessionAuditLogger.record()
        |      CameraImagePipeline.record_packet() -> camN/rows.csv
        |
        v
MonitoringStage
  stream_monitor.py: packet/valid/error/sequence counters
        |
        v
ReassemblyStage
  reassembler.py: (cam_id, frame_id) session + row_idx insertion
        |
        v
CompletedFrame
        |
        +--> StorageAndPipeline.archive_frame()
        |      output_root/cam_<id>/frame_<id>/{image.raw,metadata.json,...}
        |
        +--> CameraImagePipeline.archive_frame()
               images_root/camN/<frame_id>.{raw,pgm,json}
```

生产者和消费者在 `cli.py` 中均已挂载：`FrameReassembler`、
`StorageAndPipeline`、`SessionAuditLogger` 和 `CameraImagePipeline`
通过 `_fanout_callbacks()` 接到 `on_completed_frame` /
`on_frame_processed`。`run_receiver.ps1` 显式传入
`--max-stage reassemble`，不存在默认停在 monitor 而未启用存储的问题。

worker 边界会把异常计入 `processing_errors` 并打印
`[PROCESSING ERROR]`；保存异常不再被错误标成 parser error。结束时先
`queue.join()`，再 flush reassembler，避免未解释队列积压。

## 4. 线上 128-byte 偏移表

当前 Python 定义见 `taxi_receiver/packet_format.py`。工作区没有 RP2350A
的 `.c/.h`，因此 C 字段语义来自用户给出的 packed 定义；线上端序则由
当前 PCAP/CSV 和 Python 回归共同确认。`packed` 本身不定义端序。

| offset | size | field | C type | wire order / Python | 校验 |
|---:|---:|---|---|---|---|
| 0 | 2 | sync0 | `uint16_t` | BE `>H`，例 `A5 A0`→`0xA5A0` | 必须 `0xA5A0` |
| 2 | 2 | sync1 | `uint16_t` | BE `>H`，例 `5A 50`→`0x5A50` | 必须 `0x5A50` |
| 4 | 1 | cam_id | `uint8_t` | `B` | session key |
| 5 | 2 | frame_id | `uint16_t` | BE `>H` | 16-bit 回绕 |
| 7 | 2 | row_idx | `uint16_t` | BE `>H` | 当前完整图 0..479 |
| 9 | 1 | row_flags | `uint8_t` | `B` | `0x01/02/04/08` |
| 10 | 1 | payload_len | `uint8_t` | `B` | `0..80`；正常为 80 |
| 11 | 2 | row_seq | `uint16_t` | BE `>H` | 连续、16-bit 回绕 |
| 13 | 11 | reserved | `uint8_t[11]` | raw bytes | 当前不解释 |
| 24 | 80 | payload | `uint8_t[80]` | raw bytes | 640-bit 阈值行 |
| 104 | 10 | pad | `uint8_t[10]` | raw bytes | 期望全 0 |
| 114 | 4 | m00 | `uint32_t` | BE `>I` | telemetry |
| 118 | 2 | xc_q4 | `uint16_t` | BE `>H` | `x=xc_q4/16` |
| 120 | 2 | yc_q4 | `uint16_t` | BE `>H` | `y=yc_q4/16` |
| 122 | 2 | vx_q8 | `int16_t` | BE `>h` | `vx=vx_q8/256` |
| 124 | 2 | vy_q8 | `int16_t` | BE `>h` | `vy=vy_q8/256` |
| 126 | 2 | crc16 | `uint16_t` | LE `int.from_bytes(...,"little")` | CRC-16/CCITT-FALSE 覆盖 0..125 |

Header=24 bytes，row payload=80 bytes，trailer=24 bytes，总计 128 bytes。
`Ethernet_Frame_Adapter` 另加 14-byte Ethernet II header，因此 Wireshark
显示 142-byte frame（抓包端通常不保留 FCS）。Taxi MAC 负责
preamble/SFD、必要 padding、Ethernet CRC-32 FCS 和 IFG；Camera CRC-16
不是 Ethernet FCS。

## 5. 帧完成与图像编码规则

`FrameReassembler` 当前在任意合法 Camera 行到达时按
`(cam_id, frame_id)` 建立会话，不要求 FIRST_ROW 才创建。这样允许从流中间
启动，但 COMPLETE 仍严格要求：

- 见到 LAST_ROW；
- `expected_rows=480` 时 0..479 每个 `row_idx` 均已接收；
- 插入的行没有 Layer 3 error；
- 没有 overflow；
- 没有冲突重复；
- 关闭后状态为 `FrameStatus.COMPLETE`。

CRC、length、overflow 错误行保留在 CSV/audit 作为证据，但不进入可用行集合。
新 frame_id、timeout 或程序停止会关闭旧会话；缺行帧归为
PARTIAL/CORRUPT/TIMEOUT，不伪装为完整照片。

当前 80-byte payload 是一行 640 个 1-bit 阈值像素。`threshold_recover.py`
按 MSB-first 展开为 640 个灰度 byte（0 或 255）。完整图：

- RAW：`640 * 480 = 307,200` bytes；
- PGM：ASCII P5 header + 307,200 pixel bytes；
- 不是把 128-byte Camera packet header/trailer 写进像素区。

两类 `.raw` 必须分开理解：

- `output_root/cam_<id>/frame_<id>/image.raw` 是 StorageAndPipeline 的
  诊断归档，保存 480×80=38,400-byte packed 1-bpp 行空间；对
  PARTIAL/CORRUPT 帧会在缺行位置补零，不能直接当 640×480 Y8 打开；
- `images_root/camN/<frame_id>.raw` 只在 COMPLETE 时生成，是已展开的
  640×480 8-bit 灰度，大小 307,200 bytes，与 PGM 像素区一致。

## 6. 已实施修改

根因证据汇总：

| 现象 | 代码/配置证据 | 运行证据 | 根因 | 处置 |
|---|---|---|---|---|
| `attempt2` PGM/RAW=0 | parser 旧版把 `0x04` 当 overflow；完整帧拒绝错误行 | 2,073 个 `0x04` 全被记为 overflow | FIRST/OVERFLOW 位定义互换 | 全链统一 `0x01=overflow,0x04=first` |
| `0x58` + row_seq 高位失真 | Byte_Replacer offset9 OR flags、126/127 重算 CRC；Line_Buffer 短行补零 | `0xF700/0xBF00` 等精确移位形状 | offset9 少一 byte 后 `0x50|0x08` | 不兼容 0x58；继续在发送/capture 边界定位少字节 |
| ILA build 发 `00..7F` | xpr generic Camera=0；脚本未覆盖 | 烧录后 2,000 包全为固定序列 | 构建源选择错误 | GUI 与 Camera ILA 强制 Camera=1；固定模式留独立脚本 |
| 当前 Camera 2,000 包全 `0x08` | Capture 只在 PCLK 有效沿计 byte，HREF 结束时判长度 | PCLK 恒1、byte_valid/count恒0，HREF/data有变化 | RP→JB1 PCLK 未产生或未到达 | 板上测 RP PCLK 与 JB1/D14，查跳线/共地/pin mux |

| 文件 | 修改 | 接口影响 |
|---|---|---|
| `taxi_receiver/packet_format.py` | 修正 `0x01=overflow`、`0x04=first` | 线上格式不变，仅纠正解释 |
| `Camera_Capture.v` | 同步修正 flags 常量/注释 | 无端口变化；CDC 数据路径未改 |
| `Line_Buffer.v` | sticky overflow 从 `0x04` 改为 `0x01` | 无端口变化 |
| `taxi_receiver/reassembler.py` | 添加会话/行/完成/超时累计计数器 | 无线格式变化 |
| `taxi_receiver/image_pipeline.py` | 添加 RAW/PGM attempts/success/failure；批量 CSV flush | 输出接口不变 |
| `taxi_receiver/pipeline.py`、`cli.py` | 打印 Layer-5、绝对路径和 publication 统计 | CLI 兼容 |
| `taxi_receiver/session_audit.py` | 增加 `validation_status/reject_reason` | 仅增加 CSV 列 |
| `monitor_camera_output.ps1` | 递归统计 archive/image RAW/PGM | 诊断脚本 |
| `analyze_rows_csv.py` | 大 CSV 流式 flags/完整帧/`0x58` 诊断 | 诊断脚本 |
| `scripts/build_ethernet_ila.tcl` | Camera ILA 构建显式覆盖 `USE_CAMERA_PIPELINE=1` | 修复构建选择，不改数据接口 |
| `prg_cam.xpr` | GUI fileset generic 从 Camera=0 改为 Camera=1 | GUI 默认改为真实 Camera；固定模式仍由独立脚本提供 |
| `scripts/check_project.tcl` | 检查实际 Ethernet top、Camera generic 和 wrapper 源 | 修复过时的 Camera_Pipeline top 假设 |
| 三个 SV TB 与 Python tests | 更新真实 flags 语义和新增生命周期/写入断言 | 仅验证 |

未修改 Taxi core、RMII bridge、Vivado 自动生成目录中的上游源码。

## 7. 验证结果

### 7.1 Python

```powershell
cd D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver
C:\Users\Z\AppData\Local\Python\bin\python.exe -m pytest -q `
  --basetemp D:\prg\prg_cam\build\receiver_validation\pytest
```

结果：`71 passed`。唯一 warning 是已有 `.pytest_cache` 目录的 Windows
创建冲突，不影响测试结论。

实际生成的合成图：

- `...\pytest\test_complete_cam0_frame_write0\images\cam0\42.raw`
  = 1,280 bytes（640×2）；
- `42.pgm` = 1,293 bytes，header 为 `P5\n640 2\n255\n`；
- RAW SHA-256
  `4D22B7AF65F67F8D1BA7230A720F13D2E9A9F03B14AFF6434FE4B7F3C85CD87D`；
- PGM SHA-256
  `16919FF82EA6AE972FE5E96F9657D2FC297126949B9ED4B5605FE8A04E58BCB5`。

### 7.2 RTL 仿真

- `tb_Line_Buffer.sv`：PASS（counter/drop/sticky overflow）；
- `tb_Camera_Pipeline.sv`：PASS（4-camera arbitration/header merge/CRC-16）；
- `tb_Camera_Pipeline_Ethernet_Source.sv`：PASS（3 frames、384 payload
  handshakes、426 total handshakes、stall/TLAST）。

### 7.3 构建与硬件

第一次本轮 ILA 构建通过实现和时序，但硬件重抓 2,000 包全部是
`00..7F`。这直接证明该产物继承了 `prg_cam.xpr` 中
`USE_CAMERA_PIPELINE=0`，不是 Camera 流。抓包保存于：

`build/receiver_validation/camera_after_flag_fix.pcapng`

该文件只能作为 Fixed/Byte_FIFO→Ethernet 回归证据，不能作为 Camera
回归证据。`build_ethernet_ila.tcl` 已改为在 `synth_design` 显式传入：

```tcl
-generic {USE_CAMERA_PIPELINE=1 USE_BYTE_FIFO_PATH=1 CAMERA_LINES_PER_FRAME=480}
```

修复后的 Camera 构建结果：

- `ILA_BUILD_RESULT=PASS`；
- bit/ltx 时间：2026-07-27 18:50:21；
- ILA probe count：47；
- WNS `+1.431 ns`，WHS `+0.026 ns`，setup/hold failing endpoints 均为 0；
- bit 与 ltx 已于 18:51 成对烧录，硬件识别到 1 个 ILA。
- `check_project.tcl`：
  `PROJECT_SOURCE_CHECK_PASS top=Camera_Ethernet_Top
  generics=USE_CAMERA_PIPELINE=1 USE_BYTE_FIFO_PATH=1`。

产物 SHA-256：

- bit：
  `FA4BE84E8C9F548B8885FBDBFCFA6ACAC382B116509BFB4905944168EB2F65C3`；
- ltx：
  `0D284452E1B1A3C969D108C9CB2D2666F9B7F43544ACC365EE38E90250B7822C`；
- Camera PCAP：
  `967D9496DCA0AB6FFCC680D50F0B42ABDDB4975AA9DE85FE5018D53AB461E281`。

Camera 模式重新抓取 2,000 包，dumpcap 报告接口/pcap drop 均为 0，文件：

`build/receiver_validation/camera_mode_after_flag_fix.pcapng`

这 2,000 包不再是固定发生器，而是 Camera 管线发出的统一错误行：

- 128-byte Camera payload 除 offset 9=`0x08` 和末尾重算 CRC 外均为 0；
- CRC error=0；
- LENGTH_ERROR=2,000/2,000；
- overflow=0；
- accepted row=0、PGM/RAW attempts=0。

这里的 `RAW attempts=0` 指 `CameraImagePipeline` 的可用图像 RAW。证据归档
仍正确产生了 `camera_archive/cam_0/frame_0/image.raw`（38,400-byte
全零/补零 packed 数据）及 `errors.json/packets.csv`；它证明错误帧可审计，
不代表完成图像。

随后用 `camera_length_error_pulse_dbg==1` 触发 ILA，抓取：

`build/ethernet_ila/camera_length_error_pulse_dbg_capture.csv`

4096 个 100 MHz 样本的板上证据：

| probe | 观测 |
|---|---|
| `camera_pclk_dbg` | 4096/4096 均为 1，没有一次翻转 |
| `pclk_sync` / `pclk_level` | 全程为 1 |
| `pclk_hist[1:0]` | 全程为 `2'b11` |
| `camera_capture_byte_valid_dbg` | 4096/4096 均为 0 |
| `camera_current_byte_count_dbg` | 全程 0 |
| `camera_last_line_byte_count_dbg` | 全程 0 |
| `camera_href_dbg` | 观测到高/低变化 |
| `camera_data_dbg` | 观测到 `0x00/0x40/0xC0` 变化 |
| 触发拍 `camera_line_flags_dbg` | `0x08` |

所以当前新硬件测试的直接阻点是 PCLK 没有到达 FPGA，而不是 Python
reassembler。顶层与 XDC 按当前约定一致：`GPIO[8]`→`Camera_Pipeline.cam0_pclk`，
`GPIO[8]` 约束到 JB1/D14；`GPIO[9]`→HREF，约束到 JB7/E16。需要在
RP2350A 输出脚和 Nexys JB1/D14 两端实测 PCLK，并核对排针物理编号、共地、
3.3 V 电平和 RP 固件 pin mux。PCLK 恢复翻转前，任何 640×480 PGM 验收都
没有有效输入源。

引脚映射也由本地 `Nexys-A7-50T-Master.xdc` 交叉确认：
JB1=`D14`、JB7=`E16`，因此当前未发现 XDC 位号或顶层方向互换；仍需确认
实际跳线接的是排针丝印 JB1/JB7，而不是把“JB 数组下标”和物理针序号混用。

## 8. 用户直接运行命令

接收并分别指定 archive 与 images：

```powershell
cd D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver
.\run_receiver.ps1 `
  -Interface '\Device\NPF_{6BDDE37E-7DCA-4078-98B0-E374EFE04E7C}' `
  -OutputRoot D:\prg\prg_cam\images\temp\archive\attempt3 `
  -ImagesRoot D:\prg\prg_cam\images\temp\attempt3 `
  -ExpectedRows 480 `
  -QueueDepth 65536
```

递归监控：

```powershell
.\monitor_camera_output.ps1 `
  -OutputRoot D:\prg\prg_cam\images\temp\archive\attempt3 `
  -ImagesRoot D:\prg\prg_cam\images\temp\attempt3
```

手工递归统计：

```powershell
$camDir = 'D:\prg\prg_cam\images\temp\attempt3\cam0'
$pgm = @(Get-ChildItem -LiteralPath $camDir -Recurse -File -Filter *.pgm -ErrorAction SilentlyContinue).Count
$raw = @(Get-ChildItem -LiteralPath $camDir -Recurse -File -Filter *.raw -ErrorAction SilentlyContinue).Count
"PGM=$pgm RAW=$raw"
```

PCAP replay：

```powershell
python -m taxi_receiver.cli `
  --replay-pcap D:\path\camera.pcapng `
  --mode camera --max-stage reassemble --expected-rows 480 `
  --output-root D:\temp\archive --images-root D:\temp\images
```

查看 audit：

```powershell
Import-Csv D:\temp\archive\session_audit.csv |
  Select-Object -First 20 timestamp,cam_id,frame_id,row_idx,row_flags_raw,validation_status,reject_reason
```

## 9. 分层状态矩阵

| 层级 | 状态 | 证据 |
|---|---|---|
| Ethernet Fixed capture | PASS | 新抓 2,000/2,000，0 NIC drop，payload `00..7F` |
| Layer2 extraction | PASS | 2,000 EtherType `0x88B5`、142-byte frame |
| Layer3 flags/CRC parser | PASS（离线） | 71 Python tests；flags 语义已纠正 |
| Camera session creation | PASS（合成） | lifecycle counters/test |
| row insertion/completion | PASS（合成） | 完整/缺行/timeout tests |
| RAW writer | PASS（合成） | 1,280-byte 640×2 RAW + SHA-256 |
| PGM writer | PASS（合成） | P5 640×2、1,293 bytes + SHA-256 |
| audit logging | PASS（离线） | 包含 Layer3 reject reason tests |
| Camera-mode bitstream | PASS WITH WARNINGS | 显式 Camera generic；WNS +1.431/WHS +0.026；已烧录 |
| Camera GPIO/HREF | PARTIAL | HREF 与 data 有变化 |
| Camera PCLK/byte capture | FAIL | PCLK 4096 样本恒 1，byte_valid/count 恒 0 |
| 真实 Camera Layer3 | FAIL（当前运行） | 2,000/2,000 为 FPGA 生成的零长度错误行 |
| 真实 640×480 RAW/PGM | BLOCKED | 先恢复 RP2350A→JB1 PCLK，再采完整 0..479 |

## 10. 剩余风险与下一次 ILA 判据

`0x58` 的字节移位已被历史数据形状证明，但工作区没有 RP2350A 固件，故尚不能仅靠
静态源码判定“offset 9 字节是在 RP2350A 发出前丢失，还是在 FPGA 异步采样时
丢失”。当前最可能根因仍是 `Camera_Capture` 把 PCLK/data/HREF 分别同步到
100 MHz 后再用投票 PCLK 产生 byte-valid；这不是严格的源时钟域采集 + 异步
FIFO，合法 PCLK 边沿仍可能被滤掉。因缺失位置稳定落在 header offset 9，也
必须并行核对 RP2350A serializer/HSTX 在该边界是否少发一 byte。

ILA 触发：

```text
camera_length_error_pulse_dbg == 1
```

同时检查：

- `camera_last_line_byte_count_dbg` 是否为 127；
- `pclk_sync/pclk_hist/pclk_level/camera_capture_byte_valid_dbg`；
- `data_sync` 在 byte offsets 7..12 的实际序列；
- `camera_line_flags_dbg` 是否由 `0x50` OR `0x08` 形成 `0x58`；
- `camera_packet_data/valid/ready/last` 是否在进入 Line_Buffer 后保持。

若 RP2350A 逻辑分析仪显示 offset 9 已正确发送，而 ILA 在
`camera_capture_byte_valid_dbg` 少一次握手，则 FPGA capture CDC 是根因；
若 ILA 输入侧本身就没有该 byte，则回到 RP2350A serializer/HSTX。不要在
Python 接收端为 `0x58` 增加兼容解析或修复字段，那会掩盖真实丢字节。

当前这次 ILA 已先发现一个更早的物理/配置阻点：PCLK 完全不翻转。先在 RP
输出端与 JB1 分别测 PCLK；只有 ILA 看到稳定翻转且每行 byte_count 回到 128，
才继续评估历史约 0.55% 的短行残差和 `0x58`。这两个现象不能混成同一个错误率：
当前是 100% 零长度行，历史 `attempt2` 才是少量 127-byte 行。
