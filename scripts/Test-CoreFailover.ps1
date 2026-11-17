[CmdletBinding()]
param(
    [ValidateSet('plan','apply')][string] $Mode = 'plan',
    [string] $ApiBaseUrl = 'http://127.0.0.1:3076',
    [string] $ManifestPath,
    [string] $EvidenceDirectory = 'artifacts/failover',
    [switch] $CaptureTraceroute,
    [switch] $MeasureLoss,
    [switch] $TestDirectBackup
)
$ErrorActionPreference = 'Stop'
if (-not $ManifestPath) { $ManifestPath = Join-Path $PSScriptRoot '../gns3/core-topology.json' }
. (Join-Path $PSScriptRoot 'IosConsole.ps1')
. (Join-Path $PSScriptRoot 'CoreInterfaces.ps1')
. (Join-Path $PSScriptRoot 'CoreOspf.ps1')
. (Join-Path $PSScriptRoot 'CoreFailover.ps1')
. (Join-Path $PSScriptRoot 'FailoverProbes.ps1')
Invoke-CoreFailover -Mode $Mode -ApiBaseUrl $ApiBaseUrl -ManifestPath $ManifestPath -EvidenceDirectory $EvidenceDirectory -CaptureTraceroute:$CaptureTraceroute -MeasureLoss:$MeasureLoss -TestDirectBackup:$TestDirectBackup
