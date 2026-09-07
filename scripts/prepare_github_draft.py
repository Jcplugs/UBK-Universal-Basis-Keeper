"""Prepare draft release assets in GitHub Actions. This script cannot publish."""
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]

def require_draft(release):
    if release.get('draft') is not True or release.get('published_at') is not None:
        raise RuntimeError('Release is published or not explicitly draft; no changes allowed')
    return release

def draft_payload(config, commit, body):
    if config.get('draft') is not True:
        raise RuntimeError('Only draft releases are supported')
    return dict(tag_name=config['tag'], target_commitish=commit,
                name=config['title'], body=body, draft=True,
                prerelease=False, make_latest='false', generate_release_notes=False)

def main():
    config = json.loads((ROOT / 'release.json').read_text())
    repo = os.environ['GITHUB_REPOSITORY']
    commit = os.environ.get('UBK_RELEASE_COMMIT') or os.environ['GITHUB_SHA']
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo) or not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise RuntimeError('Invalid repository or build commit')
    base = f'https://api.github.com/repos/{repo}'
    headers = {'Authorization': 'Bearer ' + os.environ['GITHUB_TOKEN'],
               'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28',
               'User-Agent': 'UBK-Draft-Release'}
    def request(url, method='GET', obj=None, data=None, content_type='application/json'):
        body = json.dumps(obj).encode() if obj is not None else data
        req = urllib.request.Request(url, data=body, headers={**headers, 'Content-Type': content_type}, method=method)
        with urllib.request.urlopen(req, timeout=90) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    body = (ROOT / 'RELEASE.md').read_text(encoding='utf-8')
    payload = draft_payload(config, commit, body)
    existing = []
    page = 1
    while True:
        releases = request(f'{base}/releases?per_page=100&page={page}')
        existing.extend(r for r in releases if r.get('tag_name') == config['tag'])
        if len(releases) < 100:
            break
        page += 1
    if len(existing) > 1:
        raise RuntimeError('Multiple releases match this tag')
    if existing:
        release = require_draft(request(f'{base}/releases/{existing[0]["id"]}'))
        release = require_draft(request(f'{base}/releases/{release["id"]}', 'PATCH', obj=payload))
    else:
        release = require_draft(request(f'{base}/releases', 'POST', obj=payload))
    release_id = release['id']
    version = config['version']
    folder = ROOT / 'dist' / f'UBK-{version}'
    assets = [ROOT / 'dist' / f'UBK-{version}.zip', folder / 'installer.exe',
              folder / 'source.zip', folder / 'SHA256SUMS.txt']
    for p in assets:
        require_draft(request(f'{base}/releases/{release_id}'))
        current = request(f'{base}/releases/{release_id}/assets?per_page=100')
        data = p.read_bytes()
        digest = 'sha256:' + hashlib.sha256(data).hexdigest()
        same_name = [a for a in current if a['name'] == p.name]
        if same_name and same_name[0].get('digest') == digest:
            continue
        for old in same_name:
            require_draft(request(f'{base}/releases/{release_id}'))
            request(f'{base}/releases/assets/{old["id"]}', 'DELETE')
        require_draft(request(f'{base}/releases/{release_id}'))
        kind = 'application/zip' if p.suffix == '.zip' else 'application/octet-stream'
        uploaded = request(f'https://uploads.github.com/repos/{repo}/releases/{release_id}/assets?name={urllib.parse.quote(p.name)}',
                           'POST', data=data, content_type=kind)
        if uploaded.get('state') != 'uploaded' or uploaded.get('size') != len(data):
            raise RuntimeError('Asset upload is incomplete')
        if uploaded.get('digest') and uploaded['digest'] != digest:
            raise RuntimeError('Uploaded asset digest mismatch')
    final = require_draft(request(f'{base}/releases/{release_id}'))
    if not {p.name for p in assets}.issubset({a['name'] for a in final['assets']}):
        raise RuntimeError('Draft is missing required assets')
    print('Draft ready; unpublished: ' + final['html_url'])
    (ROOT / '.github-release-result.json').write_text(json.dumps({'url': final['html_url'], 'draft': True, 'id': release_id}))

if __name__ == '__main__':
    main()
