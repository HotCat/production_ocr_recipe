#!/bin/sh
# Build an ABI-compatible OpenCV 4.2 core without a native parallel worker pool.
# The installed modules/headers remain in use; only libopencv_core is overridden
# for these clients. Nothing is installed into /usr/local or PaddleOCR's venv.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -ne 1 ]; then
  echo 'Usage: scripts/build-opencv-lowcpu.sh /path/to/clean/opencv-4.2.0-source' >&2
  exit 2
fi
source_dir=$(CDPATH= cd -- "$1" && pwd)
python3 - "$source_dir" <<'PYTHON'
from pathlib import Path
import re
import sys
header = (Path(sys.argv[1]) / 'modules/core/include/opencv2/core/version.hpp').read_text()
version = tuple(int(re.search(r'#define CV_VERSION_' + part + r'\s+(\d+)', header)[1])
                for part in ('MAJOR', 'MINOR', 'REVISION'))
if version != (4, 2, 0):
    raise SystemExit('This override requires the same OpenCV 4.2.0 ABI as the installed modules')
PYTHON
if [ "$(pkg-config --modversion opencv)" != 4.2.0 ]; then
  echo 'The system opencv pkg-config package must be 4.2.0' >&2
  exit 1
fi
build_dir="$repo_dir/build/opencv-lowcpu"
prefix="$repo_dir/build/native/opencv-lowcpu"
cmake -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
  -DBUILD_LIST=core -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF \
  -DBUILD_opencv_apps=OFF -DBUILD_opencv_python2=OFF -DBUILD_opencv_python3=OFF \
  -DBUILD_JAVA=OFF -DENABLE_PRECOMPILED_HEADERS=OFF \
  -DWITH_PTHREADS_PF=OFF -DWITH_TBB=OFF -DWITH_OPENMP=OFF \
  -DWITH_HPX=OFF -DWITH_IPP=OFF
cmake --build "$build_dir" --target opencv_core --parallel "${BUILD_JOBS:-2}"
# Only the core shared library is needed. Keep other programs' OpenCV modules,
# headers and pkg-config metadata untouched, including the old core as rollback.
mkdir -p "$prefix/lib"
cp "$build_dir/lib/libopencv_core.so.4.2.0" "$prefix/lib/libopencv_core.so.4.2.0.new"
mv "$prefix/lib/libopencv_core.so.4.2.0.new" "$prefix/lib/libopencv_core.so.4.2.0"
ln -sfn libopencv_core.so.4.2.0 "$prefix/lib/libopencv_core.so.4.2"
ln -sfn libopencv_core.so.4.2 "$prefix/lib/libopencv_core.so"
echo "Installed client-only single-threaded OpenCV core: $prefix/lib"
