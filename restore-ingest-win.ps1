<#
    restore-ingest-win.ps1
    Undo setup-ingest-win.ps1 on the Windows fallback laptop.

        powershell -ExecutionPolicy Bypass -File .\restore-ingest-win.ps1
        powershell -ExecutionPolicy Bypass -File .\restore-ingest-win.ps1 -Purge

    Stops and removes the scheduled task, deletes stored SMB passwords and the
    queue, restores the wired adapter to the addressing it had before, and
    cleans the hosts file. Wi-Fi is never touched. No reboot.
#>
param(
    [switch]$Purge
)

$ErrorActionPreference = "Stop"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Run this as Administrator." -ForegroundColor Red
    exit 1
}

$ConfigDir   = Join-Path $env:LOCALAPPDATA "showkit"
$WatcherPath = Join-Path $ConfigDir "show-watcher.ps1"
$CredsGfx    = Join-Path $ConfigDir "smbcreds"
$CredsMitti  = Join-Path $ConfigDir "smbcreds-mitti"
$BeforeFile  = Join-Path $ConfigDir "network-before.json"
$TaskName    = "ShowIngestWatcher"
$DropDir     = Join-Path $env:USERPROFILE "Desktop\Ingest"
$ArchiveDir  = Join-Path $env:USERPROFILE "Desktop\Archive"

Write-Host "=== INGEST restore starting ===" -ForegroundColor Cyan

# 1. scheduled task
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'"
} else {
    Write-Host "Scheduled task '$TaskName' not present"
}

# 2. credentials and queue
foreach ($f in @($CredsGfx, $CredsMitti, (Join-Path $ConfigDir "queue.json"))) {
    if (Test-Path $f) { Remove-Item $f -Force }
}
Write-Host "Removed stored SMB credentials and push queue"

# 3. network back to whatever it was
if (Test-Path $BeforeFile) {
    $before = Get-Content $BeforeFile -Raw | ConvertFrom-Json
    $ifGuid = $before.InterfaceGuid
    $ifIndex = (Get-NetAdapter | Where-Object { $_.InterfaceGuid -eq $ifGuid }).ifIndex
    if ($ifIndex) {
        Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        if ($before.DhcpEnabled -eq 1) {
            Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -Dhcp Enabled
            Enable-NetAdapter -InterfaceIndex $ifIndex -Confirm:$false | Out-Null
            Write-Host "Adapter '$($before.AdapterName)' back on DHCP"
        } else {
            New-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 `
                -IPAddress $before.IPAddress[0] -PrefixLength ([int]($before.SubnetMask[0] -replace '^255\.255\.255\.', '24')) `
                -DefaultGateway $before.DefaultGateway[0] | Out-Null
            Write-Host "Adapter '$($before.AdapterName)' restored to $($before.IPAddress[0])"
        }
        if ($before.DnsServers.Count -gt 0) {
            Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $before.DnsServers
        }
    }
    Remove-Item $BeforeFile -Force
    Write-Host "Restored wired adapter addressing"
} else {
    Write-Host "No saved network state - check the wired adapter by hand."
}

# 4. hosts file
$hostsPath = "$env:WINDIR\System32\drivers\etc\hosts"
$hostsContent = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
if ($hostsContent -match "# BEGIN SHOWNET") {
    $hostsContent = $hostsContent -replace "(?ms)# BEGIN SHOWNET.*?# END SHOWNET\r?\n?", ""
    $hostsContent = $hostsContent -replace "(\r?\n){3,}$", "`r`n"
    Set-Content -Path $hostsPath -Value $hostsContent.TrimEnd() -Encoding ASCII -NoNewline
    Write-Host "Removed SHOWNET entries from the hosts file"
} else {
    Write-Host "Hosts file already clean"
}

# 5. show folders
if ($Purge) {
    foreach ($d in @($DropDir, $ArchiveDir)) {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    }
    Write-Host "Deleted $DropDir and $ArchiveDir"
} else {
    foreach ($d in @($DropDir, $ArchiveDir)) {
        if (Test-Path $d) {
            $n = @(Get-ChildItem -LiteralPath $d -File -Recurse -ErrorAction SilentlyContinue).Count
            Write-Host "Kept $d ($n files) - re-run with -Purge to delete"
        }
    }
}

if (Test-Path $WatcherPath) { Remove-Item $WatcherPath -Force }
if ((Test-Path $ConfigDir) -and @(Get-ChildItem $ConfigDir -Force).Count -eq 0) {
    Remove-Item $ConfigDir -Force
}

Write-Host "=== Restore complete - this laptop is back to its normal config. No reboot needed. ===" -ForegroundColor Green
if ($Host.Name -eq "ConsoleHost") { Read-Host "Press Enter to close" | Out-Null }
