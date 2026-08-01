param(
    [Parameter(Mandatory = $true)]
    [string]$Interface,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,

    [int]$ExpectedRows = 480,

    [int]$QueueDepth = 65536,

    [int]$FrameOutputQueueDepth = 256,

    [string]$ImagesRoot = '',

    [ValidateSet('strict', 'recover-zero-fill')]
    [string]$ImagePolicy = 'strict',

    [int]$MaxMissingRows = 4,

    [int]$MaxConsecutiveMissing = 2,

    [string]$PythonExe =
        'C:\Users\Z\AppData\Local\Python\bin\python.exe'
)

$ErrorActionPreference = 'Stop'
$receiverRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ImagesRoot)) {
    $ImagesRoot = [IO.Path]::GetFullPath(
        (Join-Path $receiverRoot '..\..\..\..\..\images')
    )
}
Push-Location $receiverRoot
try {
    & $PythonExe -m taxi_receiver.cli `
        --interface $Interface `
        --mode camera `
        --max-stage reassemble `
        --expected-rows $ExpectedRows `
        --image-policy $ImagePolicy `
        --max-missing-rows $MaxMissingRows `
        --max-consecutive-missing $MaxConsecutiveMissing `
        --queue-depth $QueueDepth `
        --frame-output-queue-depth $FrameOutputQueueDepth `
        --output-root $OutputRoot `
        --images-root $ImagesRoot
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
