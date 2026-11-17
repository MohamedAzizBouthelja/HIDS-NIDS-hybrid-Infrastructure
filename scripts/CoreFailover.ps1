function Invoke-CoreFailover {
    [CmdletBinding()]
    param(
        [ValidateSet('plan', 'apply')][string] $Mode = 'plan',
        [string] $ApiBaseUrl = 'http://127.0.0.1:3076',
        [string] $ManifestPath,
        [string] $EvidenceDirectory,
        [ValidateRange(1,120)][int] $Attempts = 40,
        [ValidateRange(0,10)][int] $PollSeconds = 2
    )
    $ErrorActionPreference = 'Stop'
    # Validate the dedicated project, running nodes, cables and console endpoints.
    Invoke-CoreInterfaceConfiguration -Mode plan -ApiBaseUrl $ApiBaseUrl -ManifestPath $ManifestPath | Out-Null
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $response = Invoke-RestMethod -Uri "$($ApiBaseUrl.TrimEnd('/'))/v2/projects/$($manifest.project.project_id)/nodes" -Method Get -TimeoutSec 15
    $nodes = @($response | ForEach-Object { $_ })
    $plan = 'Temporarily shutdown R1 FastEthernet0/0; verify R1-R3-R4 in both directions; no shutdown; verify R1-R2-R4. No startup save.'
    Write-Output $plan
    if ($Mode -eq 'plan') { return }
    if (-not $EvidenceDirectory) { throw 'Apply requires an evidence directory.' }
    [void](New-Item -ItemType Directory -Path $EvidenceDirectory -Force)
    $sessions = @{}
    $transcript = [System.Collections.Generic.List[object]]::new()
    $observations = [System.Collections.Generic.List[object]]::new()
    $result = [ordered]@{ started_utc = [DateTime]::UtcNow.ToString('o'); plan = $plan; shutdown_attempted = $false; restored = $false; passed = $false; error = ''; restoration_error = '' }
    $result.commit_sha = $env:GITHUB_SHA
    $result.run_id = $env:GITHUB_RUN_ID
    $result.run_attempt = $env:GITHUB_RUN_ATTEMPT
    function Save-FailoverEvidence {
        ConvertTo-Json -InputObject $transcript.ToArray() -Depth 12 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'console-transcript.json') -Encoding UTF8
        ConvertTo-Json -InputObject $observations.ToArray() -Depth 12 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'observations.json') -Encoding UTF8
        $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'result.json') -Encoding UTF8
    }
    function Invoke-FailoverCommand([string] $Name, [string] $Command) {
        $output = Send-IosCommand $sessions[$Name] $Command
        $transcript.Add([pscustomobject]@{ utc = [DateTime]::UtcNow.ToString('o'); router = $Name; command = $Command; output = $output })
        return $output
    }
    function Wait-FailoverPath([string] $Phase, [bool] $Backup) {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
            $valid = $true
            foreach ($name in @('R1','R4')) {
                $destination = if ($name -eq 'R1') { '10.255.0.4' } else { '10.255.0.1' }
                $hop = if ($Backup) { if ($name -eq 'R1') { '10.0.13.2' } else { '10.0.34.1' } } else { if ($name -eq 'R1') { '10.0.12.2' } else { '10.0.24.1' } }
                $iface = if ($Backup) { 'FastEthernet1/0' } else { 'FastEthernet0/0' }
                $output = Invoke-FailoverCommand $name "show ip route $destination"
                $ok = Test-CoreOspfRoute $output 10 ([pscustomobject]@{ next_hop = $hop; interface = $iface }) $destination
                $observations.Add([pscustomobject]@{ phase = $Phase; attempt = $attempt; router = $name; valid = $ok; elapsed_seconds = $timer.Elapsed.TotalSeconds; utc = [DateTime]::UtcNow.ToString('o') })
                if (-not $ok) { $valid = $false }
            }
            Save-FailoverEvidence
            if ($valid) {
                foreach ($name in @('R1','R4')) {
                    $source = if ($name -eq 'R1') { '10.255.0.1' } else { '10.255.0.4' }
                    $destination = if ($name -eq 'R1') { '10.255.0.4' } else { '10.255.0.1' }
                    $null = Invoke-FailoverCommand $name "ping $destination source $source repeat 1 timeout 1"
                    $output = Invoke-FailoverCommand $name "ping $destination source $source repeat 3 timeout 1"
                    if ($output -notmatch 'Success rate is 100 percent\s*\(3/3\)') { throw "$Phase routed ping failed on $name." }
                }
                Write-Output "PASS: $Phase unique next hops and bidirectional loopback pings."
                return
            }
            if ($attempt -lt $Attempts) { Start-Sleep -Seconds $PollSeconds }
        }
        throw "$Phase did not reach the required unique next hops."
    }
    function Restore-FailoverLink {
        # Retry through a fresh connection if an acknowledgement/connection was lost.
        for ($restoreAttempt = 1; $restoreAttempt -le 2; $restoreAttempt++) {
            try {
                if ($restoreAttempt -eq 2) {
                    Close-IosConsole $sessions.R1
                    $node = @($nodes | Where-Object { $_.name -eq 'R1' })[0]
                    $sessions.R1 = Open-IosConsole $node.console_host $node.console
                }
                # end is valid only in configuration mode. At EXEC IOS treats
                # it as a hostname and may spend a minute attempting DNS.
                if ($sessions.R1.Prompt -match '\(') {
                    $null = Invoke-FailoverCommand R1 'end'
                }
                if ($sessions.R1.Prompt -notmatch '^[A-Za-z0-9_.:-]+#$') {
                    throw 'Restoration requires a privileged EXEC prompt on R1.'
                }
                $null = Invoke-FailoverCommand R1 'configure terminal'
                $null = Invoke-FailoverCommand R1 'interface FastEthernet0/0'
                $null = Invoke-FailoverCommand R1 'no shutdown'
                $null = Invoke-FailoverCommand R1 'end'
                $linkUp = $false
                for ($linkAttempt = 0; $linkAttempt -lt 10; $linkAttempt++) {
                    $brief = Invoke-FailoverCommand R1 'show ip interface brief'
                    if ($brief -match '(?m)^FastEthernet0/0\s+10\.0\.12\.1\s+YES\s+\S+\s+up\s+up\s*\r?$') { $linkUp = $true; break }
                    Start-Sleep -Seconds $PollSeconds
                }
                if (-not $linkUp) { throw 'Restored R1 interface is not up/up.' }
                $result.restored = $true
                return
            }
            catch { if ($restoreAttempt -eq 2) { throw } }
        }
    }
    try {
        foreach ($name in @('R1','R4')) {
            $node = @($nodes | Where-Object { $_.name -eq $name })
            if ($node.Count -ne 1) { throw "Missing or duplicate $name." }
            $sessions[$name] = Open-IosConsole $node[0].console_host $node[0].console
        }
        $config = Invoke-FailoverCommand R1 'show running-config interface FastEthernet0/0'
        $brief = Invoke-FailoverCommand R1 'show ip interface brief'
        if ($config -notmatch '(?m)^interface FastEthernet0/0\s*\r?$' -or
            $config -notmatch '(?m)^\s*ip address 10\.0\.12\.1 255\.255\.255\.252\s*\r?$' -or
            $config -match '(?m)^\s*shutdown\s*\r?$' -or
            $brief -notmatch '(?m)^FastEthernet0/0\s+10\.0\.12\.1\s+YES\s+\S+\s+up\s+up\s*\r?$') { throw 'R1 primary interface does not match the active baseline.' }
        Wait-FailoverPath baseline $false
        $null = Invoke-FailoverCommand R1 'configure terminal'
        $null = Invoke-FailoverCommand R1 'interface FastEthernet0/0'
        # Arm cleanup BEFORE sending shutdown: a lost acknowledgement may hide a successful change.
        $result.shutdown_attempted = $true
        $result.shutdown_utc = [DateTime]::UtcNow.ToString('o')
        Save-FailoverEvidence
        try {
            $null = Invoke-FailoverCommand R1 'shutdown'
            $null = Invoke-FailoverCommand R1 'end'
            Wait-FailoverPath backup $true
        }
        finally { Restore-FailoverLink }
        Wait-FailoverPath recovery $false
        $result.passed = $true
    }
    catch {
        $result.error = $_.Exception.Message
        throw
    }
    finally {
        try {
            if ($result.shutdown_attempted -and -not $result.restored) {
                try { Restore-FailoverLink }
                catch {
                    $result.restoration_error = $_.Exception.Message
                    Write-Warning 'RESTORATION FAILED: at R1# run configure terminal, interface FastEthernet0/0, no shutdown, end. If already in configuration mode, use end first.'
                }
            }
            foreach ($session in @($sessions.Values)) {
                try { if ($session.Prompt -match '\(') { $null = Send-IosCommand $session 'end' } } catch { Write-Warning 'Could not exit configuration mode.' }
                try { Close-IosConsole $session } catch { Write-Warning 'Could not close console.' }
            }
        }
        finally { $result.finished_utc = [DateTime]::UtcNow.ToString('o'); Save-FailoverEvidence }
    }
    Write-Output 'VERIFIED: primary baseline, backup through R3, primary recovery; no configuration saved. Timing is route observation latency, not packet-loss convergence.'
}
