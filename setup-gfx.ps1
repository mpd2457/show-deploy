<#
    setup-gfx.ps1
    Run as Administrator on each GFX laptop (Win11).
    Wired IP only. Desktop Ingest + Day 1..Day 5. Share ShowShare points at that folder.
#>
    param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("GFX1", "GFX2", "GFX3")]
    [string]$MachineName,
    [string]$Gateway       = "192.168.50.1",
    [int]   $PrefixLength  = 24,
    [string]$AdapterName   = "",
    [string]$ShareUser     = "show",
    [string]$SharePassword = ""
)
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($SharePassword)) {
    # Prompted for, never baked into this file. Must match what Ingest stores.
    $secureInput = Read-Host "Share password for local account '$ShareUser'" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureInput)
    try {
        $SharePassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ([string]::IsNullOrWhiteSpace($SharePassword)) { throw "Password cannot be empty." }
}
Write-Host "=== $MachineName setup starting ===" -ForegroundColor Cyan
$hostsMap = [ordered]@{
    "INGEST"   = "192.168.50.10"
    "GFX1"     = "192.168.50.11"
    "GFX2"     = "192.168.50.12"
    "GFX3"     = "192.168.50.13"
    "MITTIA"   = "192.168.50.15"
    "MITTIB"   = "192.168.50.16"
}
$StaticIP = $hostsMap[$MachineName]
$ingestDir = "C:\Users\Public\Desktop\Ingest"
$dayNames  = @("Day 1", "Day 2", "Day 3", "Day 4", "Day 5")
$scripts   = "C:\ShowScripts"
$logFile   = Join-Path $scripts "arrival_log.txt"
function Test-WirelessAdapter {
    param($a)
    if ($a.NdisPhysicalMedium -eq "Native802_11") { return $true }
    if ($a.PhysicalMediaType -match "802\.11|Wireless|Wi-Fi|WiFi") { return $true }
    if ($a.InterfaceDescription -match "Wireless|Wi-Fi|WiFi|802\.11") { return $true }
    return $false
}
$needsReboot = $false
if ($env:COMPUTERNAME -ne $MachineName) {
    Write-Host "Renaming machine to $MachineName (requires reboot)..."
    Rename-Computer -NewName $MachineName -Force
    $needsReboot = $true
}
if ([string]::IsNullOrEmpty($AdapterName)) {
    $adapter = Get-NetAdapter -Physical | Where-Object { $_.Status -eq "Up" -and -not (Test-WirelessAdapter $_) } | Select-Object -First 1
    if (-not $adapter) { throw "No connected wired adapter. Plug in Ethernet. Wi-Fi is not used for the show IP." }
} else {
    $adapter = Get-NetAdapter -Name $AdapterName
    if (Test-WirelessAdapter $adapter) { throw "Adapter '$AdapterName' is wireless. Pass the Ethernet adapter name, or leave -AdapterName blank." }
}
Write-Host "Using wired adapter: $($adapter.Name) ($($adapter.InterfaceDescription))"
Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled
Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $StaticIP -PrefixLength $PrefixLength -DefaultGateway $Gateway | Out-Null
Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $Gateway, "8.8.8.8"
Write-Host "Static IP set on wired adapter only: $StaticIP/$PrefixLength via $Gateway"
$hostsPath = "$env:WINDIR\System32\drivers\etc\hosts"
$hostsContent = Get-Content $hostsPath -Raw -ErrorAction SilentlyContinue
if ($null -eq $hostsContent) { $hostsContent = "" }
$hostsContent = $hostsContent -replace "(?ms)# BEGIN SHOWNET.*?# END SHOWNET\r?\n?", ""
$block = "# BEGIN SHOWNET`r`n"
foreach ($name in $hostsMap.Keys) { $block += "$($hostsMap[$name])`t$name`r`n" }
$block += "# END SHOWNET`r`n"
Set-Content -Path $hostsPath -Value ($hostsContent.TrimEnd() + "`r`n`r`n" + $block) -Encoding ASCII
Write-Host "Updated hosts file"
Start-Sleep -Seconds 2
Get-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
Enable-NetFirewallRule -DisplayGroup "File and Printer Sharing" -ErrorAction SilentlyContinue
$securePass = ConvertTo-SecureString $SharePassword -AsPlainText -Force
if (-not (Get-LocalUser -Name $ShareUser -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $ShareUser -Password $securePass -PasswordNeverExpires -AccountNeverExpires -Description "Show rig file-share account" | Out-Null
    Write-Host "Created local account '$ShareUser'"
} else {
    Set-LocalUser -Name $ShareUser -Password $securePass -PasswordNeverExpires $true
    Write-Host "Local account '$ShareUser' already exists - password refreshed"
}
$SharePassword = $null
$securePass = $null
New-Item -Path $scripts -ItemType Directory -Force | Out-Null
New-Item -Path $ingestDir -ItemType Directory -Force | Out-Null
foreach ($day in $dayNames) { New-Item -Path (Join-Path $ingestDir $day) -ItemType Directory -Force | Out-Null }
icacls $ingestDir /grant "${ShareUser}:(OI)(CI)M" /grant "Users:(OI)(CI)M" /T /Q | Out-Null
$existingShare = Get-SmbShare -Name "ShowShare" -ErrorAction SilentlyContinue
if ($existingShare -and $existingShare.Path -ne $ingestDir) {
    Remove-SmbShare -Name "ShowShare" -Force
    $existingShare = $null
    Write-Host "Removed old ShowShare"
}
if (-not $existingShare) {
    New-SmbShare -Name "ShowShare" -Path $ingestDir -FullAccess "Administrators" -ChangeAccess $ShareUser, "Users" | Out-Null
    Write-Host "Created SMB share ShowShare -> $ingestDir"
} else {
    Write-Host "SMB share ShowShare already points at $ingestDir"
}
$watcherPath = Join-Path $scripts "watcher.ps1"
$watcherContent = @"
`$ingestDir = "$ingestDir"
`$logFile   = "$logFile"
`$ignore    = @("arrival_log.txt", "desktop.ini", "Thumbs.db", "queue.json")
`$maxBytes  = 5242880
`$seen = @{}
Get-ChildItem -LiteralPath `$ingestDir -File -Recurse | ForEach-Object { `$seen[`$_.FullName] = `$true }
function Write-Log([string]`$msg) {
    # rotate so the arrival log cannot quietly eat the disk over a long run
    if ((Test-Path `$logFile) -and (Get-Item `$logFile).Length -ge `$maxBytes) {
        Move-Item `$logFile "`$logFile.1" -Force
    }
    Add-Content `$logFile "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - `$msg"
}
Write-Log "Watcher started"
while (`$true) {
    Start-Sleep -Seconds 2
    try { `$files = Get-ChildItem -LiteralPath `$ingestDir -File -Recurse -ErrorAction Stop } catch { continue }
    foreach (`$f in `$files) {
        if (`$seen.ContainsKey(`$f.FullName) -or `$ignore -contains `$f.Name) { continue }
        `$seen[`$f.FullName] = `$true
        Write-Log "New file arrived: `$(`$f.Directory.Name)\`$(`$f.Name) (`$([math]::Round(`$f.Length/1MB,1)) MB)"
    }
    foreach (`$k in @(`$seen.Keys)) { if (-not (Test-Path -LiteralPath `$k)) { `$seen.Remove(`$k) } }
}
"@
Set-Content -Path $watcherPath -Value $watcherContent -Encoding UTF8
$taskName = "ShowWatcher"
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watcherPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Host "=== $MachineName setup complete ===" -ForegroundColor Green
Write-Host "IP: $StaticIP (wired only) | Decks arrive in $ingestDir"
if ($needsReboot) { Write-Host "Machine was renamed - REBOOT before Ingest can reach \\$MachineName." -ForegroundColor Yellow }
if ($Host.Name -eq "ConsoleHost") { Read-Host "Press Enter to close" | Out-Null }
