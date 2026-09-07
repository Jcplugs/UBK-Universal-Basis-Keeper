"""Rebuild the public UBK payload and its checked update manifest; never installs."""
from pathlib import Path
import hashlib
import json
import zipfile
from scripts.release_metadata import validate_build_versions

ROOT = Path(__file__).resolve().parent
ADDON_ROOT = ROOT / 'addon'
UBK = ADDON_ROOT / 'Interface/AddOns/UniversalBasisKeeper'
config = validate_build_versions(ROOT)
version = config['version']
previous = {}
for baseline_path in sorted((ROOT / 'installer').glob('baseline-*.json')):
    baseline = json.loads(baseline_path.read_text(encoding='utf-8'))
    for entry in baseline['files'] + baseline.get('retire', []):
        previous.setdefault(entry['path'], []).extend(entry.get('baselineSha256', []))
        if entry.get('sha256'):
            previous[entry['path']].append(entry['sha256'])
if not previous:
    raise ValueError('Historical update hashes are missing.')

def older_hashes(path):
    return list(dict.fromkeys(previous.get(path, [])))

files = []
for path in sorted(ADDON_ROOT.rglob('*')):
    if not path.is_file():
        continue
    relative = path.relative_to(ADDON_ROOT).as_posix()
    if not relative.startswith('Interface/AddOns/UniversalBasisKeeper/'):
        raise ValueError('Public payload must contain only UniversalBasisKeeper: ' + relative)
    if path.suffix not in {'.lua', '.toc', '.txt', '.md'}:
        raise ValueError('Unexpected distributable file: ' + relative)
    if path.suffix == '.lua':
        source = path.read_text(encoding='utf-8')
        private_markers = ('UBKTimingProbe', 'ubkTimingProbe', 'UBKTIMINGPROBE',
                           '/ubkperf', 'UBK timing active', 'UBK timing stopped',
                           'RetryCollection', 'CancelPendingCollection', 'GetCollectionState')
        if any(marker in source for marker in private_markers):
            raise ValueError('Personal timing or mail hotfix code cannot ship: ' + relative)
    files.append({'path': relative, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'baselineSha256': older_hashes(relative)})

# Historical paths exist here only to retire and restore old local code.
retired = ['Interface/AddOns/GoblinIntelligence/GoblinIntelligence.toc',
           'Interface/AddOns/UBK_Scanners/UBK_Scanners.toc']
manifest = {'version': version, 'files': files,
            'retire': [{'path': path, 'sha256': None, 'baselineSha256': older_hashes(path)} for path in retired],
            'TsmBridge': {'Source': 'Interface/AddOns/UniversalBasisKeeper/UBK_TSMBridge.lua',
                          'Version': 'v4.14.76',
                          'BridgeHashes': older_hashes('Interface/AddOns/UniversalBasisKeeper/UBK_TSMBridge.lua'),
                          'TocHashes': ['bf8643b0f5a45689487f8ea7fb289c56ee240159b2227da08771c7b71e26fcfe']}}
(ROOT / 'manifest.json').write_bytes((json.dumps(manifest, indent=2) + '\n').encode('utf-8'))
# Reviewable source inventory describes the exact addon bytes embedded in the EXE.
(ROOT / 'SOURCE_PATCH_FILES.json').write_bytes((json.dumps([{'name': Path(entry['path']).name, 'sha256': entry['sha256'].upper()} for entry in files], indent=2) + '\n').encode('utf-8'))
with zipfile.ZipFile(ROOT / 'payload.zip', 'w', zipfile.ZIP_DEFLATED, 9) as archive:
    for entry in files:
        info = zipfile.ZipInfo(entry['path'], (2026, 9, 7, 0, 0, 0))
        info.create_system = 3
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        archive.writestr(info, (ADDON_ROOT / entry['path']).read_bytes())

with zipfile.ZipFile(ROOT / 'payload.zip') as archive:
    assert set(archive.namelist()) == {entry['path'] for entry in files}
    for entry in files:
        assert hashlib.sha256(archive.read(entry['path'])).hexdigest() == entry['sha256']
loaded = [line.strip() for line in (UBK / 'UniversalBasisKeeper.toc').read_text(encoding='utf-8').splitlines() if line.strip() and not line.startswith('#')]
assert len(loaded) == len(set(loaded))
assert set(loaded) == {path.name for path in UBK.glob('*.lua')} - {'UBK_TSMBridge.lua'}
assert all((UBK / name).is_file() for name in loaded)
print('PASS: UBK', version, 'payload:', len(files), 'files; exact hashes; one addon; complete TOC loading order.')
