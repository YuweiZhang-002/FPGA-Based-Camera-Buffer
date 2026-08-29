# 双 120° 相机外参失败后的五步恢复流程

适用对象：`cam1_replacement_20260820_run01`  
当前失败证据：`16_stereo_solve_k1k2\cam0_to_new_cam1_extrinsics.rejected.json`

当前配对时间差约 `1.98–2.34 ms`，且两次模型比较使用相同的 `pairs.csv`，因此本流程不把
“板移动太快”作为首要原因。重点先验证板和机械尺度，再比较只固定 `k4=0` 的三系数模型；
只有三系数模型仍失败时，才采集新的均衡诊断数据。

## 第一步：冻结失败证据，禁止放宽门限或发布 rejected 结果

### 目标

- 保存四系数和两系数两轮失败 JSON、逐对 CSV、配对摘要及 SHA256。
- 确认正式 extrinsics 文件不存在。
- 不使用 `--allow-limited`，不修改 depth-independence 阈值。

### PowerShell

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$base = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01'
$evidenceRoot = Join-Path $base 'failure_evidence_before_k1k2k3'
$sources = @(
  (Join-Path $base '05_stereo_solve\cam0_to_new_cam1_extrinsics.rejected.json'),
  (Join-Path $base '05_stereo_solve\training_pairs.csv'),
  (Join-Path $base '04_stereo_train_pairs\pairing_summary.json'),
  (Join-Path $base '16_stereo_solve_k1k2\cam0_to_new_cam1_extrinsics.rejected.json'),
  (Join-Path $base '16_stereo_solve_k1k2\training_pairs.csv'),
  (Join-Path $base '15_stereo_train_pairs_k1k2\pairing_summary.json')
)

foreach ($source in $sources) {
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing evidence: $source" }
}
if (Test-Path -LiteralPath $evidenceRoot) {
  if (@(Get-ChildItem -LiteralPath $evidenceRoot -Force).Count -ne 0) {
    throw "Evidence output is not empty: $evidenceRoot"
  }
}
New-Item -ItemType Directory -Force -Path $evidenceRoot | Out-Null

$manifest = foreach ($source in $sources) {
  $destination = Join-Path $evidenceRoot (
    "$(Split-Path (Split-Path $source -Parent) -Leaf)_$(Split-Path $source -Leaf)"
  )
  Copy-Item -LiteralPath $source -Destination $destination
  [pscustomobject]@{
    source = $source
    archived_path = $destination
    sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
  }
}
$manifest | ConvertTo-Json -Depth 4 |
  Set-Content -LiteralPath (Join-Path $evidenceRoot 'evidence_manifest.json') -Encoding UTF8

$published = @(
  (Join-Path $base '05_stereo_solve\cam0_to_new_cam1_extrinsics.json'),
  (Join-Path $base '16_stereo_solve_k1k2\cam0_to_new_cam1_extrinsics.json')
)
foreach ($path in $published) {
  if (Test-Path -LiteralPath $path -PathType Leaf) {
    throw "Unacceptable result was unexpectedly published: $path"
  }
}
Write-Host "Failure evidence frozen: $evidenceRoot" -ForegroundColor Green
```

预期结果：只有 `.rejected.json`，没有可发布的 `cam0_to_new_cam1_extrinsics.json`。

## 第二步：测量标定板和相机机械几何

### 板的测量方法

当前 asymmetric 4×11 模型为：

- `x=(2*column+(row%2))*base_spacing_mm`
- `y=row*base_spacing_mm`
- 同一行从第 1 个圆心到第 4 个圆心的跨度应为 `6 × base_spacing`，标称 `120 mm`。
- 第 1 行到第 11 行相同奇偶位置的纵向跨度应为 `10 × base_spacing`，标称 `200 mm`。
- 圆直径标称 `10 mm`。

用游标卡尺或钢尺跨多个间距测量，不要只量一对相邻圆。用平直尺检查板中心和四角翘曲。
相机 baseline 必须量镜头光学中心到光学中心，而不是 PCB 或外壳边缘。

### 记录测量值的 PowerShell

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$auditRoot = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\mechanical_measurement_audit'
$auditPath = Join-Path $auditRoot 'measurement.json'
if (Test-Path -LiteralPath $auditRoot) {
  if (@(Get-ChildItem -LiteralPath $auditRoot -Force).Count -ne 0) {
    throw "Measurement audit output is not empty: $auditRoot"
  }
}
New-Item -ItemType Directory -Force -Path $auditRoot | Out-Null

$horizontalSpanMm = [double](Read-Host '同一行第1到第4圆心跨度 mm（约120）')
$verticalSpanMm = [double](Read-Host '第1到第11行纵向跨度 mm（约200）')
$dotDiameterMm = [double](Read-Host '多个圆平均直径 mm（约10）')
$maximumWarpMm = [double](Read-Host '整块板最大翘曲/离平面量 mm')
$opticalBaselineMm = [double](Read-Host '两个镜头光学中心距离 mm（当前名义值25）')
$opticalAxisAngleDeg = [double](Read-Host '两条光轴夹角 deg（当前名义值5）')

$spacingX = $horizontalSpanMm / 6.0
$spacingY = $verticalSpanMm / 10.0
$spacingMean = ($spacingX + $spacingY) / 2.0
$anisotropyFraction = [Math]::Abs($spacingX - $spacingY) / $spacingMean
$failures = @()
if ($anisotropyFraction -gt 0.005) {
  $failures += "板的X/Y尺度差超过0.5%：$($anisotropyFraction*100)%"
}
if ($maximumWarpMm -gt 0.5) {
  $failures += "板翘曲超过0.5 mm：$maximumWarpMm mm"
}

$audit = [ordered]@{
  created_local = (Get-Date).ToString('o')
  board = [ordered]@{
    horizontal_span_mm = $horizontalSpanMm
    vertical_span_mm = $verticalSpanMm
    base_spacing_x_mm = $spacingX
    base_spacing_y_mm = $spacingY
    base_spacing_mean_mm = $spacingMean
    scale_anisotropy_fraction = $anisotropyFraction
    dot_diameter_mean_mm = $dotDiameterMm
    maximum_warp_mm = $maximumWarpMm
  }
  rig = [ordered]@{
    optical_center_baseline_mm = $opticalBaselineMm
    optical_axis_angle_deg = $opticalAxisAngleDeg
  }
  status = $(if ($failures.Count -eq 0) { 'usable' } else { 'reject_board' })
  failures = $failures
}
$audit | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $auditPath -Encoding UTF8
$audit | ConvertTo-Json -Depth 6
if ($failures.Count -ne 0) { throw ($failures -join '; ') }
Write-Host "Measurement audit PASS: $auditPath" -ForegroundColor Green
```

若 `base_spacing_mean_mm` 不等于 20，应在下面所有求解中使用实测平均值。均匀的打印缩放主要影响
毫米尺度；X/Y 非均匀缩放或板翘曲会造成 pose 相关误差，必须更换板，不能靠修改 spacing 掩盖。

## 第三步：复用现有数据，测试固定 k4=0、求解 k1/k2/k3

### 3.1 CAM0 三系数内参

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$trainCam = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\01_cam1_intrinsic_train\cam0'
$auditPath = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\mechanical_measurement_audit\measurement.json'
$solveRoot = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\17_cam0_k1k2k3_solve'
$intrinsic = Join-Path $solveRoot 'cam0_intrinsics_k1k2k3.json'
Set-Location -LiteralPath $receiverRoot
$env:PYTHONDONTWRITEBYTECODE = '1'
$measurement = Get-Content -LiteralPath $auditPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$measurement.status -ne 'usable') { throw "Board measurement is not usable" }
$spacingMm = [double]$measurement.board.base_spacing_mean_mm
if (Test-Path -LiteralPath $solveRoot) {
  if (@(Get-ChildItem -LiteralPath $solveRoot -Force).Count -ne 0) { throw "Output is not empty: $solveRoot" }
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
  --camera-id 0 --width 640 --height 480 `
  --pattern asymmetric --columns 4 --rows 11 `
  --spacing-mm $spacingMm --dot-diameter-mm ([double]$measurement.board.dot_diameter_mean_mm) `
  --model fisheye --fov-deg 120 --fisheye-fix-k4 `
  --min-views 20 --min-final-poses 25 --max-view-rmse-px 1.5
if ($LASTEXITCODE -ne 0) { throw "CAM0 k1/k2/k3 solve failed: $LASTEXITCODE" }
$cfg = Get-Content -LiteralPath $intrinsic -Raw -Encoding UTF8 | ConvertFrom-Json
if ([Math]::Abs([double]$cfg.dist_coeffs[3]) -gt 1e-12) { throw 'CAM0 k4 is not zero' }
if ('k4' -notin @($cfg.solver_constraints.fixed_distortion_coefficients)) {
  throw 'CAM0 JSON does not declare fixed k4'
}
Write-Host "CAM0 k1/k2/k3 PASS: RMS=$($cfg.quality.rms_px)" -ForegroundColor Green
```

### 3.2 CAM0 独立 holdout

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$intrinsic = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\17_cam0_k1k2k3_solve\cam0_intrinsics_k1k2k3.json'
$holdout = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\02_cam1_intrinsic_holdout\cam0'
$outputRoot = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\18_cam0_k1k2k3_validation'
Set-Location -LiteralPath $receiverRoot
$env:PYTHONDONTWRITEBYTECODE = '1'
if (Test-Path -LiteralPath $outputRoot) {
  if (@(Get-ChildItem -LiteralPath $outputRoot -Force).Count -ne 0) { throw "Output is not empty: $outputRoot" }
}
& $python .\validate_binary_calibration.py $intrinsic $holdout `
  --output-root $outputRoot --sample-count 30 --min-holdout-views 15 `
  --median-rmse-px 0.8 --p95-rmse-px 1.2 --maximum-rmse-px 1.5 `
  --required-pass-fraction 0.90
if ($LASTEXITCODE -ne 0) { throw "CAM0 k1/k2/k3 holdout failed: $LASTEXITCODE" }
```

### 3.3 CAM1 三系数内参

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$trainCam = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\01_cam1_intrinsic_train\cam1'
$auditPath = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\mechanical_measurement_audit\measurement.json'
$solveRoot = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\19_cam1_k1k2k3_solve'
$intrinsic = Join-Path $solveRoot 'cam1_intrinsics_k1k2k3.json'
Set-Location -LiteralPath $receiverRoot
$env:PYTHONDONTWRITEBYTECODE = '1'
$measurement = Get-Content -LiteralPath $auditPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$measurement.status -ne 'usable') { throw "Board measurement is not usable" }
$spacingMm = [double]$measurement.board.base_spacing_mean_mm
if (Test-Path -LiteralPath $solveRoot) {
  if (@(Get-ChildItem -LiteralPath $solveRoot -Force).Count -ne 0) { throw "Output is not empty: $solveRoot" }
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
  --spacing-mm $spacingMm --dot-diameter-mm ([double]$measurement.board.dot_diameter_mean_mm) `
  --model fisheye --fov-deg 120 --fisheye-fix-k4 `
  --min-views 20 --min-final-poses 25 --max-view-rmse-px 1.5
if ($LASTEXITCODE -ne 0) { throw "CAM1 k1/k2/k3 solve failed: $LASTEXITCODE" }
$cfg = Get-Content -LiteralPath $intrinsic -Raw -Encoding UTF8 | ConvertFrom-Json
if ([Math]::Abs([double]$cfg.dist_coeffs[3]) -gt 1e-12) { throw 'CAM1 k4 is not zero' }
if ('k4' -notin @($cfg.solver_constraints.fixed_distortion_coefficients)) {
  throw 'CAM1 JSON does not declare fixed k4'
}
Write-Host "CAM1 k1/k2/k3 PASS: RMS=$($cfg.quality.rms_px)" -ForegroundColor Green
```

### 3.4 CAM1 独立 holdout

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$intrinsic = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\19_cam1_k1k2k3_solve\cam1_intrinsics_k1k2k3.json'
$holdout = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\02_cam1_intrinsic_holdout\cam1'
$outputRoot = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\20_cam1_k1k2k3_validation'
Set-Location -LiteralPath $receiverRoot
$env:PYTHONDONTWRITEBYTECODE = '1'
if (Test-Path -LiteralPath $outputRoot) {
  if (@(Get-ChildItem -LiteralPath $outputRoot -Force).Count -ne 0) { throw "Output is not empty: $outputRoot" }
}
& $python .\validate_binary_calibration.py $intrinsic $holdout `
  --output-root $outputRoot --sample-count 30 --min-holdout-views 15 `
  --median-rmse-px 0.8 --p95-rmse-px 1.2 --maximum-rmse-px 1.5 `
  --required-pass-fraction 0.90
if ($LASTEXITCODE -ne 0) { throw "CAM1 k1/k2/k3 holdout failed: $LASTEXITCODE" }
```

### 3.5 两台 holdout 通过后，重新生成 stillness

本阶段不要再逐行粘贴 Python 命令。使用原子化包装脚本；它会自动补做缺失 holdout、验证
summary 绑定的 intrinsic SHA，并保证两个 holdout 都 pass 后才生成 stillness。

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$base = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01'
$staticRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\03_stereo_static'
$staticAudit = Join-Path $base '21_stereo_static_k1k2k3'
$cam0Intrinsic = Join-Path $base '17_cam0_k1k2k3_solve\cam0_intrinsics_k1k2k3.json'
$cam1Intrinsic = Join-Path $base '19_cam1_k1k2k3_solve\cam1_intrinsics_k1k2k3.json'
Set-Location -LiteralPath $receiverRoot
& .\run_intrinsic_candidate_gate.ps1 `
  -PythonExe $python `
  -Cam0Intrinsic $cam0Intrinsic `
  -Cam1Intrinsic $cam1Intrinsic `
  -Cam0Holdout 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\02_cam1_intrinsic_holdout\cam0' `
  -Cam1Holdout 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\02_cam1_intrinsic_holdout\cam1' `
  -Cam0ValidationRoot (Join-Path $base '18_cam0_k1k2k3_validation') `
  -Cam1ValidationRoot (Join-Path $base '20_cam1_k1k2k3_validation') `
  -StaticRoot $staticRoot `
  -StaticAudit $staticAudit `
  -ArchiveExistingOutputs
if ($LASTEXITCODE -ne 0) { throw "Candidate gate failed: $LASTEXITCODE" }
```

### 3.6 先复用现有 04_stereo_train 测试三系数模型

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$base = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01'
$trainRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\04_stereo_train'
$staticAudit = Join-Path $base '21_stereo_static_k1k2k3'
$pairsAudit = Join-Path $base '22_stereo_train_pairs_k1k2k3'
$solveRoot = Join-Path $base '23_stereo_solve_k1k2k3'
$cam0Intrinsic = Join-Path $base '17_cam0_k1k2k3_solve\cam0_intrinsics_k1k2k3.json'
$cam1Intrinsic = Join-Path $base '19_cam1_k1k2k3_solve\cam1_intrinsics_k1k2k3.json'
Set-Location -LiteralPath $receiverRoot
& .\run_stereo_training.ps1 `
  -PythonExe $python -TrainRoot $trainRoot -StaticAudit $staticAudit `
  -PairsAudit $pairsAudit -SolveRoot $solveRoot `
  -Cam0Intrinsic $cam0Intrinsic -Cam1Intrinsic $cam1Intrinsic `
  -MinPairs 20
if ($LASTEXITCODE -ne 0) { throw "Existing-data k1/k2/k3 stereo failed: $LASTEXITCODE" }
```

如果生成 `23_stereo_solve_k1k2k3\cam0_to_new_cam1_extrinsics.json` 且质量为 acceptable，
停止，不执行第四步。若仍生成 `.rejected.json`，继续第四步。

## 第四步：只在第三步仍失败时，采集均衡诊断外参数据

### Pose 矩阵

不要连续从近处一路平移到远处。每个 pose 放好后完全停住 1–2 秒。

| 距离 | 中心/上下左右 | yaw | pitch | 最低数量 |
|---|---|---|---|---:|
| Near，约 500 mm | 中、上、下、左、右 | +20°、−20° | +20°、−20° | 9 |
| Mid，约 650 mm | 中、上、下、左、右、四角 | +25°、−25° | +25°、−25° | 13 |
| Far，约 800 mm | 中、上、下、左、右 | +15°、−15° | +15°、−15° | 9 |

总目标至少 31 个设计 pose；实时窗口目标设为 36，给检测/配对淘汰留余量。同一距离必须覆盖不同
图像区域，同一图像区域也必须包含不同距离。

### 双窗口实时采集

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$interface = '\Device\NPF_{6BDDE37E-7DCA-4078-98B0-E374EFE04E7C}'
$trainRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run02\01_stereo_diagnostic_train'
Set-Location -LiteralPath $receiverRoot
$payload = Get-ChildItem -LiteralPath $trainRoot -Recurse -File -ErrorAction SilentlyContinue |
  Select-Object -First 1
if ($null -ne $payload) { throw "Diagnostic capture root is not empty: $trainRoot" }

foreach ($cam in 0,1) {
  Start-Process powershell.exe -ArgumentList @(
    '-NoExit','-ExecutionPolicy','Bypass','-File',(Join-Path $receiverRoot 'watch_calibration_poses.ps1'),
    '-ImagesRoot',$trainRoot,'-CameraId',"$cam",'-MinPoses','36',
    '-WindowLabel','Balanced-stereo-diagnostic','-PythonExe',$python
  )
}
Write-Host "IMAGES_ROOT=$trainRoot"
Write-Host 'CAMERA_IDS=0,1'
& .\run_receiver.ps1 `
  -Interface $interface -ImagesRoot $trainRoot `
  -ExpectedRows 480 -QueueDepth 65536 -PcapBufferSize 67108864 `
  -FrameOutputQueueDepth 256 -CameraIds '0,1' -SplitByCamera on `
  -ImagePolicy strict -PublishFrames complete -PublishImages process `
  -PublisherQueueDepth 256 -CsvQueueDepth 65536 -CsvBackpressure drop `
  -BitOrder msb_first -SessionAudit off -CrcMode enabled -PythonExe $python
if ($LASTEXITCODE -ne 0) { throw "Balanced diagnostic capture failed: $LASTEXITCODE" }
```

按 Ctrl+C 正常结束后，Final Report 中必须满足：`ps_drop=0`、capture/lane/CSV/publisher drops 全为 0。
两个实时窗口都应显示至少 36 pose。只有确认采集不完整时才允许归档。不要直接运行裸
`Move-Item`；安全脚本会检查两路 PGM/JSON/RAW/rows_v2，完整采集会被拒绝归档。

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$target = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run02\01_stereo_diagnostic_train'
Set-Location -LiteralPath $receiverRoot
& .\manage_capture_directory.ps1 -Action ArchiveFailed -Target $target
if ($LASTEXITCODE -ne 0) { throw "Safe capture archive failed: $LASTEXITCODE" }
```

若误归档，先用 `Get-ChildItem` 找到确切的 `_failed_时间戳`，再显式恢复。`ArchivePath` 必须
是双路完整采集，否则脚本拒绝移动：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$target = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run02\01_stereo_diagnostic_train'
$archive = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run02\01_stereo_diagnostic_train_failed_YYYYMMDD_HHMMSS'
Set-Location -LiteralPath $receiverRoot
& .\manage_capture_directory.ps1 `
  -Action Restore -Target $target -ArchivePath $archive
if ($LASTEXITCODE -ne 0) { throw "Capture restore failed: $LASTEXITCODE" }
```

Windows 路径中的下划线不需要转义。必须写 `prg_cam`、`new_Temp`，不能写成
`prg\_cam`、`new\_Temp`。

## 第五步：检查均衡性，并用至少 30 对运行外参

### 配对和求解

复用第三步生成、且绑定三系数内参 SHA 的 `21_stereo_static_k1k2k3`。新采集不需要再采静止阈值。

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$run01 = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01'
$run02 = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run02'
$trainRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run02\01_stereo_diagnostic_train'
$staticAudit = Join-Path $run01 '21_stereo_static_k1k2k3'
$pairsAudit = Join-Path $run02 '01_stereo_diagnostic_pairs_k1k2k3'
$solveRoot = Join-Path $run02 '02_stereo_diagnostic_solve_k1k2k3'
$cam0Intrinsic = Join-Path $run01 '17_cam0_k1k2k3_solve\cam0_intrinsics_k1k2k3.json'
$cam1Intrinsic = Join-Path $run01 '19_cam1_k1k2k3_solve\cam1_intrinsics_k1k2k3.json'
Set-Location -LiteralPath $receiverRoot
& .\run_stereo_training.ps1 `
  -PythonExe $python -TrainRoot $trainRoot -StaticAudit $staticAudit `
  -PairsAudit $pairsAudit -SolveRoot $solveRoot `
  -Cam0Intrinsic $cam0Intrinsic -Cam1Intrinsic $cam1Intrinsic `
  -MinPairs 30
if ($LASTEXITCODE -ne 0) { throw "Balanced diagnostic stereo failed: $LASTEXITCODE" }
```

失败重跑时保留上一次 pair/solve 证据，在上述命令最后加入 `-ArchiveExistingOutputs`。

### 结果和距离分档检查

无论求解成功或 rejected，都可单独执行：

```powershell
$solveRoot = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run02\02_stereo_diagnostic_solve_k1k2k3'
$report = Join-Path $solveRoot 'training_pairs.csv'
$final = Join-Path $solveRoot 'cam0_to_new_cam1_extrinsics.json'
$rejected = Join-Path $solveRoot 'cam0_to_new_cam1_extrinsics.rejected.json'
if (-not (Test-Path -LiteralPath $report -PathType Leaf)) { throw "Missing report: $report" }

$accepted = @(Import-Csv -LiteralPath $report | Where-Object { $_.accepted -eq 'True' })
$bins = @(
  @{Name='Near'; Min=0.0; Max=575.0},
  @{Name='Mid'; Min=575.0; Max=725.0},
  @{Name='Far'; Min=725.0; Max=[double]::PositiveInfinity}
)
$distribution = foreach ($bin in $bins) {
  $rows = @($accepted | Where-Object {
    $z = [double]$_.board_depth_cam0_mm
    $z -ge $bin.Min -and $z -lt $bin.Max
  })
  [pscustomobject]@{DepthBin=$bin.Name; AcceptedPairs=$rows.Count}
}
$distribution | Format-Table -AutoSize
if ($accepted.Count -lt 30) { throw "Only $($accepted.Count) accepted pairs; need at least 30" }
if (@($distribution | Where-Object { $_.AcceptedPairs -lt 8 }).Count -ne 0) {
  throw 'Near/Mid/Far distribution is unbalanced; each bin needs at least 8 accepted pairs'
}

$resultPath = if (Test-Path -LiteralPath $final -PathType Leaf) { $final } else { $rejected }
if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw 'No final or rejected result JSON' }
$result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
$R = $result.R_cam1_from_cam0
$trace = [double]$R[0][0] + [double]$R[1][1] + [double]$R[2][2]
$rotationDeg = [Math]::Acos(
  [Math]::Max(-1.0,[Math]::Min(1.0,($trace-1.0)/2.0))
) * 180.0 / [Math]::PI
[pscustomobject]@{
  Status = $result.quality.status
  StereoRmsPx = $result.quality.stereo_rms_px
  AcceptedPairs = $result.quality.accepted_pairs
  BaselineMm = $result.quality.baseline_mm
  RotationDeg = $rotationDeg
  TranslationDispersionMm = $result.quality.translation_dispersion_median_mm
  DepthIndependence = $result.quality.depth_independence.status
} | Format-List

if ([string]$result.quality.status -ne 'acceptable') { throw 'Extrinsics are not acceptable' }
if ([string]$result.quality.depth_independence.status -ne 'pass') { throw 'Depth independence failed' }
Write-Host "Publishable extrinsics: $final" -ForegroundColor Green
```

最终发布条件全部满足才可继续 V1/V2 外参 holdout：

- 两台三系数内参各自独立 holdout 为 pass。
- 至少 30 个有效外参 pair，Near/Mid/Far 各不少于 8。
- `quality.status=acceptable`，`depth_independence.status=pass`。
- baseline 和旋转与第二步实测光学中心/光轴一致；不能只与外壳估计比较。
- 不存在 capture、CSV、lane、publisher drops。
