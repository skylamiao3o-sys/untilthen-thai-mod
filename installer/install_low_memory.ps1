# Windows PowerShell 5.1; ASCII source so it also runs on non-Thai Windows.
[CmdletBinding()]
param([string]$Game, [switch]$CheckOnly, [switch]$Restore, [switch]$LowDisk)

$ErrorActionPreference = 'Stop'
$plan = $null
$mutex = $null
$locked = $false
$transcript = $false
$tempPck = $null
$exitCode = 1

try {
    if ($LowDisk -and $Restore) { throw 'Low-disk mode cannot restore a backup. Use Steam -> Verify integrity of game files.' }
    if (-not $Game) { $Game = & (Join-Path $PSScriptRoot 'detect_game.ps1') }
    if (-not $Game) {
        Write-Host 'Steam -> Until Then -> Manage -> Browse local files'
        $Game = Read-Host 'Enter the full Until Then game folder path'
    }
    $Game = [IO.Path]::GetFullPath($Game.Trim().Trim('"'))
    $pck = Join-Path $Game 'UntilThen.pck'
    $backup = Join-Path $Game 'UntilThen.pck.bak'
    if (-not [IO.File]::Exists($pck) -and -not [IO.File]::Exists($backup)) {
        throw 'Cannot find UntilThen.pck or UntilThen.pck.bak in that folder.'
    }
    if ($Restore -and -not [IO.File]::Exists($backup)) {
        throw 'No UntilThen.pck.bak found. Use Steam -> Verify integrity of game files to restore the game.'
    }
    if ($LowDisk -and -not [IO.File]::Exists($pck)) {
        throw 'Low-disk mode needs an intact UntilThen.pck. Restore the game through Steam first. Existing backup kept.'
    }

    # Both font packages share a lock, so double-clicking twice cannot start two builds.
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $lockId = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Game.TrimEnd('\').ToUpperInvariant()))).Replace('-', '') }
    finally { $sha.Dispose() }
    $mutex = New-Object Threading.Mutex($false, "Local\UntilThenThaiMod_$lockId")
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another Thai mod installer is already working on this game. Wait for it to finish.' }

    $logName = 'debug.log'
    if ($Restore) { $logName = 'uninstall_debug.log' }
    Start-Transcript -LiteralPath (Join-Path $PSScriptRoot $logName) -Force | Out-Null
    $transcript = $true
    Write-Host 'Until Then - Thai Mod - LOW MEMORY installer'
    Write-Host 'Installer build: 2026-10-09-lowdisk-r1'
    Write-Host "Game: $Game"
    Write-Host 'One worker, 1 MB file buffer. Steam is managed by you.'
    Write-Host 'Installation can proceed with Steam open if the game files are available.'
    if ($LowDisk) {
        Write-Host 'LOW DISK: use the live game; keep no full .bak after installation.'
        Write-Host 'Existing .bak and recognized temporary packs are removed only after the live game passes FULL verification.'
        Write-Host 'To remove this mod later, use Steam -> Verify integrity of game files.'
    }
    try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
    . (Join-Path $PSScriptRoot 'steam_guard.ps1')

    if (-not $CheckOnly) {
        Assert-ModGameClosed
        Assert-ModFilesAvailable -Game $Game
    }

    $source = $pck
    if (-not $LowDisk -and [IO.File]::Exists($backup)) { $source = $backup }
    Write-Host "Source PCK: $source"
    Add-Type -Path (Join-Path $PSScriptRoot 'LowMemoryPck.cs')
    if ($Restore) {
        $outputLength = (Get-Item -LiteralPath $backup).Length
        Write-Host '[..] Preparing to restore the original backup...'
    } else {
        $manifest = Join-Path $PSScriptRoot 'payload.manifest'
        $expected = [int]([IO.File]::ReadAllText($manifest).Trim())
        if ($expected -le 0) { throw 'Invalid payload.manifest. Extract the whole ZIP again.' }
        Write-Host '[..] Checking source directory and mod files...'
        $plan = [UntilThenThaiMod.LowMemoryPck]::Prepare($source, (Join-Path $PSScriptRoot 'payload'), $expected)
        $outputLength = $plan.OutputLength
        Write-Host ('Files: ' + $plan.FileCount)
    }

    # Backup is created by renaming the original only AFTER a verified build exists.
    # Output stays on the game drive so final replacement never copies across drives.
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Game))
    if ($drive.DriveFormat -eq 'FAT32' -and $outputLength -ge 4GB) { throw 'This PCK is too large for FAT32. Move the game to an NTFS drive.' }
    $required = $outputLength + 256MB
    Write-Host ('New PCK: {0:N2} GB; required free: {1:N2} GB; available: {2:N2} GB' -f ($outputLength / 1GB), ($required / 1GB), ($drive.AvailableFreeSpace / 1GB))
    if ($LowDisk) {
        # Only exact historical installer filenames in THIS game directory. Never recurse,
        # follow links, sweep arbitrary Thai PCKs, or touch files in another game's folder.
        $reclaim = @(Get-ChildItem -LiteralPath $Game -File -Force | Where-Object {
            $_.Name -eq 'UntilThen.pck.bak' -or
            $_.Name -match '\AUntilThen\.thmod\.(?:tmp|[0-9]+|lowram\.[0-9a-f]{32}\.tmp)\.pck\z'
        })
        $gameDirectory = [IO.Path]::GetFullPath($Game).TrimEnd('\')
        foreach ($item in $reclaim) {
            $fullPath = [IO.Path]::GetFullPath($item.FullName)
            if ([IO.Path]::GetDirectoryName($fullPath) -ne $gameDirectory -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Refusing to remove a link or a file outside the game folder: $fullPath"
            }
            Write-Host ('Space recovery candidate: {0} ({1:N2} GB)' -f $item.Name, ($item.Length / 1GB))
        }
        if ($reclaim.Count -gt 0) {
            Write-Host '[..] Verifying EVERY resource in the live game before any space recovery...'
            [UntilThenThaiMod.LowMemoryPck]::Verify($pck)
            Write-Host '[OK] Full live-game verification passed.'
            if ($CheckOnly) {
                Write-Host '[OK] Check only: no files removed. Run INSTALL_LOW_DISK.bat to recover this space and install.'
                Write-Host 'Free space will be checked again AFTER removal; compressed/sparse files may free less than their displayed size.'
            } else {
                Assert-ModGameClosed
                # The plan keeps the verified live PCK locked against writes throughout cleanup/build.
                foreach ($item in $reclaim) {
                    if (([IO.File]::GetAttributes($item.FullName) -band [IO.FileAttributes]::ReparsePoint)) {
                        throw "File became a link during space recovery: $($item.FullName)"
                    }
                    $handle = [IO.File]::Open($item.FullName, 'Open', 'Read', 'None')
                    $handle.Dispose()
                    [IO.File]::Delete($item.FullName)
                    Write-Host ('[OK] Removed old backup/temporary pack: ' + $item.Name)
                }
                $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Game))
                Write-Host ('Available after space recovery: {0:N2} GB; required: {1:N2} GB' -f ($drive.AvailableFreeSpace / 1GB), ($required / 1GB))
            }
        }
    }
    # Do not claim enough disk space from logical file sizes; only actual deletion can confirm it.
    $spacePending = $LowDisk -and $CheckOnly -and $reclaim.Count -gt 0
    if (-not $spacePending -and $drive.AvailableFreeSpace -lt $required) { throw 'Not enough free space on the game drive. Free the required space and retry.' }

    if ($CheckOnly) {
        if ($spacePending) { Write-Host '[OK] Source/payload checks finished. No game files changed. Enough free space is NOT yet confirmed.' }
        else { Write-Host '[OK] Preflight passed. No game files were changed. Contents are verified during the actual build.' }
    } else {
        $tempPck = Join-Path $Game ('UntilThen.thmod.lowram.' + [Guid]::NewGuid().ToString('N') + '.tmp.pck')
        if ($Restore) {
            Write-Host '[..] Copying and verifying the backup before restoring it...'
            [IO.File]::Copy($backup, $tempPck, $false)
            [UntilThenThaiMod.LowMemoryPck]::Verify($tempPck)
        } else {
            Write-Host '[..] Building and checking every file. This may take several minutes on a slow disk.'
            [UntilThenThaiMod.LowMemoryPck]::Build($plan, $tempPck)
            $plan.Dispose()
            $plan = $null
        }
        Assert-ModGameClosed
        Assert-ModFilesAvailable -Game $Game

        Write-Host '[..] Installing verified PCK...'
        if ($LowDisk) {
            # Replace only after the complete new PCK has been built AND read back successfully.
            # The live game stays intact until this point; no third full PCK is created.
            [IO.File]::Replace($tempPck, $pck, [System.Management.Automation.Language.NullString]::Value)
        } elseif (-not [IO.File]::Exists($backup)) {
            # A power loss here leaves the untouched original in .bak; the next run uses it.
            [IO.File]::Move($pck, $backup)
            try { [IO.File]::Move($tempPck, $pck) }
            catch {
                if (-not [IO.File]::Exists($pck)) { [IO.File]::Copy($backup, $pck, $false) }
                throw
            }
        } elseif ([IO.File]::Exists($pck)) {
            # PS 5.1 converts $null to an empty string for string parameters.
            [IO.File]::Replace($tempPck, $pck, [System.Management.Automation.Language.NullString]::Value)
        } else {
            [IO.File]::Move($tempPck, $pck)
        }
        $tempPck = $null
        Write-Host '[OK] DONE! You can open the game when ready.'
        if ($Restore) {
            Write-Host 'Restored original game. Backup kept: UntilThen.pck.bak.'
        } else {
            Write-Host 'Settings -> Language: Thai / Thai (rough)'
            if ($LowDisk) {
                Write-Host 'Low-disk install complete: no full .bak kept. To remove the mod, use Steam -> Verify integrity of game files.'
            } else {
                Write-Host 'Original backup kept: UntilThen.pck.bak. To restore it, run UNINSTALL.bat.'
            }
        }
    }
    $exitCode = 0
} catch {
    Write-Host ('[X] ' + $_.Exception.Message)
    Write-Host 'Operation stopped. See debug.log / uninstall_debug.log next to the BAT file.'
    if ($LowDisk) { Write-Host 'Low-disk mode may already have removed old backup/temporary packs after full live-game verification.' }
    else { Write-Host 'Any existing backup is kept.' }
} finally {
    if ($plan) { $plan.Dispose() }
    # Only remove the one temporary file allocated by THIS run; never wildcard-delete folders.
    if ($tempPck -and [IO.File]::Exists($tempPck)) {
        try { [IO.File]::Delete($tempPck) } catch { Write-Host "Temporary file could not be removed: $tempPck" }
    }
    $process = [Diagnostics.Process]::GetCurrentProcess()
    Write-Host ('Peak installer working set: {0:N1} MB' -f ($process.PeakWorkingSet64 / 1MB))
    if ($transcript) { Stop-Transcript | Out-Null }
    if ($locked) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
exit $exitCode
