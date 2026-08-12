param(
    [Parameter(Mandatory = $true)]
    [string]$Pcap,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,

    [int]$ExpectedRows = 480,

    [string]$ImagesRoot = '',

    [ValidateSet('enabled', 'placeholder')]
    [string]$CrcMode = 'enabled',

    [string]$PythonExe =
        'C:\Users\Z\AppData\Local\Python\bin\python.exe'
)

$ErrorActionPreference = 'Stop'
$receiverRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $receiverRoot
try {
    $receiverArgs = @(
        '-m', 'taxi_receiver.cli',
        '--replay-pcap', $Pcap,
        '--mode', 'camera',
        '--crc-mode', $CrcMode,
        '--max-stage', 'reassemble',
        '--expected-rows', $ExpectedRows,
        '--output-root', $OutputRoot
    )
    if (-not [string]::IsNullOrWhiteSpace($ImagesRoot)) {
        $receiverArgs += @('--images-root', $ImagesRoot)
    }
    & $PythonExe @receiverArgs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
