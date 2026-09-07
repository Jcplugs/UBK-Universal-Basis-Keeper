"""Repair documentation images in the approved, mutable UBK 1.6 release."""
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import urllib.parse
import urllib.request
import zipfile

REPO = 'Jcplugs/UBK-Universal-Basis-Keeper'
RELEASE_ID = 383815484
OLD = {
    'installer.exe': 'a88b3930dd06b476219e24e4a441828fbe728de06ae7ad3d750108a4260c21bf',
    'source.zip': '3124fbfae2df842f994889781e942fce968a14b713f26a7274a53d2c9ff0aa30',
    'UBK-1.6.zip': '0986addb2136f9e8966d52f9ce6a74ef31667a98db0e7099d9d6296bb1879a6a',
    'SHA256SUMS.txt': '2bebc813a3b724061295273a3f34762da345e992dbe924e5d15ea1d89cb3205c',
}
DOCS = ['README.md', 'RELEASE.md', 'docs/KHORIUM-WALKTHROUGH.md',
        'docs/screenshots/README.md']
IMAGES = ['ubk-position-overview', 'ubk-khorium-assessment', 'ubk-khorium-recorded',
          'ubk-khorium-live-scan', 'ubk-khorium-tsm-listings']
REMOVED = {'docs/screenshots/' + n + '.jpg' for n in IMAGES}
REMOVED.add('docs/screenshots/ubk-home.png')

def digest(data):
    return hashlib.sha256(data).hexdigest()

def rewrite(data, changes, removed):
    result = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(data)) as src, zipfile.ZipFile(result, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as dst:
        names = set(src.namelist())
        for info in src.infolist():
            if info.filename not in removed:
                dst.writestr(info, changes.get(info.filename, src.read(info.filename)))
        for name in sorted(changes.keys() - names):
            info = zipfile.ZipInfo(name, (2026, 9, 7, 0, 0, 0))
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            dst.writestr(info, changes[name])
    output = result.getvalue()
    with zipfile.ZipFile(io.BytesIO(data)) as before, zipfile.ZipFile(io.BytesIO(output)) as after:
        assert after.testzip() is None
        assert not (set(after.namelist()) & removed)
        for name in before.namelist():
            if name not in removed:
                assert after.read(name) == changes.get(name, before.read(name)), name
        for name, value in changes.items():
            assert after.read(name) == value, name
    return output

def build(root):
    for name in ['source.zip', 'UBK-1.6.zip', 'installer.exe']:
        assert digest((root / name).read_bytes()) == OLD[name], name
    changes = {n: (root / n).read_bytes() for n in DOCS}
    for name in IMAGES:
        path = 'docs/screenshots/' + name + '.png'
        changes[path] = (root / path).read_bytes()
    source = rewrite((root / 'source.zip').read_bytes(), changes, REMOVED)
    prefix = 'UBK-1.6/'
    bundle_changes = {prefix + n: b for n, b in changes.items()}
    bundle_changes[prefix + 'source.zip'] = source
    removed = {prefix + n for n in REMOVED}
    with zipfile.ZipFile(root / 'UBK-1.6.zip') as archive:
        members = {n: archive.read(n) for n in archive.namelist()
                   if n not in removed and n != prefix + 'SHA256SUMS.txt'}
    members.update(bundle_changes)
    sums = ''.join(digest(b) + '  ' + n[len(prefix):] + '\n' for n, b in sorted(members.items())).encode()
    bundle_changes[prefix + 'SHA256SUMS.txt'] = sums
    bundle = rewrite((root / 'UBK-1.6.zip').read_bytes(), bundle_changes, removed)
    return {'source.zip': source, 'UBK-1.6.zip': bundle, 'SHA256SUMS.txt': sums}

def main():
    root = Path(__file__).resolve().parents[1]
    files = build(root)
    expected = {name: 'sha256:' + digest(data) for name, data in files.items()}
    token = os.environ['GITHUB_TOKEN']
    api = 'https://api.github.com/repos/' + REPO
    headers = {'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
               'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'UBK-Documentation-Repair'}
    def request(path, method='GET', obj=None, data=None):
        url = path if path.startswith('https://') else api + path
        raw = json.dumps(obj).encode() if obj is not None else data
        req = urllib.request.Request(url, data=raw, method=method,
            headers={**headers, 'Content-Type': 'application/json' if data is None else 'application/octet-stream'})
        with urllib.request.urlopen(req, timeout=60) as response:
            result = response.read()
            return json.loads(result) if result else None
    release = request(f'/releases/{RELEASE_ID}')
    if release['tag_name'] != 'v1.6' or release['draft'] or release.get('immutable'):
        raise RuntimeError('Expected mutable published UBK 1.6 release')
    current = {a['name']: a for a in release['assets']}
    if current['installer.exe']['digest'] != 'sha256:' + OLD['installer.exe']:
        raise RuntimeError('Published installer changed; stop documentation repair')
    for name in files:
        if name in current and current[name].get('digest') not in {'sha256:' + OLD[name], expected[name]}:
            raise RuntimeError('Unexpected published asset: ' + name)
    # Verify every replacement upload before replacing any public asset name.
    staged = {}
    for name, data in files.items():
        if name in current and current[name].get('digest') == expected[name]:
            continue
        temp = name + '.window-crops'
        existing = next((a for a in release['assets'] if a['name'] == temp), None)
        if existing is None:
            existing = request('https://uploads.github.com/repos/' + REPO +
                f'/releases/{RELEASE_ID}/assets?name=' + urllib.parse.quote(temp), 'POST', data=data)
        if existing.get('digest') != expected[name] or existing['size'] != len(data) or existing['state'] != 'uploaded':
            raise RuntimeError('Replacement upload mismatch: ' + name)
        staged[name] = existing['id']
    for name, data in files.items():
        (root / ('DOWNLOAD-SHA256SUMS.txt' if name == 'SHA256SUMS.txt' else name)).write_bytes(data)
    def git(*args, env=None):
        return subprocess.check_output(['git', *args], cwd=root, env=env, text=True).strip()
    git('config', 'user.name', 'github-actions[bot]')
    git('config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com')
    git('add', 'source.zip', 'UBK-1.6.zip', 'DOWNLOAD-SHA256SUMS.txt')
    if git('diff', '--cached', '--name-only'):
        git('commit', '-m', 'Correct window crops in downloadable UBK documentation')
        env = os.environ.copy()
        encoded = base64.b64encode(('x-access-token:' + token).encode()).decode()
        env.update(GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='http.https://github.com/.extraheader',
                   GIT_CONFIG_VALUE_0='AUTHORIZATION: basic ' + encoded)
        git('push', 'origin', 'HEAD:main', env=env)
    for name, asset_id in staged.items():
        latest = request(f'/releases/{RELEASE_ID}')
        if latest.get('immutable') or latest['draft']:
            raise RuntimeError('Release state changed during repair')
        old = next((a for a in latest['assets'] if a['name'] == name), None)
        if old:
            if old.get('digest') != 'sha256:' + OLD[name]:
                raise RuntimeError('Canonical asset changed during repair')
            request('/releases/assets/' + str(old['id']), 'DELETE')
        request('/releases/assets/' + str(asset_id), 'PATCH', obj={'name': name})
    request(f'/releases/{RELEASE_ID}', 'PATCH', obj={'body': (root / 'RELEASE.md').read_text(encoding='utf-8')})
    final = request(f'/releases/{RELEASE_ID}')
    for name, value in expected.items():
        assert next(a for a in final['assets'] if a['name'] == name)['digest'] == value
    print('PASS: public documentation images and ZIPs corrected; installer bytes preserved')

if __name__ == '__main__':
    main()
