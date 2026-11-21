#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -lt 1 ]; then
  echo 'Usage: scripts/run-app.sh APP [arguments]' >&2
  exit 2
fi
application=$1
shift
case "$application" in
  Barcode+Sequence) config_name=sequence ;;
  Barcode+Sequence+Barcode) config_name=doublebarcode ;;
  Barcode+Sequence+Engraving) config_name=sequence2 ;;
  Engraving+Sequence) config_name=sequence3 ;;
  Engraving+Compare) config_name=engraving-compare ;;
  *) echo "Unknown application: $application" >&2; exit 2 ;;
esac

# Validate the CPU policy before touching user configuration files.
rts_capabilities=${OCR_RTS_CAPABILITIES:-2}
case "$rts_capabilities" in
  1|2) ;;
  *) echo "OCR_RTS_CAPABILITIES must be 1 or 2" >&2; exit 2 ;;
esac

app_dir="$repo_dir/apps/$application"
if [ ! -x "$app_dir/bin/Camera" ]; then
  echo "Build first: scripts/build-app.sh '$application'" >&2
  exit 1
fi
config_dir="$HOME/ocrconfigs/$config_name"
mkdir -p "$config_dir"
for profile in fun my config1 config2 config3; do
  # noclobber also protects against another launcher creating a profile.
  if [ ! -e "$config_dir/$profile.scm" ] && [ -f "$app_dir/src/$profile.scm" ]; then
    (set -C; cat "$app_dir/src/$profile.scm" > "$config_dir/$profile.scm")
  fi
done
local_library_dirs=
if [ -f "$app_dir/runtime-libraries.local.json" ]; then
  local_library_dirs=$(python3 - "$app_dir/runtime-libraries.local.json" <<'PYTHON'
import json
from pathlib import Path
import sys
paths = json.loads(Path(sys.argv[1]).read_text())
if not isinstance(paths, list) or any(not isinstance(p, str) or not p or ':' in p or '\n' in p for p in paths):
    raise SystemExit('Invalid runtime-libraries.local.json; regenerate with scripts/configure-local.py')
print(':'.join(paths))
PYTHON
  )
fi
export LD_LIBRARY_PATH="$repo_dir/build/native/fpp:$repo_dir/build/native/reconstruct${local_library_dirs:+:$local_library_dirs}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Keep the GHC runtime bounded even when the launcher inherits GHCRTS from a
# user's shell. Two capabilities leave the GUI responsive while preventing a
# client from scheduling Haskell work across every logical CPU. Set
# OCR_RTS_CAPABILITIES=1 on a constrained line; the value was validated above.
export GHCRTS="-N$rts_capabilities"
# GC counters are collected only for an explicitly requested diagnostic run.
# The native OpenCV limit is applied in Haskell before camera/worker startup.
if [ "${OCR_CPU_PROFILE:-0}" = 1 ]; then
  export GHCRTS="$GHCRTS -T"
fi

cd "$app_dir"
exec ./bin/Camera "$@"
