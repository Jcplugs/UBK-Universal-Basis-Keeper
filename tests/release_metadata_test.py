"""Exercise release/version guards and upgrade hashes using temporary sources."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.release_metadata import load_release_config, validate_build_versions, windows_version


class ReleaseMetadataTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.addon = self.root / 'addon/Interface/AddOns/UniversalBasisKeeper'
        self.addon.mkdir(parents=True)
        for name in ('release.json', 'rebuild_payload.py', 'scripts/release_metadata.py',
                     'installer/Installer.cs', 'installer/Installer.manifest',
                     'installer/baseline-1.6-published.json'):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        (self.addon / 'UniversalBasisKeeper.toc').write_text('## Version: 1.6.1a\nUniversalBasisKeeper.lua\n', encoding='utf-8')
        (self.addon / 'UniversalBasisKeeper.lua').write_text('local loaded = true\n', encoding='utf-8')
        (self.addon / 'UBK_TSMBridge.lua').write_text('local bridge = true\n', encoding='utf-8')

    def rebuild(self):
        return subprocess.run([sys.executable, str(self.root / 'rebuild_payload.py')],
                              cwd=self.root, text=True, capture_output=True)

    def config(self):
        return json.loads((self.root / 'release.json').read_text(encoding='utf-8'))

    def write_config(self, config):
        (self.root / 'release.json').write_text(json.dumps(config), encoding='utf-8')

    def test_public_letter_revision_has_numeric_windows_version(self):
        for label, expected in [('1.6', '1.6.0.0'), ('1.6.1', '1.6.1.0'),
                                ('1.6.1a', '1.6.1.1'), ('1.6.1z', '1.6.1.26')]:
            self.assertEqual(windows_version(label), expected)
        for label in (None, '1.6a', '1.6.1a.0', '../1.6', '01.6.1a', '1.65535.1a'):
            with self.assertRaises(ValueError):
                windows_version(label)
        validate_build_versions(self.root)

    def test_label_tag_windows_version_and_draft_must_agree(self):
        original = self.config()
        for field, value in [('version', '1.6.1b'), ('windows_version', '1.6.1a.0'),
                             ('tag', 'v1.6'), ('title', 'UBK 1.6'),
                             ('draft', False), ('draft', 'true')]:
            self.write_config({**original, field: value})
            with self.assertRaises(ValueError, msg=field):
                load_release_config(self.root)

    def test_mismatched_addon_or_assembly_cannot_regenerate_payload(self):
        for name in ('manifest.json', 'payload.zip', 'SOURCE_PATCH_FILES.json'):
            (self.root / name).write_bytes(b'previous build')
        for name, old, new in (
            ('addon/Interface/AddOns/UniversalBasisKeeper/UniversalBasisKeeper.toc', '1.6.1a', '1.6'),
            ('installer/Installer.cs', 'AssemblyVersion("1.6.1.1")', 'AssemblyVersion("1.6.0.0")'),
            ('installer/Installer.cs', 'AssemblyFileVersion("1.6.1.1")', 'AssemblyFileVersion("1.6.0.0")'),
            ('installer/Installer.cs', 'AssemblyInformationalVersion("1.6.1a")', 'AssemblyInformationalVersion("1.6")'),
            ('installer/Installer.manifest', 'version="1.6.1.1"', 'version="1.6.0.0"'),
        ):
            path = self.root / name
            original = path.read_text(encoding='utf-8')
            self.assertIn(old, original)
            path.write_text(original.replace(old, new), encoding='utf-8')
            result = self.rebuild()
            self.assertNotEqual(result.returncode, 0, name)
            for output in ('manifest.json', 'payload.zip', 'SOURCE_PATCH_FILES.json'):
                self.assertEqual((self.root / output).read_bytes(), b'previous build')
            path.write_text(original, encoding='utf-8')

    def test_rebuilt_manifest_accepts_published_1_6_and_preserves_bridge_contract(self):
        result = self.rebuild()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.root / 'manifest.json').read_text(encoding='utf-8'))
        baseline = json.loads((self.root / 'installer/baseline-1.6-published.json').read_text(encoding='utf-8'))
        previous = {entry['path']: entry for entry in baseline['files']}
        self.assertEqual(manifest['version'], '1.6.1a')
        for entry in manifest['files']:
            self.assertIn(previous[entry['path']]['sha256'], entry['baselineSha256'])
            self.assertTrue(entry['path'].startswith('Interface/AddOns/UniversalBasisKeeper/'))
        for field in ('Source', 'Version', 'TocHashes'):
            self.assertEqual(manifest['TsmBridge'][field], baseline['TsmBridge'][field])
        bridge = 'Interface/AddOns/UniversalBasisKeeper/UBK_TSMBridge.lua'
        self.assertIn(previous[bridge]['sha256'], manifest['TsmBridge']['BridgeHashes'])

    def test_private_timing_or_mail_hotfix_cannot_enter_payload(self):
        path = self.addon / 'UniversalBasisKeeper.lua'
        for marker in ('UBKTimingProbe', 'ubkTimingProbe', 'UBKTIMINGPROBE', '/ubkperf',
                       'UBK timing active', 'UBK timing stopped', 'RetryCollection',
                       'CancelPendingCollection', 'GetCollectionState'):
            path.write_text('-- ' + marker + '\n', encoding='utf-8')
            result = self.rebuild()
            self.assertNotEqual(result.returncode, 0, marker)
            self.assertIn('Personal timing or mail hotfix code cannot ship', result.stderr)
            self.assertFalse((self.root / 'payload.zip').exists())


if __name__ == '__main__':
    unittest.main()
