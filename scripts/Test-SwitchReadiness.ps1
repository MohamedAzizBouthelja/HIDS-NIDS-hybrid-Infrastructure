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
$iosvl2 = @(
    foreach ($template in $templates) {
        if ($template.template_type -ne 'qemu' -or $template.builtin -eq $true) { continue }
        if ($template.name -notmatch '(?i)iosv[ _-]*l2' -and $template.hda_disk_image -notmatch '(?i)iosv[ _-]*l2|vios[ _-]*l2') { continue }

        [pscustomobject]@{
            name = $template.name
            template_id = $template.template_id
            compute_id = $template.compute_id
            adapters = $template.adapters
            disk_referenced = [bool]$template.hda_disk_image
            telnet_console = $template.console_type -eq 'telnet'
        }
    }
)
$eligible = @($iosvl2 | Where-Object {
    $_.compute_id -eq 'vm' -and $_.adapters -ge 4 -and $_.disk_referenced -and $_.telnet_console
})
$result = [ordered]@{
    checked_utc = [DateTime]::UtcNow.ToString('o')
    vm_connected = $vmConnected
    template_count = $templates.Count
    iosvl2_candidates = $iosvl2
    eligible_template_ids = @($eligible | ForEach-Object { $_.template_id })
    ready_for_boot_test = $vmConnected -and $eligible.Count -gt 0
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'readiness.json') -Encoding UTF8

if (-not $vmConnected) { throw 'The GNS3 VM is disconnected. Start it and run the inventory again.' }
if ($eligible.Count -eq 0) {
    throw 'No eligible IOSvL2 template on the GNS3 VM. Import an image approved for this lab with at least four adapters and a Telnet console, then rerun.'
}

$eligible | Format-Table name, template_id, adapters -AutoSize | Out-String | Write-Output
Write-Output 'IOSvL2 inventory passed. Boot the isolated switch pilot to verify the image and port names.'
