$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/CoreOspf.ps1')
. (Join-Path $PSScriptRoot '../scripts/CoreFailover.ps1')
$manifestPath = Join-Path $PSScriptRoot '../gns3/core-topology.json'
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('failover-' + [guid]::NewGuid())
function Assert-Failover($Condition, $Message) { if (-not $Condition) { throw "TEST FAILED: $Message" } }
. (Join-Path $PSScriptRoot '../scripts/IosConsole.ps1')
$probeCommand = 'ping 10.255.0.1 source 10.255.0.4 repeat 1 timeout 1'
$adjacencyLog = '*Nov 23 16:13:17.763: %OSPF-5-ADJCHG: Process 10, Nbr 10.255.0.2 on FastEthernet0/0 from LOADING to FULL, Loading Done'
$recoveryEcho = $adjacencyLog + $probeCommand + "`r`nSuccess rate is 100 percent (1/1)`r`nR4#"
Assert-Failover (Test-IosProbeEcho $recoveryEcho $probeCommand) 'Live recovery echo joined to an OSPF message'
Assert-Failover (-not (Test-IosProbeEcho ($recoveryEcho.Replace('repeat 1', 'repeat 2')) $probeCommand)) 'Wrong probe command following OSPF message'
Assert-Failover (-not (Test-IosProbeEcho ("unexpected" + $probeCommand) $probeCommand)) 'Unrecognized prefix before probe command'
$integrationId = 'ead82e9a-4437-40d9-93fd-db593ba0c650'
function Invoke-CoreInterfaceConfiguration {
    if ($global:FailoverMock.integration) { throw 'Core manifest validation was called for integration' }
}
function Invoke-RestMethod($Uri) {
    if ($global:FailoverMock.integration) {
        if ($Uri -like '*/v2/projects') {
            return @(
                @{ name='Hybrid-Core-Lab'; project_id='cf3df97c-53f6-4ab7-a3d3-980d0fc96de7'; status='opened' }
                @{ name='Hybrid-Core-Integration'; project_id=$integrationId; status='opened' }
            )
        }
        if ($Uri -eq "http://127.0.0.1:3076/v2/projects/$integrationId/links") { return @('integration links') }
        Assert-Failover ($Uri -eq "http://127.0.0.1:3076/v2/projects/$integrationId/nodes") 'Nodes belong to selected project'
    }
    $port = 5000
    foreach ($name in 'R1','R2','R3','R4','HTTP-CLIENT','API-A-1') {
        [pscustomobject]@{name=$name; project_id=$integrationId; console_type='telnet'; console_host='127.0.0.1'; console=(++$port)}
    }
}
function Get-IntegrationInventory($Core, $Nodes, $Links) {
    Assert-Failover ($Links -eq 'integration links') 'Integration cables are validated'
    $byName = @{}
    foreach ($node in $Nodes) { $byName[$node.name] = $node }
    return @{ Nodes=$byName }
}
function Start-FailoverHttp($Node, $Directory) {
    Assert-Failover ($Node.name -eq 'HTTP-CLIENT') 'HTTP probe uses VLAN 10 client'
    return @{ active=$true }
}
function Wait-FailoverHttp($Probe, $Phase) {
    Assert-Failover $Probe.active 'HTTP sampling stays active'
    $global:FailoverMock.httpPhases += $Phase
    if ($global:FailoverMock.scenario -eq 'integration-http-fail' -and $Phase -eq 'backup') { throw 'Mock API unavailable' }
}
function Stop-FailoverHttp($Probe) { $global:FailoverMock.httpStopped = $true }
function Open-IosConsole($Address, $Port) {
    $global:FailoverMock.opens++
    $name = switch ($Port) { 5001 { 'R1' } 5002 { 'R2' } 5004 { 'R4' } default { throw 'Unexpected console' } }
    return [pscustomobject]@{ name = $name; Prompt="$name#" }
}
function Close-IosConsole($Session) { $global:FailoverMock.closes++ }
function Start-FailoverProbes($Session, $EvidenceDirectory, $Phase) {
    $state = $global:FailoverMock
    Assert-Failover ($Session.name -eq 'R4' -and -not $state.probePhase) 'R4 exclusively owns the probe window'
    Assert-Failover ($state.down -eq ($Phase -eq 'recovery')) 'Probes begin before the link transition'
    $state.probePhase = $Phase
    return @{ output_path = $Phase }
}
function Stop-FailoverProbes($Probe) {
    $state = $global:FailoverMock
    Assert-Failover ($state.probePhase -eq $Probe.output_path) 'The active probe window is stopped'
    $state.probePhase = ''
}
function Get-FailoverProbeSummary($Path, $EventUtc) {
    Assert-Failover (-not $global:FailoverMock.probePhase -and $EventUtc) 'Summary follows sampler completion and has a command timestamp'
    return @{ phase = $Path }
}
function Wait-FailoverProbeWindow($Probe) {
    Assert-Failover ($global:FailoverMock.probePhase -eq $Probe.output_path) 'Probe window waits on the active worker'
    if ($global:FailoverMock.scenario -eq 'measure-console-failure') { throw 'R4 probe console failed during backup' }
}
function Send-IosCommand($Session, $Command) {
    $state = $global:FailoverMock
    Assert-Failover (-not ($state.probePhase -and $Session.name -eq 'R4')) 'Foreground commands must wait for the R4 probe worker'
    if ($state.scenario -eq 'measure' -and $Command -in @('shutdown','no shutdown')) {
        $expectedPhase = if ($Command -eq 'shutdown') { 'backup' } else { 'recovery' }
        Assert-Failover ($state.probePhase -eq $expectedPhase) 'Probe worker is active during the transition'
    }
    $state.commands.Add("$($Session.name):$Command")
    # Model IOS modes: accepting every command in every mode hid the live bug.
    $inConfig = $Session.Prompt -match '\('
    if ($Command -eq 'end') {
        if (-not $inConfig) { $state.invalidEnds++; throw "IOS rejected 'end' at EXEC; Translating end; Unknown command or computer name" }
        $Session.Prompt = "$($Session.name)#"
        return 'OK'
    }
    if ($Command -eq 'configure terminal') {
        if ($inConfig) { throw 'configure terminal requires EXEC mode' }
        $Session.Prompt = "$($Session.name)(config)#"
        return 'OK'
    }
    if ($Command -match '^interface (FastEthernet[01]/0)$') {
        if (-not $inConfig) { throw 'interface requires configuration mode' }
        $Session | Add-Member -NotePropertyName selectedInterface -NotePropertyValue $Matches[1] -Force
        $Session.Prompt = "$($Session.name)(config-if)#"
        return 'OK'
    }
    if ($Command -in @('shutdown','no shutdown')) {
        $target = "$($Session.name):$($Session.selectedInterface)"
        $primaryTarget = if ($state.primaryLink -eq 'R2-R4') { 'R2:FastEthernet1/0' } else { 'R1:FastEthernet0/0' }
        $allowed = @($primaryTarget)
        if ($state.scenario -like 'direct-*') { $allowed += 'R1:FastEthernet1/0' }
        Assert-Failover ($target -in $allowed) "Target router and interface: $target"
        if ($Session.Prompt -notmatch '\(config-if\)#$') { throw 'shutdown requires interface configuration mode' }
    }
    elseif ($Command -match '^(show|ping|traceroute) ' -and $inConfig) { throw 'Diagnostics require EXEC mode in this workflow' }
    switch -Regex ($Command) {
        '^traceroute (10\.255\.0\.[14]) numeric probe 1 source (10\.255\.0\.[14]) timeout 1 ttl 1 4$' {
            if ($state.scenario -eq 'trace-error' -and $state.down) { throw 'IOS rejected traceroute' }
            $destination = $Matches[1]
            # Include a missing response to ensure raw diagnostic data survives.
            return "Tracing the route to $destination`r`n  1 *`r`n  2 $destination 12 msec`r`n"
        }
        '^shutdown$' {
            if ($Session.name -eq 'R1' -and $Session.selectedInterface -eq 'FastEthernet1/0') {
                $state.secondaryDown = $true
                if ($state.scenario -eq 'direct-lost-ack') { throw 'Lost secondary shutdown acknowledgement' }
                return 'OK'
            }
            $state.down = $true; $state.cuts++
            if ($state.scenario -eq 'lost-shutdown-ack') { throw 'Lost shutdown acknowledgement' }
            return 'OK'
        }
        '^no shutdown$' {
            if ($Session.name -eq 'R1' -and $Session.selectedInterface -eq 'FastEthernet1/0') {
                if ($state.scenario -eq 'direct-secondary-restore-failure') { throw 'Secondary restoration failed' }
                $state.secondaryDown = $false
                return 'OK'
            }
            if ($state.scenario -eq 'restore-failure') { throw 'Restore transport failed' }
            if ($state.scenario -eq 'retry-restore' -and -not $state.restoreFailed) { $state.restoreFailed = $true; throw 'Lost restore acknowledgement' }
            $state.down = $false; $state.restores++; return 'OK'
        }
        '^show running-config interface (FastEthernet[01]/0)$' {
            $address = if ($Session.name -eq 'R2') { '10.0.24.1' } elseif ($Matches[1] -eq 'FastEthernet0/0') { '10.0.12.1' } else { '10.0.13.1' }
            return "interface $($Matches[1])`r`n ip address $address 255.255.255.252`r`n"
        }
        '^show ip interface brief$' {
            if ($Session.name -eq 'R4') {
                if ($state.scenario -eq 'direct-preflight-failure') { return 'FastEthernet2/0 10.0.14.2 YES manual down down' }
                return 'FastEthernet2/0 10.0.14.2 YES manual up up'
            }
            $primaryStatus = if ($state.scenario -eq 'initially-down' -or $state.down) { 'administratively down down' } else { 'up up' }
            if ($Session.name -eq 'R2') { return "FastEthernet1/0 10.0.24.1 YES manual $primaryStatus" }
            $secondaryStatus = if ($state.secondaryDown) { 'administratively down down' } else { 'up up' }
            return "FastEthernet0/0 10.0.12.1 YES manual $primaryStatus`r`nFastEthernet1/0 10.0.13.1 YES manual $secondaryStatus`r`nFastEthernet2/0 10.0.14.1 YES manual up up"
        }
        '^show ip route ([0-9.]+)$' {
            $destination = $Matches[1]
            $backup = $state.down
            if ($state.scenario -eq 'delayed-backup' -and $state.down -and $state.backupReads -lt 2) { $state.backupReads++; $backup = $false }
            if ($state.scenario -eq 'backup-failure') { $backup = $false }
            if ($state.scenario -eq 'recovery-failure' -and $state.restores -gt 0) { $backup = $true }
            if ($state.scenario -eq 'baseline-failure') { $backup = $true }
            $hop = if ($backup) { if ($Session.name -eq 'R1') { '10.0.13.2' } else { '10.0.34.1' } } else { if ($Session.name -eq 'R1') { '10.0.12.2' } else { '10.0.24.1' } }
            $interface = if ($backup) { 'FastEthernet1/0' } else { 'FastEthernet0/0' }
            if ($state.down -and $state.secondaryDown -and $state.scenario -ne 'direct-wrong-path') {
                $hop = if ($Session.name -eq 'R1') { '10.0.14.2' } else { '10.0.14.1' }
                $interface = 'FastEthernet2/0'
            }
            return "Routing entry for $destination/32`r`n Known via `"ospf 10`", distance 110, metric 21`r`n * $hop, from $destination, 00:00:01 ago, via $interface`r`n"
        }
        '^ping ' {
            if ($state.scenario -eq 'backup-ping-failure' -and $state.down) { return 'Success rate is 0 percent (0/3)' }
            return 'Success rate is 100 percent (3/3)'
        }
        default { throw "Unexpected command: $Command" }
    }
}
function Test-PrimaryLinkScenarios($primaryLink) {
    foreach ($scenario in @('plan','success','measure','measure-console-failure','trace-success','trace-error','delayed-backup','retry-restore','initially-down','baseline-failure','backup-failure','lost-shutdown-ack','backup-ping-failure','recovery-failure','restore-failure','direct-plan','direct-success','direct-preflight-failure','direct-lost-ack','direct-wrong-path','direct-secondary-restore-failure','integration-plan','integration-success','integration-http-fail')) {
        $global:FailoverMock = @{ scenario=$scenario; integration=($scenario -like 'integration-*'); httpPhases=@(); primaryLink=$primaryLink; down=$false; cuts=0; restores=0; opens=0; closes=0; invalidEnds=0; backupReads=0; restoreFailed=$false; commands=[Collections.Generic.List[string]]::new() }
        $directory = Join-Path $testDirectory "$primaryLink-$scenario"
        $isPlan = $scenario -in @('plan','direct-plan','integration-plan')
        $mode = if ($isPlan) { 'plan' } else { 'apply' }
        $failed = $false
        $capture = $scenario -in @('plan','trace-success','trace-error')
        $measure = $scenario -in @('measure','measure-console-failure','lost-shutdown-ack')
        $direct = $scenario -like 'direct-*'
        $projectName = if ($global:FailoverMock.integration) { 'Hybrid-Core-Integration' } else { 'Hybrid-Core-Lab' }
        try { $planOutput = Invoke-CoreFailover -ProjectName $projectName -PrimaryLink $primaryLink -Mode $mode -ManifestPath $manifestPath -EvidenceDirectory $directory -Attempts 2 -PollSeconds 0 -CaptureTraceroute:$capture -MeasureLoss:$measure -TestDirectBackup:$direct }
        catch { $failed = $true }
        $state = $global:FailoverMock
        $expectedSuccess = $scenario -in @('success','measure','trace-success','delayed-backup','retry-restore','direct-success','integration-success')
        Assert-Failover ($failed -eq (-not ($expectedSuccess -or $isPlan))) "$scenario status"
        Assert-Failover (-not $state.probePhase) "$scenario releases the probe console"
        Assert-Failover ($state.closes -eq $state.opens) "$scenario closes all sessions"
        Assert-Failover ($state.invalidEnds -eq 0) "$scenario never sends end at EXEC"
        Assert-Failover (-not ($state.commands | Where-Object { $_ -match 'write memory|copy .*startup' })) "$scenario never saves"
        if ($isPlan -or $scenario -in @('initially-down','baseline-failure','direct-preflight-failure')) { Assert-Failover ($state.cuts -eq 0 -and -not $state.secondaryDown) "$scenario cannot cut link" }
        elseif ($scenario -ne 'restore-failure') { Assert-Failover (-not $state.down -and $state.restores -eq 1) "$scenario restores link even after failure" }
        if ($isPlan) {
            Assert-Failover ($state.opens -eq 0) 'Plan opens no consoles'
            $target = if ($primaryLink -eq 'R2-R4') { 'R2 FastEthernet1/0' } else { 'R1 FastEthernet0/0' }
            Assert-Failover (($planOutput -join ' ') -like "*shut $target*") 'Plan identifies selected endpoint'
        }
        else {
            $evidence = Get-Content (Join-Path $directory 'result.json') -Raw | ConvertFrom-Json
            Assert-Failover ($evidence.passed -eq $expectedSuccess) "$scenario evidence accurately reports status"
            if ($state.integration) {
                Assert-Failover ($evidence.project_id -eq $integrationId -and $evidence.project -eq $projectName -and $state.httpStopped) 'Integration evidence and sampler cleanup'
                if ($expectedSuccess) { Assert-Failover (($state.httpPhases -join ',') -eq 'baseline,backup,recovery') 'HTTP passes before, during and after the cut' }
            }
            if ($scenario -eq 'measure') {
                Assert-Failover ($evidence.backup_probes.phase -eq 'backup' -and $evidence.recovery_probes.phase -eq 'recovery') 'Both probe summaries are archived'
            }
            if ($scenario -eq 'restore-failure') { Assert-Failover ($evidence.restoration_error -and -not $evidence.restored) 'Restoration failure recorded' }
            if ($scenario -in @('direct-success','direct-lost-ack','direct-wrong-path')) {
                Assert-Failover ($evidence.restored -and $evidence.links.primary.restored -and $evidence.links.secondary.restored -and -not $state.secondaryDown) "$scenario restores both links"
            }
            if ($scenario -eq 'direct-success') {
                $polls = Get-Content (Join-Path $directory 'observations.json') -Raw | ConvertFrom-Json
                $phases = @($polls | ForEach-Object { $_.phase } | Select-Object -Unique)
                Assert-Failover (($phases -join ',') -eq 'baseline,backup,direct,secondary_recovery,recovery') 'All five routing checkpoints are verified in sequence'
            }
            if ($scenario -eq 'direct-secondary-restore-failure') {
                Assert-Failover ($evidence.links.primary.restored -and -not $evidence.links.secondary.restored -and -not $evidence.restored -and $evidence.restoration_error) 'Primary restores even when secondary restoration fails'
            }
            if ($scenario -eq 'trace-success') {
                $traceData = Get-Content (Join-Path $directory 'traceroutes.json') -Raw | ConvertFrom-Json
                $traces = @($traceData | ForEach-Object { $_ })
                Assert-Failover ($traces.Count -eq 6) 'Six traceroutes captured'
                foreach ($phase in @('baseline','backup','recovery')) {
                    $rows = @($traces | Where-Object { $_.phase -eq $phase })
                    Assert-Failover ($rows.Count -eq 2 -and @($rows.router | Sort-Object -Unique).Count -eq 2) "$phase bidirectional trace capture"
                }
                Assert-Failover ($traces[0].output.Contains('1 *')) 'Timed-out probe remains diagnostic evidence'
            }
            if (-not $capture) { Assert-Failover (-not (Test-Path (Join-Path $directory 'traceroutes.json'))) 'No unsolicited trace capture' }
        }
        Write-Output "PASS: $primaryLink $scenario"
    }
}
try {
    Test-PrimaryLinkScenarios 'R1-R2'
    Test-PrimaryLinkScenarios 'R2-R4'
}
finally {
    # This is a uniquely created test directory under the system temporary directory.
    if (Test-Path -LiteralPath $testDirectory) { Remove-Item -LiteralPath $testDirectory -Recurse -Force }
    Remove-Variable FailoverMock -Scope Global -ErrorAction SilentlyContinue
}
