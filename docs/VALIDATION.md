# Import validation

Validated on the existing Ubuntu 24.04 amd64 development workstation on
2026-11-17. This validates relocated source builds against the separately
installed native stack and SDKs; it is not a clean-machine provisioning test.
No camera, PLC, engraving machine or GUI was started by these checks. Existing
production checkouts and their running services were preserved.

## Builds

- `scripts/build-native.sh`: built `libFFPLibrary.so` and `libreconstruct.so`
  from `dependencies/vision-native` using the included CMake files.
- `scripts/build-all.sh`: built all five independent `Camera` executables with
  Stack `lts-18.28` / GHC 8.10.7 and the imported shared Haskell sources.
- `ldd` resolved every required library for all five executables with the native
  output directories and the externally installed ZMotion directory in
  `LD_LIBRARY_PATH`. No SDK binaries or build outputs are committed.

The native environment uses OpenCV 4.2.0, Open3D 0.19.0, DIPlib, CGAL 6.0.1,
Ceres, fmt, graphics/USB libraries, Hikvision MVS, MindVision and ZMotion.
See BUILDING.md for the separate external prerequisites. Existing compiler
warnings remain in the imported native/device sources. Cabal also warns that
relative sibling includes cannot produce independent Hackage source tarballs;
the supported build unit is this repository layout.

## Behavioral checks

- Shared service: four unittest groups passed, including independent concurrent
  clients and maximum simultaneous inference count of one.
- All three barcode clients: compiled CLI tests passed with mock responses and
  the existing real PaddleOCR endpoint. Guard-off operation avoids OCR; matching
  print passes, while vendor misprints, missing text and ambiguous/missing
  barcodes fail. The guard accepts the full decoded barcode as a substring of
  OCR text after removing OCR whitespace.
- Dual-barcode Haskell and CLI suites: exact full decoded strings, independent
  print-guard settings, stale-setting rejection, continuity, separate image
  regions, service failure/recovery, bounded concurrency and trigger latching.
  A matching last-16 suffix cannot pass different complete barcodes. Real
  ZBar/PaddleOCR checks exercise misprints on either label and unequal codes.
- Engraving comparator: Haskell and compiled CLI suites passed for mixed
  Chinese/English text, whole-text comparison ignoring whitespace and treating
  `：`/`:` equally, case/punctuation/extra-text rejection, empty presets, OCR
  errors, timeouts and two real concurrent clients. Saved UTF-8 presets and
  profile selection restore through the actual Scheme loader after the RAM
  files disappear. No sequence increment is involved.
- Retained packaging launcher unittest passed for first-run configuration,
  upgrade preservation and duplicate-instance rejection. This does not claim
  that new release installers were built for all five clients.
- Git-visible source audit passed; all Python and shell files passed syntax
  checks. Relative resource links stay inside this repository. No compiled
  SDK/library binaries, private keys, databases or build caches were staged.

The mock ZeroMQ fixtures keep their final reply socket alive until the client
finishes, preventing intermittent reply loss caused by immediate socket
teardown. This affects test infrastructure only.

## Reproduce

Follow README.md and BUILDING.md to install dependencies and build. Configure
external vendor paths using `scripts/configure-local.py`; add runtime vendor
paths to `LD_LIBRARY_PATH` as needed. Create the separate service environment
or point clients at an existing compatible endpoint.

```sh
services/paddleocr_service/.venv/bin/python -m unittest services.paddleocr_service.test_server
scripts/test-app.sh 'Barcode+Sequence+Barcode' --real
scripts/test-app.sh 'Engraving+Compare' --real
python3 -m unittest discover -s apps/Engraving+Sequence/packaging -p 'test_*.py'
python3 scripts/audit-source.py
```

The real endpoint used was `tcp://127.0.0.1:5555`, served by the existing shared
PaddleOCR installation. The tested Python package inventory is preserved in
`services/paddleocr_service/requirements-tested.txt`; its virtual environment
and models are deliberately external. Camera capture, physical machine cycles,
USB permissions and target display behavior require hardware validation.
