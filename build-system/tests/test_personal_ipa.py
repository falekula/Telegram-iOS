import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile
import zlib


spec = importlib.util.spec_from_file_location(
    'verify_personal_ipa', Path(__file__).resolve().parents[1] / 'verify-personal-ipa.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def png_header(size, optimized=False):
    data = b'\x89PNG\r\n\x1a\n'
    if optimized:
        data += chunk(b'CgBI', b'\x50\x00\x20\x02')
    return data + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0))


class PersonalIpaTests(unittest.TestCase):
    def test_normal_and_xcode_png_dimensions(self):
        for optimized in (False, True):
            for size in (120, 180, 152, 167):
                with self.subTest(optimized=optimized, size=size):
                    self.assertEqual(verifier.png_dimensions(png_header(size, optimized)), (size, size))

    def test_malformed_png_rejected(self):
        signature = b'\x89PNG\r\n\x1a\n'
        for data in (b'not png', png_header(120, True)[:-1],
                     signature + chunk(b'IHDR', b'\0' * 8),
                     signature + chunk(b'IEND', b''),
                     signature + chunk(b'CgBI', b'\0' * 4)):
            with self.subTest(data=data), self.assertRaises(AssertionError):
                verifier.png_dimensions(data)

    def test_packaged_icons_keep_dimension_check(self):
        # Header fixtures exercise the package validator without decoding pixels.
        for optimized, wrong_size in ((False, False), (True, False), (False, True), (True, True)):
            with self.subTest(optimized=optimized, wrong_size=wrong_size), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'test.ipa'
                root = 'Payload/Telegram.app/'
                icons = {'CFBundleAlternateIcons': {'xxxgram': {'CFBundleIconFiles': ['xxxgram']}}}
                info = {'CFBundleIdentifier': 'ph.telegra.Telegraph', 'CFBundleDisplayName': 'xxxgram',
                        'CFBundleVersion': '123', 'CFBundleURLTypes': [{'CFBundleURLSchemes': ['falekulagram']}],
                        'CFBundleIcons': icons, 'CFBundleIcons~ipad': icons}
                with zipfile.ZipFile(path, 'w') as archive:
                    archive.writestr(root + 'Info.plist', plistlib.dumps(info))
                    for filename, size in [('xxxgram@2x.png', 120), ('xxxgram@3x.png', 180),
                                           ('xxxgram-76@2x.png', 152), ('xxxgram-83.5@2x.png', 167)]:
                        archive.writestr(root + filename, png_header(size + int(wrong_size), optimized))
                if wrong_size:
                    with self.assertRaisesRegex(AssertionError, 'Wrong icon dimensions'):
                        verifier.verify(path, '123')
                else:
                    self.assertEqual(verifier.verify(path, '123'), '123')


if __name__ == '__main__':
    unittest.main()
