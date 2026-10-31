"""Exercise real CMS signatures and preserve all application entitlements."""
from datetime import datetime, timedelta, timezone
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'build-system/fake-codesigning'


@unittest.skipUnless(shutil.which('openssl'), 'OpenSSL required')
class SideloadProfileTests(unittest.TestCase):
    def test_renewed_profiles_keep_identity_entitlements_and_valid_signature(self):
        original_hashes = {p.name: hashlib.sha256(p.read_bytes()).digest() for p in (SOURCE / 'profiles').glob('*.mobileprovision')}
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'generated'
            subprocess.run([sys.executable, str(ROOT / 'build-system/prepare-sideload-profiles.py'), '--output', str(output)], check=True, capture_output=True)
            cert = Path(temporary) / 'public.pem'
            subprocess.run(['openssl', 'x509', '-inform', 'DER', '-in', str(SOURCE / 'certs/Public.cer'), '-out', str(cert)], check=True, capture_output=True)

            def decode(path):
                # Make's DirectoryCodesigningSource uses smime, while the preparer verifies CMS.
                value = subprocess.run(['openssl', 'smime', '-verify', '-noverify', '-nointern', '-certfile', str(cert), '-inform', 'DER', '-in', str(path)], check=True, capture_output=True)
                return plistlib.loads(value.stdout)

            self.assertEqual({p.name for p in (output / 'profiles').glob('*.mobileprovision')}, set(original_hashes))
            now = datetime.now(timezone.utc).replace(tzinfo=None)
            for name, checksum in original_hashes.items():
                original = decode(SOURCE / 'profiles' / name)
                renewed = decode(output / 'profiles' / name)
                self.assertGreater(renewed['ExpirationDate'], now + timedelta(days=29))
                self.assertLessEqual(renewed['CreationDate'], now)
                self.assertGreater(renewed['CreationDate'], now - timedelta(minutes=1))
                self.assertEqual(renewed['TimeToLive'], 30)
                for field in ['CreationDate', 'ExpirationDate', 'TimeToLive', 'DER-Encoded-Profile']:
                    original.pop(field, None)
                    renewed.pop(field, None)
                self.assertEqual(renewed, original, name)
                self.assertEqual(hashlib.sha256((SOURCE / 'profiles' / name).read_bytes()).digest(), checksum)
            for original in (SOURCE / 'certs').iterdir():
                self.assertEqual((output / 'certs' / original.name).read_bytes(), original.read_bytes())


if __name__ == '__main__':
    unittest.main()
