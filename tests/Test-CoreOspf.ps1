$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/IosConsole.ps1')
. (Join-Path $PSScriptRoot '../scripts/CoreInterfaces.ps1')
. (Join-Path $PSScriptRoot '../scripts/CoreOspf.ps1')
$manifestPath = Join-Path $PSScriptRoot '../gns3/core-topology.json'
$routingPath = Join-Path $PSScriptRoot '../gns3/ospf.json'
$fixture = Get-Content $manifestPath -Raw | ConvertFrom-Json
$routingFixture = Get-Content $routingPath -Raw | ConvertFrom-Json
$savedSummary = $env:GITHUB_STEP_SUMMARY
$env:GITHUB_STEP_SUMMARY = ''

function Assert-OspfTest([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "TEST FAILED: $Message" }
}
$parsed = @(Get-CoreOspfNeighbors "Neighbor ID Pri State Dead Time Address Interface`r`n10.255.0.2 0 FULL/- 00:00:38 10.0.12.2 FastEthernet0/0`r`n10.255.0.3 1 FULL/DR 00:00:37 10.0.13.2 Fa1/0")
Assert-OspfTest ($parsed.Count -eq 2 -and $parsed[1].interface -eq 'FastEthernet1/0') 'Neighbor parsing must handle full and abbreviated interface names'
$padded = @(Get-CoreOspfNeighbors "Neighbor ID     Pri   State           Dead Time   Address         Interface`r`n10.255.0.1       0   FULL/  -        00:00:37    10.0.13.1      FastEthernet0/0`r`n10.255.0.4       0   FULL/  -        00:00:38    10.0.34.2      FastEthernet1/0")
Assert-OspfTest ($padded.Count -eq 2 -and $padded[0].state -eq 'FULL/-') 'IOS padded FULL/  - state must parse and normalize to FULL/-'
$realTables = Get-Content (Join-Path $PSScriptRoot 'fixtures/ospf-neighbors-ios.json') -Raw | ConvertFrom-Json
$expectedCounts = @{ R1 = 3; R2 = 2; R3 = 2; R4 = 3 }
foreach ($name in @('R1','R2','R3','R4')) {
    $rows = @(Get-CoreOspfNeighbors $realTables.$name)
    Assert-OspfTest ($rows.Count -eq $expectedCounts[$name] -and @($rows | Where-Object { $_.state -ne 'FULL/-' }).Count -eq 0) 'Captured IOS tables must retain all ten FULL neighbor rows'
}
Write-Output 'PASS: captured live IOS tables parse as R1=3, R2=2, R3=2 and R4=3 FULL neighbors'
$primary = $routingFixture.primary_routes[0]
$routeText = "Routing entry for 10.255.0.4/32`r`n Known via `"ospf 10`", distance 110, metric 21, type intra area`r`n * 10.0.12.2, from 10.255.0.4, 00:00:03 ago, via FastEthernet0/0`r`n Route metric is 21"
Assert-OspfTest (Test-CoreOspfRoute $routeText 10 $primary '10.255.0.4') 'Correct primary route must pass'
Assert-OspfTest (-not (Test-CoreOspfRoute ($routeText.Replace('10.0.12.2', '10.0.14.2')) 10 $primary '10.255.0.4')) 'Wrong next hop must fail'
Assert-OspfTest (-not (Test-CoreOspfRoute ($routeText.Replace('ospf 10', 'static')) 10 $null '10.255.0.4')) 'Static route must not count as OSPF'
Assert-OspfTest (-not (Test-CoreOspfRoute ($routeText.Replace('10.255.0.4/32', '10.255.0.0/24')) 10 $null '10.255.0.4')) 'A less-specific OSPF route must not count as a remote loopback /32'
Assert-OspfTest (-not (Test-CoreOspfRoute ($routeText + "`r`n 10.0.13.2, from 10.255.0.4, 00:00:03 ago, via FastEthernet1/0") 10 $primary '10.255.0.4')) 'ECMP must not count as a unique primary path'
Write-Output 'PASS: neighbor and route parsers reject wrong next hops, static routes and ECMP'

function Reset-OspfLab {
    $global:CoreOspfMock = @{
        nodes = @(); links = @(); routers = @{}; changes = 0; opens = 0; closes = 0; saves = 0; saveAttempts = 0; pings = 0
        fail = ''; delayNeighbors = 0; neighborRounds = 0; routeReads = 0; configEntries = @{}
    }
    $state = $global:CoreOspfMock
    $port = 5001
    foreach ($router in $fixture.routers) {
        $state.nodes += [pscustomobject]@{
            name = $router.name; node_id = $router.node_id; project_id = $fixture.project.project_id
            compute_id = 'vm'; node_type = 'dynamips'; status = 'started'; console_type = 'telnet'
            console_host = '192.168.238.128'; console = $port
        }
        $state.routers[$router.name] = @{
            process = $false; routerId = ''; passive = $false; active = @{}; loopback = $null; interfaces = @{}
        }
        $port++
    }
    foreach ($link in $fixture.links) {
        $endpoints = @()
        foreach ($side in @('a','b')) {
            $name = $link.$side
            $router = @($fixture.routers | Where-Object { $_.name -eq $name })[0]
            $peer = if ($side -eq 'a') { 'b' } else { 'a' }
            $adapter = $link."${side}_adapter"
            $state.routers[$name].interfaces["FastEthernet$adapter/0"] = @{
                address = $link."${side}_ip"; peer = $link."${peer}_ip"; peerName = $link.$peer
                cost = $null; desiredCost = $routingFixture.link_costs.($link.subnet); network = ''; ospf = $false
            }
            $endpoints += [pscustomobject]@{ node_id = $router.node_id; adapter_number = $adapter; port_number = 0 }
        }
        $state.links += [pscustomobject]@{ nodes = $endpoints; link_type = 'ethernet'; suspend = $false; filters = [pscustomobject]@{} }
    }
}
function Invoke-RestMethod {
    param($Uri, $Method, $TimeoutSec, $ErrorAction)
    Assert-OspfTest ($Method -eq 'Get') 'Routing must not mutate GNS3 topology via the API'
    $state = $global:CoreOspfMock
    switch (([uri]$Uri).AbsolutePath) {
        '/v2/projects' { return ,@([pscustomobject]@{ project_id = $fixture.project.project_id; status = 'opened' }) }
        "/v2/projects/$($fixture.project.project_id)/nodes" { return ,$state.nodes }
        "/v2/projects/$($fixture.project.project_id)/links" { return ,$state.links }
        default { throw 'Unexpected OSPF API request' }
    }
}
function Open-IosConsole([string] $Address, [int] $Port) {
    $node = @($global:CoreOspfMock.nodes | Where-Object { $_.console -eq $Port })[0]
    if ($global:CoreOspfMock.fail -eq 'console' -and $node.name -eq 'R3') { throw 'Simulated inaccessible console' }
    $global:CoreOspfMock.opens++
    return [pscustomobject]@{ Name = $node.name; Prompt = "$($node.name)#"; Selected = ''; Mode = 'exec' }
}
function Close-IosConsole($Session) { $global:CoreOspfMock.closes++ }
function Start-Sleep { param($Seconds, $Milliseconds) }
function Test-AllOspfConfigured {
    foreach ($entry in $global:CoreOspfMock.routers.GetEnumerator()) {
        $router = $entry.Value
        if (-not $router.process -or $router.routerId -ne $routingFixture.router_ids.($entry.Key) -or -not $router.passive -or
            $null -eq $router.loopback -or $router.loopback.address -ne $router.routerId -or -not $router.loopback.ospf) { return $false }
        foreach ($interface in $router.interfaces.GetEnumerator()) {
            if (-not $interface.Value.ospf -or $interface.Value.cost -ne $interface.Value.desiredCost -or $interface.Value.network -ne 'point-to-point' -or
                -not $router.active.ContainsKey($interface.Key)) { return $false }
        }
    }
    return $true
}
function Send-IosCommand($Session, [string] $Command) {
    $state = $global:CoreOspfMock
    $name = $Session.Name
    $router = $state.routers[$name]
    $body = ''
    switch -Regex ($Command) {
        '^show ip interface brief$' {
            foreach ($entry in $router.interfaces.GetEnumerator()) {
                $status = if ($state.fail -eq 'interface-down') { 'down down' } else { 'up up' }
                $body += "$($entry.Key) $($entry.Value.address) YES manual $status`r`n"
            }
            if ($null -ne $router.loopback) { $body += "Loopback0 $($router.loopback.address) YES manual up up`r`n" }
            break
        }
        '^show running-config \| section \^router$' {
            if ($state.fail -eq 'eigrp' -and $name -eq 'R4') { $body = "router eigrp 100`r`n network 10.0.0.0`r`n"; break }
            if ($router.process) {
                $body = "router ospf 10`r`n router-id $($router.routerId)`r`n log-adjacency-changes`r`n"
                if ($router.passive) { $body += " passive-interface default`r`n" }
                foreach ($interfaceName in $router.active.Keys) { $body += " no passive-interface $interfaceName`r`n" }
            }
            break
        }
        '^show running-config interface (\S+)$' {
            $interfaceName = $Matches[1]
            $body = "interface $interfaceName`r`n"
            if ($interfaceName -eq 'Loopback0') {
                $config = $router.loopback
                $body += " ip address $($config.address) 255.255.255.255`r`n"
            }
            else {
                $config = $router.interfaces[$interfaceName]
                $body += " ip address $($config.address) 255.255.255.252`r`n"
                if ($config.cost) { $body += " ip ospf cost $($config.cost)`r`n" }
                if ($config.network) { $body += " ip ospf network $($config.network)`r`n" }
            }
            if ($config.ospf) { $body += " ip ospf 10 area 0`r`n" }
            break
        }
        '^configure terminal$' { $Session.Mode = 'config'; $Session.Prompt = "$name(config)#"; $state.configEntries[$name] = $true; break }
        '^interface (\S+)$' {
            $Session.Selected = $Matches[1]
            if ($Session.Selected -eq 'Loopback0' -and $null -eq $router.loopback) { $router.loopback = @{ address = ''; ospf = $false }; $state.changes++ }
            break
        }
        '^ip address ([0-9.]+) 255\.255\.255\.255$' { $router.loopback.address = $Matches[1]; $state.changes++; break }
        '^ip ospf 10 area 0$' {
            Assert-OspfTest ($router.routerId -eq $routingFixture.router_ids.$name) 'Explicit router ID must be configured before OSPF is enabled on an interface'
            if ($Session.Selected -eq 'Loopback0') { $router.loopback.ospf = $true }
            else { $router.interfaces[$Session.Selected].ospf = $true }
            $router.process = $true; $state.changes++; break
        }
        '^ip ospf network point-to-point$' { $router.interfaces[$Session.Selected].network = 'point-to-point'; $state.changes++; break }
        '^ip ospf cost (\d+)$' { $router.interfaces[$Session.Selected].cost = [int]$Matches[1]; $state.changes++; break }
        '^no shutdown$' { $state.changes++; break }
        '^router ospf 10$' { $router.process = $true; $Session.Selected = ''; break }
        '^router-id ([0-9.]+)$' { $router.routerId = $Matches[1]; $state.changes++; break }
        '^passive-interface default$' { $router.passive = $true; $state.changes++; break }
        '^no passive-interface (\S+)$' {
            $interfaceName = $Matches[1]
            $router.active[$interfaceName] = $true; $state.changes++
            if ($state.fail -eq 'interrupted-command' -and $name -eq 'R2' -and $interfaceName -eq 'FastEthernet1/0') { throw 'Simulated command applied before console acknowledgement was interrupted' }
            break
        }
        '^exit$' { $Session.Selected = ''; break }
        '^end$' { $Session.Mode = 'exec'; $Session.Prompt = "$name#"; break }
        '^show ip ospf neighbor$' {
            if ($name -eq 'R1') { $state.neighborRounds++ }
            $full = (Test-AllOspfConfigured) -and $state.fail -ne 'neighbors' -and $state.neighborRounds -gt $state.delayNeighbors
            foreach ($entry in $router.interfaces.GetEnumerator()) {
                $neighborState = if ($full) { 'FULL/  -' } else { 'INIT/  -' }
                $body += "$($routingFixture.router_ids.($entry.Value.peerName)) 0 $neighborState 00:00:37 $($entry.Value.peer) $($entry.Key)`r`n"
            }
            break
        }
        '^show ip route ([0-9.]+)$' {
            $destination = $Matches[1]; $state.routeReads++
            $via = if ($state.fail -eq 'static-route') { 'static' } else { 'ospf 10' }
            if ($state.fail -eq 'delayed-route' -and $state.routeReads -le 12) { $body = '% Network not in table'; break }
            $primary = @($routingFixture.primary_routes | Where-Object { $_.router -eq $name -and $_.destination -eq $destination })
            $hop = if ($primary.Count -eq 1) { $primary[0].next_hop } else { @($router.interfaces.Values)[0].peer }
            if ($state.fail -eq 'wrong-primary' -and $primary.Count -eq 1) { $hop = '10.0.14.2' }
            $body = "Routing entry for $destination/32`r`n Known via `"$via`", distance 110, metric 21, type intra area`r`n * $hop, from $destination, 00:00:03 ago, via FastEthernet0/0`r`n Route metric is 21`r`n"
            break
        }
        '^ping ([0-9.]+) source ([0-9.]+) repeat (1|3) timeout 1$' {
            Assert-OspfTest ($Matches[2] -eq $routingFixture.router_ids.$name) 'Routed pings must use the loopback source'
            if ($Matches[3] -eq '3') { $state.pings++ }
            $body = if ($state.fail -eq 'ping') { 'Success rate is 0 percent (0/3)' } else { 'Success rate is 100 percent (3/3)' }
            break
        }
        '^write memory$' {
            $state.saveAttempts++
            if ($state.fail -eq 'save-ack' -and $name -eq 'R2') { $body = 'Building configuration...' }
            else { $state.saves++; $body = '[OK]' }
            break
        }
        default { throw "Unexpected OSPF command: $Command" }
    }
    return "$Command`r`n$body`r`n$($Session.Prompt)"
}
function Run-OspfTest([string] $Mode = 'apply') {
    Invoke-CoreOspfConfiguration -Mode $Mode -ManifestPath $manifestPath -RoutingPath $routingPath | Out-Null
}
try {
    Reset-OspfLab
    Run-OspfTest plan
    Assert-OspfTest ($global:CoreOspfMock.opens -eq 0 -and $global:CoreOspfMock.changes -eq 0) 'Plan must not connect to consoles'
    Write-Output 'PASS: OSPF plan is read-only'
    Run-OspfTest
    Assert-OspfTest ((Test-AllOspfConfigured) -and $global:CoreOspfMock.pings -eq 12 -and $global:CoreOspfMock.saves -eq 4 -and $global:CoreOspfMock.closes -eq 4) 'Full OSPF deployment and verification'
    Write-Output 'PASS: loopbacks, router IDs, passive defaults, costs, neighbors, routes, pings and saving'
    $global:CoreOspfMock.changes = 0
    Run-OspfTest
    Assert-OspfTest ($global:CoreOspfMock.changes -eq 0) 'Repeat apply must not reapply OSPF commands'
    Write-Output 'PASS: repeated OSPF apply does not change the existing configuration'
    foreach ($failure in @('eigrp', 'interface-down', 'console')) {
        Reset-OspfLab
        $global:CoreOspfMock.fail = $failure
        $failed = $false
        try { Run-OspfTest } catch { $failed = $true }
        Assert-OspfTest ($failed -and $global:CoreOspfMock.changes -eq 0 -and $global:CoreOspfMock.saves -eq 0) 'Prerequisite failure must prevent all routing changes'
        Write-Output "PASS: $failure prevents routing changes"
    }
    foreach ($conflict in @('router-id', 'loopback', 'cost')) {
        Reset-OspfLab
        switch ($conflict) {
            'router-id' { $global:CoreOspfMock.routers.R4.process = $true; $global:CoreOspfMock.routers.R4.routerId = '192.0.2.1' }
            'loopback' { $global:CoreOspfMock.routers.R4.loopback = @{ address = '192.0.2.1'; ospf = $false } }
            'cost' { $global:CoreOspfMock.routers.R4.interfaces['FastEthernet0/0'].cost = 999 }
        }
        $failed = $false
        try { Run-OspfTest } catch { $failed = $true }
        Assert-OspfTest ($failed -and $global:CoreOspfMock.changes -eq 0) 'Existing routing conflicts must fail before changing any router'
        Write-Output "PASS: conflicting $conflict is refused before changes"
    }
    foreach ($failure in @('neighbors', 'static-route', 'wrong-primary', 'ping')) {
        Reset-OspfLab
        $global:CoreOspfMock.fail = $failure
        $failed = $false
        try { Run-OspfTest } catch { $failed = $true }
        Assert-OspfTest ($failed -and $global:CoreOspfMock.saves -eq 0 -and $global:CoreOspfMock.closes -eq 4) 'Verification failure must prevent saving and close all consoles'
        Write-Output "PASS: $failure fails verification before saving"
    }
    Reset-OspfLab
    $global:CoreOspfMock.delayNeighbors = 2
    $global:CoreOspfMock.fail = 'delayed-route'
    Run-OspfTest
    Assert-OspfTest ($global:CoreOspfMock.neighborRounds -ge 4 -and $global:CoreOspfMock.routeReads -ge 24 -and $global:CoreOspfMock.saves -eq 4) 'Neighbor and route polling must tolerate convergence delay'
    Write-Output 'PASS: delayed neighbors and routes converge without process resets'
    Reset-OspfLab
    $global:CoreOspfMock.fail = 'interrupted-command'
    $failed = $false
    try { Run-OspfTest } catch { $failed = $true }
    Assert-OspfTest ($failed -and $global:CoreOspfMock.saves -eq 0) 'A console failure after applying a command must not save partial routing'
    $global:CoreOspfMock.fail = ''
    $global:CoreOspfMock.configEntries = @{}
    Run-OspfTest
    Assert-OspfTest ((Test-AllOspfConfigured) -and $global:CoreOspfMock.saves -eq 4 -and -not $global:CoreOspfMock.configEntries.ContainsKey('R1')) 'Resume must skip the completed R1 and finish the partially configured routers'
    Write-Output 'PASS: resumes after an applied R2 command loses its console acknowledgement'
    Reset-OspfLab
    $global:CoreOspfMock.fail = 'save-ack'
    $failed = $false
    try { Run-OspfTest } catch { $failed = $true }
    Assert-OspfTest ($failed -and $global:CoreOspfMock.saveAttempts -eq 2 -and $global:CoreOspfMock.saves -eq 1 -and $global:CoreOspfMock.closes -eq 4) 'Saving must stop on a missing OK and must not claim all four routers saved'
    Write-Output 'PASS: missing save acknowledgement fails even after routes and pings pass'
    Write-Output 'All OSPF tests passed.'
}
finally {
    $env:GITHUB_STEP_SUMMARY = $savedSummary
    Remove-Variable -Name CoreOspfMock -Scope Global -ErrorAction SilentlyContinue
}
