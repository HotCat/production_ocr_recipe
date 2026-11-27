#!/bin/sh
# Keep the validated CPU environment intact. GPU packages live in their own venv.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
service_dir="$repo_dir/services/paddleocr_service"
if [ "$#" -ne 1 ]; then
  echo 'Usage: scripts/install-ocr-gpu-runtime.sh /path/to/paddlepaddle_gpu-3.3.1-cp313-cp313-linux_x86_64.whl' >&2
  echo 'Use the official CUDA 11.8 wheel with NVIDIA driver >= 450.80.02; newer drivers are supported.' >&2
  exit 2
fi
wheel=$(realpath "$1")
[ -f "$wheel" ] || { echo "Missing GPU wheel: $wheel" >&2; exit 1; }
"$service_dir/.venv/bin/python" - "$wheel" <<'PY'
import pathlib, sys, zipfile
name = pathlib.Path(sys.argv[1]).name
if not name.startswith('paddlepaddle_gpu-3.3.1-cp313-cp313-') or sys.version_info[:2] != (3, 13):
    raise SystemExit('This runtime uses Paddle 3.3.1 with Python 3.13; use its matching GPU wheel')
with zipfile.ZipFile(sys.argv[1]) as wheel:
    if wheel.testzip() is not None:
        raise SystemExit('GPU wheel integrity check failed')
PY
if [ ! -x "$service_dir/.venv-gpu/bin/python" ]; then
  "$service_dir/.venv/bin/python" -m venv "$service_dir/.venv-gpu"
fi
# Share the unchanged OCR/PaddleX dependencies, but put GPU Paddle first in its
# own site-packages. The CPU workers never import this environment's packages.
"$service_dir/.venv-gpu/bin/python" - "$service_dir/.venv" <<'PY'
from pathlib import Path
import site, sys
cpu = Path(sys.argv[1]) / 'lib' / f'python{sys.version_info.major}.{sys.version_info.minor}' / 'site-packages'
Path(site.getsitepackages()[0], 'production-ocr-cpu-dependencies.pth').write_text(str(cpu.resolve()) + '\n')
PY
# Install the CUDA/cuDNN libraries pinned by the official wheel as well. They
# remain inside this environment; a system CUDA toolkit is unnecessary. For
# offline preparation use PIP_NO_INDEX=1 PIP_FIND_LINKS=/path/to/wheelhouse.
"$service_dir/.venv-gpu/bin/python" -m pip install "$wheel"
cd "$repo_dir"
"$service_dir/.venv-gpu/bin/python" -m services.paddleocr_service.gpu_worker --probe
echo 'GPU runtime prepared; restart paddleocr.service during a production break to add its GPU worker.'
