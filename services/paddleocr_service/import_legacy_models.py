"""Copy the production-tested PP-OCRv3 weights/dictionary into the service cache.

Usage: python -m services.paddleocr_service.import_legacy_models MODEL_ROOT EN_DICT
MODEL_ROOT contains ch_PP-OCRv3_det_infer and en_PP-OCRv3_rec_infer.
No inference code or shared libraries from the old OS are needed at runtime.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil


def import_models(source: Path, dictionary: Path, destination: Path) -> dict:
    files = [(source / model / name, Path(model) / name)
             for model in ('ch_PP-OCRv3_det_infer', 'en_PP-OCRv3_rec_infer')
             for name in ('inference.pdmodel', 'inference.pdiparams')]
    files.append((dictionary, Path('en_dict.txt')))
    # Validate every source/conflict before writing anything.
    manifest = {}
    for original, relative in files:
        data = original.read_bytes()
        if not data:
            raise ValueError(f'Empty model asset: {original}')
        target = destination / relative
        digest = hashlib.sha256(data).hexdigest()
        if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise ValueError(f'Refusing to overwrite different model asset: {target}')
        manifest[str(relative)] = {'sha256': digest, 'bytes': len(data)}
    for original, relative in files:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            shutil.copy2(original, target)
    (destination / 'manifest.json').write_text(
        json.dumps({'profile': 'legacy_en', 'use_angle_cls': False, 'files': manifest},
                   indent=2) + '\n', encoding='utf-8')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('model_root', type=Path)
    parser.add_argument('english_dictionary', type=Path)
    parser.add_argument('--destination', type=Path,
                        default=Path(__file__).parent / '.cache' / 'legacy_models')
    args = parser.parse_args()
    manifest = import_models(args.model_root, args.english_dictionary, args.destination)
    print(f'Imported {len(manifest)} verified assets to {args.destination.resolve()}')


if __name__ == '__main__':
    main()
