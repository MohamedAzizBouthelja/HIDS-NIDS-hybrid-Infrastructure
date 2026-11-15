[CmdletBinding()]
param(
    [ValidateSet('plan', 'apply')][string] $Mode = 'plan',
    [string] $ApiBaseUrl = 'http://127.0.0.1:3076',
    [string] $ManifestPath,
    [string] $RoutingPath,
    [string] $EvidenceDirectory
)
$ErrorActionPreference = 'Stop'
if (-not $ManifestPath) { $ManifestPath = Join-Path $PSScriptRoot '../gns3/core-topology.json' }
if (-not $RoutingPath) { $RoutingPath = Join-Path $PSScriptRoot '../gns3/ospf.json' }
. (Join-Path $PSScriptRoot 'IosConsole.ps1')
. (Join-Path $PSScriptRoot 'CoreInterfaces.ps1')
. (Join-Path $PSScriptRoot 'CoreOspf.ps1')
Invoke-CoreOspfConfiguration -Mode $Mode -ApiBaseUrl $ApiBaseUrl -ManifestPath $ManifestPath -RoutingPath $RoutingPath -EvidenceDirectory $EvidenceDirectory
