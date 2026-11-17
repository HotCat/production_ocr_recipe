#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cmake -S "$repo_dir/dependencies/vision-native" -B "$repo_dir/build/native" \
  -DCMAKE_BUILD_TYPE=Release "$@"
# Reconstruction templates use considerable memory; choose a conservative default.
cmake --build "$repo_dir/build/native" --parallel "${BUILD_JOBS:-2}"
