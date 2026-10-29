"""Decrypt a personal build using the locally stored key; never print credentials."""
import argparse
import hashlib
import os
from pathlib import Path
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

parser = argparse.ArgumentParser()
parser.add_argument('artifact', type=Path)
parser.add_argument('--key-file', type=Path, default=Path.home() / '.local/share/telegram-iphone-installer/artifact-password')
args = parser.parse_args()
blob = args.artifact.read_bytes()
if not blob.startswith(b'TGIPA1') or len(blob) < 34:
    raise SystemExit('Invalid encrypted artifact')
key = hashlib.sha256(args.key_file.read_bytes()).digest()
try:
    plaintext = AESGCM(key).decrypt(blob[6:18], blob[18:], None)
except Exception:
    raise SystemExit('Wrong key or damaged artifact; nothing written')
target = args.artifact.with_suffix('')
fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'wb') as output:
    output.write(plaintext)
print('Decrypted and authenticated:', target)
