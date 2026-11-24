#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/ocr-texture-cpu.XXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM
g++ -O2 -std=c++11 "$repo_dir/shared/performance/TextureUploadCpuProbe.cpp" \
  $(pkg-config --cflags --libs opencv glfw3 glew gl) -o "$test_dir/probe"
for mode in legacy base reuse; do "$test_dir/probe" "$mode"; done
