# Minimal Telnet transport for the private GNS3 console network. No credentials.
function ConvertFrom-IosTelnet($Session, [byte[]] $Bytes) {
    $text = [System.Text.StringBuilder]::new()
    foreach ($value in $Bytes) {
        switch ($Session.TelnetState) {
            'data' {
                if ($value -eq 255) { $Session.TelnetState = 'iac' }
                elseif ($value -ne 0) { [void]$text.Append([char]$value) }
            }
            'iac' {
                if ($value -eq 255) { [void]$text.Append([char]255); $Session.TelnetState = 'data' }
                elseif ($value -in @(251, 252, 253, 254)) {
                    $Session.TelnetCommand = $value; $Session.TelnetState = 'option'
                }
                elseif ($value -eq 250) { $Session.TelnetState = 'sub' }
                else { $Session.TelnetState = 'data' }
            }
            'option' {
                # WILL -> DO for echo/suppress-go-ahead, otherwise DONT.
                # DO -> WILL for suppress-go-ahead, otherwise WONT.
                $reply = $null
                if ($Session.TelnetCommand -eq 251) { $reply = if ($value -in @(1, 3)) { 253 } else { 254 } }
                elseif ($Session.TelnetCommand -eq 253) { $reply = if ($value -eq 3) { 251 } else { 252 } }
                if ($null -ne $reply) { $Session.Stream.Write([byte[]]@(255, $reply, $value), 0, 3) }
                $Session.TelnetState = 'data'
            }
            'sub' { if ($value -eq 255) { $Session.TelnetState = 'sub-iac' } }
            'sub-iac' { $Session.TelnetState = if ($value -eq 240) { 'data' } else { 'sub' } }
        }
    }
    return $text.ToString()
}

function Get-IosTerminalState([string] $Text) {
    # Dynamips may replay boot/setup history when a console reconnects.
    # Only the current terminal tail determines whether input is required.
    $withoutLogs = $Text -replace '(?m)^([A-Za-z0-9_.:-]+(?:\([A-Za-z0-9_-]+\))?[#>])?[^\r\n]*%(?:LINK|LINEPROTO|SYS)-\d-[^\r\n]*', '$1'
    $tail = $withoutLogs.TrimEnd()
    if ($tail -match '(?:^|[\r\n])([A-Za-z0-9_.:-]+(?:\([A-Za-z0-9_-]+\))?[#>])$') {
        return [pscustomobject]@{ Kind = 'prompt'; Prompt = $Matches[1]; Detail = '' }
    }
    $lastLine = ($tail -split '[\r\n]')[-1].Trim()
    if ($lastLine -match '(?i)^(Username|Password):$' -or
        $lastLine -match '(?i)(initial configuration dialog|terminate autoinstall).*:\s*$|Press RETURN to get started[!.]?\s*$') {
        return [pscustomobject]@{ Kind = 'challenge'; Prompt = ''; Detail = $lastLine }
    }
    return [pscustomobject]@{ Kind = 'waiting'; Prompt = ''; Detail = $lastLine }
}

function Read-IosResponse($Session, [string] $ExpectedEcho = '', [int] $TimeoutSeconds = 30, [switch] $AllowInitialReturn) {
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $quietTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $buffer = [byte[]]::new(8192)
    $text = [System.Text.StringBuilder]::new()
    $wakeReturns = 0
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($Session.Stream.DataAvailable) {
            $read = $Session.Stream.Read($buffer, 0, $buffer.Length)
            if ($read -eq 0) { throw 'The router console closed its connection.' }
            [void]$text.Append((ConvertFrom-IosTelnet $Session $buffer[0..($read - 1)]))
            $quietTimer.Restart()
            if ($text.Length -gt 2097152) { throw 'Console output exceeded the response limit.' }
        }
        elseif ($Session.Client.Client.Poll(1000, [System.Net.Sockets.SelectMode]::SelectRead) -and $Session.Client.Available -eq 0) {
            throw 'The router console disconnected while waiting for a prompt.'
        }
        $plain = $text.ToString() -replace '\x1b\[[0-9;]*[A-Za-z]', ''
        $terminal = Get-IosTerminalState $plain
        if ($terminal.Kind -eq 'challenge' -and $quietTimer.ElapsedMilliseconds -ge 500) {
            if ($AllowInitialReturn -and -not $ExpectedEcho -and $wakeReturns -lt 2 -and
                $terminal.Detail -match '(?i)^Press RETURN to get started[!.]?$') {
                # The first connection CR can precede IOS readiness. Send only
                # RETURN at this exact prompt; never answer login/setup questions.
                Write-Verbose 'Sending RETURN at the IOS ready prompt.'
                $Session.Stream.Write([byte[]]@(13), 0, 1)
                $wakeReturns++
                [void]$text.Clear()
                $quietTimer.Restart()
                continue
            }
            throw "IOS is currently waiting at '$($terminal.Detail)'. Prepare this console manually; no credentials or setup answers were sent."
        }
        if ($terminal.Kind -eq 'prompt' -and $quietTimer.ElapsedMilliseconds -ge 100 -and
            (-not $ExpectedEcho -or $plain.Contains($ExpectedEcho))) {
            $Session.Prompt = $terminal.Prompt
            return $plain
        }
        Start-Sleep -Milliseconds 25
    }
    throw "Timed out waiting for an IOS prompt after '$ExpectedEcho'. Last output: $($text.ToString())"
}

function Send-IosCommand($Session, [string] $Command, [int] $TimeoutSeconds = 30) {
    if ($Command -notmatch '^[\x20-\x7e]+$') { throw 'An IOS command must be one printable ASCII line.' }
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("$Command`r")
    $Session.Stream.Write($bytes, 0, $bytes.Length)
    $output = Read-IosResponse $Session -ExpectedEcho $Command -TimeoutSeconds $TimeoutSeconds
    if ($output -match '(?im)^\s*%(?!LINK-\d|LINEPROTO-\d|SYS-\d)') {
        throw "IOS rejected '$Command': $output"
    }
    return $output
}

function Open-IosConsole([string] $Address, [int] $Port) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $pending = $client.BeginConnect($Address, $Port, $null, $null)
        try {
            if (-not $pending.AsyncWaitHandle.WaitOne(5000)) { throw "Console connection timed out: ${Address}:$Port" }
            $client.EndConnect($pending)
        }
        finally { $pending.AsyncWaitHandle.Close() }
        $client.NoDelay = $true
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $stream.WriteTimeout = 5000
        $session = [pscustomobject]@{
            Client = $client; Stream = $stream; Prompt = ''
            TelnetState = 'data'; TelnetCommand = 0
        }
        $stream.Write([byte[]]@(13), 0, 1)
        $null = Read-IosResponse $session -AllowInitialReturn
        if ($session.Prompt -match '\(') { throw 'The console is already in configuration mode. Exit to an EXEC prompt first.' }
        if ($session.Prompt.EndsWith('>')) { $null = Send-IosCommand $session 'enable' }
        if (-not $session.Prompt.EndsWith('#')) { throw 'The console is not in privileged EXEC mode.' }
        $null = Send-IosCommand $session 'terminal length 0'
        return $session
    }
    catch { $client.Close(); throw }
}

function Close-IosConsole($Session) {
    if ($null -ne $Session) { $Session.Client.Close() }
}
