#!/usr/bin/env python3
"""Compile changed translation units without linking a distributable binary."""

import argparse
from pathlib import Path
import subprocess


BASELINE = '5c674f1f6a0f6ace55b67f8bc295138680fe588b'


def select_targets(changed, target_listing):
    targets = [line.rsplit(': ', 1)[0] for line in target_listing.splitlines()
               if ': ' in line]
    result = []
    for path in changed:
        if not path.startswith('Telegram/SourceFiles/') or not path.endswith('.cpp'):
            continue
        if path.startswith('Telegram/SourceFiles/tests/'):
            continue
        suffix = '/' + path.removeprefix('Telegram/') + '.o'
        matches = [target for target in targets if target.endswith(suffix)]
        if len(matches) != 1:
            raise ValueError(f'Expected one configured object for {path}, got {len(matches)}')
        result.extend(matches)
    if not result:
        raise ValueError('No changed application translation units were selected')
    return sorted(set(result))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve()
    build = source / 'out'
    ninja_file = 'build-Debug.ninja' if (build / 'build-Debug.ninja').exists() else 'build.ninja'
    changed = subprocess.check_output(
        ['git', '-C', str(source), 'diff', '--name-only', '--diff-filter=ACMR', '-z', BASELINE, 'HEAD'],
    ).decode().split('\0')
    command = ['ninja', '-C', str(build), '-f', ninja_file]
    listing = subprocess.check_output(command + ['-t', 'targets', 'all'], text=True)
    targets = select_targets(changed, listing)
    print(f'Checking {len(targets)} changed application translation units; no distributable binary.', flush=True)
    subprocess.run(command + ['-k', '0', '-j', '4'] + targets, check=True)


if __name__ == '__main__':
    main()
