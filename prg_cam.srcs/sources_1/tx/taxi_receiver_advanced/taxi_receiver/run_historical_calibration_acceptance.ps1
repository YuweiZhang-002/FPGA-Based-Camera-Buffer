[CmdletBinding()]
param(
    [string]$PythonExe = 'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe',
    [string]$OutputRoot = 'D:\prg\prg_cam\build\calibration_acceptance_20260824',
    [switch]$ArchiveExistingOutputs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$receiverRoot = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $receiverRoot '..\..\..\..\..')).Path
$run20Build = Join-Path $repoRoot 'build\cam1_replacement_20260820_run01'
$run20Images = Join-Path $repoRoot 'images\new_Temp\cam1_replacement_20260820_run01'
$run21Build = Join-Path $repoRoot 'build\stereo_final_20260821'
$run21Images = Join-Path $repoRoot 'images\new_Temp\stereo_final_20260821'
$nominalConfig = Join-Path $receiverRoot 'calibration_configs\rig_nominal_geometry.json'
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

function Prepare-Root {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw "Acceptance output is not a directory: $Path"
        }
        if (@(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0) {
            if (-not $ArchiveExistingOutputs) {
                throw "Acceptance output is not empty: $Path. Use -ArchiveExistingOutputs to preserve it and rerun."
            }
            $archive = "${Path}_previous_${timestamp}"
            Move-Item -LiteralPath $Path -Destination $archive
            Write-Host "Previous acceptance output archived: $archive"
        }
    }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

Assert-File -Path $PythonExe -Label 'Python executable'
Assert-File -Path $nominalConfig -Label 'Nominal rig geometry'
Assert-Directory -Path $run20Build -Label '20 August build evidence'
Assert-Directory -Path $run20Images -Label '20 August image evidence'
Assert-Directory -Path $run21Build -Label '21 August build evidence'
Assert-Directory -Path $run21Images -Label '21 August image evidence'
Prepare-Root -Path $OutputRoot

$intrinsicRoot = Join-Path $OutputRoot '01_intrinsics'
$extrinsicRoot = Join-Path $OutputRoot '02_extrinsics'
New-Item -ItemType Directory -Force -Path $intrinsicRoot, $extrinsicRoot | Out-Null

$intrinsicCases = @(
    [pscustomobject]@{
        Slug = 'run20_cam0_k1k4';
        Intrinsic = Join-Path $run20Build '01_cam0_solve\cam0_intrinsics_120.json';
        Holdout = Join-Path $run20Images '02_cam1_intrinsic_holdout\cam0'
    },
    [pscustomobject]@{
        Slug = 'run20_cam1_k1k4';
        Intrinsic = Join-Path $run20Build '01_cam1_solve\cam1_intrinsics_120.json';
        Holdout = Join-Path $run20Images '02_cam1_intrinsic_holdout\cam1'
    },
    [pscustomobject]@{
        Slug = 'run20_cam0_k1k2';
        Intrinsic = Join-Path $run20Build '10_cam0_k1k2_solve\cam0_intrinsics_k1k2.json';
        Holdout = Join-Path $run20Images '02_cam1_intrinsic_holdout\cam0'
    },
    [pscustomobject]@{
        Slug = 'run20_cam1_k1k2';
        Intrinsic = Join-Path $run20Build '12_cam1_k1k2_solve\cam1_intrinsics_k1k2.json';
        Holdout = Join-Path $run20Images '02_cam1_intrinsic_holdout\cam1'
    },
    [pscustomobject]@{
        Slug = 'run20_cam0_k1k3';
        Intrinsic = Join-Path $run20Build '17_cam0_k1k2k3_solve\cam0_intrinsics_k1k2k3.json';
        Holdout = Join-Path $run20Images '02_cam1_intrinsic_holdout\cam0'
    },
    [pscustomobject]@{
        Slug = 'run20_cam1_k1k3';
        Intrinsic = Join-Path $run20Build '19_cam1_k1k2k3_solve\cam1_intrinsics_k1k2k3.json';
        Holdout = Join-Path $run20Images '02_cam1_intrinsic_holdout\cam1'
    }
)

$env:PYTHONDONTWRITEBYTECODE = '1'
Push-Location -LiteralPath $receiverRoot
try {
    foreach ($case in $intrinsicCases) {
        Assert-File -Path $case.Intrinsic -Label "$($case.Slug) intrinsic"
        Assert-Directory -Path $case.Holdout -Label "$($case.Slug) holdout"
        $caseOutput = Join-Path $intrinsicRoot $case.Slug
        New-Item -ItemType Directory -Force -Path $caseOutput | Out-Null
        Write-Host "`n[INTRINSIC] $($case.Slug)"
        & $PythonExe .\validate_binary_calibration.py $case.Intrinsic $case.Holdout `
            --output-root $caseOutput `
            --sample-count 30 `
            --min-holdout-views 15 `
            --median-rmse-px 0.8 `
            --p95-rmse-px 1.2 `
            --maximum-rmse-px 1.5 `
            --required-pass-fraction 0.90 `
            --no-images
        $intrinsicExit = $LASTEXITCODE
        Set-Content -LiteralPath (Join-Path $caseOutput 'process_exit_code.txt') -Value $intrinsicExit -Encoding ascii
        if ($intrinsicExit -notin 0, 3) {
            throw "$($case.Slug) intrinsic validation failed unexpectedly with exit code $intrinsicExit"
        }
    }

    $promotedCam0 = Join-Path $receiverRoot 'calibration_configs\cam0_replacement_20260820_run01\cam0_intrinsics_120.json'
    $promotedCam1 = Join-Path $receiverRoot 'calibration_configs\cam1_replacement_20260820_run01\cam1_intrinsics_120.json'
    $k1k2Cam0 = Join-Path $run20Build '10_cam0_k1k2_solve\cam0_intrinsics_k1k2.json'
    $k1k2Cam1 = Join-Path $run20Build '12_cam1_k1k2_solve\cam1_intrinsics_k1k2.json'
    $k1k3Cam0 = Join-Path $run20Build '17_cam0_k1k2k3_solve\cam0_intrinsics_k1k2k3.json'
    $k1k3Cam1 = Join-Path $run20Build '19_cam1_k1k2k3_solve\cam1_intrinsics_k1k2k3.json'

    $extrinsicCases = @(
        [pscustomobject]@{
            Slug = 'run01_k1k4'; TrainRoot = Join-Path $run20Images '04_stereo_train';
            Cam0 = $promotedCam0; Cam1 = $promotedCam1;
            Stillness = Join-Path $run20Build '03_stereo_static\stillness_config.json';
            FrozenPairs = $null; FrozenSummary = $null; FrozenResult = $null
        },
        [pscustomobject]@{
            Slug = 'run01_k1k2'; TrainRoot = Join-Path $run20Images '04_stereo_train';
            Cam0 = $k1k2Cam0; Cam1 = $k1k2Cam1;
            Stillness = Join-Path $run20Build '14_stereo_static_k1k2\stillness_config.json';
            FrozenPairs = $null; FrozenSummary = $null; FrozenResult = $null
        },
        [pscustomobject]@{
            Slug = 'run01_k1k3'; TrainRoot = Join-Path $run20Images '04_stereo_train';
            Cam0 = $k1k3Cam0; Cam1 = $k1k3Cam1;
            Stillness = Join-Path $run20Build '21_stereo_static_k1k2k3\stillness_config.json';
            FrozenPairs = $null; FrozenSummary = $null; FrozenResult = $null
        },
        [pscustomobject]@{
            Slug = 'first_final_capture'; TrainRoot = Join-Path $run21Images '01_train_retry01';
            Cam0 = $k1k3Cam0; Cam1 = $k1k3Cam1;
            Stillness = Join-Path $run20Build '21_stereo_static_k1k2k3\stillness_config.json';
            FrozenPairs = Join-Path $run21Build '01_pairs_failed_20260821_115244\pairs.csv';
            FrozenSummary = Join-Path $run21Build '01_pairs_failed_20260821_115244\pairing_summary.json';
            FrozenResult = Join-Path $run21Build '02_solve_failed_20260821_115244\cam0_to_new_cam1_extrinsics.rejected.json'
        },
        [pscustomobject]@{
            Slug = 'controlled_retry'; TrainRoot = Join-Path $run21Images '01_train_retry01';
            Cam0 = $k1k3Cam0; Cam1 = $k1k3Cam1;
            Stillness = Join-Path $run20Build '21_stereo_static_k1k2k3\stillness_config.json';
            FrozenPairs = $null; FrozenSummary = $null; FrozenResult = $null
        }
    )

    foreach ($case in $extrinsicCases) {
        Write-Host "`n[EXTRINSIC] $($case.Slug)"
        Assert-Directory -Path $case.TrainRoot -Label "$($case.Slug) training dataset"
        Assert-File -Path $case.Cam0 -Label "$($case.Slug) CAM0 intrinsic"
        Assert-File -Path $case.Cam1 -Label "$($case.Slug) CAM1 intrinsic"
        Assert-File -Path $case.Stillness -Label "$($case.Slug) stillness config"
        $caseRoot = Join-Path $extrinsicRoot $case.Slug
        $pairRoot = Join-Path $caseRoot 'pairs'
        $solveRoot = Join-Path $caseRoot 'solve'
        New-Item -ItemType Directory -Force -Path $pairRoot, $solveRoot | Out-Null
        $pairsPath = Join-Path $pairRoot 'pairs.csv'
        $summaryPath = Join-Path $pairRoot 'pairing_summary.json'

        if ($null -ne $case.FrozenPairs) {
            Assert-File -Path $case.FrozenPairs -Label "$($case.Slug) frozen pairs"
            Assert-File -Path $case.FrozenSummary -Label "$($case.Slug) frozen pairing summary"
            Copy-Item -LiteralPath $case.FrozenPairs -Destination $pairsPath
            Copy-Item -LiteralPath $case.FrozenSummary -Destination $summaryPath
            Write-Host 'Using the archived first-pass pair manifest because its source directory was later replaced.'
        }
        else {
            & $PythonExe .\build_stereo_pairs.py $case.TrainRoot `
                --cam0-intrinsics $case.Cam0 `
                --cam1-intrinsics $case.Cam1 `
                --output-root $pairRoot `
                --stillness-config $case.Stillness `
                --max-center-dt-ms 33.5 `
                --min-cam0-edge-margin-px 12 `
                --min-pairs 20
            if ($LASTEXITCODE -ne 0) {
                throw "$($case.Slug) stereo pairing failed with exit code $LASTEXITCODE"
            }
        }

        $extrinsicPath = Join-Path $solveRoot 'cam0_to_cam1_extrinsics.json'
        $trainingReport = Join-Path $solveRoot 'training_pairs.csv'
        if ($null -ne $case.FrozenResult) {
            Assert-File -Path $case.FrozenResult -Label "$($case.Slug) frozen result"
            Copy-Item -LiteralPath $case.FrozenResult -Destination (
                Join-Path $solveRoot 'cam0_to_cam1_extrinsics.rejected.json'
            )
            @{
                status = 'historical_artifact_only'
                replayable = $false
                source_result = $case.FrozenResult
                reason = 'The archived pair manifest references frame IDs 7663 onward, but the capture directory was replaced by a later 0-based 2221-frame dataset.'
            } | ConvertTo-Json -Depth 3 | Set-Content `
                -LiteralPath (Join-Path $solveRoot 'replay_status.json') `
                -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $solveRoot 'process_exit_code.txt') -Value 'not_replayed' -Encoding ascii
            Write-Warning 'First final capture is accepted only as a hash-bound historical result; its original frames are no longer replayable.'
            continue
        }
        & $PythonExe .\calibrate_binary_stereo.py $pairsPath `
            --pairing-summary $summaryPath `
            --cam0-intrinsics $case.Cam0 `
            --cam1-intrinsics $case.Cam1 `
            --stillness-config $case.Stillness `
            --output $extrinsicPath `
            --report $trainingReport `
            --min-pairs 20
        $stereoExit = $LASTEXITCODE
        Set-Content -LiteralPath (Join-Path $solveRoot 'process_exit_code.txt') -Value $stereoExit -Encoding ascii
        if ($stereoExit -notin 0, 3) {
            throw "$($case.Slug) stereo solve failed unexpectedly with exit code $stereoExit"
        }
    }

    & $PythonExe .\summarize_calibration_acceptance.py `
        --repo-root $repoRoot `
        --output-root $OutputRoot `
        --nominal-config $nominalConfig
    if ($LASTEXITCODE -ne 0) {
        throw "Acceptance summarisation failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

Write-Host "`nHistorical calibration acceptance completed: $OutputRoot" -ForegroundColor Green
