# P11 Python 接收端性能优化源码机制审计

> 审计日期：2026-07-28  
> 审计对象：`taxi_receiver_advanced/taxi_receiver` 当前工作树  
> 修改前基准：Git `HEAD`，提交 `de56798`（`chore: complete signle-camera transmission through Ethernet`）  
> 证据顺序：当前源码与 `git diff` > `git show de56798:<path>` > 测试与运行报告  
> 本文只解释现有修改，不修改恢复策略、Layer1～Layer3校验或线上协议。

## 证据边界

以下已跟踪文件可以直接通过 `git show HEAD:<path>` 取得修改前版本，并通过
`git diff -- <path>` 与当前工作树逐行比较：

- `taxi_receiver/cli.py`
- `run_receiver.ps1`
- `taxi_receiver/capture.py`
- `taxi_receiver/pipeline.py`
- `taxi_receiver/stream_monitor.py`
- `taxi_receiver/storage.py`
- `tests/test_pipeline_synthetic.py`
- `tests/test_reassembler.py`
- `Camera_Capture.v`
- `scripts/build_ethernet_ila.tcl`
- `scripts/inspect_camera_capture_debug_nets.tcl`

以下文件是当前工作树中的未跟踪新文件，Git `HEAD` 中不存在旧版本：

- `taxi_receiver/async_sink.py`
- `analyze_camera_archive.py`

因此，对这两个文件只能确认“修改前没有该文件、修改后新增该机制”，不能虚构一个
旧实现。当前工作树中还存在此前 RECOVERED 功能产生的 `image_pipeline.py` 和
`test_image_recovery.py` 改动；它们不是本轮性能优化的主要 diff，本文只在真实
调用链需要时引用其当前行为。

---

## A. 核心方向总结

本轮修改没有改变 Camera packet 的解析、严格校验、重组规则或 FPGA Ethernet
协议。性能优化集中在三件事：

1. 将“完整帧完成后”的 RAW/PGM/JSON、frame archive 和 per-frame CSV 写盘，
   从 `taxi-worker` 的 packet 热路径移到独立的、有界的 frame output queue 和
   output worker。
2. 减少热路径中的第二次完整 Ethernet frame 复制，并把 `summary_v2.csv` 从
   “每帧读取并重写全部历史”改为持久句柄追加。
3. 增加 capture packet queue 的容量、高水位、drop 百分比和生产/消费速率，
   使“Python 消费者跟不上”可以直接从报告中判断。

需要严格限定优化范围：`image_pipeline.record_packet()` 和
`SessionAuditLogger` 仍通过 `on_frame_processed` 在 packet consumer 中运行，
逐包 `rows_v2.csv`/`session_audit_v2.csv` 格式化没有被移入 frame output worker。
它们当前采用批量/定时 flush，而不是每行 `fsync`，但如果它们本身成为新的 CPU
瓶颈，仍需用下一轮 queue 指标证明，不能假设已经消失。

---

## B. 修改前与修改后的数据流

### B.1 修改前

```text
 NIC / Npcap / Scapy callback
              |
              v
 +----------------------------------+
 | capture packet queue             |
 | queue.Queue[RawEthernetFrame]     |
 | live 满队列：put_nowait 失败/drop |
 +----------------------------------+
              |
              v
       taxi-worker（单线程）
              |
              v
 Validation -> Parsing -> Monitor -> Reassembler
                                      |
                                      | CompletedFrame
                                      v
                          on_completed_frame（同步）
                                      |
                      +---------------+----------------+
                      |                                |
                      v                                v
             StorageAndPipeline               CameraImagePipeline
             RAW/JSON/packets.csv              PGM/RAW/JSON
             errors.json/summary_v2.csv        recovered/rejected
                      |                                |
                      +---------------+----------------+
                                      |
                                      v
                         返回处理下一 Ethernet packet

 同一 taxi-worker 还同步执行：
 on_frame_processed -> session_audit_v2.csv + images/camN/rows_v2.csv
```

修改前 `cli.py` 的 `on_completed_frame` 直接绑定
`_fanout_callbacks(storage, image_pipeline.archive_frame)`。在
`stages.py:149-184` 中，`ReassemblyStage.process()` 调用 `_emit()`，
而 `_emit()` 直接执行 `self.on_completed_frame(completed)`。因此完整帧一旦
关闭，目录创建、JSON 序列化、RAW/PGM 写入、flush/fsync、rename 和
`summary_v2.csv` 更新都发生在 `taxi-worker` 内。

磁盘操作把单个 packet 的 consumer 服务时间拉长。生产端仍持续通过
`ScapyLiveCapture._callback()` 向 capture packet queue 投递，队列库存逐渐增长；
到达 `maxsize` 后，实时模式的 `put_nowait()` 抛出 `queue.Full`，该 Ethernet
packet 在进入 Layer2 之前被主动丢弃。

### B.2 修改后

```text
 NIC / Npcap / Scapy callback
              |
              v
 +----------------------------------+
 | capture packet queue             |  数据单位：一个 Ethernet packet
 | producer: capture callback       |
 | consumer: taxi-worker            |
 | live 满队列：主动 drop 并计数    |
 +----------------------------------+
              |
              v
       taxi-worker（packet 热路径）
              |
              v
 Validation -> Parsing -> Monitor -> Reassembler
                                      |
                                      | CompletedFrame
                                      v
 +--------------------------------------------------+
 | bounded frame output queue                       |
 | producer: taxi-worker                            |
 | consumer: taxi-frame-output worker               |
 | 满队列：submit() 阻塞，不静默丢完整图像          |
 +--------------------------------------------------+
                                      |
                                      v
                          output worker（单线程）
                                      |
                      +---------------+----------------+
                      |                                |
                      v                                v
             StorageAndPipeline               CameraImagePipeline
             RAW/JSON/packets.csv              PGM/RAW/JSON
             errors.json/summary_v2.csv        recovered/rejected

 packet 热路径中仍然保留：
 on_frame_processed -> session_audit_v2.csv + images/camN/rows_v2.csv
```

短时磁盘抖动会积压在 frame output queue 中，不再立即延长每个 packet 的解析
时间。这个队列有上限，不是无限内存：若磁盘长期低于图像产生速率，
`AsyncCallbackDispatcher.submit()` 最终会在 `queue.put()` 阻塞，背压重新
传回 `taxi-worker`，继而可能使 capture packet queue 增长并产生 drop。这是
有界系统的预期行为，也是为什么必须同时看两个 queue peak。

---

## C. 按文件展开源码对比

### C.1 `taxi_receiver/async_sink.py`

#### 【文件及职责】

路径：`taxi_receiver/async_sink.py`  
主要类：`AsyncCallbackDispatcher`（第 23 行）  
位置：Layer5 完整帧关闭后，位于 reassembler 与磁盘输出 sink 之间。

#### 【修改前】

Git `de56798` 中没有此文件。修改前 `CompletedFrame` 由 packet consumer 直接
传给同步输出回调；证据在旧版 `cli.py:176` 和 `stages.py:181-184`。

#### 【修改后】

构造函数在第 32～57 行创建有界 `queue.Queue(maxsize=queue_depth)` 和独立
daemon worker。最关键的入队代码在第 59～67 行：

```python
def submit(self, item: T) -> None:
    if self._closed:
        raise RuntimeError("async callback dispatcher is closed")
    self._queue.put(item)
    self.stats.submitted += 1
    self.stats.queue_peak = max(
        self.stats.queue_peak,
        self._queue.qsize(),
    )
```

这里使用阻塞式 `put()`，没有 `put_nowait()` 和 drop 分支。frame output queue
满时，生产者即 `taxi-worker` 等待空位，完整图像不会被静默丢弃。

worker 位于第 89～103 行。回调成功才递增 `processed`；异常时递增
`failures` 并输出 `[FRAME OUTPUT ERROR]`，最后始终 `task_done()`。

关闭逻辑位于第 69～78 行：

```python
self._queue.join()
self._queue.put(_STOP)
self._worker.join(timeout=30.0)
```

先 drain 所有已提交 frame，再投递停止标记，最后 join worker。

#### 【修改理由】

解决完整帧 RAW/PGM/JSON/归档同步写盘阻塞 packet consumer 的问题。它不提高
磁盘本身速度，而是用有限缓冲把短时输出延迟与 packet 解析解耦。

#### 【边界风险】

- callback 异常不会使主线程抛异常或返回非零退出码；主线程只能通过 stderr 和
  最终 `callback failures` 感知。这是“可观察但不强制失败”的策略。
- `close()` 的 `queue.join()` 没有超时。如果 callback 永久挂起而不是抛异常，
  退出也会永久等待；30秒 timeout 只作用于 drain 完成后的 worker join。
- queue 满时 `submit()` 会阻塞并把背压重新传给 packet consumer。
- `CompletedFrame` 本身不是 frozen dataclass。但 `reassembler.py:319-359`
  在关闭 session 时先 `pop()`，并用 `dict(session.rows)`、
  `list(session.packet_records)`、`list(session.errors)` 创建快照；row payload
  是不可变 `bytes`。按当前单一所有权调用关系，入队后 reassembler 不再修改它。
  类型系统没有禁止未来 callback 修改同一对象，这是后续维护风险。
- queue depth 太小，短时写盘抖动就会回传背压；太大则会放大内存占用。
  一个 `CompletedFrame` 不只是像素 bytes，还包含 rows 字典和约480条
  `PacketRecord`，不能用“帧数×38.4KB”低估实际内存。

#### 【验证证据】

`tests/test_pipeline_synthetic.py:117-181` 对同一组100帧分别使用同步慢回调和
异步 dispatcher。同步路径出现 capture drop，异步路径满足：

```text
dropped_capture_queue == 0
submitted == 100
processed == 100
failures == 0
queue_peak > 0
```

该测试证明机制层面的解耦，不证明真实磁盘在120秒内一定持续跟得上。

---

### C.2 `taxi_receiver/cli.py`

#### 【文件及职责】

路径：`taxi_receiver/cli.py`  
主要函数：`build_argument_parser()`、`main()`、`_fanout_callbacks()`  
位置：组装 capture、pipeline、reassembler、输出 sink，并负责退出生命周期。

#### 【修改前】

Git `de56798` 的 `cli.py:176`：

```python
on_completed_frame=_fanout_callbacks(
    storage,
    image_pipeline.archive_frame if image_pipeline is not None else None,
),
```

该回调由 `ReassemblyStage._emit()` 在 `taxi-worker` 中同步执行。旧版
`cli.py:228-238` 在退出时先 `pipeline.stop()`，随后只关闭 session audit 和
image pipeline；`StorageAndPipeline` 当时也没有持久 summary 句柄需要关闭。

#### 【修改后】

第 53～61 行增加 `--frame-output-queue-depth`。第 212～221 行先组合真实输出
回调，再创建 dispatcher：

```python
completed_frame_callback = _fanout_callbacks(
    storage,
    image_pipeline.archive_frame if image_pipeline is not None else None,
)
frame_output = AsyncCallbackDispatcher(
    completed_frame_callback,
    queue_depth=args.frame_output_queue_depth,
)
```

第 248～250 行将 reassembler 的完成回调改为：

```python
on_completed_frame=frame_output.submit
```

`_fanout_callbacks()` 位于第 326～350 行。它即使遇到第一个 sink 异常，也继续
调用其他 sink，最后重新抛出第一个异常。异步 worker 因而会把整个 frame 标成
一次 callback failure，但不会因为 archive A 失败而跳过 archive B。

退出顺序在第 300～322 行：

1. `pipeline.stop()`：停捕获、drain capture packet queue、join packet worker、
   flush reassembler；flush 产生的 frame 也会提交到 frame output queue。
2. `frame_output.close()`：drain frame output queue 并 join output worker。
3. 打印 packet/reassembly、frame output 和 image publication 报告。
4. 最内层 `finally` 再次幂等 close dispatcher，然后关闭 session audit、
   per-camera rows CSV、summary CSV。

第 231～235 行按 `pcap_recorder is not None` 设置 `include_raw`，把是否保留完整
L2 frame 的决策下推到 capture 层。

#### 【修改理由】

- 完成帧输出移出 packet consumer。
- 把 output queue 深度变成显式运行参数。
- 确保退出时两个队列按正确顺序 drain，持久 CSV 句柄最终 close。
- 避免未录制 PCAP 时构造无消费者的完整 frame bytes。

#### 【边界风险】

- output worker 的异常只体现在 stderr 和最终 failure count，CLI 不据此返回
  非零状态。
- `_fanout_callbacks` 的两个 sink 接收同一个 `CompletedFrame` 对象；当前 sink
  只读它，但没有 frozen 类型强制。
- 单一全局 output worker 保持提交 FIFO 顺序，也意味着某个 camera 的慢写盘会
  串行阻塞另一个 camera。目录名含 `cam_<id>/frame_<id>`，不会因相同 frame_id
  在不同 camera 间碰撞。
- `on_frame_processed` 仍同步执行 `session_audit` 和
  `image_pipeline.record_packet`（第 251～254 行）。本轮没有把逐包 CSV 完全
  异步化。

#### 【验证证据】

- `test_slow_frame_storage_is_decoupled_from_capture_queue`
- 最终报告新增 `FRAME OUTPUT QUEUE`：
  capacity、peak、submitted、processed、failures。
- 当前全部 pytest：88项通过。

---

### C.3 `run_receiver.ps1`

#### 【文件及职责】

路径：`run_receiver.ps1`  
位置：Windows live capture 启动入口，将 PowerShell 参数传给 Python CLI。

#### 【修改前】

Git `de56798` 的第10行只有 `$QueueDepth=65536`；第32～34行只传
`--queue-depth`、`--output-root` 和 `--images-root`，不存在 frame output
queue 参数。

#### 【修改后】

当前第12行新增：

```powershell
[int]$FrameOutputQueueDepth = 256
```

第45行传入：

```powershell
--frame-output-queue-depth $FrameOutputQueueDepth
```

同一 diff 中还包含 `ImagePolicy/MaxMissingRows/MaxConsecutiveMissing` 参数；这些
属于之前的 RECOVERED 功能，不是输出解耦本身。

#### 【修改理由】

允许现场测试独立调节 packet queue 和 completed-frame queue，避免把两个深度
混成一个参数。

#### 【边界风险】

- 过小：短时 Defender/磁盘抖动就会让 `submit()` 阻塞。
- 过大：延迟异常暴露、退出 drain 时间变长、占用大量内存。
- `-ExecutionPolicy Bypass` 只是调用方式，不改变脚本内部队列语义。

#### 【验证证据】

CLI 启动时打印 `Frame output queue: <depth>`，结束时输出真实 peak/capacity。

---

### C.4 `taxi_receiver/capture.py`

#### 【文件及职责】

路径：`taxi_receiver/capture.py`  
主要类：`RawEthernetFrame`（第27行）、`ScapyLiveCapture`（第49行）  
位置：Layer1，Scapy/Npcap callback 到普通 Python bytes 对象的边界。

#### 【修改前】

Git `de56798` 的 `capture.py:76-77`：

```python
payload=bytes(eth.payload),
raw_bytes=bytes(packet),
```

每个包至少构造 payload bytes，同时无条件再序列化一次完整 Scapy packet。
即使没有 `PcapRecorder` 消费 `raw_bytes`，第二份完整 L2 bytes 仍被分配。

#### 【修改后】

第 59～68 行增加 `include_raw`。第 81～87 行：

```python
payload=bytes(eth.payload),
raw_bytes=bytes(packet) if self.include_raw else b"",
```

`cli.py:231-235` 只在 `pcap_recorder` 存在时启用完整 frame 副本。

#### 【修改理由】

减少的是：

- `bytes(packet)` 的 Scapy 序列化 CPU；
- 完整 L2 frame 的额外对象分配；
- 该副本的内存带宽和后续垃圾回收压力。

它没有取消 `bytes(eth.payload)`，因为 Layer2/3 必须在 Scapy callback 返回后继续
使用128-byte payload。

#### 【边界风险】

底层 capture buffer 生命周期是安全的：`payload` 始终被复制为不可变 `bytes`，
`RawEthernetFrame` 不保留 Scapy Packet 或 memoryview。关闭 `include_raw` 后，
`raw_bytes` 只是独立的空 `bytes`，不存在 callback 返回后引用 Npcap buffer 的
问题。启用 `--pcap` 时仍必须保留 `bytes(packet)`，优化不会生效。

#### 【验证证据】

Git diff 清楚显示无条件完整复制变成条件复制；现有 Layer1/2、PCAP replay 和
全部 pytest 均通过。

---

### C.5 `taxi_receiver/pipeline.py`

#### 【文件及职责】

路径：`taxi_receiver/pipeline.py`  
主要类：`TaxiReceiverPipeline`（第33行）  
位置：capture callback、capture packet queue 和 `taxi-worker` 的编排边界。

#### 【修改前】

Git `de56798` 已经使用有界 packet queue。旧版第144～146行：

```python
self._queue.put_nowait(frame)
except queue.Full:
    self.monitor.record_dropped_capture()
```

因此“实时队列满后主动drop”不是本轮新增行为。本轮之前的问题是无法看到容量和
峰值，而且完成帧同步写盘会拖慢该队列的唯一 consumer。

#### 【修改后】

第 51～52 行拒绝非正 queue depth；第72行把容量交给 monitor。第 136～153 行
在 lossless/offline 和 live 两条成功入队路径上记录 `qsize()`：

```python
self._queue.put_nowait(frame)
self.monitor.record_capture_queue_depth(self._queue.qsize())
```

live `queue.Full` 仍然只执行 `record_dropped_capture()`；没有改成无限队列。
offline replay 则使用带 timeout 的阻塞 put，保留证据而不主动drop。

退出时第101～117行先停止 source，再 `self._queue.join()`，随后 join worker，
最后 flush reassembler。这是 capture queue “结束时无未解释积压”的门槛。

#### 【修改理由】

让“队列真的到过多深”成为证据，并校验配置，而不是改变原有实时丢包策略。

#### 【边界风险】

- `qsize()` 在并发环境中是近似瞬时值；这里只有单 producer callback 和单
  consumer 的诊断用途，适合做 high-water mark，但不是同步原语。
- peak 只在成功入队后更新。发生 `Full` 时没有再次写 capacity，但既然 Full
  已经发生，就可确定队列曾达到 capacity。
- output queue 满后阻塞 `taxi-worker`，仍可能间接推高 capture queue。

#### 【验证证据】

120秒旧报告中 `Capture queue drops=82135` 已证明旧队列发生 Full；新报告将
同时给出 `Capture queue peak=<peak>/<capacity>`。

---

### C.6 `taxi_receiver/stream_monitor.py`

#### 【文件及职责】

路径：`taxi_receiver/stream_monitor.py`  
主要类：`GlobalStatistics`（第39行）、`StreamMonitor`（第68行）  
位置：Layer1～Layer4计数和周期/最终报告。

#### 【修改前】

Git `de56798` 有 ingress、matching 和 drops，但没有 queue capacity/peak。
旧版第159～164行把 Ethernet packet 增量命名为 `fps`，最终第202行打印
`Average frame rate`，容易被误读为 camera image fps。

#### 【修改后】

第 50～52 行新增：

```python
dropped_capture_queue: int = 0
capture_queue_capacity: int = 0
capture_queue_peak: int = 0
```

第84～92行设置容量并取历史最大值。周期报告第163～194行：

- `packets_per_second = matching frame 增量 / 本次报告间隔`
- 单位是 Ethernet packets/s；
- 窗口是相邻两次周期报告之间。

最终报告第196～241行：

- `elapsed = 当前monotonic - GlobalStatistics创建时刻`
- `producer_rate = total_ethernet_frames / elapsed`
- `consumer_rate = matching_frames / elapsed`
- `drop_percent = dropped_capture_queue / total_ethernet_frames × 100%`
- `queue_peak/capacity` 是整个进程生命周期内的最大成功入队深度/配置上限。

计数起点必须明确：

- `Capture ingress` 在 `pipeline._on_frame()` 一进入 Python callback handoff 时
  增加；它不是 NIC 线速计数，也看不到 callback 之前的 kernel/Npcap drop。
- `Matching Ethernet` 在 `stages.py:67-80` 的 Ethernet validation 成功后增加，
  因而已经从 packet queue 出队并由 consumer 处理。
- `Valid packets` 还要通过 Layer3 Camera校验。

#### 【修改理由】

把“消费者比生产者慢”从推测变成可量化结论，并纠正 packet rate 与 camera
image fps 的术语混淆。

#### 【边界风险】

- 当前 `consumer_rate` 实际是“通过 Ethernet validation 的平均 packet rate”。
  若出现 Layer2 validation failure，它会小于 dequeue rate；必须与
  `Bad Ethernet length/validation failures` 一起解释。
- 平均值可能掩盖短时突发，因此仍需看 peak 和周期性 drop 增量。
- image fps 只能看 `IMAGE PUBLICATION` 的 complete/recovered/usable 指标。

#### 【验证证据】

旧报告：

```text
Capture ingress       = 877432
Matching Ethernet     = 795297
Capture queue drops   = 82135
```

且没有 Bad Ethernet length、Parser error 或 Processing error，因此：

```text
877432 - 795297 = 82135
```

这与 `_on_frame()` 的 Full 分支定义完全一致。

---

### C.7 `taxi_receiver/storage.py`

#### 【文件及职责】

路径：`taxi_receiver/storage.py`  
主要类：`StorageAndPipeline`（第44行）  
位置：完整 frame 的原子目录归档和全局 `summary_v2.csv`。

#### 【修改前】

Git `de56798` 的 `_append_summary()` 第158～180行：

```python
existing = []
if self.summary_path.exists():
    existing.extend(csv.DictReader(handle))
...
writer.writerows(existing)
writer.writerow(row)
os.replace(temp_path, self.summary_path)
```

第 `n` 帧写入时读取并写回前 `n-1` 行。累计工作量：

```text
1 + 2 + ... + n = n(n+1)/2 = O(n²)
```

帧数越多，每次 summary 更新越慢。修改前该操作还在 packet consumer 的同步
completed-frame 回调中。

#### 【修改后】

第 49～53 行增加持久 `_summary_handle/_summary_writer` 和 lock。第 169～211
行改为：

```python
writer = self._get_summary_writer()
writer.writerow(row)
self._summary_handle.flush()
```

首次打开时：

1. 检查现有文件是否非空；
2. 非空则读取一次 header，并要求严格等于 `SUMMARY_FIELDS`；
3. 以 append 模式打开；
4. 只在空文件写一次 header。

后续每帧只追加一行，单次写入接近 O(1)。第 96～102 行 `close()` 在程序退出时
flush、close 并清空引用。

frame目录本身的原子发布没有改变：第55～91行先在 sibling temp directory 中
写完并关闭 RAW/JSON/packets.csv/errors.json，再调用
`_replace_directory_with_retry()` rename。Windows临时外部句柄仍按既有逻辑重试。

#### 【修改理由】

去掉 summary 历史全表遍历和全文件重写，并把该写盘移到 output worker。

#### 【边界风险】

- 当前每条 summary 仍执行 Python `flush()`，但不执行 `os.fsync()`；正常退出时
  close 可保证 Python buffer 写出，断电时不提供介质级持久性保证。
- append 的单行不是 crash-atomic；进程恰好在 `writerow` 中止时可能留下不完整
  尾行。旧版 temp+replace 对 summary 更抗中断，但代价是 O(n²)。
- schema 不匹配会抛 `ValueError`，不会静默追加错误列；异步 worker记录 failure。
- `_summary_lock` 保证进程内线程安全。当前正常路径只有单一 output worker 使用
  句柄；lock 不提供跨进程文件锁，不能同时启动两个 receiver 写同一个 OutputRoot。
- frame目录 rename 已成功、随后 summary append 失败时，frame目录会存在但
  summary 缺行。错误会计入 output callback failure，没有自动回补机制。

#### 【验证证据】

Git diff 直接证明旧版 `DictReader + writerows(existing) + os.replace` 被持久
append 替换；全部 storage/receiver pytest 通过。

---

### C.8 `analyze_camera_archive.py`

#### 【文件及职责】

路径：`analyze_camera_archive.py`  
主要函数：`analyze_csv()`（第17行）、`analyze_images()`（第106行）、
`_row_hashes()`（第223行）  
位置：离线诊断，不在 live capture 热路径。

#### 【修改前】

Git `de56798` 中不存在该文件，无法取得旧实现。

#### 【修改后】

`analyze_csv()` 流式读取全部 `rows_v2.csv`，跳过用于视觉分帧的空行，并统计：

- flags、errors、length error；
- length error 的 payload_len字段、row_idx、frame_id和10秒时间桶；
- FIRST/LAST相关性和row_idx越界。

它在第88行明确输出：

```text
physical_href_byte_count_distribution = NOT_RECORDED_IN_CSV
```

因此不会把 packet header 的 `payload_len` 冒充 ILA 的 Camera byte_count。
随后读取全部 `rejected.csv`，统计重叠 reject reasons、missing count 和最大
连续缺行分布。

`analyze_images()` 读取：

- complete目录下的全部 JSON/RAW/PGM；
- recovered目录下的全部 `metadata.json/image.raw/image.pgm`；
- RAW是否严格为640×480；
- PGM像素体是否逐字节等于RAW；
- JSON `missing_rows` 对应的每个固定 row_idx 是否整行全零。

第 177～202 行对分布抽样的相邻 frame 计算每行 SHA-256，并分别报告：

- 相同位置hash数量；
- 排除当前帧 missing rows 后的相同位置hash数量；
- 具体相同行样例。

#### 【修改理由】

把“zero fill 是否插在正确 row_idx”和“是否有跨帧旧行复用”从视觉判断变成
逐字节证据。

#### 【边界风险】

- 默认只抽样12组相邻已发布frame，不是所有frame两两比较。
- 静止场景中，相邻帧对应行完全相同是合法现象；相同行hash本身不能证明污染。
- 脚本能证明 missing row 是否为零、PGM与RAW是否一致，但无法仅凭输出图像证明
  某个非missing行的来源一定是当前传感器曝光。最终还需 frame_id/row_idx、
  reassembler生命周期和合成测试联合判断。
- `ROW_PIXELS=640`、`EXPECTED_ROWS=480` 是当前图像配置事实；配置改变后脚本也
  必须同步更新。

#### 【验证证据】

attempt3全量运行结果：

```text
rows_v2.csv records          795297
rejected.csv records         802
published images             1022
invalid RAW sizes            0
PGM/RAW mismatches           0
zero-fill failures           0
```

---

### C.9 `tests/test_pipeline_synthetic.py`

#### 【文件及职责】

路径：`tests/test_pipeline_synthetic.py`  
主要测试：`test_slow_frame_storage_is_decoupled_from_capture_queue()`
（第117行）  
位置：无硬件的 capture/consumer并发回归。

#### 【修改前】

Git `de56798` 的文件在第111行结束，没有慢消费者测试。

#### 【修改后】

第120～129行构造100个“一包即一完整帧”的 synthetic Camera frame。
`slow_store()` 每帧睡眠2ms，`PacedFrameSource` 每0.5ms生产一帧，capture queue
深度固定为2。

第一轮直接把 `slow_store` 作为同步 `on_completed_frame`，断言出现 capture
drop。第二轮把相同回调放进 `AsyncCallbackDispatcher`，断言 capture drop为0、
100帧全部 processed、failure为0。

#### 【修改理由】

直接复现因果链：

```text
同步慢回调 -> packet consumer服务时间变长 -> 小队列Full -> capture drop
```

再证明异步frame output能切断这个短时因果链。

#### 【边界风险】

该测试没有证明：

- Npcap/NIC在真实速率下零丢包；
- Windows Defender和真实磁盘120秒持续吞吐；
- output queue 深度256永远不会满；
- 逐包 rows/session CSV 已不构成瓶颈；
- FPGA length error 得到修复。

#### 【验证证据】

当前全套 pytest：`88 passed`。该测试中的同步/异步两组断言均通过。

---

### C.10 `tests/test_reassembler.py`

#### 【文件及职责】

路径：`tests/test_reassembler.py`  
主要测试：`test_frame_switch_never_reuses_previous_frame_rows()`（第77行）  
位置：Layer5 session生命周期与固定row_idx布局验证。

#### 【修改前】

Git `de56798` 中没有 `_parsed_fill()` 和跨frame隔离测试。

#### 【修改后】

测试先构造完整 frame10，row0填 `0x11`、row1填 `0x22`。然后只给 frame11 的
row1填 `0x44`，再用 frame12 的FIRST触发关闭frame11。断言：

```python
assert set(switched.rows) == {1}
assert switched.to_bytes(2)[:ROW_BYTES] == bytes(ROW_BYTES)
assert switched.to_bytes(2)[ROW_BYTES:] == bytes([0x44]) * ROW_BYTES
```

这同时验证：

- frame11没有复用frame10的row0；
- 缺失row0写在固定位置并保持全零；
- 有效row1没有append到错误位置。

源码侧证据是 `reassembler.py:319-359`：按 `(cam_id, frame_id)` pop session，
再复制独立rows字典生成 `CompletedFrame`。

#### 【修改理由】

排除“上一frame rows容器被下一frame复用”和“缺行后整体append上移”两个假说。

#### 【边界风险】

测试使用两行小帧，不覆盖真实480行磁盘输出；该部分由
`analyze_camera_archive.py` 对1022张真实输出补充验证。

#### 【验证证据】

测试通过；attempt3 的 zero-fill failures为0，所有输出RAW长度一致。

---

### C.11 RTL/Tcl：仅增加可观察性

#### `Camera_Capture.v`

【文件及职责】Camera异步PCLK/HREF/DATA在100MHz域的同步、边沿检测和byte_count。  
【修改前】`pclk_pulse/href_rise/href_fall` 已存在并参与同一功能逻辑。  
【修改后】第94～100行只添加：

```verilog
(* MARK_DEBUG = "TRUE" *) wire pclk_pulse = ...;
(* MARK_DEBUG = "TRUE" *) wire href_rise = ...;
(* MARK_DEBUG = "TRUE" *) wire href_fall = ...;
```

【修改理由】防止这些内部net被综合优化掉，允许ILA同时看到同步后PCLK脉冲和
HREF边沿。  
【边界风险】`MARK_DEBUG` 会保留网络并可能改变布局布线/资源及时序，但不会改变
布尔表达式、状态转移、byte_count阈值或数据路径语义；不能主动修复漏采/重采。  
【验证证据】Git diff只有3条属性，没有功能表达式变化。

#### `scripts/build_ethernet_ila.tcl`

【文件及职责】从综合设计创建并连接Ethernet/Camera ILA。  
【修改前】probe0～46已覆盖packet/frame、FIFO、raw Camera输入及同步寄存器。  
【修改后】第130～135行增加probe47～49：

```tcl
pclk_pulse
href_rise
href_fall
```

【修改理由】在同一100MHz ILA时间轴上对照raw PCLK/HREF、同步结果、byte_valid、
byte_count和length_error。  
【边界风险】必须重新实现并生成匹配的bit/ltx；旧DCP里未保留的net不能靠修改
ltx凭空出现。  
【验证证据】旧routed DCP检查到 `pclk_pulse COUNT=0`，说明需要MARK_DEBUG后
重建；这不是功能修复证据。

#### `scripts/inspect_camera_capture_debug_nets.tcl`

【文件及职责】只读打开routed DCP并列出匹配的内部net。  
【修改前】检查pclk_hist/level/sync、href_sync和data_sync。  
【修改后】第13～15行加入pclk_pulse/href_rise/href_fall查询。  
【修改理由】在连接ILA前验证层次名和net是否真实存在，避免猜端口名。  
【边界风险】它只检查netlist对象，不采波形、不判断硬件对错。  
【验证证据】Vivado 2025.2.1已成功读取现有routed DCP并输出对象数量。

---

### C.12 十项边界审计结果

| 审计项 | 结论 | 源码证据 |
|---|---|---|
| 1. output worker异常能否被主线程感知 | 部分能：stderr和failure计数；不会传播为非零退出码 | `async_sink.py:89-101` |
| 2. 退出时是否停接收、drain、flush、join | 正常路径是；先packet queue，后frame queue，再关闭CSV | `pipeline.py:101-117`、`cli.py:300-322` |
| 3. frame queue满是否回传背压 | 会；`queue.put()`为阻塞式 | `async_sink.py:59-67` |
| 4. frame入队后是否仍被reassembler修改 | 当前不会；session先pop，rows/records/errors浅复制 | `reassembler.py:319-359` |
| 5. 是否需要额外bytes快照 | 当前row payload为不可变bytes，session已脱离；无需再次复制像素，但对象可变性依赖约定 | `reassembler.py:211-257,343-359` |
| 6. 多camera顺序和命名 | 单worker保持全局提交顺序；`cam_<id>/frame_<id>`隔离命名 | `storage.py:55-63` |
| 7. summary持久句柄是否单一使用 | 正常路径单output worker；另有进程内lock保护 | `storage.py:49-53,169-211` |
| 8. CSV header是否重复 | 空文件写一次；非空先校验header，不重复写 | `storage.py:185-211` |
| 9. writer失败是否误增success | image RAW/PGM success只在无异常else分支增加；async processed同理 | `image_pipeline.py:374-409`、`async_sink.py:96-101` |
| 10. frame queue depth边界 | 小：快速背压；大：内存/退出延迟增大并延迟暴露持续慢盘 | `async_sink.py:32-56`、`run_receiver.ps1:12` |

补充：若 StorageAndPipeline 的frame目录发布成功但summary追加失败，output callback
会计为failure，但目录已存在，summary可能缺记录；当前没有事务回滚或自动补写。

---

## D. 两类队列对比

| 项目 | Capture packet queue | Frame output queue |
|---|---|---|
| 类型 | `queue.Queue[RawEthernetFrame]` | `queue.Queue[CompletedFrame/object]` |
| 生产者 | Scapy/Npcap callback | `taxi-worker`中的ReassemblyStage |
| 消费者 | `taxi-worker` | `taxi-frame-output` worker |
| 数据单位 | 一个Ethernet packet/Camera row包 | 一个已关闭图像session |
| 默认/脚本深度 | Python默认8192；脚本传65536 | 默认/脚本256 |
| live满队列行为 | `put_nowait`失败，主动drop并计数 | 阻塞`submit()`，不静默drop完整图像 |
| offline满队列行为 | 带timeout重试，保留证据 | 同样阻塞 |
| 相关peak | `capture_queue_peak/capacity` | `FRAME OUTPUT QUEUE queue peak/capacity` |
| 相关失败 | `Capture queue drops` | `callback failures` |
| 满队列后果 | packet在Layer2前丢失，形成row_seq gap | 背压taxi-worker；持续过久会间接推高capture queue |
| 内存主要内容 | RawEthernetFrame、128-byte payload、可选完整L2 bytes | rows、packet records、errors、frame元数据 |

这两个队列不能用同一个“queue drops”概念解释：capture queue选择丢packet；
frame output queue选择等待空位。

---

## E. 性能因果链与旧报告守恒

### E.1 因果链

```text
同步完整帧写盘
  + summary_v2.csv 每帧读取/重写全部历史 O(n²)
  + 可选的第二份完整Ethernet frame复制
                         |
                         v
taxi-worker平均服务时间增加
                         |
                         v
consumer rate < capture callback producer rate
                         |
                         v
capture packet queue积压并达到capacity
                         |
                         v
put_nowait -> queue.Full -> 主动drop packet
                         |
                         v
row_seq出现gap / frame缺行 / FIRST或LAST可能丢失
                         |
                         v
COMPLETE减少、REJECTED增加、usable fps下降
```

### E.2 守恒关系

旧120.905秒报告：

```text
Capture ingress       = 877432
Matching Ethernet     = 795297
Capture queue drops   = 82135
length errors         = 2729
sequence gaps         = 84864
```

第一条关系：

```text
877432 - 795297 = 82135
```

`Capture ingress`在 `_on_frame()` 入队前计数；`Matching Ethernet`在 consumer
完成Layer2 validation后计数。报告中Bad Ethernet length、Parser errors和
Processing errors都是0，因此二者差值精确等于 `queue.Full` 分支计数，直接把
82135定位为Python应用层capture queue主动drop，而不是EtherType过滤。

第二条关系：

```text
82135 + 2729 = 84864
```

`StreamMonitor.record_camera_result()` 只有 `result.ok` 才调用
`_update_sequence()`。因此：

- 82135个未进入consumer的packet表现为row_seq缺口；
- 2729个已收到但被LENGTH_ERROR严格拒绝的packet也不会推进last_sequence，
  下一有效包到来时同样表现为缺口。

两者完全解释84864，且CRC errors、Bad Ethernet length、Parser errors均为0。
所以本轮优化优先解决consumer吞吐和length error两个独立来源，不支持优先把
问题归因于“已收到的RMII帧随机CRC损坏”。

本轮性能修改能够改善：

- 同步完整图像磁盘I/O阻塞packet consumer；
- capture queue积压；
- 未录制PCAP时不必要的完整L2 frame复制；
- `summary_v2.csv`随frame数增长越来越慢；
- 缺乏queue深度、生产/消费速率观测。

本轮性能修改不能直接修复：

- FPGA实际漏采或重复HREF/PCLK；
- Camera_Capture产生127/129/130-byte行；
- 在进入MAC前已经发生的Camera row丢失；
- Taxi/MII/RMII/PHY/NIC物理链路丢帧；
- RP2350A连接FPGA后出现电平、共地、串扰、双驱动或供电畸变；
- 磁盘长期吞吐低于完整图像产生吞吐。

---

## F. 当前尚未解决的问题

### F.1 Python侧

1. **真实120秒结果尚未回归。** Synthetic测试证明机制，不等于达到
   `<0.1%` live capture drop验收。
2. **逐包CSV仍在packet consumer。** `session_audit_v2.csv`和`rows_v2.csv`采用
   256行/0.5秒等批量flush，但逐包字段构造和`writerow`仍消耗taxi-worker CPU。
   只有新一轮producer/consumer/peak数据才能判断它是否成为下一瓶颈。
3. **output callback failure不改变退出码。** 自动化环境必须检查最终
   `callback failures`，不能只看进程是否正常退出。
4. **frame output queue可以重新传播背压。** 若其peak持续贴近capacity而不是
   短时上升后回落，说明磁盘长期跟不上，扩大队列只能延后故障。
5. **summary append的崩溃一致性弱于旧版replace。** 复杂度从O(n²)降到近O(1)
   的代价是尾行不具备单记录原子性。
6. **没有跨进程OutputRoot锁。** 不能让两个receiver进程同时写同一目录。

### F.2 FPGA Camera输入侧

现有ILA已在 `Camera_Capture` 的 `href_fall/line_end` 判定点抓到129和130字节
行，说明至少一部分length error在Line_Buffer之前已经形成。新增MARK_DEBUG/ILA
只能区分：

```text
物理raw HREF/PCLK
 -> href_sync/pclk_sync
 -> href_rise/fall、pclk_pulse
 -> byte_valid/byte_count
 -> length_error
```

它不会主动改变采样结果。RP2350A输出端和FPGA接收端仍需同步测量，才能区分源端
少发/多发、电气畸变和FPGA CDC边沿误判。

### F.3 Taxi/MII/RMII/物理层

旧报告CRC、Ethernet固定长度、parser均为0，且sequence gap已由queue drop和
length error守恒解释，当前没有额外未解释gap指向MAC/RMII。但这不替代以下
硬件证据：

- MAC前row_seq连续性；
- `frame_valid/ready/last`；
- `tx_fifo_overflow/tx_error_underflow`；
- RMII TXEN/TXD；
- 独立dumpcap/NIC kernel drop统计。

---

## G. 下一次120秒测试应比较的指标

必须使用同一bit/ltx、相同Camera配置、相同网卡和相同输出介质，并记录修改前与
修改后两组完整报告。

| 指标 | 单位/来源 | 修复后判断 |
|---|---|---|
| `capture_queue_drops` | packets；capture queue Full次数 | 接近0，至少低于ingress的0.1% |
| `capture_queue_peak/capacity` | packets | peak不应长期贴住capacity；偶发高峰可接受 |
| `producer_rate` | Python capture ingress packets/s | 与同场景源输入一致 |
| `consumer_rate` | Layer2 matching packets/s | 应接近producer rate；差值不应持续累积 |
| `frame_output_queue_peak/capacity` | completed frames | 应有余量且运行后不单调逼近capacity |
| `output_worker_failures` | completed-frame callback次数 | 必须为0 |
| `length_errors` | packets | Python优化不应伪造下降；仍由FPGA/物理侧独立处理 |
| `sequence_gaps` | missing row_seq数量 | queue drop归零后应接近可解释的length errors |
| `complete_fps` | images/s | 与修改前同口径比较 |
| `recovered_fps` | images/s | 与修改前同口径比较 |
| `total_usable_fps` | `(complete+recovered)/elapsed` | 源约15fps时应尽量接近15fps |

推荐联合判断：

```text
producer_rate <= consumer_rate（或两者在测量误差内接近）
AND capture_queue_drops / ingress < 0.1%
AND capture_queue_peak 明显低于 capacity
AND frame_output_queue_peak 不持续贴顶
AND output_worker_failures == 0
```

满足这些条件，才可以说主要瓶颈已经从Python接收端移除。如果capture queue健康，
但frame output queue持续贴顶，则瓶颈转移到了磁盘输出；如果两个queue都健康而
length errors不下降，则应继续按Camera HREF/PCLK/CDC的ILA证据链排查，而不是
扩大RECOVERED阈值。
