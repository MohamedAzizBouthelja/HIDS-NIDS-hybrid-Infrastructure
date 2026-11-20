[CmdletBinding()]
param(
    [ValidateSet('plan','apply')][string] $Mode = 'plan',
    [string] $ApiBaseUrl = 'http://127.0.0.1:3076',
    [string] $EvidenceDirectory = 'artifacts/switching-rstp',
    [ValidateRange(1,60)][int] $Attempts = 20
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IosConsole.ps1')
$projectId = '7cbabf3b-476c-4693-9fc8-fa23a16ec4a7'
$api = $ApiBaseUrl.TrimEnd('/')
$projectPath = "/v2/projects/$projectId"
$nodeTypes = @{ 'SW-A1' = 'qemu'; 'SW-A2' = 'qemu'; 'Client-A' = 'vpcs'; 'Client-B' = 'vpcs'; 'Test-C' = 'vpcs' }
$clients = [ordered]@{ 'Client-A' = '192.168.10.11'; 'Client-B' = '192.168.10.12' }
$sessions = @{}
$nodes = @{}
$transcript = [Collections.Generic.List[object]]::new()
$result = [ordered]@{
    project_id = $projectId; run_id = $env:GITHUB_RUN_ID; commit_sha = $env:GITHUB_SHA
    started_utc = [DateTime]::UtcNow.ToString('o'); mode = $Mode; vlan = 10
    shutdown_attempted = $false; interrupted_port = ''; alternate_port = ''; restored = $false
    passed = $false; error = ''; restoration_error = ''
}
[void](New-Item -ItemType Directory -Force -Path $EvidenceDirectory)

function Read-RstpApi([string] $Path) {
    $response = Invoke-RestMethod -Method Get -Uri "$api$Path" -TimeoutSec 15
    $response | ForEach-Object { $_ }
}

function Save-RstpEvidence {
    ConvertTo-Json -InputObject $transcript.ToArray() -Depth 6 |
        Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'console-transcript.json') -Encoding UTF8
    $result | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'result.json') -Encoding UTF8
}

function Save-RstpCommand([string] $Name, [string] $Command, [string] $Output) {
    $transcript.Add([pscustomobject]@{
        utc = [DateTime]::UtcNow.ToString('o'); node = $Name; command = $Command; output = $Output
    })
}

function Invoke-RstpCommand([string] $Name, [string] $Command) {
    $output = Send-IosCommand $sessions[$Name] $Command -TimeoutSeconds 12
    Save-RstpCommand $Name $Command $output
    return $output
}

function Get-RstpUplinks([string] $Output) {
    $ports = @{}
    foreach ($match in [regex]::Matches($Output, '(?im)^[ \t]*(?:Gi|GigabitEthernet)(0/[01])[ \t]+(Root|Altn|Desg)[ \t]+(FWD|BLK|LRN|LSN)[ \t]+([^\r\n]+)')) {
        $name = "GigabitEthernet$($match.Groups[1].Value)"
        if ($ports.ContainsKey($name)) { throw "Duplicate spanning-tree row for $name." }
        if ($match.Groups[4].Value -match '\bEdge\b') { throw "Uplink $name is an STP edge port." }
        $ports[$name] = "$($match.Groups[2].Value) $($match.Groups[3].Value)"
    }
    return $ports
}

function Wait-RstpState([string] $Phase) {
    for ($i = 0; $i -lt $Attempts; $i++) {
        $table = Invoke-RstpCommand 'SW-A2' 'show spanning-tree vlan 10'
        if ($table -match '(?im)^[ \t]*VLAN0010[ \t]*\r?$' -and $table -match 'protocol rstp') {
            $roles = Get-RstpUplinks $table
            $forwarding = @($roles.Keys | Where-Object { $roles[$_] -eq 'Root FWD' })
            $blocked = @($roles.Keys | Where-Object { $roles[$_] -eq 'Altn BLK' })
            if ($Phase -eq 'failover') {
                if ($forwarding.Count -eq 1 -and $forwarding[0] -eq $result.alternate_port -and
                    -not $roles.ContainsKey($result.interrupted_port)) { return $roles }
            }
            elseif ($roles.Count -eq 2 -and $forwarding.Count -eq 1 -and $blocked.Count -eq 1) {
                return $roles
            }
        }
        if ($i -lt $Attempts - 1) { Start-Sleep -Seconds 1 }
    }
    throw "$Phase did not reach the expected VLAN 10 spanning-tree state. See the console transcript."
}

function Invoke-VpcsPing([string] $Name, [string] $Destination, [int] $Count) {
    $session = $sessions[$Name]
    $command = "ping $Destination -c $Count"
    $bytes = [Text.Encoding]::ASCII.GetBytes("$command`r")
    $session.Stream.Write($bytes, 0, $bytes.Length)
    $output = Read-IosResponse $session -TimeoutSeconds 12
    Save-RstpCommand $Name $command $output
    $matches = [regex]::Matches($output, '(?im)^\s*\d+ bytes from ' + [regex]::Escape($Destination) + ' icmp_seq=(\d+)\s+ttl=\d+[^\r\n]*')
    return @($matches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique).Count
}

function Assert-ClientConnectivity([string] $Phase) {
    $null = Invoke-VpcsPing 'Client-A' $clients['Client-B'] 1
    $null = Invoke-VpcsPing 'Client-B' $clients['Client-A'] 1
    $forward = Invoke-VpcsPing 'Client-A' $clients['Client-B'] 3
    $reverse = Invoke-VpcsPing 'Client-B' $clients['Client-A'] 3
    if ($forward -ne 3 -or $reverse -ne 3) { throw "$Phase VLAN 10 ping failed (A to B: $forward/3, B to A: $reverse/3)." }
    Write-Output "PASS: $Phase VLAN 10 pings 3/3 in both directions."
}

function Set-RstpUplink([string] $Command) {
    $session = $sessions['SW-A2']
    if ($session.Prompt -match '\(') { $null = Invoke-RstpCommand 'SW-A2' 'end' }
    if ($session.Prompt -cne $switchPrompt) { throw 'SW-A2 console no longer has its original EXEC prompt.' }
    $null = Invoke-RstpCommand 'SW-A2' 'configure terminal'
    $null = Invoke-RstpCommand 'SW-A2' "interface $($result.interrupted_port)"
    $null = Invoke-RstpCommand 'SW-A2' $Command
    $null = Invoke-RstpCommand 'SW-A2' 'end'
}

function Restore-RstpUplink {
    try { Set-RstpUplink 'no shutdown' }
    catch {
        Close-IosConsole $sessions['SW-A2']
        $sessions.Remove('SW-A2')
        $node = $nodes['SW-A2']
        $sessions['SW-A2'] = Open-IosConsole $node.console_host $node.console -AllowConfigMode
        Set-RstpUplink 'no shutdown'
    }
    $port = $result.interrupted_port
    for ($i = 0; $i -lt $Attempts; $i++) {
        $status = Invoke-RstpCommand 'SW-A2' "show interfaces $port"
        if ($status -match ('(?im)^' + [regex]::Escape($port) + ' is up, line protocol is up\b')) {
            $result.restored = $true
            return
        }
        if ($i -lt $Attempts - 1) { Start-Sleep -Seconds 1 }
    }
    throw "SW-A2 $port did not return to up/up."
}

try {
    $project = Read-RstpApi $projectPath
    if ($project.project_id -ne $projectId -or $project.name -cne 'Switching-Pilot' -or $project.status -ne 'opened') {
        throw 'Open the workflow-provisioned Switching-Pilot project before running this test.'
    }
    foreach ($node in @(Read-RstpApi "$projectPath/nodes")) {
        if (-not $nodeTypes.ContainsKey($node.name) -or $nodes.ContainsKey($node.name) -or $node.project_id -ne $projectId -or
            $node.node_type -ne $nodeTypes[$node.name] -or $node.compute_id -ne 'vm') { throw "Unexpected pilot node '$($node.name)'." }
        $nodes[$node.name] = $node
    }
    if ($nodes.Count -ne $nodeTypes.Count) { throw 'Expected two switches and three VPCS in the pilot.' }

    $expected = @(
        'SW-A1:0|SW-A2:0', 'SW-A1:1|SW-A2:1', 'Client-A:0|SW-A1:2', 'Client-B:0|SW-A2:2', 'SW-A2:3|Test-C:0'
    )
    $namesById = @{}
    foreach ($node in $nodes.Values) {
        if (-not $node.node_id -or $namesById.ContainsKey($node.node_id)) { throw 'Missing or duplicate pilot node ID.' }
        $namesById[$node.node_id] = $node.name
    }
    $seen = @{}
    foreach ($link in @(Read-RstpApi "$projectPath/links")) {
        $parts = foreach ($endpoint in $link.nodes) {
            if (-not $namesById.ContainsKey($endpoint.node_id) -or $endpoint.port_number -ne 0) { throw 'Unexpected pilot link endpoint.' }
            "$($namesById[$endpoint.node_id]):$($endpoint.adapter_number)"
        }
        $key = ($parts | Sort-Object) -join '|'
        if ($key -notin $expected -or $seen.ContainsKey($key) -or $link.link_type -ne 'ethernet' -or $link.suspend -eq $true -or
            @($link.filters.PSObject.Properties).Count -gt 0) { throw 'Unexpected, duplicate or impaired pilot link.' }
        $seen[$key] = $true
    }
    $result.missing_links = @($expected | Where-Object { -not $seen.ContainsKey($_) })
    if ($Mode -eq 'plan') {
        if ($result.missing_links.Count) { Write-Output "Missing pilot links: $($result.missing_links -join ', ')" }
        Write-Output 'Plan: verify VLAN 10 redundant trunks, interrupt the forwarding uplink on SW-A2, verify the alternate path, then restore and recheck both links.'
        return
    }
    if ($result.missing_links.Count) { throw 'Complete both trunks and the three access cables before running apply.' }
    $endpoints = @{}
    foreach ($name in @('SW-A1','SW-A2','Client-A','Client-B')) {
        $node = $nodes[$name]
        if ($node.status -ne 'started' -or $node.console_type -ne 'telnet' -or $node.console -lt 1 -or
            $node.console -gt 65535 -or [string]::IsNullOrWhiteSpace($node.console_host) -or $node.console_host -in @('0.0.0.0','::')) {
            throw "Start $name and verify its Telnet console."
        }
        $endpointKey = '{0}:{1}' -f $node.console_host, $node.console
        if ($endpoints.ContainsKey($endpointKey)) { throw "Duplicate pilot console endpoint $endpointKey." }
        $endpoints[$endpointKey] = $true
        $sessions[$name] = Open-IosConsole $node.console_host $node.console -Vpcs:($node.node_type -eq 'vpcs')
    }
    $switchPrompt = $sessions['SW-A2'].Prompt
    foreach ($name in @('SW-A1','SW-A2')) {
        $summary = Invoke-RstpCommand $name 'show spanning-tree summary'
        if ($summary -notmatch 'Switch is in rapid-pvst mode') { throw "$name must run Rapid PVST before testing." }
        $trunks = Invoke-RstpCommand $name 'show interfaces trunk'
        foreach ($port in 0,1) {
            if ($trunks -notmatch "(?im)^[ \t]*(?:Gi|GigabitEthernet)0/$port[ \t]+[^\r\n]+[ \t]trunking[ \t]+999[ \t]*\r?$") {
                throw "$name Gi0/$port must be a standalone 802.1Q trunk with native VLAN 999."
            }
        }
    }
    $root = Invoke-RstpCommand 'SW-A1' 'show spanning-tree vlan 10'
    $rootPorts = Get-RstpUplinks $root
    if ($root -notmatch 'This bridge is the root' -or $rootPorts.Count -ne 2 -or
        @($rootPorts.Values | Where-Object { $_ -ne 'Desg FWD' }).Count) { throw 'SW-A1 must be the VLAN 10 root with both designated uplinks forwarding.' }

    $baseline = Wait-RstpState 'baseline'
    $result.interrupted_port = @($baseline.Keys | Where-Object { $baseline[$_] -eq 'Root FWD' })[0]
    $result.alternate_port = @($baseline.Keys | Where-Object { $baseline[$_] -eq 'Altn BLK' })[0]
    Assert-ClientConnectivity 'baseline'
    $result.shutdown_attempted = $true
    Save-RstpEvidence
    try {
        Set-RstpUplink 'shutdown'
        $null = Wait-RstpState 'failover'
        Assert-ClientConnectivity 'failover'
    }
    finally {
        try { Restore-RstpUplink }
        catch {
            $result.restoration_error = $_.Exception.Message
            Write-Warning "Restore $($result.interrupted_port) on SW-A2 with no shutdown."
            throw
        }
    }
    $null = Wait-RstpState 'recovery'
    Assert-ClientConnectivity 'recovery'
    $result.passed = $true
    Write-Output 'VERIFIED: VLAN 10 alternate trunk forwarded after the interruption and both trunks returned to the redundant state.'
}
catch { $result.error = $_.Exception.Message; throw }
finally {
    try {
        foreach ($session in $sessions.Values) { Close-IosConsole $session }
    }
    finally {
        $result.finished_utc = [DateTime]::UtcNow.ToString('o')
        Save-RstpEvidence
    }
}
