# Shared by install/uninstall. Dot-source only; loading this file never closes any application.
# Windows PowerShell 5.1, ASCII source. Never force-kill games, Steam, helpers or services.

function Get-ModSessionProcesses {
    param([string[]]$Name)
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    foreach ($item in @(Get-Process -Name $Name -ErrorAction SilentlyContinue)) {
        try {
            if ($item.SessionId -eq $session) { $item }
        } catch {
            # A process may exit while we inspect it. An actual file lock is checked separately.
            Write-Host ('[!] Could not inspect process {0}: {1}' -f $item.Id, $_.Exception.Message)
        }
    }
}

function Assert-ModGameClosed {
    $gameProcesses = @(Get-ModSessionProcesses -Name 'UntilThen', 'UntilThen.console', 'UntilThen_console')
    if ($gameProcesses.Count) {
        throw ('Save and close Until Then before continuing. Game PID(s): ' + (($gameProcesses | ForEach-Object { $_.Id }) -join ', '))
    }
}

function Get-ModSteamExecutable {
    param([object[]]$Processes)
    $candidates = New-Object 'Collections.Generic.List[string]'
    # Use the running client first; registry entries can point to an old install or another user.
    foreach ($item in $Processes) {
        try { if ($item.Path) { $candidates.Add($item.Path) } } catch { }
    }
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        $settings = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($settings.SteamExe) { $candidates.Add($settings.SteamExe) }
        foreach ($folder in @($settings.SteamPath, $settings.InstallPath)) {
            if ($folder) { $candidates.Add((Join-Path $folder 'steam.exe')) }
        }
    }
    foreach ($candidate in $candidates) {
        try {
            $candidate = [IO.Path]::GetFullPath($candidate.Trim('"').Replace('/', '\'))
            if ([IO.Path]::GetFileName($candidate) -ieq 'steam.exe' -and [IO.File]::Exists($candidate)) {
                return $candidate
            }
        } catch { }
    }
    return $null
}

function Close-ModSteam {
    param([ValidateRange(1, 30)][int]$TimeoutSeconds = 30)
    Assert-ModGameClosed
    $steam = @(Get-ModSessionProcesses -Name 'steam')
    if (-not $steam.Count) { return }

    Write-Host ('[..] Closing Steam normally. Waiting at most {0} seconds...' -f $TimeoutSeconds)
    $executable = Get-ModSteamExecutable -Processes $steam
    if ($executable) {
        Write-Host ('Steam executable: ' + $executable)
        try {
            # No -Wait: the launch helper itself must not become an unlimited wait.
            Start-Process -FilePath $executable -ArgumentList '-shutdown' -WindowStyle Hidden -ErrorAction Stop
        } catch {
            Write-Host ('[!] Could not request Steam shutdown: ' + $_.Exception.Message)
            Write-Host '[!] Exit Steam manually from the tray. If access is denied, close Steam from its own window.'
        }
    } else {
        Write-Host '[!] Cannot locate steam.exe. Exit Steam manually from the tray while this installer waits.'
    }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $nextNotice = 5
    while ($true) {
        $steam = @(Get-ModSessionProcesses -Name 'steam')
        if (-not $steam.Count) {
            Assert-ModGameClosed
            Write-Host '[OK] Steam closed.'
            return
        }
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
        if ($timer.Elapsed.TotalSeconds -ge $nextNotice) {
            Write-Host ('[..] Still waiting for Steam ({0}/{1} seconds)...' -f [int]$timer.Elapsed.TotalSeconds, $TimeoutSeconds)
            $nextNotice += 5
        }
        Start-Sleep -Milliseconds 250
    }
    $ids = ($steam | ForEach-Object { $_.Id }) -join ', '
    throw ("Steam did not exit within $TimeoutSeconds seconds (PID: $ids). Finish any game, download or Cloud sync, then fully exit Steam (tray -> Exit) and retry. If Steam is unresponsive, close Steam Client Bootstrapper in Task Manager. No game files were replaced.")
}

function Assert-ModClientsClosed {
    Assert-ModGameClosed
    if (@(Get-ModSessionProcesses -Name 'steam').Count) {
        throw 'Steam reopened during this operation. Fully exit Steam and retry. No game files were replaced.'
    }
}

function Assert-ModFilesAvailable {
    param([string]$Game)
    foreach ($name in @('UntilThen.pck', 'UntilThen.pck.bak')) {
        $path = Join-Path $Game $name
        if (-not [IO.File]::Exists($path)) { continue }
        $handle = $null
        try {
            $handle = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        } catch [UnauthorizedAccessException] {
            throw "Cannot access $name. Check game folder permissions; use Run as administrator if needed."
        } catch [IO.IOException] {
            throw "$name is locked or cannot be opened: $($_.Exception.Message) Close the game and Steam, wait for any file scan to finish, then retry."
        } finally { if ($handle) { $handle.Dispose() } }
    }
}
