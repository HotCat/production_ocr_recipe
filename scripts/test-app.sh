#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -lt 1 ]; then
  echo 'Usage: scripts/test-app.sh APP [--real]' >&2
  exit 2
fi
application=$1
shift
case "$application" in
  Barcode+Sequence|Barcode+Sequence+Barcode|Barcode+Sequence+Engraving) runner=tests/run_barcode_guard_tests.sh ;;
  Engraving+Compare) runner=tests/run_engraving_compare_tests.sh ;;
  Engraving+Sequence) echo 'No application-specific test runner; run the shared service tests.' >&2; exit 2 ;;
  *) echo "Unknown application: $application" >&2; exit 2 ;;
esac
cd "$repo_dir/apps/$application"
if [ ! -f stack.local.yaml ]; then
  python3 "$repo_dir/scripts/configure-local.py" --app "$application"
fi
if [ -f stack.local.yaml ]; then
  export STACK_YAML="$PWD/stack.local.yaml"
fi
export LD_LIBRARY_PATH="$repo_dir/build/native/fpp:$repo_dir/build/native/reconstruct${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export BARCODE_TEST_PYTHON="${BARCODE_TEST_PYTHON:-$repo_dir/services/paddleocr_service/.venv/bin/python}"
export ENGRAVING_TEST_PYTHON="${ENGRAVING_TEST_PYTHON:-$repo_dir/services/paddleocr_service/.venv/bin/python}"
exec sh "$runner" "$@"
