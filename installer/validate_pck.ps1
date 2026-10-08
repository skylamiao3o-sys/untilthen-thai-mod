# Retain the old interface, but validate bounds and ALL resource hashes, not just file size.
param([Parameter(Mandatory=$true)][string]$Pck, [string]$Base)
$ErrorActionPreference = 'Stop'
try {
    if (-not ('UntilThenThaiMod.LowMemoryPck' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'LowMemoryPck.cs')
    }
    # Keep stdout compatible with callers that expect exactly OK / BAD.
    $previous = [Console]::Out
    try {
        [Console]::SetOut([IO.TextWriter]::Null)
        [UntilThenThaiMod.LowMemoryPck]::Verify($Pck)
    } finally { [Console]::SetOut($previous) }
    Write-Output 'OK'
    exit 0
} catch {
    Write-Output ('BAD ' + $_.Exception.Message)
    exit 1
}
