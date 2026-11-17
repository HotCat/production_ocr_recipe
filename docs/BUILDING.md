# External prerequisites and portable paths

The repository vendors the modified project sources. It does not vendor
standard Hackage/system packages, camera SDKs, ZMotion binary libraries, Paddle
models or Python environments. Those remain external installations.

## Ubuntu build packages

Typical Ubuntu 24.04 development dependencies (install through your normal
system provisioning, not through a production GUI):

```sh
sudo apt install build-essential cmake pkg-config git haskell-stack \
  libgmp-dev libtinfo-dev libffi-dev zlib1g-dev libzmq3-dev cppzmq-dev \
  libzbar-dev libglfw3-dev libglew-dev libgl1-mesa-dev libglu1-mesa-dev \
  libx11-dev libxxf86vm-dev libxrandr-dev libxi-dev libxcursor-dev \
  libusb-1.0-0-dev libeigen3-dev libsdl2-dev libsdl1.2-dev libsdl-mixer1.2-dev \
  libgtk2.0-dev libjpeg-dev libpng-dev libtiff-dev libmpfr-dev \
  libsqlite3-dev patchelf
```

This is the development host's custom native stack:

- OpenCV 4.2.0 with contrib modules, exposing `pkg-config opencv` (not just
  `opencv4`), and its CMake package. The Haskell binding's build description
  currently uses that pkg-config name. Keep the version consistent across all
  native and Haskell components. Upstream source:
  <https://github.com/opencv/opencv/tree/4.2.0> and
  <https://github.com/opencv/opencv_contrib/tree/4.2.0>.
- Open3D 0.19.0 with C++ development headers and CMake package:
  <https://github.com/isl-org/Open3D/tree/v0.19.0>.
- DIPlib with DIP/DIPviewer headers, libraries and CMake package:
  <https://github.com/DIPlib/diplib>.
- CGAL 6.0.1 development headers/CMake package, Ceres and fmt:
  <https://github.com/CGAL/cgal/tree/v6.0.1>,
  <https://github.com/ceres-solver/ceres-solver>, <https://github.com/fmtlib/fmt>.
  Native reconstruction compiles as C++17.

These are external open-source system installations, not copied `.so` files.
A stock Ubuntu OpenCV installation is a different ABI; do not mix it with
libraries compiled against the workstation's 4.2 stack. The included CMake
source builds `FFPLibrary` and `reconstruct` from the imported sources.

## Vendor installations (excluded from the repository)

- Hikvision MVS: headers in `/opt/MVS/include`, library in `/opt/MVS/lib/64`.
  Applications and Husk retain the MVS runtime search path.
- MindVision: install its `CameraApi.h` and related headers plus `libMVSDK.so`.
  The default search assumes system headers/library directories.
- ZMotion: install `libzmotion.so` separately. Its existing API headers and
  project wrapper source are retained in Husk, but no vendor binary is uploaded.

Use `scripts/configure-local.py --library-dir DIR --include-dir DIR` for
additional vendor paths (repeat arguments for multiple directories). This
creates ignored `stack.local.yaml` files. The build helper selects them when
present. For direct Stack commands/tests, export
`STACK_YAML="$PWD/stack.local.yaml"` in the application directory, or use
`scripts/test-app.sh` which does this automatically. Add external vendor
runtime paths to `LD_LIBRARY_PATH` or configure your system linker as usual.

No camera SDK installer, driver, transport plugin or precompiled library is
committed. The Haskell/C++ camera integration wrappers remain as necessary
project source. PCI/USB permissions and camera subnet setup remain installation
steps specific to your hardware.

## Source paths and runtime resources

Each application uses `../../dependencies/*`. Husk includes its own device
sources and the native headers under `../vision-native`; native library outputs
are under the repository's `build/native`. The build helper supplies absolute
linker paths computed from the current checkout; local Stack configurations
record these computed paths because Cabal rejects relative installed library
paths. Regenerate local settings after moving the clone. No build file requires the
old `/home/hotcat/Downloads/new3dvision` directory.

Fonts/textures are stored once in `assets/` with relative links from each app.
Run from the application directory, or use `scripts/run-app.sh`. The inherited
font assets and their ownership are preserved; the repository does not grant a
new license for third-party fonts.

The non-OCR 3D/calibration methods in the preserved Husk/native API still contain
historical site-specific data paths. They are not build dependencies for these
OCR clients and their calibration/data is not uploaded. Using those methods
requires separate configuration and validation.
