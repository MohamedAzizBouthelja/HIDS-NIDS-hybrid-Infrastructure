# Dependency-free contract tests. All HTTP calls are replaced with an in-memory API.
$ErrorActionPreference = 'Stop'
$deployScript = Join-Path $PSScriptRoot '../scripts/Deploy-CoreTopology.ps1'
$manifestPath = Join-Path $PSScriptRoot '../gns3/core-topology.json'
$fixture = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$managedId = $fixture.project.project_id
$savedSummary = $env:GITHUB_STEP_SUMMARY
$env:GITHUB_STEP_SUMMARY = ''

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "TEST FAILED: $Message" }
}

function Reset-MockLab {
    $global:CoreTopologyMock = @{
        projects = [System.Collections.Generic.List[object]]::new()
        nodes = [System.Collections.Generic.List[object]]::new()
        links = [System.Collections.Generic.List[object]]::new()
        writes = [System.Collections.Generic.List[object]]::new()
        failNodeName = ''
        connected = $true
    }
    # These baseline projects must never be modified.
    $global:CoreTopologyMock.projects.Add([pscustomobject]@{
        name = 'Foundation-Test'; project_id = 'c2de961e-c2bb-4849-bda7-2ae06e3fd28b'; status = 'opened'
    })
    $global:CoreTopologyMock.projects.Add([pscustomobject]@{
        name = 'Router-Boot-Test'; project_id = '7b095e33-a5df-43c0-818c-ccb01e8847d5'; status = 'opened'
    })
}

function Invoke-RestMethod {
    param($Uri, $Method, $TimeoutSec, $ContentType, $Body, $ErrorAction)
    $state = $global:CoreTopologyMock
    $path = ([uri]$Uri).AbsolutePath
    if ($Method -eq 'GET') {
        switch ($path) {
            '/v2/version' { return [pscustomobject]@{ version = '2.2.61' } }
            # Invoke-RestMethod emits a JSON array as one pipeline object.
            # Keep that shape, including empty and single-item arrays.
            '/v2/computes' { return ,@([pscustomobject]@{ compute_id = 'vm'; connected = $state.connected }) }
            '/v2/projects' { return ,($state.projects.ToArray()) }
            "/v2/projects/$managedId/nodes" { return ,($state.nodes.ToArray()) }
            "/v2/projects/$managedId/links" { return ,($state.links.ToArray()) }
            default { throw "Mock rejected unexpected GET $path" }
        }
    }
    if ($Method -ne 'POST') { throw "Mock rejected mutation method $Method" }
    $payload = if ($Body) { $Body | ConvertFrom-Json } else { $null }
    if ($path -eq '/v2/projects') {
        Assert-True ($payload.project_id -eq $managedId) 'Only the managed project may be created'
        Assert-True (@($state.projects | Where-Object { $_.project_id -eq $managedId }).Count -eq 0) 'Duplicate project creation'
        $created = [pscustomobject]@{ project_id = $payload.project_id; name = $payload.name; status = 'opened' }
        $state.projects.Add($created)
        $state.writes.Add($path)
        return $created
    }
    Assert-True ($path.StartsWith("/v2/projects/$managedId/")) 'Mutation outside managed project'
    if ($path -eq "/v2/projects/$managedId/nodes") {
        if ($payload.name -eq $state.failNodeName) { throw 'Simulated router creation failure' }
        Assert-True (@($state.nodes | Where-Object { $_.node_id -eq $payload.node_id }).Count -eq 0) 'Duplicate node creation'
        # IDs and MACs must be assigned by GNS3, not copied from the source router.
        Assert-True ($null -eq $payload.properties.mac_addr -and $null -eq $payload.properties.dynamips_id) 'Copied runtime router identity'
        $ports = @(0..5 | ForEach-Object { [pscustomobject]@{
            adapter_number = $_; port_number = 0; name = "FastEthernet$_/0"; link_type = 'ethernet'
        } })
        $created = [pscustomobject]@{
            node_id = $payload.node_id; project_id = $managedId; name = $payload.name
            compute_id = $payload.compute_id; node_type = $payload.node_type
            properties = $payload.properties; status = 'stopped'; ports = $ports
        }
        $state.nodes.Add($created)
        $state.writes.Add($path)
        return $created
    }
    if ($path -eq "/v2/projects/$managedId/links") {
        foreach ($endpoint in $payload.nodes) {
            foreach ($existing in $state.links) {
                foreach ($used in $existing.nodes) {
                    Assert-True (-not ($endpoint.node_id -eq $used.node_id -and
                        $endpoint.adapter_number -eq $used.adapter_number -and
                        $endpoint.port_number -eq $used.port_number)) 'Ethernet port already connected'
                }
            }
        }
        $created = [pscustomobject]@{
            link_id = [guid]::NewGuid().ToString(); nodes = $payload.nodes
            link_type = 'ethernet'; suspend = $false; filters = [pscustomobject]@{}
        }
        $state.links.Add($created)
        $state.writes.Add($path)
        return $created
    }
    if ($path -match '/nodes/([^/]+)/start$') {
        $idToStart = $Matches[1]
        $node = @($state.nodes | Where-Object { $_.node_id -eq $idToStart })
        Assert-True ($node.Count -eq 1) 'Start requested for unknown router'
        $node[0].status = 'started'
        $state.writes.Add($path)
        return $node[0]
    }
    throw "Mock rejected unexpected POST $path"
}

function Invoke-Deployment([string] $Mode = 'apply', [switch] $Start) {
    & $deployScript -ManifestPath $manifestPath -Mode $Mode -StartRouters:$Start | Out-Null
}

function Assert-RejectedWithoutWrites([string] $Label) {
    $global:CoreTopologyMock.writes.Clear()
    $rejected = $false
    try { Invoke-Deployment } catch { $rejected = $true }
    Assert-True $rejected "$Label must be rejected"
    Assert-True ($global:CoreTopologyMock.writes.Count -eq 0) "$Label must fail before mutations"
    Write-Output "PASS: $Label"
}

try {
    Reset-MockLab
    Invoke-Deployment -Mode plan -Start
    Assert-True ($global:CoreTopologyMock.writes.Count -eq 0) 'Plan must be read-only, even with Start requested'
    Write-Output 'PASS: fresh plan makes no changes'

    Invoke-Deployment
    Assert-True ($global:CoreTopologyMock.nodes.Count -eq 4 -and $global:CoreTopologyMock.links.Count -eq 5) 'Fresh deployment size'
    Assert-True ($global:CoreTopologyMock.writes.Count -eq 10) 'Exactly one project, four nodes, five links created'
    Assert-True (@($global:CoreTopologyMock.nodes | Where-Object { $_.status -ne 'stopped' }).Count -eq 0) 'Routers remain stopped by default'
    Write-Output 'PASS: creates isolated four-router project and five links'

    $global:CoreTopologyMock.writes.Clear()
    Invoke-Deployment
    Assert-True ($global:CoreTopologyMock.writes.Count -eq 0) 'Repeated deployment must be a no-op'
    Write-Output 'PASS: second apply creates no duplicates and makes no changes'

    Invoke-Deployment -Start
    Assert-True ($global:CoreTopologyMock.writes.Count -eq 4) 'Only four start requests expected'
    $global:CoreTopologyMock.writes.Clear()
    Invoke-Deployment -Start
    Assert-True ($global:CoreTopologyMock.writes.Count -eq 0) 'Started routers must not restart'
    Write-Output 'PASS: optional start is idempotent'

    # Reversed endpoints still identify the same cable.
    $firstLink = $global:CoreTopologyMock.links[0]
    $firstLink.nodes = @($firstLink.nodes[1], $firstLink.nodes[0])
    Invoke-Deployment
    Assert-True ($global:CoreTopologyMock.writes.Count -eq 0) 'Link identity must ignore endpoint order'
    Write-Output 'PASS: reversed cable endpoints are reused'

    $global:CoreTopologyMock.nodes[0].properties.slot2 = 'PA-4T+'
    Assert-RejectedWithoutWrites 'adapter drift'
    $global:CoreTopologyMock.nodes[0].properties.slot2 = 'PA-FE-TX'

    $global:CoreTopologyMock.nodes[0].properties.idlepc = ''
    Assert-RejectedWithoutWrites 'missing Idle-PC'
    $global:CoreTopologyMock.nodes[0].properties.idlepc = '0x60630338'

    $global:CoreTopologyMock.nodes[0].status = 'suspended'
    Assert-RejectedWithoutWrites 'suspended router'
    $global:CoreTopologyMock.nodes[0].status = 'started'

    $global:CoreTopologyMock.links[0].suspend = $true
    Assert-RejectedWithoutWrites 'suspended link'
    $global:CoreTopologyMock.links[0].suspend = $false

    $global:CoreTopologyMock.links[0].filters = [pscustomobject]@{ latency = @(10) }
    Assert-RejectedWithoutWrites 'active link impairment'
    $global:CoreTopologyMock.links[0].filters = [pscustomobject]@{}

    $global:CoreTopologyMock.nodes.Add($global:CoreTopologyMock.nodes[0])
    Assert-RejectedWithoutWrites 'duplicate router'
    $global:CoreTopologyMock.nodes.RemoveAt(4)

    $global:CoreTopologyMock.nodes[0].name = 'Unexpected-Router'
    Assert-RejectedWithoutWrites 'unexpected router'
    $global:CoreTopologyMock.nodes[0].name = 'R1'

    $global:CoreTopologyMock.nodes[0].node_id = [guid]::NewGuid().ToString()
    Assert-RejectedWithoutWrites 'same name with wrong node ID'
    $global:CoreTopologyMock.nodes[0].node_id = $fixture.routers[0].node_id

    $global:CoreTopologyMock.links[0].nodes[0].adapter_number = 5
    Assert-RejectedWithoutWrites 'incorrect cable endpoint'
    # Reset to a fresh project for recovery tests.
    Reset-MockLab
    $global:CoreTopologyMock.failNodeName = 'R3'
    $failed = $false
    try { Invoke-Deployment } catch { $failed = $true }
    Assert-True ($failed -and $global:CoreTopologyMock.nodes.Count -eq 2) 'Expected interruption after two routers'
    $global:CoreTopologyMock.failNodeName = ''
    $global:CoreTopologyMock.writes.Clear()
    Invoke-Deployment
    Assert-True ($global:CoreTopologyMock.nodes.Count -eq 4 -and $global:CoreTopologyMock.links.Count -eq 5) 'Interrupted deployment recovery'
    Assert-True ($global:CoreTopologyMock.writes.Count -eq 7) 'Resume creates only two missing routers and five links'
    Write-Output 'PASS: interrupted deployment resumes without deleting existing objects'

    Reset-MockLab
    $global:CoreTopologyMock.failNodeName = 'R2'
    $failed = $false
    try { Invoke-Deployment } catch { $failed = $true }
    Assert-True ($failed -and $global:CoreTopologyMock.nodes.Count -eq 1) 'Expected interruption after one router'
    $global:CoreTopologyMock.failNodeName = ''
    $global:CoreTopologyMock.writes.Clear()
    Invoke-Deployment
    Assert-True ($global:CoreTopologyMock.writes.Count -eq 8) 'Singleton node response: resume creates three routers and five links'
    Write-Output 'PASS: one-router and empty-link JSON arrays are handled correctly'

    while ($global:CoreTopologyMock.links.Count -gt 1) { $global:CoreTopologyMock.links.RemoveAt(1) }
    $global:CoreTopologyMock.writes.Clear()
    Invoke-Deployment
    Assert-True ($global:CoreTopologyMock.writes.Count -eq 4 -and $global:CoreTopologyMock.links.Count -eq 5) 'Singleton link response: create only four missing links'
    Write-Output 'PASS: single-link JSON array is handled correctly'

    $global:CoreTopologyMock.links.RemoveAt(0)
    $global:CoreTopologyMock.writes.Clear()
    Invoke-Deployment
    Assert-True ($global:CoreTopologyMock.writes.Count -eq 1 -and $global:CoreTopologyMock.links.Count -eq 5) 'Repair only missing cable'
    Write-Output 'PASS: missing link is recreated without touching routers'

    $coreProject = @($global:CoreTopologyMock.projects | Where-Object { $_.project_id -eq $managedId })[0]
    $coreProject.status = 'closed'
    Assert-RejectedWithoutWrites 'closed project'
    $coreProject.status = 'opened'

    $global:CoreTopologyMock.connected = $false
    Assert-RejectedWithoutWrites 'disconnected VM'

    Reset-MockLab
    $global:CoreTopologyMock.projects.Add([pscustomobject]@{
        name = 'Hybrid-Core-Lab'; project_id = [guid]::NewGuid().ToString(); status = 'opened'
    })
    Assert-RejectedWithoutWrites 'project name collision'
    Write-Output 'All core topology tests passed.'
}
finally {
    $env:GITHUB_STEP_SUMMARY = $savedSummary
    Remove-Variable -Name CoreTopologyMock -Scope Global -ErrorAction SilentlyContinue
}
