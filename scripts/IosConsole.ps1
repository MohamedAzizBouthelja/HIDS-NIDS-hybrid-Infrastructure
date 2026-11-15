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

function Read-IosResponse($Session, [string] $ExpectedEcho = '', [int] $TimeoutSeconds = 30) {
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $buffer = [byte[]]::new(8192)
    $text = [System.Text.StringBuilder]::new()
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($Session.Stream.DataAvailable) {
            $read = $Session.Stream.Read($buffer, 0, $buffer.Length)
            if ($read -eq 0) { throw 'The router console closed its connection.' }
            [void]$text.Append((ConvertFrom-IosTelnet $Session $buffer[0..($read - 1)]))
            if ($text.Length -gt 2097152) { throw 'Console output exceeded the response limit.' }
            $plain = $text.ToString() -replace '\x1b\[[0-9;]*[A-Za-z]', ''
            if ($plain -match '(?im)(?:^|[\r\n])\s*(Username|Password):' -or
                $plain -match '(?i)initial configuration dialog|terminate autoinstall|Press RETURN to get started') {
                throw 'IOS is asking for authentication or initial setup. Prepare this console manually; no credentials or setup answers were sent.'
            }
            $prompts = [regex]::Matches($plain, '(?m)(?:^|[\r\n])([A-Za-z0-9_.:-]+(?:\([A-Za-z0-9_-]+\))?[#>])[ \t]*(?=$|[\r\n])')
            if ($prompts.Count -gt 0 -and (-not $ExpectedEcho -or $plain.Contains($ExpectedEcho))) {
                $Session.Prompt = $prompts[$prompts.Count - 1].Groups[1].Value
                return $plain
            }
        }
        elseif ($Session.Client.Client.Poll(1000, [System.Net.Sockets.SelectMode]::SelectRead) -and $Session.Client.Available -eq 0) {
            throw 'The router console disconnected while waiting for a prompt.'
        }
        else { Start-Sleep -Milliseconds 25 }
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
        $null = Read-IosResponse $session
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
