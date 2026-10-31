"""Renew bundled self-signed build profiles; the IPA still requires device re-signing."""
import argparse
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


SOURCE = Path(__file__).resolve().parent / 'fake-codesigning'


def openssl(*arguments):
    result = subprocess.run(['openssl', *map(str, arguments)], capture_output=True)
    if result.returncode:
        raise RuntimeError('OpenSSL failed during build-profile preparation: ' + arguments[0])
    return result.stdout


def prepare(output):
    output = Path(output).resolve()
    if output == SOURCE.resolve() or SOURCE.resolve() in output.parents:
        raise ValueError('Generated profiles must be outside the bundled signing directory')
    now = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)
    certificate = (SOURCE / 'certs/Public.cer').read_bytes()
    end_date = openssl('x509', '-inform', 'DER', '-in', SOURCE / 'certs/Public.cer', '-noout', '-enddate').decode().strip()
    expires = min(now + timedelta(days=30), datetime.strptime(end_date.split('=', 1)[1], '%b %d %H:%M:%S %Y %Z'))
    if expires <= now + timedelta(days=1):
        raise RuntimeError('Bundled build certificate must be renewed')

    with tempfile.TemporaryDirectory(prefix='xxxgram-build-profiles-') as temporary:
        temporary = Path(temporary)
        public_pem = temporary / 'public.pem'
        signing_pem = temporary / 'signing.pem'
        public_pem.write_bytes(openssl('x509', '-inform', 'DER', '-in', SOURCE / 'certs/Public.cer', '-outform', 'PEM'))
        # This is the repository's public, empty-password test identity, not an Apple account key.
        descriptor = os.open(signing_pem, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(descriptor)
        extraction = ['pkcs12', '-in', SOURCE / 'certs/SelfSigned.p12', '-passin', 'pass:', '-nodes', '-out', signing_pem]
        try:
            openssl(*extraction)
        except RuntimeError:
            # OpenSSL 3 needs its legacy provider for the bundled PKCS#12 encryption.
            openssl(*extraction, '-legacy')
        extracted_certificate = openssl('x509', '-in', signing_pem, '-outform', 'DER')
        if extracted_certificate != certificate:
            raise RuntimeError('Bundled build certificate and signing identity differ')

        profiles = sorted((SOURCE / 'profiles').glob('*.mobileprovision'))
        if not profiles:
            raise RuntimeError('No bundled build profiles found')
        staged = temporary / 'profiles'
        staged.mkdir()
        for source in profiles:
            # Verify against the bundled certificate, ignoring its untrusted self-signed chain.
            decoded = openssl('cms', '-verify', '-noverify', '-nointern', '-certfile', public_pem, '-inform', 'DER', '-in', source)
            profile = plistlib.loads(decoded)
            if profile.get('DeveloperCertificates') != [certificate]:
                raise RuntimeError('Unexpected developer certificate in ' + source.name)
            profile['CreationDate'] = now
            profile['ExpirationDate'] = expires
            profile['TimeToLive'] = (expires - now).days
            profile.pop('DER-Encoded-Profile', None)
            payload = temporary / 'profile.plist'
            payload.write_bytes(plistlib.dumps(profile))
            destination = staged / source.name
            openssl('cms', '-sign', '-binary', '-nodetach', '-in', payload,
                    '-signer', signing_pem, '-inkey', signing_pem, '-outform', 'DER', '-out', destination)
            verified = openssl('cms', '-verify', '-noverify', '-nointern', '-certfile', public_pem,
                               '-inform', 'DER', '-in', destination)
            if plistlib.loads(verified) != profile:
                raise RuntimeError('Generated profile verification failed: ' + source.name)
        # Publish only after all generated profiles have passed signature/content checks.
        (output / 'profiles').mkdir(parents=True, exist_ok=True)
        shutil.copytree(SOURCE / 'certs', output / 'certs', dirs_exist_ok=True)
        for profile in staged.iterdir():
            shutil.copy2(profile, output / 'profiles' / profile.name)
    print('Prepared {} build-only profiles; valid until {}'.format(len(profiles), expires.isoformat()))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', default='build/sideload-codesigning')
    prepare(parser.parse_args().output)
