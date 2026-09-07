"""Replace the mutable 1.6 downloads with the tested prospecting hotfix."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPO = 'Jcplugs/UBK-Universal-Basis-Keeper'
RELEASE_ID = 383815484
OLD = {
    'installer.exe': 'sha256:a88b3930dd06b476219e24e4a441828fbe728de06ae7ad3d750108a4260c21bf',
    'source.zip': 'sha256:9a0e0dd4e590fafd419f5e2bbc6107681e008450446c2fd00f50f17aae41e32d',
    'UBK-1.6.zip': 'sha256:b759f50e5d7778f20323e945a6bc8d7c534e97b868d9dcd609f4626749b552de',
    'SHA256SUMS.txt': 'sha256:83ad76aec82dc116eceb5bc7804cb6bcd724aebb71e790b30fac8550776f6bf6',
}
CORE = 'Interface/AddOns/UniversalBasisKeeper/UniversalBasisKeeper.lua'

def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()

def checked_files():
    folder = ROOT / 'dist/UBK-1.6'
    files = {name: (ROOT / 'dist' / name if name == 'UBK-1.6.zip' else folder / name).read_bytes() for name in OLD}
    core = (ROOT / 'addon' / CORE).read_bytes()
    assert b'local quantity = GetRealmQuantityForItem(item)' in core
    assert b'tonumber(GetRealmQuantityForItem(item))' not in core
    assert b'UBKPersonalRecovery' not in core
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    entry = next(x for x in manifest['files'] if x['path'] == CORE)
    assert entry['sha256'] == hashlib.sha256(core).hexdigest()
    baseline = json.loads((ROOT / 'installer/baseline-1.6-before-prospect-hotfix.json').read_text())
    old_core = next(x for x in baseline['files'] if x['path'] == CORE)['sha256']
    assert old_core in entry['baselineSha256'], 'Published 1.6 must be an accepted upgrade'
    with zipfile.ZipFile(io.BytesIO(files['source.zip'])) as source:
        assert source.read('addon/' + CORE) == core
        assert source.read('manifest.json') == (ROOT / 'manifest.json').read_bytes()
        assert 'tests/prospect_observer_test.lua' in source.namelist()
        assert not any('PersonalRecovery' in n or 'personal_recovery_test' in n for n in source.namelist())
    with zipfile.ZipFile(ROOT / 'payload.zip') as payload:
        assert payload.read(CORE) == core
    with zipfile.ZipFile(io.BytesIO(files['UBK-1.6.zip'])) as bundle:
        assert bundle.read('UBK-1.6/' + CORE) == core
        for name in ['source.zip', 'installer.exe', 'SHA256SUMS.txt']:
            assert bundle.read('UBK-1.6/' + name) == files[name]
        for line in files['SHA256SUMS.txt'].decode().splitlines():
            sha, name = line.split('  ', 1)
            assert hashlib.sha256(bundle.read('UBK-1.6/' + name)).hexdigest() == sha
    assert files['installer.exe'][:2] == b'MZ'
    assert digest(files['installer.exe']) != OLD['installer.exe']
    return files

def main():
    files = checked_files()
    expected = {name: digest(data) for name, data in files.items()}
    if '--verify-only' in sys.argv:
        print('PASS: public hotfix source, standalone addon, payload, upgrade baseline and ZIP checksums agree')
        return
    assert os.environ['GITHUB_REPOSITORY'] == REPO
    assert os.environ['GITHUB_REF'] == 'refs/heads/main'
    api = 'https://api.github.com/repos/' + REPO
    headers = {'Authorization': 'Bearer ' + os.environ['GITHUB_TOKEN'], 'Accept': 'application/vnd.github+json',
               'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'UBK-Prospecting-Hotfix'}
    def request(path, method='GET', obj=None, data=None):
        url = path if path.startswith('https://') else api + path
        raw = json.dumps(obj).encode() if obj is not None else data
        req = urllib.request.Request(url, data=raw, method=method,
            headers={**headers, 'Content-Type': 'application/json' if data is None else 'application/octet-stream'})
        with urllib.request.urlopen(req, timeout=60) as response:
            result = response.read()
            return json.loads(result) if result else None
    def release():
        value = request(f'/releases/{RELEASE_ID}')
        if value['tag_name'] != 'v1.6' or value['draft'] or value.get('immutable') or not value.get('published_at'):
            raise RuntimeError('Expected mutable published UBK 1.6 release')
        return value
    current = release()
    for name in files:
        old = next((a for a in current['assets'] if a['name'] == name), None)
        if old and old.get('digest') not in {OLD[name], expected[name]}:
            raise RuntimeError('Unexpected public asset changed: ' + name)
    # All builds and fixture tests finish before this first write. Stage every
    # upload and verify its digest before replacing a canonical download name.
    staged = {}
    for name, data in files.items():
        current = release()
        if any(a['name'] == name and a.get('digest') == expected[name] for a in current['assets']):
            continue
        temp = name + '.prospecting-hotfix-' + os.environ['GITHUB_RUN_ID']
        item = next((a for a in current['assets'] if a['name'] == temp), None)
        if item is None:
            item = request('https://uploads.github.com/repos/' + REPO +
                f'/releases/{RELEASE_ID}/assets?name=' + urllib.parse.quote(temp), 'POST', data=data)
        if item.get('digest') != expected[name] or item['size'] != len(data) or item['state'] != 'uploaded':
            raise RuntimeError('Replacement upload mismatch: ' + name)
        staged[name] = item['id']
    subprocess.run([sys.executable, str(ROOT / 'scripts/sync_github_downloads.py')], cwd=ROOT, check=True)
    for name, asset_id in staged.items():
        current = release()
        old = next((a for a in current['assets'] if a['name'] == name), None)
        if old:
            if old.get('digest') != OLD[name]:
                raise RuntimeError('Canonical asset changed during hotfix')
            request('/releases/assets/' + str(old['id']), 'DELETE')
        request('/releases/assets/' + str(asset_id), 'PATCH', obj={'name': name})
    request(f'/releases/{RELEASE_ID}', 'PATCH', obj={'body': (ROOT / 'RELEASE.md').read_text(encoding='utf-8')})
    final = release()
    for name, sha in expected.items():
        assert next(a for a in final['assets'] if a['name'] == name)['digest'] == sha
    print('PASS: published installer, source, standalone addon and full bundle contain prospecting hotfix 1')
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as out:
        out.write('Prospecting hotfix 1 verified in every [UBK 1.6 download](' + final['html_url'] + ').\n')

if __name__ == '__main__':
    main()
