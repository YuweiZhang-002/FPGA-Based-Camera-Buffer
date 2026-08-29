# 双相机外参标定执行手册

> **当前执行状态：120°+120°技术归档，外参受控不发布。** 当前两份K1/K2/K3
> 内参及其独立holdout已经存在，`build/stereo_final_20260821/01_pairs`也已产生23个
> `ready` pairs；数值求解输出保存在
> `build/stereo_final_20260821/02_solve/cam0_to_new_cam1_extrinsics.rejected.json`。
> 该候选为`quality.status=unacceptable`、`publishable=false`，原因是tx/ty未通过
> depth-independence门。因此本文下方历史命令只作复刻结构参考，本轮不得继续采集、
> 不得执行V1/V2挽救，也不得生成或提升正式`cam0_to_cam1_extrinsics.json`。
> 历史full44/mask26 `release`组合仍必须被当前严格点集门拒绝
> （`taxi_receiver/extrinsic_config.py:61-177`）。

本文适用于当前 `cam0 + cam1`、640×480 二值图像、4×11 非对称圆点板和
OpenCV fisheye 模型。外参作为独立配置发布；不会修改或重新优化原有内参。
历史污染/非污染模型的完整参数和数值域对照见
[`CALIBRATION_MODEL_COMPARISON.md`](CALIBRATION_MODEL_COMPARISON.md)。

## 1. 固定输入和变换方向

以下是历史单相机发布来源，不等于当前严格双目输入已经兼容：

| 相机 | 来源 | SHA256 |
|---|---|---|
| cam0 | `build\attempt12_cam0_calibration_audit_full44\cam0_intrinsics_full44.json` | `9FCD510B1ADB22BB1FF8801AD487928345EDB8CDB25A5F241C49135DFBAD65F5` |
| cam1 | `build\attempt11_cam1_calibration_audit_mask26\cam1_intrinsics_mask26.json` | `CDBA3CA3069225803D681C9DE33A6305E884BA6D5CC49DFAF76395182F829F25` |

Attempt9 是旧 cam1 配置，独立验证不通过；不能替代上表的 cam1。Attempt11
实际是 cam1，Attempt12 实际是 cam0。

选中这两份配置的独立证据已经内嵌在
`calibration_configs/release_manifest.json`，不依赖被忽略的 `build` 目录长期
保留：

| 可读名称 | 证据来源（旧编号） | 训练结果 | 固定 K/D 独立验证 |
|---|---|---|---|
| CAM0 (Non-polluted Calibration) | Attempt12 | 26 views，RMS 0.419823 px | V1 P95/max 0.649444/0.979780 px；V2 0.561059/0.785472 px |
| CAM1 (Polluted Calibration, point26 removed) | Attempt11；干净板验证为 Attempt15 | 29 views，RMS 0.359865 px | clean full-44 V1 P95/max 0.585397/0.739774 px；V2 0.433945/0.481036 px |

外参文件始终保存：

```text
X_cam1 = R_cam1_from_cam0 * X_cam0 + t_cam1_from_cam0
```

平移单位为 mm。cam1 内参训练时删除过索引26；Attempt15虽用干净板完整44点通过
固定内参验证，当前外参阶段也不能据此擅自把其计算点集改写为`[0..43]`。

Attempt15证明固定cam1 K/D可以在clean-board full44检测上通过单相机holdout，
但不会重写`cam1_intrinsics_mask26.json`中的`excluded_point_indices=[26]`。
因此当前严格求解器仍把它解析为43点，不能与cam0 full44配对。cam0 鱼眼模型在
图像角点外只剩约2.33°单调余量这一历史风险仍成立，但它不是绕过点集门的理由。

不得重新采用的历史候选也保存在 manifest 中。`source.path`、
`validation_evidence[].source_path` 和
`rejected_candidates[].validation[].source_path` 是来源标签，不要求相应
`build` 文件在运行期继续存在；判定所需的数值已经随受控 manifest 保存：

| 可读名称 | 证据来源（旧编号） | 历史证据 | 决策 |
|---|---|---|---|
| CAM1 (Polluted Calibration, full44) | Attempt9 | holdout P95 1.202277 px、max 1.532513 px | 拒绝 |
| CAM0 (Polluted Calibration, point26 removed) | Attempt10 | 没有当前格式的固定 K/D 独立发布证据 | 拒绝 |
| CAM1 (Non-polluted Calibration, full44) | Attempt13 | V1/V2 max 22157.218986/21367.601555 px | 拒绝该 K/D；图片保留为干净板压力数据 |
| CAM1 (Non-polluted Calibration, corner supplement) | Attempt14 | 训练 RMS 0.286566 px，但 V1/V2 max 7110.917592/6849.170243 px | 拒绝该 K/D；图片保留为边角压力数据 |

历史数据清单同样固化在 manifest：

| 证据来源（旧编号） | 相机 | 会话数 | PGM/RAW/JSON 各自数量 | 用途 |
|---|---:|---:|---:|---|
| 9 | cam1 | 2 | 2,539 | 旧模型对照 |
| 10 | cam0 | 3 | 6,210 | 旧污染板/mask26 对照 |
| 11 | cam1 | 3 | 6,013 | 当前 cam1 内参来源 |
| 12 | cam0 | 3 | 4,059 | 当前 cam0 内参来源 |
| 13 | cam1 | 3 | 3,764 | 干净板验证与压力数据 |
| 14 | cam1 | 1 | 1,243 | 边角补充与压力数据 |
| 合计 | — | 15 | 23,828 | 不能直接求双目 R/T |

上述23,828个发布帧的元数据审计结果均为 `COMPLETE`、`missing_count=0`、
`bit_order=msb_first`，且没有 CRC、overflow 或 sync 错误。
历史 Attempt12/13 train 的帧中心周期中位数为66.6461 ms，单帧首末行抓包
跨度中位数为62.1190 ms；因此后续 `33.5 ms` 只作为约半周期的候选配对上限，
仍必须结合静止窗口，不能把抓包时间当成硬件曝光同步。

首次执行且 canonical 副本尚不存在时，将这两份构建输出按固定 SHA 原样提升到
受控配置目录：

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  'D:\prg\prg_cam\prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver\promote_stereo_intrinsics.ps1' `
  -RepoRoot 'D:\prg\prg_cam'
if ($LASTEXITCODE -ne 0) {
    throw "Intrinsic promotion failed with exit code $LASTEXITCODE"
}
```

脚本拒绝错误 SHA、错误 `camera_id` 和覆盖内容不同的已有配置。成功后正式流程
使用 `calibration_configs` 下的副本；其字节和 SHA 与上表来源完全相同。
manifest 中的 canonical `path` 相对于 manifest 所在目录。canonical 副本一旦
存在，脚本每次仍验证其 SHA 和 `camera_id`，但不再要求被忽略的 `build` 来源
继续存在，因此可在构建输出清理后幂等重跑。manifest 中历史 `source` 与
`evidence` 路径则相对于仓库根目录，仅作为来源标签。

## 2. 一次性 PowerShell 变量

```powershell
$repo = 'D:\prg\prg_cam'
$receiverRoot = Join-Path $repo `
  'prg_cam.srcs\sources_1\tx\taxi_receiver_advanced\taxi_receiver'
$python = `
  'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'

# 以下refit2分支只保留为历史诊断复放示例，不是当前120°+120°归档输入。
# 当前已接受K/D位于build/cam1_replacement_20260820_run01的17/19 solve目录，
# 但本轮不重新求解或发布外参；正式阶段2手册将给出未来复刻时的参数化入口。
$intrinsicSet = 'refit2'   # 'refit2' only; legacy 'release' is blocked

switch ($intrinsicSet) {
  'refit2' {
    # 2026-08-19 用 attempt18 的 150 张共同帧重标；cam0 限制为 2 项畸变。
    # cam0 单调裕量 29.13deg -> 89.90deg。尚未进入 release_manifest.json，
    # 仅供诊断，不可发布。
    $cam0Intrinsic = Join-Path $receiverRoot `
      'calibration_configs\cam0_intrinsics_refit2_k1k2.json'
    $cam1Intrinsic = Join-Path $receiverRoot `
      'calibration_configs\cam1_intrinsics_refit2_k1k2k3k4.json'
  }
  'release' {
    throw (
      'Blocked: legacy release pair is cam0 full44 versus cam1 mask26. ' +
      'Current strict point-set validation forbids this stereo pairing.'
    )
  }
  default { throw "unknown intrinsic set: $intrinsicSet" }
}
foreach ($p in @($cam0Intrinsic, $cam1Intrinsic)) {
  if (!(Test-Path -LiteralPath $p -PathType Leaf)) { throw "missing intrinsics: $p" }
}
Write-Host "intrinsics = $intrinsicSet"

$staticRoot = Join-Path $repo 'images\new_Temp\attempt16_extrinsics_static'
$trainRoot = Join-Path $repo 'images\new_Temp\attempt16_extrinsics_train'
$holdoutV1Root = Join-Path $repo 'images\new_Temp\attempt16_extrinsics_holdout_v1'
$holdoutV2Root = Join-Path $repo 'images\new_Temp\attempt16_extrinsics_holdout_v2'
$auditRoot = Join-Path $repo 'build\attempt16_extrinsics_audit'

$staticAudit = Join-Path $auditRoot '00_static'
$trainPairsAudit = Join-Path $auditRoot '01_train_pairs'
$solveAudit = Join-Path $auditRoot '02_solve'
$v1PairsAudit = Join-Path $auditRoot '03_holdout_v1_pairs'
$v1Audit = Join-Path $auditRoot '04_holdout_v1_validation'
$v2PairsAudit = Join-Path $auditRoot '05_holdout_v2_pairs'
$v2Audit = Join-Path $auditRoot '06_holdout_v2_validation'

Set-Location $receiverRoot
```

检查内参身份，输出必须与第1节完全一致：

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath $cam0Intrinsic
Get-FileHash -Algorithm SHA256 -LiteralPath $cam1Intrinsic
```

在采集任何双目Training之前，调用当前Python实现本身解析物点集合。该检查不复制
Python规则，也不取交集；任何非零退出都必须停下：

```powershell
$pointSetProbe = @'
import sys
from pathlib import Path
from taxi_receiver.extrinsic_config import (
    intrinsic_point_set,
    validate_intrinsic_pair,
)

doc0, _, _, doc1, _, _ = validate_intrinsic_pair(
    Path(sys.argv[1]),
    Path(sys.argv[2]),
)
points0 = intrinsic_point_set(doc0)
points1 = intrinsic_point_set(doc1)
print(
    'INTRINSIC_POINT_SET_PASS ' +
    f'count={len(points0)} indices={sorted(points0)} ' +
    f'cam1_equal={points1 == points0}'
)
'@

$pointSetOutput = @(
  $pointSetProbe |
    & $python - $cam0Intrinsic $cam1Intrinsic 2>&1
)
$pointSetExit = $LASTEXITCODE
$pointSetOutput | ForEach-Object { Write-Host ([string]$_) }

if ($pointSetExit -ne 0) {
  throw "Intrinsic point-set identity failed with exit code $pointSetExit"
}
if (-not ($pointSetOutput -match '^INTRINSIC_POINT_SET_PASS ')) {
  throw 'Intrinsic point-set check returned no PASS identity line'
}
```

预期的唯一成功签名是`INTRINSIC_POINT_SET_PASS`，并且两机显示相同count/indices。
历史`release`组合应在这里明确失败；这正是修正后的预期，而不是脚本故障。

## 3. 确认网卡和空目录

```powershell
& $python -m taxi_receiver.cli --list
if ($LASTEXITCODE -ne 0) {
    throw "Interface enumeration failed with exit code $LASTEXITCODE"
}
```

当前曾使用过的接口为：

```powershell
$interface = '\Device\NPF_{6BDDE37E-7DCA-4078-98B0-E374EFE04E7C}'
```

必须根据本次 `--list` 和流量确认，不能只因 GUID 仍存在就盲用。每次采集及其
整套审计输出均使用全新目录；下面检查会同时拒绝复用非空图像根和非空审计根：

```powershell
$datasetRoots = @($staticRoot, $trainRoot, $holdoutV1Root, $holdoutV2Root)
$attemptRoots = @($datasetRoots) + @($auditRoot)
foreach ($root in $attemptRoots) {
    if (Test-Path -LiteralPath $root) {
        $existing = Get-ChildItem -LiteralPath $root -Force -Recurse |
          Select-Object -First 1
        if ($null -ne $existing) {
            throw "Refusing to reuse non-empty Attempt16 root: $root"
        }
    }
}
$attemptRoots | ForEach-Object {
    New-Item -ItemType Directory -Force -Path $_ | Out-Null
}
```

任何阶段失败后，不要在这些固定路径上覆盖重跑；先保留本轮证据，再把所有
`attempt16` 目录变量改成新的 attempt/run 后缀并重新执行空目录检查。

## 4. 通用双相机采集命令

每次只替换 `$captureRoot`。同一个接收进程必须同时收到 cam0 和 cam1：

```powershell
$captureRoot = $staticRoot

.\run_receiver.ps1 `
  -Interface $interface `
  -ImagesRoot $captureRoot `
  -ExpectedRows 480 `
  -QueueDepth 65536 `
  -PcapBufferSize 67108864 `
  -FrameOutputQueueDepth 256 `
  -CameraIds '0,1' `
  -SplitByCamera on `
  -ImagePolicy strict `
  -PublishFrames complete `
  -PublishImages process `
  -PublisherQueueDepth 256 `
  -CsvQueueDepth 65536 `
  -CsvBackpressure drop `
  -BitOrder msb_first `
  -SessionAudit off `
  -CrcMode enabled `
  -PythonExe $python
if ($LASTEXITCODE -ne 0) {
    throw "Receiver capture failed with exit code $LASTEXITCODE"
}
```

用 `Ctrl+C` 正常结束，并等待 Final Report。一次数据只有在以下条件满足时才可
进入标定：

- cam0、cam1 的 PGM/RAW/JSON 数量相等且均非零；
- `ps_drop`、capture queue drops、lane queue drops 为0；
- publisher/callback failure 为0；
- CRC、sync、length、overflow 错误为0；
- 最好 `csv_rows_dropped=0`。新 sidecar JSON 已包含抓包时间，CSV 少量丢失
  不再破坏新数据配对，但该会话的逐行审计将不完整。

快速计数：

```powershell
foreach ($cam in 0, 1) {
    $camRoot = Join-Path $captureRoot "cam$cam"
    $pgm = @(Get-ChildItem -LiteralPath $camRoot -Filter '*.pgm' -File `
      -ErrorAction SilentlyContinue).Count
    $raw = @(Get-ChildItem -LiteralPath $camRoot -Filter '*.raw' -File `
      -ErrorAction SilentlyContinue).Count
    $json = @(Get-ChildItem -LiteralPath $camRoot -Filter '*.json' -File `
      -ErrorAction SilentlyContinue).Count
    Write-Host "cam$cam PGM=$pgm RAW=$raw JSON=$json"
}
```

## 5. 阶段A：静态噪声和 Eq.8 阈值

1. 标定板完整出现在两台相机内。
2. 板和机架完全固定，不做任何移动。
3. 将 `$captureRoot=$staticRoot`，运行第4节命令至少20秒；目标是两边各有
   至少200帧完整44点检测。
4. 计算两台相机独立的相邻帧阈值与窗口总漂移阈值：

```powershell
& $python .\build_stereo_pairs.py $staticRoot `
  --cam0-intrinsics $cam0Intrinsic `
  --cam1-intrinsics $cam1Intrinsic `
  --output-root $staticAudit `
  --estimate-stillness-only `
  --window-frames 5 `
  --min-static-frames 200
if ($LASTEXITCODE -ne 0) {
    throw "Static stillness estimation failed with exit code $LASTEXITCODE"
}
```

关键输出：

```text
00_static/stillness_config.json
00_static/frames_cam0.csv
00_static/frames_cam1.csv
```

阈值使用 `median + 3×1.4826×MAD`；正式训练必须引用这份 JSON，不应手工
把阈值调大来掩盖移动。

## 6. 阶段B：训练姿态采集

将 `$captureRoot=$trainRoot` 后运行第4节命令。每个姿态：

1. 只移动标定板，机架、镜头、焦距保持固定；
2. 两边必须同时完整看到44点；
3. 停止后保持1–2秒，再移动到下一姿态；
4. 覆盖中央、左右、上下、近中远、俯仰、偏航和板内旋转；
5. 目标25–30个有效稳定姿态；避免 cam0 极端四角和过大倾角。

构建训练帧对：

```powershell
& $python .\build_stereo_pairs.py $trainRoot `
  --cam0-intrinsics $cam0Intrinsic `
  --cam1-intrinsics $cam1Intrinsic `
  --output-root $trainPairsAudit `
  --stillness-config (Join-Path $staticAudit 'stillness_config.json') `
  --max-center-dt-ms 33.5 `
  --min-cam0-edge-margin-px 12 `
  --min-pairs 20
if ($LASTEXITCODE -ne 0) {
    throw "Training pair construction failed with exit code $LASTEXITCODE"
}
```

配对使用每帧首末抓包时间的中心，不要求两台相机 `frame_id` 相等。必须同时
通过5帧静止窗口；同一块静止平台只保留时间差最小、漂移最小的一对，返回到
几何上相同的旧姿态也不会重复计数。cam0 圆点中心距画面边界必须至少12 px。输出：

```text
01_train_pairs/pairs.csv
01_train_pairs/pairing_summary.json
01_train_pairs/frames_cam0.csv
01_train_pairs/frames_cam1.csv
```

`pairs.csv` 同时保留同一静止平台内未入选的候选行，并以
`same_static_pose_not_representative` 标记。

## 7. 阶段C：固定内参求外参

```powershell
if (Test-Path -LiteralPath $solveAudit) {
    $existingSolveOutput = Get-ChildItem -LiteralPath $solveAudit -Force -Recurse |
      Select-Object -First 1
    if ($null -ne $existingSolveOutput) {
        throw "Refusing to overwrite non-empty solve audit root: $solveAudit"
    }
}
New-Item -ItemType Directory -Force -Path $solveAudit | Out-Null
$extrinsics = Join-Path $solveAudit 'cam0_to_cam1_extrinsics.json'

& $python .\calibrate_binary_stereo.py `
  (Join-Path $trainPairsAudit 'pairs.csv') `
  --pairing-summary (Join-Path $trainPairsAudit 'pairing_summary.json') `
  --cam0-intrinsics $cam0Intrinsic `
  --cam1-intrinsics $cam1Intrinsic `
  --stillness-config (Join-Path $staticAudit 'stillness_config.json') `
  --output $extrinsics `
  --report (Join-Path $solveAudit 'training_pairs.csv') `
  --min-pairs 20
if ($LASTEXITCODE -ne 0) {
    throw "Stereo calibration failed with exit code $LASTEXITCODE"
}
```

求解器执行：

1. 两边分别用固定内参 `undistortPoints + ITERATIVE/IPPE + LM` 解板位姿；
2. 用 Eq.7 形成逐姿态 cam0→cam1 变换并做 SO(3)/平移鲁棒离群检查；
3. 自动处理圆点顺序的180°候选；
4. 对入选帧对执行 `cv2.fisheye.stereoCalibrate`；
5. 只启用 `CALIB_FIX_INTRINSIC | CALIB_CHECK_COND`，并检查返回的 K/D 与输入
   逐项不变；
6. 外参 JSON 锚定两份内参、帧对清单、配对摘要和静止配置的 SHA256。

cam0 数值域警告会让训练配置标记为 `limited`，这不是求解失败。只有两轮独立
holdout 都通过且明确接受该边缘限制后，才可把此外参冻结为发布候选。

## 8. 阶段D：独立 Holdout V1

重新启动接收器，使用 `$captureRoot=$holdoutV1Root` 和15–20个未出现在训练集
的新姿态。然后：

```powershell
& $python .\build_stereo_pairs.py $holdoutV1Root `
  --cam0-intrinsics $cam0Intrinsic `
  --cam1-intrinsics $cam1Intrinsic `
  --output-root $v1PairsAudit `
  --stillness-config (Join-Path $staticAudit 'stillness_config.json') `
  --max-center-dt-ms 33.5 `
  --min-pairs 15
if ($LASTEXITCODE -ne 0) {
    throw "Holdout V1 pair construction failed with exit code $LASTEXITCODE"
}

& $python .\validate_binary_extrinsics.py $extrinsics `
  (Join-Path $v1PairsAudit 'pairs.csv') `
  --pairing-summary (Join-Path $v1PairsAudit 'pairing_summary.json') `
  --cam0-intrinsics $cam0Intrinsic `
  --cam1-intrinsics $cam1Intrinsic `
  --stillness-config (Join-Path $staticAudit 'stillness_config.json') `
  --output-root $v1Audit `
  --min-holdout-pairs 15
if ($LASTEXITCODE -ne 0) {
    throw "Holdout V1 validation failed with exit code $LASTEXITCODE"
}
```

## 9. 阶段E：独立 Holdout V2

再次独立启动、停止接收器，使用 `$captureRoot=$holdoutV2Root` 和另一组15–20
个新姿态：

```powershell
& $python .\build_stereo_pairs.py $holdoutV2Root `
  --cam0-intrinsics $cam0Intrinsic `
  --cam1-intrinsics $cam1Intrinsic `
  --output-root $v2PairsAudit `
  --stillness-config (Join-Path $staticAudit 'stillness_config.json') `
  --max-center-dt-ms 33.5 `
  --min-pairs 15
if ($LASTEXITCODE -ne 0) {
    throw "Holdout V2 pair construction failed with exit code $LASTEXITCODE"
}

& $python .\validate_binary_extrinsics.py $extrinsics `
  (Join-Path $v2PairsAudit 'pairs.csv') `
  --pairing-summary (Join-Path $v2PairsAudit 'pairing_summary.json') `
  --cam0-intrinsics $cam0Intrinsic `
  --cam1-intrinsics $cam1Intrinsic `
  --stillness-config (Join-Path $staticAudit 'stillness_config.json') `
  --output-root $v2Audit `
  --min-holdout-pairs 15
if ($LASTEXITCODE -ne 0) {
    throw "Holdout V2 validation failed with exit code $LASTEXITCODE"
}
```

每轮输出 `holdout_summary.json`、`holdout_pairs.csv`、最多12对整流诊断图和
`rectified_montage.png`。验证会拒绝训练图片哈希出现在 holdout 中。

## 10. 发布门槛和反馈处理

V1、V2 都必须为 `status=pass`。默认门槛：

- 至少15个独立帧对；
- 双向跨相机重投影 RMSE：median≤0.8 px、P95≤1.2 px、max≤1.5 px；
- 至少90%姿态≤1.2 px；
- 整流纵向误差 P95≤1.2 px；
- 旋转离散度中位数≤0.5°；
- 平移离散度中位数≤基线1%（并设0.5 mm数值下限）；
- 训练/holdout 图像哈希零重叠。

常见反馈：

| 现象 | 首要检查 |
|---|---|
| 一边没有图像增长 | 双相机同时发送、cam_id 路由和接口选择 |
| `missing_complete_frame_timing` | sidecar 是否为新版本；旧数据需完整 `rows_v2.csv` |
| 静止帧为0 | 板是否保持足够久；先重做固定板200帧噪声实验 |
| PnP低误差但 R/T 离散大 | 时间配对、点序、机架松动 |
| 平移整体按比例偏差 | 实测打印板20 mm间距 |
| 误差随倾角/边缘增大 | Eq.10圆心偏差或 cam0 数值域边界 |
| 训练好、V1/V2差 | 姿态覆盖不足、过拟合或机械/温度变化 |

历史 `images\new_Temp` 只有单相机分批数据，所有15个会话均没有 cam0/cam1
时间重叠；最近两个异相机会话仍相隔672.4秒。因此这些数据只能用于内参和
压力测试，不能生成或发布 cam0→cam1 外参。
