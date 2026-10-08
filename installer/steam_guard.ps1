# Game/file checks shared by install/uninstall. Filename retained for package compatibility.
# Steam is user-managed: never query, start, stop or wait for the Steam client.

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
