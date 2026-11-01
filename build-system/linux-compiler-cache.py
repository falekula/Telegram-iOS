"""Authenticate and bound the private compiler cache before writing any entries."""
import argparse
import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import runpy
import shutil
import tarfile
import tempfile

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAX_BYTES = 1024 ** 3
MAX_ARCHIVE = MAX_BYTES + 64 * 1024 ** 2
MAX_ENTRIES = 100000
ENCRYPT = runpy.run_path(str(Path(__file__).with_name('encrypt-linux-artifact.py')))['encrypt_artifact']


def save_cache(source, encrypted, password):
    source, encrypted = Path(source), Path(encrypted)
    paths = sorted(source.rglob('*'))
    if len(paths) > MAX_ENTRIES:
        raise ValueError('Cache entry limit exceeded')
    total = 0
    for path in paths:
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError('Unsupported cache entry')
        if path.is_file():
            total += path.stat().st_size
    if total > MAX_BYTES:
        raise ValueError('Cache byte limit exceeded')
    encrypted.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.cache-save-', dir=encrypted.parent) as scratch:
        archive = Path(scratch) / 'cache.tar.gz'
        with tarfile.open(archive, 'w:gz', compresslevel=1) as output:
            for path in paths:
                output.add(path, arcname=path.relative_to(source).as_posix(), recursive=False)
        if archive.stat().st_size > MAX_ARCHIVE:
            raise ValueError('Cache archive limit exceeded')
        # Encryption verifies its own authenticated round trip. Only this
        # encrypted result is handed to actions/cache; the temporary tar dies.
        os.replace(ENCRYPT(archive, password), encrypted)


def restore_cache(encrypted, destination, password):
    encrypted, destination = Path(encrypted), Path(destination)
    if destination.exists() or destination.is_symlink():
        raise FileExistsError('Cache destination already exists')
    if len(password.encode()) < 32 or encrypted.stat().st_size > MAX_ARCHIVE + 34:
        raise ValueError('Invalid cache input')
    blob = encrypted.read_bytes()
    if not blob.startswith(b'TGIPA1') or len(blob) < 34:
        raise ValueError('Invalid cache format')
    plaintext = AESGCM(hashlib.sha256(password.encode()).digest()).decrypt(
        blob[6:18], blob[18:], None)
    if len(plaintext) > MAX_ARCHIVE:
        raise ValueError('Cache archive limit exceeded')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.cache-restore-', dir=destination.parent) as scratch:
        stage = Path(scratch) / 'data'
        stage.mkdir(mode=0o700)
        with tarfile.open(fileobj=io.BytesIO(plaintext), mode='r:gz') as archive:
            total, count, seen = 0, 0, set()
            for member in archive:
                name = PurePosixPath(member.name)
                count += 1
                total += member.size
                if (count > MAX_ENTRIES or total > MAX_BYTES or member.size < 0
                        or name.is_absolute() or '..' in name.parts
                        or not name.parts or '\\' in member.name
                        or member.name in seen or not (member.isfile() or member.isdir())):
                    raise ValueError('Unsafe cache archive')
                seen.add(member.name)
                target = stage.joinpath(*name.parts)
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                if member.isdir():
                    target.mkdir(exist_ok=True, mode=0o700)
                else:
                    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    with os.fdopen(descriptor, 'wb') as output, archive.extractfile(member) as source:
                        shutil.copyfileobj(source, output, length=1024 * 1024)
        # All archive paths and content are authenticated before destination
        # becomes visible. Rename must never replace a preexisting cache.
        if destination.exists() or destination.is_symlink():
            raise FileExistsError('Cache destination already exists')
        stage.rename(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('save', 'restore'))
    parser.add_argument('cache', type=Path)
    parser.add_argument('encrypted', type=Path)
    args = parser.parse_args()
    password = os.environ.get('TELEGRAM_ARTIFACT_PASSWORD', '')
    try:
        if args.mode == 'save':
            save_cache(args.cache, args.encrypted, password)
        else:
            restore_cache(args.encrypted, args.cache, password)
    except Exception:
        # Archives can contain compiler inputs and API credentials. Never
        # echo exception payloads, file contents or paths from that archive.
        raise SystemExit('Private compiler cache unavailable; no unverified cache installed')
    print('Private compiler cache ' + ('encrypted' if args.mode == 'save' else 'authenticated and restored'))


if __name__ == '__main__':
    main()
