#!/usr/bin/env python3
"""Export the tested CPU/CUDA service and Python runtime for offline Ubuntu 24.04.

No compiler, pip, network, Conda installation or GPU-specific engine rebuild is
needed on the target. NVIDIA's compatible host driver remains a prerequisite.
Models, runtimes and generated bundles stay outside Git.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
SERVICE = ROOT / 'services/paddleocr_service'


def interpreter_info(python):
    command = ('import json,sys,sysconfig; print(json.dumps(dict('
               'executable=sys.executable,base=sys.base_prefix,'
               'site=sysconfig.get_path("purelib"),version="%d.%d"%sys.version_info[:2])))')
    return json.loads(subprocess.check_output([str(python), '-c', command], text=True))


def copytree(source, target, *extra_ignored):
    shutil.copytree(source, target, ignore=shutil.ignore_patterns(
        '__pycache__', '*.pyc', *extra_ignored), symlinks=False)


def write_executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New bundle directory (must not exist)')
    parser.add_argument('--archive', action='store_true', help='Also create OUTPUT.tar.gz')
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    if output.exists():
        parser.error('Output already exists; choose a new path')
    cpu = interpreter_info(SERVICE / '.venv/bin/python')
    gpu = interpreter_info(SERVICE / '.venv-gpu/bin/python')
    if cpu['version'] != gpu['version']:
        parser.error('CPU/GPU Python versions must match')
    base = Path(cpu['base'])
    version = cpu['version']
    output.mkdir(parents=True)
    runtime = output / 'python'
    (runtime / 'bin').mkdir(parents=True)
    executable = Path(cpu['executable']).resolve()
    shutil.copy2(executable, runtime / 'bin' / ('python' + version))
    stdlib = base / 'lib' / ('python' + version)
    copytree(stdlib, runtime / 'lib' / ('python' + version), 'site-packages')
    copytree(Path(cpu['site']), runtime / 'lib' / ('python' + version) / 'site-packages')
    target_service = output / 'services/paddleocr_service'
    target_service.mkdir(parents=True)
    for source in SERVICE.glob('*.py'):
        shutil.copy2(source, target_service / source.name)
    for name in ('run.sh', 'requirements-tested.txt', 'README.md'):
        shutil.copy2(SERVICE / name, target_service / name)
    copytree(Path(gpu['site']), target_service / '.gpu-site', 'production-ocr-cpu-dependencies.pth')
    for models in ('legacy_models', 'official_models'):
        copytree(SERVICE / '.cache' / models, target_service / '.cache' / models)
    # Copy the base interpreter's own non-system native dependencies. Wheels
    # carry their private CUDA/BLAS libraries inside site-packages already.
    queue = [executable, *stdlib.joinpath('lib-dynload').glob('*.so')]
    visited = set()
    for binary in queue:
        if binary in visited:
            continue
        visited.add(binary)
        result = subprocess.run(['ldd', str(binary)], capture_output=True, text=True)
        for line in result.stdout.splitlines():
            words = line.split()
            if len(words) < 3 or words[1] != '=>':
                continue
            dependency = Path(words[2])
            if not dependency.is_absolute() or not dependency.is_relative_to(base):
                continue
            target = runtime / 'lib' / words[0]
            if not target.exists():
                shutil.copy2(dependency.resolve(), target)
                queue.append(dependency.resolve())
    for name, gpu_runtime in (('.venv', False), ('.venv-gpu', True)):
        prefix = '"$service_dir/.gpu-site:$repo_dir"' if gpu_runtime else '"$repo_dir"'
        wrapper = f'''#!/bin/sh
set -eu
service_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
repo_dir=$(dirname -- "$(dirname -- "$service_dir")")
unset PYTHONHOME
export PYTHONNOUSERSITE=1
export PYTHONPATH={prefix}
export LD_LIBRARY_PATH="$repo_dir/python/lib${{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}}"
exec "$repo_dir/python/bin/python{version}" "$@"
'''
        write_executable(target_service / name / 'bin/python', wrapper)
    (output / 'scripts').mkdir()
    shutil.copy2(ROOT / 'scripts/install-ocr-user-service.sh', output / 'scripts')
    write_executable(output / 'run-service.sh', '''#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$root/services/paddleocr_service/run.sh" "$@"
''')
    write_executable(output / 'install.sh', '''#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$root/services/paddleocr_service/.venv-gpu/bin/python" -m services.paddleocr_service.gpu_worker --probe
"$root/scripts/install-ocr-user-service.sh"
systemctl --user enable --now paddleocr.service
systemctl --user restart paddleocr.service
'''.replace('"$root/services/paddleocr_service/.venv-gpu/bin/python"', 'cd "$root"\n"$root/services/paddleocr_service/.venv-gpu/bin/python"', 1))
    (output / 'README.txt').write_text('''Offline production OCR service, Ubuntu 24.04 x86_64

Supports RTX 3090 / 3080 / 3070 using the same CUDA runtime and model files.
Install a compatible NVIDIA driver on the target first. No CUDA toolkit,
Python installation, compilation or model download is required.

Extract this entire directory anywhere writable. To validate GPU support:
  services/paddleocr_service/.venv-gpu/bin/python -m services.paddleocr_service.gpu_worker --probe
From this directory, run ./install.sh during a production break. It replaces
the current user's paddleocr.service path and restarts that service on 5555.
The old unit is backed up by the installer. Keep the bundle at this path after
installation; rerun install.sh after moving it. Clients/launcher may stay in
their existing checkout and still use tcp://127.0.0.1:5555.

For a standalone smoke test without replacing an existing service:
  ./run-service.sh --bind tcp://127.0.0.1:5556 --gpu-mode required

Client launcher JSON ocr_dispatch: cpu, gpu or auto. CPU workers remain
available if the optional GPU worker fails. Explicit gpu never silently falls
back or replays a failed inspection. Use service op=status to check readiness.
The GPU has one serial worker to bound VRAM use. Validate production images
and available VRAM on each target card; other operating systems, CPU
architectures and driver versions have not been certified by this export.
''')
    manifest = {}
    for path in sorted(output.rglob('*')):
        if path.is_file():
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                while block := stream.read(1024 * 1024):
                    digest.update(block)
            manifest[str(path.relative_to(output))] = {'sha256': digest.hexdigest(), 'bytes': path.stat().st_size}
    (output / 'manifest.json').write_text(json.dumps({
        'platform': 'Ubuntu 24.04 x86_64', 'python': version,
        'source_has_local_changes': bool(subprocess.check_output(
            ['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip()),
        'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'files': manifest}, indent=2) + '\n')
    print(f'Exported {len(manifest)} files: {output}', flush=True)
    if args.archive:
        archive = output.with_name(output.name + '.tar.gz')
        if archive.exists():
            raise FileExistsError(archive)
        with tarfile.open(archive, 'w:gz', compresslevel=1) as tar:
            tar.add(output, arcname=output.name)
        print(f'Archive: {archive}', flush=True)


if __name__ == '__main__':
    main()
