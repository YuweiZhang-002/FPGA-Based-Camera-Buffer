[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PythonExe,

    [Parameter(Mandatory = $true)]
    [string]$Cam0Intrinsic,

    [Parameter(Mandatory = $true)]
    [string]$Cam1Intrinsic,

    [Parameter(Mandatory = $true)]
    [string]$Cam0Holdout,

    [Parameter(Mandatory = $true)]
    [string]$Cam1Holdout,

    [Parameter(Mandatory = $true)]
    [string]$Cam0ValidationRoot,

    [Parameter(Mandatory = $true)]
    [string]$Cam1ValidationRoot,

    [Parameter(Mandatory = $true)]
    [string]$StaticRoot,

    [Parameter(Mandatory = $true)]
    [string]$StaticAudit,

    [switch]$ArchiveExistingOutputs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$receiverRoot = $PSScriptRoot
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

function Assert-File {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label is missing: $Path"
    }
}

function Assert-Directory {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label is missing: $Path"
    }
}

function Move-OutputAside {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label path is not a directory: $Path"
    }
    if (@(Get-ChildItem -LiteralPath $Path -Force).Count -eq 0) {
        return
    }
    if (-not $ArchiveExistingOutputs) {
        throw (
            "$Label output is non-empty or stale: $Path. " +
            'Rerun with -ArchiveExistingOutputs to preserve it and continue.'
        )
    }
    $archive = "${Path}_stale_${timestamp}"
    if (Test-Path -LiteralPath $archive) {
        throw "$Label archive already exists: $archive"
    }
    Move-Item -LiteralPath $Path -Destination $archive
    Write-Host "$Label archived: $archive"
}

function Assert-ConstrainedIntrinsic {
    param([string]$Path, [int]$CameraId)
    Assert-File -Path $Path -Label "CAM$CameraId intrinsic"
    $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$document.camera_id -ne $CameraId) {
        throw "CAM$CameraId intrinsic camera_id mismatch: $Path"
    }
    if ([string]$document.quality.status -ne 'acceptable') {
        throw "CAM$CameraId intrinsic is not acceptable: $($document.quality.status)"
    }
    $coefficients = @($document.dist_coeffs)
    if ($coefficients.Count -ne 4 -or [Math]::Abs([double]$coefficients[3]) -gt 1e-12) {
        throw "CAM$CameraId intrinsic does not fix k4 at zero: $Path"
    }
    if ('k4' -notin @($document.solver_constraints.fixed_distortion_coefficients)) {
        throw "CAM$CameraId intrinsic JSON does not declare fixed k4: $Path"
    }
}

function Test-HoldoutBinding {
    param([string]$Summary, [string]$Intrinsic, [int]$CameraId)
    if (-not (Test-Path -LiteralPath $Summary -PathType Leaf)) {
        return $false
    }
    $document = Get-Content -LiteralPath $Summary -Raw -Encoding UTF8 | ConvertFrom-Json
    $expectedHash = (Get-FileHash -LiteralPath $Intrinsic -Algorithm SHA256).Hash
    $recordedHash = ([string]$document.calibration.sha256).ToUpperInvariant()
    if ($recordedHash -ne $expectedHash) {
        return $false
    }
    if ([int]$document.calibration.camera_id -ne $CameraId) {
        throw "CAM$CameraId holdout summary camera_id mismatch: $Summary"
    }
    if ([string]$document.status -ne 'pass') {
        throw "CAM$CameraId independent holdout status is not pass: $($document.status)"
    }
    return $true
}

function Ensure-Holdout {
    param(
        [int]$CameraId,
        [string]$Intrinsic,
        [string]$Holdout,
        [string]$OutputRoot
    )
    Assert-Directory -Path $Holdout -Label "CAM$CameraId holdout dataset"
    $summary = Join-Path $OutputRoot 'holdout_summary.json'
    if (Test-HoldoutBinding -Summary $summary -Intrinsic $Intrinsic -CameraId $CameraId) {
        Write-Host "CAM$CameraId independent holdout: PASS (reused)" -ForegroundColor Green
        return
    }

    Move-OutputAside -Path $OutputRoot -Label "CAM$CameraId validation"
    & $PythonExe .\validate_binary_calibration.py $Intrinsic $Holdout `
        --output-root $OutputRoot `
        --sample-count 30 `
        --min-holdout-views 15 `
        --median-rmse-px 0.8 `
        --p95-rmse-px 1.2 `
        --maximum-rmse-px 1.5 `
        --required-pass-fraction 0.90
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "CAM$CameraId independent holdout failed with exit code $exitCode"
    }
    if (-not (Test-HoldoutBinding -Summary $summary -Intrinsic $Intrinsic -CameraId $CameraId)) {
        throw "CAM$CameraId validation completed without a correctly bound summary: $summary"
    }
    Write-Host "CAM$CameraId independent holdout: PASS (generated)" -ForegroundColor Green
}

Assert-File -Path $PythonExe -Label 'Python executable'
Assert-ConstrainedIntrinsic -Path $Cam0Intrinsic -CameraId 0
Assert-ConstrainedIntrinsic -Path $Cam1Intrinsic -CameraId 1
Assert-Directory -Path $StaticRoot -Label 'Static dataset'
Assert-Directory -Path (Join-Path $StaticRoot 'cam0') -Label 'Static CAM0 lane'
Assert-Directory -Path (Join-Path $StaticRoot 'cam1') -Label 'Static CAM1 lane'

$env:PYTHONDONTWRITEBYTECODE = '1'
Push-Location -LiteralPath $receiverRoot
try {
    Ensure-Holdout `
        -CameraId 0 `
        -Intrinsic $Cam0Intrinsic `
        -Holdout $Cam0Holdout `
        -OutputRoot $Cam0ValidationRoot
    Ensure-Holdout `
        -CameraId 1 `
        -Intrinsic $Cam1Intrinsic `
        -Holdout $Cam1Holdout `
        -OutputRoot $Cam1ValidationRoot

    # Always regenerate stillness after both independently bound holdouts pass.
    # A pre-existing file may have been produced after a failed interactive
    # command and therefore cannot prove the required execution order.
    Move-OutputAside -Path $StaticAudit -Label 'Stillness audit'
    & $PythonExe .\build_stereo_pairs.py $StaticRoot `
        --cam0-intrinsics $Cam0Intrinsic `
        --cam1-intrinsics $Cam1Intrinsic `
        --output-root $StaticAudit `
        --estimate-stillness-only `
        --window-frames 5 `
        --min-static-frames 200
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Stillness estimation failed with exit code $exitCode"
    }

    $stillnessPath = Join-Path $StaticAudit 'stillness_config.json'
    Assert-File -Path $stillnessPath -Label 'Stillness configuration'
    $stillness = Get-Content -LiteralPath $stillnessPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $cam0Hash = (Get-FileHash -LiteralPath $Cam0Intrinsic -Algorithm SHA256).Hash
    $cam1Hash = (Get-FileHash -LiteralPath $Cam1Intrinsic -Algorithm SHA256).Hash
    if (([string]$stillness.intrinsics.cam0.sha256).ToUpperInvariant() -ne $cam0Hash) {
        throw 'Generated stillness CAM0 intrinsic hash mismatch'
    }
    if (([string]$stillness.intrinsics.cam1.sha256).ToUpperInvariant() -ne $cam1Hash) {
        throw 'Generated stillness CAM1 intrinsic hash mismatch'
    }
    Write-Host 'Candidate holdouts and stillness: PASS' -ForegroundColor Green
    Write-Host "Stillness: $stillnessPath"
}
finally {
    Pop-Location
}
