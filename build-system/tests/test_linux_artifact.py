import hashlib
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest

try:
    from cryptography.exceptions import InvalidTag
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    raise unittest.SkipTest('cryptography is required for Linux artifact tests')


ROOT = Path(__file__).resolve().parents[1]
ENCRYPT = runpy.run_path(str(ROOT / 'encrypt-linux-artifact.py'))['encrypt_artifact']


class LinuxArtifactTests(unittest.TestCase):
    def test_existing_decryptor_round_trip_and_permissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'xxxgram-linux.tar.gz'
            plaintext = bytes(range(256)) * 512
            source.write_bytes(plaintext)
            password = 'test-key-with-more-than-thirty-two-characters'
            key_file = Path(temporary) / 'key'
            key_file.write_bytes(password.encode())
            encrypted = ENCRYPT(source, password)
            self.assertEqual(encrypted.stat().st_mode & 0o777, 0o600)
            self.assertEqual(encrypted.read_bytes()[:6], b'TGIPA1')
            source.unlink()
            result = subprocess.run([sys.executable, str(ROOT / 'decrypt-sideload-artifact.py'),
                                     str(encrypted), '--key-file', str(key_file)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(source.read_bytes(), plaintext)
            self.assertEqual(source.stat().st_mode & 0o777, 0o600)
            self.assertNotIn(password.encode(), result.stdout + result.stderr)

    def test_wrong_key_and_tampering_write_no_plaintext(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'archive.tar.gz'
            source.write_bytes(b'private application')
            password = 'correct-strong-test-key-0123456789012345'
            encrypted = ENCRYPT(source, password)
            original = encrypted.read_bytes()
            source.unlink()
            key_file = Path(temporary) / 'key'
            for key, blob in [
                ('wrong-strong-test-key-012345678901234567', original),
                (password, original[:-1] + bytes([original[-1] ^ 1])),
                (password, original[:8] + bytes([original[8] ^ 1]) + original[9:]),
            ]:
                with self.subTest(key_matches=key == password, blob_matches=blob == original):
                    encrypted.write_bytes(blob)
                    key_file.write_bytes(key.encode())
                    result = subprocess.run([sys.executable, str(ROOT / 'decrypt-sideload-artifact.py'),
                                             str(encrypted), '--key-file', str(key_file)], capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(source.exists())

    def test_fresh_nonce_and_no_overwrite_or_weak_password(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'archive'
            source.write_bytes(b'same plaintext')
            password = 'unicode-test-key-' + '\u044f' * 20
            with self.assertRaises(ValueError):
                ENCRYPT(source, 'short')
            self.assertFalse(source.with_suffix('.enc').exists())
            encrypted = ENCRYPT(source, password)
            first = encrypted.read_bytes()
            with self.assertRaises(FileExistsError):
                ENCRYPT(source, password)
            self.assertEqual(encrypted.read_bytes(), first)
            encrypted.unlink()
            second = ENCRYPT(source, password).read_bytes()
            self.assertNotEqual(first[6:18], second[6:18])
            key = hashlib.sha256(password.encode()).digest()
            self.assertEqual(AESGCM(key).decrypt(second[6:18], second[18:], None), source.read_bytes())
            with self.assertRaises(InvalidTag):
                AESGCM(key).decrypt(first[6:18], second[18:], None)


if __name__ == '__main__':
    unittest.main()
