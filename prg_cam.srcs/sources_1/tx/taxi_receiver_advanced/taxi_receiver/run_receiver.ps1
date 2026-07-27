param(
    [Parameter(Mandatory = $true)]
    [string]$Interface,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,

    [int]$ExpectedRows = 480,

    [int]$QueueDepth = 65536,

    [string]$ImagesRoot = '',

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
        --queue-depth $QueueDepth `
        --output-root $OutputRoot `
        --images-root $ImagesRoot
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
