import io
from pathlib import Path
import runpy
import tarfile
import tempfile
import unittest
from unittest.mock import patch

try:
    import cryptography
except ImportError:
    raise unittest.SkipTest('cryptography required')

MODULE = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'linux-compiler-cache.py'))
SAVE, RESTORE = MODULE['save_cache'], MODULE['restore_cache']
KEY = 'private-test-cache-password-at-least-32-characters'


class CompilerCacheTests(unittest.TestCase):
    def test_round_trip_exclusive_restore_and_encrypted_payload(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = root / 'source'; source.mkdir()
            (source / 'a').mkdir(); (source / 'a/result').write_bytes(b'api-secret-example' * 100)
            encrypted = root / 'cache.enc'; SAVE(source, encrypted, KEY)
            self.assertNotIn(b'api-secret-example', encrypted.read_bytes())
            self.assertEqual(encrypted.stat().st_mode & 0o777, 0o600)
            RESTORE(encrypted, root / 'restored', KEY)
            self.assertEqual((root / 'restored/a/result').read_bytes(), (source / 'a/result').read_bytes())
            with self.assertRaises(FileExistsError): RESTORE(encrypted, root / 'restored', KEY)
            self.assertEqual(list(root.glob('.cache-*')), [])

    def test_authentication_failure_leaves_destination_absent(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); source=root/'source'; source.mkdir(); (source/'result').write_bytes(b'private')
            encrypted=root/'cache.enc'; SAVE(source, encrypted, KEY)
            for password in [KEY+'wrong', KEY]:
                if password==KEY:
                    b=encrypted.read_bytes(); encrypted.write_bytes(b[:-1]+bytes([b[-1]^1]))
                with self.assertRaises(Exception): RESTORE(encrypted,root/'restored',password)
                self.assertFalse((root/'restored').exists())

    def test_authenticated_unsafe_archives_are_rejected_atomically(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            for name,kind in [('../escape',tarfile.REGTYPE),('/absolute',tarfile.REGTYPE),
                              ('link',tarfile.SYMTYPE),('hard',tarfile.LNKTYPE),('fifo',tarfile.FIFOTYPE)]:
                archive=root/'bad.tar.gz'
                with tarfile.open(archive,'w:gz') as out:
                    good=tarfile.TarInfo('good'); good.size=2; out.addfile(good,io.BytesIO(b'ok'))
                    bad=tarfile.TarInfo(name); bad.type=kind; bad.linkname='../escape'; out.addfile(bad)
                encrypted=MODULE['ENCRYPT'](archive,KEY)
                with self.assertRaises(ValueError): RESTORE(encrypted,root/'restored',KEY)
                self.assertFalse((root/'restored').exists());self.assertFalse((root/'escape').exists())
                encrypted.unlink()
            self.assertEqual(list(root.glob('.cache-*')), [])

    def test_links_cannot_be_saved(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); source=root/'source';source.mkdir();(source/'link').symlink_to('/etc/passwd')
            with self.assertRaises(ValueError): SAVE(source,root/'cache.enc',KEY)
            self.assertFalse((root/'cache.enc').exists())

    def test_authenticated_archive_limits_are_enforced_before_install(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); archive=root/'large.tar.gz'
            with tarfile.open(archive,'w:gz') as out:
                for name in ['one','two']:
                    entry=tarfile.TarInfo(name);entry.size=3;out.addfile(entry,io.BytesIO(b'123'))
            encrypted=MODULE['ENCRYPT'](archive,KEY)
            for limit in [{'MAX_BYTES':5},{'MAX_ENTRIES':1},{'MAX_ARCHIVE':1}]:
                with patch.dict(RESTORE.__globals__,limit):
                    with self.assertRaises(ValueError): RESTORE(encrypted,root/'restored',KEY)
                self.assertFalse((root/'restored').exists())
            source=root/'source';source.mkdir();(source/'one').write_bytes(b'123')
            with patch.dict(SAVE.__globals__,{'MAX_BYTES':2}):
                with self.assertRaises(ValueError): SAVE(source,root/'oversized.enc',KEY)
            self.assertFalse((root/'oversized.enc').exists())


if __name__ == '__main__':
    unittest.main()
