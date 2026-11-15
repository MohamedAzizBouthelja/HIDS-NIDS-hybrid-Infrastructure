function Invoke-CoreInterfaceConfiguration {
    [CmdletBinding()]
    param(
        [ValidateSet('plan', 'apply')][string] $Mode = 'plan',
        [string] $ApiBaseUrl = 'http://127.0.0.1:3076',
        [string] $ManifestPath,
        [string] $EvidenceDirectory
    )
    $ErrorActionPreference = 'Stop'
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $apiBase = $ApiBaseUrl.TrimEnd('/')
    $projectId = $manifest.project.project_id
    $projectPath = "/v2/projects/$projectId"
    $byName = @{}
    $interfaces = @{}
    $usedPorts = @{}
    $usedAddresses = @{}
    $expectedLinks = @()
    $transcript = [System.Collections.Generic.List[object]]::new()
    $sessions = @{}

    function Read-CoreApi([string] $Path) {
        $response = Invoke-RestMethod -Uri "$apiBase$Path" -Method Get -TimeoutSec 15 -ErrorAction Stop
        foreach ($item in $response) { Write-Output $item }
    }
    function Save-CoreEvidence([string] $FileName, $Value) {
        if ($EvidenceDirectory) {
            $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory $FileName) -Encoding UTF8
        }
    }
    function Invoke-RecordedCommand([string] $Name, [string] $Command) {
        $output = Send-IosCommand $sessions[$Name] $Command
        $transcript.Add([pscustomobject]@{ router = $Name; command = $Command; output = $output })
        Save-CoreEvidence 'console-transcript.json' $transcript.ToArray()
        return $output
    }
    function Get-LinkIdentity($Endpoints) {
        return ((@($Endpoints | ForEach-Object { "$($_.node_id):$($_.adapter_number):$($_.port_number)" }) | Sort-Object) -join '|')
    }
    function ConvertTo-Ipv4Number([string] $Address) {
        if ($Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "Invalid IPv4 address: $Address" }
        $parsed = [System.Net.IPAddress]::Parse($Address)
        $bytes = $parsed.GetAddressBytes()
        if ($bytes.Length -ne 4) { throw 'Only IPv4 is supported.' }
        return ([uint64]$bytes[0] * 16777216 + [uint64]$bytes[1] * 65536 + [uint64]$bytes[2] * 256 + $bytes[3])
    }

    if ($projectId -ne 'cf3df97c-53f6-4ab7-a3d3-980d0fc96de7') { throw 'Interface configuration targets only the dedicated Hybrid-Core-Lab project.' }
    if (@($manifest.routers).Count -ne 4 -or @($manifest.links).Count -ne 5) { throw 'Expected four routers and five links in the manifest.' }
    $nodeIds = @{}
    foreach ($router in $manifest.routers) {
        if ($router.name -cnotmatch '^R[1-4]$' -or $byName.ContainsKey($router.name) -or $nodeIds.ContainsKey($router.node_id)) { throw 'Invalid or duplicate manifest router.' }
        [void][guid]::Parse($router.node_id)
        $byName[$router.name] = $router
        $nodeIds[$router.node_id] = $true
        $interfaces[$router.name] = @()
    }
    foreach ($link in $manifest.links) {
        if ($link.a -eq $link.b -or -not $byName.ContainsKey($link.a) -or -not $byName.ContainsKey($link.b) -or
            $link.a_adapter -notin 0..5 -or $link.b_adapter -notin 0..5 -or $link.subnet -notmatch '^([0-9.]+)/30$') { throw 'Invalid manifest link.' }
        $network = ConvertTo-Ipv4Number ($link.subnet.Split('/')[0])
        if ($network % 4 -ne 0) { throw 'The link subnet is not a /30 network boundary.' }
        $endpoints = @()
        foreach ($side in @('a', 'b')) {
            $name = $link.$side
            $adapter = $link."${side}_adapter"
            $address = [string]$link."${side}_ip"
            $ipNumber = ConvertTo-Ipv4Number $address
            if (($ipNumber -ne ($network + 1) -and $ipNumber -ne ($network + 2)) -or $usedAddresses.ContainsKey($address)) { throw 'Link addresses must be distinct usable hosts in the declared /30.' }
            $portKey = "${name}:$adapter"
            if ($usedPorts.ContainsKey($portKey)) { throw 'The manifest uses an interface twice.' }
            $usedPorts[$portKey] = $true
            $usedAddresses[$address] = $true
            $peerSide = if ($side -eq 'a') { 'b' } else { 'a' }
            $interfaces[$name] += [pscustomobject]@{
                name = "FastEthernet$adapter/0"; address = $address; mask = '255.255.255.252'
                peer_address = [string]$link."${peerSide}_ip"
            }
            $endpoints += @{ node_id = $byName[$name].node_id; adapter_number = $adapter; port_number = 0 }
        }
        $expectedLinks += Get-LinkIdentity $endpoints
    }

    if ($EvidenceDirectory) { [void](New-Item -ItemType Directory -Path $EvidenceDirectory -Force) }
    $projects = @(Read-CoreApi '/v2/projects')
    $project = @($projects | Where-Object { $_.project_id -eq $projectId })
    if ($project.Count -ne 1 -or $project[0].status -ne 'opened') { throw 'Open Hybrid-Core-Lab before running this workflow.' }
    $nodes = @(Read-CoreApi "$projectPath/nodes")
    $links = @(Read-CoreApi "$projectPath/links")
    if ($nodes.Count -ne 4 -or $links.Count -ne 5) { throw 'Deploy the four routers and five links first.' }
    $seenNames = @{}
    foreach ($node in $nodes) {
        if (-not $byName.ContainsKey($node.name) -or $seenNames.ContainsKey($node.name) -or
            $node.node_id -ne $byName[$node.name].node_id -or $node.project_id -ne $projectId -or
            $node.status -ne 'started' -or $node.compute_id -ne 'vm' -or $node.node_type -ne 'dynamips' -or
            $node.console_type -ne 'telnet' -or $node.console -lt 1 -or $node.console -gt 65535 -or
            [string]::IsNullOrWhiteSpace($node.console_host) -or $node.console_host -eq '0.0.0.0') {
            throw 'Unexpected, stopped, or incorrectly placed router, or unusable console endpoint.'
        }
        $seenNames[$node.name] = $true
    }
    $seenLinks = @{}
    foreach ($link in $links) {
        $key = Get-LinkIdentity $link.nodes
        if (@($link.nodes).Count -ne 2 -or $key -notin $expectedLinks -or $seenLinks.ContainsKey($key) -or
            $link.link_type -ne 'ethernet' -or $link.suspend -eq $true -or
            ($null -ne $link.filters -and @($link.filters.PSObject.Properties).Count -gt 0)) { throw 'Unexpected or impaired core link. No IOS commands were sent.' }
        $seenLinks[$key] = $true
    }
    $plan = @($manifest.routers | ForEach-Object {
        [pscustomobject]@{ router = $_.name; hostname = $_.name; interfaces = $interfaces[$_.name] }
    })
    Save-CoreEvidence 'address-plan.json' $plan
    Write-Output ($plan | ConvertTo-Json -Depth 10)
    if ($Mode -eq 'plan') {
        Write-Output 'PLAN ONLY: API GET requests only; no console connections or IOS changes.'
        return
    }

    $pendingCommands = @{}
    $backup = @{}
    $applied = @()
    $pingResults = @()
    try {
        # Read and back up all target interfaces before changing any router.
        foreach ($node in $nodes) {
            $name = $node.name
            Write-Output "Checking IOS console: $name"
            $sessions[$name] = Open-IosConsole $node.console_host $node.console
            $hostnameOutput = Invoke-RecordedCommand $name 'show running-config | include ^hostname'
            if ($hostnameOutput -notmatch '(?m)^hostname ([A-Za-z0-9_.:-]+)\s*$') { throw "$name returned no recognizable IOS hostname." }
            $oldHostname = $Matches[1]
            $commands = @()
            if ($oldHostname -cne $name) { $commands += "hostname $name" }
            $backup[$name] = [ordered]@{ hostname = $oldHostname; interfaces = @() }
            foreach ($interface in $interfaces[$name]) {
                $oldConfig = Invoke-RecordedCommand $name "show running-config interface $($interface.name)"
                if ($oldConfig -notmatch "(?m)^interface $([regex]::Escape($interface.name))\s*$") { throw "Cannot read $name $($interface.name)." }
                $backup[$name].interfaces += [pscustomobject]@{ name = $interface.name; configuration = $oldConfig }
                if ($oldConfig -match '(?m)^\s*(ip unnumbered|ip vrf forwarding|vrf forwarding)\b') {
                    throw "$name $($interface.name) has an unsupported unnumbered or VRF configuration. Refusing to modify it."
                }
                $addresses = [regex]::Matches($oldConfig, '(?m)^\s*ip address ([^\r\n]+)')
                $desired = "$($interface.address) $($interface.mask)"
                if ($addresses.Count -gt 1 -or ($addresses.Count -eq 1 -and $addresses[0].Groups[1].Value.Trim() -ne $desired)) {
                    throw "$name $($interface.name) already has a different IP configuration. Refusing to overwrite it."
                }
                $shutdown = $oldConfig -match '(?m)^\s*shutdown\s*$'
                if ($addresses.Count -eq 0 -or $shutdown) {
                    $commands += "interface $($interface.name)"
                    if ($addresses.Count -eq 0) { $commands += "ip address $desired" }
                    if ($shutdown) { $commands += 'no shutdown' }
                    $commands += 'exit'
                }
            }
            $pendingCommands[$name] = $commands
        }
        Save-CoreEvidence 'before-ios.json' $backup
        Save-CoreEvidence 'pending-commands.json' $pendingCommands
        foreach ($name in @('R1', 'R2', 'R3', 'R4')) {
            $commands = @($pendingCommands[$name])
            if ($commands.Count -eq 0) { Write-Output "$name already matches the interface configuration."; continue }
            Write-Output "Configuring $name"
            $null = Invoke-RecordedCommand $name 'configure terminal'
            foreach ($command in $commands) { $null = Invoke-RecordedCommand $name $command }
            $null = Invoke-RecordedCommand $name 'end'
            $applied += $name
            Save-CoreEvidence 'applied-routers.json' $applied
        }

        # Interfaces may need a short interval after both ends are enabled.
        $interfacesReady = $false
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            $interfacesReady = $true
            foreach ($name in @('R1', 'R2', 'R3', 'R4')) {
                $brief = Invoke-RecordedCommand $name 'show ip interface brief'
                foreach ($interface in $interfaces[$name]) {
                    $pattern = '(?m)^' + [regex]::Escape($interface.name) + '\s+' + [regex]::Escape($interface.address) + '\s+\S+\s+\S+\s+up\s+up\s*$'
                    if ($brief -notmatch $pattern) { $interfacesReady = $false }
                }
            }
            if ($interfacesReady) { break }
            if ($attempt -lt 10) { Start-Sleep -Seconds 3 }
        }
        if (-not $interfacesReady) { throw 'Not all ten link endpoints reached the expected address and up/up state. Inspect the console transcript.' }

        foreach ($name in @('R1', 'R2', 'R3', 'R4')) {
            foreach ($interface in $interfaces[$name]) {
                # Warm up ARP separately; it is not counted as the measured probe.
                $null = Invoke-RecordedCommand $name "ping $($interface.peer_address) repeat 1 timeout 1"
                $result = Invoke-RecordedCommand $name "ping $($interface.peer_address) repeat 3 timeout 1"
                $passed = $result -match 'Success rate is 100 percent\s*\(3/3\)'
                $pingResults += [pscustomobject]@{ router = $name; interface = $interface.name; destination = $interface.peer_address; passed = $passed; output = $result }
                Save-CoreEvidence 'ping-results.json' $pingResults
                if (-not $passed) { throw "Ping failed: $name to $($interface.peer_address). Startup configurations have not been saved by this run." }
                Write-Output "PASS: $name -> $($interface.peer_address) (3/3)"
            }
        }
        # Persist only after the complete link test passes.
        foreach ($name in @('R1', 'R2', 'R3', 'R4')) {
            $saved = Invoke-RecordedCommand $name 'write memory'
            if ($saved -notmatch '\[OK\]') { throw "$name did not acknowledge saving its configuration." }
        }
        Write-Output 'VERIFIED: ten link endpoints up/up; ten directional ping tests passed; all four configurations saved.'
        Write-Output 'This verifies direct neighbors only. OSPF, EIGRP, VLANs and end-to-end routed paths are not configured yet.'
        if ($env:GITHUB_STEP_SUMMARY) {
            @('## Core interfaces verified', '', '- Ten endpoints: expected addresses and up/up', '- Ten directional neighbor tests: 3/3 replies each', '- Four startup configurations saved', '', 'Direct neighbors only; dynamic routing and VLANs are still pending.') |
                Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding UTF8 -Append
        }
    }
    finally {
        try {
            foreach ($name in @($sessions.Keys)) {
                if ($sessions[$name].Prompt -match '\(') {
                    try { $null = Invoke-RecordedCommand $name 'end' }
                    catch { Write-Warning "Could not return $name to EXEC mode: $($_.Exception.Message)" }
                }
            }
            Save-CoreEvidence 'before-ios.json' $backup
            Save-CoreEvidence 'console-transcript.json' $transcript.ToArray()
        }
        finally {
            foreach ($session in $sessions.Values) {
                try { Close-IosConsole $session }
                catch { Write-Warning "Could not close a console session: $($_.Exception.Message)" }
            }
        }
    }
}
