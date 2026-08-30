[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [switch]$PreflightOnly,

    [string]$McuUrl =
      'https://github.com/YuweiZhang-002/-RP2354A-OV5640-Camera-Module.git',
    [string]$FpgaUrl =
      'https://github.com/YuweiZhang-002/FPGA-Based-Camera-Buffer.git',
    [string]$HostUrl =
      'https://github.com/YuweiZhang-002/Host_Camera_Packet_Receiver.git',

    [string]$TaxiUrl = 'https://github.com/fpganinja/taxi.git',
    [string]$RmiiUrl =
      'https://github.com/WangXuan95/FPGA-RMII-SMII.git',

    [string]$McuRef = '6c4157b',
    [string]$FpgaRef = '107a8e8',
    [string]$HostRef = '3910249',
    [string]$TaxiRef = 'bc4a6d3f2aa30156267ad279682e66d99558a633',
    [string]$RmiiRef = '5fef5b5641029777655c5fc34228c3a8b13e4ac9'
)

$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
$git = Get-Command git -ErrorAction Stop
$runId = Get-Date -Format 'yyyyMMdd_HHmmss'
$manifestPath = Join-Path $workspace 'bootstrap_manifest.json'

$repositories = @(
    [pscustomobject]@{ Name = 'MCU';  Url = $McuUrl;  Ref = $McuRef },
    [pscustomobject]@{ Name = 'FPGA'; Url = $FpgaUrl; Ref = $FpgaRef },
    [pscustomobject]@{ Name = 'Host'; Url = $HostUrl; Ref = $HostRef }
)

$thirdParty = @(
    [pscustomobject]@{
        Name = 'taxi'
        Url = $TaxiUrl
        Ref = $TaxiRef
        RelativePath = 'FPGA\third_party\taxi'
        RequiredFile = 'src\eth\rtl\taxi_eth_mac_mii_fifo.f'
    },
    [pscustomobject]@{
        Name = 'FPGA-RMII-SMII'
        Url = $RmiiUrl
        Ref = $RmiiRef
        RelativePath = 'FPGA\third_party\FPGA-RMII-SMII'
        RequiredFile = 'RTL\rmii_phy_if.v'
    }
)

$planRows = @(
    foreach ($repo in $repositories) {
        [pscustomobject]@{
            Kind = 'first-party'
            Name = $repo.Name
            Destination = Join-Path $workspace $repo.Name
            Ref = $repo.Ref
        }
    }
    foreach ($repo in $thirdParty) {
        [pscustomobject]@{
            Kind = 'third-party'
            Name = $repo.Name
            Destination = Join-Path $workspace $repo.RelativePath
            Ref = $repo.Ref
        }
    }
)

$planRows | Format-Table -AutoSize
Write-Host "Manifest: $manifestPath"
if ($PreflightOnly -or $WhatIfPreference) {
    Write-Host 'PREFLIGHT_ONLY=PASS; no directory or repository was changed.'
    exit 0
}

if (Test-Path -LiteralPath $workspace -PathType Container) {
    $unexpected = @(
        Get-ChildItem -LiteralPath $workspace -Force -ErrorAction Stop |
          Where-Object { $_.Name -notin @('MCU', 'FPGA', 'Host') }
    )
    if ($unexpected.Count -ne 0) {
        throw "Workspace contains unmanaged entries: $workspace"
    }
} elseif ($PSCmdlet.ShouldProcess($workspace, 'Create reproduction workspace')) {
    New-Item -ItemType Directory -Path $workspace | Out-Null
}

function Resolve-PinnedRepository {
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [string]$Url,
        [Parameter(Mandatory = $true)] [string]$Ref,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    if (!(Test-Path -LiteralPath (Join-Path $Destination '.git'))) {
        if (!$PSCmdlet.ShouldProcess($Destination, "Clone $Name")) { return }
        & $git.Source clone --no-checkout $Url $Destination
        if ($LASTEXITCODE -ne 0) { throw "$Name clone failed" }
        & $git.Source -C $Destination checkout --detach $Ref
        if ($LASTEXITCODE -ne 0) { throw "$Name checkout failed: $Ref" }
    }

    $actual = (& $git.Source -C $Destination rev-parse HEAD).Trim()
    $dirty = @(& $git.Source -C $Destination status --porcelain)
    if (!$actual.StartsWith($Ref, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name HEAD mismatch: expected $Ref, actual $actual"
    }
    if ($dirty.Count -ne 0) {
        throw "$Name repository is dirty: $Destination"
    }
    [pscustomobject]@{
        name = $Name
        url = $Url
        requested_ref = $Ref
        resolved_commit = $actual
        dirty = $false
        path = $Destination
    }
}

$resolved = @(
    foreach ($repo in $repositories) {
        Resolve-PinnedRepository -Name $repo.Name -Url $repo.Url `
          -Ref $repo.Ref -Destination (Join-Path $workspace $repo.Name)
    }
)

$resolvedDependencies = @(
    foreach ($repo in $thirdParty) {
        $destination = Join-Path $workspace $repo.RelativePath
        $record = Resolve-PinnedRepository -Name $repo.Name -Url $repo.Url `
          -Ref $repo.Ref -Destination $destination
        $requiredPath = Join-Path $destination $repo.RequiredFile
        if (!(Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "$($repo.Name) required source is missing: $requiredPath"
        }
        $record
    }
)

$manifest = [ordered]@{
    schema_version = 1
    run_id = "bootstrap_$runId"
    created_utc = [DateTime]::UtcNow.ToString('o')
    status = 'bootstrap_ready'
    workspace_root = $workspace
    git_version = (& $git.Source --version).Trim()
    powershell_version = $PSVersionTable.PSVersion.ToString()
    repositories = $resolved
    third_party = $resolvedDependencies
    runtime_identity = [ordered]@{
        mcu_firmware_sha256 = $null
        fpga_bit_sha256 = $null
        fpga_ltx_sha256 = $null
        host_interface_guid = $null
        camera_ids = @()
        capture_root = $null
        intrinsic_sha256 = @()
        extrinsic_sha256 = $null
        result_status = 'NOT_RUN'
    }
    evidence_rule = 'No evidence promotion across layers.'
}
$manifest | ConvertTo-Json -Depth 8 |
  Set-Content -LiteralPath $manifestPath -Encoding utf8
Write-Host 'BOOTSTRAP_STATUS=PASS'
Write-Host "BOOTSTRAP_MANIFEST=$manifestPath"
exit 0
