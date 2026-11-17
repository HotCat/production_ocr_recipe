#!/usr/bin/env python3
"""Generate ignored local Stack files for separately installed vendor libraries."""
import argparse
from pathlib import Path
import json

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', help='Configure only this application')
parser.add_argument('--library-dir', type=Path, action='append', default=[])
parser.add_argument('--include-dir', type=Path, action='append', default=[])
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
for directory in args.library_dir + args.include_dir:
    if not directory.is_dir():
        parser.error(f'Not a directory: {directory}')
if args.app and not (root / 'apps' / args.app / 'stack.yaml').is_file():
    parser.error('Unknown application')
args.library_dir = [root / 'build/native/fpp', root / 'build/native/reconstruct'] + args.library_dir
for app in (root / 'apps').iterdir():
    if args.app and app.name != args.app:
        continue
    if not app.is_dir():
        continue
    text = (app / 'stack.yaml').read_text()
    for key, paths in [('extra-lib-dirs', args.library_dir), ('extra-include-dirs', args.include_dir)]:
        if paths:
            text += '\n' + key + ':\n' + ''.join('- ' + json.dumps(str(p.resolve())) + '\n' for p in paths)
    (app / 'stack.local.yaml').write_text(text)
    print(app.name + ': wrote stack.local.yaml')
