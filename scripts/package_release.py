"""Collect the complete source and installer into the downloadable release folder."""
from pathlib import Path
import hashlib
import json
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIRS = {'addon', 'installer', 'tests', 'docs', 'scripts', '.github'}
ROOT_FILES = {
    'README.md', 'README.txt', 'USER_GUIDE.md', 'UBK_RELEASE_NOTES.txt',
    'DEVELOPMENT_NOTES.md', 'STRESS-TESTS.md', 'VERIFICATION.txt',
    'LUA_TEST_RESULTS.txt', 'INSTALLER_TEST_RESULTS.txt', 'START-HERE.txt',
    'BUILD.txt', 'Build.cmd', 'rebuild_payload.py', 'manifest.json',
    'release.json', '.gitignore', '.gitattributes', 'SOURCE_PATCH_FILES.json', 'RELEASE.md',
}

def source_files(root=ROOT):
    for p in sorted(root.rglob('*')):
        rel = p.relative_to(root)
        if not p.is_file() or '__pycache__' in rel.parts or p.suffix in {'.pyc', '.exe'}:
            continue
        if (len(rel.parts) == 1 and p.name in ROOT_FILES) or rel.parts[0] in SOURCE_DIRS:
            yield p

def archive(path, members):
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as out:
        for name, data in members:
            entry = zipfile.ZipInfo(name, (2026, 9, 7, 0, 0, 0))
            entry.create_system = 3
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            out.writestr(entry, data)
    with zipfile.ZipFile(path) as check:
        if check.testzip() is not None:
            raise ValueError('ZIP verification failed')

def main():
    config = json.loads((ROOT / 'release.json').read_text())
    version = config['version']
    if version != '1.6' or config['draft'] is not True:
        raise ValueError('This packaging revision is for the UBK 1.6 draft')
    setup = ROOT / f'UBK-{version}-Setup.exe'
    if not setup.is_file() or setup.read_bytes()[:2] != b'MZ':
        raise ValueError('Build the Windows installer before packaging')
    folder = ROOT / 'dist' / f'UBK-{version}'
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True, exist_ok=True)
    source = folder / 'source.zip'
    members = [(p.relative_to(ROOT).as_posix(), p.read_bytes()) for p in source_files()]
    archive(source, members)
    shutil.copyfile(setup, folder / 'installer.exe')
    for name in ('START-HERE.txt', 'UBK_RELEASE_NOTES.txt', 'README.md',
                 'USER_GUIDE.md', 'RELEASE.md', 'BUILD.txt', 'VERIFICATION.txt',
                 'STRESS-TESTS.md', 'LUA_TEST_RESULTS.txt', 'INSTALLER_TEST_RESULTS.txt'):
        shutil.copyfile(ROOT / name, folder / name)
    shutil.copytree(ROOT / 'addon/Interface', folder / 'Interface', dirs_exist_ok=True)
    shutil.copytree(ROOT / 'docs', folder / 'docs', dirs_exist_ok=True)
    sums = ''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(folder).as_posix()}\n'
                   for p in sorted(folder.rglob('*')) if p.is_file() and p.name != 'SHA256SUMS.txt')
    (folder / 'SHA256SUMS.txt').write_text(sums, encoding='utf-8')
    bundle = ROOT / 'dist' / f'UBK-{version}.zip'
    archive(bundle, [(f'{folder.name}/{p.relative_to(folder).as_posix()}', p.read_bytes()) for p in sorted(folder.rglob('*')) if p.is_file()])
    print(f'Packaged: {bundle.name}; installer + source in {folder.name}/')

if __name__ == '__main__':
    main()
