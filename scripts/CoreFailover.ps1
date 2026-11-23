function Invoke-CoreFailover {
    [CmdletBinding()]
    param(
        [ValidateSet('plan', 'apply')][string] $Mode = 'plan',
        [string] $ApiBaseUrl = 'http://127.0.0.1:3076',
        [string] $ManifestPath,
        [string] $EvidenceDirectory,
        [switch] $CaptureTraceroute,
        [switch] $MeasureLoss,
        [switch] $TestDirectBackup,
        [ValidateRange(1,120)][int] $Attempts = 40,
        [ValidateRange(0,10)][int] $PollSeconds = 2,
        [ValidateSet('R1-R2','R2-R4')][string] $PrimaryLink = 'R1-R2'
    )
    $ErrorActionPreference = 'Stop'
    # Validate the dedicated project, running nodes, cables and console endpoints.
    Invoke-CoreInterfaceConfiguration -Mode plan -ApiBaseUrl $ApiBaseUrl -ManifestPath $ManifestPath | Out-Null
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $response = Invoke-RestMethod -Uri "$($ApiBaseUrl.TrimEnd('/'))/v2/projects/$($manifest.project.project_id)/nodes" -Method Get -TimeoutSec 15
    $nodes = @($response | ForEach-Object { $_ })
    $primary = [ordered]@{ router = 'R1'; interface = 'FastEthernet0/0'; address = '10.0.12.1'; shutdown_attempted = $false; restored = $false; restore_command_utc = @() }
    if ($PrimaryLink -eq 'R2-R4') {
        $primary.router = 'R2'
        $primary.interface = 'FastEthernet1/0'
        $primary.address = '10.0.24.1'
    }
    $target = "$($primary.router) $($primary.interface)"
    $plan = "Verify R1-R2-R4; shut $target and verify R1-R3-R4; "
    if ($TestDirectBackup) {
        $plan += 'shut R1 FastEthernet1/0 and verify direct R1-R4; restore R1 FastEthernet1/0 and verify R1-R3-R4; '
    }
    $plan += "restore $target and verify R1-R2-R4. No startup save."
    Write-Output $plan
    if ($CaptureTraceroute) { Write-Output 'Traceroute capture enabled in both directions at every route checkpoint; maximum TTL 4.' }
    if ($MeasureLoss) { Write-Output 'R4 will probe the R1 loopback around the primary link shutdown and restoration, then path checks will run.' }
    if ($Mode -eq 'plan') { return }
    if (-not $EvidenceDirectory) { throw 'Apply requires an evidence directory.' }
    [void](New-Item -ItemType Directory -Path $EvidenceDirectory -Force)
    $sessions = @{}
    $transcript = [System.Collections.Generic.List[object]]::new()
    $observations = [System.Collections.Generic.List[object]]::new()
    $traces = [System.Collections.Generic.List[object]]::new()
    $result = [ordered]@{ started_utc = [DateTime]::UtcNow.ToString('o'); plan = $plan; shutdown_attempted = $false; restored = $false; passed = $false; error = ''; restoration_error = '' }
    $result.commit_sha = $env:GITHUB_SHA
    $result.run_id = $env:GITHUB_RUN_ID
    $result.run_attempt = $env:GITHUB_RUN_ATTEMPT
    $result.capture_traceroute = [bool]$CaptureTraceroute
    $result.measure_loss = [bool]$MeasureLoss
    $result.test_direct_backup = [bool]$TestDirectBackup
    $result.primary_link = $PrimaryLink
    $secondary = [ordered]@{ router = 'R1'; interface = 'FastEthernet1/0'; address = '10.0.13.1'; shutdown_attempted = $false; restored = $false; restore_command_utc = @() }
    $result.links = [ordered]@{ primary = $primary }
    if ($TestDirectBackup) { $result.links.secondary = $secondary }
    $probe = $null
    function Save-FailoverEvidence {
        ConvertTo-Json -InputObject $transcript.ToArray() -Depth 12 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'console-transcript.json') -Encoding UTF8
        ConvertTo-Json -InputObject $observations.ToArray() -Depth 12 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'observations.json') -Encoding UTF8
        $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'result.json') -Encoding UTF8
        if ($CaptureTraceroute) { ConvertTo-Json -InputObject $traces.ToArray() -Depth 12 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'traceroutes.json') -Encoding UTF8 }
    }
    function Invoke-FailoverCommand([string] $Name, [string] $Command) {
        $output = Send-IosCommand $sessions[$Name] $Command
        $transcript.Add([pscustomobject]@{ utc = [DateTime]::UtcNow.ToString('o'); router = $Name; command = $Command; output = $output })
        return $output
    }
    function Wait-FailoverPath([string] $Phase, [ValidateSet('primary','secondary','direct')][string] $Path) {
        $links = @{
            primary = @{ interface = 'FastEthernet0/0'; R1 = '10.0.12.2'; R4 = '10.0.24.1' }
            secondary = @{ interface = 'FastEthernet1/0'; R1 = '10.0.13.2'; R4 = '10.0.34.1' }
            direct = @{ interface = 'FastEthernet2/0'; R1 = '10.0.14.2'; R4 = '10.0.14.1' }
        }
        $expected = $links[$Path]
        $timer = [Diagnostics.Stopwatch]::StartNew()
        for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
            $valid = $true
            foreach ($name in @('R1','R4')) {
                $destination = if ($name -eq 'R1') { '10.255.0.4' } else { '10.255.0.1' }
                $output = Invoke-FailoverCommand $name "show ip route $destination"
                $ok = Test-CoreOspfRoute $output 10 ([pscustomobject]@{ next_hop = $expected[$name]; interface = $expected.interface }) $destination
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
                    if ($CaptureTraceroute) {
                        # Four TTL levels, one probe each, one-second timeout;
                        # numeric output avoids DNS delays. This is diagnostic
                        # capture: route/ping acceptance remains independent.
                        $command = "traceroute $destination numeric probe 1 source $source timeout 1 ttl 1 4"
                        $output = Invoke-FailoverCommand $name $command
                        $traces.Add([pscustomobject]@{ phase = $Phase; router = $name; utc = [DateTime]::UtcNow.ToString('o'); command = $command; output = $output })
                        Save-FailoverEvidence
                    }
                }
                Write-Output "PASS: $Phase unique next hops and bidirectional loopback pings."
                return
            }
            if ($attempt -lt $Attempts) { Start-Sleep -Seconds $PollSeconds }
        }
        throw "$Phase did not reach the required unique next hops."
    }
    function Test-FailoverInterfaceUp([string] $Brief, [string] $Interface, [string] $Address) {
        return $Brief -match ('(?m)^' + [regex]::Escape($Interface) + '[ \t]+' + [regex]::Escape($Address) + '[ \t]+YES[ \t]+\S+[ \t]+up[ \t]+up\s*\r?$')
    }
    function Assert-FailoverInterface($Link, [string] $Brief) {
        $config = Invoke-FailoverCommand $Link.router "show running-config interface $($Link.interface)"
        if ($config -notmatch ('(?m)^interface ' + [regex]::Escape($Link.interface) + '\s*\r?$') -or
            $config -notmatch ('(?m)^\s*ip address ' + [regex]::Escape($Link.address) + ' 255\.255\.255\.252\s*\r?$') -or
            $config -match '(?m)^\s*shutdown\s*\r?$' -or
            -not (Test-FailoverInterfaceUp $Brief $Link.interface $Link.address)) {
            throw "$($Link.router) $($Link.interface) does not match the active baseline."
        }
    }
    function Disable-FailoverLink($Link) {
        $null = Invoke-FailoverCommand $Link.router 'configure terminal'
        $null = Invoke-FailoverCommand $Link.router "interface $($Link.interface)"
        # A lost acknowledgement can hide a successful change.
        $Link.shutdown_attempted = $true
        $result.shutdown_attempted = $true
        Save-FailoverEvidence
        $Link.shutdown_utc = [DateTime]::UtcNow.ToString('o')
        if ($Link -eq $primary) { $result.shutdown_utc = $Link.shutdown_utc }
        $null = Invoke-FailoverCommand $Link.router 'shutdown'
        $null = Invoke-FailoverCommand $Link.router 'end'
    }
    function Restore-FailoverLink($Link) {
        # Retry through a fresh connection if an acknowledgement/connection was lost.
        for ($restoreAttempt = 1; $restoreAttempt -le 2; $restoreAttempt++) {
            try {
                if ($restoreAttempt -eq 2) {
                    Close-IosConsole $sessions[$Link.router]
                    $node = @($nodes | Where-Object { $_.name -eq $Link.router })[0]
                    $sessions[$Link.router] = Open-IosConsole $node.console_host $node.console
                }
                # end is valid only in configuration mode. At EXEC IOS treats
                # it as a hostname and may spend a minute attempting DNS.
                if ($sessions[$Link.router].Prompt -match '\(') {
                    $null = Invoke-FailoverCommand $Link.router 'end'
                }
                if ($sessions[$Link.router].Prompt -cne "$($Link.router)#") {
                    throw "Restoration requires a privileged EXEC prompt on $($Link.router)."
                }
                $null = Invoke-FailoverCommand $Link.router 'configure terminal'
                $null = Invoke-FailoverCommand $Link.router "interface $($Link.interface)"
                $Link.restore_command_utc += [DateTime]::UtcNow.ToString('o')
                if ($Link -eq $primary) { $result.restore_command_utc = $Link.restore_command_utc }
                $null = Invoke-FailoverCommand $Link.router 'no shutdown'
                $null = Invoke-FailoverCommand $Link.router 'end'
                $linkUp = $false
                for ($linkAttempt = 0; $linkAttempt -lt 10; $linkAttempt++) {
                    $brief = Invoke-FailoverCommand $Link.router 'show ip interface brief'
                    if (Test-FailoverInterfaceUp $brief $Link.interface $Link.address) { $linkUp = $true; break }
                    Start-Sleep -Seconds $PollSeconds
                }
                if (-not $linkUp) { throw "Restored $($Link.router) $($Link.interface) is not up/up." }
                $Link.restored = $true
                Write-Output "RESTORED: $($Link.router) $($Link.interface) is up/up."
                return
            }
            catch { if ($restoreAttempt -eq 2) { throw } }
        }
    }
    function Restore-FailoverLinks {
        $errors = @()
        foreach ($link in @($secondary, $primary)) {
            if ($link.shutdown_attempted -and -not $link.restored) {
                try { Restore-FailoverLink $link }
                catch { $errors += "$($link.router) $($link.interface): $($_.Exception.Message)" }
            }
        }
        $result.restored = $result.shutdown_attempted -and $errors.Count -eq 0
        $result.restoration_error = $errors -join ' | '
        if ($errors.Count -gt 0) { throw $result.restoration_error }
    }
    try {
        $consoleEndpoints = @{}
        $consoleRouters = @('R1','R4')
        if ($primary.router -eq 'R2') { $consoleRouters += 'R2' }
        foreach ($name in $consoleRouters) {
            $node = @($nodes | Where-Object { $_.name -eq $name })
            if ($node.Count -ne 1) { throw "Missing or duplicate $name." }
            $endpoint = '{0}:{1}' -f $node[0].console_host, $node[0].console
            if ($consoleEndpoints.ContainsKey($endpoint)) { throw "Duplicate console endpoint $endpoint." }
            $consoleEndpoints[$endpoint] = $true
            $sessions[$name] = Open-IosConsole $node[0].console_host $node[0].console
            if ($sessions[$name].Prompt -cne "$name#") { throw "Expected $name# at $endpoint. Check the GNS3 console mapping." }
        }
        $brief = Invoke-FailoverCommand $primary.router 'show ip interface brief'
        Assert-FailoverInterface $primary $brief
        if ($TestDirectBackup) {
            $brief = Invoke-FailoverCommand $secondary.router 'show ip interface brief'
            Assert-FailoverInterface $secondary $brief
            $r4Brief = Invoke-FailoverCommand R4 'show ip interface brief'
            if (-not (Test-FailoverInterfaceUp $brief 'FastEthernet2/0' '10.0.14.1') -or
                -not (Test-FailoverInterfaceUp $r4Brief 'FastEthernet2/0' '10.0.14.2')) {
                throw 'Direct R1–R4 link must be up/up at both endpoints before the test.'
            }
        }
        Wait-FailoverPath baseline primary
        if ($MeasureLoss) { $probe = Start-FailoverProbes $sessions.R4 $EvidenceDirectory 'backup' }
        try {
            Disable-FailoverLink $primary
            if ($MeasureLoss) {
                Wait-FailoverProbeWindow $probe
                $completedProbe = $probe
                $probe = $null
                Stop-FailoverProbes $completedProbe
                $result.backup_probes = Get-FailoverProbeSummary $completedProbe.output_path $result.shutdown_utc
            }
            Wait-FailoverPath backup secondary
            if ($TestDirectBackup) {
                Disable-FailoverLink $secondary
                foreach ($link in @($primary, $secondary)) {
                    $cutBrief = Invoke-FailoverCommand $link.router 'show ip interface brief'
                    $downPattern = '(?m)^' + [regex]::Escape($link.interface) + '[ \t]+' + [regex]::Escape($link.address) + '[ \t]+YES[ \t]+\S+[ \t]+administratively down[ \t]+down\s*\r?$'
                    if ($cutBrief -notmatch $downPattern) { throw "$($link.router) $($link.interface) is not administratively down." }
                }
                Wait-FailoverPath direct direct
                Restore-FailoverLink $secondary
                Wait-FailoverPath secondary_recovery secondary
            }
            if ($MeasureLoss) { $probe = Start-FailoverProbes $sessions.R4 $EvidenceDirectory 'recovery' }
        }
        finally { Restore-FailoverLinks }
        if ($MeasureLoss) {
            Wait-FailoverProbeWindow $probe
            $completedProbe = $probe
            $probe = $null
            Stop-FailoverProbes $completedProbe
            $result.recovery_probes = Get-FailoverProbeSummary $completedProbe.output_path $result.restore_command_utc[0]
        }
        Wait-FailoverPath recovery primary
        $result.passed = $true
    }
    catch {
        $result.error = $_.Exception.Message
        throw
    }
    finally {
        try {
            if ($result.shutdown_attempted -and -not $result.restored) {
                try { Restore-FailoverLinks }
                catch {
                    $result.restoration_error = $_.Exception.Message
                    foreach ($link in @($secondary, $primary)) {
                        if ($link.shutdown_attempted -and -not $link.restored) {
                            Write-Warning "RESTORATION FAILED: on $($link.router), restore $($link.interface) with no shutdown. See the manual recovery steps in README.md."
                        }
                    }
                }
            }
            if ($null -ne $probe) {
                try { Stop-FailoverProbes $probe } catch { Write-Warning "R4 probe cleanup reported: $($_.Exception.Message)" }
            }
            foreach ($session in @($sessions.Values)) {
                try { if ($session.Prompt -match '\(') { $null = Send-IosCommand $session 'end' } } catch { Write-Warning 'Could not exit configuration mode.' }
                try { Close-IosConsole $session } catch { Write-Warning 'Could not close console.' }
            }
        }
        finally { $result.finished_utc = [DateTime]::UtcNow.ToString('o'); Save-FailoverEvidence }
    }
    Write-Output 'VERIFIED: primary baseline, backup through R3, primary recovery; no configuration saved. Timing is route observation latency, not packet-loss convergence.'
    if ($TestDirectBackup) { Write-Output 'VERIFIED: direct R1-R4 backup in both directions and both transit interfaces restored.' }
    if ($CaptureTraceroute) { Write-Output "CAPTURED: $($traces.Count) diagnostic traceroutes; inspect traceroutes.json for hop responses and timeouts." }
}
