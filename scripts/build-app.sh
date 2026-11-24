#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -lt 1 ]; then
  echo 'Usage: scripts/build-app.sh APP [stack build options]' >&2
  exit 2
fi
application=$1
shift
opencv_library_dir="$repo_dir/build/native/opencv-lowcpu/lib"
if [ -r "$opencv_library_dir/libopencv_core.so.4.2" ]; then
  # Also use this runtime for direct bin/Camera launches, not only the launcher.
  set -- "--ghc-options=-optl-Wl,-rpath,$opencv_library_dir" "$@"
fi
case "$application" in
  Barcode+Sequence|Barcode+Sequence+Barcode|Barcode+Sequence+Engraving|Engraving+Sequence|Engraving+Compare) ;;
  *) echo "Unknown application: $application" >&2; exit 2 ;;
esac
cd "$repo_dir/apps/$application"
if [ -f stack.local.yaml ]; then
  stack --extra-lib-dirs "$repo_dir/build/native/fpp" --extra-lib-dirs "$repo_dir/build/native/reconstruct" --stack-yaml stack.local.yaml build Camera --copy-bins --local-bin-path bin "$@"
else
  stack --extra-lib-dirs "$repo_dir/build/native/fpp" --extra-lib-dirs "$repo_dir/build/native/reconstruct" build Camera --copy-bins --local-bin-path bin "$@"
fi
