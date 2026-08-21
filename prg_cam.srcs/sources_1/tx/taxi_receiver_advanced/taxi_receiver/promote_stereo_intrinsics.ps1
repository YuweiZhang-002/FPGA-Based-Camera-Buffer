param(
    [string]$RepoRoot = [IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot '..\..\..\..\..')
    ),

    [string]$DestinationRoot = (Join-Path $PSScriptRoot 'calibration_configs')
)

$ErrorActionPreference = 'Stop'

$releases = @(
    [ordered]@{
        camera_id = 0
        canonical_path = 'cam0_intrinsics_full44.json'
        source_path = `
          'build/attempt12_cam0_calibration_audit_full44/cam0_intrinsics_full44.json'
        sha256 = '9FCD510B1ADB22BB1FF8801AD487928345EDB8CDB25A5F241C49135DFBAD65F5'
        training_evidence = [ordered]@{
            attempt = 12
            accepted_views = 26
            rms_px = 0.41982267039767823
            point_policy = 'full_44_points'
        }
        validation_evidence = @(
            [ordered]@{
                name = 'Attempt12 holdout V1'
                source_path = `
                  'build/attempt12_cam0_calibration_audit_full44/holdout_v1.validation/holdout_summary.json'
                status = 'pass'
                sampled_views = 30
                p95_rmse_px = 0.649443857742002
                maximum_rmse_px = 0.9797804056787323
            },
            [ordered]@{
                name = 'Attempt12 holdout V2'
                source_path = `
                  'build/attempt12_cam0_calibration_audit_full44/holdout_v2.validation/holdout_summary.json'
                status = 'pass'
                sampled_views = 30
                p95_rmse_px = 0.5610586424923205
                maximum_rmse_px = 0.7854717509144694
            }
        )
        numerical_domain = [ordered]@{
            status = 'limited_margin'
            first_derivative_root_deg = 29.128074725863176
            maximum_image_corner_inverse_theta_deg = 26.79640595407983
            monotonic_margin_deg = 2.331668771783342
            operational_policy = `
              'Keep all 44 points inside the validated cam0 image region and away from extreme corners.'
        }
    },
    [ordered]@{
        camera_id = 1
        canonical_path = 'cam1_intrinsics_mask26.json'
        source_path = `
          'build/attempt11_cam1_calibration_audit_mask26/cam1_intrinsics_mask26.json'
        sha256 = 'CDBA3CA3069225803D681C9DE33A6305E884BA6D5CC49DFAF76395182F829F25'
        training_evidence = [ordered]@{
            attempt = 11
            accepted_views = 29
            rms_px = 0.35986451833244737
            detected_point_count = 44
            used_point_count = 43
            excluded_point_indices = @(26)
        }
        extrinsic_point_policy = [ordered]@{
            point_count = 44
            point_indices = '0..43'
            rationale = `
              'Attempt15 fixed-K/D validation passed on clean full-44 holdouts; the index-26 exclusion is training provenance only.'
        }
        validation_evidence = @(
            [ordered]@{
                name = 'Attempt15 clean full-44 holdout V1'
                source_path = `
                  'build/attempt15_cam1_release_a11_on_clean_full44/holdout_v1/holdout_summary.json'
                status = 'pass'
                sampled_views = 30
                p95_rmse_px = 0.5853969654848926
                maximum_rmse_px = 0.7397744538233594
            },
            [ordered]@{
                name = 'Attempt15 clean full-44 holdout V2'
                source_path = `
                  'build/attempt15_cam1_release_a11_on_clean_full44/holdout_v2/holdout_summary.json'
                status = 'pass'
                sampled_views = 30
                p95_rmse_px = 0.4339445486610615
                maximum_rmse_px = 0.4810363216808063
            }
        )
    }
)

$rejectedCandidates = @(
    [ordered]@{
        attempt = 9
        camera_id = 1
        source_path = 'build/attempt9_calibration_audit/cam1_intrinsics.json'
        training = [ordered]@{
            accepted_views = 28
            rms_px = 0.5751673301606861
        }
        validation = @(
            [ordered]@{
                name = 'Attempt9 holdout V1'
                source_path = `
                  'build/attempt9_calibration_audit/holdout_validation_v1/holdout_summary.json'
                status = 'fail'
                p95_rmse_px = 1.20227743884616
                maximum_rmse_px = 1.532513280898361
            }
        )
        decision = 'rejected'
        reason = 'Independent holdout exceeded both P95 and maximum RMSE release limits.'
    },
    [ordered]@{
        attempt = 10
        camera_id = 0
        source_path = `
          'build/attempt10_cam0_calibration_audit_mask26/cam0_intrinsics_mask26.json'
        training = [ordered]@{
            accepted_views = 31
            rms_px = 0.47302150856643504
            excluded_point_indices = @(26)
        }
        validation = @()
        decision = 'rejected'
        reason = `
          'Legacy contaminated-board/mask26 result without current-format fixed-K/D independent release evidence.'
    },
    [ordered]@{
        attempt = 13
        camera_id = 1
        source_path = `
          'build/attempt13_cam1_calibration_audit_full44/cam1_intrinsics_full44.json'
        training = [ordered]@{
            accepted_views = 28
            rms_px = 0.42662425686741406
        }
        validation = @(
            [ordered]@{
                name = 'Attempt13 holdout V1'
                source_path = `
                  'build/attempt13_cam1_calibration_audit_full44/holdout_v1.validation/holdout_summary.json'
                status = 'fail'
                p95_rmse_px = 4.797836086989136
                maximum_rmse_px = 22157.218985582356
            },
            [ordered]@{
                name = 'Attempt13 holdout V2'
                source_path = `
                  'build/attempt13_cam1_calibration_audit_full44/holdout_v2.validation/holdout_summary.json'
                status = 'fail'
                p95_rmse_px = 0.9787102825503836
                maximum_rmse_px = 21367.601555353758
            }
        )
        decision = 'rejected'
        reason = `
          'The fitted K/D produced catastrophic non-invertible holdout solutions; retain the images only as clean-board stress data.'
    },
    [ordered]@{
        attempt = 14
        camera_id = 1
        source_path = `
          'build/attempt14_cam1_calibration_audit_full44_corner/cam1_intrinsics_full44_corner.json'
        training = [ordered]@{
            accepted_views = 36
            rms_px = 0.28656623341915816
        }
        validation = @(
            [ordered]@{
                name = 'Attempt14 diagnostic holdout V1'
                source_path = `
                  'build/attempt14_cam1_calibration_audit_full44_corner/diagnostic_holdout_v1/holdout_summary.json'
                status = 'fail'
                p95_rmse_px = 5.810642889902217
                maximum_rmse_px = 7110.917591617589
            },
            [ordered]@{
                name = 'Attempt14 diagnostic holdout V2'
                source_path = `
                  'build/attempt14_cam1_calibration_audit_full44_corner/diagnostic_holdout_v2/holdout_summary.json'
                status = 'fail'
                p95_rmse_px = 0.6735607333161134
                maximum_rmse_px = 6849.170242571309
            }
        )
        decision = 'rejected'
        reason = `
          'Low training RMS did not generalize; both diagnostic holdouts contained catastrophic solutions.'
    }
)

$historicalDatasetInventory = [ordered]@{
    root = 'images/new_Temp'
    session_count = 15
    file_totals = [ordered]@{
        pgm = 23828
        raw = 23828
        json = 23828
        rows_v2_csv = 15
    }
    attempts = @(
        [ordered]@{ attempt = 9; camera_id = 1; sessions = 2; published_frames = 2539; role = 'legacy_model_comparison' },
        [ordered]@{ attempt = 10; camera_id = 0; sessions = 3; published_frames = 6210; role = 'legacy_contaminated_board_mask26_comparison' },
        [ordered]@{ attempt = 11; camera_id = 1; sessions = 3; published_frames = 6013; role = 'selected_cam1_intrinsic_source' },
        [ordered]@{ attempt = 12; camera_id = 0; sessions = 3; published_frames = 4059; role = 'selected_cam0_intrinsic_source' },
        [ordered]@{ attempt = 13; camera_id = 1; sessions = 3; published_frames = 3764; role = 'clean_board_validation_and_stress_data' },
        [ordered]@{ attempt = 14; camera_id = 1; sessions = 1; published_frames = 1243; role = 'corner_supplement_and_stress_data' }
    )
    published_metadata_integrity = [ordered]@{
        status = 'COMPLETE'
        missing_count = 0
        bit_order = 'msb_first'
        crc_errors = 0
        overflow_errors = 0
        sync_errors = 0
    }
    cross_camera_timing_audit = [ordered]@{
        overlapping_session_pairs = 0
        nearest_gap_seconds = 672.400429
        median_frame_center_period_ms = 66.64609909057617
        median_frame_row_receive_span_ms = 62.1190071105957
        pairing_candidate_limit_ms = 33.5
        timing_stat_sources = @(
            'attempt12_cam0_intrinsics_train_full44',
            'attempt13_cam1_intrinsics_train_full44'
        )
        earlier_session = 'attempt12_cam0_intrinsics_holdout_v2_full44'
        earlier_end_capture_timestamp = '1786814527.252630949'
        later_session = 'attempt13_cam1_intrinsics_train_full44'
        later_start_capture_timestamp = '1786815199.653059959'
        conclusion = `
          'Historical sessions cannot provide cam0/cam1 pose pairs for extrinsic calibration.'
    }
}

function Assert-CalibrationIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$CameraId,

        [Parameter(Mandatory = $true)]
        [string]$Sha256,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    if ($actualHash -ne $Sha256) {
        throw "$Label hash mismatch for cam$CameraId`: expected $Sha256, got $actualHash"
    }
    $document = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path |
      ConvertFrom-Json
    if ($document.camera_id -ne $CameraId) {
        throw (
            "$Label camera_id mismatch for ${Path}: " +
            "expected $CameraId, got $($document.camera_id)"
        )
    }
}

New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null

foreach ($release in $releases) {
    $source = Join-Path $RepoRoot ($release.source_path -replace '/', '\')
    $destination = Join-Path $DestinationRoot $release.canonical_path

    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        Assert-CalibrationIdentity `
          -Path $destination `
          -CameraId $release.camera_id `
          -Sha256 $release.sha256 `
          -Label 'Canonical intrinsic'
    }
    else {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw (
                "Missing canonical intrinsic and initial promotion source: " +
                "$destination; $source"
            )
        }
        Assert-CalibrationIdentity `
          -Path $source `
          -CameraId $release.camera_id `
          -Sha256 $release.sha256 `
          -Label 'Source intrinsic'
        $temporary = "$destination.$PID.tmp"
        try {
            Copy-Item -LiteralPath $source -Destination $temporary
            Assert-CalibrationIdentity `
              -Path $temporary `
              -CameraId $release.camera_id `
              -Sha256 $release.sha256 `
              -Label 'Copied intrinsic'
            Move-Item -LiteralPath $temporary -Destination $destination
        }
        finally {
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary -Force
            }
        }
    }

    # Build outputs are historical provenance, not runtime dependencies.  If
    # one is still present, reject silent source drift; after build cleanup the
    # verified canonical copy is sufficient for idempotent reruns.
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        Assert-CalibrationIdentity `
          -Path $source `
          -CameraId $release.camera_id `
          -Sha256 $release.sha256 `
          -Label 'Historical source intrinsic'
    }
}

$manifestPath = Join-Path $DestinationRoot 'release_manifest.json'
$createdUtc = [DateTime]::UtcNow.ToString('o')
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $existingManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath |
      ConvertFrom-Json
    if ($existingManifest.created_utc) {
        $createdUtc = [string]$existingManifest.created_utc
    }
}

$manifest = [ordered]@{
    schema = 'taxi_receiver.intrinsic_release_manifest/2'
    created_utc = $createdUtc
    path_base = 'manifest_directory'
    historical_path_base = 'repository_root'
    policy = `
      'Exact byte copies; canonical SHA256 and camera_id are verified on every promotion run.'
    historical_source_policy = `
      'Source and evidence paths are provenance labels. Embedded evidence remains authoritative if ignored build artifacts are cleaned.'
    validation_thresholds_px = [ordered]@{
        p95_rmse_max = 1.2
        maximum_rmse_max = 1.5
    }
    cameras = @(
        foreach ($release in $releases) {
            [ordered]@{
                camera_id = $release.camera_id
                path = $release.canonical_path
                sha256 = $release.sha256
                source = [ordered]@{
                    attempt = $release.training_evidence.attempt
                    path = $release.source_path
                    required_after_promotion = $false
                }
                training_evidence = $release.training_evidence
                validation_evidence = $release.validation_evidence
                decision = 'selected'
                extrinsic_point_policy = $release.extrinsic_point_policy
                numerical_domain = $release.numerical_domain
            }
        }
    )
    rejected_candidates = $rejectedCandidates
    historical_dataset_inventory = $historicalDatasetInventory
}
$manifestText = $manifest | ConvertTo-Json -Depth 12
$writeManifest = $true
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $currentManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath |
      ConvertFrom-Json
    $currentComparable = $currentManifest | ConvertTo-Json -Depth 12 -Compress
    $expectedComparable = $manifest | ConvertTo-Json -Depth 12 -Compress
    $writeManifest = $currentComparable -ne $expectedComparable
}
if ($writeManifest) {
    $manifestText | Set-Content -LiteralPath $manifestPath -Encoding UTF8
}

Write-Host "Canonical intrinsics: $DestinationRoot"
foreach ($release in $releases) {
    $destination = Join-Path $DestinationRoot $release.canonical_path
    Write-Host "cam$($release.camera_id): $destination [$($release.sha256)]"
}
Write-Host "manifest: $manifestPath"
