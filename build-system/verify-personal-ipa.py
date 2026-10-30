"""Check the packaged app, where generated plist fragments can override source files."""
import argparse
import plistlib
import re
import struct
import zipfile


def png_dimensions(data):
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'Invalid icon PNG'
    # Xcode's optimized PNGs put a CgBI chunk before IHDR. Locate IHDR by
    # walking chunks instead of assuming it immediately follows the signature.
    offset = 8
    while offset + 12 <= len(data):
        length = struct.unpack_from('>I', data, offset)[0]
        chunk_type = data[offset + 4:offset + 8]
        end = offset + 12 + length
        assert end <= len(data), 'Truncated icon PNG chunk'
        if chunk_type == b'IHDR':
            assert length == 13, 'Invalid icon PNG header'
            return struct.unpack_from('>II', data, offset + 8)
        if chunk_type == b'IEND':
            break
        offset = end
    raise AssertionError('Missing icon PNG header')


def verify(path, expected_build=None):
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, 'Corrupt IPA archive'
        root = 'Payload/Telegram.app/'
        info = plistlib.loads(archive.read(root + 'Info.plist'))
        assert info['CFBundleIdentifier'] == 'ph.telegra.Telegraph', 'Unexpected bundle identifier'
        assert info['CFBundleDisplayName'] == 'xxxgram', 'Packaged display name was overwritten'
        if expected_build is not None:
            assert str(info['CFBundleVersion']) == str(expected_build), 'Wrong build number'
        schemes = {scheme for row in info.get('CFBundleURLTypes', []) for scheme in row.get('CFBundleURLSchemes', [])}
        assert 'falekulagram' in schemes, 'Missing personal launcher URL scheme'
        for key in ('CFBundleIcons', 'CFBundleIcons~ipad'):
            icons = info.get(key, {}).get('CFBundleAlternateIcons', {})
            assert 'xxxgram' in icons, 'Missing xxxgram alternate icon in ' + key
            assert icons['xxxgram'].get('CFBundleIconFiles'), 'Empty icon file list'
        for filename, size in [('xxxgram@2x.png', 120), ('xxxgram@3x.png', 180), ('xxxgram-76@2x.png', 152), ('xxxgram-83.5@2x.png', 167)]:
            data = archive.read(root + filename)
            dimensions = png_dimensions(data)
            assert dimensions == (size, size), f'Wrong icon dimensions: {filename}: {dimensions}, expected {(size, size)}'
        for filename in archive.namelist():
            if not re.fullmatch(re.escape(root) + r'[^/]+\.lproj/InfoPlist\.strings', filename):
                continue
            data = archive.read(filename)
            try:
                strings = plistlib.loads(data)
            except plistlib.InvalidFileException:
                # actool/plutil normally converts these to binary plists.
                text = data.decode('utf-16' if data[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8-sig')
                match = re.search(r'"CFBundleDisplayName"\s*=\s*"([^"]*)"', text)
                strings = {'CFBundleDisplayName': match.group(1)} if match else {}
            assert strings.get('CFBundleDisplayName', 'xxxgram') == 'xxxgram', 'Localized app name overrides xxxgram'
        return info['CFBundleVersion']


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('ipa')
    parser.add_argument('--expected-build')
    args = parser.parse_args()
    version = verify(args.ipa, args.expected_build)
    print('Verified xxxgram IPA, build', version, '(name, launcher, iPhone/iPad icons, archive integrity)')
