<#
    show-watcher.ps1
    Ingest-side push watcher for the Windows fallback laptop.

    Same rules as show-watcher.py on Linux:
      * only push a file once its size AND mtime have stopped changing and no
        process holds it open, so a half-copied deck never lands
      * verify the size the far end reports after every push
      * retry failures with backoff
      * the queue lives in %LOCALAPPDATA%\showkit\queue.json so failures survive
        a reboot
      * pushes to different machines overlap

    Run by setup-ingest-win.ps1 via a scheduled task at logon.
#>

$ErrorActionPreference = "Stop"
Import-Module ThreadJob -ErrorAction Stop

# Paths default to the per-user locations set up by setup-ingest-win.ps1. The
# environment overrides exist so the offline test harness can point the watcher
# at a throwaway tree.
$ConfigDir  = Join-Path $env:LOCALAPPDATA "showkit"
$QueueFile  = Join-Path $ConfigDir "queue.json"
$DropDir    = Join-Path $env:USERPROFILE "Desktop\Ingest"
$ArchiveDir = Join-Path $env:USERPROFILE "Desktop\Archive"
$LogFile    = Join-Path $DropDir "push_log.txt"
$CredsGfx   = Join-Path $ConfigDir "smbcreds"
$CredsMitti = Join-Path $ConfigDir "smbcreds-mitti"

if ($env:SHOWKIT_DROP)    { $DropDir    = $env:SHOWKIT_DROP }
if ($env:SHOWKIT_ARCHIVE) { $ArchiveDir = $env:SHOWKIT_ARCHIVE }
if ($env:SHOWKIT_CONFIG)  {
    $ConfigDir  = $env:SHOWKIT_CONFIG
    $QueueFile  = Join-Path $ConfigDir "queue.json"
    $CredsGfx   = Join-Path $ConfigDir "smbcreds"
    $CredsMitti = Join-Path $ConfigDir "smbcreds-mitti"
    $LogFile    = Join-Path $DropDir "push_log.txt"
}

$PollSeconds    = 2
$SettlePolls    = 3
$MaxAttempts    = 8
$Backoff        = @(0, 5, 15, 45, 120, 300, 600, 900)
$MaxSkips       = 10
$SkipRetry      = 60
$LogRotateBytes = 5MB
$LogKeep        = 3

$GfxTargets   = @("GFX1", "GFX2", "GFX3")
$MattiTargets = @("MITTIA", "MITTIB")
$DeckExt   = @(".pptx", ".ppt", ".key", ".pdf")
$MediaExt  = @(".mp4", ".mov", ".mxf", ".avi", ".mkv", ".wav", ".mp3", ".aac", ".m4a")
$Ignore    = @("push_log.txt", "queue.json", "Thumbs.db", "desktop.ini", ".directory")

# ------------------------------------------------------------------- utilities

function Write-Log([string]$Message) {
    $line = "{0} - {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    $dir = Split-Path -Parent $LogFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -ge $LogRotateBytes) {
            for ($i = $LogKeep; $i -ge 1; $i--) {
                $src = if ($i -eq 1) { "$LogFile.1" } else { "$LogFile.$i" }
                if (Test-Path $src) {
                    if ($i -eq $LogKeep) { Remove-Item $src -Force }
                    else { Move-Item $src "$LogFile.$($i + 1)" -Force }
                }
            }
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {
        Write-Host "LOG WRITE FAILED: $_"
    }
}

function Test-Reachable([string]$Host_) {
    # Same single-ping probe the Linux watcher uses, so both agree on what
    # counts as "machine is here". Windows and Linux ping take different flags.
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        & ping -n 1 -w 1000 $Host_ *> $null
    } else {
        & ping -c 1 -W 1 $Host_ *> $null
    }
    return ($LASTEXITCODE -eq 0)
}

function Test-SmbShare([string]$Host_, [string]$CredsFile) {
    # A machine can answer a ping and still have its share asleep or its SMB
    # service stopped. Probing with a directory listing tells the two apart, so
    # an unreachable share is reported as FAIL (password/share, per the README)
    # rather than SKIP (machine not here).
    & smbclient "\\$Host_\ShowShare" -A $CredsFile -m SMB3 -c ls *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-CredsFor([string]$Host_) {
    if ($MattiTargets -contains $Host_) {
        $c = Read-Creds $CredsMitti
        if ($c) { return $c }
    }
    return (Read-Creds $CredsGfx)
}

function Remove-EntryProp($Entry, [string]$Name) {
    if ($null -ne $Entry -and $Entry.PSObject.Properties.Name -contains $Name) {
        $Entry.PSObject.Properties.Remove($Name)
    }
}

# ---------------------------------------------------------------------- queue

function Read-Queue {
    if (-not (Test-Path $QueueFile)) { return [ordered]@{} }
    try {
        $raw = Get-Content -LiteralPath $QueueFile -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return [ordered]@{} }
        $obj = $raw | ConvertFrom-Json
        $h = [ordered]@{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    } catch {
        Write-Log "QUEUE READ FAILED (starting empty): $_"
        return [ordered]@{}
    }
}

function Save-Queue($Queue) {
    try {
        if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        $tmp = "$QueueFile.tmp"
        $Queue | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $QueueFile -Force
    } catch {
        Write-Log "QUEUE WRITE FAILED: $_"
    }
}

function Get-EntryProp($Entry, [string]$Name) {
    if ($null -eq $Entry) { return $null }
    if ($Entry.PSObject.Properties.Name -contains $Name) { return $Entry.$Name }
    return $null
}

function Set-EntryProp($Entry, [string]$Name, $Value) {
    if ($Entry.PSObject.Properties.Name -contains $Name) {
        $Entry.$Name = $Value
    } else {
        $Entry | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-MapValue($Map, [string]$Key, $Default) {
    if ($null -eq $Map) { return $Default }
    if ($Map.PSObject.Properties.Name -contains $Key) { return $Map.$Key }
    return $Default
}

function Set-MapValue($Entry, [string]$MapName, [string]$Key, $Value) {
    $map = Get-EntryProp $Entry $MapName
    if ($null -eq $map) {
        $map = [pscustomobject]@{}
        Set-EntryProp $Entry $MapName $map
    }
    if ($map.PSObject.Properties.Name -contains $Key) { $map.$Key = $Value }
    else { $map | Add-Member -NotePropertyName $Key -NotePropertyValue $Value }
}

function Remove-MapKey($Entry, [string]$MapName, [string]$Key) {
    $map = Get-EntryProp $Entry $MapName
    if ($null -eq $map) { return }
    if ($map.PSObject.Properties.Name -contains $Key) {
        $map.PSObject.Properties.Remove($Key)
    }
}

# --------------------------------------------------------------- classification

function Get-Label([string]$Path) {
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($DeckExt -contains $ext) { return "DECK" }
    if ($MediaExt -contains $ext) { return "MEDIA" }
    return "UNKNOWN EXT $ext -> ALL"
}

function Get-Targets([string]$Label) {
    switch ($Label) {
        "DECK"  { return $GfxTargets }
        "MEDIA" { return $MattiTargets }
        default { return @($GfxTargets + $MattiTargets) }
    }
}

# ---------------------------------------------------------------------- worker

function Invoke-Push($Path, $Entry, $Queue) {
    $name = $Path.Name
    $expected = [int64]$Entry.size
    $label = $Entry.label
    $targetList = @(Get-Targets $label)

    if (-not (Get-EntryProp $Entry "archived")) {
        Set-EntryProp $Entry "archived" $true
        try {
            if (-not (Test-Path $ArchiveDir)) { New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null }
            Copy-Item -LiteralPath $Path.FullName -Destination (Join-Path $ArchiveDir $name) -Force
        } catch {
            Write-Log "ARCHIVE FAILED : $name : $_"
        }
    }

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $work = @()
    foreach ($h in $targetList) {
        $delivered = Get-MapValue (Get-EntryProp $Entry "delivered") $h $false
        $givenUp = (Get-MapValue (Get-EntryProp $Entry "given_up") $h $null) -ne $null
        $next = [double](Get-MapValue (Get-EntryProp $Entry "next_try") $h 0)
        if (-not $delivered -and -not $givenUp -and $now -ge $next) { $work += $h }
    }
    if ($work.Count -eq 0) { return }

    # Each host is independent: failures must not stop the other machines, and
    # a large file on one host must not delay the rest.
    # Thread jobs run in their own runspace, so everything they need is passed
    # in or defined inline. Nothing from the parent scope is visible here.
    $credsGfxJob   = $CredsGfx
    $credsMittiJob = $CredsMitti

    $jobs = @()
    foreach ($h in $work) {
        $jobs += Start-ThreadJob -ScriptBlock {
            param($Path, $h, $expected, $credsGfxJob, $credsMittiJob)
            $ok = $null
            $detail = ""
            try {
                # inline copy of Test-Reachable: thread jobs cannot see it
                if ($IsWindows -or $env:OS -eq "Windows_NT") {
                    & ping -n 1 -w 1000 $h *> $null
                } else {
                    & ping -c 1 -W 1 $h *> $null
                }
                if ($LASTEXITCODE -ne 0) {
                    return @{ Host = $h; Ok = $null; Detail = "" }
                }
                $credsFile = if ($h -in @("MITTIA", "MITTIB")) { $credsMittiJob } else { $credsGfxJob }
                if (-not (Test-Path $credsFile)) { throw "no stored credentials for $h" }

                # ping said yes, so a share-level problem is a real failure
                & smbclient "\\$h\ShowShare" -A $credsFile -m SMB3 -c ls *> $null
                if ($LASTEXITCODE -ne 0) { throw "share not reachable (service asleep or wrong password)" }

                $out = & smbclient "\\$h\ShowShare" -A $credsFile -m SMB3 `
                        -c "put `"$($Path.FullName)`" `"$($Path.Name)`"" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $lines = (($out | Out-String).Trim() -split "`r?`n") | Where-Object { $_.Trim() }
                    throw "put failed: $($lines[-1])"
                }

                # verify against the size the far end reports
                $sizeOut = & smbclient "\\$h\ShowShare" -A $credsFile -m SMB3 `
                        -c "allinfo `"$($Path.Name)`"" 2>&1
                $remote = $null
                foreach ($line in ($sizeOut | Out-String -Stream)) {
                    if ($line -match 'size\s*[:=]\s*(\d+)') { $remote = [int64]$Matches[1] }
                }
                if ($null -ne $remote -and $remote -ne $expected) {
                    throw "SIZE MISMATCH local $expected remote $remote"
                }
                $ok = $true
            } catch {
                $ok = $false
                $detail = $_.Exception.Message
            }
            return @{ Host = $h; Ok = $ok; Detail = $detail }
        } -ArgumentList $Path, $h, $expected, $credsGfxJob, $credsMittiJob
    }

    $results = @()
    if ($jobs.Count -gt 0) {
        $null = $jobs | Wait-Job
        $results = @($jobs | Receive-Job)
        $jobs | Remove-Job -Force
    }

    $lock = [System.Threading.Mutex]::new($false, "Global\showkit-queue")
    $null = $lock.WaitOne(30000)
    try {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        foreach ($r in $results) {
            $h = $r.Host
            $dest = "\\$h\ShowShare"
            if ($null -eq $r.Ok) {
                $n = [int](Get-MapValue (Get-EntryProp $Entry "skip_count") $h 0) + 1
                Set-MapValue $Entry "skip_count" $h $n
                if ($n -le $MaxSkips) {
                    Set-MapValue $Entry "next_try" $h ($now + $SkipRetry)
                    Write-Log "SKIP [$label] -> $dest : $name (machine not present, will check again in ${SkipRetry}s)"
                } else {
                    Set-MapValue $Entry "given_up" $h "machine never came up"
                    Remove-MapKey $Entry "next_try" $h
                    Write-Log "SKIP [$label] -> $dest : $name (never came up, not retrying this machine)"
                }
                continue
            }
            Remove-MapKey $Entry "skip_count" $h
            Remove-MapKey $Entry "given_up" $h
            $attempts = [int](Get-MapValue (Get-EntryProp $Entry "targets") $h 0) + 1
            Set-MapValue $Entry "targets" $h $attempts
            if ($r.Ok) {
                Set-MapValue $Entry "delivered" $h $true
                Remove-MapKey $Entry "next_try" $h
                Write-Log "OK   [$label] -> $dest : $name ($attempts attempt)"
            } else {
                $delay = $Backoff[[Math]::Min($attempts, $Backoff.Count - 1)]
                Set-MapValue $Entry "next_try" $h ($now + $delay)
                $left = $MaxAttempts - $attempts
                if ($left -le 0) {
                    Set-MapValue $Entry "given_up" $h $r.Detail
                    Write-Log "FAIL [$label] -> $dest : $name : $($r.Detail) : giving up"
                } else {
                    Write-Log "FAIL [$label] -> $dest : $name : $($r.Detail) : retry in ${delay}s, $left attempt(s) left"
                }
            }
        }

        # settled = every target either delivered to or given up on
        $settled = $true
        foreach ($h in $targetList) {
            $delivered = Get-MapValue (Get-EntryProp $Entry "delivered") $h $false
            $givenUp = (Get-MapValue (Get-EntryProp $Entry "given_up") $h $null) -ne $null
            if (-not $delivered -and -not $givenUp) { $settled = $false; break }
        }
        if ($settled) {
            Set-EntryProp $Entry "done" $true
            $givenUpMap = Get-EntryProp $Entry "given_up"
            $absent = 0; $failed = @()
            foreach ($h in $targetList) {
                $why = Get-MapValue $givenUpMap $h $null
                if ($null -eq $why) { continue }
                if ($why -eq "machine never came up") { $absent++ }
                else {
                    $tries = Get-MapValue (Get-EntryProp $Entry "targets") $h 0
                    $failed += "$h ($tries/$MaxAttempts tries)"
                }
            }
            if ($failed.Count -gt 0) {
                Write-Log "GIVE UP $name : $($failed -join ', ') - re-drop the file to try again"
            } elseif ($absent -gt 0) {
                Write-Log "DONE $name ($absent machine(s) never came up)"
            } else {
                Write-Log "DONE $name"
            }
        }
        Save-Queue $Queue
    } finally {
        $lock.ReleaseMutex()
        $lock.Dispose()
    }
}

# ------------------------------------------------------------------ main loop

function Test-FileOpen([string]$Path) {
    # Exclusive open: succeeds only when no other process holds the file, which
    # is how we tell a finished copy from one still being written.
    $fs = $null
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'None')
        return $false
    } catch {
        return $true
    } finally {
        if ($null -ne $fs) { $fs.Dispose() }
    }
}

function Get-Listings {
    if (-not (Test-Path $DropDir)) { return @() }
    $out = @()
    foreach ($f in Get-ChildItem -LiteralPath $DropDir -File -ErrorAction SilentlyContinue) {
        if ($Ignore -contains $f.Name) { continue }
        $out += $f
    }
    return $out
}

New-Item -ItemType Directory -Path $DropDir -Force | Out-Null
New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null
New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null

$queue = Read-Queue
$stable = @{}

# A restart usually means the laptop just came up: forget backoff timers and
# never-present flags so anything outstanding is retried immediately.
foreach ($name in @($queue.Keys)) {
    $e = $queue[$name]
    if ($null -ne (Get-EntryProp $e "done")) { continue }
    Set-EntryProp $e "next_try" $null
    Set-EntryProp $e "skip_count" $null
    Set-EntryProp $e "given_up" $null
}
Save-Queue $queue

$resumed = @($queue.Keys | Where-Object { $null -eq (Get-EntryProp $queue[$_] "done") }).Count
Write-Log "Watcher started, $resumed file(s) carried over from last run"

while ($true) {
    Start-Sleep -Seconds $PollSeconds

    foreach ($f in Get-Listings) {
        # size + mtime must both hold still for SETTLE_POLLS samples
        $sig = "$($f.Length)|$($f.LastWriteTimeUtc.Ticks)"

        $entry = if ($queue.Contains($f.Name)) { $queue[$f.Name] } else { $null }

        if ($null -ne $entry -and [int64]$entry.size -ne [int64]$f.Length) {
            $queue.Remove($f.Name)
            Save-Queue $queue
            Write-Log "CHANGED $($f.Name) - size moved, treating as a new version"
            $entry = $null
            $stable.Remove($f.Name)
        }

        if ($null -eq $entry) {
            if (-not $stable.ContainsKey($f.Name)) {
                $stable[$f.Name] = @{ Sig = $sig; Count = 1 }
                continue
            }
            if ($stable[$f.Name].Sig -ne $sig) {
                $stable[$f.Name] = @{ Sig = $sig; Count = 1 }
                continue
            }
            $count = $stable[$f.Name].Count + 1
            $stable[$f.Name].Count = $count
            if ($count -ge $SettlePolls -and -not (Test-FileOpen $f.FullName)) {
                $existing = if ($queue.Contains($f.Name)) { $queue[$f.Name] } else { $null }
                if ($null -eq $existing -or [int64]$existing.size -ne [int64]$f.Length) {
                    $label = Get-Label $f.FullName
                    $queue[$f.Name] = [pscustomobject]@{
                        size    = [int64]$f.Length
                        label   = $label
                        targets = [pscustomobject]@{}
                        queued  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
                    }
                    Save-Queue $queue
                    Write-Log "QUEUED $($f.Name) [$label]"
                    $stable.Remove($f.Name)
                }
            }
            continue
        }

        if ($null -ne (Get-EntryProp $entry "done")) { continue }

        $needs = $false
        foreach ($h in @(Get-Targets $entry.label)) {
            $delivered = Get-MapValue (Get-EntryProp $entry "delivered") $h $false
            $givenUp = (Get-MapValue (Get-EntryProp $entry "given_up") $h $null) -ne $null
            $next = [double](Get-MapValue (Get-EntryProp $entry "next_try") $h 0)
            if (-not $delivered -and -not $givenUp -and
                [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge $next) { $needs = $true; break }
        }
        if ($needs -and -not (Test-FileOpen $f.FullName)) {
            Invoke-Push $f $entry $queue
        }
    }

    # forget files that left the folder
    foreach ($name in @($queue.Keys)) {
        if (-not (Test-Path (Join-Path $DropDir $name))) {
            Write-Log "GONE  $name - removed from Ingest, dropping from queue"
            $queue.Remove($name)
            Save-Queue $queue
        }
    }
}
