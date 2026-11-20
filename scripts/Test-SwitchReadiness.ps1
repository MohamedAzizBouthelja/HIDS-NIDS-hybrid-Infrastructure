[CmdletBinding()]
param(
    [string] $ApiBaseUrl = 'http://127.0.0.1:3076',
    [string] $EvidenceDirectory = 'artifacts/switch-readiness'
)

$ErrorActionPreference = 'Stop'
$api = $ApiBaseUrl.TrimEnd('/')
[void](New-Item -ItemType Directory -Force -Path $EvidenceDirectory)

function Read-Gns3Inventory([string] $Path) {
    $response = Invoke-RestMethod -Method Get -Uri "$api$Path" -TimeoutSec 15
    $response | ForEach-Object { $_ }
}

$computes = @(Read-Gns3Inventory '/v2/computes')
$templates = @(Read-Gns3Inventory '/v2/templates')
$vm = @($computes | Where-Object { $_.compute_id -eq 'vm' })
$vmConnected = $vm.Count -eq 1 -and $vm[0].connected -eq $true

# The pilot maps four separate interfaces on SW-A2. A template match is
# inventory evidence. Console boot and switching capability need a live test.
$qemuTemplates = @($templates | Where-Object { $_.template_type -eq 'qemu' -and $_.builtin -ne $true })
$iosvl2 = @(
    foreach ($template in $qemuTemplates) {
        $imagePattern = '(?i)(?:iosv|vios)[ _-]*l2'
        if ($template.name -notmatch $imagePattern -and $template.hda_disk_image -notmatch $imagePattern) { continue }
        $issues = @(
            if ($template.compute_id -ne 'vm') { "Compute is '$($template.compute_id)'. Select the GNS3 VM." }
            if ($template.adapters -lt 4) { "$($template.adapters) adapter(s) reported. Set at least four." }
            if ([string]::IsNullOrWhiteSpace($template.hda_disk_image)) { 'Attach the IOSvL2 boot disk as HDA.' }
            if ($template.console_type -ne 'telnet') { "Console is '$($template.console_type)'. Select Telnet." }
        )

        [pscustomobject]@{
            name = $template.name
            template_id = $template.template_id
            compute_id = $template.compute_id
            adapters = $template.adapters
            disk_referenced = -not [string]::IsNullOrWhiteSpace($template.hda_disk_image)
            telnet_console = $template.console_type -eq 'telnet'
            issues = $issues
        }
    }
)
$eligible = @($iosvl2 | Where-Object { $_.issues.Count -eq 0 })
$result = [ordered]@{
    checked_utc = [DateTime]::UtcNow.ToString('o')
    vm_connected = $vmConnected
    template_count = $templates.Count
    qemu_template_names = @($qemuTemplates | ForEach-Object { $_.name })
    iosvl2_candidates = $iosvl2
    eligible_template_ids = @($eligible | ForEach-Object { $_.template_id })
    ready_for_boot_test = $vmConnected -and $eligible.Count -gt 0
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'readiness.json') -Encoding UTF8

if (-not $vmConnected) { throw 'The GNS3 VM is disconnected. Start it and run the inventory again.' }
if ($iosvl2.Count -eq 0) {
    $names = if ($qemuTemplates.Count) { $result.qemu_template_names -join ', ' } else { '(none)' }
    Write-Output "QEMU templates seen by this controller: $names"
    throw 'The controller has no recognized IOSvL2 QEMU template. Complete the appliance import on this controller and rerun. See docs/switching-pilot.md.'
}
if ($eligible.Count -eq 0) {
    foreach ($candidate in $iosvl2) {
        Write-Warning ("{0} ({1}) - {2}" -f $candidate.name, $candidate.template_id, ($candidate.issues -join ' '))
    }
    throw 'IOSvL2 is registered, but no candidate passes readiness. Correct the settings listed above and rerun.'
}

$eligible | Format-Table name, template_id, adapters -AutoSize | Out-String | Write-Output
Write-Output 'IOSvL2 inventory passed. Boot the isolated switch pilot to verify the image and port names.'
