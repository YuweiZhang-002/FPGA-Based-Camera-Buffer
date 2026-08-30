[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)] [string]$HostRepository,
    [Parameter(Mandatory = $true)] [string]$PythonExe,
    [Parameter(Mandatory = $true)] [string]$OutputRoot,
    [string]$FixtureRoot = '',
    [switch]$PreflightOnly
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($FixtureRoot)) {
    $FixtureRoot = Join-Path $PSScriptRoot `
      '..\docs\fixtures\golden_dual_camera_small'
}
$hostRoot = [IO.Path]::GetFullPath($HostRepository)
$python = [IO.Path]::GetFullPath($PythonExe)
$output = [IO.Path]::GetFullPath($OutputRoot)
$fixtures = [IO.Path]::GetFullPath($FixtureRoot)
$positive = Join-Path $fixtures 'golden_dual_camera_480rows.pcap'
$negative = Join-Path $fixtures 'golden_crc_error_single_packet.pcap'
$expectedPath = Join-Path $fixtures 'expected_results.json'

$required = @(
    (Join-Path $hostRoot 'taxi_receiver\cli.py'),
    $python,
    $positive,
    $negative,
    $expectedPath
)
$missing = @($required | Where-Object {
    !(Test-Path -LiteralPath $_ -PathType Leaf)
})
if ($missing.Count -ne 0) {
    $missing | ForEach-Object { [Console]::Error.WriteLine("Missing input: $_") }
    exit 1
}

$expected = Get-Content -Raw -LiteralPath $expectedPath | ConvertFrom-Json
$hashRows = @(
    [pscustomobject]@{
        Name = 'positive'
        Expected = $expected.positive_fixture.sha256
        Actual = (Get-FileHash -LiteralPath $positive -Algorithm SHA256).Hash.ToLower()
    }
    [pscustomobject]@{
        Name = 'negative'
        Expected = $expected.negative_fixture.sha256
        Actual = (Get-FileHash -LiteralPath $negative -Algorithm SHA256).Hash.ToLower()
    }
)
$hashRows | Format-Table -AutoSize
if (@($hashRows | Where-Object { $_.Actual -ne $_.Expected }).Count -ne 0) {
    [Console]::Error.WriteLine('Fixture SHA-256 precheck failed.')
    exit 2
}

if ($PreflightOnly -or $WhatIfPreference) {
    Write-Host "HOST_REPOSITORY=$hostRoot"
    Write-Host "PYTHON=$python"
    Write-Host "OUTPUT_ROOT=$output"
    Write-Host 'PREFLIGHT_ONLY=PASS; replay was not started.'
    exit 0
}

if (Test-Path -LiteralPath $output) {
    if (@(Get-ChildItem -LiteralPath $output -Force).Count -ne 0) {
        [Console]::Error.WriteLine("Output root is not empty: $output")
        exit 2
    }
} elseif ($PSCmdlet.ShouldProcess($output, 'Create golden validation output')) {
    New-Item -ItemType Directory -Path $output | Out-Null
}

$positiveRoot = Join-Path $output 'positive'
$archiveRoot = Join-Path $positiveRoot 'archive'
$imagesRoot = Join-Path $positiveRoot 'images'
$positiveLog = Join-Path $positiveRoot 'replay.log'
New-Item -ItemType Directory -Force -Path $positiveRoot | Out-Null

Push-Location $hostRoot
try {
    $positiveArgs = @(
        '-m', 'taxi_receiver.cli',
        '--replay-pcap', $positive,
        '--mode', 'camera',
        '--max-stage', 'reassemble',
        '--expected-rows', '480',
        '--output-root', $archiveRoot,
        '--images-root', $imagesRoot,
        '--camera-ids', '0,1',
        '--split-by-camera', 'on',
        '--image-policy', 'strict',
        '--publish-frames', 'complete',
        '--publish-images', 'thread',
        '--session-audit', 'on',
        '--bit-order', 'msb_first'
    )
    & $python @positiveArgs 2>&1 | Tee-Object -FilePath $positiveLog
    $positiveExit = $LASTEXITCODE
}
finally {
    Pop-Location
}
if ($positiveExit -ne 0) {
    [Console]::Error.WriteLine("Positive replay failed: $positiveExit")
    exit 5
}

$negativeRoot = Join-Path $output 'negative'
$negativeLog = Join-Path $negativeRoot 'replay.log'
New-Item -ItemType Directory -Force -Path $negativeRoot | Out-Null
Push-Location $hostRoot
try {
    $negativeArgs = @(
        '-m', 'taxi_receiver.cli',
        '--replay-pcap', $negative,
        '--mode', 'camera',
        '--max-stage', 'monitor',
        '--camera-ids', '0,1'
    )
    & $python @negativeArgs 2>&1 | Tee-Object -FilePath $negativeLog
    $negativeExit = $LASTEXITCODE
}
finally {
    Pop-Location
}
if ($negativeExit -ne 0) {
    [Console]::Error.WriteLine("Negative replay command failed: $negativeExit")
    exit 5
}

$positiveText = Get-Content -Raw -LiteralPath $positiveLog
$negativeText = Get-Content -Raw -LiteralPath $negativeLog
$checks = @(
    [pscustomobject]@{ Name = 'positive ingress'; Pass = $positiveText -match 'Capture ingress\s*:\s*960' },
    [pscustomobject]@{ Name = 'positive matching'; Pass = $positiveText -match 'Matching Ethernet\s*:\s*960' },
    [pscustomobject]@{ Name = 'positive valid'; Pass = $positiveText -match 'Valid packets\s*:\s*960' },
    [pscustomobject]@{ Name = 'positive CRC'; Pass = $positiveText -match 'CRC errors\s*:\s*0' },
    [pscustomobject]@{ Name = 'positive frames'; Pass = @($positiveText -split "`n" | Where-Object { $_ -match 'frames complete\s*:\s*1' }).Count -eq 2 },
    [pscustomobject]@{ Name = 'negative ingress'; Pass = $negativeText -match 'Capture ingress\s*:\s*1' },
    [pscustomobject]@{ Name = 'negative valid'; Pass = $negativeText -match 'Valid packets\s*:\s*0' },
    [pscustomobject]@{ Name = 'negative CRC'; Pass = $negativeText -match 'CRC errors\s*:\s*1' }
)

foreach ($camera in 'cam0', 'cam1') {
    $cameraRoot = Join-Path $imagesRoot $camera
    $pgmFiles = @(
        Get-ChildItem -LiteralPath $cameraRoot -Filter '*.pgm' -File `
          -ErrorAction SilentlyContinue
    )
    $rowsPath = Join-Path $cameraRoot 'rows.csv'
    $rowCount = 0
    $rowsValid = $false
    if (Test-Path -LiteralPath $rowsPath -PathType Leaf) {
        $rowRecords = @(Import-Csv -LiteralPath $rowsPath)
        $rowCount = $rowRecords.Count
        $acceptedRows = @($rowRecords | Where-Object {
            $_.parse_ok -eq '1' -and
            $_.layer3_valid -eq '1' -and
            $_.row_accepted -eq '1' -and
            $_.crc_ok -eq '1'
        })
        $uniqueRows = @(
            $rowRecords |
              ForEach-Object { [int]$_.row_idx } |
              Sort-Object -Unique
        )
        $rowsValid = (
            $acceptedRows.Count -eq 480 -and
            $uniqueRows.Count -eq 480 -and
            [int]$uniqueRows[0] -eq 0 -and
            [int]$uniqueRows[-1] -eq 479
        )
    }
    $pgmValid = $false
    if ($pgmFiles.Count -eq 1) {
        $pgmBytes = [IO.File]::ReadAllBytes($pgmFiles[0].FullName)
        $header = "P5`n640 480`n255`n"
        $prefixLength = [Math]::Min($pgmBytes.Length, 32)
        $prefix = [Text.Encoding]::ASCII.GetString(
            $pgmBytes, 0, $prefixLength
        )
        $pgmValid = (
            $prefix.StartsWith($header, [StringComparison]::Ordinal) -and
            $pgmBytes.Length -eq (
                [Text.Encoding]::ASCII.GetByteCount($header) + 640 * 480
            )
        )
    }
    $checks += [pscustomobject]@{
        Name = "$camera PGM count"
        Pass = $pgmFiles.Count -eq 1
    }
    $checks += [pscustomobject]@{
        Name = "$camera rows.csv count"
        Pass = $rowCount -eq 480
    }
    $checks += [pscustomobject]@{
        Name = "$camera PGM shape"
        Pass = $pgmValid
    }
    $checks += [pscustomobject]@{
        Name = "$camera accepted row set"
        Pass = $rowsValid
    }
}

$checks | Format-Table -AutoSize
$failed = @($checks | Where-Object { !$_.Pass })
$summary = [ordered]@{
    schema_version = 1
    created_utc = [DateTime]::UtcNow.ToString('o')
    status = if ($failed.Count -eq 0) { 'pass' } else { 'fail' }
    host_commit = (& git -C $hostRoot rev-parse HEAD).Trim()
    fixture_expected = $expectedPath
    checks = $checks
    failures = @(
        foreach ($failure in $failed) { $failure.Name }
    )
    outputs = [ordered]@{
        positive_log = $positiveLog
        negative_log = $negativeLog
        images_root = $imagesRoot
        archive_root = $archiveRoot
    }
    evidence_scope = 'Host offline parse/reassemble/publication only'
}
$summaryPath = Join-Path $output 'golden_validation_summary.json'
$summary | ConvertTo-Json -Depth 8 |
  Set-Content -LiteralPath $summaryPath -Encoding utf8
if ($failed.Count -ne 0) {
    [Console]::Error.WriteLine("Golden validation failed; see $summaryPath")
    exit 4
}
Write-Host 'GOLDEN_VALIDATION_STATUS=PASS'
Write-Host "GOLDEN_VALIDATION_SUMMARY=$summaryPath"
exit 0
