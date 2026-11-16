$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/IosConsole.ps1')
. (Join-Path $PSScriptRoot '../scripts/CoreInterfaces.ps1')
$manifestPath = Join-Path $PSScriptRoot '../gns3/core-topology.json'
$fixture = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$savedSummary = $env:GITHUB_STEP_SUMMARY
$env:GITHUB_STEP_SUMMARY = ''

function Assert-InterfaceTest([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "TEST FAILED: $Message" }
}

# Byte-level tests include negotiation split across separate network reads.
$memory = [System.IO.MemoryStream]::new()
$telnet = [pscustomobject]@{ Stream = $memory; TelnetState = 'data'; TelnetCommand = 0 }
$decoded = ConvertFrom-IosTelnet $telnet ([byte[]]@(82, 255))
$decoded += ConvertFrom-IosTelnet $telnet ([byte[]]@(251))
$decoded += ConvertFrom-IosTelnet $telnet ([byte[]]@(1, 49, 13, 0, 10))
Assert-InterfaceTest ($decoded -eq "R1`r`n") 'Split Telnet WILL ECHO must not leak negotiation bytes'
Assert-InterfaceTest (([System.BitConverter]::ToString($memory.ToArray())) -eq 'FF-FD-01') 'WILL ECHO negotiation response'
$decoded = ConvertFrom-IosTelnet $telnet ([byte[]]@(255, 253, 24, 255, 250, 24, 1, 255))
$decoded += ConvertFrom-IosTelnet $telnet ([byte[]]@(240, 35))
Assert-InterfaceTest ($decoded -eq '#') 'Split subnegotiation must be ignored'
Assert-InterfaceTest (([System.BitConverter]::ToString($memory.ToArray())) -eq 'FF-FD-01-FF-FC-18') 'Unsupported option must be refused'
$memory.Dispose()
Write-Output 'PASS: fragmented Telnet negotiation, CR-NUL and subnegotiation'

$history = "Would you like to enter the initial configuration dialog? [yes/no]: no`r`nPress RETURN to get started!`r`nUsername:`r`nPassword:`r`nRouter>"
$terminal = Get-IosTerminalState $history
Assert-InterfaceTest ($terminal.Kind -eq 'prompt' -and $terminal.Prompt -eq 'Router>') 'Historical setup/login text must not override the current prompt'
Write-Output 'PASS: replayed setup and login history ends at a usable EXEC prompt'
foreach ($activePrompt in @('Password:', 'Username:', 'Would you like to enter the initial configuration dialog? [yes/no]:', 'Would you like to terminate autoinstall? [yes]:', 'Press RETURN to get started!')) {
    $terminal = Get-IosTerminalState ("Router#`r`n" + $activePrompt)
    Assert-InterfaceTest ($terminal.Kind -eq 'challenge') 'A live challenge must override an earlier historical prompt'
}
Write-Output 'PASS: live authentication, setup and RETURN prompts are identified at the terminal tail'
$terminal = Get-IosTerminalState "R1(config-if)#*Nov 15 10:00:00: %LINK-3-UPDOWN: Interface FastEthernet0/0, changed state to up`r`n"
Assert-InterfaceTest ($terminal.Kind -eq 'prompt' -and $terminal.Prompt -eq 'R1(config-if)#') 'A syslog line must not hide the current configuration prompt'
Write-Output 'PASS: known syslog messages after the prompt do not hide it'
$interleavedEcho = "no pass`r`n*Nov 16 20:46:25.275: %LINEPROTO-5-UPDOWN: Line protocol on Interface Loopback0, changed state to upive-interface FastEthernet1/0`r`nR2(config-router)#"
Assert-InterfaceTest (Test-IosCommandEcho $interleavedEcho 'no passive-interface FastEthernet1/0') 'Recognized syslog may interrupt the echo without a newline before its remainder'
Assert-InterfaceTest (-not (Test-IosCommandEcho $interleavedEcho 'no passive-interface FastEthernet9/9')) 'Different or incomplete command must not match'
Assert-InterfaceTest (-not (Test-IosCommandEcho "no pass`r`nive-interface FastEthernet1/0`r`nR2#" 'no passive-interface FastEthernet1/0')) 'Unexplained echo corruption must not be accepted'
Assert-InterfaceTest (-not (Test-IosCommandEcho "FastEthernet1/0`r`n%SYS-5-CONFIG_I: Configured from console`r`nno passive-interface`r`nR2#" 'no passive-interface FastEthernet1/0')) 'Echo characters must remain in command order'
Write-Output 'PASS: syslog-interrupted echo is accepted without accepting missing or reordered command characters'
$ospfEcho = "no pass`r`n*Nov 16 20:46:25.275: %OSPF-5-ADJCHG: Process 10, Nbr 10.255.0.2 on FastEthernet0/0 from LOADING to FULLive-interface FastEthernet1/0`r`nR2(config-router)#"
Assert-InterfaceTest (Test-IosCommandEcho $ospfEcho 'no passive-interface FastEthernet1/0') 'Structured OSPF syslog must be handled like interface syslog'
$terminal = Get-IosTerminalState "R1#*Nov 16 20:46:25.275: %OSPF-5-ADJCHG: Process 10, Nbr 10.255.0.2 from LOADING to FULL`r`n"
Assert-InterfaceTest ($terminal.Kind -eq 'prompt' -and $terminal.Prompt -eq 'R1#') 'OSPF syslog must not hide an EXEC prompt'
Write-Output 'PASS: OSPF adjacency syslog is recognized without changing the current prompt'

function Reset-InterfaceLab {
    $global:CoreInterfaceMock = @{
        nodes = @(); links = @(); routers = @{}
        opens = 0; closes = 0; changes = 0; saves = 0; measuredPings = 0
        failOpen = ''; failPing = $false; failCommand = $false; linkDown = $false
    }
    $state = $global:CoreInterfaceMock
    $port = 5001
    foreach ($router in $fixture.routers) {
        $state.nodes += [pscustomobject]@{
            node_id = $router.node_id; name = $router.name; project_id = $fixture.project.project_id
            compute_id = 'vm'; node_type = 'dynamips'; status = 'started'
            console_type = 'telnet'; console_host = '192.168.238.128'; console = $port
        }
        $state.routers[$router.name] = @{ hostname = 'Router'; interfaces = @{}; mode = 'exec' }
        $port++
    }
    foreach ($link in $fixture.links) {
        $endpoints = @()
        foreach ($side in @('a', 'b')) {
            $name = $link.$side
            $router = @($fixture.routers | Where-Object { $_.name -eq $name })[0]
            $adapter = $link."${side}_adapter"
            $state.routers[$name].interfaces["FastEthernet$adapter/0"] = @{ address = ''; mask = ''; shutdown = $true }
            $endpoints += [pscustomobject]@{ node_id = $router.node_id; adapter_number = $adapter; port_number = 0 }
        }
        $state.links += [pscustomobject]@{ nodes = $endpoints; link_type = 'ethernet'; suspend = $false; filters = [pscustomobject]@{} }
    }
}

function Invoke-RestMethod {
    param($Uri, $Method, $TimeoutSec, $ErrorAction)
    Assert-InterfaceTest ($Method -eq 'Get') 'Interface workflow must never mutate the GNS3 API'
    $state = $global:CoreInterfaceMock
    switch (([uri]$Uri).AbsolutePath) {
        '/v2/projects' { return ,@([pscustomobject]@{ project_id = $fixture.project.project_id; status = 'opened' }) }
        "/v2/projects/$($fixture.project.project_id)/nodes" { return ,$state.nodes }
        "/v2/projects/$($fixture.project.project_id)/links" { return ,$state.links }
        default { throw 'Unexpected API request in interface test' }
    }
}
function Open-IosConsole([string] $Address, [int] $Port) {
    $state = $global:CoreInterfaceMock
    $node = @($state.nodes | Where-Object { $_.console -eq $Port })[0]
    if ($node.name -eq $state.failOpen) { throw 'Simulated password or initial setup prompt' }
    $state.opens++
    return [pscustomobject]@{ Name = $node.name; CurrentInterface = '' }
}
function Close-IosConsole($Session) { $global:CoreInterfaceMock.closes++ }
function Start-Sleep { param($Seconds, $Milliseconds) }
function Send-IosCommand($Session, [string] $Command) {
    $state = $global:CoreInterfaceMock
    $router = $state.routers[$Session.Name]
    $body = ''
    switch -Regex ($Command) {
        '^show running-config \| include \^hostname$' { $body = "hostname $($router.hostname)"; break }
        '^show running-config interface (FastEthernet\d/0)$' {
            $ifName = $Matches[1]; $config = $router.interfaces[$ifName]
            $body = "interface $ifName`r`n"
            if ($config.address) { $body += " ip address $($config.address) $($config.mask)`r`n" }
            else { $body += " no ip address`r`n" }
            if ($config.shutdown) { $body += " shutdown`r`n" }
            break
        }
        '^configure terminal$' { $router.mode = 'config'; break }
        '^hostname (R[1-4])$' { $router.hostname = $Matches[1]; $state.changes++; break }
        '^interface (FastEthernet\d/0)$' { $Session.CurrentInterface = $Matches[1]; break }
        '^ip address ([0-9.]+) ([0-9.]+)$' {
            if ($state.failCommand) { throw 'IOS rejected ip address: % Invalid input detected' }
            $config = $router.interfaces[$Session.CurrentInterface]
            $config.address = $Matches[1]; $config.mask = $Matches[2]; $state.changes++; break
        }
        '^no shutdown$' { $router.interfaces[$Session.CurrentInterface].shutdown = $false; $state.changes++; break }
        '^exit$' { $Session.CurrentInterface = ''; break }
        '^end$' { $router.mode = 'exec'; break }
        '^show ip interface brief$' {
            $body = 'Interface IP-Address OK? Method Status Protocol' + "`r`n"
            foreach ($entry in $router.interfaces.GetEnumerator()) {
                $status = if ($entry.Value.shutdown) { 'administratively down' } elseif ($state.linkDown) { 'down' } else { 'up' }
                $protocol = if ($status -eq 'up') { 'up' } else { 'down' }
                $body += "$($entry.Key) $($entry.Value.address) YES manual $status $protocol`r`n"
            }
            break
        }
        '^ping [0-9.]+ repeat (1|3) timeout 1$' {
            if ($Matches[1] -eq '3') {
                $state.measuredPings++
                $body = if ($state.failPing) { 'Success rate is 0 percent (0/3)' } else { 'Success rate is 100 percent (3/3)' }
            }
            else { $body = 'Success rate is 0 percent (0/1)' }
            break
        }
        '^write memory$' { $state.saves++; $body = '[OK]'; break }
        default { throw "Unexpected IOS command: $Command" }
    }
    return "$Command`r`n$body`r`n$($router.hostname)#"
}

function Run-InterfaceTest([string] $Mode = 'apply') {
    Invoke-CoreInterfaceConfiguration -Mode $Mode -ManifestPath $manifestPath | Out-Null
}

try {
    Reset-InterfaceLab
    Run-InterfaceTest plan
    Assert-InterfaceTest ($global:CoreInterfaceMock.opens -eq 0 -and $global:CoreInterfaceMock.changes -eq 0) 'Plan must not open consoles'
    Write-Output 'PASS: plan only reads the API'

    Run-InterfaceTest
    Assert-InterfaceTest ($global:CoreInterfaceMock.changes -eq 24) 'Four hostnames, ten addresses and ten interface activations'
    Assert-InterfaceTest ($global:CoreInterfaceMock.measuredPings -eq 10 -and $global:CoreInterfaceMock.saves -eq 4) 'Ten neighbor tests and four saves'
    Assert-InterfaceTest ($global:CoreInterfaceMock.closes -eq 4) 'All consoles closed after success'
    Write-Output 'PASS: configures all links, tests both directions and saves'

    $global:CoreInterfaceMock.changes = 0
    Run-InterfaceTest
    Assert-InterfaceTest ($global:CoreInterfaceMock.changes -eq 0) 'Repeated apply must not reapply matching interface commands'
    Write-Output 'PASS: repeated apply does not change matching interfaces'

    Reset-InterfaceLab
    $global:CoreInterfaceMock.failOpen = 'R4'
    $failed = $false
    try { Run-InterfaceTest } catch { $failed = $true }
    Assert-InterfaceTest ($failed -and $global:CoreInterfaceMock.changes -eq 0 -and $global:CoreInterfaceMock.closes -eq 3) 'Preflight all consoles before changing any router'
    Write-Output 'PASS: inaccessible console prevents configuration and closes earlier sessions'

    Reset-InterfaceLab
    $global:CoreInterfaceMock.routers.R4.interfaces['FastEthernet0/0'].address = '192.0.2.1'
    $global:CoreInterfaceMock.routers.R4.interfaces['FastEthernet0/0'].mask = '255.255.255.0'
    $failed = $false
    try { Run-InterfaceTest } catch { $failed = $true }
    Assert-InterfaceTest ($failed -and $global:CoreInterfaceMock.changes -eq 0) 'Conflicting IP must fail before configuration'
    Write-Output 'PASS: unexpected IP address is not overwritten'

    foreach ($failure in @('failPing', 'linkDown', 'failCommand')) {
        Reset-InterfaceLab
        $global:CoreInterfaceMock[$failure] = $true
        $failed = $false
        try { Run-InterfaceTest } catch { $failed = $true }
        Assert-InterfaceTest ($failed -and $global:CoreInterfaceMock.saves -eq 0 -and $global:CoreInterfaceMock.closes -eq 4) 'Failure must prevent startup-config saves and close all sessions'
        Write-Output "PASS: $failure stops the run before saving"
    }

    foreach ($failure in @('stopped', 'miswired', 'suspended')) {
        Reset-InterfaceLab
        switch ($failure) {
            'stopped' { $global:CoreInterfaceMock.nodes[0].status = 'stopped' }
            'miswired' { $global:CoreInterfaceMock.links[0].nodes[0].adapter_number = 5 }
            'suspended' { $global:CoreInterfaceMock.links[0].suspend = $true }
        }
        $failed = $false
        try { Run-InterfaceTest } catch { $failed = $true }
        Assert-InterfaceTest ($failed -and $global:CoreInterfaceMock.opens -eq 0) 'Invalid topology must fail before console access'
        Write-Output "PASS: $failure topology is rejected before console access"
    }
    Write-Output 'All interface tests passed.'
}
finally {
    $env:GITHUB_STEP_SUMMARY = $savedSummary
    Remove-Variable -Name CoreInterfaceMock -Scope Global -ErrorAction SilentlyContinue
}
