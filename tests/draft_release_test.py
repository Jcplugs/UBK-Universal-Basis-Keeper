"""Protect the requested unpublished release boundary without network calls."""
import importlib.util
from pathlib import Path
import unittest
spec = importlib.util.spec_from_file_location('draft', Path(__file__).resolve().parents[1]/'scripts/prepare_github_draft.py')
draft = importlib.util.module_from_spec(spec)
spec.loader.exec_module(draft)
class DraftReleaseTest(unittest.TestCase):
    def test_published_and_ambiguous_releases_are_rejected(self):
        for value in ({}, {'draft':False}, {'draft':True,'published_at':'2026-09-07'}, {'draft':'true'}):
            with self.assertRaises(RuntimeError): draft.require_draft(value)
        draft.require_draft({'draft':True,'published_at':None})
    def test_payload_never_publishes_or_marks_latest(self):
        config={'draft':True,'tag':'v1.6','title':'UBK 1.6'}
        payload=draft.draft_payload(config,'a'*40,'notes')
        self.assertIs(payload['draft'],True)
        self.assertEqual(payload['make_latest'],'false')
        config['draft']=False
        with self.assertRaises(RuntimeError): draft.draft_payload(config,'a'*40,'notes')
if __name__=='__main__': unittest.main()
