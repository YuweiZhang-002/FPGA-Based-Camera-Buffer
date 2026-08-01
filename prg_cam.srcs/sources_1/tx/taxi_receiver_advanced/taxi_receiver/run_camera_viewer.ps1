param(
    [string]$ArchiveRoot = 'D:\prg\prg_cam\images\temp\archive',

    [string]$Attempt = 'attempt1',

    [string]$Camera = '',

    [int]$RefreshIntervalMs = 50,

    [int]$PollIntervalMs = 50,

    [string]$PythonExe = 'C:\Users\Z\AppData\Local\Python\bin\python.exe'
)

$ErrorActionPreference = 'Stop'
$viewerRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $viewerRoot
try {
    & $PythonExe -m taxi_receiver.viewer_cli `
        --archive-root $ArchiveRoot `
        --attempt $Attempt `
        --camera $Camera `
        --refresh-interval-ms $RefreshIntervalMs `
        --poll-interval-ms $PollIntervalMs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
