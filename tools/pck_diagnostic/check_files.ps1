# Windows PowerShell 5.1; ASCII source for non-Thai Windows.
[CmdletBinding()]
param([string]$Game)

$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot 'diagnostic.log'
$transcript = $false
$result = 1
try {
    Start-Transcript -LiteralPath $log -Force | Out-Null
    $transcript = $true
    Write-Host 'Until Then - READ ONLY diagnostic 2026-10-09-r1'
    Write-Host 'Reads game files only. Does not install, rename files, or control Steam.'
    Write-Host ('PowerShell: {0}; CLR: {1}; process bits: {2}' -f $PSVersionTable.PSVersion, [Environment]::Version, ([IntPtr]::Size * 8))
    if (-not $Game) { $Game = & (Join-Path $PSScriptRoot 'detect_game.ps1') }
    if (-not $Game) { $Game = Read-Host 'Enter the full Until Then game folder path' }
    $Game = [IO.Path]::GetFullPath($Game.Trim().Trim('"'))
    $pck = Join-Path $Game 'UntilThen.pck'
    $backup = Join-Path $Game 'UntilThen.pck.bak'
    $source = $pck
    if ([IO.File]::Exists($backup)) { $source = $backup }
    Write-Host "Game: $Game"
    Write-Host "Source the low-memory installer would select: $source"
    Write-Host 'An existing .bak takes priority over the live .pck.'

    # Identify the old EXE extraction left on this PC, without launching it.
    $extracted = Join-Path ([IO.Path]::GetTempPath()) 'UntilThenThaiMod\install_low_memory.ps1'
    if ([IO.File]::Exists($extracted)) {
        Write-Host "EXE extraction script: $extracted"
        Write-Host ('EXE extraction SHA256: ' + (Get-FileHash -LiteralPath $extracted -Algorithm SHA256).Hash)
        Select-String -LiteralPath $extracted -Pattern 'One worker|installer build:' | ForEach-Object { Write-Host $_.Line.Trim() }
    }

    Add-Type -Path (Join-Path $PSScriptRoot 'ProbePck.cs')
    Write-Host ([UntilThenPckProbe]::SelfTest())
    $found = 0
    foreach ($name in @('UntilThen.pck', 'UntilThen.pck.bak', 'UntilThen.pck.bak.old')) {
        $path = Join-Path $Game $name
        if ([IO.File]::Exists($path)) {
            $found++
            Write-Host "`nChecking: $name"
            Write-Host ([UntilThenPckProbe]::Inspect($path))
        } else {
            Write-Host "Not present: $name"
        }
    }
    if ($found -eq 0) { throw 'No PCK files found in that game folder.' }
    Write-Host 'Diagnostic finished. A MISMATCH or READ ERROR is recorded above if found.'
    Write-Host 'Send diagnostic.log to the mod maintainer. No game files were changed.'
    $result = 0
} catch {
    Write-Host ('[X] Diagnostic failed: ' + $_.Exception.Message)
} finally {
    Write-Host ('Peak diagnostic working set: {0:N1} MB' -f ([Diagnostics.Process]::GetCurrentProcess().PeakWorkingSet64 / 1MB))
    Write-Host "Log: $log"
    if ($transcript) { Stop-Transcript | Out-Null }
}
exit $result
