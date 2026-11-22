function Get-CableKey($a,$b) { return (@($a,$b) | Sort-Object) -join '|' }

function Get-IntegrationInventory($core, $NodeList, $LinkList) {
    $types = @{ R1='dynamips'; R2='dynamips'; R3='dynamips'; R4='dynamips'; 'SW-CLIENT'='docker'; 'Client-A'='vpcs'; 'SW-SERVER'='docker'; 'Server-A'='vpcs' }
    $extended = @($NodeList | Where-Object { $_.name -in 'MON-GW','NAT-1' }).Count -gt 0
    if ($extended) {
        $types['MON-GW'] = 'qemu'
        $types['NAT-1'] = 'nat'
    }
    $nodes = @{}
    $names = @{}
    foreach ($n in $NodeList) {
        if ($nodes.ContainsKey($n.name) -or $types[$n.name] -ne $n.node_type -or $n.compute_id -ne 'vm' -or $n.status -ne 'started') {
            throw "Unexpected or stopped integration node: $($n.name)."
        }
        $nodes[$n.name] = $n
        $names[$n.node_id] = $n.name
    }
    foreach ($name in $types.Keys) { if (-not $nodes.ContainsKey($name)) { throw "Missing $name in the integration copy." } }
    $expected = @(foreach ($link in $core.links) { Get-CableKey "$($link.a):$($link.a_adapter)" "$($link.b):$($link.b_adapter)" })
    $expected += @('Client-A:0|SW-CLIENT:2','R1:3|SW-CLIENT:4','R4:4|SW-SERVER:4','Server-A:0|SW-SERVER:2')
    if ($extended) {
        $expected += @('MON-GW:0|NAT-1:0','MON-GW:1|R4:3')
    }
    $actual = @(foreach ($link in $LinkList) {
        if ($link.nodes.Count -ne 2 -or $link.link_type -ne 'ethernet' -or $link.suspend -or @($link.filters.PSObject.Properties).Count -gt 0) { throw 'Unexpected or impaired cable.' }
        $ends = @(foreach ($e in $link.nodes) {
            if ($e.port_number -ne 0 -or -not $names.ContainsKey($e.node_id)) { throw 'Unexpected cable endpoint.' }
            "$($names[$e.node_id]):$($e.adapter_number)"
        })
        Get-CableKey $ends[0] $ends[1]
    })
    $diff = @(Compare-Object $expected $actual)
    if ($diff.Count) { throw "Check integration cables: $($diff.InputObject -join ', ')." }
    return @{ Nodes = $nodes; Extended = $extended }
}
