"""Build low-disk ZIPs while preserving every published v1.0 payload byte.

The original archives are supplied separately and are never committed to the repo.
"""
import argparse
import hashlib
from pathlib import Path
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / ('ThaiMod' if (ROOT / 'ThaiMod').is_dir() else 'installer')
RELEASE_HASHES = {
    'Itim': '3a8cb87f8ee3a0ae5ad460f2593e148d19f69fe02e80684161ce923c37ea87ab',
    'Sarabun': '65ff05a86513f568e18e4f78442f6f3d037ebb8e832ca080c8c5d4afde47f050',
}
HELPERS = {
    'INSTALL.bat': 'INSTALL_LOW_DISK.bat',
    'INSTALL_LOW_DISK.bat': 'INSTALL_LOW_DISK.bat',
    'INSTALL_KEEP_BACKUP.bat': 'INSTALL.bat',
    'INSTALL_README.txt': 'LOW_DISK_README.txt',
    'LOW_DISK_README.txt': 'LOW_DISK_README.txt',
    'BACKUP_MODE_README.txt': 'INSTALL_README.txt',
    **{name: name for name in ('install_low_memory.ps1', 'LowMemoryPck.cs', 'detect_game.ps1',
                              'validate_pck.ps1', 'steam_guard.ps1', 'UNINSTALL.bat')},
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--originals', type=Path, default=ROOT / 'build/dist')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/lowdisk_release')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    sums = []
    for font in ('Itim', 'Sarabun'):
        original = args.originals / f'UntilThen_ThaiMod_{font}.zip'
        with original.open('rb') as f:
            assert hashlib.file_digest(f, 'sha256').hexdigest() == RELEASE_HASHES[font]
        archive = args.output / f'UntilThen_ThaiMod_{font}_LowDisk_20261009.zip'
        helpers = {}
        for target, source in HELPERS.items():
            data = (SOURCE / source).read_bytes()
            if target.endswith('.bat'):
                data = data.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
            helpers[target] = data
        with zipfile.ZipFile(original) as old:
            payload = sorted(i.filename for i in old.infolist()
                             if i.filename.startswith('payload/') and not i.is_dir())
            manifest = old.read('payload.manifest')
            assert len(payload) == int(manifest.strip())
            with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
                for name, data in helpers.items():
                    z.writestr(name, data)
                z.writestr('payload.manifest', manifest)
                for name in payload:
                    with old.open(name) as src, z.open(name, 'w', force_zip64=True) as dst:
                        shutil.copyfileobj(src, dst, 1024 * 1024)
            with zipfile.ZipFile(archive) as z:
                assert z.testzip() is None
                assert set(z.namelist()) == set(helpers) | set(payload) | {'payload.manifest'}
                for name, data in helpers.items():
                    assert z.read(name) == data, name
                for name in payload:
                    with old.open(name) as src, z.open(name) as dst:
                        assert hashlib.file_digest(src, 'sha256').digest() == hashlib.file_digest(dst, 'sha256').digest(), name
        with archive.open('rb') as f:
            digest = hashlib.file_digest(f, 'sha256').hexdigest()
        sums.append(f'{digest}  {archive.name}')
        print(f'{archive.name}: {archive.stat().st_size:,} bytes; {len(payload)} unchanged payload files')
    (args.output / 'SHA256SUMS.txt').write_text('\n'.join(sums) + '\n', encoding='ascii')


if __name__ == '__main__':
    main()
