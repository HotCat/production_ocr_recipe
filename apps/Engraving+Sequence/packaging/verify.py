#!/usr/bin/python3
"""Verify built packages with developer paths and network access unavailable."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('packages', nargs='+', type=Path)
    parser.add_argument('--inference', action='store_true', help='Load all packaged models and recognize a generated image')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='engraving-package-test-') as temporary:
        temp = Path(temporary)
        root = temp / 'root'
        root.mkdir()
        for deb in args.packages:
            subprocess.run(['dpkg-deb', '--extract', str(deb.resolve()), str(root)], check=True)
            info = subprocess.check_output(['dpkg-deb', '--field', str(deb), 'Depends'], text=True).strip()
            dependencies = {item.strip().split()[0] for item in info.split(',')}
            assert not dependencies.intersection({'ghc', 'gcc', 'haskell-stack', 'cabal-install', 'python3-dev'}), info
        empty = temp / 'empty'
        empty.touch()
        # This is runtime isolation, not a full Ubuntu VM. Host Ubuntu system libraries
        # remain available; all custom /opt, /home and /usr/local libraries are hidden.
        base = ['bwrap', '--unshare-user', '--unshare-pid', '--unshare-net', '--die-with-parent',
                '--clearenv', '--ro-bind', '/usr', '/usr', '--symlink', 'usr/bin', '/bin',
                '--symlink', 'usr/sbin', '/sbin', '--tmpfs', '/usr/local',
                '--ro-bind', '/lib', '/lib', '--ro-bind', '/lib64', '/lib64',
                '--ro-bind', '/etc', '/etc', '--ro-bind', str(empty), '/etc/ld.so.preload',
                '--ro-bind', str(empty), '/etc/ld.so.cache',
                '--ro-bind', str(root / 'opt'), '/opt', '--proc', '/proc', '--dev', '/dev',
                '--tmpfs', '/tmp', '--tmpfs', '/home', '--dir', '/home/test',
                '--setenv', 'HOME', '/home/test', '--setenv', 'PATH', '/usr/bin:/bin',
                '--setenv', 'LC_ALL', 'C.UTF-8', '--chdir', '/tmp']
        if Path('/usr/lib64').is_dir():
            base += ['--tmpfs', '/usr/lib64']
        if (root / 'opt/engraving-sequence/launch').exists():
            subprocess.run(base + ['/opt/engraving-sequence/launch', '--check'], check=True)
        ocr = root / 'opt/paddleocr-service/ocr'
        if ocr.exists():
            subprocess.run(base + ['/opt/paddleocr-service/ocr/launch', '--check'], check=True)
            if args.inference:
                script = '''import runpy, cv2, numpy as np, json
module = runpy.run_path('/opt/paddleocr-service/ocr/server.py')
image = np.full((140, 600, 3), 255, np.uint8)
cv2.putText(image, 'SERIAL 123456', (20, 90), cv2.FONT_HERSHEY_SIMPLEX, 1.7, (0,0,0), 3)
engine = module['PaddleEngine']('en', 'cpu')
result = engine.recognize(image)
print('Packaged inference:', json.dumps(result, ensure_ascii=False))
assert '123456' in result['text'], result
'''
                # Match the packaged service environment, while blocking network access.
                command = base + ['--setenv', 'PYTHONHOME', '/opt/paddleocr-service/python',
                    '--setenv', 'PYTHONNOUSERSITE', '1', '--setenv', 'PYTHONDONTWRITEBYTECODE', '1',
                    '--setenv', 'LD_LIBRARY_PATH', '/opt/paddleocr-service/python/lib',
                    '--setenv', 'PADDLE_PDX_CACHE_HOME', '/tmp/paddlex',
                    '--setenv', 'PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK', 'True',
                    '--setenv', 'PADDLE_PDX_ENABLE_MKLDNN_BYDEFAULT', 'False',
                    '--setenv', 'PADDLEOCR_MODEL_ROOT', '/opt/paddleocr-service/ocr/models',
                    '/opt/paddleocr-service/python/bin/python3', '-c', script]
                subprocess.run(command, check=True, timeout=240)
        for manifest in (root / 'usr/share/doc').glob('*/runtime-manifest.json'):
            data = json.loads(manifest.read_text())
            print(data['package'], ':', len(data['libraries']), 'native dependency records,',
                  len(data['system_dependencies']), 'Ubuntu runtime packages')
        print('Relocated package checks passed. Camera/PLC acceptance still requires the target hardware.')


if __name__ == '__main__':
    main()
