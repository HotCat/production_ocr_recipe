#!/bin/sh
# Compile the actual camera constructor with fake SDK calls; never open hardware.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/ocr-camera-selection.XXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM
camera_dir="$repo_dir/dependencies/husk-scheme/hs-src/Device/Camera/Hikvision"
mvs_include=${HIKVISION_INCLUDE_DIR:-/opt/MVS/include}
# pkg-config flags intentionally split into compiler arguments.
${CXX:-c++} -std=c++14 -Wall -Wextra -I"$camera_dir" -I"$mvs_include" \
  $(pkg-config --cflags opencv) \
  "$repo_dir/shared/camera-tests/CameraSelectionSpec.cpp" \
  -o "$test_dir/camera-selection" $(pkg-config --libs opencv)
"$test_dir/camera-selection"
