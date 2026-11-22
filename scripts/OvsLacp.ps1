# The caller validates the isolated topology, access VLANs and client addresses.
function Test-PilotBond([string] $Node) {
    $ports = (Invoke-Ovs $Node 'ovs-vsctl list-ports br0') -split '\s+'
    if ('bond0' -notin $ports) {
        foreach ($port in 'eth0','eth1') { Assert-OvsPort $Node $port 'trunk[][10,30,99]' }
        if ((Invoke-Ovs $Node 'ovs-vsctl get Bridge br0 rstp_enable') -ne 'true') {
            throw "$Node requires the prepared RSTP trunks."
        }
        return $false
    }
    Assert-OvsPort $Node bond0 'trunk[][10,30,99]'
    $members = (Invoke-Ovs $Node 'ovs-vsctl get Port bond0 interfaces').Trim('[]') -split ',\s*'
    $expectedIds = foreach ($port in 'eth0','eth1') { Invoke-Ovs $Node "ovs-vsctl get Interface $port _uuid" }
    if ($members.Count -ne 2 -or (Compare-Object $members $expectedIds) -or
        ((Invoke-Ovs $Node 'ovs-vsctl get Port bond0 lacp bond_mode') -replace '[\s"]','') -notin 'activebalance-tcp','activeactive-backup') {
        throw "$Node bond0 must use active LACP with balance-tcp or active-backup and contain exactly eth0 and eth1."
    }
    return $true
}

function Wait-PilotBond([string] $Phase, [string] $Down) {
    $activePort = if ($Down -eq 'eth0') { 'eth1' } else { 'eth0' }
    for ($i = 0; $i -lt $Attempts; $i++) {
        $ready = $true
        foreach ($name in $left,$right) {
            $bond = Invoke-Ovs $name 'ovs-appctl bond/show bond0'
            $lacp = Invoke-Ovs $name 'ovs-appctl lacp/show bond0'
            if ($bond -notmatch '(?m)^lacp_status: negotiated\s*$') { $ready = $false }
            if ($bond -notmatch '(?m)^bond_mode: active-backup\s*$' -or
                $bond -notmatch "(?m)^active member mac: [^\r\n]*\($activePort\)\s*$") { $ready = $false }
            foreach ($port in 'eth0','eth1') {
                if ($port -eq $Down) {
                    if ($bond -notmatch "(?m)^member ${port}: disabled\s*$") { $ready = $false }
                }
                elseif ($bond -notmatch "(?m)^member ${port}: enabled\s*$" -or
                        $lacp -notmatch "(?m)^member: ${port}: current attached\s*$") { $ready = $false }
            }
        }
        if ($ready) {
            try { Assert-ClientPings $Phase }
            catch {
                $pingError = $_
                foreach ($switch in $left,$right) {
                    foreach ($command in 'ovs-vsctl --columns=name,vlan_mode,tag,trunks list Port',
                            'ovs-vsctl --columns=name,ofport,admin_state,link_state,error list Interface',
                            'ovs-appctl fdb/show br0', 'ovs-ofctl dump-ports br0') {
                        try { $null = Invoke-Ovs $switch $command }
                        catch { Write-Warning "Diagnostic failed on ${switch}: $command" }
                    }
                }
                throw $pingError
            }
            $result.checkpoints += $Phase
            Save-Result
            return
        }
        Start-Sleep -Seconds 1
    }
    throw "Bond did not converge at $Phase. See console-transcript.json."
}

function Invoke-LacpPilot {
    $result.checkpoints = @()
    $pending = @($left,$right | Where-Object { -not (Test-PilotBond $_) })
    if ($pending.Count) {
        # Isolate both physical paths before changing either bridge. On failure
        # leave them isolated until a retry completes both OVSDB transactions.
        foreach ($name in $left,$right) {
            foreach ($port in 'eth0','eth1') { $null = Invoke-Ovs $name "ip link set $port down" }
        }
        foreach ($name in $pending) {
            $null = Invoke-Ovs $name 'ovs-vsctl -- del-port br0 eth0 -- del-port br0 eth1 -- add-bond br0 bond0 eth0 eth1 -- set Port bond0 vlan_mode=trunk trunks=10,30,99 lacp=active bond_mode=active-backup other_config:lacp-time=fast other_config:bond-primary=eth0'
        }
    }
    foreach ($name in $left,$right) {
        if (-not (Test-PilotBond $name)) { throw "$name bond0 is missing." }
    }
    # Both ends now have one verified logical uplink. OVS 2.17 does not
    # support RSTP on bonded ports. Also normalize a previous partial run.
    foreach ($name in $left,$right) {
        # Migrate existing balance-tcp bonds in place on reruns.
        $null = Invoke-Ovs $name 'ovs-vsctl set Port bond0 bond_mode=active-backup other_config:bond-primary=eth0 other_config:lacp-time=fast'
        $null = Invoke-Ovs $name 'ovs-vsctl set Bridge br0 stp_enable=false rstp_enable=false'
        if ((Invoke-Ovs $name 'ovs-vsctl get Bridge br0 rstp_enable') -ne 'false') {
            throw "$name still has RSTP enabled after bond conversion."
        }
    }
    foreach ($name in $left,$right) {
        foreach ($port in 'eth0','eth1') { $null = Invoke-Ovs $name "ip link set $port up" }
    }
    Wait-PilotBond 'baseline'
    foreach ($port in 'eth0','eth1') {
        $result.interrupted_port = $port
        $result.shutdown_attempted = $true
        $result.restored = $false
        Save-Result
        try {
            $null = Invoke-Ovs $right "ip link set $port down"
            if (Test-AdminUp $port) { throw "$port is still up." }
            Wait-PilotBond "$port down" $port
        }
        finally {
            try { Restore-Uplink }
            catch { $result.restoration_error = $_.Exception.Message; throw }
        }
        Wait-PilotBond "$port restored"
    }
}
