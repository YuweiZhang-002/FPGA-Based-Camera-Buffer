# 新 CAM1（120°）内参到双目外参：按阶段独立执行手册

本手册不再提供需要跨窗口继承的公共 PowerShell 变量、公共采集函数或公共会话模块。
每一个阶段的代码块都包含自己的工作目录、绝对数据路径、CameraIds、实时窗口和完整
`run_receiver.ps1` 命令；重新打开 PowerShell 时直接重新执行当前阶段，不必先执行别节。

旧 CAM1 内参和旧 cam0→cam1 外参不得继续使用。约22 mm基线和约3°夹角只用于外参
求解后的合理性检查，不作为求解强制输入。

## 0. 当前状态与执行索引

### 0.1 当前问题的实测结论

2026-08-20检查结果：

- `01_cam1_intrinsic_train\cam1` 已有3482组 PGM/RAW/JSON；
- 后续所谓“holdout”帧仍继续写进训练目录，最新曾到 frame 45313；
- `02_cam1_intrinsic_holdout` 是空目录，没有 `cam1\rows_v2.csv` 或 PGM；
- `01_cam1_solve\cam1_intrinsics_120.json` 已存在，29个最终姿态，训练 RMS约
  0.308 px，单视图最大RMSE约0.518 px，`quality.status=acceptable`。

因此当前故障是旧采集命令仍使用训练阶段 `ImagesRoot`，不是 CAM1 包解析或图像发布失败。
误写到训练目录的后续帧不能移动/复制成 holdout。保留已完成的 solve，从第3节重新采集
真正独立的 holdout。

### 0.2 阶段索引

| 阶段 | 直接执行章节 | CameraIds | 数据绝对路径 | 主要输出 |
|---|---:|---:|---|---|
| CAM1内参训练采集 | 2.1 | `1` | `...run01\01_cam1_intrinsic_train` | PGM/RAW/JSON/rows |
| CAM1内参求解 | 2.2 | `1` | 同上 | `build\...\01_cam1_solve` |
| CAM1独立holdout采集 | **3.1（当前应执行）** | `1` | `...run01\02_cam1_intrinsic_holdout` | 独立PGM/RAW/JSON/rows |
| CAM1固定K/D验证 | 3.2 | `1` | 同上 | `02_cam1_validation` |
| 双目静止性 | 4 | `0,1` | `03_stereo_static` | `stillness_config.json` |
| 外参训练 | 5 | `0,1` | `04_stereo_train` | pairs + extrinsics |
| 外参holdout V1 | 6 | `0,1` | `05_stereo_holdout_v1` | V1 validation |
| 外参holdout V2 | 7 | `0,1` | `06_stereo_holdout_v2` | V2 validation |

所有采集均按 Ctrl+C正常停止并等待 Final Report。正式数据要求 PGM/RAW/JSON数量一致且
非零，并且 `ps_drop`、capture/lane/csv drops、CRC、sync、overflow、publisher failures
全部为0。

## 1. 可选：CAM1线上ID专用探针

### 执行索引

| 项目 | 值 |
|---|---|
| 模块 | `run_receiver.ps1` |
| CameraIds | `0,1`，仅用于确认包头ID |
| 输出 | `build\camera_id_probe_<timestamp>` |
| 是否正式数据 | 否 |

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$interface = '\Device\NPF_{6BDDE37E-7DCA-4078-98B0-E374EFE04E7C}'
$probeRoot = "D:\prg\prg_cam\build\camera_id_probe_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
Set-Location -LiteralPath $receiverRoot

& .\run_receiver.ps1 `
  -Interface $interface -ImagesRoot $probeRoot `
  -ExpectedRows 480 -QueueDepth 8192 -PcapBufferSize 67108864 `
  -FrameOutputQueueDepth 64 -CameraIds '0,1' -SplitByCamera on `
  -ImagePolicy strict -PublishFrames complete -PublishImages thread `
  -PublisherQueueDepth 64 -CsvQueueDepth 8192 -CsvBackpressure block `
  -BitOrder msb_first -SessionAudit off -CrcMode enabled -PythonExe $python
if ($LASTEXITCODE -ne 0) { throw "Camera-ID probe failed: $LASTEXITCODE" }
```

只有 CAM1 的 `PacketRows>0` 且 PGM非零后才进入内参流程。`-CameraIds`只是白名单，
不会把CAM0改名为CAM1。

## 2. CAM1内参训练

### 2.1 CAM1训练采集：完整独立命令

### 执行索引

| 项目 | 值 |
|---|---|
| 接收模块 | `run_receiver.ps1` |
| 实时模块 | `watch_calibration_poses.ps1` |
| CameraIds | `1` |
| 写入路径 | `...run01\01_cam1_intrinsic_train` |
| 目标 | 30–40个监测Pose，至少25个最终Pose |

当前run的训练和solve已经完成，不要再次执行本节。新run需要重训时，先把代码中的
`run01`整体替换为新的run名，然后执行：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$interface = '\Device\NPF_{6BDDE37E-7DCA-4078-98B0-E374EFE04E7C}'
$trainRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\01_cam1_intrinsic_train'
Set-Location -LiteralPath $receiverRoot

$payload = Get-ChildItem -LiteralPath $trainRoot -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -in @('.pgm','.raw','.json') -or $_.Name -eq 'rows_v2.csv' } |
  Select-Object -First 1
if ($null -ne $payload) { throw "Training root is not empty: $trainRoot" }

Start-Process powershell.exe -ArgumentList @(
  '-NoExit','-ExecutionPolicy','Bypass','-File',
  (Join-Path $receiverRoot 'watch_calibration_poses.ps1'),
  '-ImagesRoot',$trainRoot,'-CameraId','1','-MinPoses','30',
  '-WindowLabel','CAM1-intrinsic-training','-PythonExe',$python
)

Write-Host "STAGE=CAM1 intrinsic training"
Write-Host "IMAGES_ROOT=$trainRoot"
Write-Host 'CAMERA_IDS=1'
& .\run_receiver.ps1 `
  -Interface $interface -ImagesRoot $trainRoot `
  -ExpectedRows 480 -QueueDepth 65536 -PcapBufferSize 67108864 `
  -FrameOutputQueueDepth 256 -CameraIds '1' -SplitByCamera on `
  -ImagePolicy strict -PublishFrames complete -PublishImages process `
  -PublisherQueueDepth 256 -CsvQueueDepth 65536 -CsvBackpressure drop `
  -BitOrder msb_first -SessionAudit off -CrcMode enabled -PythonExe $python
if ($LASTEXITCODE -ne 0) { throw "CAM1 training capture failed: $LASTEXITCODE" }

$camRoot = Join-Path $trainRoot 'cam1'
Get-ChildItem -LiteralPath $camRoot -File -ErrorAction SilentlyContinue |
  Group-Object Extension | Select-Object Name,Count | Format-Table -AutoSize
```

失败后重采新run最稳妥。若明确删除本阶段，先预演，核对后再执行第二条：

```powershell
$target = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\01_cam1_intrinsic_train'
Remove-Item -LiteralPath $target -Recurse -Force -WhatIf
```

```powershell
# 不可恢复；仅在WhatIf目标完全正确且solve/下游也准备重做时执行。
$target = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\01_cam1_intrinsic_train'
Remove-Item -LiteralPath $target -Recurse -Force
```

### 2.2 CAM1内参求解：完整独立命令

### 执行索引

| 项目 | 值 |
|---|---|
| 输入 | `01_cam1_intrinsic_train\cam1` |
| 模块 | `calibrate_binary_camera_refill.py` |
| CameraId | `1` |
| 输出 | `build\...\01_cam1_solve\cam1_intrinsics_120.json` |

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$trainCam = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\01_cam1_intrinsic_train\cam1'
$solveRoot = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\01_cam1_solve'
$intrinsic = Join-Path $solveRoot 'cam1_intrinsics_120.json'
Set-Location -LiteralPath $receiverRoot

if (Test-Path -LiteralPath $solveRoot) {
  $existing = Get-ChildItem -LiteralPath $solveRoot -Recurse -Force | Select-Object -First 1
  if ($null -ne $existing) { throw "Solve output is not empty: $solveRoot" }
}
New-Item -ItemType Directory -Force -Path $solveRoot | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

& $python .\calibrate_binary_camera_refill.py $trainCam `
  --output $intrinsic `
  --report (Join-Path $solveRoot 'accepted_views.csv') `
  --attempt-report (Join-Path $solveRoot 'replacement_attempts.csv') `
  --cluster-report (Join-Path $solveRoot 'pose_clusters.csv') `
  --selected-dir (Join-Path $solveRoot "selected_$stamp") `
  --diagnostics-dir (Join-Path $solveRoot "diagnostics_$stamp") `
  --camera-id 1 --width 640 --height 480 `
  --pattern asymmetric --columns 4 --rows 11 `
  --spacing-mm 20 --dot-diameter-mm 10 `
  --model fisheye --fov-deg 120 `
  --min-views 20 --min-final-poses 25 --max-view-rmse-px 1.5
if ($LASTEXITCODE -ne 0) { throw "CAM1 intrinsic solve failed: $LASTEXITCODE" }
```

不得使用 `--allow-limited`。当前run01已有通过结果，不要覆盖。

## 3. CAM1独立内参holdout（当前从这里继续）

### 3.1 Holdout采集：完整独立命令

### 执行索引

| 项目 | 值 |
|---|---|
| 接收模块 | `run_receiver.ps1` |
| 实时模块 | `watch_calibration_poses.ps1` |
| CameraIds | `1` |
| 写入路径 | `...run01\02_cam1_intrinsic_holdout` |
| 目标 | 15–20个全新Pose |

这是当前应该执行的命令。它不读取训练阶段变量，也不会写入训练目录：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$interface = '\Device\NPF_{6BDDE37E-7DCA-4078-98B0-E374EFE04E7C}'
$holdoutRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\02_cam1_intrinsic_holdout'
Set-Location -LiteralPath $receiverRoot

$payload = Get-ChildItem -LiteralPath $holdoutRoot -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -in @('.pgm','.raw','.json') -or $_.Name -eq 'rows_v2.csv' } |
  Select-Object -First 1
if ($null -ne $payload) { throw "Holdout root is not empty: $holdoutRoot" }
New-Item -ItemType Directory -Force -Path $holdoutRoot | Out-Null

Start-Process powershell.exe -ArgumentList @(
  '-NoExit','-ExecutionPolicy','Bypass','-File',
  (Join-Path $receiverRoot 'watch_calibration_poses.ps1'),
  '-ImagesRoot',$holdoutRoot,'-CameraId','1','-MinPoses','15',
  '-WindowLabel','CAM1-intrinsic-holdout','-PythonExe',$python
)

Write-Host 'STAGE=CAM1 intrinsic holdout'
Write-Host "IMAGES_ROOT=$holdoutRoot"
Write-Host 'CAMERA_IDS=1'
& .\run_receiver.ps1 `
  -Interface $interface -ImagesRoot $holdoutRoot `
  -ExpectedRows 480 -QueueDepth 65536 -PcapBufferSize 67108864 `
  -FrameOutputQueueDepth 256 -CameraIds '1' -SplitByCamera on `
  -ImagePolicy strict -PublishFrames complete -PublishImages process `
  -PublisherQueueDepth 256 -CsvQueueDepth 65536 -CsvBackpressure drop `
  -BitOrder msb_first -SessionAudit off -CrcMode enabled -PythonExe $python
if ($LASTEXITCODE -ne 0) { throw "CAM1 holdout capture failed: $LASTEXITCODE" }

$camRoot = Join-Path $holdoutRoot 'cam1'
$pgm = @(Get-ChildItem -LiteralPath $camRoot -Filter '*.pgm' -File -ErrorAction SilentlyContinue).Count
$raw = @(Get-ChildItem -LiteralPath $camRoot -Filter '*.raw' -File -ErrorAction SilentlyContinue).Count
$json = @(Get-ChildItem -LiteralPath $camRoot -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
$rows = Test-Path -LiteralPath (Join-Path $camRoot 'rows_v2.csv')
[pscustomobject]@{Root=$holdoutRoot;CameraId=1;Pgm=$pgm;Raw=$raw;Json=$json;RowsCsv=$rows} |
  Format-List
if ($pgm -eq 0 -or $pgm -ne $raw -or $pgm -ne $json -or -not $rows) {
  throw 'Holdout publication is incomplete; do not run validation.'
}
```

如果输出的 `IMAGES_ROOT` 不是 `02_cam1_intrinsic_holdout`，立即 Ctrl+C。停止接收器后，
也在实时窗口按 Ctrl+C生成 `cam1_preflight.csv` 和 montage。

本阶段失败重采：

```powershell
$target = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\02_cam1_intrinsic_holdout'
Remove-Item -LiteralPath $target -Recurse -Force -WhatIf
```

```powershell
# 只在WhatIf确认后执行；不会删除已通过的01_cam1_solve。
$target = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\02_cam1_intrinsic_holdout'
Remove-Item -LiteralPath $target -Recurse -Force
```

### 3.2 固定K/D验证：完整独立命令

### 执行索引

| 项目 | 值 |
|---|---|
| 固定内参 | `build\...\01_cam1_solve\cam1_intrinsics_120.json` |
| 独立图像 | `02_cam1_intrinsic_holdout\cam1` |
| 模块 | `validate_binary_calibration.py` |
| 输出 | `build\...\02_cam1_validation` |

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$intrinsic = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\01_cam1_solve\cam1_intrinsics_120.json'
$holdoutCam = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\02_cam1_intrinsic_holdout\cam1'
$validationRoot = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\02_cam1_validation'
Set-Location -LiteralPath $receiverRoot

if (-not (Test-Path -LiteralPath $intrinsic)) { throw "Missing intrinsic: $intrinsic" }
if (@(Get-ChildItem -LiteralPath $holdoutCam -Filter '*.pgm' -File -ErrorAction SilentlyContinue).Count -lt 15) {
  throw "Fewer than 15 holdout PGM files: $holdoutCam"
}
if (Test-Path -LiteralPath $validationRoot) {
  $existing = Get-ChildItem -LiteralPath $validationRoot -Force -Recurse | Select-Object -First 1
  if ($null -ne $existing) { throw "Validation output is not empty: $validationRoot" }
}

& $python .\validate_binary_calibration.py $intrinsic $holdoutCam `
  --output-root $validationRoot --sample-count 30 --min-holdout-views 15 `
  --median-rmse-px 0.8 --p95-rmse-px 1.2 --maximum-rmse-px 1.5 `
  --required-pass-fraction 0.90
if ($LASTEXITCODE -ne 0) { throw "CAM1 holdout validation failed: $LASTEXITCODE" }
```

只有 `holdout_summary.json` 的 `status=pass` 才能进入双目阶段。若采集完整性失败，删除并
重采holdout；若质量合格holdout上的几何指标失败，应返回训练阶段，不能反复挑holdout。

### 3.3 发布新CAM1内参：完整独立命令

```powershell
$intrinsic = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\01_cam1_solve\cam1_intrinsics_120.json'
$summaryPath = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\02_cam1_validation\holdout_summary.json'
$releaseRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver\calibration_configs\cam1_replacement_20260820_run01'
$releaseIntrinsic = Join-Path $releaseRoot 'cam1_intrinsics_120.json'

$summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
$sourceHash = (Get-FileHash -LiteralPath $intrinsic -Algorithm SHA256).Hash
if ($summary.status -ne 'pass' -or
    $summary.calibration.camera_id -ne 1 -or
    $summary.calibration.sha256.ToUpperInvariant() -ne $sourceHash) {
  throw 'Holdout evidence does not match the solved CAM1 intrinsic.'
}
if (Test-Path -LiteralPath $releaseRoot) {
  $existing = Get-ChildItem -LiteralPath $releaseRoot -Force | Select-Object -First 1
  if ($null -ne $existing) { throw "Release root is not empty: $releaseRoot" }
}
New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null
Copy-Item -LiteralPath $intrinsic -Destination $releaseIntrinsic
Copy-Item -LiteralPath $summaryPath `
  -Destination (Join-Path $releaseRoot 'intrinsic_holdout_summary.json')
Get-FileHash -LiteralPath $releaseIntrinsic -Algorithm SHA256
```

## 4. 双目静止性采集与阈值

### 执行索引

| 项目 | 值 |
|---|---|
| CameraIds | `0,1` |
| 数据路径 | `...run01\03_stereo_static` |
| 实时窗口 | cam0和cam1各一个，Pose保持1正常 |
| 输出 | `build\...\03_stereo_static\stillness_config.json` |

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$interface = '\Device\NPF_{6BDDE37E-7DCA-4078-98B0-E374EFE04E7C}'
$staticRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\03_stereo_static'
Set-Location -LiteralPath $receiverRoot

$payload = Get-ChildItem -LiteralPath $staticRoot -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -in @('.pgm','.raw','.json') -or $_.Name -eq 'rows_v2.csv' } |
  Select-Object -First 1
if ($null -ne $payload) { throw "Static root is not empty: $staticRoot" }

foreach ($cam in 0,1) {
  Start-Process powershell.exe -ArgumentList @(
    '-NoExit','-ExecutionPolicy','Bypass','-File',(Join-Path $receiverRoot 'watch_calibration_poses.ps1'),
    '-ImagesRoot',$staticRoot,'-CameraId',"$cam",'-MinPoses','1',
    '-WindowLabel','Stereo-stillness','-PythonExe',$python
  )
}
Write-Host "IMAGES_ROOT=$staticRoot"; Write-Host 'CAMERA_IDS=0,1'
& .\run_receiver.ps1 `
  -Interface $interface -ImagesRoot $staticRoot `
  -ExpectedRows 480 -QueueDepth 65536 -PcapBufferSize 67108864 `
  -FrameOutputQueueDepth 256 -CameraIds '0,1' -SplitByCamera on `
  -ImagePolicy strict -PublishFrames complete -PublishImages process `
  -PublisherQueueDepth 256 -CsvQueueDepth 65536 -CsvBackpressure drop `
  -BitOrder msb_first -SessionAudit off -CrcMode enabled -PythonExe $python
if ($LASTEXITCODE -ne 0) { throw "Static capture failed: $LASTEXITCODE" }
```

固定机架和标定板，两个窗口都达到至少200个有效帧后停止。然后独立执行：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$staticRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\03_stereo_static'
$staticAudit = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\03_stereo_static'
$cam0Intrinsic = Join-Path $receiverRoot 'calibration_configs\cam0_replacement_20260820_run01\cam0_intrinsics_120.json'
$cam1Intrinsic = Join-Path $receiverRoot 'calibration_configs\cam1_replacement_20260820_run01\cam1_intrinsics_120.json'
Set-Location -LiteralPath $receiverRoot
& $python .\build_stereo_pairs.py $staticRoot `
  --cam0-intrinsics $cam0Intrinsic --cam1-intrinsics $cam1Intrinsic `
  --output-root $staticAudit --estimate-stillness-only `
  --window-frames 5 --min-static-frames 200
if ($LASTEXITCODE -ne 0) { throw "Stillness estimation failed: $LASTEXITCODE" }
```

失败重采仅删除 `03_stereo_static` 图像目录和对应build审计目录，先用 `-WhatIf`。

```powershell
$targets = @(
  'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\03_stereo_static',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\03_stereo_static'
)
$targets | ForEach-Object { Remove-Item -LiteralPath $_ -Recurse -Force -WhatIf }
```

```powershell
# 仅在WhatIf确认后执行；如果已有下游外参结果，也必须一并作废。
$targets = @(
  'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\03_stereo_static',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\03_stereo_static'
)
$targets | Where-Object { Test-Path -LiteralPath $_ } |
  ForEach-Object { Remove-Item -LiteralPath $_ -Recurse -Force }
```

## 5. 外参训练、配对和求解

### 执行索引

| 项目 | 值 |
|---|---|
| CameraIds | `0,1` |
| 数据路径 | `...run01\04_stereo_train` |
| 实时窗口 | cam0/cam1各一个，目标25–35 Pose |
| 配对输出 | `04_stereo_train_pairs` |
| 外参输出 | `05_stereo_solve\cam0_to_new_cam1_extrinsics.json` |

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$interface = '\Device\NPF_{6BDDE37E-7DCA-4078-98B0-E374EFE04E7C}'
$trainRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\04_stereo_train'
Set-Location -LiteralPath $receiverRoot
$payload = Get-ChildItem -LiteralPath $trainRoot -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -in @('.pgm','.raw','.json') -or $_.Name -eq 'rows_v2.csv' } |
  Select-Object -First 1
if ($null -ne $payload) { throw "Stereo training root is not empty: $trainRoot" }
foreach ($cam in 0,1) {
  Start-Process powershell.exe -ArgumentList @(
    '-NoExit','-ExecutionPolicy','Bypass','-File',(Join-Path $receiverRoot 'watch_calibration_poses.ps1'),
    '-ImagesRoot',$trainRoot,'-CameraId',"$cam",'-MinPoses','25',
    '-WindowLabel','Stereo-extrinsic-training','-PythonExe',$python
  )
}
Write-Host "IMAGES_ROOT=$trainRoot"; Write-Host 'CAMERA_IDS=0,1'
& .\run_receiver.ps1 `
  -Interface $interface -ImagesRoot $trainRoot `
  -ExpectedRows 480 -QueueDepth 65536 -PcapBufferSize 67108864 `
  -FrameOutputQueueDepth 256 -CameraIds '0,1' -SplitByCamera on `
  -ImagePolicy strict -PublishFrames complete -PublishImages process `
  -PublisherQueueDepth 256 -CsvQueueDepth 65536 -CsvBackpressure drop `
  -BitOrder msb_first -SessionAudit off -CrcMode enabled -PythonExe $python
if ($LASTEXITCODE -ne 0) { throw "Stereo training capture failed: $LASTEXITCODE" }
```

覆盖近/中/远三档尺度和双向倾斜，每个姿态稳定1–2秒。采集结束后独立执行：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$trainRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\04_stereo_train'
$staticAudit = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\03_stereo_static'
$pairsAudit = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\04_stereo_train_pairs'
$solveRoot = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\05_stereo_solve'
$cam0Intrinsic = Join-Path $receiverRoot 'calibration_configs\cam0_replacement_20260820_run01\cam0_intrinsics_120.json'
$cam1Intrinsic = Join-Path $receiverRoot 'calibration_configs\cam1_replacement_20260820_run01\cam1_intrinsics_120.json'
Set-Location -LiteralPath $receiverRoot

& .\run_stereo_training.ps1 `
  -PythonExe $python `
  -TrainRoot $trainRoot `
  -StaticAudit $staticAudit `
  -PairsAudit $pairsAudit `
  -SolveRoot $solveRoot `
  -Cam0Intrinsic $cam0Intrinsic `
  -Cam1Intrinsic $cam1Intrinsic `
  -ArchiveExistingOutputs
```

基线明显偏离约22 mm或旋转明显偏离约3°时检查打印间距、同步配对和机架；不要手改JSON。

外参训练失败时，训练数据、pairs、solve和已经生成的holdout下游结果必须一起清理：

```powershell
$targets = @(
  'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\04_stereo_train',
  'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\05_stereo_holdout_v1',
  'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\06_stereo_holdout_v2',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\04_stereo_train_pairs',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\05_stereo_solve',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\06_stereo_holdout_v1_pairs',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\07_stereo_holdout_v1_validation',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\08_stereo_holdout_v2_pairs',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\09_stereo_holdout_v2_validation'
)
$targets | ForEach-Object { Remove-Item -LiteralPath $_ -Recurse -Force -WhatIf }
```

```powershell
# 不可恢复；仅在上一个WhatIf清单完全正确后执行。
$targets = @(
  'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\04_stereo_train',
  'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\05_stereo_holdout_v1',
  'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\06_stereo_holdout_v2',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\04_stereo_train_pairs',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\05_stereo_solve',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\06_stereo_holdout_v1_pairs',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\07_stereo_holdout_v1_validation',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\08_stereo_holdout_v2_pairs',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\09_stereo_holdout_v2_validation'
)
$targets | Where-Object { Test-Path -LiteralPath $_ } |
  ForEach-Object { Remove-Item -LiteralPath $_ -Recurse -Force }
```

## 6. 外参holdout V1

### 执行索引

| 项目 | 值 |
|---|---|
| CameraIds | `0,1` |
| 数据路径 | `...run01\05_stereo_holdout_v1` |
| 目标 | 15–20个全新Pose |
| 输出 | `06_stereo_holdout_v1_pairs`、`07_stereo_holdout_v1_validation` |

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$interface = '\Device\NPF_{6BDDE37E-7DCA-4078-98B0-E374EFE04E7C}'
$holdoutRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\05_stereo_holdout_v1'
Set-Location -LiteralPath $receiverRoot
$payload = Get-ChildItem -LiteralPath $holdoutRoot -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -in @('.pgm','.raw','.json') -or $_.Name -eq 'rows_v2.csv' } |
  Select-Object -First 1
if ($null -ne $payload) { throw "V1 root is not empty: $holdoutRoot" }
foreach ($cam in 0,1) {
  Start-Process powershell.exe -ArgumentList @(
    '-NoExit','-ExecutionPolicy','Bypass','-File',(Join-Path $receiverRoot 'watch_calibration_poses.ps1'),
    '-ImagesRoot',$holdoutRoot,'-CameraId',"$cam",'-MinPoses','15',
    '-WindowLabel','Stereo-holdout-V1','-PythonExe',$python
  )
}
Write-Host "IMAGES_ROOT=$holdoutRoot"; Write-Host 'CAMERA_IDS=0,1'
& .\run_receiver.ps1 `
  -Interface $interface -ImagesRoot $holdoutRoot `
  -ExpectedRows 480 -QueueDepth 65536 -PcapBufferSize 67108864 `
  -FrameOutputQueueDepth 256 -CameraIds '0,1' -SplitByCamera on `
  -ImagePolicy strict -PublishFrames complete -PublishImages process `
  -PublisherQueueDepth 256 -CsvQueueDepth 65536 -CsvBackpressure drop `
  -BitOrder msb_first -SessionAudit off -CrcMode enabled -PythonExe $python
if ($LASTEXITCODE -ne 0) { throw "V1 capture failed: $LASTEXITCODE" }
```

配对和验证使用同样的绝对路径，不依赖第5节变量：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$holdoutRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\05_stereo_holdout_v1'
$staticAudit = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\03_stereo_static'
$pairsAudit = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\06_stereo_holdout_v1_pairs'
$validationRoot = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\07_stereo_holdout_v1_validation'
$cam0Intrinsic = Join-Path $receiverRoot 'calibration_configs\cam0_replacement_20260820_run01\cam0_intrinsics_120.json'
$cam1Intrinsic = Join-Path $receiverRoot 'calibration_configs\cam1_replacement_20260820_run01\cam1_intrinsics_120.json'
$extrinsics = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\05_stereo_solve\cam0_to_new_cam1_extrinsics.json'
Set-Location -LiteralPath $receiverRoot
& $python .\build_stereo_pairs.py $holdoutRoot `
  --cam0-intrinsics $cam0Intrinsic --cam1-intrinsics $cam1Intrinsic `
  --output-root $pairsAudit `
  --stillness-config (Join-Path $staticAudit 'stillness_config.json') `
  --max-center-dt-ms 33.5 --min-pairs 15
if ($LASTEXITCODE -ne 0) { throw "V1 pairing failed: $LASTEXITCODE" }
& $python .\validate_binary_extrinsics.py $extrinsics (Join-Path $pairsAudit 'pairs.csv') `
  --pairing-summary (Join-Path $pairsAudit 'pairing_summary.json') `
  --cam0-intrinsics $cam0Intrinsic --cam1-intrinsics $cam1Intrinsic `
  --stillness-config (Join-Path $staticAudit 'stillness_config.json') `
  --output-root $validationRoot --min-holdout-pairs 15
if ($LASTEXITCODE -ne 0) { throw "V1 validation failed: $LASTEXITCODE" }
```

V1仅因丢包、帧不完整或配对不足而失败时，按下面清理后重采；若质量合格数据上的几何
验证失败，应返回第5节重做外参训练。

```powershell
$targets = @(
  'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\05_stereo_holdout_v1',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\06_stereo_holdout_v1_pairs',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\07_stereo_holdout_v1_validation'
)
$targets | ForEach-Object { Remove-Item -LiteralPath $_ -Recurse -Force -WhatIf }
```

```powershell
# 仅在WhatIf确认后执行。
$targets = @(
  'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\05_stereo_holdout_v1',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\06_stereo_holdout_v1_pairs',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\07_stereo_holdout_v1_validation'
)
$targets | Where-Object { Test-Path -LiteralPath $_ } |
  ForEach-Object { Remove-Item -LiteralPath $_ -Recurse -Force }
```

## 7. 外参holdout V2

### 执行索引

| 项目 | 值 |
|---|---|
| CameraIds | `0,1` |
| 数据路径 | `...run01\06_stereo_holdout_v2` |
| 目标 | 与V1独立的15–20个Pose |
| 输出 | `08_stereo_holdout_v2_pairs`、`09_stereo_holdout_v2_validation` |

V2采集命令与V1结构相同，但以下三个位置必须全部使用V2，不能只改一个变量：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$interface = '\Device\NPF_{6BDDE37E-7DCA-4078-98B0-E374EFE04E7C}'
$holdoutRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\06_stereo_holdout_v2'
Set-Location -LiteralPath $receiverRoot
$payload = Get-ChildItem -LiteralPath $holdoutRoot -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -in @('.pgm','.raw','.json') -or $_.Name -eq 'rows_v2.csv' } |
  Select-Object -First 1
if ($null -ne $payload) { throw "V2 root is not empty: $holdoutRoot" }
foreach ($cam in 0,1) {
  Start-Process powershell.exe -ArgumentList @(
    '-NoExit','-ExecutionPolicy','Bypass','-File',(Join-Path $receiverRoot 'watch_calibration_poses.ps1'),
    '-ImagesRoot',$holdoutRoot,'-CameraId',"$cam",'-MinPoses','15',
    '-WindowLabel','Stereo-holdout-V2','-PythonExe',$python
  )
}
Write-Host "IMAGES_ROOT=$holdoutRoot"; Write-Host 'CAMERA_IDS=0,1'
& .\run_receiver.ps1 `
  -Interface $interface -ImagesRoot $holdoutRoot `
  -ExpectedRows 480 -QueueDepth 65536 -PcapBufferSize 67108864 `
  -FrameOutputQueueDepth 256 -CameraIds '0,1' -SplitByCamera on `
  -ImagePolicy strict -PublishFrames complete -PublishImages process `
  -PublisherQueueDepth 256 -CsvQueueDepth 65536 -CsvBackpressure drop `
  -BitOrder msb_first -SessionAudit off -CrcMode enabled -PythonExe $python
if ($LASTEXITCODE -ne 0) { throw "V2 capture failed: $LASTEXITCODE" }
```

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$holdoutRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\06_stereo_holdout_v2'
$staticAudit = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\03_stereo_static'
$pairsAudit = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\08_stereo_holdout_v2_pairs'
$validationRoot = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\09_stereo_holdout_v2_validation'
$cam0Intrinsic = Join-Path $receiverRoot 'calibration_configs\cam0_replacement_20260820_run01\cam0_intrinsics_120.json'
$cam1Intrinsic = Join-Path $receiverRoot 'calibration_configs\cam1_replacement_20260820_run01\cam1_intrinsics_120.json'
$extrinsics = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\05_stereo_solve\cam0_to_new_cam1_extrinsics.json'
Set-Location -LiteralPath $receiverRoot
& $python .\build_stereo_pairs.py $holdoutRoot `
  --cam0-intrinsics $cam0Intrinsic --cam1-intrinsics $cam1Intrinsic `
  --output-root $pairsAudit `
  --stillness-config (Join-Path $staticAudit 'stillness_config.json') `
  --max-center-dt-ms 33.5 --min-pairs 15
if ($LASTEXITCODE -ne 0) { throw "V2 pairing failed: $LASTEXITCODE" }
& $python .\validate_binary_extrinsics.py $extrinsics (Join-Path $pairsAudit 'pairs.csv') `
  --pairing-summary (Join-Path $pairsAudit 'pairing_summary.json') `
  --cam0-intrinsics $cam0Intrinsic --cam1-intrinsics $cam1Intrinsic `
  --stillness-config (Join-Path $staticAudit 'stillness_config.json') `
  --output-root $validationRoot --min-holdout-pairs 15
if ($LASTEXITCODE -ne 0) { throw "V2 validation failed: $LASTEXITCODE" }
```

V2采集完整性或配对数量失败时：

```powershell
$targets = @(
  'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\06_stereo_holdout_v2',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\08_stereo_holdout_v2_pairs',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\09_stereo_holdout_v2_validation'
)
$targets | ForEach-Object { Remove-Item -LiteralPath $_ -Recurse -Force -WhatIf }
```

```powershell
# 仅在WhatIf确认后执行。
$targets = @(
  'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\06_stereo_holdout_v2',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\08_stereo_holdout_v2_pairs',
  'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\09_stereo_holdout_v2_validation'
)
$targets | Where-Object { Test-Path -LiteralPath $_ } |
  ForEach-Object { Remove-Item -LiteralPath $_ -Recurse -Force }
```

## 8. 最终判定

- CAM1内参训练配置 `quality.status=acceptable`，且独立holdout `status=pass`；
- 训练 `pairing_summary.json` 为 `status=ready` 且至少20个不同双目Pose；
- 外参V1、V2均为 `status=pass`；
- 双向重投影 median≤0.8 px、P95≤1.2 px、max≤1.5 px；
- 整流纵向P95≤1.2 px；
- baseline/rotation与约22 mm/3°机械结构没有明显矛盾；
- cam0内参、新CAM1内参和新外参作为同一版本bundle发布，禁止混用旧CAM1 SHA或旧外参。

历史污染/非污染板模型、FOV和鱼眼可逆性对照见
[`CALIBRATION_MODEL_COMPARISON.md`](CALIBRATION_MODEL_COMPARISON.md)。
