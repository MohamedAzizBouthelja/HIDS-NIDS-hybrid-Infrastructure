function Get-CoreOspfNeighbors([string] $Output) {
    $rows = [regex]::Matches($Output, '(?m)^\s*([0-9.]+)\s+\d+\s+(\S+)\s+\S+\s+([0-9.]+)\s+((?:FastEthernet|Fa)\d/0)\s*$')
    foreach ($row in $rows) {
        [pscustomobject]@{
            router_id = $row.Groups[1].Value; state = $row.Groups[2].Value
            address = $row.Groups[3].Value
            interface = ($row.Groups[4].Value -replace '^Fa(?=\d)', 'FastEthernet')
        }
    }
}

function Test-CoreOspfRoute([string] $Output, [int] $ProcessId, $ExpectedPrimary, [string] $Destination) {
    if (-not $Destination -or $Output -notmatch ('(?m)^Routing entry for ' + [regex]::Escape($Destination) + '/32\s*$')) { return $false }
    if ($Output -notmatch ('Known via "ospf ' + $ProcessId + '"')) { return $false }
    if ($null -eq $ExpectedPrimary) { return $true }
    $hops = [regex]::Matches($Output, '(?m)^\s*\*?\s*([0-9.]+),[^\r\n]*\bvia\s+((?:FastEthernet|Fa)\d/0)\s*$')
    return ($hops.Count -eq 1 -and $hops[0].Groups[1].Value -eq $ExpectedPrimary.next_hop -and
        ($hops[0].Groups[2].Value -replace '^Fa(?=\d)', 'FastEthernet') -eq $ExpectedPrimary.interface)
}

function Invoke-CoreOspfConfiguration {
    [CmdletBinding()]
    param(
        [ValidateSet('plan', 'apply')][string] $Mode = 'plan',
        [string] $ApiBaseUrl = 'http://127.0.0.1:3076',
        [string] $ManifestPath,
        [string] $RoutingPath,
        [string] $EvidenceDirectory
    )
    $ErrorActionPreference = 'Stop'
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $routing = Get-Content -LiteralPath $RoutingPath -Raw | ConvertFrom-Json
    if ($routing.process_id -ne 10 -or $routing.area -ne 0 -or @($routing.router_ids.PSObject.Properties).Count -ne 4) { throw 'Expected OSPF process 10, area 0, and four router IDs.' }
    if (@($routing.primary_routes).Count -ne 2) { throw 'Expected primary-route checks in both directions.' }
    foreach ($name in @('R1', 'R4')) {
        $checks = @($routing.primary_routes | Where-Object { $_.router -ceq $name })
        $destination = if ($name -eq 'R1') { '10.255.0.4' } else { '10.255.0.1' }
        $nextHop = if ($name -eq 'R1') { '10.0.12.2' } else { '10.0.24.1' }
        if ($checks.Count -ne 1 -or $checks[0].destination -ne $destination -or $checks[0].next_hop -ne $nextHop -or $checks[0].interface -ne 'FastEthernet0/0') { throw 'Primary-route checks must require the path through R2 in both directions.' }
    }
    $interfaces = @{}
    $expectedNeighbors = @{}
    $routerByName = @{}
    foreach ($router in $manifest.routers) {
        $routerByName[$router.name] = $router
        if ($router.name -cnotmatch '^R[1-4]$' -or $routing.router_ids.($router.name) -cne ('10.255.0.' + $router.name.Substring(1))) { throw 'Unexpected router name or OSPF router ID.' }
        $interfaces[$router.name] = @()
        $expectedNeighbors[$router.name] = @()
    }
    foreach ($link in $manifest.links) {
        $cost = $routing.link_costs.($link.subnet)
        if ($cost -notin @(10, 30, 100)) { throw "Invalid OSPF cost for $($link.subnet)." }
        foreach ($side in @('a', 'b')) {
            $peer = if ($side -eq 'a') { 'b' } else { 'a' }
            $name = $link.$side
            $interfaces[$name] += [pscustomobject]@{ name = "FastEthernet$($link."${side}_adapter")/0"; address = $link."${side}_ip"; cost = $cost }
            $expectedNeighbors[$name] += [pscustomobject]@{
                router_id = $routing.router_ids.($link.$peer); address = $link."${peer}_ip"
                interface = "FastEthernet$($link."${side}_adapter")/0"
            }
        }
    }
    # Reuse the established read-only topology validation (no console or IOS writes).
    Invoke-CoreInterfaceConfiguration -Mode plan -ApiBaseUrl $ApiBaseUrl -ManifestPath $ManifestPath | Out-Null
    $response = Invoke-RestMethod -Uri "$($ApiBaseUrl.TrimEnd('/'))/v2/projects/$($manifest.project.project_id)/nodes" -Method Get -TimeoutSec 15 -ErrorAction Stop
    $nodes = @($response | ForEach-Object { $_ })
    $plan = @($manifest.routers | ForEach-Object {
        [pscustomobject]@{ router = $_.name; process_id = 10; area = 0; loopback0 = $routing.router_ids.($_.name); interfaces = $interfaces[$_.name] }
    })
    if ($EvidenceDirectory) { [void](New-Item -ItemType Directory -Path $EvidenceDirectory -Force) }
    function Save-OspfEvidence([string] $FileName, $Value) {
        if ($EvidenceDirectory) { $Value | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory $FileName) -Encoding UTF8 }
    }
    Save-OspfEvidence 'ospf-plan.json' $plan
    Write-Output ($plan | ConvertTo-Json -Depth 10)
    if ($Mode -eq 'plan') { Write-Output 'PLAN ONLY: no console connections or routing changes.'; return }

    $sessions = @{}
    $transcript = [System.Collections.Generic.List[object]]::new()
    $backup = @{}
    $pending = @{}
    $neighborHistory = @()
    $routeEvidence = @()
    $pingEvidence = @()
    function Invoke-OspfCommand([string] $Name, [string] $Command) {
        $output = Send-IosCommand $sessions[$Name] $Command
        $transcript.Add([pscustomobject]@{ router = $Name; command = $Command; output = $output })
        Save-OspfEvidence 'console-transcript.json' $transcript.ToArray()
        return $output
    }
    function Add-OspfInterfaceCommands([string] $Name, [string] $IfName, [string] $OldConfig, [bool] $IsLink, [int] $Cost) {
        $commands = @()
        $processLine = [regex]::Matches($OldConfig, '(?m)^\s*ip ospf \d+ area [^\r\n]+')
        if ($processLine.Count -gt 1 -or ($processLine.Count -eq 1 -and $processLine[0].Value.Trim() -notmatch '^ip ospf 10 area (0|0\.0\.0\.0)$')) { throw "$Name $IfName belongs to another OSPF process or area." }
        if ($processLine.Count -eq 0) { $commands += 'ip ospf 10 area 0' }
        if ($IsLink) {
            $networkLine = [regex]::Matches($OldConfig, '(?m)^\s*ip ospf network [^\r\n]+')
            if ($networkLine.Count -gt 1 -or ($networkLine.Count -eq 1 -and $networkLine[0].Value.Trim() -ne 'ip ospf network point-to-point')) { throw "$Name $IfName has an unexpected OSPF network type." }
            if ($networkLine.Count -eq 0) { $commands += 'ip ospf network point-to-point' }
            $costLine = [regex]::Matches($OldConfig, '(?m)^\s*ip ospf cost \d+')
            if ($costLine.Count -gt 1 -or ($costLine.Count -eq 1 -and $costLine[0].Value.Trim() -ne "ip ospf cost $Cost")) { throw "$Name $IfName has a different OSPF cost. Resolve it explicitly." }
            if ($costLine.Count -eq 0) { $commands += "ip ospf cost $Cost" }
        }
        return $commands
    }
    try {
        # Inspect every router before making routing changes on any router.
        foreach ($node in $nodes) {
            $name = $node.name
            $routerId = $routing.router_ids.$name
            Write-Output "Checking OSPF prerequisites: $name"
            $sessions[$name] = Open-IosConsole $node.console_host $node.console
            $brief = Invoke-OspfCommand $name 'show ip interface brief'
            $routerConfig = Invoke-OspfCommand $name 'show running-config | section ^router'
            $backup[$name] = [ordered]@{ router_configuration = $routerConfig; interfaces = @(); loopback0 = $null }
            $protocols = [regex]::Matches($routerConfig, '(?m)^router ([^\r\n]+)')
            if ($protocols.Count -gt 1 -or ($protocols.Count -eq 1 -and $protocols[0].Groups[1].Value.Trim() -ne 'ospf 10')) { throw "$name has another routing protocol/process. No automatic redistribution or protocol removal is allowed." }
            if ($protocols.Count -eq 1 -and $routerConfig -notmatch "(?m)^\s*router-id $([regex]::Escape($routerId))\s*$") { throw "$name has an existing OSPF process with a missing or different explicit router ID. No automatic process restart is allowed." }
            if ($routerConfig -match '(?m)^\s*(network |redistribute |area |default-information |distribute-list |distance |passive-interface (?!default))') { throw "$name has additional routing policy outside this baseline." }
            $commands = @()
            $hasLoopback = $brief -match '(?m)^Loopback0\s+'
            $loopConfig = ''
            if ($hasLoopback) {
                $loopConfig = Invoke-OspfCommand $name 'show running-config interface Loopback0'
                $backup[$name].loopback0 = $loopConfig
                if ($loopConfig -notmatch "(?m)^\s*ip address $([regex]::Escape($routerId)) 255\.255\.255\.255\s*$" -or
                    [regex]::Matches($loopConfig, '(?m)^\s*ip address ').Count -ne 1 -or
                    $loopConfig -match '(?m)^\s*(ip unnumbered|ip vrf forwarding|vrf forwarding)\b') { throw "$name Loopback0 has an unexpected address or routing context." }
            }
            $loopCommands = @(Add-OspfInterfaceCommands $name 'Loopback0' $loopConfig $false 0)
            if (-not $hasLoopback -or $loopConfig -match '(?m)^\s*shutdown\s*$') {
                $commands += 'interface Loopback0'
                if (-not $hasLoopback) { $commands += "ip address $routerId 255.255.255.255" }
                if (-not $hasLoopback -or $loopConfig -match '(?m)^\s*shutdown\s*$') { $commands += 'no shutdown' }
                $commands += 'exit'
            }
            # Loopback exists before the process is created, keeping its selected ID stable.
            $processCommands = @()
            if ($protocols.Count -eq 0) { $processCommands += "router-id $routerId" }
            if ($routerConfig -notmatch '(?m)^\s*passive-interface default\s*$') { $processCommands += 'passive-interface default' }
            foreach ($interface in $interfaces[$name]) {
                if ($routerConfig -notmatch "(?m)^\s*no passive-interface $([regex]::Escape($interface.name))\s*$") { $processCommands += "no passive-interface $($interface.name)" }
            }
            if ($processCommands.Count -gt 0) { $commands += 'router ospf 10'; $commands += $processCommands; $commands += 'exit' }
            # Set the explicit process router ID before enabling OSPF on any interface.
            if ($loopCommands.Count -gt 0) { $commands += 'interface Loopback0'; $commands += $loopCommands; $commands += 'exit' }
            foreach ($interface in $interfaces[$name]) {
                $upPattern = '(?m)^' + [regex]::Escape($interface.name) + '\s+' + [regex]::Escape($interface.address) + '\s+\S+\s+\S+\s+up\s+up\s*$'
                if ($brief -notmatch $upPattern) { throw "$name $($interface.name) is not at the expected address and up/up state. Run the interface workflow first." }
                $oldConfig = Invoke-OspfCommand $name "show running-config interface $($interface.name)"
                $backup[$name].interfaces += [pscustomobject]@{ name = $interface.name; configuration = $oldConfig }
                if ($oldConfig -notmatch "(?m)^\s*ip address $([regex]::Escape($interface.address)) 255\.255\.255\.252\s*$") { throw "$name $($interface.name) has an unexpected subnet mask." }
                $ifCommands = @(Add-OspfInterfaceCommands $name $interface.name $oldConfig $true $interface.cost)
                if ($ifCommands.Count -gt 0) { $commands += "interface $($interface.name)"; $commands += $ifCommands; $commands += 'exit' }
            }
            $pending[$name] = $commands
        }
        Save-OspfEvidence 'before-ospf.json' $backup
        Save-OspfEvidence 'pending-commands.json' $pending
        foreach ($name in @('R1', 'R2', 'R3', 'R4')) {
            if (@($pending[$name]).Count -eq 0) { Write-Output "$name already matches the OSPF configuration."; continue }
            Write-Output "Configuring OSPF: $name"
            $null = Invoke-OspfCommand $name 'configure terminal'
            foreach ($command in $pending[$name]) { $null = Invoke-OspfCommand $name $command }
            $null = Invoke-OspfCommand $name 'end'
        }
        $stable = 0
        for ($attempt = 1; $attempt -le 40; $attempt++) {
            $allFull = $true
            foreach ($name in @('R1', 'R2', 'R3', 'R4')) {
                $output = Invoke-OspfCommand $name 'show ip ospf neighbor'
                $neighbors = @(Get-CoreOspfNeighbors $output)
                $healthy = $neighbors.Count -eq @($expectedNeighbors[$name]).Count
                foreach ($expected in $expectedNeighbors[$name]) {
                    $found = @($neighbors | Where-Object { $_.router_id -eq $expected.router_id -and $_.address -eq $expected.address -and $_.interface -eq $expected.interface -and $_.state -like 'FULL/*' })
                    if ($found.Count -ne 1) { $healthy = $false }
                }
                if (-not $healthy) { $allFull = $false }
                $neighborHistory += [pscustomobject]@{ attempt = $attempt; router = $name; full = $healthy; output = $output }
                Write-Output "OSPF check ${attempt}: $name neighbors=$($neighbors.Count), expected=$(@($expectedNeighbors[$name]).Count), all FULL=$healthy"
            }
            Save-OspfEvidence 'neighbors.json' $neighborHistory
            if ($allFull) { $stable++ } else { $stable = 0 }
            if ($stable -ge 2) { break }
            if ($attempt -lt 40) { Start-Sleep -Seconds 3 }
        }
        if ($stable -lt 2) { throw 'OSPF did not reach the expected ten directional FULL adjacencies. Inspect neighbors.json; no process restart or link cut was attempted.' }

        # Verify all twelve remote /32 routes and the primary next hops in both directions.
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            $routesReady = $true
            $routeEvidence = @()
            foreach ($name in @('R1', 'R2', 'R3', 'R4')) {
                foreach ($remote in @('R1', 'R2', 'R3', 'R4') | Where-Object { $_ -ne $name }) {
                    $destination = $routing.router_ids.$remote
                    $output = Invoke-OspfCommand $name "show ip route $destination"
                    $primary = @($routing.primary_routes | Where-Object { $_.router -eq $name -and $_.destination -eq $destination })
                    $expected = if ($primary.Count -eq 1) { $primary[0] } else { $null }
                    $valid = Test-CoreOspfRoute $output 10 $expected $destination
                    if (-not $valid) { $routesReady = $false }
                    $routeEvidence += [pscustomobject]@{ router = $name; destination = $destination; valid = $valid; output = $output }
                }
            }
            Save-OspfEvidence 'routes.json' $routeEvidence
            if ($routesReady) { break }
            if ($attempt -lt 10) { Start-Sleep -Seconds 3 }
        }
        if (-not $routesReady) { throw 'Missing OSPF routes or incorrect primary next hop. Inspect routes.json before proceeding.' }
        foreach ($name in @('R1', 'R2', 'R3', 'R4')) {
            foreach ($remote in @('R1', 'R2', 'R3', 'R4') | Where-Object { $_ -ne $name }) {
                $destination = $routing.router_ids.$remote
                $source = $routing.router_ids.$name
                $null = Invoke-OspfCommand $name "ping $destination source $source repeat 1 timeout 1"
                $output = Invoke-OspfCommand $name "ping $destination source $source repeat 3 timeout 1"
                $passed = $output -match 'Success rate is 100 percent\s*\(3/3\)'
                $pingEvidence += [pscustomobject]@{ router = $name; source = $source; destination = $destination; passed = $passed; output = $output }
                Save-OspfEvidence 'loopback-pings.json' $pingEvidence
                if (-not $passed) { throw "Routed ping failed: $name ($source) to $remote ($destination). Configurations have not been saved by this run." }
                Write-Output "PASS: $name loopback -> $remote loopback (3/3)"
            }
        }
        foreach ($name in @('R1', 'R2', 'R3', 'R4')) {
            $output = Invoke-OspfCommand $name 'write memory'
            if ($output -notmatch '\[OK\]') { throw "$name did not acknowledge saving OSPF configuration." }
        }
        Write-Output 'VERIFIED: ten directional FULL adjacencies; twelve OSPF loopback routes and ping tests; primary R1-R2-R4 route in both directions; four configurations saved.'
        Write-Output 'Backup paths are configured but failover has not been tested. No links were cut.'
        if ($env:GITHUB_STEP_SUMMARY) {
            @('## OSPF baseline verified', '', '- Ten directional FULL adjacencies across five links', '- Twelve remote loopback routes learned through OSPF 10', '- Twelve loopback-source ping tests: 3/3 each', '- R1 to R4 and R4 to R1 primary next hops point through R2', '- Four configurations saved', '', 'No failover test or link cut was performed.') |
                Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding UTF8 -Append
        }
    }
    finally {
        try {
            foreach ($name in @($sessions.Keys)) {
                if ($sessions[$name].Prompt -match '\(') {
                    try { $null = Invoke-OspfCommand $name 'end' } catch { Write-Warning "Could not return $name to EXEC mode." }
                }
            }
            Save-OspfEvidence 'before-ospf.json' $backup
            Save-OspfEvidence 'console-transcript.json' $transcript.ToArray()
        }
        finally {
            foreach ($session in $sessions.Values) {
                try { Close-IosConsole $session } catch { Write-Warning 'Could not close an OSPF console session.' }
            }
        }
    }
}
