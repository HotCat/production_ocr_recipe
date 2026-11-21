#!/bin/sh
# Real compiled client and GUI preview worker, without camera, PLC or log writes.
set -eu
app_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_dir=$(dirname -- "$(dirname -- "$app_dir")")
cd "$app_dir"
case ${1:-} in
  ''|--real) ;;
  *) echo 'Usage: tests/run_ocr_tests.sh [--real]' >&2; exit 2 ;;
esac
if [ -f stack.local.yaml ]; then export STACK_YAML="$app_dir/stack.local.yaml"; fi
export LD_LIBRARY_PATH="$repo_dir/build/native/fpp:$repo_dir/build/native/reconstruct:/opt/MVS/lib/64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if [ -f runtime-libraries.local.json ]; then
  local_dirs=$(python3 -c 'import json; print(":".join(json.load(open("runtime-libraries.local.json"))))')
  export LD_LIBRARY_PATH="$local_dirs:$LD_LIBRARY_PATH"
fi
generated_dir=$(stack path --dist-dir)/build/Camera/Camera-tmp
test_dir=$(mktemp -d /tmp/engraving-ocr-tests.XXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM
stack ghc -- -threaded -package husk-scheme -package opencv -package mtl \
  -package inline-c -package inline-c-cpp -package raw-strings-qq \
  -package text -package bytestring -package stm \
  -i../../shared/production-log -isrc -i"$generated_dir" -Isrc -optcxx-std=c++11 -lzmq \
  -outputdir "$test_dir" tests/OcrWorkerProbe.hs -o "$test_dir/worker-probe"
test_python=${ENGRAVING_TEST_PYTHON:-$repo_dir/services/paddleocr_service/.venv/bin/python}
if [ "${1:-}" = --real ]; then
  "$test_python" tests/test_ocr_worker.py --probe "$test_dir/worker-probe" \
    --real-endpoint "${PADDLEOCR_ENDPOINT:-tcp://127.0.0.1:5555}"
  "$test_python" ../Barcode+Sequence/tests/test_ocr_client.py --binary bin/Camera \
    --real-endpoint "${PADDLEOCR_ENDPOINT:-tcp://127.0.0.1:5555}"
else
  "$test_python" tests/test_ocr_worker.py --probe "$test_dir/worker-probe"
  "$test_python" ../Barcode+Sequence/tests/test_ocr_client.py --binary bin/Camera
fi
