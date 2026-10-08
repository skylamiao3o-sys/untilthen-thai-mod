"""Install release ZIPs into disposable game copies and independently verify all resources.

The supplied --base is opened read-only. Tests never install into the real game.
"""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

from test_low_memory_installer import ROOT, directory


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--archives', type=Path, default=ROOT / 'build/lowdisk_release')
    args = parser.parse_args()
    baseline = directory(args.base)
    build = ROOT / 'build/lowdisk_verification'
    build.mkdir(parents=True, exist_ok=True)
    for font in ('Itim', 'Sarabun'):
        print(f'{font}: testing packaged installer against a disposable full-size game copy...', flush=True)
        with tempfile.TemporaryDirectory(prefix=font + ' ', dir=build) as temporary:
            folder = Path(temporary).resolve()
            assert folder.is_relative_to(build.resolve())
            package = folder / 'package'
            game = folder / 'game'
            game.mkdir()
            pck = game / 'UntilThen.pck'
            archive = args.archives / f'UntilThen_ThaiMod_{font}_LowDisk_20261009.zip'
            expected = baseline.copy()
            with zipfile.ZipFile(archive) as z:
                # Locally built/validated archives only; still reject path traversal.
                for info in z.infolist():
                    assert (package / info.filename).resolve().is_relative_to(package.resolve())
                    if info.filename.startswith('payload/') and not info.is_dir():
                        with z.open(info) as resource:
                            expected['res://' + info.filename[len('payload/'):]] = (
                                0, info.file_size, hashlib.file_digest(resource, 'md5').digest())
                z.extractall(package)
            shutil.copyfile(args.base, pck)
            # Reproduce the affected PC's bad-backup selection problem without risking any real file.
            (game / 'UntilThen.pck.bak').write_bytes(b'broken old backup')
            result = subprocess.run(['powershell.exe', '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                                     '-File', str(package / 'install_low_memory.ps1'), '-Game', str(game), '-LowDisk'],
                                    capture_output=True, text=True, errors='replace', timeout=600)
            (build / (font + '.install.log')).write_text(result.stdout + result.stderr, encoding='utf-8')
            assert result.returncode == 0, result.stdout + result.stderr
            assert [p.name for p in game.iterdir()] == ['UntilThen.pck']
            actual = directory(pck)
            assert set(actual) == set(expected)
            with pck.open('rb') as f:
                for name, (offset, size, digest) in actual.items():
                    assert (size, digest) == expected[name][1:], name
                    f.seek(offset)
                    md5 = hashlib.md5()
                    remaining = size
                    while remaining:
                        chunk = f.read(min(1024 * 1024, remaining))
                        assert chunk, name
                        md5.update(chunk)
                        remaining -= len(chunk)
                    assert md5.digest() == digest, name
            print(f'PASS {font}: {len(actual):,} resources; {pck.stat().st_size:,} bytes; only one PCK remains.', flush=True)
            for line in result.stdout.splitlines():
                if 'Peak installer' in line:
                    print(line, flush=True)


if __name__ == '__main__':
    main()
