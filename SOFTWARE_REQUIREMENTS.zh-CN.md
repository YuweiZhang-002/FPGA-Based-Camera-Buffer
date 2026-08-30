# 软件需求与已验证环境

本文件是 MCU → FPGA → Host 公开复刻流程的软件配置总清单。“要求版本”
来自源码或脚本；“观测版本”只说明 2026-08-30 原验证机使用过该版本，不能
擅自解释成理论最低版本。

## 标记定义

| 标记 | 含义 |
|---|---|
| 必需 | 缺少后，对应构建或运行无法执行。 |
| 阶段性 | 只在实时抓包、ILA、标定或 MATLAB 作图等指定阶段需要。 |
| 已观测 | 原验证机实际检测到的版本。 |
| 最低版本未验证 | 仓库证据不足，禁止猜测最早兼容版本。 |

## 原验证机软件快照

| 组件 | 项目要求 | 已观测版本 | 使用范围 |
|---|---|---|---|
| Windows | 实时抓包与 Vivado 的权威流程为 Windows | NT `10.0.26200.0`，64 位进程 | 最低 Windows 版本未验证。 |
| Windows PowerShell | 5.1 或 PowerShell 7 | `5.1.26100.9168` | 当前脚本没有依赖 PowerShell 7 专属语法。 |
| Git | 必需，未声明最低版本 | `2.54.0.windows.1` | 克隆、固定提交、HEAD/dirty 与证据记录。 |
| Xilinx Vivado | 支持 `xc7a50ticsg324-1L`；复刻基线使用 2025.2.1 | `2025.2.1` 64 位 | 综合、实现、Xsim、bitstream、Hardware Manager 与 ILA。 |
| CMake | 工程声明 `3.13...3.27` policy compatibility | `3.31.5` | MCU 配置；未承诺所有更高版本均兼容。 |
| Ninja | 文档化 MCU 命令必需 | `1.12.1` | `-G Ninja` 基线。 |
| Arm GNU toolchain | Pico 兼容，工程请求 `14_2_Rel1` | GCC `14.2.1` | RP2350 编译。 |
| Pico SDK | 外部 `2.2.0` 兼容 SDK | `2.2.0` | 通过 `PICO_SDK_PATH` 引入，不内嵌。 |
| picotool | 编程/检查阶段可选 | `2.2.0-a4` | UF2 拖放不要求 picotool。 |
| Python | 源码语法要求 3.10 或更高 | `3.14.6` 64 位 | Host 接收、测试与标定。 |
| Scapy | 实时抓包需要；当前未固定版本 | `2.7.0` | `requirements-live.txt`。 |
| pytest | 完整测试需要；当前未固定版本 | `9.1.1` | `requirements-live.txt`。 |
| NumPy | `>=1.24` | `2.5.1` | 标定。 |
| OpenCV headless | `>=4.8,<5` | `4.14.0.94`（`cv2 4.14.0`） | 排除已记录的 OpenCV 5.0.0.93 fisheye 多视图回归。 |
| Npcap | 仅 Windows 实时抓包必需 | 安装版本未记录 | 单独安装；可能需要管理员 PowerShell。 |
| Wireshark | 原始 `0x88B5` 故障定位推荐 | 未验证 | 区分 PHY/NIC 可见性与 Python 解析。 |
| MATLAB | `scripts_matlab/*.m` 可选 | 检测到 R2026a Update 4 | 最低版本/工具箱未确认；本轮 batch 启动返回 filesystem inconsistency，不能标为 PASS。 |

## 目录约定

```text
<WORKSPACE>/
├─ MCU/
├─ FPGA/
│  └─ third_party/
│     ├─ taxi/
│     └─ FPGA-RMII-SMII/
└─ Host/
```

不要从原工作站复制 `.venv`、Vivado runs、MCU `build/`、图像、抓包或旧
第三方源码目录。使用 `scripts_ps/initialize_reproduction_workspace.ps1`
重新获取固定提交，并检查 `bootstrap_manifest.json`。

## MCU 软件配置

必需：CMake、Ninja、Arm GNU toolchain、Pico SDK 2.2.0、
`PICO_SDK_PATH`、`PICO_BOARD=pico2`、`PICO_PLATFORM=rp2350`。

```powershell
$mcu = '<WORKSPACE>\MCU'
$cmake = '<CMAKE_EXE>'
$ninja = '<NINJA_EXE>'
$env:PICO_SDK_PATH = '<PICO_SDK_ROOT>'
$env:Path = "$(Split-Path $ninja);$env:Path"

& $cmake --version
& $ninja --version
& '<ARM_NONE_EABI_GCC_EXE>' --version

& $cmake -S $mcu -B (Join-Path $mcu 'build') -G Ninja `
  -DPICO_BOARD=pico2 -DPICO_PLATFORM=rp2350
& $cmake --build (Join-Path $mcu 'build') --config Release
```

Raspberry Pi Pico VS Code 扩展属于可选工具，不能用其本机缓存取代显式的
SDK、toolchain、board 和 platform 记录。

## FPGA/Vivado 软件配置

必需：Vivado/Xsim/Hardware Manager、`xc7a50ticsg324-1L` 器件支持、
TAXI/RMII 固定提交。Program/Observe/Capture 还需要 cable/JTAG driver、
`hw_server` 和连接的 `xc7a50t`。

```powershell
$fpga = '<WORKSPACE>\FPGA'
$vivado = '<VIVADO_INSTALL>\Vivado\bin\vivado.bat'
$runner = Join-Path $fpga 'scripts_ps\run_ethernet_ila.ps1'

& $runner -Action Build -VivadoBin $vivado -PreflightOnly
if ($LASTEXITCODE -ne 0) {
  throw "Vivado preflight failed: $LASTEXITCODE"
}
```

ILA 的 `.bit` 与 `.ltx` 必须来自同一 build。能够下载 bit 但 probe 不匹配
不构成有效 ILA 结果。仓库没有给出 RAM/磁盘最低数值，不得自行发明。

## Host 接收与标定配置

```powershell
$host = '<WORKSPACE>\Host'
$basePython = '<PYTHON_3_10_OR_LATER_EXE>'

& $basePython -m venv (Join-Path $host '.venv')
$python = Join-Path $host '.venv\Scripts\python.exe'

& $python -m pip install --upgrade pip
& $python -m pip install -r (Join-Path $host 'requirements-live.txt')
& $python -m pip install -r (Join-Path $host 'requirements-calibration.txt')
& $python -m pytest -q $host
```

| 操作 | 需要的软件 |
|---|---|
| 标准库离线 PCAP / golden fixture | Python；不需要网卡或 Npcap。 |
| 完整 pytest | pytest；标定测试还需要 NumPy/OpenCV。 |
| 实时抓包 | Python、Scapy、单独安装的 Npcap、匹配网卡、真实 Npcap GUID，通常还要管理员 shell。 |
| PGM/CSV | Python 与可写输出空间。 |
| 内/外参 | Python、NumPy、OpenCV headless、PGM 输入和全新输出目录。 |
| Tk viewer | 带 Tk/Tcl 的 Python；无界面接收/标定不需要。 |

实时采集前必须执行：

```powershell
Set-Location $host
& $python -m taxi_receiver.cli --list
if ($LASTEXITCODE -ne 0) {
  throw "Npcap/interface enumeration failed: $LASTEXITCODE"
}
```

复制实际 `\Device\NPF_{...}`；占位字符串不是配置，通常会触发 Windows
error 123。

## MATLAB 可选配置

本地脚本使用 `readtable`、`imread`、`tiledlayout`、`yyaxis` 和
`exportgraphics`。尚未证明最低 MATLAB release 或必须工具箱。

```powershell
$matlab = '<MATLAB_ROOT>\bin\matlab.exe'
& $matlab -batch "disp(version); ver"
if ($LASTEXITCODE -ne 0) {
  throw "MATLAB preflight failed: $LASTEXITCODE"
}
```

MATLAB 启动失败属于环境失败，不是实验结论；MCU、FPGA、抓包和 OpenCV
标定都不依赖 MATLAB。

## 避免空管道的软件检查

```powershell
$toolChecks = @(
  foreach ($name in 'git', 'powershell') {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    [pscustomobject]@{
      Tool = $name
      Found = $null -ne $command
      Path = if ($command) { $command.Source } else { '' }
    }
  }
)

$toolChecks | Format-Table -AutoSize
if (@($toolChecks | Where-Object { -not $_.Found }).Count -ne 0) {
  throw 'Required base software is missing'
}
```

每次实验还必须把实际版本、三个仓库 commit/dirty、UF2/bit/LTX hash、
Npcap GUID、Python 包版本和输出目录写入 run manifest。“软件已安装”不能
自动推出对应 build、program、capture 或 calibration 已通过。
