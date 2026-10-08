"""Read-only diagnostic tests using independent PCK fixtures, never the real game."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_low_memory_installer import ROOT, PACKAGE, directory, fixture, powershell


class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        (ROOT / 'build').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='diagnostic test ', dir=ROOT / 'build')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.package = self.root / 'check [files] & safe!'
        self.package.mkdir()
        for name in ('check_files.ps1', 'ProbePck.cs', 'CHECK_FILES.bat'):
            shutil.copy2(ROOT / 'tools/pck_diagnostic' / name, self.package)
        shutil.copy2(PACKAGE / 'detect_game.ps1', self.package)
        self.game = self.root / 'Game [test] & safe!'
        self.game.mkdir()
        self.pck = self.game / 'UntilThen.pck'
        self.original = {
            'res://.godot/extension_list.cfg': b'res://addons/fmod/fmod.gdextension\n',
            'res://empty': b'',
            'res://unicode/ภาษาไทย.txt': b'abc' * 40000,
            'res://large': b'L' * (1024 * 1024 + 1),
        }
        fixture(self.pck, self.original)

    def snapshot(self):
        return {p.name: (hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mtime_ns)
                for p in self.game.iterdir()}

    def check(self):
        before = self.snapshot()
        result = powershell(self.package / 'check_files.ps1', '-Game', self.game)
        self.assertEqual(self.snapshot(), before, 'Diagnostic modified the game folder')
        # The useful report must appear in the file, not just native console output.
        log = (self.package / 'diagnostic.log').read_text(encoding='utf-8-sig')
        self.assertIn('SAMPLE SUMMARY:', log)
        self.assertIn('MD5 self-test: PASS', log)
        return result, log

    def test_valid_relative_and_absolute_offsets(self):
        for relative in (True, False):
            with self.subTest(relative=relative):
                fixture(self.pck, self.original, relative=relative)
                _, log = self.check()
                self.assertIn('SAMPLE SUMMARY: checked=3; mismatches=0', log)
                self.assertIn('SKIPPED: sample is larger than 1 MB', log)
                self.assertIn('target found: True', log)

    def test_bad_backup_is_identified_without_altering_live_file(self):
        backup = self.game / 'UntilThen.pck.bak'
        shutil.copy2(self.pck, backup)
        offset, _, _ = directory(backup)['res://.godot/extension_list.cfg']
        with backup.open('r+b') as f:
            f.seek(offset)
            f.write(b'X')
        _, log = self.check()
        self.assertIn('Source the low-memory installer would select: ' + str(backup), log)
        self.assertIn('SAMPLE SUMMARY: checked=3; mismatches=0', log)
        self.assertIn('SAMPLE SUMMARY: checked=3; mismatches=1', log)
        damaged = b'X' + self.original['res://.godot/extension_list.cfg'][1:]
        self.assertIn('actual=' + hashlib.md5(damaged).hexdigest(), log)

    def test_truncated_backup_reports_error_and_keeps_live_report(self):
        (self.game / 'UntilThen.pck.bak').write_bytes(b'GDPC')
        _, log = self.check()
        self.assertIn('READ ERROR: EndOfStreamException:', log)
        self.assertIn('SAMPLE SUMMARY: checked=3; mismatches=0', log)

    def test_target_is_found_even_outside_first_eight_entries(self):
        entries = {f'res://{i}.txt': b'abc' for i in range(20)}
        entries.update(self.original)
        fixture(self.pck, entries)
        _, log = self.check()
        self.assertIn('RESOURCE: res://.godot/extension_list.cfg', log)
        self.assertIn('SAMPLE SUMMARY: checked=9; mismatches=0', log)

    def test_bat_launch_records_log(self):
        before = self.snapshot()
        command = f'cmd.exe /d /s /c ""{self.package / "CHECK_FILES.bat"}" -Game "{self.game}""'
        run = subprocess.run(command, input='\n', text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             errors='replace', timeout=30)
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertEqual(self.snapshot(), before)
        log = (self.package / 'diagnostic.log').read_text(encoding='utf-8-sig')
        self.assertIn('SAMPLE SUMMARY: checked=3; mismatches=0', log)


if __name__ == '__main__':
    unittest.main(verbosity=2)
