#!/bin/sh
# All five real Haskell/C++ modules; loopback TCP only, no camera/PLC operations.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/ocr-debug-modbus.XXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM
for application in 'Barcode+Sequence' 'Barcode+Sequence+Barcode' 'Barcode+Sequence+Engraving' 'Engraving+Sequence' 'Engraving+Compare'; do
  case "$application" in
    Barcode+Sequence) variable_prefix=BARCODE_SEQUENCE ;;
    Barcode+Sequence+Barcode) variable_prefix=DOUBLE_BARCODE ;;
    Barcode+Sequence+Engraving) variable_prefix=BARCODE_ENGRAVING ;;
    Engraving+Sequence) variable_prefix=SEQUENCE ;;
    Engraving+Compare) variable_prefix=ENGRAVING_COMPARE ;;
  esac
  reader_option=
  case "$application" in Barcode*) reader_option=-DBARCODE_APP ;; esac
  cd "$repo_dir/apps/$application"
  export STACK_YAML="$PWD/stack.yaml"
  if [ -f stack.local.yaml ]; then export STACK_YAML="$PWD/stack.local.yaml"; fi
  native_dirs="/opt/MVS/lib/64:$repo_dir/build/native/fpp:$repo_dir/build/native/reconstruct"
  if [ -f runtime-libraries.local.json ]; then
    local_dirs=$(python3 -c 'import json; print(":".join(json.load(open("runtime-libraries.local.json"))))')
    native_dirs="$native_dirs:$local_dirs"
  fi
  export LD_LIBRARY_PATH="$native_dirs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  generated_dir=$(stack path --dist-dir)/build/Camera/Camera-tmp
  output_dir="$test_dir/$application"
  mkdir -p "$output_dir"
  stack ghc -- -threaded -package husk-scheme -package opencv -package mtl \
    -package inline-c -package inline-c-cpp -package raw-strings-qq \
    -package text -package bytestring -package stm -package async -package Yampa \
    -package sqlite-simple -package time -package filepath -package template-haskell \
    -i../../shared/production-log -isrc -i"$generated_dir" -Isrc -I../../dependencies/modbuspp \
    -optcxx-std=c++11 -L/opt/MVS/lib/64 -lMvCameraControl \
    -optl-Wl,-rpath,/opt/MVS/lib/64 -lzmq -lzbar $reader_option \
    -outputdir "$output_dir" "$repo_dir/shared/production-log/tests/ModbusDebugProbe.hs" -o "$output_dir/probe"
  python3 "$repo_dir/shared/production-log/tests/check_debug_modbus.py" "$output_dir/probe" "$variable_prefix"
done
