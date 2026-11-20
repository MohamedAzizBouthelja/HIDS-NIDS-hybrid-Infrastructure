[CmdletBinding()]
param(
    [ValidateSet('plan','apply')][string] $Mode = 'plan',
    [string] $ApiBaseUrl = 'http://127.0.0.1:3076',
    [string] $EvidenceDirectory = 'artifacts/switching-pilot',
    [guid] $SwitchTemplateId
)

$ErrorActionPreference = 'Stop'
$api = $ApiBaseUrl.TrimEnd('/')
$projectName = 'Switching-Pilot'
$projectId = '7cbabf3b-476c-4693-9fc8-fa23a16ec4a7'
$projectPath = "/v2/projects/$projectId"
$devices = [ordered]@{
    'SW-A1' = @{ type = 'qemu'; x = -160; y = 0 }
    'SW-A2' = @{ type = 'qemu'; x = 160; y = 0 }
    'Client-A' = @{ type = 'vpcs'; x = -160; y = 170 }
    'Client-B' = @{ type = 'vpcs'; x = 85; y = 170 }
    'Test-C' = @{ type = 'vpcs'; x = 235; y = 170 }
}
$wires = @(
    @{ a = 'SW-A1'; a_port = 0; b = 'SW-A2'; b_port = 0 }
    @{ a = 'SW-A1'; a_port = 2; b = 'Client-A'; b_port = 0 }
    @{ a = 'SW-A2'; a_port = 2; b = 'Client-B'; b_port = 0 }
    @{ a = 'SW-A2'; a_port = 3; b = 'Test-C'; b_port = 0 }
)
$trunkB = @{ a = 'SW-A1'; a_port = 1; b = 'SW-A2'; b_port = 1 }

function Invoke-PilotApi([string] $Method, [string] $Path, $Payload) {
    $request = @{ Method = $Method; Uri = "$api$Path"; TimeoutSec = 30 }
    if ($null -ne $Payload) {
        $request.ContentType = 'application/json'
        $request.Body = ConvertTo-Json -InputObject $Payload -Depth 10 -Compress
    }
    $response = Invoke-RestMethod @request
    $response | ForEach-Object { if ($null -ne $_) { $_ } }
}

function Get-PilotEndpoints($Wire, $Nodes) {
    foreach ($side in @('a','b')) {
        $node = $Nodes[$Wire[$side]]
        $adapter = $Wire[${side} + '_port']
        if (-not $node) { return }
        $label = if ($node.node_type -eq 'qemu') { "Gi0/$adapter" } else { 'Ethernet0' }
        $port = @($node.ports | Where-Object {
            $_.adapter_number -eq $adapter -and $_.port_number -eq 0 -and
            ($_.name -eq $label -or $_.name -eq ($label -replace '^Gi', 'GigabitEthernet'))
        })
        if ($port.Count -ne 1) { throw "Unexpected port mapping for $($node.name) $label. Inspect the appliance ports." }
        @{ node_id = $node.node_id; adapter_number = $port[0].adapter_number; port_number = $port[0].port_number }
    }
}

function Get-PilotLinkKey($Endpoints) {
    return (($Endpoints | ForEach-Object { "$($_.node_id):$($_.adapter_number):$($_.port_number)" } | Sort-Object) -join '|')
}

function Read-PilotState {
    $nodes = @{}
    foreach ($node in @(Invoke-PilotApi GET "$projectPath/nodes")) {
        $expected = $devices[$node.name]
        if (-not $expected -or $nodes.ContainsKey($node.name) -or $node.project_id -ne $projectId -or
            $node.node_type -ne $expected.type -or $node.compute_id -ne 'vm' -or $node.console_type -ne 'telnet' -or
            ($expected.type -eq 'qemu' -and $node.template_id -ne $templateId)) {
            throw "Unexpected or incompatible node '$($node.name)' in $projectName."
        }
        $nodes[$node.name] = $node
    }
    $allowed = @(
        foreach ($wire in $wires + @($trunkB)) {
            $endpoints = @(Get-PilotEndpoints $wire $nodes)
            if ($endpoints.Count -eq 2) { Get-PilotLinkKey $endpoints }
        }
    )
    $existing = @{}
    foreach ($link in @(Invoke-PilotApi GET "$projectPath/links")) {
        $key = Get-PilotLinkKey $link.nodes
        if ($key -notin $allowed -or $existing.ContainsKey($key) -or $link.suspend -eq $true -or
            @($link.filters.PSObject.Properties).Count -gt 0) { throw "Unexpected or impaired link in $projectName." }
        $existing[$key] = $true
    }
    $missingWires = @(
        foreach ($wire in $wires) {
            $endpoints = @(Get-PilotEndpoints $wire $nodes)
            if ($endpoints.Count -ne 2 -or -not $existing.ContainsKey((Get-PilotLinkKey $endpoints))) { $wire }
        }
    )
    return @{ nodes = $nodes; missing_wires = $missingWires }
}

& (Join-Path $PSScriptRoot 'Test-SwitchReadiness.ps1') -ApiBaseUrl $ApiBaseUrl -EvidenceDirectory $EvidenceDirectory
$readiness = Get-Content -LiteralPath (Join-Path $EvidenceDirectory 'readiness.json') -Raw | ConvertFrom-Json
$eligible = @($readiness.eligible_template_ids)
if (-not $PSBoundParameters.ContainsKey('SwitchTemplateId')) {
    if ($eligible.Count -ne 1) { throw 'Multiple eligible templates. Select one with switch_template_id from readiness.json.' }
    $SwitchTemplateId = [guid]$eligible[0]
}
$templateId = $SwitchTemplateId.ToString()
if ($templateId -notin $eligible) { throw 'The selected switch template did not pass readiness.' }

$projects = @(Invoke-PilotApi GET '/v2/projects')
$project = @($projects | Where-Object { $_.project_id -eq $projectId -or $_.name -eq $projectName })
if ($project.Count -gt 1 -or ($project.Count -eq 1 -and
    ($project[0].project_id -ne $projectId -or $project[0].name -cne $projectName))) {
    throw 'Switching-Pilot name or ID conflict. Use the existing manual project with the pilot guide.'
}
if ($project.Count -eq 1 -and $project[0].status -ne 'opened') { throw 'Open Switching-Pilot in GNS3, then rerun.' }
$state = if ($project.Count) { Read-PilotState } else { @{ nodes = @{}; missing_wires = $wires } }
$plan = [ordered]@{
    project_id = $projectId
    project_name = $projectName
    template_id = $templateId
    create_project = $project.Count -eq 0
    create_nodes = @($devices.Keys | Where-Object { -not $state.nodes.ContainsKey($_) })
    create_links = @($state.missing_wires)
}
$planJson = ConvertTo-Json -InputObject $plan -Depth 8
$planJson | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'plan.json') -Encoding UTF8
Write-Output $planJson
if ($Mode -eq 'plan') { return }

if ($plan.create_project) {
    $created = Invoke-PilotApi POST '/v2/projects' @{
        name = $projectName; project_id = $projectId; auto_start = $false; auto_open = $false; auto_close = $false
    }
    if ($created.project_id -ne $projectId -or $created.name -cne $projectName -or $created.status -ne 'opened') {
        throw 'Unexpected project creation result.'
    }
}
foreach ($name in $plan.create_nodes) {
    $device = $devices[$name]
    $payload = @{ name = $name; compute_id = 'vm'; x = $device.x; y = $device.y }
    if ($device.type -eq 'qemu') {
        $null = Invoke-PilotApi POST "$projectPath/templates/$templateId" $payload
    }
    else {
        $payload.node_type = 'vpcs'
        $payload.console_type = 'telnet'
        $null = Invoke-PilotApi POST "$projectPath/nodes" $payload
    }
}
$state = Read-PilotState
if ($state.nodes.Count -ne $devices.Count) { throw 'The pilot does not contain all five expected nodes.' }
# Resolve all ports before adding any missing cables.
$newLinks = @(
    foreach ($wire in $state.missing_wires) { @{ nodes = @(Get-PilotEndpoints $wire $state.nodes) } }
)
foreach ($link in $newLinks) { $null = Invoke-PilotApi POST "$projectPath/links" $link }
$state = Read-PilotState
if ($state.nodes.Count -ne $devices.Count -or $state.missing_wires.Count) { throw 'Pilot topology verification failed.' }
ConvertTo-Json -InputObject @($state.nodes.Values | Select-Object name,node_id,node_type,ports,status) -Depth 8 |
    Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'nodes.json') -Encoding UTF8
Write-Output 'Pilot topology verified. Open it in GNS3 and start the devices for the boot and VLAN checks.'
