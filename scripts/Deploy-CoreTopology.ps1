[CmdletBinding()]
param(
    [ValidateSet('plan', 'apply')][string] $Mode = 'plan',
    [string] $ApiBaseUrl = 'http://127.0.0.1:3076',
    [string] $ManifestPath = (Join-Path $PSScriptRoot '../gns3/core-topology.json'),
    [switch] $StartRouters,
    [string] $EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$apiBase = $ApiBaseUrl.TrimEnd('/')
$projectId = $manifest.project.project_id
$projectPath = "/v2/projects/$projectId"
$desiredRouters = @($manifest.routers)
$desiredLinks = @($manifest.links)
$propertyNames = @($manifest.router_properties.PSObject.Properties.Name)
$routerByName = @{}
$desiredLinkByKey = @{}

function Invoke-Gns3([string] $Method, [string] $ApiPath, $Payload = $null) {
    $request = @{ Uri = "$apiBase$ApiPath"; Method = $Method; TimeoutSec = 60; ErrorAction = 'Stop' }
    if ($null -ne $Payload) {
        $request.ContentType = 'application/json'
        $request.Body = $Payload | ConvertTo-Json -Depth 20 -Compress
    }
    try {
        # Invoke-RestMethod emits a JSON array as one pipeline object.
        # Enumerate it here so callers' @(...) captures actual list items.
        $response = Invoke-RestMethod @request
        foreach ($item in $response) { Write-Output $item }
    }
    catch {
        # Do not retry POST automatically: the server may already have applied it.
        throw "$Method $ApiPath failed: $($_.Exception.Message). Inspect the lab and rerun to resume; existing matching objects are reused."
    }
}

function Get-EndpointKey($Endpoint) {
    return "$($Endpoint.node_id):$($Endpoint.adapter_number):$($Endpoint.port_number)"
}

function Get-LinkKey($Endpoints) {
    return ((@($Endpoints | ForEach-Object { Get-EndpointKey $_ }) | Sort-Object) -join '|')
}

function Get-DesiredEndpoints($Link) {
    return @(
        @{ node_id = $routerByName[$Link.a].node_id; adapter_number = [int]$Link.a_adapter; port_number = 0 }
        @{ node_id = $routerByName[$Link.b].node_id; adapter_number = [int]$Link.b_adapter; port_number = 0 }
    )
}

function Assert-Router($Node, $Expected) {
    if ($Node.node_id -ne $Expected.node_id -or $Node.name -cne $Expected.name -or
        $Node.project_id -ne $projectId -or $Node.node_type -ne 'dynamips' -or
        $Node.compute_id -ne $manifest.compute_id) {
        throw "Unexpected identity or emulator for $($Expected.name). No existing devices will be reconfigured."
    }
    foreach ($propertyName in $propertyNames) {
        if ($Node.properties.$propertyName -cne $manifest.router_properties.$propertyName) {
            throw "$($Expected.name): property $propertyName differs from the manifest. Resolve this explicitly; automatic replacement is disabled."
        }
    }
    if ($Node.status -notin @('started', 'stopped')) {
        throw "$($Expected.name) is $($Node.status); resolve its state before deployment."
    }
    $ports = @($Node.ports)
    if ($ports.Count -ne 6) { throw "$($Expected.name) must have exactly six Ethernet ports." }
    foreach ($adapter in 0..5) {
        $found = @($ports | Where-Object {
            $_.adapter_number -eq $adapter -and $_.port_number -eq 0 -and
            $_.name -ceq "FastEthernet$adapter/0" -and $_.link_type -eq 'ethernet'
        })
        if ($found.Count -ne 1) { throw "$($Expected.name): missing or invalid FastEthernet$adapter/0." }
    }
}

function Assert-State($Nodes, $Links) {
    $seenNames = @{}
    $seenIds = @{}
    foreach ($node in @($Nodes)) {
        if (-not $routerByName.ContainsKey($node.name)) {
            throw "Unexpected device '$($node.name)' in the managed core project. No devices will be deleted."
        }
        if ($seenNames.ContainsKey($node.name) -or $seenIds.ContainsKey($node.node_id)) {
            throw 'Duplicate device name or ID in the managed project.'
        }
        $seenNames[$node.name] = $true
        $seenIds[$node.node_id] = $true
        Assert-Router $node $routerByName[$node.name]
    }
    $seenLinks = @{}
    $seenEndpoints = @{}
    foreach ($link in @($Links)) {
        if (@($link.nodes).Count -ne 2) { throw 'Invalid existing link endpoint count.' }
        $key = Get-LinkKey $link.nodes
        if (-not $desiredLinkByKey.ContainsKey($key) -or $seenLinks.ContainsKey($key)) {
            throw 'Unexpected or duplicate link in the managed core project. No links will be deleted.'
        }
        if ($link.link_type -ne 'ethernet' -or $link.suspend -eq $true -or
            ($null -ne $link.filters -and @($link.filters.PSObject.Properties).Count -gt 0)) {
            throw 'An existing link is suspended, filtered, or not Ethernet. Resolve the experiment state before deployment.'
        }
        foreach ($endpoint in $link.nodes) {
            if (-not $seenIds.ContainsKey($endpoint.node_id)) { throw 'Existing link references an absent device.' }
            $endpointKey = Get-EndpointKey $endpoint
            if ($seenEndpoints.ContainsKey($endpointKey)) { throw 'An Ethernet port is used by multiple links.' }
            $seenEndpoints[$endpointKey] = $true
        }
        $seenLinks[$key] = $true
    }
}

function Save-Evidence([string] $FileName, $Value) {
    if ($EvidenceDirectory) {
        $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory $FileName) -Encoding UTF8
    }
}

# Validate the manifest before contacting the controller.
if ($projectId -in @('c2de961e-c2bb-4849-bda7-2ae06e3fd28b', '7b095e33-a5df-43c0-818c-ccb01e8847d5')) {
    throw 'The deployment must not target either baseline test project.'
}
[void][guid]::Parse($projectId)
if ($desiredRouters.Count -ne 4 -or $desiredLinks.Count -ne 5) { throw 'Expected four routers and five links.' }
$desiredIds = @{}
foreach ($router in $desiredRouters) {
    [void][guid]::Parse($router.node_id)
    if ($routerByName.ContainsKey($router.name) -or $desiredIds.ContainsKey($router.node_id)) { throw 'Duplicate manifest router.' }
    $routerByName[$router.name] = $router
    $desiredIds[$router.node_id] = $true
}
$desiredEndpoints = @{}
foreach ($link in $desiredLinks) {
    if (-not $routerByName.ContainsKey($link.a) -or -not $routerByName.ContainsKey($link.b) -or $link.a -eq $link.b -or
        $link.a_adapter -notin 0..5 -or $link.b_adapter -notin 0..5) { throw 'Invalid manifest link.' }
    $endpoints = Get-DesiredEndpoints $link
    foreach ($endpoint in $endpoints) {
        $key = Get-EndpointKey $endpoint
        if ($desiredEndpoints.ContainsKey($key)) { throw 'Manifest uses the same Ethernet port twice.' }
        $desiredEndpoints[$key] = $true
    }
    $desiredLinkByKey[(Get-LinkKey $endpoints)] = $link
}

if ($EvidenceDirectory) { [void](New-Item -ItemType Directory -Path $EvidenceDirectory -Force) }
$version = Invoke-Gns3 GET '/v2/version'
if ($version.version -notlike '2.2.*') { throw 'This deployment targets the GNS3 2.2 API.' }
$computes = @(Invoke-Gns3 GET '/v2/computes')
$compute = @($computes | Where-Object { $_.compute_id -eq $manifest.compute_id })
if ($compute.Count -ne 1 -or $compute[0].connected -ne $true) { throw 'GNS3 VM is missing or disconnected.' }
$projects = @(Invoke-Gns3 GET '/v2/projects')
$project = @($projects | Where-Object { $_.project_id -eq $projectId })
$nameConflicts = @($projects | Where-Object { $_.name -eq $manifest.project.name -and $_.project_id -ne $projectId })
if ($project.Count -gt 1 -or $nameConflicts.Count -gt 0 -or
    ($project.Count -eq 1 -and $project[0].name -cne $manifest.project.name)) {
    throw 'Core project name/ID conflict. Existing projects will not be adopted or renamed.'
}

$nodes = @()
$links = @()
if ($project.Count -eq 1) {
    if ($project[0].status -ne 'opened') {
        # Opening can start devices if auto_start is set. Require the user to open it explicitly.
        throw 'Open Hybrid-Core-Lab in GNS3 before rerunning. The workflow does not automatically open closed projects.'
    }
    $nodes = @(Invoke-Gns3 GET "$projectPath/nodes")
    $links = @(Invoke-Gns3 GET "$projectPath/links")
    Assert-State $nodes $links
}
$missingRouters = @($desiredRouters | Where-Object { $_.node_id -notin @($nodes.node_id) })
$existingLinkKeys = @($links | ForEach-Object { Get-LinkKey $_.nodes })
$missingLinks = @($desiredLinks | Where-Object { (Get-LinkKey (Get-DesiredEndpoints $_)) -notin $existingLinkKeys })
$plan = [ordered]@{
    mode = $Mode; project_id = $projectId; project_name = $manifest.project.name
    create_project = ($project.Count -eq 0)
    create_routers = @($missingRouters.name)
    create_links = @($missingLinks | ForEach-Object { "$($_.a):f$($_.a_adapter)/0 -- $($_.b):f$($_.b_adapter)/0" })
    start_routers = [bool]$StartRouters
    timestamp_utc = [datetime]::UtcNow.ToString('o')
    git_commit = $env:GITHUB_SHA
}
Save-Evidence 'plan.json' $plan
Save-Evidence 'before.json' @{ nodes = $nodes; links = $links }
Write-Output ($plan | ConvertTo-Json -Depth 10)
if ($Mode -eq 'plan') {
    Write-Output 'PLAN ONLY: no changes made. Select apply to create the missing objects.'
    return
}

# Additive operations only. No PUT, DELETE, router stop, or IOS configuration.
try {
    if ($project.Count -eq 0) {
        $created = Invoke-Gns3 POST '/v2/projects' @{
            name = $manifest.project.name; project_id = $projectId
            auto_close = $false; auto_open = $false; auto_start = $false
        }
        if ($created.project_id -ne $projectId -or $created.status -ne 'opened') { throw 'Unexpected project creation response.' }
    }
    foreach ($router in $missingRouters) {
        Write-Output "Creating $($router.name)"
        $createdNode = Invoke-Gns3 POST "$projectPath/nodes" @{
            node_id = $router.node_id; name = $router.name; compute_id = $manifest.compute_id
            node_type = 'dynamips'; console_type = 'telnet'; symbol = ':/symbols/router.svg'
            x = [int]$router.x; y = [int]$router.y; properties = $manifest.router_properties
        }
        Assert-Router $createdNode $router
    }
    foreach ($link in $missingLinks) {
        Write-Output "Connecting $($link.a) to $($link.b)"
        $null = Invoke-Gns3 POST "$projectPath/links" @{ nodes = @(Get-DesiredEndpoints $link) }
    }

    # Re-read and verify before starting any router.
    $nodes = @(Invoke-Gns3 GET "$projectPath/nodes")
    $links = @(Invoke-Gns3 GET "$projectPath/links")
    Assert-State $nodes $links
    if ($nodes.Count -ne 4 -or $links.Count -ne 5) { throw 'Deployment did not produce four routers and five links.' }
    if ($StartRouters) {
        foreach ($node in $nodes) {
            if ($node.status -ne 'started') {
                Write-Output "Starting $($node.name)"
                $null = Invoke-Gns3 POST "$projectPath/nodes/$($node.node_id)/start"
            }
        }
        $nodes = @(Invoke-Gns3 GET "$projectPath/nodes")
        Assert-State $nodes $links
        if (@($nodes | Where-Object { $_.status -ne 'started' }).Count -gt 0) { throw 'Not all routers are started.' }
    }
    Write-Output 'VERIFIED: four routers, five Ethernet links, and the expected adapters and Idle-PC.'
    Write-Output 'No IP addresses or routing protocols have been configured. API started status does not prove IOS finished booting.'
    if ($env:GITHUB_STEP_SUMMARY) {
        @(
            '## Core topology verified'
            "Project: $($manifest.project.name) ($projectId)"
            "Created routers: $($missingRouters.Count); created links: $($missingLinks.Count)."
            "Start routers requested: $([bool]$StartRouters)."
            'Four routers, five Ethernet links. IP addressing and routing configuration are still pending.'
        ) | Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding UTF8 -Append
    }
}
finally {
    # Preserve partial state after failure; do not delete devices or their configurations.
    try {
        $currentNodes = @(Invoke-Gns3 GET "$projectPath/nodes")
        $currentLinks = @(Invoke-Gns3 GET "$projectPath/links")
        Save-Evidence 'after.json' @{ nodes = $currentNodes; links = $currentLinks }
    }
    catch { Write-Warning "Could not collect final evidence: $($_.Exception.Message)" }
}
