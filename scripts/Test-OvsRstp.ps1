[CmdletBinding()]
param(
    [ValidateSet('plan','prepare','apply')][string] $Mode = 'plan',
    [string] $ProjectName = 'Switching-Pilot-OVS',
    [string] $ApiBaseUrl = 'http://127.0.0.1:3076',
    [string] $EvidenceDirectory = 'artifacts/ovs-rstp',
    [ValidateRange(1,60)][int] $Attempts = 35
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IosConsole.ps1')
. (Join-Path $PSScriptRoot 'OvsConsole.ps1')
$api = $ApiBaseUrl.TrimEnd('/')
$left = 'OpenvSwitch-1'
$right = 'OpenvSwitch-2'
$expected = @{ $left = 'docker'; $right = 'docker'; 'Client-A' = 'vpcs'; 'Client-B' = 'vpcs'; 'Test-C' = 'vpcs' }
$requiredLinks = @('OpenvSwitch-1:0|OpenvSwitch-2:0', 'Client-A:0|OpenvSwitch-1:2', 'Client-B:0|OpenvSwitch-2:2', 'OpenvSwitch-2:3|Test-C:0')
$secondTrunk = 'OpenvSwitch-1:1|OpenvSwitch-2:1'
$nodes = @{}
$sessions = @{}
$transcript = [Collections.Generic.List[object]]::new()
$result = [ordered]@{
    mode = $Mode; project_name = $ProjectName; project_id = $null
    run_id = $env:GITHUB_RUN_ID; commit_sha = $env:GITHUB_SHA
    second_trunk_connected = $false; prepared = $false; passed = $false
    interrupted_port = ''; alternate_port = ''; shutdown_attempted = $false
    restored = $false; error = ''; restoration_error = ''
}
[void](New-Item -ItemType Directory -Force -Path $EvidenceDirectory)

function Read-Gns3([string] $Path) {
    $data = Invoke-RestMethod -Method Get -Uri "$api$Path" -TimeoutSec 15
    $data | ForEach-Object { $_ }
}

function Save-Result {
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'result.json') -Encoding UTF8
    ConvertTo-Json -InputObject $transcript.ToArray() -Depth 6 |
        Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'console-transcript.json') -Encoding UTF8
}

function Record-Command([string] $Node, [string] $Command, [string] $Output) {
    $transcript.Add([pscustomobject]@{ utc = [DateTime]::UtcNow.ToString('o'); node = $Node; command = $Command; output = $Output })
}

function Invoke-Ovs([string] $Node, [string] $Command) {
    try { $output = Send-OvsCommand $sessions[$Node] $Command }
    catch { Record-Command $Node $Command $_.Exception.Message; throw }
    Record-Command $Node $Command $output
    return $output
}

function Invoke-VpcsPing([string] $Node, [string] $Destination, [int] $Count) {
    $command = "ping $Destination -c $Count"
    $bytes = [Text.Encoding]::ASCII.GetBytes("$command" + [char]13)
    $session = $sessions[$Node]
    $session.Stream.Write($bytes, 0, $bytes.Length)
    $output = Read-IosResponse $session -TimeoutSeconds 12 -Vpcs
    Record-Command $Node $command $output
    $pattern = '(?im)^\s*\d+ bytes from ' + [regex]::Escape($Destination) + ' icmp_seq=(\d+)\s+ttl=\d+'
    return @([regex]::Matches($output, $pattern) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique).Count
}

function Assert-ClientPings([string] $Phase) {
    foreach ($probe in @(@{ node = 'Client-A'; ip = '192.168.10.12' }, @{ node = 'Client-B'; ip = '192.168.10.11' })) {
        $null = Invoke-VpcsPing $probe.node $probe.ip 1
        $count = Invoke-VpcsPing $probe.node $probe.ip 3
        if ($count -ne 3) { throw "$Phase VLAN 10 ping from $($probe.node) failed ($count/3)." }
    }
    Write-Output "PASS: $Phase VLAN 10 pings 3/3 in both directions."
}

function Assert-OvsPort([string] $Node, [string] $Port, [string] $Settings) {
    $bridge = Invoke-Ovs $Node "ovs-vsctl port-to-br $Port"
    $fields = Invoke-Ovs $Node "ovs-vsctl get Port $Port vlan_mode tag trunks"
    if ($bridge -ne 'br0' -or ($fields -replace '[\s"]','') -ne $Settings) {
        throw "$Node $Port has unexpected VLAN settings. Complete the VLAN pilot first."
    }
}

function Get-UplinkStates([string] $Node) {
    $states = @{}
    foreach ($port in 'eth0','eth1') {
        $status = Invoke-Ovs $Node "ovs-vsctl get Port $port rstp_status"
        $role = [regex]::Match($status, 'rstp_port_role="?([A-Za-z]+)').Groups[1].Value
        $state = [regex]::Match($status, 'rstp_port_state="?([A-Za-z]+)').Groups[1].Value
        $states[$port] = "$role $state"
    }
    return $states
}

function Test-AdminUp([string] $Port) {
    $output = Invoke-Ovs $right "ip link show $Port"
    $flags = [regex]::Match($output, '(?m)^\d+:\s+[^<\r\n]+<([^>]+)>')
    if (-not $flags.Success) { throw "Could not read $right $Port link flags." }
    return ($flags.Groups[1].Value -split ',') -contains 'UP'
}

function Wait-RstpStates([string] $Phase) {
    for ($i = 0; $i -lt $Attempts; $i++) {
        $states = Get-UplinkStates $right
        if ($Phase -eq 'prepare') {
            if ($states.eth0 -eq 'Root Forwarding') { return $states }
        }
        elseif ($Phase -eq 'failover') {
            if ($states[$result.alternate_port] -eq 'Root Forwarding' -and $states[$result.interrupted_port] -ne 'Root Forwarding') {
                return $states
            }
        }
        else {
            $forwarding = @($states.Keys | Where-Object { $states[$_] -eq 'Root Forwarding' })
            $alternate = @($states.Keys | Where-Object { $states[$_] -eq 'Alternate Discarding' })
            if ($forwarding.Count -eq 1 -and $alternate.Count -eq 1) { return $states }
        }
        if ($i -lt $Attempts - 1) { Start-Sleep -Seconds 1 }
    }
    throw "$Phase RSTP state did not converge. See console-transcript.json."
}

function Assert-RootSwitch {
    $states = Get-UplinkStates $left
    if ($states.eth0 -ne 'Designated Forwarding' -or $states.eth1 -ne 'Designated Forwarding') {
        throw "$left must be the root with both uplinks designated and forwarding."
    }
}

function Restore-Uplink {
    try { $null = Invoke-Ovs $right "ip link set $($result.interrupted_port) up" }
    catch {
        Close-IosConsole $sessions[$right]
        $sessions.Remove($right)
        $node = $nodes[$right]
        $sessions[$right] = Open-OvsConsole $node.console_host $node.console $right
        $null = Invoke-Ovs $right "ip link set $($result.interrupted_port) up"
    }
    if (-not (Test-AdminUp $result.interrupted_port)) { throw 'The interrupted uplink is still administratively down.' }
    $result.restored = $true
    Write-Output "RESTORED: $right $($result.interrupted_port) is administratively up."
}

try {
    $projects = @(Read-Gns3 '/v2/projects')
    $project = @($projects | Where-Object { $_.name -ceq $ProjectName })
    if ($project.Count -eq 0) {
        $openedNames = @($projects | Where-Object { $_.status -eq 'opened' } | ForEach-Object { $_.name })
        $opened = if ($openedNames.Count) { $openedNames -join ', ' } else { '(none)' }
        throw "Project '$ProjectName' was not found on the runner's controller. Open the OVS pilot in GNS3 and enter its exact name in project_name. Currently open: $opened"
    }
    if ($project.Count -gt 1) {
        throw "More than one project is named '$ProjectName'. Give the OVS pilot a unique name and enter it in project_name."
    }
    if ($project[0].status -ne 'opened') {
        throw "Project '$ProjectName' exists but is $($project[0].status). Open it in GNS3 on the runner PC and start a new plan run."
    }
    $result.project_id = ([guid]$project[0].project_id).ToString()
    $projectPath = "/v2/projects/$($result.project_id)"
    $nodeNames = @{}
    foreach ($node in @(Read-Gns3 "$projectPath/nodes")) {
        if (-not $expected.ContainsKey($node.name) -or $nodes.ContainsKey($node.name) -or
            $node.node_type -ne $expected[$node.name] -or $node.project_id -ne $result.project_id -or
            $node.compute_id -ne 'vm' -or -not $node.node_id -or $nodeNames.ContainsKey($node.node_id)) {
            throw "Unexpected node '$($node.name)'. Use the isolated OVS pilot topology."
        }
        $nodes[$node.name] = $node
        $nodeNames[$node.node_id] = $node.name
    }
    if ($nodes.Count -ne $expected.Count) { throw 'Expected OpenvSwitch-1, OpenvSwitch-2, Client-A, Client-B, and Test-C.' }
    $seen = @{}
    foreach ($link in @(Read-Gns3 "$projectPath/links")) {
        if (@($link.nodes).Count -ne 2 -or $link.link_type -ne 'ethernet' -or $link.suspend -eq $true -or
            @($link.filters.PSObject.Properties).Count -gt 0) { throw 'Unexpected or impaired OVS pilot link.' }
        $parts = foreach ($end in $link.nodes) {
            if (-not $nodeNames.ContainsKey($end.node_id) -or $end.port_number -ne 0) { throw 'Unexpected OVS pilot link endpoint.' }
            "$($nodeNames[$end.node_id]):$($end.adapter_number)"
        }
        $key = ($parts | Sort-Object) -join '|'
        if ($key -notin ($requiredLinks + $secondTrunk) -or $seen.ContainsKey($key)) { throw "Unexpected pilot cable $key." }
        $seen[$key] = $true
    }
    $missing = @($requiredLinks | Where-Object { -not $seen.ContainsKey($_) })
    if ($missing.Count) { throw "Missing pilot cables: $($missing -join ', ')." }
    $result.second_trunk_connected = $seen.ContainsKey($secondTrunk)
    if ($Mode -eq 'plan') {
        Write-Output "OVS pilot wiring passed. Second trunk connected: $($result.second_trunk_connected)."
        $result.passed = $true
        return
    }
    if ($Mode -eq 'prepare' -and $result.second_trunk_connected) { throw 'Uncable eth1 on both switches before prepare.' }
    if ($Mode -eq 'apply' -and -not $result.second_trunk_connected) { throw 'Complete prepare before cabling eth1 to eth1 and running apply.' }

    $endpoints = @{}
    foreach ($name in $left,$right,'Client-A','Client-B') {
        $node = $nodes[$name]
        $endpoint = "$($node.console_host):$($node.console)"
        if ($node.status -ne 'started' -or $node.console_type -ne 'telnet' -or $node.console -lt 1 -or $node.console -gt 65535 -or
            [string]::IsNullOrWhiteSpace($node.console_host) -or $node.console_host -in @('0.0.0.0','::') -or $endpoints.ContainsKey($endpoint)) {
            throw "Start $name and verify its distinct Telnet console."
        }
        $endpoints[$endpoint] = $true
        if ($node.node_type -eq 'docker') {
            $sessions[$name] = Open-OvsConsole $node.console_host $node.console $name
            if ((Invoke-Ovs $name 'ovs-vsctl --version') -notmatch 'ovs-vsctl \(Open vSwitch\)') { throw "$name is not an OVS console." }
        }
        else {
            try { $sessions[$name] = Open-IosConsole $node.console_host $node.console -Vpcs }
            catch { throw "Could not open $name console. $($_.Exception.Message)" }
        }
    }
    foreach ($name in $left,$right) {
        Assert-OvsPort $name 'eth0' 'trunk[][10,30,99]'
        Assert-OvsPort $name 'eth2' 'access10[]'
    }
    Assert-OvsPort $right 'eth3' 'access30[]'

    if ($Mode -eq 'prepare') {
        Assert-ClientPings 'single-trunk baseline'
        foreach ($name in $left,$right) {
            if ((Invoke-Ovs $name 'ovs-vsctl port-to-br eth1') -ne 'br0') { throw "$name eth1 must belong to br0." }
        }
        foreach ($name in $left,$right) {
            $priority = if ($name -eq $left) { 4096 } else { 32768 }
            $null = Invoke-Ovs $name "ovs-vsctl -- clear Port eth1 tag -- set Port eth1 vlan_mode=trunk trunks=10,30,99 -- set Port eth0 other_config:rstp-enable=true other_config:rstp-port-admin-edge=false other_config:rstp-port-auto-edge=false -- set Port eth1 other_config:rstp-enable=true other_config:rstp-port-admin-edge=false other_config:rstp-port-auto-edge=false -- set Bridge br0 stp_enable=false rstp_enable=true other_config:rstp-priority=$priority"
            Assert-OvsPort $name 'eth1' 'trunk[][10,30,99]'
            if ((Invoke-Ovs $name 'ovs-vsctl get Bridge br0 rstp_enable') -ne 'true') { throw "$name RSTP did not enable." }
        }
        $null = Wait-RstpStates 'prepare'
        Assert-ClientPings 'prepared single trunk'
        $result.prepared = $true
        $result.passed = $true
        Write-Output 'Both switches are prepared. Cable eth1 to eth1, then run apply.'
        return
    }

    foreach ($name in $left,$right) {
        Assert-OvsPort $name 'eth1' 'trunk[][10,30,99]'
        if ((Invoke-Ovs $name 'ovs-vsctl get Bridge br0 rstp_enable') -ne 'true') { throw "$name RSTP is disabled. Return to the one-trunk prepare step." }
    }
    if (-not (Test-AdminUp 'eth0') -or -not (Test-AdminUp 'eth1')) { throw "$right uplinks must both be administratively up." }
    $baseline = Wait-RstpStates 'baseline'
    $result.baseline_roles = $baseline
    Assert-RootSwitch
    Assert-ClientPings 'baseline'
    $result.interrupted_port = @($baseline.Keys | Where-Object { $baseline[$_] -eq 'Root Forwarding' })[0]
    $result.alternate_port = @($baseline.Keys | Where-Object { $baseline[$_] -eq 'Alternate Discarding' })[0]
    $result.shutdown_attempted = $true
    Save-Result
    try {
        $null = Invoke-Ovs $right "ip link set $($result.interrupted_port) down"
        if (Test-AdminUp $result.interrupted_port) { throw 'The selected uplink did not shut down.' }
        $result.failover_roles = Wait-RstpStates 'failover'
        Assert-ClientPings 'failover'
    }
    finally {
        try { Restore-Uplink }
        catch {
            $result.restoration_error = $_.Exception.Message
            Write-Warning "Restore $right with: ip link set $($result.interrupted_port) up"
            throw
        }
    }
    $result.recovery_roles = Wait-RstpStates 'recovery'
    Assert-RootSwitch
    Assert-ClientPings 'recovery'
    $result.passed = $true
    Write-Output 'VERIFIED: the alternate OVS trunk carried VLAN 10 after interruption and RSTP returned to a redundant state.'
}
catch { $result.error = $_.Exception.Message; throw }
finally {
    try { foreach ($session in $sessions.Values) { Close-IosConsole $session } }
    finally { Save-Result }
}
