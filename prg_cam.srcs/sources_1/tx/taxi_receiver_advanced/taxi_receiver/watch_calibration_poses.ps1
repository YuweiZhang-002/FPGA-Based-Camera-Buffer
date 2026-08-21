param(
    [Parameter(Mandatory = $true)]
    [string]$ImagesRoot,

    [ValidateRange(0, 1)]
    [int]$CameraId = 1,

    [int]$MinPoses = 25,

    [string]$WindowLabel = '',

    [string]$Report = '',

    [string]$Montage = '',

    [double]$PollIntervalSeconds = 0.5,

    [string]$PythonExe =
      'C:\Users\Z\AppData\Local\Python\pythoncore-3.14-64\python.exe'
)

$ErrorActionPreference = 'Stop'
if ($MinPoses -lt 1) {
    throw 'MinPoses must be positive.'
}
if ($PollIntervalSeconds -le 0.0) {
    throw 'PollIntervalSeconds must be positive.'
}

$receiverRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$datasetRoot = [IO.Path]::GetFullPath($ImagesRoot)
$cameraRoot = Join-Path $datasetRoot "cam$CameraId"
New-Item -ItemType Directory -Force -Path $cameraRoot | Out-Null
$stageLabel = if ([string]::IsNullOrWhiteSpace($WindowLabel)) {
    Split-Path -Leaf $datasetRoot
} else {
    $WindowLabel
}

if ([string]::IsNullOrWhiteSpace($Report)) {
    $Report = Join-Path $datasetRoot "cam${CameraId}_preflight.csv"
}
if ([string]::IsNullOrWhiteSpace($Montage)) {
    $Montage = Join-Path $datasetRoot "cam${CameraId}_preflight_montage.png"
}

try {
    $Host.UI.RawUI.WindowTitle =
      "$stageLabel - cam$CameraId valid frames / poses"
}
catch {
    # Some redirected/non-interactive hosts do not expose a writable title.
}
Write-Host "Monitoring: $cameraRoot"
Write-Host "Stage: $stageLabel"
Write-Host (
    'Each line reports valid_frames=<complete 44-point grids>/<inspected> ' +
    "and poses=<distinct poses>/$MinPoses."
)
Write-Host 'Press Ctrl+C after capture has stopped to write the CSV and montage.'

$arguments = @(
    (Join-Path $receiverRoot 'preflight_calibration_frames.py'),
    $cameraRoot,
    '--watch',
    '--poll-interval', $PollIntervalSeconds,
    '--min-poses', $MinPoses,
    '--width', 640,
    '--height', 480,
    '--pattern', 'asymmetric',
    '--columns', 4,
    '--rows', 11,
    '--zone-map',
    '--report', $Report,
    '--montage', $Montage
)

Push-Location $receiverRoot
try {
    & $PythonExe @arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Calibration monitor failed with exit code $exitCode"
    }
}
finally {
    Pop-Location
}
