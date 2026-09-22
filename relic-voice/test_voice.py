import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from corrections import apply_rules, finish_text
import model_store


class CorrectionsTest(unittest.TestCase):
    def test_longest_scoped_whole_phrase_no_cascade(self):
        rules = [dict(heard='cloud', replacement='sky'),
                 dict(heard='cloud code', replacement='Claude Code'),
                 dict(heard='Claude Code', replacement='wrong'),
                 dict(heard='cloud code', replacement='Scoped', app='code.exe')]
        self.assertEqual(apply_rules('cloud code cloud cloudy', rules)[0], 'Claude Code sky cloudy')
        self.assertEqual(apply_rules('cloud code', rules, 'code.exe')[0], 'Scoped')

    def test_spelling_does_not_invent_homophones(self):
        config = {'vocabulary': ['Claude', 'PostgreSQL']}
        self.assertEqual(finish_text('ask claude about postgresql', config)[0], 'ask Claude about PostgreSQL')
        self.assertEqual(finish_text('the cat clawed the sofa', config)[0], 'the cat clawed the sofa')

    def test_explicit_spelling_survives_punctuation(self):
        class Formatter:
            def restore(self, text): return text.lower() + '.', {}
        config = {'corrections': [dict(heard='cloud code', replacement='Claude Code')]}
        self.assertEqual(finish_text('ask cloud code', config, Formatter())[0], 'ask Claude Code.')

    def test_punctuation_cannot_change_negation_or_numbers(self):
        class BadFormatter:
            def restore(self, text): return 'do transfer 200', {}
        text, _, warning = finish_text('do not transfer 20', {}, BadFormatter())
        self.assertEqual(text, 'do not transfer 20')
        self.assertIsNotNone(warning)

    def test_apostrophe_and_no_cascade(self):
        rules = [dict(heard='can', replacement='CAN'), dict(heard='CAN', replacement='other')]
        self.assertEqual(apply_rules("can can't canyon", rules)[0], "CAN can't canyon")


class DownloadTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.folder = Path(self.tmp.name)
        self.payload = b'verified model bytes'
        self.manifest = dict(base_url='https://models.relic.space/test', files=[dict(name='model.bin', bytes=len(self.payload), sha256=hashlib.sha256(self.payload).hexdigest())])
        self.patch = patch.object(model_store, 'MANIFEST', self.manifest)
        self.patch.start()
    def tearDown(self): self.patch.stop(); self.tmp.cleanup()
    def response(self, data, status=200, headers=None):
        import io
        response = io.BytesIO(data)
        response.status, response.headers = status, headers or {}
        return response
    def test_checksum_failure_never_publishes(self):
        with patch('urllib.request.urlopen', return_value=self.response(b'X'*len(self.payload))):
            with self.assertRaises(ValueError): model_store.ensure_models(self.folder)
        self.assertFalse((self.folder/'model.bin').exists())
        self.assertFalse((self.folder/'model.bin.partial').exists())
    def test_resume_and_verified_offline_reuse(self):
        (self.folder/'model.bin.partial').write_bytes(self.payload[:5])
        with patch('urllib.request.urlopen', return_value=self.response(self.payload[5:],206,{'Content-Range':f'bytes 5-{len(self.payload)-1}/{len(self.payload)}'})) as request:
            model_store.ensure_models(self.folder)
            self.assertEqual(request.call_args[0][0].get_header('Range'), 'bytes=5-')
        with patch('urllib.request.urlopen', side_effect=AssertionError('network used')):
            model_store.ensure_models(self.folder)
        self.assertEqual((self.folder/'model.bin').read_bytes(),self.payload)
    def test_server_ignoring_range_restarts_safely(self):
        (self.folder/'model.bin.partial').write_bytes(b'bad')
        with patch('urllib.request.urlopen', return_value=self.response(self.payload)):
            model_store.ensure_models(self.folder)
        self.assertEqual((self.folder/'model.bin').read_bytes(),self.payload)
    def test_cancel_does_not_create_final(self):
        with self.assertRaises(InterruptedError): model_store.ensure_models(self.folder,canceled=lambda:True)
        self.assertFalse((self.folder/'model.bin').exists())


if __name__ == '__main__': unittest.main()
