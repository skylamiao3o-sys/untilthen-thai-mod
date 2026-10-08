"""Build the standalone read-only diagnostic without game files or installer payload."""
import hashlib
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FILES = ('CHECK_FILES.bat', 'check_files.ps1', 'ProbePck.cs', 'detect_game.ps1', 'README.txt')
source = ROOT / 'tools/pck_diagnostic'
destination = ROOT / 'build/lowram_release/upload'
destination.mkdir(parents=True, exist_ok=True)
archive = destination / 'UntilThen_CheckFiles_20261009_r1.zip'
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for name in FILES:
        data = (source / name).read_bytes()
        if name.endswith('.bat'):
            data = data.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
        z.writestr(name, data)
with zipfile.ZipFile(archive) as z:
    assert set(z.namelist()) == set(FILES)
    assert z.testzip() is None
with archive.open('rb') as f:
    digest = hashlib.file_digest(f, 'sha256').hexdigest()
print(f'{archive.name}: {archive.stat().st_size} bytes; SHA256 {digest}')
