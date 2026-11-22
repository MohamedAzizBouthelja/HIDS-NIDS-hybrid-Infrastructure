# Count only Ethernet/IPv4 ARP for the two pilot clients. GNS3's x86
# uBridge writes little-endian classic Ethernet PCAP.
function Read-PilotArpCapture([string] $Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 24 -or [BitConverter]::ToString($b,0,4) -notin 'D4-C3-B2-A1','4D-3C-B2-A1' -or
        [BitConverter]::ToUInt32($b,20) -ne 1) { throw 'Missing or unsupported Ethernet PCAP header.' }
    $frames = 0
    $counts = [ordered]@{}
    for ($i = 24; $i + 16 -le $b.Length;) {
        $length = [long][BitConverter]::ToUInt32($b,$i+8)
        $i += 16
        if ($length -gt $b.Length - $i) { break } # A bounded stream may end mid-frame.
        $start = $i
        $i += $length
        $frames++
        if ($length -lt 42) { continue }
        $type = $b[$start+12]*256 + $b[$start+13]
        $arp = $start + 14
        $tag = 'untagged'
        if ($type -eq 0x8100 -and $length -ge 46) {
            $tag = 'VLAN ' + (($b[$arp]*256 + $b[$arp+1]) -band 4095)
            $type = $b[$arp+2]*256 + $b[$arp+3]
            $arp += 4
        }
        if ($type -ne 0x0806 -or [BitConverter]::ToString($b,$arp,6) -ne '00-01-08-00-06-04') { continue }
        $sender = $b[($arp+14)..($arp+17)] -join '.'
        $target = $b[($arp+24)..($arp+27)] -join '.'
        $op = $b[$arp+6]*256 + $b[$arp+7]
        if ($sender -eq '192.168.10.11' -and $target -eq '192.168.10.12' -and $op -eq 1) { $kind = 'A request' }
        elseif ($sender -eq '192.168.10.12' -and $target -eq '192.168.10.11' -and $op -eq 2) { $kind = 'B reply' }
        else { continue }
        $counts["$kind ($tag)"]++
    }
    return [ordered]@{ complete_frames = $frames; arp = $counts }
}

function Write-PilotWireEvidence {
    $started = [ordered]@{}
    $result.wire_observations = [ordered]@{}
    $cables = [ordered]@{
        client_a = 'Client-A:0|OpenvSwitch-1:2'
        eth0 = 'OpenvSwitch-1:0|OpenvSwitch-2:0'
        eth1 = 'OpenvSwitch-1:1|OpenvSwitch-2:1'
        client_b = 'Client-B:0|OpenvSwitch-2:2'
    }
    try {
        foreach ($label in $cables.Keys) {
            $link = $seen[$cables[$label]]
            $url = "$api$projectPath/links/$(([guid]$link.link_id).ToString())"
            if ((Invoke-RestMethod -Uri $url -TimeoutSec 5).capturing) { throw "Capture already active on $label." }
            $body = @{ capture_file_name = "lacp-$label-$([guid]::NewGuid().ToString('N')).pcap" } | ConvertTo-Json
            $null = Invoke-RestMethod -Method Post -Uri "$url/start_capture" -ContentType 'application/json' -Body $body -TimeoutSec 10
            $started[$label] = $url
        }
        $null = Invoke-VpcsCommand 'Client-A' 'clear arp' '(?im)^clear arp[ \t\r]*$'
        $null = Invoke-VpcsPing 'Client-A' '192.168.10.12' 1
        foreach ($label in $started.Keys) {
            try {
                $file = Join-Path (Resolve-Path $EvidenceDirectory).Path "$label-$([guid]::NewGuid().ToString('N')).pcap"
                # The GNS3 endpoint streams until disconnected. Retain the received prefix.
                & curl.exe --silent --fail --max-time 3 --output $file "$($started[$label])/pcap"
                if ($LASTEXITCODE -notin 0,28) { throw "PCAP stream returned curl exit $LASTEXITCODE." }
                if ($LASTEXITCODE -eq 28 -and -not (Test-Path -LiteralPath $file -PathType Leaf)) {
                    $result.wire_observations[$label] = @{ status = 'stream timed out without data' }
                    Write-Warning "No capture data returned for $label before timeout."
                    continue
                }
                $observation = Read-PilotArpCapture $file
                $result.wire_observations[$label] = $observation
                Write-Host "ARP on ${label}: $($observation | ConvertTo-Json -Compress)"
            } catch { Write-Warning "Could not read ${label}: $($_.Exception.Message)" }
        }
    }
    finally {
        foreach ($url in $started.Values) {
            try { $null = Invoke-RestMethod -Method Post -Uri "$url/stop_capture" -TimeoutSec 10 }
            catch { Write-Warning "Could not stop capture at $url" }
        }
    }
}
