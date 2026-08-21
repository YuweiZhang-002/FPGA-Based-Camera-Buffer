function Get-CaptureHealth {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Stage
    )

    $results = @()
    foreach ($cam in 0, 1) {
        $camRoot = Join-Path $Root "cam$cam"
        $pgm = @(Get-ChildItem -LiteralPath $camRoot -Filter '*.pgm' `
          -File -ErrorAction SilentlyContinue).Count
        $raw = @(Get-ChildItem -LiteralPath $camRoot -Filter '*.raw' `
          -File -ErrorAction SilentlyContinue).Count
        $sidecars = @(Get-ChildItem -LiteralPath $camRoot -Filter '*.json' `
          -File -ErrorAction SilentlyContinue)
        $docs = @($sidecars | ForEach-Object {
            Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json
        })
        $rowCsv = Join-Path $camRoot 'rows_v2.csv'

        $results += [pscustomobject]@{
            Stage = $Stage
            Camera = "cam$cam"
            PGM = $pgm
            RAW = $raw
            JSON = $sidecars.Count
            RowsCsv = Test-Path -LiteralPath $rowCsv
            NonComplete = @($docs | Where-Object status -ne 'COMPLETE').Count
            Missing = @($docs | Where-Object { [int]$_.missing_count -ne 0 }).Count
            Overflow = @($docs | Where-Object had_overflow -eq $true).Count
            CRC = @($docs | Where-Object had_crc_error -eq $true).Count
            Sync = @($docs | Where-Object had_sync_error -eq $true).Count
            Conflict = @($docs | Where-Object had_conflicting_duplicate -eq $true).Count
            BadGeometry = @($docs | Where-Object {
                [int]$_.width -ne 640 -or [int]$_.height -ne 480 -or
                [int]$_.row_count -ne 480
            }).Count
        }
    }
    return $results
}

function Assert-CaptureHealth {
    param(
        [Parameter(Mandatory = $true)][object[]]$Health
    )

    $bad = @($Health | Where-Object {
        $_.PGM -eq 0 -or $_.PGM -ne $_.RAW -or $_.PGM -ne $_.JSON -or
        !$_.RowsCsv -or $_.NonComplete -ne 0 -or $_.Missing -ne 0 -or
        $_.Overflow -ne 0 -or $_.CRC -ne 0 -or $_.Sync -ne 0 -or
        $_.Conflict -ne 0 -or $_.BadGeometry -ne 0
    })
    if ($bad.Count -ne 0) {
        $bad | Format-Table -AutoSize
        throw 'Capture failed the dual-camera integrity gate'
    }
}
