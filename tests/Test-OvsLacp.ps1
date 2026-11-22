$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../scripts/OvsLacp.ps1"
$left = 'left'
$right = 'right'
$Attempts = 1
$result = @{}
$script:down = ''
$script:bonds = @{}
$script:failProbe = $false
function Assert-OvsPort {}
function Save-Result {}
function Test-AdminUp { return $false }
function Restore-Uplink { $script:down = '' }
function Assert-ClientPings($Phase) {
    if ($script:failProbe -and $Phase -eq 'eth0 down') { throw 'injected ping failure' }
}
function Invoke-Ovs($Node, $Command) {
    switch -Wildcard ($Command) {
        'ovs-vsctl list-ports br0' { if ($script:bonds[$Node]) { return 'bond0' }; return 'eth0 eth1' }
        '*get Bridge br0 rstp_enable' { return 'true' }
        '*get Interface * _uuid' { return ($Command -split ' ')[3] }
        '*get Port bond0 interfaces' { return '[eth0, eth1]' }
        '*get Port bond0 lacp bond_mode' { return "active`nbalance-tcp" }
        '*add-bond*' { $script:bonds[$Node] = $true }
        'ip link set * down' { $script:down = ($Command -split ' ')[3] }
        'ip link set * up' { $script:down = '' }
        '*bond/show*' {
            $lines = foreach ($port in 'eth0','eth1') {
                $state = if ($port -eq $script:down) { 'disabled' } else { 'enabled' }
                "member ${port}: $state"
            }
            return (@('lacp_status: negotiated') + $lines -join "`n")
        }
        '*lacp/show*' { return "member: eth0: current attached`nmember: eth1: current attached" }
        default { throw "Unexpected $Command" }
    }
}
Invoke-LacpPilot
if (($result.checkpoints -join ',') -ne 'baseline,eth0 down,eth0 restored,eth1 down,eth1 restored') { throw 'Missing checkpoints' }
$script:failProbe = $true
try { Invoke-LacpPilot; throw 'Expected ping failure' } catch { if ($_.Exception.Message -ne 'injected ping failure') { throw } }
if ($script:down) { throw 'Failed to restore interrupted member' }
Write-Output 'Passed LACP conversion, both member tests, rerun and failure cleanup.'
