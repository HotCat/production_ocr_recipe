#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
case ${1:-} in
  ''|--real) ;;
  *) echo 'Usage: tests/run_engraving_compare_tests.sh [--real]' >&2; exit 2 ;;
esac
test_python=${ENGRAVING_TEST_PYTHON:-../../services/paddleocr_service/.venv/bin/python}
stack build Camera --copy-bins --local-bin-path bin
test_dir=$(mktemp -d /tmp/engraving-compare-tests.XXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM
stack ghc -- -threaded -package async -package text -package containers -package transformers \
  -package husk-scheme -i../../shared/production-log -isrc -L/opt/MVS/lib/64 -lMvCameraControl \
  -optl-Wl,-rpath,/opt/MVS/lib/64 -outputdir "$test_dir" \
  tests/EngravingCompareSpec.hs -o "$test_dir/compare-tests"
"$test_dir/compare-tests"
if [ "${1:-}" = --real ]; then
  "$test_python" -u tests/test_engraving_compare.py --binary bin/Camera \
    --real-endpoint "${PADDLEOCR_ENDPOINT:-tcp://127.0.0.1:5555}"
else
  "$test_python" -u tests/test_engraving_compare.py --binary bin/Camera
fi
