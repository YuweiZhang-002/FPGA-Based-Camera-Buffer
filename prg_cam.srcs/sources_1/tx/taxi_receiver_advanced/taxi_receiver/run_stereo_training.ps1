[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PythonExe,

    [Parameter(Mandatory = $true)]
    [string]$TrainRoot,

    [Parameter(Mandatory = $true)]
    [string]$StaticAudit,

    [Parameter(Mandatory = $true)]
    [string]$PairsAudit,

    [Parameter(Mandatory = $true)]
    [string]$SolveRoot,

    [Parameter(Mandatory = $true)]
    [string]$Cam0Intrinsic,

    [Parameter(Mandatory = $true)]
    [string]$Cam1Intrinsic,

    [ValidateRange(6, 1000)]
    [int]$MinPairs = 20,

    [switch]$ArchiveExistingOutputs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$receiverRoot = $PSScriptRoot
$stillnessPath = Join-Path $StaticAudit 'stillness_config.json'
$pairsPath = Join-Path $PairsAudit 'pairs.csv'
$pairingSummaryPath = Join-Path $PairsAudit 'pairing_summary.json'
$extrinsicsPath = Join-Path $SolveRoot 'cam0_to_new_cam1_extrinsics.json'
$trainingReportPath = Join-Path $SolveRoot 'training_pairs.csv'
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

function Assert-FileExists {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label does not exist: $Path"
    }
}

function Assert-DirectoryExists {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label does not exist: $Path"
    }
}

function Prepare-OutputDirectory {
    param([string]$Path, [string]$Label)

    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw "$Label output path is not a directory: $Path"
        }
        $existing = @(Get-ChildItem -LiteralPath $Path -Force)
        if ($existing.Count -gt 0) {
            if (-not $ArchiveExistingOutputs) {
                throw (
                    "$Label output is not empty: $Path. " +
                    "Rerun this script with -ArchiveExistingOutputs to preserve " +
                    "the partial output and start cleanly."
                )
            }
            $archivePath = "${Path}_failed_${timestamp}"
            if (Test-Path -LiteralPath $archivePath) {
                throw "$Label archive path already exists: $archivePath"
            }
            Move-Item -LiteralPath $Path -Destination $archivePath
            Write-Host "$Label previous output archived: $archivePath"
        }
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    if (@(Get-ChildItem -LiteralPath $Path -Force).Count -ne 0) {
        throw "$Label output is not empty after preparation: $Path"
    }
}

Assert-FileExists -Path $PythonExe -Label 'Python executable'
Assert-DirectoryExists -Path $TrainRoot -Label 'Stereo training dataset'
Assert-DirectoryExists -Path (Join-Path $TrainRoot 'cam0') -Label 'CAM0 training lane'
Assert-DirectoryExists -Path (Join-Path $TrainRoot 'cam1') -Label 'CAM1 training lane'
Assert-FileExists -Path $Cam0Intrinsic -Label 'CAM0 intrinsic'
Assert-FileExists -Path $Cam1Intrinsic -Label 'CAM1 intrinsic'
Assert-FileExists -Path $stillnessPath -Label 'Stillness configuration'

$cam0Frames = @(
    Get-ChildItem -LiteralPath (Join-Path $TrainRoot 'cam0') -Filter '*.pgm' -File
).Count
$cam1Frames = @(
    Get-ChildItem -LiteralPath (Join-Path $TrainRoot 'cam1') -Filter '*.pgm' -File
).Count
if ($cam0Frames -eq 0 -or $cam1Frames -eq 0) {
    throw "Stereo training images are missing: CAM0=$cam0Frames CAM1=$cam1Frames"
}

$cam0Hash = (Get-FileHash -LiteralPath $Cam0Intrinsic -Algorithm SHA256).Hash
$cam1Hash = (Get-FileHash -LiteralPath $Cam1Intrinsic -Algorithm SHA256).Hash
$stillness = Get-Content -LiteralPath $stillnessPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$boundCam0Hash = [string]$stillness.intrinsics.cam0.sha256
$boundCam1Hash = [string]$stillness.intrinsics.cam1.sha256

if ($cam0Hash -ne $boundCam0Hash.ToUpperInvariant()) {
    throw (
        "CAM0 provenance mismatch before pairing. Input: $Cam0Intrinsic " +
        "SHA256=$cam0Hash; stillness: $stillnessPath " +
        "binds SHA256=$boundCam0Hash. Use the intrinsic that generated the " +
        "stillness file, or regenerate stillness first."
    )
}
if ($cam1Hash -ne $boundCam1Hash.ToUpperInvariant()) {
    throw (
        "CAM1 provenance mismatch before pairing. Input: $Cam1Intrinsic " +
        "SHA256=$cam1Hash; stillness: $stillnessPath " +
        "binds SHA256=$boundCam1Hash. Use the intrinsic that generated the " +
        "stillness file, or regenerate stillness first."
    )
}

Write-Host "CAM0 intrinsic: $Cam0Intrinsic"
Write-Host "CAM0 SHA256:    $cam0Hash"
Write-Host "CAM1 intrinsic: $Cam1Intrinsic"
Write-Host "CAM1 SHA256:    $cam1Hash"
Write-Host "Training frames: CAM0=$cam0Frames CAM1=$cam1Frames"
Write-Host 'Intrinsic/stillness provenance: PASS' -ForegroundColor Green

Prepare-OutputDirectory -Path $PairsAudit -Label 'Stereo pairing'
Prepare-OutputDirectory -Path $SolveRoot -Label 'Stereo solve'

$env:PYTHONDONTWRITEBYTECODE = '1'
Push-Location -LiteralPath $receiverRoot
try {
    & $PythonExe .\build_stereo_pairs.py $TrainRoot `
        --cam0-intrinsics $Cam0Intrinsic `
        --cam1-intrinsics $Cam1Intrinsic `
        --output-root $PairsAudit `
        --stillness-config $stillnessPath `
        --max-center-dt-ms 33.5 `
        --min-cam0-edge-margin-px 12 `
        --min-pairs $MinPairs
    $pairExitCode = $LASTEXITCODE
    if ($pairExitCode -ne 0) {
        throw "Stereo training pairing failed with exit code $pairExitCode"
    }

    Assert-FileExists -Path $pairsPath -Label 'Accepted stereo pairs CSV'
    Assert-FileExists -Path $pairingSummaryPath -Label 'Pairing summary'
    $pairingSummary = Get-Content -LiteralPath $pairingSummaryPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    if ([string]$pairingSummary.status -ne 'ready') {
        throw "Pairing summary status is not ready: $($pairingSummary.status)"
    }

    & $PythonExe .\calibrate_binary_stereo.py $pairsPath `
        --pairing-summary $pairingSummaryPath `
        --cam0-intrinsics $Cam0Intrinsic `
        --cam1-intrinsics $Cam1Intrinsic `
        --stillness-config $stillnessPath `
        --output $extrinsicsPath `
        --report $trainingReportPath `
        --min-pairs $MinPairs
    $solveExitCode = $LASTEXITCODE
    if ($solveExitCode -ne 0) {
        throw "Stereo solve failed with exit code $solveExitCode"
    }

    Assert-FileExists -Path $extrinsicsPath -Label 'Stereo extrinsics'
    $extrinsics = Get-Content -LiteralPath $extrinsicsPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $translation = @($extrinsics.t_cam1_from_cam0_mm)
    $rotationMatrix = $extrinsics.R_cam1_from_cam0
    if ($translation.Count -ne 3 -or $null -eq $rotationMatrix) {
        throw "Extrinsics transform fields are missing from $extrinsicsPath"
    }
    $baseline = [Math]::Sqrt(
        $translation[0] * $translation[0] +
        $translation[1] * $translation[1] +
        $translation[2] * $translation[2]
    )
    $trace = (
        [double]$rotationMatrix[0][0] +
        [double]$rotationMatrix[1][1] +
        [double]$rotationMatrix[2][2]
    )
    $rotationDegrees = (
        [Math]::Acos([Math]::Max(-1.0, [Math]::Min(1.0, ($trace - 1.0) / 2.0))) *
        180.0 / [Math]::PI
    )

    Write-Host 'Stereo training and solve: PASS' -ForegroundColor Green
    Write-Host "Pairs:      $pairsPath"
    Write-Host "Extrinsics: $extrinsicsPath"
    Write-Host ("baseline={0:N3} mm rotation={1:N3} deg" -f $baseline, $rotationDegrees)
}
finally {
    Pop-Location
}
