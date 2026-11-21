#!/bin/sh
# Compile each real FRP network into an isolated probe. No IO callbacks are run.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/ocr-frp-cpu.XXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM
for application in 'Engraving+Sequence' 'Barcode+Sequence'; do
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
  flag=
  if [ "$application" = 'Barcode+Sequence' ]; then flag=-DBARCODE_APP; fi
  stack ghc -- -O2 -threaded -rtsopts -with-rtsopts=-N2 -package husk-scheme -package opencv -package mtl \
    -package inline-c -package inline-c-cpp -package raw-strings-qq \
    -package text -package bytestring -package stm -package async -package Yampa \
    -package sqlite-simple -package time -package filepath -package template-haskell \
    -i../../shared/production-log -isrc -i"$generated_dir" -Isrc -I../../dependencies/modbuspp \
    -optcxx-std=c++11 -L/opt/MVS/lib/64 -lMvCameraControl \
    -optl-Wl,-rpath,/opt/MVS/lib/64 -lzmq -lzbar $flag \
    -outputdir "$output_dir" "$repo_dir/shared/performance/FrpCpuProbe.hs" -o "$output_dir/probe"
  echo "$application: idle FRP network only; callbacks NOT executed"
  "$output_dir/probe" 100000 +RTS -T -s -RTS
done
