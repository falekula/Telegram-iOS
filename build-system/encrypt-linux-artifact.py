"""Encrypt a Linux build using the existing authenticated TGIPA1 artifact format."""
import argparse
import hashlib
import os
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def encrypt_artifact(source, password):
    if len(password.encode('utf-8')) < 32:
        raise ValueError('A strong TELEGRAM_ARTIFACT_PASSWORD is required')
    source = Path(source)
    plaintext = source.read_bytes()
    cipher = AESGCM(hashlib.sha256(password.encode('utf-8')).digest())
    nonce = os.urandom(12)
    ciphertext = cipher.encrypt(nonce, plaintext, None)
    if cipher.decrypt(nonce, ciphertext, None) != plaintext:
        raise RuntimeError('Artifact encryption verification failed')
    destination = source.with_name(source.name + '.enc')
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as output:
        output.write(b'TGIPA1' + nonce + ciphertext)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    arguments = parser.parse_args()
    try:
        encrypt_artifact(arguments.artifact, os.environ.get('TELEGRAM_ARTIFACT_PASSWORD', ''))
    except ValueError as error:
        raise SystemExit(str(error))
    print('Artifact encrypted and round-trip verified')


if __name__ == '__main__':
    main()
