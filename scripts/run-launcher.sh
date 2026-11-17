#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
launcher_python=${OCR_LAUNCHER_PYTHON:-$repo_dir/launcher/.venv/bin/python}
if [ ! -x "$launcher_python" ]; then
  printf '%s\n' 'Install the launcher first: scripts/install-launcher.sh' >&2
  exit 1
fi
cd "$repo_dir"
exec "$launcher_python" -m launcher "$@"
