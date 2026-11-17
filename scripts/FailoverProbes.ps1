function Start-FailoverProbes($Session, [string] $EvidenceDirectory, [string] $Phase) {
    $state = [hashtable]::Synchronized(@{ stop = $false; baseline_replies = 0; failure = '' })
    $outputPath = Join-Path $EvidenceDirectory "probes-$Phase.jsonl"
    Set-Content -LiteralPath $outputPath -Value '' -NoNewline -Encoding UTF8
    $worker = [PowerShell]::Create()
    try {
        [void]$worker.AddScript({
            param($Session, $State, $OutputPath, $ConsoleScript)
            $ErrorActionPreference = 'Stop'
            . $ConsoleScript
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $command = 'ping 10.255.0.1 source 10.255.0.4 repeat 1 timeout 1'
            for ($sequence = 1; -not $State.stop -and $clock.Elapsed.TotalSeconds -lt 90; $sequence++) {
                $start = [DateTime]::UtcNow
                $tick = $clock.ElapsedMilliseconds
                try {
                    $output = Send-IosCommand $Session $command -TimeoutSeconds 5
                    if ($Session.Prompt -cne 'R4#' -or $output -notmatch '(?m)^[ \t]*(?:R4#)?ping 10\.255\.0\.1 source 10\.255\.0\.4 repeat 1 timeout 1[ \t]*\r?$' -or
                        $output -notmatch 'Success rate is (?:100 percent\s*\(1/1\)|0 percent\s*\(0/1\))') {
                        throw "Unexpected R4 console response: $output"
                    }
                }
                catch {
                    $State.failure = $_.Exception.Message
                    $row = [ordered]@{ sequence = $sequence; command_started_utc = $start.ToString('o'); response_read_utc = [DateTime]::UtcNow.ToString('o'); reply = $null; console_error = $State.failure }
                    Add-Content -LiteralPath $OutputPath -Value ($row | ConvertTo-Json -Compress) -Encoding UTF8
                    return
                }
                $reply = $output -match 'Success rate is 100 percent'
                $row = [ordered]@{ sequence = $sequence; command_started_utc = $start.ToString('o'); response_read_utc = [DateTime]::UtcNow.ToString('o'); reply = $reply; output = $output }
                Add-Content -LiteralPath $OutputPath -Value ($row | ConvertTo-Json -Compress) -Encoding UTF8
                if ($reply) { $State.baseline_replies++ } else { $State.baseline_replies = 0 }
                $delay = 1000 - ($clock.ElapsedMilliseconds - $tick)
                if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
            }
        }).AddArgument($Session).AddArgument($state).AddArgument($outputPath).AddArgument((Join-Path $PSScriptRoot 'IosConsole.ps1'))
        $task = $worker.BeginInvoke()
        $probe = @{ worker = $worker; task = $task; state = $state; output_path = $outputPath; phase = $Phase }
    }
    catch { $worker.Dispose(); throw }
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($state.baseline_replies -lt 3) {
            if ($task.IsCompleted -or $timer.Elapsed.TotalSeconds -ge 12) {
                throw "R4 probe stream did not produce three consecutive replies before $Phase."
            }
            Start-Sleep -Milliseconds 50
        }
    }
    catch { Stop-FailoverProbes $probe; throw }
    return $probe
}

function Stop-FailoverProbes($Probe) {
    $Probe.state.stop = $true
    try {
        $null = $Probe.worker.EndInvoke($Probe.task)
        if ($Probe.state.failure) {
            throw "R4 $($Probe.phase) sampling aborted after a console error. Close other console clients before retrying. $($Probe.state.failure)"
        }
        if ($Probe.worker.HadErrors) { throw ($Probe.worker.Streams.Error[0]) }
    }
    finally { $Probe.worker.Dispose() }
}

function Wait-FailoverProbeWindow($Probe) {
    # An early worker exit ends the window immediately. Stop-FailoverProbes
    # reports its error, and the caller restores the link in finally.
    if ($Probe.task.AsyncWaitHandle.WaitOne(25000) -and -not $Probe.state.failure) {
        throw "R4 $($Probe.phase) sampler finished before the capture window ended."
    }
}

function Get-FailoverProbeSummary([string] $Path, [DateTimeOffset] $EventUtc) {
    $rows = @(Get-Content -LiteralPath $Path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    if (@($rows | Where-Object { $_.console_error }).Count -gt 0) { throw 'Cannot summarize a probe window with a console error.' }
    $before = @($rows | Where-Object { [DateTimeOffset]$_.response_read_utc -lt $EventUtc })
    $after = @($rows | Where-Object { [DateTimeOffset]$_.command_started_utc -ge $EventUtc })
    if ($before.Count -eq 0 -or $after.Count -eq 0) { throw 'Probe samples do not cover both sides of the transition.' }
    $missed = @($after | Where-Object { -not $_.reply })
    $lastMiss = if ($missed.Count -gt 0) { $missed[-1].sequence } else { 0 }
    $stable = @($after | Where-Object { $_.sequence -gt $lastMiss -and $_.reply })
    $stableSeconds = if ($stable.Count -ge 3) { [Math]::Round((([DateTimeOffset]$stable[0].response_read_utc) - $EventUtc).TotalSeconds, 3) } else { $null }
    return [ordered]@{
        samples_before = $before.Count; samples_overlapping_command_start = $rows.Count - $before.Count - $after.Count
        samples_after = $after.Count; replies_after = $after.Count - $missed.Count; timeouts_after = $missed.Count
        first_reply_in_final_streak_seconds = $stableSeconds; final_reply_streak = $stable.Count
    }
}
