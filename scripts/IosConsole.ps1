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
    $withoutLogs = $Text -replace '(?m)^([A-Za-z0-9_.:-]+(?:\([A-Za-z0-9_-]+\))?[#>])?[^\r\n]*%[A-Z][A-Z0-9_]*-[0-7]-[A-Z0-9_]+:[^\r\n]*', '$1'
    $tail = $withoutLogs.TrimEnd()
    if ($tail -match '(?:^|[\r\n])([A-Za-z0-9_.:-]+(?:\([A-Za-z0-9_-]+\))?[#>])$') {
        return [pscustomobject]@{ Kind = 'prompt'; Prompt = $Matches[1]; Detail = '' }
    }
    $lastLine = ($tail -split '[\r\n]')[-1].Trim()
    if ($lastLine -match '\[confirm\]$') {
        return [pscustomobject]@{ Kind = 'confirmation'; Prompt = ''; Detail = $lastLine }
    }
    if ($lastLine -match '(?i)^(Username|Password):$' -or
        $lastLine -match '(?i)(initial configuration dialog|terminate autoinstall).*:\s*$|Press RETURN to get started[!.]?\s*$') {
        return [pscustomobject]@{ Kind = 'challenge'; Prompt = ''; Detail = $lastLine }
    }
    return [pscustomobject]@{ Kind = 'waiting'; Prompt = ''; Detail = $lastLine }
}

function Test-IosCommandEcho([string] $Text, [string] $ExpectedEcho) {
    if (-not $ExpectedEcho -or $Text.Contains($ExpectedEcho)) { return $true }
    if ($Text -notmatch '%[A-Z][A-Z0-9_]*-[0-7]-[A-Z0-9_]+:') { return $false }
    # IOS can insert a syslog anywhere in the echo, even before the remainder
    # of a command on the same line. Keep raw output, but accept its echoed
    # characters in order when a recognized asynchronous log is present.
    $position = 0
    foreach ($character in $Text.ToCharArray()) {
        if ($character -ceq $ExpectedEcho[$position]) {
            $position++
            if ($position -eq $ExpectedEcho.Length) { return $true }
        }
    }
    return $false
}

function Test-IosNvramSaveConfirmation([string] $Text, [string] $ExpectedEcho, [string] $Question) {
    return ($ExpectedEcho -ceq 'write memory' -and
        $Question -match '^Overwrite the previous NVRAM configuration\?\s*\[confirm\]$' -and
        $Text -match '(?i)Warning:\s*Attempting to overwrite an NVRAM configuration previously written\s+by a different version of the system image\.' -and
        (Test-IosCommandEcho $Text $ExpectedEcho))
}

function Read-IosResponse($Session, [string] $ExpectedEcho = '', [int] $TimeoutSeconds = 30, [switch] $AllowInitialReturn, [switch] $Vpcs) {
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $quietTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $buffer = [byte[]]::new(8192)
    $text = [System.Text.StringBuilder]::new()
    $wakeReturns = 0
    $saveConfirmations = 0
    $handledConfirmationOffset = -1
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
        # Terminal private-mode sequences such as ESC[?2004h, window titles,
        # and bells can sit beside a visible VPCS prompt.
        $plain = $text.ToString() -replace '\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x07', ''
        if ($Vpcs) {
            # VPCS can indent its prompt and include terminal framing bytes.
            # Require a complete prompt on the final line before accepting it.
            $vpcsText = $plain -replace '[^\x20-\x7e\r\n\t]', ''
            $vpcsPrompt = [regex]::Match($vpcsText.TrimEnd(), '(?:^|[\r\n])[ \t]*([A-Za-z0-9_.:-]+(?:\[\d+\])?>)\z')
            if ($vpcsPrompt.Success -and $quietTimer.ElapsedMilliseconds -ge 100 -and
                (Test-IosCommandEcho $vpcsText $ExpectedEcho)) {
                $Session.Prompt = $vpcsPrompt.Groups[1].Value
                return $vpcsText
            }
        }
        $terminal = Get-IosTerminalState $plain
        if ($terminal.Kind -eq 'confirmation' -and $quietTimer.ElapsedMilliseconds -ge 500) {
            $offset = $plain.LastIndexOf($terminal.Detail, [System.StringComparison]::Ordinal)
            if ($saveConfirmations -eq 1 -and $offset -eq $handledConfirmationOffset) {
                # IOS can take time to write NVRAM. The old question remains in
                # the buffer while waiting for new data; do not confirm it twice.
            }
            elseif ($saveConfirmations -eq 0 -and $offset -ge 0 -and
                (Test-IosNvramSaveConfirmation $plain $ExpectedEcho $terminal.Detail)) {
                Write-Verbose 'Confirming the NVRAM overwrite requested by write memory.'
                $Session.Stream.Write([byte[]]@(13), 0, 1)
                $saveConfirmations++
                $handledConfirmationOffset = $offset
                $quietTimer.Restart()
                # Preserve the warning and confirmation in the returned transcript.
                continue
            }
            else {
                throw "IOS requested an unsupported or repeated confirmation after '$ExpectedEcho': $($terminal.Detail). No additional confirmation was sent."
            }
        }
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
        if (-not $Vpcs -and $terminal.Kind -eq 'prompt' -and $quietTimer.ElapsedMilliseconds -ge 100 -and
            (Test-IosCommandEcho $plain $ExpectedEcho)) {
            $Session.Prompt = $terminal.Prompt
            return $plain
        }
        Start-Sleep -Milliseconds 25
    }
    if ($Vpcs) {
        $tail = $text.ToString([Math]::Max(0, $text.Length - 256), [Math]::Min(256, $text.Length))
        $escaped = ConvertTo-Json -InputObject $tail -Compress
        $bytes = ($tail.ToCharArray() | ForEach-Object { '{0:X2}' -f [int]$_ }) -join ' '
        throw "Timed out waiting for a VPCS prompt. Console tail: $escaped. Tail bytes: $bytes"
    }
    throw "Timed out waiting for an IOS prompt after '$ExpectedEcho'. Last output: $($text.ToString())"
}

function Send-IosCommand($Session, [string] $Command, [int] $TimeoutSeconds = 30) {
    if ($Command -notmatch '^[\x20-\x7e]+$') { throw 'An IOS command must be one printable ASCII line.' }
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("$Command`r")
    $Session.Stream.Write($bytes, 0, $bytes.Length)
    $output = Read-IosResponse $Session -ExpectedEcho $Command -TimeoutSeconds $TimeoutSeconds
    $errors = [regex]::Matches($output, '(?im)^\s*%(?![A-Z][A-Z0-9_]*-[0-7]-[A-Z0-9_]+:)[^\r\n]*')
    foreach ($errorLine in $errors) {
        # A missing route is a valid show result while OSPF is converging.
        if ($Command -match '^show ip route [0-9.]+$' -and $errorLine.Value.Trim() -match '^% Network not in table\.?$') { continue }
        throw "IOS rejected '$Command': $output"
    }
    return $output
}

function Open-Gns3Telnet([string] $Address, [int] $Port) {
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
        return [pscustomobject]@{
            Client = $client; Stream = $stream; Prompt = ''
            TelnetState = 'data'; TelnetCommand = 0
        }
    }
    catch { $client.Close(); throw }
}

function Open-IosConsole([string] $Address, [int] $Port, [switch] $Vpcs, [switch] $AllowConfigMode) {
    $session = Open-Gns3Telnet $Address $Port
    try {
        $session.Stream.Write([byte[]]@(13), 0, 1)
        $null = Read-IosResponse $session -AllowInitialReturn:(-not $Vpcs) -Vpcs:$Vpcs
        if ($Vpcs) {
            if (-not $session.Prompt.EndsWith('>')) { throw 'Expected a VPCS console prompt.' }
            return $session
        }
        if ($session.Prompt -match '\(') {
            if ($AllowConfigMode) { return $session }
            throw 'The console is already in configuration mode. Exit to an EXEC prompt first.'
        }
        if ($session.Prompt.EndsWith('>')) { $null = Send-IosCommand $session 'enable' }
        if (-not $session.Prompt.EndsWith('#')) { throw 'The console is not in privileged EXEC mode.' }
        $null = Send-IosCommand $session 'terminal length 0'
        return $session
    }
    catch { Close-IosConsole $session; throw }
}

function Close-IosConsole($Session) {
    if ($null -ne $Session) { $Session.Client.Close() }
}
