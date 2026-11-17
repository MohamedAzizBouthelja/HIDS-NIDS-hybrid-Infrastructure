$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/CoreOspf.ps1')
. (Join-Path $PSScriptRoot '../scripts/CoreFailover.ps1')
$manifestPath = Join-Path $PSScriptRoot '../gns3/core-topology.json'
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('failover-' + [guid]::NewGuid())
function Assert-Failover($Condition, $Message) { if (-not $Condition) { throw "TEST FAILED: $Message" } }
function Invoke-CoreInterfaceConfiguration { }
function Invoke-RestMethod { return @([pscustomobject]@{ name='R1'; console_host='127.0.0.1'; console=5001 }, [pscustomobject]@{ name='R4'; console_host='127.0.0.1'; console=5004 }) }
function Open-IosConsole($Address, $Port) {
    $global:FailoverMock.opens++
    $name = if ($Port -eq 5001) { 'R1' } else { 'R4' }
    return [pscustomobject]@{ name = $name; Prompt="$name#" }
}
function Close-IosConsole($Session) { $global:FailoverMock.closes++ }
function Send-IosCommand($Session, $Command) {
    $state = $global:FailoverMock
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
    if ($Command -eq 'interface FastEthernet0/0') {
        if (-not $inConfig) { throw 'interface requires configuration mode' }
        $Session.Prompt = "$($Session.name)(config-if)#"
        return 'OK'
    }
    if ($Command -in @('shutdown','no shutdown')) {
        if ($Session.Prompt -notmatch '\(config-if\)#$') { throw 'shutdown requires interface configuration mode' }
    }
    elseif ($Command -match '^(show|ping) ' -and $inConfig) { throw 'show/ping requires EXEC mode in this workflow' }
    switch -Regex ($Command) {
        '^shutdown$' {
            $state.down = $true; $state.cuts++
            if ($state.scenario -eq 'lost-shutdown-ack') { throw 'Lost shutdown acknowledgement' }
            return 'OK'
        }
        '^no shutdown$' {
            if ($state.scenario -eq 'restore-failure') { throw 'Restore transport failed' }
            if ($state.scenario -eq 'retry-restore' -and -not $state.restoreFailed) { $state.restoreFailed = $true; throw 'Lost restore acknowledgement' }
            $state.down = $false; $state.restores++; return 'OK'
        }
        '^show running-config interface' { return "interface FastEthernet0/0`r`n ip address 10.0.12.1 255.255.255.252`r`n" }
        '^show ip interface brief$' {
            if ($state.scenario -eq 'initially-down' -or $state.down) { return 'FastEthernet0/0 10.0.12.1 YES manual administratively down down' }
            return 'FastEthernet0/0 10.0.12.1 YES manual up up'
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
            return "Routing entry for $destination/32`r`n Known via `"ospf 10`", distance 110, metric 21`r`n * $hop, from $destination, 00:00:01 ago, via $interface`r`n"
        }
        '^ping ' {
            if ($state.scenario -eq 'backup-ping-failure' -and $state.down) { return 'Success rate is 0 percent (0/3)' }
            return 'Success rate is 100 percent (3/3)'
        }
        default { throw "Unexpected command: $Command" }
    }
}
try {
    foreach ($scenario in @('plan','success','delayed-backup','retry-restore','initially-down','baseline-failure','backup-failure','lost-shutdown-ack','backup-ping-failure','recovery-failure','restore-failure')) {
        $global:FailoverMock = @{ scenario=$scenario; down=$false; cuts=0; restores=0; opens=0; closes=0; invalidEnds=0; backupReads=0; restoreFailed=$false; commands=[Collections.Generic.List[string]]::new() }
        $directory = Join-Path $testDirectory $scenario
        $mode = if ($scenario -eq 'plan') { 'plan' } else { 'apply' }
        $failed = $false
        try { Invoke-CoreFailover -Mode $mode -ManifestPath $manifestPath -EvidenceDirectory $directory -Attempts 2 -PollSeconds 0 | Out-Null }
        catch { $failed = $true }
        $state = $global:FailoverMock
        Assert-Failover ($failed -eq ($scenario -notin @('plan','success','delayed-backup','retry-restore'))) "$scenario status"
        Assert-Failover ($state.closes -eq $state.opens) "$scenario closes all sessions"
        Assert-Failover ($state.invalidEnds -eq 0) "$scenario never sends end at EXEC"
        Assert-Failover (-not ($state.commands | Where-Object { $_ -match 'write memory|copy .*startup' })) "$scenario never saves"
        if ($scenario -in @('plan','initially-down','baseline-failure')) { Assert-Failover ($state.cuts -eq 0) "$scenario cannot cut link" }
        elseif ($scenario -ne 'restore-failure') { Assert-Failover (-not $state.down -and $state.restores -eq 1) "$scenario restores link even after failure" }
        if ($scenario -eq 'plan') { Assert-Failover ($state.opens -eq 0) 'Plan opens no consoles' }
        else {
            $evidence = Get-Content (Join-Path $directory 'result.json') -Raw | ConvertFrom-Json
            Assert-Failover ($evidence.passed -eq ($scenario -in @('success','delayed-backup','retry-restore'))) "$scenario evidence accurately reports status"
            if ($scenario -eq 'restore-failure') { Assert-Failover ($evidence.restoration_error -and -not $evidence.restored) 'Restoration failure recorded' }
        }
        Write-Output "PASS: $scenario"
    }
}
finally {
    # This is a uniquely created test directory under the system temporary directory.
    if (Test-Path -LiteralPath $testDirectory) { Remove-Item -LiteralPath $testDirectory -Recurse -Force }
    Remove-Variable FailoverMock -Scope Global -ErrorAction SilentlyContinue
}
