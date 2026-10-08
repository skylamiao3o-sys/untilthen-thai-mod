"""Independent PCK fixtures + installer failure/reinstall tests. Never installs to the real game.

Run with Python 3.12 on Windows. --real-base also builds against that read-only PCK
and checks every output resource against the original or the current mod payload.
"""
import argparse
import hashlib
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / ("ThaiMod" if (ROOT / "ThaiMod").is_dir() else "installer")
PS = "powershell.exe"
HELPERS = ("INSTALL.bat", "UNINSTALL.bat", "install_low_memory.ps1", "LowMemoryPck.cs", "validate_pck.ps1", "steam_guard.ps1")


def fixture(path, files, relative=True):
    records = []
    table_size = 100
    for name, content in files.items():
        raw = name.encode("utf-8")
        raw += b"\0" * (-len(raw) % 4)
        records.append((raw, content))
        table_size += 40 + len(raw)
    start = (table_size + 31) // 32 * 32
    offset = 0
    with path.open("wb") as f:
        f.write(struct.pack("<6IQ16II", 0x43504447, 2, 4, 1, 4, 0,
                            start if relative else 0, *([0] * 16), len(files)))
        for raw, content in records:
            f.write(struct.pack("<I", len(raw)) + raw)
            f.write(struct.pack("<QQ16sI", offset if relative else start + offset,
                                len(content), hashlib.md5(content).digest(), 0))
            offset += (len(content) + 31) // 32 * 32
        f.write(b"\0" * (start - f.tell()))
        for _, content in records:
            f.write(content)
            f.write(b"\0" * (-len(content) % 32))


def directory(path):
    result = {}
    with path.open("rb") as f:
        fields = struct.unpack("<6IQ16II", f.read(100))
        assert fields[:2] == (0x43504447, 2)
        for _ in range(fields[-1]):
            length, = struct.unpack("<I", f.read(4))
            name = f.read(length).rstrip(b"\0").decode("utf-8")
            offset, size, md5, flags = struct.unpack("<QQ16sI", f.read(36))
            assert flags == 0
            assert name not in result
            result[name] = (fields[6] + offset, size, md5)
    return result


def check_contents(path, expected):
    entries = directory(path)
    assert set(entries) == set(expected), "Missing or unexpected resource paths"
    with path.open("rb") as f:
        for name, (offset, size, digest) in entries.items():
            f.seek(offset)
            actual = f.read(size)
            assert actual == expected[name], name
            assert hashlib.md5(actual).digest() == digest, name


RUNNER = r'''
param([string]$Code, [string]$Base, [string]$Payload, [string]$Output)
$ErrorActionPreference = 'Stop'
$plan = $null
try {
    Add-Type -Path $Code
    $plan = [UntilThenThaiMod.LowMemoryPck]::Prepare($Base, $Payload, -1)
    [UntilThenThaiMod.LowMemoryPck]::Build($plan, $Output)
    exit 0
} catch { Write-Host $_; exit 1 }
finally {
    if ($plan) { $plan.Dispose() }
    Write-Host ('Peak working set MB: {0:N1}' -f ([Diagnostics.Process]::GetCurrentProcess().PeakWorkingSet64 / 1MB))
}
'''


def powershell(script, *args, ok=True, stdin=None):
    result = subprocess.run([PS, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
                             "-File", str(script), *map(str, args)],
                            input=stdin, capture_output=True, text=True, errors="replace", timeout=60)
    if ok and result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    if not ok and result.returncode == 0:
        raise AssertionError("Expected a failure: " + result.stdout)
    return result.stdout + result.stderr




class InstallerTests(unittest.TestCase):
    def setUp(self):
        (ROOT / 'build').mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="lowram test ! & ' ", dir=ROOT / "build")
        self.root = Path(self.tmp.name)
        assert self.root.resolve().is_relative_to((ROOT / "build").resolve())
        self.package = self.root / "package"
        self.game = self.root / "game"
        self.package.mkdir()
        self.game.mkdir()
        for name in HELPERS:
            shutil.copy2(PACKAGE / name, self.package / name)
        # Mock process discovery in the fixture runner only; never close the user's Steam.
        self.install_runner = self.root / "invoke_install.ps1"
        self.install_runner.write_text(r'''
param([string]$Script, [string]$Game, [switch]$CheckOnly, [switch]$MockRunning, [switch]$HoldLive, [switch]$Restore, [switch]$MockReopen, [switch]$MockGameRunning, [switch]$MockGameReopen)
$script:steamTouches = 0
$script:gameQueries = 0
function Get-Process {
    [CmdletBinding()]param([string[]]$Name)
    if (-not $Name -or $Name -contains 'steam' -or $Name -contains 'steamwebhelper' -or $Name -contains 'steamservice') {
        $script:steamTouches++
    }
    if ($Name -contains 'UntilThen') { $script:gameQueries++ }
    $available = @()
    if ($MockRunning -or ($MockReopen -and $script:gameQueries -ge 2)) {
        $available += [PSCustomObject]@{ ProcessName = 'steam'; Id = 4242; Path = $null; SessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId }
    }
    if ($MockGameRunning -or ($MockGameReopen -and $script:gameQueries -ge 2)) {
        $available += [PSCustomObject]@{ ProcessName = 'UntilThen'; Id = 4243; SessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId }
    }
    $available | Where-Object { $Name -contains $_.ProcessName }
}
# Fail the test on ANY Steam inspection/control/wait, even if the installer catches the error.
function Get-ItemProperty { [CmdletBinding()]param([string]$LiteralPath); $script:steamTouches++ }
function Start-Process { [CmdletBinding()]param([string]$FilePath, [string[]]$ArgumentList, [string]$WindowStyle); $script:steamTouches++; throw 'Unexpected launch' }
function Stop-Process { [CmdletBinding()]param([string[]]$Name, [int[]]$Id, [switch]$Force); $script:steamTouches++; throw 'Unexpected process stop' }
function Start-Sleep { param([int]$Milliseconds, [int]$Seconds); $script:steamTouches++; throw 'Unexpected wait' }
$handle = $null
try {
    if ($HoldLive) { $handle = [IO.File]::Open((Join-Path $Game 'UntilThen.pck'), 'Open', 'Read', 'Read') }
    & $Script -Game $Game -CheckOnly:$CheckOnly -Restore:$Restore
    $result = $LASTEXITCODE
    Write-Host ('Steam operations: ' + $script:steamTouches)
    if ($script:steamTouches -ne 0) { exit 99 }
    exit $result
} finally { if ($handle) { $handle.Dispose() } }
''', encoding="ascii")
        (self.package / "payload").mkdir()
        self.original = {"res://unchanged.txt": b"original content", "res://replace.txt": b"old",
                         "res://empty.txt": b"", "res://large.bin": bytes(range(256)) * 12289}
        self.payload = {"replace.txt": b"new Thai mod", "added.txt": b"added resource",
                        "nested/ภาษาไทย.txt": "สวัสดี".encode("utf-8")}
        for name, content in self.payload.items():
            path = self.package / "payload" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        (self.package / "payload.manifest").write_text(str(len(self.payload)), encoding="ascii")
        self.pck = self.game / "UntilThen.pck"
        self.bak = self.game / "UntilThen.pck.bak"
        fixture(self.pck, self.original)
        self.old_bytes = self.pck.read_bytes()
        self.expected = self.original | {"res://" + k: v for k, v in self.payload.items()}

    def tearDown(self):
        assert self.root.resolve().is_relative_to((ROOT / "build").resolve())
        self.tmp.cleanup()

    def install(self, ok=True, check=False):
        return powershell(self.install_runner, "-Script", self.package / "install_low_memory.ps1", "-Game", self.game,
                          *(["-CheckOnly"] if check else []), ok=ok)

    def test_running_steam_does_not_block_install(self):
        output = powershell(self.install_runner, "-Script", self.package / "install_low_memory.ps1",
                            "-Game", self.game, "-MockRunning")
        self.assertIn('Steam operations: 0', output)
        check_contents(self.pck, self.expected)
        self.assertEqual(self.bak.read_bytes(), self.old_bytes)

    def test_restore_uses_shared_guard_and_preserves_backup(self):
        self.install()
        output = powershell(self.install_runner, '-Script', self.package / 'install_low_memory.ps1',
                            '-Game', self.game, '-Restore', '-MockRunning')
        self.assertIn('Steam operations: 0', output)
        self.assertEqual(self.pck.read_bytes(), self.old_bytes)
        self.assertEqual(self.bak.read_bytes(), self.old_bytes)

    def test_steam_starting_during_build_does_not_block_install(self):
        output = powershell(self.install_runner, '-Script', self.package / 'install_low_memory.ps1',
                            '-Game', self.game, '-MockReopen')
        self.assertIn('Steam operations: 0', output)
        check_contents(self.pck, self.expected)
        self.assertEqual(self.bak.read_bytes(), self.old_bytes)
        self.assertFalse(list(self.game.glob('*.tmp.pck')))

    def test_running_game_preserves_live_file(self):
        output = powershell(self.install_runner, '-Script', self.package / 'install_low_memory.ps1',
                            '-Game', self.game, '-MockRunning', '-MockGameRunning', ok=False)
        self.assertIn('Save and close Until Then', output)
        self.assertIn('Steam operations: 0', output)
        self.assertEqual(self.pck.read_bytes(), self.old_bytes)
        self.assertFalse(self.bak.exists())

    def test_game_reopening_during_build_preserves_live_file(self):
        output = powershell(self.install_runner, '-Script', self.package / 'install_low_memory.ps1',
                            '-Game', self.game, '-MockGameReopen', ok=False)
        self.assertIn('Save and close Until Then', output)
        self.assertIn('Steam operations: 0', output)
        self.assertEqual(self.pck.read_bytes(), self.old_bytes)
        self.assertFalse(self.bak.exists())
        self.assertFalse(list(self.game.glob('*.tmp.pck')))

    def test_restore_rejects_bad_backup_without_overwriting_live(self):
        self.bak.write_bytes(b'invalid backup')
        powershell(self.install_runner, '-Script', self.package / 'install_low_memory.ps1',
                   '-Game', self.game, '-Restore', ok=False)
        self.assertEqual(self.pck.read_bytes(), self.old_bytes)
        self.assertEqual(self.bak.read_bytes(), b'invalid backup')
        self.assertFalse(list(self.game.glob('*.tmp.pck')))

    def test_uninstall_batch_preflight(self):
        self.bak.write_bytes(self.old_bytes)
        command = f'cmd.exe /d /s /c ""{self.package / "UNINSTALL.bat"}" -Game "{self.game}" -CheckOnly"'
        result = subprocess.run(command, input='\n', capture_output=True, text=True, errors='replace', timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Preparing to restore', result.stdout)
        self.assertEqual(self.pck.read_bytes(), self.old_bytes)

    def test_locked_live_file_is_preserved(self):
        # Steam may remain open, but an actual file lock must still stop the operation.
        self.bak.write_bytes(self.old_bytes)
        output = powershell(self.install_runner, "-Script", self.package / "install_low_memory.ps1",
                            "-Game", self.game, "-HoldLive", '-MockRunning', ok=False)
        self.assertIn('UntilThen.pck is locked', output)
        self.assertIn('Steam operations: 0', output)
        self.assertEqual(self.pck.read_bytes(), self.old_bytes)
        self.assertEqual(self.bak.read_bytes(), self.old_bytes)
        self.assertFalse(list(self.game.glob("*.tmp.pck")))

    def test_batch_launcher_with_special_characters_in_path(self):
        command = f'cmd.exe /d /s /c ""{self.package / "INSTALL.bat"}" -Game "{self.game}" -CheckOnly"'
        result = subprocess.run(command, input="\n", capture_output=True, text=True, errors="replace")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Preflight passed', result.stdout)
        self.assertEqual(self.pck.read_bytes(), self.old_bytes)

    def test_second_installer_is_blocked(self):
        holder = self.root / "hold_mutex.ps1"
        holder.write_text(r'''
param([string]$Game)
$sha = [Security.Cryptography.SHA256]::Create()
$key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Game.TrimEnd('\').ToUpperInvariant()))).Replace('-', '')
$mutex = New-Object Threading.Mutex($false, "Local\UntilThenThaiMod_$key")
try {
    [void]$mutex.WaitOne()
    [Console]::WriteLine('READY')
    [void][Console]::ReadLine()
} finally { $mutex.ReleaseMutex(); $mutex.Dispose(); $sha.Dispose() }
''', encoding="ascii")
        process = subprocess.Popen([PS, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                                    str(holder), '-Game', str(self.game)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(), 'READY')
            self.assertIn('Another Thai mod installer', self.install(ok=False))
            self.assertEqual(self.pck.read_bytes(), self.old_bytes)
            self.assertFalse(self.bak.exists())
        finally:
            process.communicate(input='\n', timeout=10)

    def test_first_install_reinstall_and_recovery(self):
        self.install()
        check_contents(self.pck, self.expected)
        self.assertEqual(self.bak.read_bytes(), self.old_bytes)
        self.install()
        check_contents(self.pck, self.expected)
        self.assertEqual(self.bak.read_bytes(), self.old_bytes)
        self.pck.unlink()
        self.install()
        check_contents(self.pck, self.expected)
        self.pck.write_bytes(b"broken live game")
        self.install()
        check_contents(self.pck, self.expected)
        self.assertEqual(self.bak.read_bytes(), self.old_bytes)
        self.assertFalse(list(self.game.glob("*.tmp.pck")))

    def test_absolute_offsets(self):
        fixture(self.pck, self.original, relative=False)
        self.install()
        check_contents(self.pck, self.expected)

    def test_preflight_does_not_modify_game(self):
        self.install(check=True)
        self.assertEqual(self.pck.read_bytes(), self.old_bytes)
        self.assertFalse(self.bak.exists())

    def test_incomplete_payload_preserves_game(self):
        (self.package / "payload/added.txt").unlink()
        self.assertIn("Incomplete payload", self.install(ok=False))
        self.assertEqual(self.pck.read_bytes(), self.old_bytes)
        self.assertFalse(self.bak.exists())

    def test_bad_checksum_preserves_game(self):
        offset, _, _ = directory(self.pck)["res://unchanged.txt"]
        with self.pck.open("r+b") as f:
            f.seek(offset)
            f.write(b"X")
        damaged = self.pck.read_bytes()
        self.assertIn("Checksum mismatch", self.install(ok=False))
        self.assertEqual(self.pck.read_bytes(), damaged)
        self.assertFalse(self.bak.exists())
        self.assertFalse(list(self.game.glob("*.tmp.pck")))

    def test_truncated_source_preserves_game(self):
        self.pck.write_bytes(self.old_bytes[:-40])
        damaged = self.pck.read_bytes()
        self.install(ok=False)
        self.assertEqual(self.pck.read_bytes(), damaged)
        self.assertFalse(self.bak.exists())

    def test_bad_existing_backup_preserves_live(self):
        self.bak.write_bytes(b"bad backup")
        self.install(ok=False)
        self.assertEqual(self.pck.read_bytes(), self.old_bytes)
        self.assertEqual(self.bak.read_bytes(), b"bad backup")

    def test_validation_rejects_corruption_even_when_size_is_unchanged(self):
        powershell(self.package / "validate_pck.ps1", "-Pck", self.pck)
        offset, _, _ = directory(self.pck)["res://unchanged.txt"]
        with self.pck.open("r+b") as f:
            f.seek(offset)
            f.write(b"!")
        output = powershell(self.package / "validate_pck.ps1", "-Pck", self.pck, ok=False)
        self.assertIn("Checksum mismatch", output)

    def test_existing_output_is_never_overwritten(self):
        runner = self.root / "build.ps1"
        runner.write_text(RUNNER, encoding="ascii")
        output = self.root / "existing.pck"
        output.write_bytes(b"keep me")
        powershell(runner, "-Code", self.package / "LowMemoryPck.cs", "-Base", self.pck,
                   "-Payload", self.package / "payload", "-Output", output, ok=False)
        self.assertEqual(output.read_bytes(), b"keep me")


def real_build(base, package):
    folder = ROOT / "build/lowram_verification"
    folder.mkdir(exist_ok=True)
    runner = folder / "build.ps1"
    runner.write_text(RUNNER, encoding="ascii")
    output = folder / (package.name + ".verified.pck")
    log = powershell(runner, "-Code", package / "LowMemoryPck.cs", "-Base", base,
                     "-Payload", package / "payload", "-Output", output)
    print(log, flush=True)
    (folder / (package.name + ".build.log")).write_text(log, encoding="utf-8")
    expected = directory(base)
    for path in (package / "payload").rglob("*"):
        if path.is_file():
            with path.open("rb") as f:
                digest = hashlib.file_digest(f, "md5").digest()
            expected["res://" + path.relative_to(package / "payload").as_posix()] = (0, path.stat().st_size, digest)
    actual = directory(output)
    assert set(actual) == set(expected), "Resource set differs from base + payload"
    with output.open("rb") as f:
        for name, (offset, size, digest) in actual.items():
            assert (size, digest) == expected[name][1:], name
            f.seek(offset)
            h = hashlib.md5()
            remaining = size
            while remaining:
                chunk = f.read(min(1024 * 1024, remaining))
                assert chunk, name
                h.update(chunk)
                remaining -= len(chunk)
            assert h.digest() == digest, name
    print(f"PASS independent full verification: {len(actual):,} resources; {output.stat().st_size:,} bytes", flush=True)
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--real-base", type=Path)
    parser.add_argument("--package", type=Path, default=PACKAGE)
    args = parser.parse_args()
    if args.real_base:
        real_build(args.real_base, args.package.resolve())
    else:
        unittest.main(argv=[__file__], verbosity=2)
