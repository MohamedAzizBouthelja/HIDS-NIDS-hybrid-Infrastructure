function Record-Command([string] $Node, [string] $Command, [string] $Output) {
    $transcript.Add([pscustomobject]@{ utc = [DateTime]::UtcNow.ToString('o'); node = $Node; command = $Command; output = $Output })
}

function Invoke-Ovs([string] $Node, [string] $Command) {
    try { $output = Send-OvsCommand $sessions[$Node] $Command }
    catch { Record-Command $Node $Command $_.Exception.Message; throw }
    Record-Command $Node $Command $output
    return $output
}

function Invoke-VpcsCommand([string] $Node, [string] $Command, [string] $OutputPattern) {
    $bytes = [Text.Encoding]::ASCII.GetBytes("$Command" + [char]13)
    $session = $sessions[$Node]
    $session.Stream.Write($bytes, 0, $bytes.Length)
    try { $output = Read-IosResponse $session -TimeoutSeconds 12 -Vpcs -VpcsOutputPattern $OutputPattern }
    catch {
        Record-Command $Node $Command $_.Exception.Message
        throw "$Node failed to complete '$Command'. $($_.Exception.Message)"
    }
    Record-Command $Node $Command $output
    return ($output -replace '\r+\n|\r+', "`n")
}

function Assert-ClientAddress([string] $Node, [string] $Address) {
    $output = Invoke-VpcsCommand $Node 'show ip' '(?i)IP/MASK[ \t]*:'
    $expected = '(?im)^[ \t]*IP/MASK[ \t]*:[ \t]*' + [regex]::Escape("$Address/24") + '[ \t]*$'
    if ($output -notmatch $expected) { throw "$Node must use $Address/24. VPCS show ip output: $output" }
}

function Invoke-VpcsPing([string] $Node, [string] $Destination, [int] $Count) {
    $output = Invoke-VpcsCommand $Node "ping $Destination -c $Count" '(?i)icmp_seq=|not reachable|no gateway found|timed? out|timeout|invalid options|unknown command|cannot resolve|unreachable'
    $pattern = '(?im)^\s*\d+ bytes from ' + [regex]::Escape($Destination) + ' icmp_seq=(\d+)\s+ttl=\d+'
    $replies = @([regex]::Matches($output, $pattern) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique).Count
    return @{ replies = $replies; output = $output }
}
