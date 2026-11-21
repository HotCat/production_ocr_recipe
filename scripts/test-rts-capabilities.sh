#!/bin/sh
# Test the actual installed binaries and launch path without GUI/camera/PLC/logs.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for application in 'Barcode+Sequence' 'Barcode+Sequence+Barcode' 'Barcode+Sequence+Engraving' 'Engraving+Sequence' 'Engraving+Compare'; do
  output=$(env -u OCR_OPENCV_THREADS GHCRTS=-N OCR_RTS_CAPABILITIES=2 \
    "$repo_dir/scripts/run-app.sh" "$application" --runtime-info 2>&1)
  echo "$output" | grep -F 'Haskell capabilities=2; OpenCV threads=1' >/dev/null
  echo "$application: $output"
done
output=$(OCR_RTS_CAPABILITIES=1 OCR_OPENCV_THREADS=2 \
  "$repo_dir/scripts/run-app.sh" 'Engraving+Sequence' --runtime-info 2>&1)
echo "$output" | grep -F 'Haskell capabilities=1; OpenCV threads=2' >/dev/null
if OCR_RTS_CAPABILITIES=3 "$repo_dir/scripts/run-app.sh" 'Engraving+Sequence' --runtime-info >/dev/null 2>&1; then
  echo 'Invalid RTS limit accepted' >&2; exit 1
fi
if OCR_OPENCV_THREADS=garbage "$repo_dir/scripts/run-app.sh" 'Engraving+Sequence' --runtime-info >/dev/null 2>&1; then
  echo 'Invalid native thread limit accepted' >&2; exit 1
fi
sh -n "$repo_dir/scripts/run-app.sh"
echo 'PASS: real capabilities/native limits, inherited GHCRTS override, invalid settings; no hardware initialized.'
