"""Keep repository downloads identical to the tested draft release assets."""
import base64
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.release_metadata import load_release_config

def main():
    config = load_release_config(ROOT)
    version = config['version']
    folder = ROOT / 'dist' / f'UBK-{version}'
    for source, target in (
        (folder / 'installer.exe', ROOT / 'installer.exe'),
        (folder / 'source.zip', ROOT / 'source.zip'),
        (folder / 'SHA256SUMS.txt', ROOT / 'DOWNLOAD-SHA256SUMS.txt'),
        (ROOT / 'dist' / f'UBK-{version}.zip', ROOT / f'UBK-{version}.zip'),
    ):
        shutil.copyfile(source, target)
    shutil.copytree(folder / 'Interface', ROOT / 'Interface', dirs_exist_ok=True)
    def git(*args, env=None):
        return subprocess.check_output(['git', *args], cwd=ROOT, env=env, text=True).strip()
    git('config', 'user.name', 'github-actions[bot]')
    git('config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com')
    git('add', '-f', 'installer.exe', 'source.zip', f'UBK-{version}.zip',
        'DOWNLOAD-SHA256SUMS.txt', 'Interface', 'manifest.json',
        'SOURCE_PATCH_FILES.json', 'LUA_TEST_RESULTS.txt', 'INSTALLER_TEST_RESULTS.txt')
    if git('diff', '--cached', '--name-only'):
        git('commit', '-m', f'Update tested UBK {version} release downloads')
        env = os.environ.copy()
        encoded = base64.b64encode(('x-access-token:' + env['GITHUB_TOKEN']).encode()).decode()
        env.update(GIT_CONFIG_COUNT='1',
                   GIT_CONFIG_KEY_0='http.https://github.com/.extraheader',
                   GIT_CONFIG_VALUE_0='AUTHORIZATION: basic ' + encoded)
        git('push', 'origin', 'HEAD:main', env=env)
    commit = git('rev-parse', 'HEAD')
    with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as out:
        out.write(f'UBK_RELEASE_COMMIT={commit}\n')
    print('Repository downloads match the tested draft build: ' + commit)

if __name__ == '__main__':
    main()
