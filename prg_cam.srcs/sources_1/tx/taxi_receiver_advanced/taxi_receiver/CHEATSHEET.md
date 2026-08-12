# 接收机架构决策与调优指南

面向工程实现与性能调优。每一节都按 **【数据/执行流程】→【工程原因】→【量化收益】** 三段展开，
命令只是结论的落地形式。

事实基线：当前源码 > 实测报告 > Git 历史 > 推测。所有数字均为本机实测，
测量方法附在对应小节。默认值以 `python -m taxi_receiver.cli --help` 为准（核对于 2026-08-05）。

---

## 1. 链路捕获与零拷贝解包（Capture & Line-Rate Parsing）

### 【数据/执行流程】

```
NIC → Npcap 内核环形缓冲(--pcap-buffer-size, 默认 8 MiB)
    → pcap_setfilter("ether proto 0x88b5")   内核态丢弃无关帧
    → pcap_next_ex()  ctypes 直取指针 + string_at 拷贝
    → 纯字节切片构造 RawEthernetFrame        ← 不再实例化 scapy Ether
    → 有界 queue.Queue(--queue-depth)         [边界①]
    → 共享 worker: ValidationStage → ParsingStage(binascii.crc_hqx)
```

核心函数：`ScapyLiveCapture._run_capture()`（`capture.py:176`）、
`peek_camera_id()`（`packet_format.py:136`）、`crc16_ccitt_false()`（`packet_format.py:150`）。
关键数据结构：`RawEthernetFrame`（`src_mac/dst_mac/ethertype/camera_id/payload/raw_bytes/timestamp`）。

### 【工程原因】

四条线程（capture / 共享 worker / lane×2）共用一个 GIL，所以每包 CPU 成本是**串行相加**的，
不是并行摊薄的。原实现里两处纯 Python 开销吃掉了 75% 的预算：

- **`Ether(packet_bytes)` = 28.8 μs/包。** pcap 句柄本来就是 ctypes/winpcapy，scapy 只被用来取
  `src`/`dst`/`type` 三个字段 —— 而 `ethertype` 已由内核 BPF 保证，三者都能切片得到。
- **纯 Python 查表 CRC16 = 10.5 μs/包。** 126 字节要跑 126 次 Python 循环迭代。

capture 线程抢不到 GIL → 来不及从 Npcap 内核缓冲取包 → 内核缓冲溢出 → `ps_drop`。
注意这个丢弃发生在**我们的第一行 Python 代码之前**，任何下游队列调参都无效。

### 【量化收益】

单包 GIL 预算（本机实测，40,000 包样本）：

| 阶段 | 优化前 μs/包 | 优化后 μs/包 | 手段 |
|---|---:|---:|---|
| capture 回调 | 28.8 | 0.5 | 字节切片替代 `Ether()`（52.6×） |
| L3 parse + CRC16 | 19.5 | 9.3 | `binascii.crc_hqx`（CRC 部分 39×） |
| L5 reassembly | 2.8 | 2.8 | — |
| L4 monitor | 0.5 | 0.5 | — |
| L2 validate | 0.4 | 0.4 | — |
| **合计** | **52.0** | **13.5** | **3.85×** |
| **单核吞吐上限** | **19,231 pkt/s** | **74,074 pkt/s** | 对 15,000 pkt/s 线速有 4.9× 余量 |

上板效果：`ps_drop` 从 **3,047,448 / 9,179,893（33.2%）** → **0**；
`sequence gaps` 从 1,674,620 + 1,823,492 → **0 + 0**；`Valid packets == Capture ingress`。

> **等价性已验证**：`binascii.crc_hqx(data, 0xFFFF)` 与 CRC-16/CCITT-FALSE 逐位等价
> （0/1/2/126/200 字节各 200 组随机数据全部相符），且与 FPGA `Byte_Replacer` 的 `crc16_byte` 一致。

### 命令

```powershell
# 内核缓冲加大到 64 MiB（run_receiver.ps1 未透出此参数，需直接调 CLI）
python -m taxi_receiver.cli --interface "\Device\NPF_{...}" --mode camera `
  --pcap-buffer-size 67108864
```

---

## 2. S1 每相机 Lane 与 S2 多进程发布（Process Architecture）

### 【数据/执行流程】

```
共享 worker (Layer1-3 结束)
    → CameraLanePool.submit(): 按 cam_id 路由，白名单外计 unroutable
    → 每相机 queue.Queue(--queue-depth / 2)              [边界②]
    → CameraLane 线程: FrameReassembler → rows_v2.csv 队列  [边界③]
                       → PublishPolicy 闸门
    → 每 sink 一个 AsyncCallbackDispatcher(--frame-output-queue-depth)  [边界④]
    → CameraImagePipeline.archive_frame()
         publish_async=True → _frame_to_envelope() → mp.Queue(--publisher-queue-depth) [边界⑤]
                            → 子进程 _run_image_publication_worker()
                                 → recover → PGM 编码 → RAW/JSON 落盘
```

跨进程载荷是 `_PublishedFrameEnvelope`：一块连续 `expected_rows × 80` 的 `rows_blob`，
外加 `present_rows` 位图与 `missing_rows`。

### 【工程原因】

- **S1（线程）解决的是隔离，不是速度。** 拆分前两台相机共用一条队列，cam1 的一次发布
  阻塞会让 cam0 的行在同一个队列里被无差别丢弃 —— 实测两路 `sequence gaps` 相差仅 0.1%，
  正是无差别丢弃的指纹。拆分后每路有独立的 `lane drops` 归账。
- **S2（进程）解决的才是速度。** recovery 解包（480 行 × 640 像素位展开）、PGM 编码、
  RAW/JSON 写盘是纯 CPU + I/O，在 GIL 下再多线程也不会并行。
- **`present_rows` 是必需字段不是优化。** `to_bytes()` 会把缺失行补零，光有 blob 无法区分
  "这行没收到"和"这行像素全 0"。丢掉它，子进程的 recovery 闸门会把每帧都判为完整帧，
  把补零行当真实数据发布。

### 【量化收益】

923,514 帧双相机负载，`recover-zero-fill` + `publish eligible`：

| 指标 | `--publish-images thread` | `--publish-images process` |
|---|---:|---:|
| Elapsed | 83.7 s | **65.0 s** |
| Consumer rate | 11,033 pkt/s | **14,214 pkt/s（+29%）** |
| lane `submit blocked` | 17.8 s + 57.2 s | **0.000 s + 0.000 s** |
| `publisher blocked` | — | 0.034 s + 0.044 s |
| images complete | 854 + 854 | 854 + 854 |
| 3,416 个 `.raw`/`.pgm` | — | **sha256 逐个一致** |

S1 单独的吞吐收益是 **−5%**（多一次队列跳转与线程交接），这与预期一致：GIL 下线程不并行。
把 S1 当性能手段是错的，它的价值是隔离与可观测性。

### 命令

```powershell
# S2 开（默认）
--publish-images process --publisher-queue-depth 2048
# S2 关（A/B 基准）
--publish-images thread
```

> **判断 S2 是否真的生效**：报告里必须同时出现 `-- sink: images` 与 `IMAGE PUBLICATION →
> publish mode: process`。只有 `-- sink: storage` 说明你没给 `--images-root`，
> 此时 `--publish-images` / `--publisher-queue-depth` 全是死参数。

---

## 3. Sink 隔离与磁盘 I/O 避坑（I/O Bottleneck Avoidance）

### 【数据/执行流程】

两条完全独立的输出通路，各自一个 dispatcher，互不影响：

| Sink | 开关 | 产出 | 每帧代价 |
|---|---|---|---|
| images | `--images-root` | `camN/<frame_id>.pgm/.raw/.json` | 位展开 + 编码 + 3 文件（已进子进程） |
| storage | `--output-root` | `cam_N/frame_<id>/` 4 个文件 + `summary_v2.csv` | `to_bytes` + sha256 + mkdir + 4 文件 + `os.replace` + 每帧 flush |
| rows_v2.csv | 默认开，`--no-rows-csv` 关 | `camN/rows_v2.csv` | 1 次 `put`（写在独立线程） |
| session_audit_v2.csv | `--session-audit` | `session_audit_v2.csv` | **同步写在 lane 线程上** |

### 【工程原因】

- **NTFS 目录元数据锁 + Defender 实时扫描。** 一次运行创建数万个小文件（5,754 帧 × 4 文件
  = 23,016 个）会让 `os.replace` 撞上 WinError 5/32，`_replace_directory_with_retry`
  退避重试到 0.5 s。同样帧率下 replay 阻塞 0 s、live 阻塞 220 s，差别只在文件系统。
- **`frame_id` 每次上电从 ~20 重启。** 复用同一个 archive root 会让每帧都撞上一次运行的目录。
  这曾导致 2,767 提交 / 0 成功的整场发布中断 —— 而当时退出码还是 0。
- **`session_audit_v2.csv` 与 `rows_v2.csv` 高度重复**，前者却是同步落盘在关键路径上。

### 【量化收益】

- archive root 改为 `run_<时间戳>` 子目录后，跨运行冲突 **2,767 → 0**。
- 冲突不再在 sink 线程抛异常（改写 `frame_<id>.dup<k>` 并计数），单个坏 sink 不再拖垮健康 sink：
  实测 storage 48/48 失败时 images 仍 48/48 成功。
- live 默认关闭 `session_audit_v2.csv`，从 lane 线程摘掉同步 CSV。
- stderr 从 2,767 条重复 traceback 降到每 sink 20 条上限（控制台写是同步慢操作，本身就是第二个瓶颈）。

### 命令

```powershell
# 吞吐运行：只留图像通路
--images-root R:\images --no-rows-csv --publish-frames complete
# 取证运行：加 archive，默认落到 run_<时间戳>\
-OutputRoot D:\...\archive          # 撞旧数据就退出 6：-ArchiveRootPolicy require-empty
```

---

## 4. PowerShell 诊断与生产命令（Command Architecture）

### 【数据/执行流程】

梯度式：每一级只引入一个新变量，上一级不干净就不要进下一级。

### 【工程原因】

测吞吐时必须剥离文件系统影响，否则你测的是 Defender 不是接收机；
生产采集时才打开容错补零，否则 `--publish-frames complete` 会在 recovery 之前就把
非完整帧滤掉，`--image-policy recover-zero-fill` 形同虚设。

### 【量化收益】

形成四道闸门的可复现压测体系（`verify_s2.ps1`），实测全量包 Gate 3 `105.26 s → 0.00 s`、
Gate 1 `3,416 files 逐字节一致`。

### 梯度命令

```powershell
cd D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver

# L0 找接口
python -m taxi_receiver.cli --list

# L1 连通性盲测（不落盘，只看 Matching / Valid / CRC / CAMERA N packets）
python -m taxi_receiver.cli --interface "\Device\NPF_{...}" --mode camera

# L2 纯 S2 线速压测（剥离一切文件系统影响；R: 为 RAMDisk）
python -m taxi_receiver.cli --interface "\Device\NPF_{...}" --mode camera `
  --images-root R:\images `
  --publish-images process --publisher-queue-depth 2048 `
  --frame-output-queue-depth 2048 --pcap-buffer-size 67108864 `
  --no-rows-csv --publish-frames complete

# L3 容错救帧采集（生产）
.\run_receiver.ps1 -Interface "\Device\NPF_{...}" `
  -ImagesRoot D:\prg\prg_cam\build\runN\images `
  -ImagePolicy recover-zero-fill -PublishFrames eligible

# L4 离线无损 A/B + 四道闸门
.\verify_s2.ps1 -ReplayPcap D:\prg\prg_cam\build\wire.pcapng `
                -OutRoot D:\prg\prg_cam\build\s2_verify
```

四道闸门：① 每张图 sha256 一致 ② publisher 进程真的发布且零失败
③ lane `submit blocked` 至少腰斩 ④ live 下 consumer ≥ producer 且 lane 丢弃为 0。

---

## 5. 丢包定位模型：四个位置，从上往下看

上游没解决，下游数字没有意义。

| 报告字段 | 物理位置 | 判据 | 修复方向 |
|---|---|---|---|
| `ps_drop` | Npcap 内核缓冲 → 用户态 | 与 `Capture queue drops` **同时**看：队列没满而 ps_drop 大 = capture 线程 GIL 饥饿 | 降低单包成本（第 1 节）；`--pcap-buffer-size` 只是缓解 |
| `Capture queue drops` | capture 线程 → 共享 worker | `Capture queue peak == capacity` | 共享 worker 的 L2/L3 成本 |
| `Lane queue drops` | 共享 worker → lane | `lane peak == capacity` | **去看 `submit blocked`**，几乎总是下游 sink |
| `csv_rows_dropped` | lane → rows_v2.csv writer | `csv_queue_peak` 接近容量 | `--csv-queue-depth` 或 `--no-rows-csv` |

判断某个 sink 是不是天花板，只看一个数：

```
CAMERA LANE 0
  -- sink: images
  submit blocked : 34.249 s over 61 waits      ← ÷ Elapsed = 该 lane 被这个 sink 拖住的比例
```

> **口径**：`queue peak == capacity` 只能证明"满过一次"，**不能**证明它是瓶颈；
> `submit blocked` 才能。S2 生效后 `submit blocked` 应趋近 0，阻塞转移到 `publisher blocked`，
> 那才是真正的发布上限。

---

## 6. 退出码

| 码 | 含义 |
|---|---|
| 0 | 正常 |
| 2 | 参数错（互斥选项；`recover-zero-fill` 缺 `--images-root` 或 `--expected-rows≠480`） |
| 3 | 抓包权限不足 —— 管理员身份打开终端 |
| 4 | 抓包 OSError（接口名错、Npcap 未装） |
| 5 | 未安装 scapy（live 需要；`--replay-pcap` 不需要） |
| 6 | archive root 已有旧帧数据（`require-empty` 策略） |
| 7 | 某个 sink 一帧都没成功，或连续失败被熔断；stderr 点名是哪个 |

---

## 7. 完整开关表（按功能分组）

### 数据源
| CLI | ps1 | 默认 | 作用 |
|---|---|---|---|
| `--interface` | `-Interface` | 必填 | live 抓包接口 |
| `--replay-pcap` | — | — | 离线 replay，与 `--interface` 互斥；**无损**（阻塞背压） |
| `--pcap` | — | — | 顺便把匹配帧录成 pcap |
| `--pcap-buffer-size` | — | 8 MiB | Npcap 内核缓冲，`pcap_set_buffer_size()` |
| `--source-mac` | — | `02:00:00:00:00:02` | 仅离线 replay 的源 MAC 过滤 |

### 处理深度
| CLI | ps1 | 默认 | 作用 |
|---|---|---|---|
| `--mode` | 固定 `camera` | `camera` | `fixed` 是 00..7F 诊断源 |
| `--max-stage` | 固定 `reassemble` | `monitor` | validate/parse/monitor/reassemble |
| `--reassemble` | — | 关 | `--max-stage reassemble` 简写 |
| `--expected-rows` | `-ExpectedRows` | 480 | 每帧行数 |
| `--frame-timeout` | — | 2.0 s | 会话超时 |

> 给了 `--output-root` 或 `--images-root` 时 `max_stage` 自动提到 `reassemble`。

### S1 每相机分线
| CLI | ps1 | 默认 | 作用 |
|---|---|---|---|
| `--split-by-camera` | `-SplitByCamera` | `auto` | auto = camera 模式且有 root 时开；`off` 用于 A/B |
| `--camera-ids` | `-CameraIds` | `0,1,2,3` | cam_id 白名单（该字节来自线上，不可信） |
| `--queue-depth` | `-QueueDepth` | 8192 / ps1 65536 | 共享 capture 队列；lane 队列 = 其一半 |

### S2 图像发布
| CLI | ps1 | 默认 | 作用 |
|---|---|---|---|
| `--images-root` | `-ImagesRoot` | ps1 自动算 | **不给就没有图像通路，S2 无从生效** |
| `--publish-images` | `-PublishImages` | `process` | `thread` 是 S2 前行为，A/B 基准 |
| `--publisher-queue-depth` | `-PublisherQueueDepth` | 256 | lane → publisher 进程的有界 IPC 队列 |
| `--frame-output-queue-depth` | `-FrameOutputQueueDepth` | 256 | reassembly → sink 的有界队列 |
| `--publish-frames` | `-PublishFrames` | `complete` | 非完整帧是否进 sink；配 recovery 用 `eligible` |
| `--image-policy` | `-ImagePolicy` | `strict` | `recover-zero-fill` 才补零救帧 |
| `--max-missing-rows` | `-MaxMissingRows` | 4 | recovery 允许的总缺行 |
| `--max-consecutive-missing` | `-MaxConsecutiveMissing` | 2 | 排他阈值，2 = 最多容忍连续 1 行 |
| `--bit-order` | — | `msb_first` | 80 字节打包行的位序 |

### 遥测与取证
| CLI | ps1 | 默认 | 作用 |
|---|---|---|---|
| `--no-rows-csv` | `-NoRowsCsv` | 开着 | 关掉每包 rows_v2.csv |
| `--csv-queue-depth` | — | 65536 | rows_v2.csv 队列 |
| `--csv-backpressure` | — | `auto` | auto = replay 阻塞 / live 丢弃 |
| `--session-audit` | `-SessionAudit` | `auto` | auto = live 关 / replay 开；需 `--output-root`；**同步写** |
| `--output-root` | `-OutputRoot` | 无 | frame archive；最贵的 sink |
| `--archive-root-policy` | `-ArchiveRootPolicy` | `run-subdir` | run-subdir / require-empty / reuse |
| `--archive-collision-policy` | `-ArchiveCollisionPolicy` | `suffix` | 撞名写 `.dup<k>`，不在 sink 线程抛异常 |
| `--error-directory` | — | 无 | 畸形载荷存二进制 |
| `--report-interval` | — | 1.0 s | 周期速率行；`1e9` = 只要最终报告 |

---

## 8. 已知缺陷（影响读数，不影响已落盘数据）

**Ctrl+C 会连带杀死 S2 子进程。** Windows 把 CTRL_C_EVENT 投递给整个控制台进程组，
`_run_image_publication_worker` 只捕获 `Exception`，而 `KeyboardInterrupt` 是 `BaseException`，
子进程在 `work_queue.get()` 处直接退出，不回应统计握手。后果：

- 已发布的图像**在盘上完好**（实测 1,456 + 1,456 张 PGM 齐全）；
- `IMAGE PUBLICATION` 整段读数为 0（`publisher published: 0`、`stats ok: 0`、`images complete: 0`）——
  **这是假读数，不是真丢失**；
- 关闭时每条 lane 在 `result_queue.get(timeout=120)` 上空等，2 路 = 约 240 s 挂起；
- IPC 队列中尚未消费的帧（上限 `--publisher-queue-depth`）确实丢失。

规避：用离线 `--replay-pcap` 做需要读 `IMAGE PUBLICATION` 的测量（自然结束，不走 Ctrl+C），
或直接数盘上的 `.pgm` 文件数。修复方向见文档 07 第 8 章。
