"""Public packages retain UBK integration without personal mail/profiling patches."""
from pathlib import Path
import json
import unittest

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / 'addon/Interface/AddOns/UniversalBasisKeeper'

class PublicPayloadTests(unittest.TestCase):
    def test_no_timing_implementation_or_personal_mail_patch(self):
        forbidden = ('UBKTimingProbe', 'ubkTimingProbe', 'UBKTIMINGPROBE', '/ubkperf',
                     'UBK timing active', 'UBK timing stopped',
                     'TSM.Accounting.Mail.RetryCollection',
                     'TSM.Accounting.Mail.GetCollectionState',
                     'TSM.Accounting.Mail.CancelPendingCollection',
                     'Mail collection paused:')
        for path in ADDON.glob('*.lua'):
            source = path.read_text(encoding='utf-8')
            for marker in forbidden:
                with self.subTest(file=path.name, marker=marker):
                    self.assertNotIn(marker, source)
        self.assertFalse((ROOT / 'addon/Interface/AddOns/TradeSkillMaster').exists())

    def test_payload_keeps_required_integration(self):
        manifest = json.loads((ROOT / 'manifest.json').read_text())
        self.assertEqual(manifest['version'], '1.6.1a')
        self.assertEqual(manifest['TsmBridge']['Source'],
                         'Interface/AddOns/UniversalBasisKeeper/UBK_TSMBridge.lua')
        for row in manifest['files']:
            self.assertTrue(row['path'].startswith('Interface/AddOns/UniversalBasisKeeper/'))
        bridge = (ADDON / 'UBK_TSMBridge.lua').read_text()
        self.assertIn('CustomString.RegisterSource', bridge)
        self.assertIn('function B.InstallPendingPostGuard()', bridge)
        self.assertIn('function B.RecoverOnLogin()', bridge)
        self.assertIn('B.buyLedgerCSV', bridge)

if __name__ == '__main__':
    unittest.main()
