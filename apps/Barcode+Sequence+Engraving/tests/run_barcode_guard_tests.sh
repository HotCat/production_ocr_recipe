#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
test_python=${BARCODE_TEST_PYTHON:-python3}
case ${1:-} in
  ''|--real) ;;
  *) echo 'Usage: tests/run_barcode_guard_tests.sh [--real]' >&2; exit 2 ;;
esac
stack build Camera --copy-bins --local-bin-path bin
generated_dir=$(stack path --dist-dir)/build/Camera/Camera-tmp
test_dir=$(mktemp -d /tmp/sequence-barcode-tests.XXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM
stack ghc -- -threaded -package husk-scheme -package opencv -package mtl \
  -package inline-c -package inline-c-cpp -package raw-strings-qq \
  -package text -package bytestring -package stm -package async -package Yampa \
  -isrc -i"$generated_dir" -Isrc -I../../dependencies/modbuspp \
  -optcxx-std=c++11 -L/opt/MVS/lib/64 -lMvCameraControl \
  -optl-Wl,-rpath,/opt/MVS/lib/64 -lzmq -lzbar \
  -outputdir "$test_dir" tests/BarcodeGuardSpec.hs -o "$test_dir/guard-tests"
if [ "${1:-}" = --real ]; then
  "$test_python" tests/generate_barcode_guard_labels.py "$test_dir/labels"
  "$test_dir/guard-tests" "$test_dir/labels"
  "$test_python" tests/test_barcode_guard.py --binary bin/Camera \
    --real-endpoint "${PADDLEOCR_ENDPOINT:-tcp://127.0.0.1:5555}"
else
  "$test_dir/guard-tests"
  "$test_python" tests/test_barcode_guard.py --binary bin/Camera
fi
