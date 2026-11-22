$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../scripts/OvsLacp.ps1"
$left = 'left'
$right = 'right'
$Attempts = 1
$result = @{}
$script:down = ''
$script:bonds = @{}
$script:rstp = @{ left = 'true'; right = 'true' }
$script:diagnostics = 0
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
        '*get Bridge br0 rstp_enable' { return $script:rstp[$Node] }
        '*set Bridge br0 stp_enable=false rstp_enable=false' {
            if ($script:bonds.Count -ne 2) { throw 'Both bonds must exist before disabling RSTP' }
            $script:rstp[$Node] = 'false'
        }
        'ovs-vsctl --columns=*' { return '' }
        'ovs-appctl fdb/show br0' { $script:diagnostics++; return '' }
        'ovs-ofctl dump-ports br0' { return '' }
        '*get Interface * _uuid' { return ($Command -split ' ')[3] }
        '*get Port bond0 interfaces' { return '[eth0, eth1]' }
        '*get Port bond0 lacp bond_mode' { return "active`n$($script:bonds[$Node])" }
        '*add-bond*bond_mode=active-backup*' { $script:bonds[$Node] = 'active-backup' }
        'ovs-vsctl set Port bond0 bond_mode=active-backup other_config:bond-primary=eth0 other_config:lacp-time=fast' {
            $script:bonds[$Node] = 'active-backup'
        }
        'ip link set * down' { $script:down = ($Command -split ' ')[3] }
        'ip link set * up' { $script:down = '' }
        '*bond/show*' {
            $lines = foreach ($port in 'eth0','eth1') {
                $state = if ($port -eq $script:down) { 'disabled' } else { 'enabled' }
                "member ${port}: $state"
            }
            $active = if ($script:down -eq 'eth0') { 'eth1' } else { 'eth0' }
            return (@('lacp_status: negotiated', "bond_mode: $($script:bonds[$Node])", "active member mac: 02:00:00:00:00:01($active)") + $lines -join "`n")
        }
        '*lacp/show*' { return "member: eth0: current attached`nmember: eth1: current attached" }
        default { throw "Unexpected $Command" }
    }
}
Invoke-LacpPilot
if (($result.checkpoints -join ',') -ne 'baseline,eth0 down,eth0 restored,eth1 down,eth1 restored') { throw 'Missing checkpoints' }
if ($script:rstp.Values -contains 'true') { throw 'RSTP still enabled' }
$script:bonds = @{ left = 'balance-tcp'; right = 'balance-tcp' }
Invoke-LacpPilot
if ($script:bonds.Values -contains 'balance-tcp') { throw 'Existing bonds were not migrated' }
$script:rstp[$left] = 'true'
$script:failProbe = $true
try { Invoke-LacpPilot; throw 'Expected ping failure' } catch { if ($_.Exception.Message -ne 'injected ping failure') { throw } }
if ($script:diagnostics -ne 2 -or $script:rstp[$left] -ne 'false') { throw 'Missing diagnostics or existing bond repair' }
if ($script:down) { throw 'Failed to restore interrupted member' }
Write-Output 'Passed LACP conversion, both member tests, rerun and failure cleanup.'
