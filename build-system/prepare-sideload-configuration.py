"""Inject Actions secrets without writing credentials into the source tree or log."""
import json
import os
from pathlib import Path
import re


def main():
    api_id = os.environ.get('TELEGRAM_API_ID', '')
    api_hash = os.environ.get('TELEGRAM_API_HASH', '')
    if not api_id.isdecimal() or not 0 < int(api_id) <= 2147483647:
        raise SystemExit('Missing or invalid TELEGRAM_API_ID secret')
    if not re.fullmatch(r'[0-9a-fA-F]{32}', api_hash):
        raise SystemExit('Missing or invalid TELEGRAM_API_HASH secret')
    config = json.loads(Path('build-system/sideload-configuration.json').read_text())
    config.update(api_id=api_id, api_hash=api_hash)
    target = Path('build/private-sideload-configuration.json')
    target.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as output:
        json.dump(config, output)
    print('Private API configuration prepared')


if __name__ == '__main__':
    main()
