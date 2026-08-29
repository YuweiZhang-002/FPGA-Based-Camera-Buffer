# Vivado Tcl、ILA 抓取与 bitstream 自动化

## 1. 为什么 GitHub 页面看起来像“没有上传 Tcl”

这不是 `.gitignore` 把全部 Tcl 排除掉造成的。当前 `main` 实际跟踪了 26 个
`.tcl` 文件，第一方构建、编程和 ILA 抓取入口位于 [`scripts/`](../scripts/)。
过去的问题是 README 只在正文里提到“Vivado Tcl”，没有给出入口表、完整调用
顺序和 PowerShell 驱动，所以从单个 testbench 页面进入仓库时很难发现它们。

另一个容易混淆的事实是：本地历史分支曾包含 113 个额外 Tcl，但它们全部位于
`prg_cam.srcs/sources_1/lib/taxi-master/`，属于第三方 TAXI 源码。公开仓库按
[`THIRD_PARTY_DEPENDENCIES.md`](../THIRD_PARTY_DEPENDENCIES.md) 的边界不内嵌
第三方代码，实验者必须自行获取并放入脚本要求的固定相对路径。因此，“第三方
Tcl 未上传”是发布策略，“第一方 Tcl 难以发现”才是文档缺口。

## 2. 第一方脚本与调用拓扑

| 阶段 | Tcl 入口 | 作用 | 成功标记/产物 |
|---|---|---|---|
| ILA 构建 | `scripts/build_ethernet_ila.tcl` | 综合、实现、布线并插入 4096 深度 ILA | `ILA_BUILD_RESULT=PASS`、`.bit`、`.ltx`、DCP、reports |
| 编程 | `scripts/program_ethernet_ila.tcl` | 将配对的 bit/LTX 写入 `xc7a50t_0` | `HW_ILA_PROGRAM_RESULT=PASS` |
| 有界观察 | `scripts/observe_ethernet_ila_trigger.tcl` | 在指定毫秒窗口内观察 trigger；不会无限等待 | `ILA_OBSERVE_RESULT=...` |
| CSV 抓取 | `scripts/capture_ethernet_ila.tcl` | 等待一次 trigger 并导出 4096 samples | `ILA_CAPTURE_RESULT=PASS`、CSV |
| 丢包诊断 | `scripts/diagnose_fpga_host_drops_60s.tcl` | 抓取开始/结束快照并观察 FIFO almost-full | `DROP_DIAG_RESULT=PASS`、CSV |
| plain bit | `scripts/rebuild_gui_ethernet.tcl` | 不以 ILA 调试为目标的常规工程重建 | `GUI_REBUILD_RESULT=PASS`、bit/DCP/reports |

统一 PowerShell 入口是：

```text
scripts_ps/run_ethernet_ila.ps1
    -> PRECHECK / DRY-RUN
    -> 选择一个 Tcl 入口
    -> Vivado batch
    -> 检查成功标记和输出文件
    -> build/ila_runs/<timestamp>_<action>/run_manifest.json
```

当前 `build_ethernet_ila.tcl` 的 A3 布局重点观察 CAM1，并不是 CAM0/CAM1
完全对称的 probe 集。可用的一位触发包括 `camera_packet_valid`、
`camera1_crc_error_pulse_dbg`、`camera_packet_fifo_almost_full`、
`frame_handshake`、`tx_error_underflow` 和 `tx_fifo_overflow`。不得凭名字猜测
其他 probe；应以本次 bit 配对的 LTX 和编程日志列出的 `HW_PROBE` 为准。

## 3. PowerShell 前置变量与第三方依赖

在普通 PowerShell 或 VS Code 集成 PowerShell 终端中执行均可。必须从仓库根
目录开始，并将 Vivado 路径改为本机实际安装位置：

```powershell
$repo = 'D:\prg\prg_cam'
$vivado = 'D:\Xilinx_Vivado\2025.2.1\Vivado\bin\vivado.bat' # <- 本机路径
$driver = Join-Path $repo 'scripts_ps\run_ethernet_ila.ps1'

Set-Location $repo

if (!(Test-Path -LiteralPath $vivado -PathType Leaf)) {
    throw "Vivado 不存在：$vivado"
}
if (!(Test-Path -LiteralPath $driver -PathType Leaf)) {
    throw "自动化入口不存在：$driver"
}
```

构建前还必须按 `THIRD_PARTY_DEPENDENCIES.md` 准备 TAXI 与 RMII 源码。驱动器
会检查关键文件；缺失时退出码为 `1`，不会启动 Vivado，也不会把“环境不完整”
误报成 RTL 综合失败。

## 4. 生成带 ILA 的 bit 和 LTX

先 dry-run，只显示将使用的工程、Vivado、Tcl 和输出位置：

```powershell
& $driver `
  -Action Build `
  -VivadoBin $vivado `
  -PreflightOnly

if ($LASTEXITCODE -ne 0) {
    throw "ILA build preflight 失败：$LASTEXITCODE"
}
```

预检通过后执行完整 synthesis -> implementation -> bitstream -> probes/reports：

```powershell
& $driver `
  -Action Build `
  -VivadoBin $vivado

if ($LASTEXITCODE -ne 0) {
    throw "ILA build 失败：$LASTEXITCODE"
}
```

固定构建产物位于 `build/ethernet_ila/`：

- `Camera_Ethernet_Top_ila.bit`
- `Camera_Ethernet_Top_ila.ltx`
- `Camera_Ethernet_Top_ila_routed.dcp`
- `timing_summary.rpt`、`drc.rpt`、`utilization.rpt`

每次调用的日志、SHA-256 和 Git HEAD 另存到新的
`build/ila_runs/<timestamp>_build/run_manifest.json`。Tcl 的历史固定产物路径仍会
更新，因此正式实验前应把 manifest 视为本次 bit/LTX 身份的证据。

## 5. 编程 FPGA

连接 JTAG、上电并关闭占用硬件服务器的其他 Vivado 会话，然后执行：

```powershell
& $driver `
  -Action Program `
  -VivadoBin $vivado

if ($LASTEXITCODE -ne 0) {
    throw "FPGA ILA 编程失败：$LASTEXITCODE"
}
```

PASS 要求同时满足：Vivado 退出码为 0、日志含
`HW_ILA_PROGRAM_RESULT=PASS`，且列出一个 hardware ILA 和它的 probes。
bit 与 LTX 必须来自同一次构建；旧 LTX 配新 bit 会导致 probe 名错误、数据错位
或 `get_hw_probes` 找不到对象。plain bit 可能根本没有 ILA，不能配用 ILA LTX。

## 6. 先观察，再抓 CSV

`Capture` 内部使用 `wait_on_hw_ila`，在 trigger 永远不出现时会持续等待。因此先
用 10 秒有界观察验证当前链路是否能产生 packet activity：

```powershell
& $driver `
  -Action Observe `
  -VivadoBin $vivado `
  -TriggerName 'camera_packet_valid' `
  -ObserveMs 10000

if ($LASTEXITCODE -ne 0) {
    throw "ILA 有界观察失败：$LASTEXITCODE"
}
```

`TRIGGERED_OR_STOPPED` 表示观察窗口内发生过触发；
`NO_TRIGGER_IN_WINDOW` 不是 Tcl 崩溃，而是该 probe 在窗口内没有变为 1。后者应
先检查相机输入、packet FIFO 和当前 bit/LTX 身份，不要直接启动无限等待抓取。

活动触发已经出现后，导出完整 CSV：

```powershell
& $driver `
  -Action Capture `
  -VivadoBin $vivado `
  -TriggerName 'camera_packet_valid' `
  -TriggerPosition 512

if ($LASTEXITCODE -ne 0) {
    throw "ILA CSV 抓取失败：$LASTEXITCODE"
}
```

CSV 写入本次唯一 run 目录的 `ila_capture.csv`。`TriggerPosition` 的范围是
0..4095；数值越大，保留的触发前历史越多。

## 7. CRC、backpressure 与 TX 故障触发

CRC 是 FPGA 链路诊断，不应用来替代内/外参图像质量判断。当前 A3 ILA 只暴露
CAM1 CRC error pulse。先有界观察，再抓取；下面的 3072 为慢事件保留较长的
触发前历史：

```powershell
& $driver `
  -Action Observe `
  -VivadoBin $vivado `
  -TriggerName 'camera1_crc_error_pulse_dbg' `
  -ObserveMs 10000

& $driver `
  -Action Capture `
  -VivadoBin $vivado `
  -TriggerName 'camera1_crc_error_pulse_dbg' `
  -TriggerPosition 3072
```

检查 FIFO backpressure：

```powershell
& $driver `
  -Action Observe `
  -VivadoBin $vivado `
  -TriggerName 'camera_packet_fifo_almost_full' `
  -ObserveMs 60000
```

执行开始/结束快照和 almost-full 观察：

```powershell
& $driver `
  -Action DiagnoseDrops `
  -VivadoBin $vivado `
  -DiagnoseSeconds 60

if ($LASTEXITCODE -ne 0) {
    throw "FPGA 丢包诊断失败：$LASTEXITCODE"
}
```

当前诊断使用 `camera_packet_valid` 获取快照，所以必须有实时相机 packet 流量；
静止场景可以，完全无包不可以。A3 只记录 `camera_drop_count_1`，不能据此宣称
CAM0 drop 已被同等观测。

## 8. 生成 plain bit

如需不依赖 ILA 抓取的常规工程 bitstream，运行：

```powershell
& $driver `
  -Action PlainBit `
  -VivadoBin $vivado `
  -PreflightOnly

if ($LASTEXITCODE -ne 0) {
    throw "plain bit preflight 失败：$LASTEXITCODE"
}

& $driver `
  -Action PlainBit `
  -VivadoBin $vivado

if ($LASTEXITCODE -ne 0) {
    throw "plain bit 生成失败：$LASTEXITCODE"
}
```

该流程调用 `rebuild_gui_ethernet.tcl`，输出 GUI project implementation 的 bit，
以及 timing、reset exception coverage、CDC、DRC、utilization 报告。plain bit 与
ILA bit 是两个不同实验身份，发布、编程和归档时必须明确标注，禁止混用 LTX。

## 9. PASS/FAIL 与常见故障

| Observed | Expected | 解释与下一步 |
|---|---|---|
| `PRECHECK failed` 且列出 TAXI/RMII 文件 | 两个关键依赖文件均存在 | 按第三方依赖文档放到精确路径；不是 RTL 失败 |
| `Run directory is not empty` | 每次生成唯一 run 目录 | 换一个新的 `-RunRoot`；不要覆盖历史证据 |
| 找不到 `xc7a50t_0` | 恰好一个器件 | 检查 JTAG、电源、Hardware Server 和器件名 |
| 找不到 trigger probe | LTX 中恰好一个同名一位 probe | 核对本次 bit/LTX 配对和编程日志中的 `HW_PROBE` |
| `NO_TRIGGER_IN_WINDOW` | 活跃链路触发 `camera_packet_valid` | 从相机输入到 packet FIFO 逐层找第一个无活动节点 |
| Capture 长时间等待 | trigger 最终出现 | `Ctrl+C` 停止；改用 Observe 验证触发后再 Capture |
| Tcl 显示 PASS，但主机无包 | Host 也有 matching/parsed/complete 计数 | FPGA PASS 不能跨层提升为 Host PASS，继续查 RMII/PHY/NIC/Npcap |

退出码由 PowerShell 驱动统一解释：`0` 为完成且输出验证通过，`1` 为环境或
precheck 失败，`2` 为输入/目录无效，`4` 为执行后产物验证失败，`5` 为脚本内部
错误。Vivado 自身非零退出码会保留在 manifest 中；最终判断必须同时查看日志、
成功标记、产物和 `run_manifest.json`，不能只看终端最后一行。
