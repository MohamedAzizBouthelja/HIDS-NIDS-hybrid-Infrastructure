# Reuses the GNS3 Telnet connection and decoder from IosConsole.ps1.
function Read-OvsConsole($Session, [string] $Pattern) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $buffer = [byte[]]::new(4096)
    $text = [Text.StringBuilder]::new()
    while ($clock.Elapsed.TotalSeconds -lt 12) {
        if ($Session.Stream.DataAvailable) {
            $count = $Session.Stream.Read($buffer, 0, $buffer.Length)
            if ($count -eq 0) { throw 'OVS console disconnected.' }
            [void]$text.Append((ConvertFrom-IosTelnet $Session $buffer[0..($count - 1)]))
            if ($text.Length -gt 65536) { throw 'OVS console response exceeded 64 KiB.' }
            $clean = $text.ToString() -replace '\x1b\[[0-?]*[ -/]*[@-~]', ''
            $match = [regex]::Match($clean, $Pattern)
            if ($match.Success) { return $match }
        }
        elseif ($Session.Client.Client.Poll(1000, [Net.Sockets.SelectMode]::SelectRead) -and $Session.Client.Available -eq 0) {
            throw 'OVS console disconnected.'
        }
        Start-Sleep -Milliseconds 25
    }
    throw "Timed out waiting for the OVS console. Last output: $text"
}

function Open-OvsConsole([string] $Address, [int] $Port, [string] $NodeName) {
    $session = Open-Gns3Telnet $Address $Port
    try {
        $session.Stream.Write([byte[]]@(13), 0, 1)
        $prompt = '(?m)^' + [regex]::Escape($NodeName) + ':/#[ \t]*\r?$'
        $null = Read-OvsConsole $session $prompt
        $session | Add-Member -NotePropertyName OvsPrompt -NotePropertyValue $prompt
        return $session
    }
    catch { Close-IosConsole $session; throw }
}

function Send-OvsCommand($Session, [string] $Command) {
    $id = [guid]::NewGuid().ToString('N')
    $start = "OVS_BEGIN_$id"
    $end = "OVS_END_$id"
    # The markers must appear on their own lines, so a terminal echo
    # cannot be mistaken for the actual command result.
    $line = 'echo {0}; {1}; rc=$?; echo; echo {2}:$rc' -f $start, $Command, $end
    $bytes = [Text.Encoding]::ASCII.GetBytes("$line" + [char]13)
    $Session.Stream.Write($bytes, 0, $bytes.Length)
    $pattern = "(?m)^$start\r?\n(?s:(?<output>.*?))^$end" + ':(?<status>\d+)\r?\n' + $Session.OvsPrompt.Substring(4)
    $reply = Read-OvsConsole $Session $pattern
    $output = $reply.Groups['output'].Value.Trim()
    if ($reply.Groups['status'].Value -ne '0') { throw "OVS command failed ($Command): $output" }
    return $output
}
