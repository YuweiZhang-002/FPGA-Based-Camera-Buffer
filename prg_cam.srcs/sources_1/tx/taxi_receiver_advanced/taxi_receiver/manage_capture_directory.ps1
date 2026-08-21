[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('ArchiveFailed', 'Restore')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$Target,

    [string]$ArchivePath = '',

    [string]$AllowedRoot = 'D:\prg\prg_cam'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-SafePath {
    param([string]$Path, [string]$Label)
    $resolved = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes allowed root ${root}: $resolved"
    }
    return $resolved
}

function Get-CaptureState {
    param([string]$Path)
    $lanes = foreach ($cameraId in 0, 1) {
        $lane = Join-Path $Path "cam$cameraId"
        [pscustomobject]@{
            camera_id = $cameraId
            lane_exists = Test-Path -LiteralPath $lane -PathType Container
            pgm = @(Get-ChildItem -LiteralPath $lane -Filter '*.pgm' -File -ErrorAction SilentlyContinue).Count
            json = @(Get-ChildItem -LiteralPath $lane -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
            raw = @(Get-ChildItem -LiteralPath $lane -Filter '*.raw' -File -ErrorAction SilentlyContinue).Count
            rows_v2 = Test-Path -LiteralPath (Join-Path $lane 'rows_v2.csv') -PathType Leaf
        }
    }
    $complete = $true
    foreach ($lane in $lanes) {
        if (
            -not $lane.lane_exists -or
            $lane.pgm -eq 0 -or
            $lane.pgm -ne $lane.json -or
            $lane.pgm -ne $lane.raw -or
            -not $lane.rows_v2
        ) {
            $complete = $false
        }
    }
    return [pscustomobject]@{ complete = $complete; lanes = $lanes }
}

$targetPath = Resolve-SafePath -Path $Target -Label 'Target'

if ($Action -eq 'ArchiveFailed') {
    if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) {
        throw "Capture target does not exist: $targetPath"
    }
    $state = Get-CaptureState -Path $targetPath
    $state.lanes | Format-Table -AutoSize
    if ($state.complete) {
        throw (
            'Refusing to archive: the capture is complete in both lanes. ' +
            'Use it for pairing, or explicitly choose Restore only after an accidental archive.'
        )
    }
    $destination = "${targetPath}_failed_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    if (Test-Path -LiteralPath $destination) {
        throw "Archive destination already exists: $destination"
    }
    Move-Item -LiteralPath $targetPath -Destination $destination
    Write-Host "Incomplete capture archived: $destination"
    return
}

if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    throw '-ArchivePath is mandatory for Restore'
}
$sourcePath = Resolve-SafePath -Path $ArchivePath -Label 'Archive source'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
    throw "Archive source does not exist: $sourcePath"
}
if (Test-Path -LiteralPath $targetPath) {
    throw "Restore target already exists: $targetPath"
}
$targetParent = [IO.Path]::GetDirectoryName($targetPath)
$sourceParent = [IO.Path]::GetDirectoryName($sourcePath)
$targetLeaf = [IO.Path]::GetFileName($targetPath)
$sourceLeaf = [IO.Path]::GetFileName($sourcePath)
if (-not $sourceParent.Equals($targetParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Archive source and restore target must have the same parent directory'
}
if (-not $sourceLeaf.StartsWith("${targetLeaf}_failed_", [StringComparison]::OrdinalIgnoreCase)) {
    throw "Archive name does not belong to target: $sourceLeaf"
}
$state = Get-CaptureState -Path $sourcePath
$state.lanes | Format-Table -AutoSize
if (-not $state.complete) {
    throw 'Refusing to restore: archive is not a complete two-camera capture'
}
Move-Item -LiteralPath $sourcePath -Destination $targetPath
Write-Host "Complete capture restored: $targetPath" -ForegroundColor Green
