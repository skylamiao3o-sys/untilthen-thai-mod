# Windows PowerShell 5.1; ASCII source so it also runs on non-Thai Windows.
[CmdletBinding()]
param([string]$Game, [switch]$CheckOnly, [switch]$Restore,
      [ValidateRange(1, 30)][int]$SteamTimeoutSeconds = 30)

$ErrorActionPreference = 'Stop'
$plan = $null
$mutex = $null
$locked = $false
$transcript = $false
$tempPck = $null
$exitCode = 1

try {
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
    Write-Host "Game: $Game"
    Write-Host 'One worker, 1 MB file buffer. Steam will stay closed after installation.'
    try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
    . (Join-Path $PSScriptRoot 'steam_guard.ps1')

    if (-not $CheckOnly) {
        Close-ModSteam -TimeoutSeconds $SteamTimeoutSeconds
        Assert-ModFilesAvailable -Game $Game
    }

    $source = $pck
    if ([IO.File]::Exists($backup)) { $source = $backup }
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
    if ($drive.AvailableFreeSpace -lt $required) { throw 'Not enough free space on the game drive. Free the required space and retry.' }

    if ($CheckOnly) {
        Write-Host '[OK] Preflight passed. No game files were changed. Contents are verified during the actual build.'
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
        Assert-ModClientsClosed
        Assert-ModFilesAvailable -Game $Game

        Write-Host '[..] Installing verified PCK...'
        if (-not [IO.File]::Exists($backup)) {
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
        Write-Host '[OK] DONE! Open Steam and the game when ready.'
        if ($Restore) {
            Write-Host 'Restored original game. Backup kept: UntilThen.pck.bak.'
        } else {
            Write-Host 'Settings -> Language: Thai / Thai (rough)'
            Write-Host 'Original backup kept: UntilThen.pck.bak. To restore it, run UNINSTALL.bat.'
        }
    }
    $exitCode = 0
} catch {
    Write-Host ('[X] ' + $_.Exception.Message)
    Write-Host 'Operation stopped. Any existing backup is kept. See debug.log / uninstall_debug.log next to the BAT file.'
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
