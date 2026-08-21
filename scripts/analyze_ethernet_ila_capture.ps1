param(
    [string]$CsvPath = (Join-Path $PSScriptRoot "..\build\ethernet_ila\frame_handshake_capture.csv")
)

$rows = @(Import-Csv -LiteralPath $CsvPath | Where-Object { $_.'Sample in Buffer' -ne 'Radix - UNSIGNED' })
if ($rows.Count -eq 0) { throw "No ILA samples found in $CsvPath" }

function HexValue([string]$Text) {
    return [Convert]::ToInt32($Text, 16)
}

function EthernetFcs($Bytes) {
    [uint64]$crc = 4294967295
    foreach ($byte in $Bytes) {
        $crc = ($crc -bxor [uint64]$byte) -band 4294967295
        for ($bit = 0; $bit -lt 8; $bit++) {
            if (($crc -band 1) -ne 0) {
                $crc = (($crc -shr 1) -bxor [uint64]3988292384) -band 4294967295
            } else {
                $crc = ($crc -shr 1) -band 4294967295
            }
        }
    }
    return ($crc -bxor [uint64]4294967295) -band 4294967295
}

$expectedHeader = @(0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x02,0x00,0x00,0x00,0x00,0x02,0x88,0xB5)
$handshakes = @()
$packetHandshakes = @()
$triggerSamples = @()
for ($i = 0; $i -lt $rows.Count; $i++) {
    $row = $rows[$i]
    if ($row.TRIGGER -eq '1') { $triggerSamples += $i }
    if ($row.frame_valid -eq '1' -and $row.frame_ready -eq '1') {
        $handshakes += [pscustomobject]@{ Sample=$i; Data=(HexValue $row.'frame_data[7:0]'); Last=($row.frame_last -eq '1') }
    }
    if ($row.packet_valid -eq '1' -and $row.packet_ready -eq '1') {
        $packetHandshakes += [pscustomobject]@{ Sample=$i; Data=(HexValue $row.'packet_data[7:0]'); Last=($row.packet_last -eq '1') }
    }
}

function Get-CompleteSequences($Events, [int]$ExpectedLength) {
    $result = @()
    $start = 0
    for ($i = 0; $i -lt $Events.Count; $i++) {
        if ($Events[$i].Last) {
            $length = $i - $start + 1
            if ($start -gt 0 -or $length -eq $ExpectedLength) {
                $result += ,@($Events[$start..$i])
            }
            $start = $i + 1
        }
    }
    return $result
}

$frameSequences = @(Get-CompleteSequences $handshakes 142 | Where-Object { $_.Count -eq 142 })
$packetSequences = @(Get-CompleteSequences $packetHandshakes 128 | Where-Object { $_.Count -eq 128 })
$headerPass = $true
$framePayloadPass = $true
$frameLastPass = $true
foreach ($seq in $frameSequences) {
    for ($i = 0; $i -lt 14; $i++) {
        if ($seq[$i].Data -ne $expectedHeader[$i]) { $headerPass = $false }
    }
    for ($i = 0; $i -lt 128; $i++) {
        if ($seq[$i+14].Data -ne $i) { $framePayloadPass = $false }
    }
    if (-not $seq[141].Last -or $seq[141].Data -ne 0x7F) { $frameLastPass = $false }
    if (@($seq[0..140] | Where-Object Last).Count -ne 0) { $frameLastPass = $false }
}

$packetPass = $true
foreach ($seq in $packetSequences) {
    for ($i = 0; $i -lt 128; $i++) {
        if ($seq[$i].Data -ne $i) { $packetPass = $false }
    }
    if (-not $seq[127].Last) { $packetPass = $false }
}

$txBursts = @()
$burstStart = $null
for ($i = 0; $i -le $rows.Count; $i++) {
    $high = ($i -lt $rows.Count -and $rows[$i].rmii_tx_en_dbg -eq '1')
    if ($high -and $null -eq $burstStart) { $burstStart = $i }
    if (-not $high -and $null -ne $burstStart) {
        $burstRows = @($rows[$burstStart..($i-1)])
        $distinctTxd = @($burstRows | ForEach-Object { $_.'rmii_txd_dbg[1:0]' } | Sort-Object -Unique)
        $txBursts += [pscustomobject]@{
            Start=$burstStart; End=($i-1); Samples=$burstRows.Count
            DistinctTxd=($distinctTxd -join ',')
            Complete=($burstStart -gt 0 -and $i -lt $rows.Count)
        }
        $burstStart = $null
    }
}

$completeBursts = @($txBursts | Where-Object Complete)
$decoded = @()
foreach ($burst in $completeBursts) {
    $dibits = @($rows[$burst.Start..$burst.End] | Where-Object { $_.phy_ref_clk -eq '1' } | ForEach-Object { HexValue $_.'rmii_txd_dbg[1:0]' })
    $bytes = @()
    for ($i = 0; $i + 3 -lt $dibits.Count; $i += 4) {
        $bytes += ($dibits[$i] -bor ($dibits[$i+1] -shl 2) -bor ($dibits[$i+2] -shl 4) -bor ($dibits[$i+3] -shl 6))
    }
    $preamblePass = ($bytes.Count -eq 154)
    for ($i = 0; $i -lt [Math]::Min(7, $bytes.Count); $i++) {
        if ($bytes[$i] -ne 0x55) { $preamblePass = $false }
    }
    if ($bytes.Count -lt 8 -or $bytes[7] -ne 0xD5) { $preamblePass = $false }
    $fcsText = 'n/a'
    $expectedFcsText = 'n/a'
    $fcsPass = $false
    if ($bytes.Count -eq 154) {
        $frameBytes = @($bytes[8..149])
        [uint64]$expectedFcs = EthernetFcs $frameBytes
        $expectedFcsBytes = @(($expectedFcs -band 0xFF), (($expectedFcs -shr 8) -band 0xFF), (($expectedFcs -shr 16) -band 0xFF), (($expectedFcs -shr 24) -band 0xFF))
        $actualFcsBytes = @($bytes[150..153])
        $fcsText = (($actualFcsBytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
        $expectedFcsText = (($expectedFcsBytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
        $fcsPass = (($actualFcsBytes -join ',') -eq ($expectedFcsBytes -join ','))
    }
    $decoded += [pscustomobject]@{
        Start=$burst.Start; Samples=$burst.Samples; Dibits=$dibits.Count; Bytes=$bytes.Count
        Prefix=(($bytes | Select-Object -First 22 | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
        Suffix=(($bytes | Select-Object -Last 8 | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
        PreamblePass=$preamblePass; Fcs=$fcsText; ExpectedFcs=$expectedFcsText; FcsPass=$fcsPass
    }
}

$txdChangesWhileTxen = 0
for ($i = 1; $i -lt $rows.Count; $i++) {
    if ($rows[$i].rmii_tx_en_dbg -eq '1' -and $rows[$i].'rmii_txd_dbg[1:0]' -ne $rows[$i-1].'rmii_txd_dbg[1:0]') {
        $txdChangesWhileTxen++
    }
}

$errors = @($rows | Where-Object { $_.tx_error_underflow -eq '1' -or $_.tx_fifo_overflow -eq '1' })
$goodPulseSamples = @($rows | Where-Object { $_.tx_fifo_good_frame -eq '1' }).Count

Write-Output "samples=$($rows.Count) trigger_samples=$($triggerSamples -join ',')"
Write-Output "frame_handshakes=$($handshakes.Count) complete_142B_frames=$($frameSequences.Count) header_pass=$headerPass payload_pass=$framePayloadPass last_pass=$frameLastPass"
Write-Output "packet_handshakes=$($packetHandshakes.Count) complete_128B_packets=$($packetSequences.Count) packet_sequence_last_pass=$packetPass"
Write-Output "txen_high_samples=$(@($rows | Where-Object rmii_tx_en_dbg -eq '1').Count) tx_bursts=$($txBursts.Count) complete_tx_bursts=$($completeBursts.Count) txd_changes_while_txen=$txdChangesWhileTxen"
foreach ($burst in $txBursts) { Write-Output "tx_burst start=$($burst.Start) end=$($burst.End) samples=$($burst.Samples) complete=$($burst.Complete) txd_values=$($burst.DistinctTxd)" }
for ($i = 1; $i -lt $txBursts.Count; $i++) {
    Write-Output "tx_ifg previous_end=$($txBursts[$i-1].End) next_start=$($txBursts[$i].Start) low_samples=$($txBursts[$i].Start-$txBursts[$i-1].End-1)"
}
foreach ($item in $decoded) { Write-Output "rmii_decode start=$($item.Start) samples=$($item.Samples) dibits=$($item.Dibits) bytes=$($item.Bytes) preamble_sfd_pass=$($item.PreamblePass) prefix=$($item.Prefix) suffix=$($item.Suffix) fcs=$($item.Fcs) expected_fcs=$($item.ExpectedFcs) fcs_pass=$($item.FcsPass)" }
Write-Output "underflow_or_overflow_high_samples=$($errors.Count) tx_fifo_good_frame_high_samples=$goodPulseSamples"

if ($frameSequences.Count -gt 0) {
    Write-Output "first_complete_frame_header=$((($frameSequences[0][0..13] | ForEach-Object { '{0:X2}' -f $_.Data }) -join ' '))"
    Write-Output "first_complete_frame_tail=$((($frameSequences[0][138..141] | ForEach-Object { '{0:X2}' -f $_.Data }) -join ' ')) last=$($frameSequences[0][141].Last)"
}
