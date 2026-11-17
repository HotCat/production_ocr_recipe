#!/usr/bin/env python3
"""Audit Git-visible sources without reading ignored runtime data or SDK binaries."""
import json
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
raw = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root)
paths = sorted(set(p.decode() for p in raw.split(b'\0') if p))
errors = []
secret_patterns = [
    re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'),
    re.compile(rb'(?<![A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[A-Z0-9]{16})(?![A-Za-z0-9])'),
]
for name in paths:
    p = root / name
    if any(part in {'.git', '.aws', '.codex', '.agents', '.venv', '.stack-work'} for part in p.relative_to(root).parts):
        errors.append(f'Forbidden directory: {name}')
        continue
    if p.is_symlink():
        target = p.resolve()
        if not target.is_relative_to(root) or not target.exists():
            errors.append(f'Invalid or escaping symlink: {name}')
        continue
    if not p.is_file():
        errors.append(f'Missing file: {name}')
        continue
    if p.stat().st_size >= 100 * 1024 * 1024:
        errors.append(f'GitHub size limit: {name}')
    content = p.read_bytes()
    if content.startswith((b'\x7fELF', b'!<arch>\n', b'SQLite format 3\0', b'MZ')):
        errors.append(f'Compiled binary/archive/database: {name}')
    if any(pattern.search(content) for pattern in secret_patterns):
        errors.append(f'Possible credential (inspect locally): {name}')
    if p.suffix in {'.cabal', '.yaml'} and b'/home/hotcat/Downloads/' in content:
        errors.append(f'Workstation build path: {name}')
for app in (root / 'apps').iterdir():
    lines = (app / 'stack.yaml').read_text().splitlines()
    packages = False
    for line in lines:
        if line == 'packages:':
            packages = True
            continue
        if packages and line.startswith('- '):
            if not (app / line[2:].strip()).is_dir():
                errors.append(f'Missing Stack package: {app.name}: {line}')
        elif packages and line and not line.startswith('#'):
            packages = False
for line in subprocess.check_output(['git', 'ls-files', '--stage'], cwd=root, text=True).splitlines():
    if line.startswith('160000 '):
        errors.append('Unexpected gitlink: ' + line.split('\t', 1)[-1])
if errors:
    print('\n'.join(errors))
    sys.exit(1)
print(f'PASS: {len(paths)} Git-visible source/assets files; no SDK binaries, build artifacts, escaping symlinks or credential signatures.')
