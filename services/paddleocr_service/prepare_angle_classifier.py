"""Explicitly provision the optional PaddleOCR 0/180-degree classifier.

Run on a networked preparation machine, or supply --archive for offline installs.
Inference never fetches assets. Copy the legacy_models directory to deployments.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import tarfile
import urllib.request

MODEL = 'ch_ppocr_mobile_v2.0_cls_infer'
URL = f'https://paddleocr.bj.bcebos.com/dygraph_v2.0/ch/{MODEL}.tar'
SHA256 = '507352585040d035da3b1e6374694ad679a850acb0a36a8d0d47984176357717'


def prepare(archive: bytes, destination: Path) -> Path:
    if hashlib.sha256(archive).hexdigest() != SHA256:
        raise ValueError('Angle classifier archive SHA256 mismatch')
    assets = {}
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        # Extract only these two exact regular files; no arbitrary archive paths.
        for name in ('inference.pdmodel', 'inference.pdiparams'):
            member = tar.getmember(f'{MODEL}/{name}')
            if not member.isfile():
                raise ValueError(f'Not a regular model file: {name}')
            assets[name] = tar.extractfile(member).read()
    target = destination / MODEL
    for name, data in assets.items():
        if not data:
            raise ValueError(f'Empty model file: {name}')
        if (target / name).exists() and (target / name).read_bytes() != data:
            raise ValueError(f'Refusing to overwrite different model asset: {target / name}')
    target.mkdir(parents=True, exist_ok=True)
    for name, data in assets.items():
        if not (target / name).exists():
            (target / name).write_bytes(data)
    (target / 'manifest.json').write_text(json.dumps({
        'source': URL, 'archive_sha256': SHA256,
        'labels': ['0', '180'], 'threshold': .9,
        'files': {name: {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
                  for name, data in assets.items()},
    }, indent=2) + '\n')
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='Previously downloaded official .tar (offline)')
    parser.add_argument('--destination', type=Path, default=Path(os.getenv(
        'PADDLEOCR_LEGACY_MODEL_ROOT', str(Path(__file__).parent / '.cache' / 'legacy_models'))))
    args = parser.parse_args()
    if args.archive:
        archive = args.archive.read_bytes()
    else:
        with urllib.request.urlopen(URL, timeout=60) as response:
            archive = response.read()
    print(f'Prepared verified classifier: {prepare(archive, args.destination).resolve()}')


if __name__ == '__main__':
    main()
