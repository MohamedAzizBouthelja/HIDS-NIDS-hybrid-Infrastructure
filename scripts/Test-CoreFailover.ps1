[CmdletBinding()]
param(
    [ValidateSet('plan','apply')][string] $Mode = 'plan',
    [string] $ApiBaseUrl = 'http://127.0.0.1:3076',
    [string] $ManifestPath,
    [string] $EvidenceDirectory = 'artifacts/failover',
    [switch] $CaptureTraceroute,
    [switch] $MeasureLoss,
    [switch] $TestDirectBackup,
    [ValidateSet('R1-R2','R2-R4')][string] $PrimaryLink = 'R1-R2',
    [ValidateSet('Hybrid-Core-Lab','Hybrid-Core-Integration')][string] $ProjectName = 'Hybrid-Core-Lab'
)
$ErrorActionPreference = 'Stop'
if (-not $ManifestPath) { $ManifestPath = Join-Path $PSScriptRoot '../gns3/core-topology.json' }
. (Join-Path $PSScriptRoot 'IosConsole.ps1')
. (Join-Path $PSScriptRoot 'CoreInterfaces.ps1')
. (Join-Path $PSScriptRoot 'CoreOspf.ps1')
. (Join-Path $PSScriptRoot 'CoreFailover.ps1')
. (Join-Path $PSScriptRoot 'FailoverProbes.ps1')
. (Join-Path $PSScriptRoot 'IntegrationTopology.ps1')
. (Join-Path $PSScriptRoot 'FailoverHttp.ps1')
Invoke-CoreFailover -ProjectName $ProjectName -PrimaryLink $PrimaryLink -Mode $Mode -ApiBaseUrl $ApiBaseUrl -ManifestPath $ManifestPath -EvidenceDirectory $EvidenceDirectory -CaptureTraceroute:$CaptureTraceroute -MeasureLoss:$MeasureLoss -TestDirectBackup:$TestDirectBackup
