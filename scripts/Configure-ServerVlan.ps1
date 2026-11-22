[CmdletBinding()]
param(
    [ValidateSet('plan','apply')][string] $Mode = 'plan',
    [string] $ProjectName = 'Hybrid-Core-Integration',
    [string] $ApiBaseUrl = 'http://127.0.0.1:3076',
    [string] $EvidenceDirectory = 'artifacts/server-vlan'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IosConsole.ps1')
. (Join-Path $PSScriptRoot 'OvsConsole.ps1')
. (Join-Path $PSScriptRoot 'PilotConsole.ps1')
$core = Get-Content -Raw (Join-Path $PSScriptRoot '../gns3/core-topology.json') | ConvertFrom-Json
$sessions = @{}
$transcript = [Collections.Generic.List[object]]::new()
$result = [ordered]@{ project = $ProjectName; mode = $Mode; commit = $env:GITHUB_SHA; passed = $false; pings = @(); error = '' }
$null = New-Item -ItemType Directory -Force -Path $EvidenceDirectory

function Invoke-Router([string] $Name, [string] $Command) {
    try { $output = Send-IosCommand $sessions[$Name] $Command }
    catch { Record-Command $Name $Command $_.Exception.Message; throw }
    Record-Command $Name $Command $output
    return $output
}

function Test-RoutedPing([string] $Name, [string] $Address) {
    $null = Invoke-VpcsPing $Name $Address 1
    $probe = Invoke-VpcsPing $Name $Address 3
    $result.pings += @{ node = $Name; destination = $Address; replies = $probe.replies }
    if ($probe.replies -ne 3) { throw "$Name to $Address failed: $($probe.output)" }
    Write-Host "PASS $Name to $Address (3/3)"
}

function Get-CableKey($a,$b) { return (@($a,$b) | Sort-Object) -join '|' }

try {
    $projects = Invoke-RestMethod "$ApiBaseUrl/v2/projects" -TimeoutSec 15
    $project = @($projects | Where-Object { $_.name -ceq $ProjectName -and $_.status -eq 'opened' })
    if ($project.Count -ne 1 -or $ProjectName -eq $core.project.name -or $project[0].project_id -eq $core.project.project_id) {
        throw 'Open the integration copy and enter its exact project name.'
    }
    $base = "$ApiBaseUrl/v2/projects/$([guid]$project[0].project_id)"
    $types = @{ R1='dynamips'; R2='dynamips'; R3='dynamips'; R4='dynamips'; 'SW-CLIENT'='docker'; 'Client-A'='vpcs'; 'SW-SERVER'='docker'; 'Server-A'='vpcs' }
    $nodes = @{}
    $names = @{}
    foreach ($n in (Invoke-RestMethod "$base/nodes" -TimeoutSec 15)) {
        if ($nodes.ContainsKey($n.name) -or $types[$n.name] -ne $n.node_type -or $n.compute_id -ne 'vm' -or $n.status -ne 'started') {
            throw "Unexpected or stopped integration node: $($n.name)."
        }
        $nodes[$n.name] = $n
        $names[$n.node_id] = $n.name
    }
    foreach ($name in $types.Keys) { if (-not $nodes.ContainsKey($name)) { throw "Missing $name in the integration copy." } }
    $expected = @(foreach ($link in $core.links) { Get-CableKey "$($link.a):$($link.a_adapter)" "$($link.b):$($link.b_adapter)" })
    $expected += @('Client-A:0|SW-CLIENT:2','R1:3|SW-CLIENT:4','R4:4|SW-SERVER:4','Server-A:0|SW-SERVER:2')
    $actual = @(foreach ($link in (Invoke-RestMethod "$base/links" -TimeoutSec 15)) {
        if ($link.nodes.Count -ne 2 -or $link.link_type -ne 'ethernet' -or $link.suspend -or @($link.filters.PSObject.Properties).Count -gt 0) { throw 'Unexpected or impaired cable.' }
        $ends = @(foreach ($e in $link.nodes) {
            if ($e.port_number -ne 0 -or -not $names.ContainsKey($e.node_id)) { throw 'Unexpected cable endpoint.' }
            "$($names[$e.node_id]):$($e.adapter_number)"
        })
        Get-CableKey $ends[0] $ends[1]
    })
    $diff = @(Compare-Object $expected $actual)
    if ($diff.Count) { throw "Check integration cables: $($diff.InputObject -join ', ')." }
    foreach ($name in 'R1','R4','SW-SERVER','Client-A','Server-A') {
        $n = $nodes[$name]
        if ($n.console_type -ne 'telnet' -or -not $n.console_host -or $n.console -lt 1) { throw "Missing Telnet endpoint for $name." }
        $sessions[$name] = if ($n.node_type -eq 'docker') { Open-OvsConsole $n.console_host $n.console $name }
            else { Open-IosConsole $n.console_host $n.console -Vpcs:($n.node_type -eq 'vpcs') }
        if ($n.node_type -eq 'dynamips' -and $sessions[$name].Prompt -cne "$name#") { throw "Unexpected IOS hostname on $name." }
    }
    Assert-ClientAddress 'Client-A' '192.168.10.11'
    Test-RoutedPing 'Client-A' '10.255.0.4'
    $config = Invoke-Router R4 'show running-config | section ^interface FastEthernet4/0'
    $section = ''
    foreach ($line in ($config -split '[\r\n]+')) {
        if ($line -match '^interface (\S+)') {
            $section = $Matches[1]
            if ($section -notin 'FastEthernet4/0','FastEthernet4/0.20') { throw "Unexpected R4 subinterface $section." }
        }
        elseif ($section -and $line -match '^\s+(ip address|encapsulation)\b') {
            if ($section -ne 'FastEthernet4/0.20' -or $line.Trim() -notin 'ip address 192.168.20.1 255.255.255.0','encapsulation dot1Q 20') { throw "Conflicting R4 configuration: $line" }
        }
    }
    if ($config -notmatch '(?m)^interface FastEthernet4/0\s*$') { throw 'R4 FastEthernet4/0 missing.' }
    foreach ($port in 'eth2','eth4') {
        if ((Invoke-Ovs 'SW-SERVER' "ovs-vsctl port-to-br $port") -ne 'br0') { throw "$port must be a standalone port on br0." }
        $fields = (Invoke-Ovs 'SW-SERVER' "ovs-vsctl get Port $port vlan_mode tag trunks") -replace '[\s"]',''
        $desired = if ($port -eq 'eth2') { 'access20[]' } else { 'trunk[][20]' }
        if ($fields -notin '[][][]',$desired) { throw "Conflicting VLAN settings on $port." }
    }
    $server = Invoke-VpcsCommand 'Server-A' 'show ip' '(?i)IP/MASK'
    if ($server -notmatch '(?im)^IP/MASK\s*:\s*(0\.0\.0\.0/0|192\.168\.20\.11/24)\s*$') { throw 'Server-A already has a different address.' }
    if ($Mode -eq 'apply') {
        $null = Invoke-Ovs 'SW-SERVER' 'ovs-vsctl -- set Port eth2 vlan_mode=access tag=20 -- set Port eth4 vlan_mode=trunk trunks=20'
        foreach ($command in 'configure terminal','interface FastEthernet4/0','no shutdown','exit','interface FastEthernet4/0.20','encapsulation dot1Q 20','ip address 192.168.20.1 255.255.255.0','exit','router ospf 10','passive-interface FastEthernet4/0.20','network 192.168.20.0 0.0.0.255 area 0','end') {
            $null = Invoke-Router R4 $command
        }
        $null = Invoke-VpcsCommand 'Server-A' 'ip 192.168.20.11/24 192.168.20.1' '(?i)192\.168\.20\.11'
        Assert-ClientAddress 'Server-A' '192.168.20.11'
        Test-RoutedPing 'Server-A' '192.168.20.1'
        for ($i=0; $i -lt 30; $i++) {
            $route = Invoke-Router R1 'show ip route 192.168.20.0'
            if ($route -match 'Routing entry for 192\.168\.20\.0/24' -and $route -match 'Known via "ospf 10"' -and $route -match '10\.0\.12\.2') { break }
            if ($i -eq 29) { throw 'R1 did not learn VLAN 20 through R2.' }
            Start-Sleep -Seconds 1
        }
        Test-RoutedPing 'Client-A' '192.168.20.11'
        Test-RoutedPing 'Server-A' '192.168.10.11'
        if ((Invoke-Router R4 'write memory') -notmatch '\[OK\]') { throw 'R4 save was not acknowledged.' }
        $save = Invoke-VpcsCommand 'Server-A' 'save' '(?i)startup\.vpc|saved'
        if ($save -notmatch '(?i)done|saved') { throw "Server-A save was not acknowledged: $save" }
    }
    $result.passed = $true
}
catch { $result.error = $_.Exception.Message; throw }
finally {
    foreach ($s in $sessions.Values) { Close-IosConsole $s }
    $result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $EvidenceDirectory 'result.json') -Encoding UTF8
    ConvertTo-Json -InputObject $transcript.ToArray() -Depth 4 | Set-Content (Join-Path $EvidenceDirectory 'console-transcript.json') -Encoding UTF8
}
