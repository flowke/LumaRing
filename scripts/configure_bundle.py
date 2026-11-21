#!/usr/bin/env python3
"""Read-only version source; stamp a staged app without changing repository files."""
import argparse
import base64
import json
import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_version(root=ROOT):
    value = (root / 'VERSION').read_text().strip()
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value):
        raise ValueError('VERSION must be an explicit stable version such as 0.1.0; no v prefix.')
    return value


def update_configuration(root=ROOT):
    config = json.loads((root / 'Resources/UpdateConfig.json').read_text())
    repository = config['repository']
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Invalid GitHub owner/repository.')
    if len(base64.b64decode(config['publicEDKey'], validate=True)) != 32:
        raise ValueError('A 32-byte Sparkle public Ed25519 key is required.')
    return config


def configure(destination, root=ROOT, *, development=False):
    version = read_version(root)
    info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
    info.update(CFBundleShortVersionString=version, CFBundleVersion=version)
    if development:
        info.update(CFBundleIdentifier=f"{info['CFBundleIdentifier']}.dev", CFBundleName='LumaRing Dev',
                    CFBundleDisplayName='LumaRing Dev', SUEnableAutomaticChecks=False)
        info.pop('SUFeedURL', None)
        info.pop('SUPublicEDKey', None)
    else:
        config = update_configuration(root)
        info.update(SUFeedURL=f"https://github.com/{config['repository']}/releases/latest/download/appcast.xml",
                    SUPublicEDKey=config['publicEDKey'])
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(plistlib.dumps(info, sort_keys=False))
    return info


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--print-version', action='store_true')
    parser.add_argument('--verify-tag')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--development', action='store_true')
    args = parser.parse_args()
    version = read_version()
    if args.verify_tag and args.verify_tag != f'v{version}':
        parser.error(f'Tag must exactly match VERSION: v{version}')
    if args.output:
        configure(args.output, development=args.development)
    if args.print_version:
        print(version)
