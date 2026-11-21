#!/bin/sh
# Compare the machine's OpenCV worker default with one and two workers, at 30fps.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/ocr-opencv-cpu.XXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM
# This repository's installed OpenCV 4.2 publishes the pkg-config name "opencv".
g++ -O2 -std=c++11 "$repo_dir/shared/performance/OpenCvCpuProbe.cpp" \
  $(pkg-config --cflags --libs opencv) -o "$test_dir/probe"
for threads in -1 1 2; do "$test_dir/probe" "$threads" "${1:-30}"; done
