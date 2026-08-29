# 两台 120° 相机的约束 fisheye（仅求解 k1/k2）比较流程

日期：2026-08-20  
数据集：`cam1_replacement_20260820_run01`

## 结论和边界

本轮不重新采集任何图像。复用以下三组既有数据：

- 内参训练：`01_cam1_intrinsic_train\cam0`、`cam1`
- 独立内参 holdout：`02_cam1_intrinsic_holdout\cam0`、`cam1`
- 双目静止/训练：`03_stereo_static`、`04_stereo_train`

新增的 `--fisheye-fix-k3-k4` 会给 OpenCV 设置 `CALIB_FIX_K3 | CALIB_FIX_K4`，初值为零，
因此只优化 `k1/k2`。输出 JSON 的 `solver_constraints` 会记录固定和自由系数。本轮所有结果写入
`10` 至 `16` 开头的新目录，不覆盖目前的四系数模型、旧 stillness 或旧外参结果。

严格顺序为：CAM0 求解 → CAM0 独立 holdout → CAM1 求解 → CAM1 独立 holdout →
比较 → 用两份新内参重新计算 stillness → 复用 `04_stereo_train` 做外参训练。

## 0. 输入和程序预检

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$dataRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01'
Set-Location -LiteralPath $receiverRoot
$env:PYTHONDONTWRITEBYTECODE = '1'

& $python .\calibrate_binary_camera_refill.py --help |
  Select-String -SimpleMatch '--fisheye-fix-k3-k4'
if ($LASTEXITCODE -ne 0) { throw "Constrained intrinsic CLI is unavailable: $LASTEXITCODE" }

$required = @(
  (Join-Path $dataRoot '01_cam1_intrinsic_train\cam0'),
  (Join-Path $dataRoot '01_cam1_intrinsic_train\cam1'),
  (Join-Path $dataRoot '02_cam1_intrinsic_holdout\cam0'),
  (Join-Path $dataRoot '02_cam1_intrinsic_holdout\cam1'),
  (Join-Path $dataRoot '03_stereo_static\cam0'),
  (Join-Path $dataRoot '03_stereo_static\cam1'),
  (Join-Path $dataRoot '04_stereo_train\cam0'),
  (Join-Path $dataRoot '04_stereo_train\cam1')
)
foreach ($path in $required) {
  if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Missing input: $path" }
  $count = @(Get-ChildItem -LiteralPath $path -Filter '*.pgm' -File).Count
  if ($count -eq 0) { throw "No PGM input: $path" }
  Write-Host "$count PGM  $path"
}
```

当前已核对的数量应为 CAM0/CAM1：内参训练 `3602/3482`，独立 holdout `2552/2314`，
静止数据 `436/436`，外参训练 `4241/4273`。

## 1. CAM0：固定 k3/k4 的内参求解

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$trainCam = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\01_cam1_intrinsic_train\cam0'
$solveRoot = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\10_cam0_k1k2_solve'
$intrinsic = Join-Path $solveRoot 'cam0_intrinsics_k1k2.json'
Set-Location -LiteralPath $receiverRoot
$env:PYTHONDONTWRITEBYTECODE = '1'

if (Test-Path -LiteralPath $solveRoot) {
  if (@(Get-ChildItem -LiteralPath $solveRoot -Force).Count -ne 0) {
    throw "CAM0 output is not empty: $solveRoot"
  }
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
  --spacing-mm 20 --dot-diameter-mm 10 `
  --model fisheye --fov-deg 120 --fisheye-fix-k3-k4 `
  --min-views 20 --min-final-poses 25 --max-view-rmse-px 1.5
if ($LASTEXITCODE -ne 0) { throw "CAM0 constrained intrinsic solve failed: $LASTEXITCODE" }

$cfg = Get-Content -LiteralPath $intrinsic -Raw -Encoding UTF8 | ConvertFrom-Json
$d = @($cfg.dist_coeffs)
if ($d.Count -ne 4 -or [Math]::Abs([double]$d[2]) -gt 1e-12 -or [Math]::Abs([double]$d[3]) -gt 1e-12) {
  throw "CAM0 k3/k4 are not fixed at zero"
}
Write-Host "CAM0 constrained solve PASS: RMS=$($cfg.quality.rms_px), D=$($d -join ', ')" -ForegroundColor Green
```

不要添加 `--allow-limited`。命令返回非零时，不进入 CAM0 holdout。

## 2. CAM0：独立 holdout

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$intrinsic = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\10_cam0_k1k2_solve\cam0_intrinsics_k1k2.json'
$holdoutCam = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\02_cam1_intrinsic_holdout\cam0'
$validationRoot = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\11_cam0_k1k2_validation'
Set-Location -LiteralPath $receiverRoot
$env:PYTHONDONTWRITEBYTECODE = '1'

if (-not (Test-Path -LiteralPath $intrinsic -PathType Leaf)) { throw "Missing CAM0 intrinsic: $intrinsic" }
if (Test-Path -LiteralPath $validationRoot) {
  if (@(Get-ChildItem -LiteralPath $validationRoot -Force).Count -ne 0) {
    throw "CAM0 validation output is not empty: $validationRoot"
  }
}

& $python .\validate_binary_calibration.py $intrinsic $holdoutCam `
  --output-root $validationRoot --sample-count 30 --min-holdout-views 15 `
  --median-rmse-px 0.8 --p95-rmse-px 1.2 --maximum-rmse-px 1.5 `
  --required-pass-fraction 0.90
if ($LASTEXITCODE -ne 0) { throw "CAM0 constrained holdout failed: $LASTEXITCODE" }
```

必须看到 `holdout validation: pass`，否则停止；不能手工删掉高误差 holdout 视图来改变结论。

## 3. CAM1：固定 k3/k4 的内参求解

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$trainCam = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\01_cam1_intrinsic_train\cam1'
$solveRoot = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\12_cam1_k1k2_solve'
$intrinsic = Join-Path $solveRoot 'cam1_intrinsics_k1k2.json'
Set-Location -LiteralPath $receiverRoot
$env:PYTHONDONTWRITEBYTECODE = '1'

if (Test-Path -LiteralPath $solveRoot) {
  if (@(Get-ChildItem -LiteralPath $solveRoot -Force).Count -ne 0) {
    throw "CAM1 output is not empty: $solveRoot"
  }
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
  --model fisheye --fov-deg 120 --fisheye-fix-k3-k4 `
  --min-views 20 --min-final-poses 25 --max-view-rmse-px 1.5
if ($LASTEXITCODE -ne 0) { throw "CAM1 constrained intrinsic solve failed: $LASTEXITCODE" }

$cfg = Get-Content -LiteralPath $intrinsic -Raw -Encoding UTF8 | ConvertFrom-Json
$d = @($cfg.dist_coeffs)
if ($d.Count -ne 4 -or [Math]::Abs([double]$d[2]) -gt 1e-12 -or [Math]::Abs([double]$d[3]) -gt 1e-12) {
  throw "CAM1 k3/k4 are not fixed at zero"
}
Write-Host "CAM1 constrained solve PASS: RMS=$($cfg.quality.rms_px), D=$($d -join ', ')" -ForegroundColor Green
```

## 4. CAM1：独立 holdout

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$intrinsic = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\12_cam1_k1k2_solve\cam1_intrinsics_k1k2.json'
$holdoutCam = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\02_cam1_intrinsic_holdout\cam1'
$validationRoot = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\13_cam1_k1k2_validation'
Set-Location -LiteralPath $receiverRoot
$env:PYTHONDONTWRITEBYTECODE = '1'

if (-not (Test-Path -LiteralPath $intrinsic -PathType Leaf)) { throw "Missing CAM1 intrinsic: $intrinsic" }
if (Test-Path -LiteralPath $validationRoot) {
  if (@(Get-ChildItem -LiteralPath $validationRoot -Force).Count -ne 0) {
    throw "CAM1 validation output is not empty: $validationRoot"
  }
}

& $python .\validate_binary_calibration.py $intrinsic $holdoutCam `
  --output-root $validationRoot --sample-count 30 --min-holdout-views 15 `
  --median-rmse-px 0.8 --p95-rmse-px 1.2 --maximum-rmse-px 1.5 `
  --required-pass-fraction 0.90
if ($LASTEXITCODE -ne 0) { throw "CAM1 constrained holdout failed: $LASTEXITCODE" }
```

## 5. 四系数模型与 k1/k2 模型对比

本段现在是自包含命令：如果某个约束模型的 `holdout_summary.json` 缺失，会先用对应的独立
holdout 自动补做验证。若验证目录仅含不完整的旧输出，会先改名归档，不会删除证据。

```powershell
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$base = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01'
$dataRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01'
Set-Location -LiteralPath $receiverRoot
$env:PYTHONDONTWRITEBYTECODE = '1'

function Ensure-ConstrainedHoldout {
  param(
    [Parameter(Mandatory=$true)][string]$Camera,
    [Parameter(Mandatory=$true)][string]$Intrinsic,
    [Parameter(Mandatory=$true)][string]$Holdout,
    [Parameter(Mandatory=$true)][string]$OutputRoot
  )

  $summary = Join-Path $OutputRoot 'holdout_summary.json'
  if (Test-Path -LiteralPath $summary -PathType Leaf) {
    Write-Host "$Camera constrained holdout already exists: $summary"
    return
  }
  if (-not (Test-Path -LiteralPath $Intrinsic -PathType Leaf)) {
    throw "$Camera constrained intrinsic is missing: $Intrinsic"
  }
  if (-not (Test-Path -LiteralPath $Holdout -PathType Container)) {
    throw "$Camera independent holdout directory is missing: $Holdout"
  }
  if (Test-Path -LiteralPath $OutputRoot) {
    $partial = @(Get-ChildItem -LiteralPath $OutputRoot -Force)
    if ($partial.Count -ne 0) {
      $archive = "${OutputRoot}_incomplete_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
      Move-Item -LiteralPath $OutputRoot -Destination $archive
      Write-Host "$Camera incomplete validation archived: $archive"
    }
  }

  & $python .\validate_binary_calibration.py $Intrinsic $Holdout `
    --output-root $OutputRoot --sample-count 30 --min-holdout-views 15 `
    --median-rmse-px 0.8 --p95-rmse-px 1.2 --maximum-rmse-px 1.5 `
    --required-pass-fraction 0.90
  $validationExit = $LASTEXITCODE
  if ($validationExit -ne 0) {
    throw "$Camera constrained holdout failed: $validationExit"
  }
  if (-not (Test-Path -LiteralPath $summary -PathType Leaf)) {
    throw "$Camera validation returned success but did not create: $summary"
  }
}

Ensure-ConstrainedHoldout `
  -Camera 'CAM0' `
  -Intrinsic (Join-Path $base '10_cam0_k1k2_solve\cam0_intrinsics_k1k2.json') `
  -Holdout (Join-Path $dataRoot '02_cam1_intrinsic_holdout\cam0') `
  -OutputRoot (Join-Path $base '11_cam0_k1k2_validation')

Ensure-ConstrainedHoldout `
  -Camera 'CAM1' `
  -Intrinsic (Join-Path $base '12_cam1_k1k2_solve\cam1_intrinsics_k1k2.json') `
  -Holdout (Join-Path $dataRoot '02_cam1_intrinsic_holdout\cam1') `
  -OutputRoot (Join-Path $base '13_cam1_k1k2_validation')

$cases = @(
  @{ Camera='CAM0'; Model='k1-k4'; Intrinsic=(Join-Path $receiverRoot 'calibration_configs\cam0_replacement_20260820_run01\cam0_intrinsics_120.json'); Validation=(Join-Path $base '02_cam0_validation\holdout_summary.json') },
  @{ Camera='CAM0'; Model='k1-k2'; Intrinsic=(Join-Path $base '10_cam0_k1k2_solve\cam0_intrinsics_k1k2.json'); Validation=(Join-Path $base '11_cam0_k1k2_validation\holdout_summary.json') },
  @{ Camera='CAM1'; Model='k1-k4'; Intrinsic=(Join-Path $receiverRoot 'calibration_configs\cam1_replacement_20260820_run01\cam1_intrinsics_120.json'); Validation=(Join-Path $base '02_cam1_validation\holdout_summary.json') },
  @{ Camera='CAM1'; Model='k1-k2'; Intrinsic=(Join-Path $base '12_cam1_k1k2_solve\cam1_intrinsics_k1k2.json'); Validation=(Join-Path $base '13_cam1_k1k2_validation\holdout_summary.json') }
)

$table = foreach ($case in $cases) {
  if (-not (Test-Path -LiteralPath $case.Intrinsic -PathType Leaf)) { throw "Missing: $($case.Intrinsic)" }
  if (-not (Test-Path -LiteralPath $case.Validation -PathType Leaf)) { throw "Missing: $($case.Validation)" }
  $i = Get-Content -LiteralPath $case.Intrinsic -Raw -Encoding UTF8 | ConvertFrom-Json
  $v = Get-Content -LiteralPath $case.Validation -Raw -Encoding UTF8 | ConvertFrom-Json
  [pscustomobject]@{
    Camera = $case.Camera
    Model = $case.Model
    fx = [Math]::Round([double]$i.K[0][0], 3)
    fy = [Math]::Round([double]$i.K[1][1], 3)
    k1 = [Math]::Round([double]$i.dist_coeffs[0], 6)
    k2 = [Math]::Round([double]$i.dist_coeffs[1], 6)
    k3 = [Math]::Round([double]$i.dist_coeffs[2], 6)
    k4 = [Math]::Round([double]$i.dist_coeffs[3], 6)
    TrainRMS = [Math]::Round([double]$i.quality.rms_px, 4)
    Holdout = [string]$v.status
    Median = [Math]::Round([double]$v.quality.median_rmse_px, 4)
    P95 = [Math]::Round([double]$v.quality.p95_rmse_px, 4)
    Maximum = [Math]::Round([double]$v.quality.maximum_rmse_px, 4)
    PassFraction = [double]$v.quality.fraction_at_or_below_p95_limit
  }
}
Write-Host 'Intrinsic parameters'
$table | Select-Object Camera,Model,fx,fy,k1,k2,k3,k4,TrainRMS |
  Format-Table -AutoSize
Write-Host 'Independent holdout'
$table | Select-Object Camera,Model,Holdout,Median,P95,Maximum,
  @{Name='PassPercent';Expression={ [Math]::Round(100.0 * $_.PassFraction, 1) }} |
  Format-Table -AutoSize

$failed = @($table | Where-Object { $_.Model -eq 'k1-k2' -and $_.Holdout -ne 'pass' })
if ($failed.Count -ne 0) { throw 'At least one constrained intrinsic failed independent holdout' }
```

选择规则：训练 RMS 不是唯一依据。`k1/k2` 模型必须分别通过原封不动的独立 holdout 门限；
最终还必须让外参深度一致性通过。较低自由度但略高训练 RMS 是正常现象，不能因此单独否决约束模型。

## 6. 用 k1/k2 内参重新生成 stillness

这里复用 `03_stereo_static` 图像，但必须写入新审计目录。绝不能继续使用旧
`03_stereo_static\stillness_config.json`，因为它绑定的是四系数内参 SHA256。

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$staticRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\03_stereo_static'
$staticAudit = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\14_stereo_static_k1k2'
$cam0Intrinsic = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\10_cam0_k1k2_solve\cam0_intrinsics_k1k2.json'
$cam1Intrinsic = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\12_cam1_k1k2_solve\cam1_intrinsics_k1k2.json'
Set-Location -LiteralPath $receiverRoot
$env:PYTHONDONTWRITEBYTECODE = '1'

if (Test-Path -LiteralPath $staticAudit) {
  if (@(Get-ChildItem -LiteralPath $staticAudit -Force).Count -ne 0) {
    throw "Constrained stillness output is not empty: $staticAudit"
  }
}

& $python .\build_stereo_pairs.py $staticRoot `
  --cam0-intrinsics $cam0Intrinsic --cam1-intrinsics $cam1Intrinsic `
  --output-root $staticAudit --estimate-stillness-only `
  --window-frames 5 --min-static-frames 200
if ($LASTEXITCODE -ne 0) { throw "Constrained stillness estimation failed: $LASTEXITCODE" }

$stillness = Join-Path $staticAudit 'stillness_config.json'
if (-not (Test-Path -LiteralPath $stillness -PathType Leaf)) { throw "Missing: $stillness" }
$s = Get-Content -LiteralPath $stillness -Raw -Encoding UTF8 | ConvertFrom-Json
$h0 = (Get-FileHash -LiteralPath $cam0Intrinsic -Algorithm SHA256).Hash.ToLowerInvariant()
$h1 = (Get-FileHash -LiteralPath $cam1Intrinsic -Algorithm SHA256).Hash.ToLowerInvariant()
if ([string]$s.intrinsics.cam0.sha256 -ne $h0 -or [string]$s.intrinsics.cam1.sha256 -ne $h1) {
  throw 'New stillness does not bind the constrained intrinsic hashes'
}
Write-Host 'Constrained stillness provenance PASS' -ForegroundColor Green
```

## 7. 复用 04_stereo_train 运行外参训练

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$receiverRoot = 'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$trainRoot = 'D:\prg\prg_cam\images\new_Temp\cam1_replacement_20260820_run01\04_stereo_train'
$staticAudit = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\14_stereo_static_k1k2'
$pairsAudit = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\15_stereo_train_pairs_k1k2'
$solveRoot = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\16_stereo_solve_k1k2'
$cam0Intrinsic = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\10_cam0_k1k2_solve\cam0_intrinsics_k1k2.json'
$cam1Intrinsic = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01\12_cam1_k1k2_solve\cam1_intrinsics_k1k2.json'
Set-Location -LiteralPath $receiverRoot

& .\run_stereo_training.ps1 `
  -PythonExe $python `
  -TrainRoot $trainRoot `
  -StaticAudit $staticAudit `
  -PairsAudit $pairsAudit `
  -SolveRoot $solveRoot `
  -Cam0Intrinsic $cam0Intrinsic `
  -Cam1Intrinsic $cam1Intrinsic
if ($LASTEXITCODE -ne 0) { throw "Constrained stereo workflow failed: $LASTEXITCODE" }
```

首次运行不加 `-ArchiveExistingOutputs`。如果这两个新输出目录中已有上一次失败的部分结果，
保留证据并重跑的方法是只在最后一行参数后增加：

```powershell
  -Cam1Intrinsic $cam1Intrinsic `
  -ArchiveExistingOutputs
```

脚本会先验证 stillness 绑定的两份内参 SHA256，再生成 `pairs.csv`，只有配对状态为 `ready`
才调用外参求解；因此不会再出现 mismatch 后继续读取不存在文件所引发的连锁 Null 错误。

当前装配采用 `25 mm` 名义基线和 `5°` 名义夹角，只作为结果 sanity check，不应写成求解器硬约束。
正式接受仍以脚本的 stereo RMS、逐对平移离散度、`tz` 随深度漂移等数值门限为准。

## 8. 失败时查看证据

```powershell
$base = 'D:\prg\prg_cam\build\cam1_replacement_20260820_run01'
Get-ChildItem -LiteralPath (Join-Path $base '16_stereo_solve_k1k2') -Force |
  Select-Object Name,Length,LastWriteTime
Get-ChildItem -LiteralPath (Join-Path $base '16_stereo_solve_k1k2') `
  -Filter '*.rejected.json' -File -ErrorAction SilentlyContinue |
  ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }
Get-Content -LiteralPath (Join-Path $base '15_stereo_train_pairs_k1k2\pairing_summary.json') `
  -Raw -Encoding UTF8
```

如果任一内参 holdout 失败，停止在该相机，不生成 stillness。若两相机 holdout 都通过但外参仍因
深度漂移失败，则保留 `16_stereo_solve_k1k2` 的 rejected JSON；这说明问题已不再能简单归因于
`k3/k4` 过拟合，需要进一步比较点序、板平面误差或相机同步，而不是重新采集 `04_stereo_train`。
