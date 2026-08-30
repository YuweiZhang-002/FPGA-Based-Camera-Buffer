[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)] [string]$RunRoot,
    [Parameter(Mandatory = $true)] [string]$McuRepository,
    [Parameter(Mandatory = $true)] [string]$FpgaRepository,
    [Parameter(Mandatory = $true)] [string]$HostRepository,
    [string]$McuFirmware,
    [string]$FpgaBit,
    [string]$FpgaLtx,
    [string]$InterfaceGuid,
    [string]$CameraIds = '',
    [string]$CaptureRoot,
    [string[]]$IntrinsicJson = @(),
    [string]$ExtrinsicJson,
    [switch]$PreflightOnly
)

$ErrorActionPreference = 'Stop'
$resolvedRunRoot = [IO.Path]::GetFullPath($RunRoot)
$git = Get-Command git -ErrorAction Stop
$cameraIdList = @(
    $CameraIds -split ',' |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -ne '' }
)

function Get-RepositoryIdentity([string]$name, [string]$path) {
    $resolved = [IO.Path]::GetFullPath($path)
    if (!(Test-Path -LiteralPath (Join-Path $resolved '.git'))) {
        throw "$name is not a Git repository: $resolved"
    }
    [ordered]@{
        name = $name
        path = $resolved
        head = (& $git.Source -C $resolved rev-parse HEAD).Trim()
        dirty = (@(& $git.Source -C $resolved status --porcelain).Count -ne 0)
        remote = ((& $git.Source -C $resolved remote get-url origin 2>$null) |
          Select-Object -First 1)
    }
}

function Get-Artifact([string]$name, [string]$path, [bool]$required = $false) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        if ($required) { throw "$name path is required" }
        return $null
    }
    $resolved = [IO.Path]::GetFullPath($path)
    if (!(Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$name does not exist: $resolved"
    }
    [ordered]@{
        path = $resolved
        bytes = (Get-Item -LiteralPath $resolved).Length
        sha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLower()
    }
}

$repositories = @(
    Get-RepositoryIdentity 'MCU' $McuRepository
    Get-RepositoryIdentity 'FPGA' $FpgaRepository
    Get-RepositoryIdentity 'Host' $HostRepository
)
$artifacts = [ordered]@{
    mcu_firmware = Get-Artifact 'MCU firmware' $McuFirmware
    fpga_bit = Get-Artifact 'FPGA bit' $FpgaBit
    fpga_ltx = Get-Artifact 'FPGA ltx' $FpgaLtx
    intrinsics = @(
        foreach ($path in $IntrinsicJson) {
            Get-Artifact 'intrinsic JSON' $path $true
        }
    )
    extrinsics = Get-Artifact 'extrinsic JSON' $ExtrinsicJson
}

$preview = [pscustomobject]@{
    RunRoot = $resolvedRunRoot
    Repositories = $repositories.Count
    CameraIds = ($cameraIdList -join ',')
    Interface = $InterfaceGuid
    CaptureRoot = $CaptureRoot
}
$preview | Format-List
if ($PreflightOnly -or $WhatIfPreference) {
    Write-Host 'PREFLIGHT_ONLY=PASS; no manifest was written.'
    exit 0
}

if (Test-Path -LiteralPath $resolvedRunRoot) {
    $existing = @(Get-ChildItem -LiteralPath $resolvedRunRoot -Force)
    if ($existing.Count -ne 0) {
        throw "Run root is not empty; evidence is immutable: $resolvedRunRoot"
    }
} elseif ($PSCmdlet.ShouldProcess($resolvedRunRoot, 'Create immutable run root')) {
    New-Item -ItemType Directory -Path $resolvedRunRoot | Out-Null
}

$manifest = [ordered]@{
    schema_version = 1
    run_id = Split-Path -Leaf $resolvedRunRoot
    created_utc = [DateTime]::UtcNow.ToString('o')
    status = 'identity_frozen_data_not_yet_validated'
    repositories = $repositories
    artifacts = $artifacts
    hardware = [ordered]@{
        interface_guid = $InterfaceGuid
        camera_ids = $cameraIdList
    }
    capture = [ordered]@{
        root = $CaptureRoot
        status = 'NOT_RUN'
    }
    validation = [ordered]@{
        status = 'NOT_RUN'
        first_failed_boundary = $null
        summaries = @()
    }
    evidence_rule = 'No evidence promotion across layers.'
}
$manifestPath = Join-Path $resolvedRunRoot 'run_manifest.json'
$manifest | ConvertTo-Json -Depth 10 |
  Set-Content -LiteralPath $manifestPath -Encoding utf8
Write-Host 'RUN_IDENTITY_STATUS=PASS'
Write-Host "RUN_MANIFEST=$manifestPath"
exit 0
