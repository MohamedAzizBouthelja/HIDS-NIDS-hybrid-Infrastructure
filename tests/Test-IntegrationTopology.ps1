$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/IntegrationTopology.ps1')
$core = Get-Content -Raw (Join-Path $PSScriptRoot '../gns3/core-topology.json') | ConvertFrom-Json

function New-TestNode($name, $type) {
    [pscustomobject]@{ name=$name; node_type=$type; node_id=$name; compute_id='vm'; status='started' }
}
function New-TestLink($a, $i, $b, $j) {
    [pscustomobject]@{
        link_type='ethernet'; suspend=$false; filters=[pscustomobject]@{}
        nodes=@(@{ node_id=$a; adapter_number=$i; port_number=0 }, @{ node_id=$b; adapter_number=$j; port_number=0 })
    }
}
function Assert-Rejected($nodes, $links, $label) {
    try { $null = Get-IntegrationInventory $core $nodes $links }
    catch { return }
    throw "Invalid topology accepted: $label"
}
$nodes = @(
    foreach ($r in $core.routers) { New-TestNode $r.name 'dynamips' }
    foreach ($s in 'SW-CLIENT','SW-SERVER') { New-TestNode $s 'docker' }
    foreach ($v in 'Client-A','Server-A') { New-TestNode $v 'vpcs' }
)
$links = @(
    foreach ($l in $core.links) { New-TestLink $l.b $l.b_adapter $l.a $l.a_adapter }
    New-TestLink 'SW-CLIENT' 2 'Client-A' 0
    New-TestLink 'SW-CLIENT' 4 'R1' 3
    New-TestLink 'SW-SERVER' 2 'Server-A' 0
    New-TestLink 'SW-SERVER' 4 'R4' 4
)
if ((Get-IntegrationInventory $core $nodes $links).Extended) { throw 'Baseline misclassified.' }
$gatewayNodes = $nodes + (New-TestNode 'MON-GW' 'qemu')
$extendedNodes = $gatewayNodes + (New-TestNode 'NAT-1' 'nat')
$extendedLinks = $links + (New-TestLink 'R4' 3 'MON-GW' 1) + (New-TestLink 'MON-GW' 0 'NAT-1' 0)
if (!(Get-IntegrationInventory $core $extendedNodes $extendedLinks).Extended) { throw 'Extension misclassified.' }
$apiNodes = $extendedNodes + (New-TestNode 'API-A' 'docker')
$apiLinks = $extendedLinks + (New-TestLink 'SW-SERVER' 3 'API-A' 0)
$null = Get-IntegrationInventory $core $apiNodes $apiLinks
Assert-Rejected $apiNodes $extendedLinks 'missing API cable'
Assert-Rejected $apiNodes ($extendedLinks + (New-TestLink 'API-A' 0 'SW-SERVER' 4)) 'API on trunk'
$httpNodes = $apiNodes + (New-TestNode 'HTTP-CLIENT' 'docker')
$httpLink = New-TestLink 'HTTP-CLIENT' 0 'SW-CLIENT' 3
$null = Get-IntegrationInventory $core $httpNodes ($apiLinks + $httpLink)
Assert-Rejected $httpNodes $apiLinks 'missing HTTP client cable'
Assert-Rejected $httpNodes ($apiLinks + (New-TestLink 'HTTP-CLIENT' 0 'SW-SERVER' 3)) 'HTTP client on server switch'
$vlanNodes = $httpNodes + (New-TestNode 'TEST-CLIENT' 'docker') + (New-TestNode 'MGMT-PC' 'vpcs') + (New-TestNode 'SEC-PC' 'vpcs')
$vlanLinks = $apiLinks + $httpLink + (New-TestLink 'TEST-CLIENT' 0 'SW-CLIENT' 5) + (New-TestLink 'MGMT-PC' 0 'SW-CLIENT' 6) + (New-TestLink 'SEC-PC' 0 'SW-SERVER' 5)
$null = Get-IntegrationInventory $core $vlanNodes $vlanLinks
Assert-Rejected $vlanNodes ($vlanLinks[0..($vlanLinks.Count - 2)]) 'missing security cable'
$apiNodes[-1].name = 'API-A-1'
$null = Get-IntegrationInventory $core $vlanNodes $vlanLinks
Assert-Rejected ($vlanNodes + (New-TestNode 'API-A' 'docker')) $vlanLinks 'ambiguous API node'
Assert-Rejected $gatewayNodes $links 'missing NAT'
foreach ($missing in 0..10) {
    $remaining = @(foreach ($i in 0..10) { if ($i -ne $missing) { $extendedLinks[$i] } })
    Assert-Rejected $extendedNodes $remaining "missing cable $missing"
}
Assert-Rejected $extendedNodes ($extendedLinks + $links[0]) 'duplicate cable'
$extendedLinks[9].nodes[0].adapter_number = 4
Assert-Rejected $extendedNodes $extendedLinks 'gateway on server trunk'
Write-Host 'PASS baseline, private-link extension, and invalid integration layouts'
