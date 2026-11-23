function Start-FailoverHttp($Node, [string] $EvidenceDirectory) {
    $rows = Join-Path $EvidenceDirectory 'http-probes.jsonl'
    Set-Content -LiteralPath $rows -Value '' -NoNewline -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'http-checkpoints.jsonl') -Value '' -NoNewline -Encoding UTF8
    $state = [hashtable]::Synchronized(@{ stop = $false; lastGoodStart = [DateTime]::MinValue; failure = '' })
    # Transport one multiline Python program through the interactive Telnet shell.
    $python = @"
from http.client import HTTPConnection, HTTPException
import json

connection = HTTPConnection('192.168.20.12', 8080, timeout=2, source_address=('192.168.10.12', 0))
try:
    connection.request('GET', '/health')
    response = connection.getresponse()
    body = response.read(4096)
    healthy = response.status == 200 and json.loads(body) == {'status': 'ok', 'service': 'API-A'}
    print(json.dumps({'healthy': healthy, 'status': response.status}))
except (OSError, ValueError, EOFError, HTTPException) as error:
    print(json.dumps({'healthy': False, 'error': str(error)}))
finally:
    connection.close()
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($python))
    $command = "python3 -c `"import base64;exec(base64.b64decode('$encoded'))`""
    $worker = [PowerShell]::Create()
    try {
        [void]$worker.AddScript({
            param($Node, $State, $Rows, $Command, $Scripts)
            $ErrorActionPreference = 'Stop'
            . (Join-Path $Scripts 'IosConsole.ps1')
            . (Join-Path $Scripts 'OvsConsole.ps1')
            $session = $null
            try {
                $session = Open-Gns3Telnet $Node.console_host $Node.console
                $prompt = '^[^\n]*[#$][ \t]*$'
                $session.Stream.Write([byte[]]@(13), 0, 1)
                $null = Read-OvsConsole $session "(?m)$prompt"
                $session | Add-Member -NotePropertyName OvsPrompt -NotePropertyValue $prompt
                while (-not $State.stop) {
                    $started = [DateTime]::UtcNow
                    $sample = (Send-OvsCommand $session $Command) | ConvertFrom-Json
                    $row = [ordered]@{
                        started_utc = $started.ToString('o'); finished_utc = [DateTime]::UtcNow.ToString('o')
                        source = '192.168.10.12'; healthy = $sample.healthy; status = $sample.status; error = $sample.error
                    }
                    Add-Content -LiteralPath $Rows -Value ($row | ConvertTo-Json -Compress) -Encoding UTF8
                    if ($sample.healthy) { $State.lastGoodStart = $started }
                    Start-Sleep -Milliseconds 500
                }
            }
            catch { $State.failure = $_.Exception.Message }
            finally { if ($session) { Close-IosConsole $session } }
        }).AddArgument($Node).AddArgument($state).AddArgument($rows).AddArgument($command).AddArgument($PSScriptRoot)
        return @{ worker = $worker; task = $worker.BeginInvoke(); state = $state; evidence = $EvidenceDirectory }
    }
    catch { $worker.Dispose(); throw }
}

function Wait-FailoverHttp($Probe, [string] $Phase) {
    $since = [DateTime]::UtcNow
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($Probe.state.lastGoodStart -lt $since) {
        if ($Probe.task.IsCompleted -or $timer.Elapsed.TotalSeconds -ge 20) {
            throw "No fresh healthy HTTP-CLIENT response during $Phase. Inspect http-probes.jsonl. $($Probe.state.failure)"
        }
        Start-Sleep -Milliseconds 100
    }
    $checkpoint = @{ phase = $Phase; healthy_probe_started_utc = $Probe.state.lastGoodStart.ToString('o') }
    Add-Content -LiteralPath (Join-Path $Probe.evidence 'http-checkpoints.jsonl') -Value ($checkpoint | ConvertTo-Json -Compress) -Encoding UTF8
}

function Stop-FailoverHttp($Probe) {
    $Probe.state.stop = $true
    try {
        $null = $Probe.worker.EndInvoke($Probe.task)
        if ($Probe.state.failure) { throw $Probe.state.failure }
        if ($Probe.worker.HadErrors) { throw $Probe.worker.Streams.Error[0] }
    }
    finally { $Probe.worker.Dispose() }
}
