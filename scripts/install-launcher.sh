#!/bin/sh
# Install the launcher only; does not start any production application.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Qt must use Ubuntu's native library stack rather than Conda's X11/XKB ABI.
launcher_base_python=${OCR_LAUNCHER_BASE_PYTHON:-/usr/bin/python3}
if [ ! -x "$launcher_base_python" ]; then
  printf 'Python interpreter not found: %s\n' "$launcher_base_python" >&2
  exit 1
fi
rebuild_environment=false
if [ -x "$repo_dir/launcher/.venv/bin/python" ]; then
  existing_base=$("$repo_dir/launcher/.venv/bin/python" -c 'import sys; print(sys.base_prefix)')
  requested_base=$("$launcher_base_python" -c 'import sys; print(sys.base_prefix)')
  if [ "$existing_base" != "$requested_base" ]; then rebuild_environment=true; fi
fi
if "$rebuild_environment"; then
  "$launcher_base_python" -m venv --clear "$repo_dir/launcher/.venv"
else
  "$launcher_base_python" -m venv "$repo_dir/launcher/.venv"
fi
"$repo_dir/launcher/.venv/bin/python" -m pip install -r "$repo_dir/launcher/requirements.txt"
cd "$repo_dir"
"$repo_dir/launcher/.venv/bin/python" -m launcher --check-config
# Generate the user's desktop menu entry with the current clone's path.
"$repo_dir/launcher/.venv/bin/python" - "$repo_dir" <<'PY'
import os
from pathlib import Path
import sys
repo = Path(sys.argv[1])
directory = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share'))) / 'applications'
directory.mkdir(parents=True, exist_ok=True)
# Escape the Desktop Entry specification's reserved characters, not shell syntax.
def quoted(value):
    value = str(value).replace('%', '%%').replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$')
    return '"' + value + '"'
entry = directory / 'production-ocr-launcher.desktop'
entry.write_text('[Desktop Entry]\nType=Application\nName=Production OCR Launcher\nName[zh_CN]=生产 OCR 启动器\n'
                 'Comment=Select a production OCR application and its parameters\n'
                 'Exec=' + quoted(repo / 'scripts/run-launcher.sh') + '\n'
                 'Icon=applications-science\nTerminal=false\nCategories=Utility;\nStartupNotify=true\n', encoding='utf-8')
print('Installed desktop menu entry:', entry)
PY
printf '%s\n' 'Launcher installed. Start it with scripts/run-launcher.sh or the desktop menu.'
