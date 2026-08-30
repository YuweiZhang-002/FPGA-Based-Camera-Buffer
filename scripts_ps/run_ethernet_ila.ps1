[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'Build',
        'Program',
        'Observe',
        'Capture',
        'DiagnoseDrops',
        'PlainBit'
    )]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$VivadoBin,

    [string]$TriggerName = 'camera_packet_valid',

    [ValidateRange(0, 4095)]
    [int]$TriggerPosition = 512,

    [ValidateRange(1, 3600000)]
    [int]$ObserveMs = 10000,

    [ValidateRange(1, 86400)]
    [int]$DiagnoseSeconds = 60,

    [string]$RunRoot,

    [switch]$PreflightOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptMap = @{
    Build         = 'scripts\build_ethernet_ila.tcl'
    Program       = 'scripts\program_ethernet_ila.tcl'
    Observe       = 'scripts\observe_ethernet_ila_trigger.tcl'
    Capture       = 'scripts\capture_ethernet_ila.tcl'
    DiagnoseDrops = 'scripts\diagnose_fpga_host_drops_60s.tcl'
    PlainBit      = 'scripts\rebuild_gui_ethernet.tcl'
}
$markerMap = @{
    Build         = 'ILA_BUILD_RESULT=PASS'
    Program       = 'HW_ILA_PROGRAM_RESULT=PASS'
    Observe       = 'ILA_OBSERVE_RESULT='
    Capture       = 'ILA_CAPTURE_RESULT=PASS'
    DiagnoseDrops = 'DROP_DIAG_RESULT=PASS'
    PlainBit      = 'GUI_REBUILD_RESULT=PASS'
}

$vivadoPath = [System.IO.Path]::GetFullPath($VivadoBin)
$tclPath = Join-Path $repoRoot $scriptMap[$Action]
$ilaRoot = Join-Path $repoRoot 'build\ethernet_ila'
$bitPath = Join-Path $ilaRoot 'Camera_Ethernet_Top_ila.bit'
$ltxPath = Join-Path $ilaRoot 'Camera_Ethernet_Top_ila.ltx'
$plainRoot = Join-Path $repoRoot 'build\gui_ethernet_rebuild'
$plainBitPath = Join-Path $plainRoot 'Camera_Ethernet_Top.bit'
$plainDcpPath = Join-Path $plainRoot 'Camera_Ethernet_Top_routed.dcp'

if ([string]::IsNullOrWhiteSpace($RunRoot)) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $RunRoot = Join-Path $repoRoot (
        'build\ila_runs\{0}_{1}' -f $stamp, $Action.ToLowerInvariant()
    )
}
$runPath = [System.IO.Path]::GetFullPath($RunRoot)

$requiredPaths = @($vivadoPath, $tclPath)
switch ($Action) {
    'Build' {
        $requiredPaths += Join-Path $repoRoot 'scripts\recreate_project.tcl'
        $requiredPaths += Join-Path $repoRoot (
            'third_party\taxi\src\eth\rtl\' +
            'taxi_eth_mac_mii_fifo.f'
        )
        $requiredPaths += Join-Path $repoRoot (
            'third_party\FPGA-RMII-SMII\RTL\' +
            'rmii_phy_if.v'
        )
    }
    'PlainBit' {
        $requiredPaths += Join-Path $repoRoot 'scripts\recreate_project.tcl'
        $requiredPaths += Join-Path $repoRoot (
            'third_party\taxi\src\eth\rtl\' +
            'taxi_eth_mac_mii_fifo.f'
        )
        $requiredPaths += Join-Path $repoRoot (
            'third_party\FPGA-RMII-SMII\RTL\' +
            'rmii_phy_if.v'
        )
    }
    'Program' {
        $requiredPaths += $bitPath, $ltxPath
    }
    default {
        $requiredPaths += $ltxPath
    }
}

$missing = @(
    foreach ($path in $requiredPaths) {
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
            $path
        }
    }
)

$plan = [pscustomobject]@{
    Action          = $Action
    Repository      = $repoRoot
    Vivado          = $vivadoPath
    TclScript       = $tclPath
    RunRoot         = $runPath
    TriggerName     = $TriggerName
    TriggerPosition = $TriggerPosition
    ObserveMs       = $ObserveMs
    DiagnoseSeconds = $DiagnoseSeconds
}
$plan | Format-List

if ($missing.Count -gt 0) {
    [Console]::Error.WriteLine(
        "PRECHECK failed. Missing required paths:`n  " +
        ($missing -join "`n  ")
    )
    exit 1
}

if (Test-Path -LiteralPath $runPath) {
    $existing = @(
        Get-ChildItem -LiteralPath $runPath -Force -ErrorAction SilentlyContinue |
            Select-Object -First 1
    )
    if ($existing.Count -gt 0) {
        [Console]::Error.WriteLine("Run directory is not empty: $runPath")
        exit 2
    }
}

if ($PreflightOnly -or $WhatIfPreference) {
    Write-Host 'PRECHECK_RESULT=PASS'
    Write-Host 'DRY_RUN_RESULT=PASS'
    exit 0
}

New-Item -ItemType Directory -Force -Path $runPath | Out-Null
$logPath = Join-Path $runPath ("{0}.log" -f $Action.ToLowerInvariant())
$manifestPath = Join-Path $runPath 'run_manifest.json'
$captureCsv = Join-Path $runPath 'ila_capture.csv'
$dropRoot = Join-Path $runPath 'drop_diagnosis'

$gitHead = (& git -C $repoRoot rev-parse HEAD 2>$null)
$gitDirty = @(& git -C $repoRoot status --porcelain 2>$null).Count -gt 0
$startedAt = Get-Date

$environmentValues = @{
    # This workstation's per-user Tcl app manifest makes Vivado fail during
    # load_features ([Common 17-356]).  Built-in synthesis, implementation,
    # Chipscope, and hw_manager features remain available with local apps off.
    XILINX_LOCAL_USER_DATA = 'no'
    ILA_TRIGGER_NAME     = $TriggerName
    ILA_TRIGGER_POSITION = [string]$TriggerPosition
    ILA_CAPTURE_CSV      = $captureCsv
    ILA_OBSERVE_MS       = [string]$ObserveMs
    DROP_DIAG_SECONDS    = [string]$DiagnoseSeconds
    DROP_DIAG_OUT_DIR    = $dropRoot
}
$savedEnvironment = @{}
foreach ($name in $environmentValues.Keys) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable(
        $name,
        'Process'
    )
    [Environment]::SetEnvironmentVariable(
        $name,
        $environmentValues[$name],
        'Process'
    )
}

$exitCode = 5
$toolExitCode = $null
$status = 'internal_error'
try {
    Push-Location $repoRoot
    try {
        # Windows PowerShell 5 can promote native stderr records to terminating
        # errors when the outer preference is Stop.  Vivado uses stderr for a
        # normal nonzero diagnostic, so preserve its real process exit code
        # before applying the wrapper status contract.
        $savedErrorPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $vivadoPath `
                -mode batch `
                -nolog `
                -nojournal `
                -source $tclPath `
                2>&1 |
                Tee-Object -FilePath $logPath
            $toolExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $savedErrorPreference
        }
    }
    finally {
        Pop-Location
    }

    if ($toolExitCode -ne 0) {
        $exitCode = 5
        $status = 'vivado_failed'
        throw "Vivado exited with code $toolExitCode. See $logPath"
    }
    $exitCode = 0

    $marker = $markerMap[$Action]
    $markerSeen = Select-String `
        -LiteralPath $logPath `
        -SimpleMatch $marker `
        -Quiet
    if (!$markerSeen) {
        $exitCode = 4
        $status = 'validation_failed'
        throw "Expected completion marker was not found: $marker"
    }
    if ($Action -eq 'Capture' -and
        !(Test-Path -LiteralPath $captureCsv -PathType Leaf)) {
        $exitCode = 4
        $status = 'validation_failed'
        throw "ILA capture CSV was not generated: $captureCsv"
    }

    $status = 'pass'
}
catch {
    [Console]::Error.WriteLine([string]$_)
}
finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable(
            $name,
            $savedEnvironment[$name],
            'Process'
        )
    }

    $artifactSpecs = @(
        [pscustomobject]@{ Path = $logPath; Role = 'execution_log' }

        if ($Action -in @('Program', 'Observe', 'Capture', 'DiagnoseDrops')) {
            [pscustomobject]@{ Path = $ltxPath; Role = 'probe_map_input' }
        }
        if ($Action -eq 'Program') {
            [pscustomobject]@{ Path = $bitPath; Role = 'bitstream_input' }
        }
        if ($status -eq 'pass' -and $Action -eq 'Build') {
            [pscustomobject]@{ Path = $bitPath; Role = 'generated_bitstream' }
            [pscustomobject]@{ Path = $ltxPath; Role = 'generated_probe_map' }
            foreach ($name in 'timing_summary.rpt', 'drc.rpt', 'utilization.rpt') {
                [pscustomobject]@{
                    Path = Join-Path $ilaRoot $name
                    Role = 'generated_report'
                }
            }
        }
        if ($status -eq 'pass' -and $Action -eq 'PlainBit') {
            [pscustomobject]@{ Path = $plainBitPath; Role = 'generated_bitstream' }
            [pscustomobject]@{ Path = $plainDcpPath; Role = 'generated_checkpoint' }
            foreach ($name in @(
                'timing_summary.rpt',
                'reset_exception_coverage.rpt',
                'cdc.rpt',
                'drc.rpt',
                'utilization.rpt'
            )) {
                [pscustomobject]@{
                    Path = Join-Path $plainRoot $name
                    Role = 'generated_report'
                }
            }
        }
        if ($status -eq 'pass' -and $Action -eq 'Capture') {
            [pscustomobject]@{ Path = $captureCsv; Role = 'generated_ila_csv' }
        }
        if ($status -eq 'pass' -and $Action -eq 'DiagnoseDrops' -and
            (Test-Path -LiteralPath $dropRoot -PathType Container)) {
            foreach ($item in @(
                Get-ChildItem -LiteralPath $dropRoot -Filter '*.csv' -File
            )) {
                [pscustomobject]@{ Path = $item.FullName; Role = 'generated_ila_csv' }
            }
        }
    )

    $artifactRows = @(
        foreach ($spec in $artifactSpecs) {
            if (Test-Path -LiteralPath $spec.Path -PathType Leaf) {
                $evidencePath = $spec.Path
                if ($spec.Role -like 'generated_*' -and
                    !([IO.Path]::GetFullPath($spec.Path).StartsWith(
                        $runPath,
                        [StringComparison]::OrdinalIgnoreCase
                    ))) {
                    $artifactArchive = Join-Path $runPath 'artifacts'
                    New-Item -ItemType Directory -Force -Path $artifactArchive |
                        Out-Null
                    $evidencePath = Join-Path $artifactArchive (
                        Split-Path -Leaf $spec.Path
                    )
                    Copy-Item -LiteralPath $spec.Path -Destination $evidencePath
                }
                $item = Get-Item -LiteralPath $evidencePath
                [ordered]@{
                    path   = $item.FullName
                    role   = $spec.Role
                    bytes  = $item.Length
                    sha256 = (
                        Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256
                    ).Hash
                }
            }
        }
    )

    $manifest = [ordered]@{
        run_id           = Split-Path -Leaf $runPath
        action           = $Action
        status           = $status
        exit_code        = $exitCode
        tool_exit_code   = $toolExitCode
        started_at       = $startedAt.ToString('o')
        completed_at     = (Get-Date).ToString('o')
        git_head         = [string]$gitHead
        git_dirty        = $gitDirty
        vivado           = $vivadoPath
        tcl_script       = $tclPath
        trigger_name     = $TriggerName
        trigger_position = $TriggerPosition
        artifacts        = $artifactRows
    }
    $manifest |
        ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath $manifestPath -Encoding utf8
}

if ($status -ne 'pass') {
    exit $exitCode
}

Write-Host "AUTOMATION_RESULT=PASS"
Write-Host "RUN_MANIFEST=$manifestPath"
exit 0
