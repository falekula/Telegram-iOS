import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

PREPARE = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'prepare-sideload-configuration.py'))['main']


class ConfigurationTests(unittest.TestCase):
    def test_valid_and_missing_credentials(self):
        previous = Path.cwd()
        with tempfile.TemporaryDirectory() as temp:
            try:
                os.chdir(temp)
                Path('build-system').mkdir()
                Path('build-system/sideload-configuration.json').write_text('{"enable_icloud":false}')
                with patch.dict(os.environ, {'TELEGRAM_API_ID': '12345', 'TELEGRAM_API_HASH': 'ab' * 16}):
                    output = io.StringIO()
                    with contextlib.redirect_stdout(output):
                        PREPARE()
                    path = Path('build/private-sideload-configuration.json')
                    self.assertEqual(json.loads(path.read_text())['api_hash'], 'ab' * 16)
                    self.assertFalse(json.loads(path.read_text())['enable_icloud'])
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                    self.assertNotIn('ab' * 16, output.getvalue())
                for api_id, api_hash in [('', ''), ('-1', 'ab' * 16), ('123', 'short')]:
                    with patch.dict(os.environ, {'TELEGRAM_API_ID': api_id, 'TELEGRAM_API_HASH': api_hash}):
                        with self.assertRaises(SystemExit):
                            PREPARE()
            finally:
                os.chdir(previous)


if __name__ == '__main__':
    unittest.main()
