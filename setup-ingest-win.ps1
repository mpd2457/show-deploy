<#
    setup-ingest-win.ps1
    Fallback Ingest for when mkultra2 is not available: a Windows 11 Pro work
    laptop. Takes over the 192.168.50.10 role and pushes to GFX1-3 and the
    Mitti Macs exactly like the Linux Ingest does.

    Differences from the Linux box, all deliberate:
      * the drop folder is the user's own Desktop\Ingest, not Public
      * the SMB share is consumed, not served - nothing is shared back
      * setup is per-user, the task runs as that user

    Run as Administrator from the show-deploy folder:
        powershell -ExecutionPolicy Bypass -File .\setup-ingest-win.ps1
#>
param(
    [string]$Gateway      = "192.168.50.1",
    [int]   $PrefixLength = 24,
    [string]$AdapterName  = "",
    [string]$ShareUser    = "show",
    [string]$SharePassword = "",
    [string]$MacUser      = "",
    [string]$MacPassword  = ""
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Run this as Administrator." -ForegroundColor Red
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WatcherSrc = Join-Path $ScriptDir "show-watcher.ps1"
if (-not (Test-Path $WatcherSrc)) {
    throw "Cannot find show-watcher.ps1 next to this script. Copy the whole show-deploy folder."
}

$StaticIp = "192.168.50.10"
$HostsMap = [ordered]@{
    "INGEST" = $StaticIp
    "GFX1"   = "192.168.50.11"
    "GFX2"   = "192.168.50.12"
    "GFX3"   = "192.168.50.13"
    "MITTIA" = "192.168.50.15"
    "MITTIB" = "192.168.50.16"
}

$ScriptsDir  = Join-Path $env:LOCALAPPDATA "showkit"
$ConfigDir   = $ScriptsDir
$CredsGfx    = Join-Path $ConfigDir "smbcreds"
$CredsMitti  = Join-Path $ConfigDir "smbcreds-mitti"
$WatcherPath = Join-Path $ScriptsDir "show-watcher.ps1"
$DropDir     = Join-Path $env:USERPROFILE "Desktop\Ingest"
$ArchiveDir  = Join-Path $env:USERPROFILE "Desktop\Archive"
$TaskName    = "ShowIngestWatcher"
$DayNames    = @("Day 1", "Day 2", "Day 3", "Day 4", "Day 5")

Write-Host "=== INGEST (Windows fallback) setup starting ===" -ForegroundColor Cyan

# ------------------------------------------------------------------ credentials
function Read-Secret([string]$Prompt) {
    $s = Read-Host $Prompt -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# Default offered so load-in is not an invented password per machine. Enter
# accepts it; type to override.
$DefaultSharePassword = "showrig"
if ([string]::IsNullOrWhiteSpace($SharePassword)) {
    Write-Host "GFX share password for local account '$ShareUser' (Enter = $DefaultSharePassword):" -NoNewline
    $SharePassword = Read-Secret " "
}
if ([string]::IsNullOrWhiteSpace($SharePassword)) { $SharePassword = $DefaultSharePassword }

Write-Host ""
$useMacs = Read-Host "Push media to Mitti Macs this show? (y/N)"
if ($useMacs -match '^[Yy]') {
    if ([string]::IsNullOrWhiteSpace($MacUser)) {
        $MacUser = Read-Host "Mac login name"
    }
    if ([string]::IsNullOrWhiteSpace($MacPassword)) {
        Write-Host "Mac login password for '$MacUser' (Enter = $DefaultSharePassword):" -NoNewline
        $MacPassword = Read-Secret " "
    }
    if ([string]::IsNullOrWhiteSpace($MacPassword)) { $MacPassword = $DefaultSharePassword }
    Write-Host "Mac credentials will be stored for '$MacUser'."
}
Write-Host ""

# -------------------------------------------------------------------- adapter
function Test-WirelessAdapter($a) {
    if ($a.NdisPhysicalMedium -eq "Native802_11") { return $true }
    if ($a.PhysicalMediaType -match "802\.11|Wireless|Wi-Fi|WiFi") { return $true }
    if ($a.InterfaceDescription -match "Wireless|Wi-Fi|WiFi|802\.11") { return $true }
    return $false
}

if ([string]::IsNullOrEmpty($AdapterName)) {
    $adapter = Get-NetAdapter -Physical |
        Where-Object { $_.Status -eq "Up" -and -not (Test-WirelessAdapter $_) } |
        Select-Object -First 1
    if (-not $adapter) {
        throw "No connected wired adapter. Plug in Ethernet. Wi-Fi is never used for the show IP."
    }
} else {
    $adapter = Get-NetAdapter -Name $AdapterName
    if (Test-WirelessAdapter $adapter) { throw "Adapter '$AdapterName' is wireless." }
}
Write-Host "Using wired adapter: $($adapter.Name) ($($adapter.InterfaceDescription))"

# ------------------------------------------------------------------ static IP
# Remember what was there so restore-ingest-win.ps1 can put it back.
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($adapter.InterfaceGuid)"
$before = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
[ordered]@{
    InterfaceGuid = $adapter.InterfaceGuid
    AdapterName   = $adapter.Name
    DhcpEnabled   = $before.DhcpEnabled
    IpAddress     = @($before.IPAddress)
    SubnetMask    = @($before.SubnetMask)
    DefaultGateway= @($before.DefaultGateway)
    DnsServers    = @($before.NameServer)
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ConfigDir "network-before.json") -Encoding UTF8

Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled
Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $StaticIp `
    -PrefixLength $PrefixLength -DefaultGateway $Gateway | Out-Null
Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $Gateway, "8.8.8.8"
Write-Host "Static IP set on wired adapter only: $StaticIp/$PrefixLength via $Gateway"

# -------------------------------------------------------------------- hostnames
$hostsPath = "$env:WINDIR\System32\drivers\etc\hosts"
$hostsContent = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
if ($null -eq $hostsContent) { $hostsContent = "" }
$hostsContent = $hostsContent -replace "(?ms)# BEGIN SHOWNET.*?# END SHOWNET\r?\n?", ""
$block = "# BEGIN SHOWNET`r`n"
foreach ($name in $HostsMap.Keys) { $block += "$($HostsMap[$name])`t$name`r`n" }
$block += "# END SHOWNET`r`n"
Set-Content -Path $hostsPath -Value ($hostsContent.TrimEnd() + "`r`n`r`n" + $block) -Encoding ASCII
Write-Host "Updated hosts file"

Start-Sleep -Seconds 2
Get-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue |
    Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue

# --------------------------------------------------------------------- folders
foreach ($d in @($ScriptsDir, $ConfigDir, $DropDir, $ArchiveDir)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}
foreach ($day in $DayNames) { New-Item -ItemType Directory -Path (Join-Path $DropDir $day) -Force | Out-Null }

# credentials, in the same smbclient -A format the Linux watcher writes
$credBody = "username=$ShareUser`npassword=$SharePassword`n"
Set-Content -LiteralPath $CredsGfx -Value $credBody -Encoding ASCII -NoNewline
icacls $CredsGfx /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
if (-not [string]::IsNullOrWhiteSpace($MacUser)) {
    Set-Content -LiteralPath $CredsMitti -Value "username=$MacUser`npassword=$MacPassword`n" -Encoding ASCII -NoNewline
    icacls $CredsMitti /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
} else {
    Remove-Item $CredsMitti -Force -ErrorAction SilentlyContinue
    Write-Host "No Mac credentials stored - media pushes will FAIL if Mitti machines are used."
}
$SharePassword = $null
$MacPassword = $null

# --------------------------------------------------------------------- watcher
Install-Item -Path $WatcherSrc -Destination $WatcherPath -Force
Write-Host "Installed watcher to $WatcherPath"

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WatcherPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host "Registered and started scheduled task '$TaskName'"

Write-Host "=== INGEST (Windows fallback) setup complete ===" -ForegroundColor Green
Write-Host "Drop files in:  $DropDir"
Write-Host "Archive:        $ArchiveDir"
Write-Host "Log:            $(Join-Path $DropDir 'push_log.txt')"
Write-Host "Day folders:    Day 1 - Day 5"
Write-Host "Check it:       Get-ScheduledTask -TaskName $TaskName"
if ($Host.Name -eq "ConsoleHost") { Read-Host "Press Enter to close" | Out-Null }
